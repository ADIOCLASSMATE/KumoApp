import Foundation
import os

let shutdownLogger = Logger(subsystem: "io.kumo.KumoApp", category: "shutdown")

/// Result of a best-effort shutdown attempt. `status` is the most recent
/// observable core status (falls back to the on-disk state store, then a
/// stopped `CoreStatus()`). `diagnostics` lists every step that failed,
/// stage-prefixed, so callers can surface or log them without losing the
/// later errors to the first one — matching Sparkle's
/// `Promise.all([disable, stopCore])` + per-branch try/catch pattern.
public struct ShutdownResult: Sendable {
    public let status: CoreStatus
    public let diagnostics: [String]

    public init(status: CoreStatus, diagnostics: [String] = []) {
        self.status = status
        self.diagnostics = diagnostics
    }

    public var failed: Bool { !diagnostics.isEmpty }
}

enum RuntimeAuthority: Equatable, Sendable {
    /// Normal App/CLI construction. All production runtime mutations must be
    /// performed by the authenticated privileged Helper.
    case serviceRequired

    /// Restricted to the Helper process and isolated tests.
    case supervisor
}

public struct KumoController: Sendable {
    public let paths: KumoPaths
    let profileRepository: ProfileRepository
    let overrideRepository: OverrideRepository
    let supervisor: CoreSupervisor
    let stateStore: CoreStateStore
    let systemProxyController: SystemProxyController
    let coreInstaller: CoreInstaller
    let subStoreManager: SubStoreManager
    let backupManager: KumoBackupManager
    let appUpdateManager: AppUpdateManager
    let appUpdateInstaller: any AppUpdateInstalling
    let preferencesStore: UserPreferencesStore
    let subStoreSupervisor: SubStoreSupervisor
    let serviceManager: KumoServiceManager
    let profileActivationCoordinator: ProfileActivationCoordinator
    let profileOperationGate: ProfileOperationGate
    let profileOperationFileLock: ProfileOperationFileLock
    let privilegedCoreDestination: URL?
    let privilegedRuntimeOwnership: StateFileOwnership?
    let runtimeAuthority: RuntimeAuthority

    public init(
        paths: KumoPaths = KumoPaths(),
        systemProxyCommandRunner: SystemProxyCommandRunner = .live
    ) {
        self.init(
            paths: paths,
            useServiceBackend: true,
            systemProxyCommandRunner: systemProxyCommandRunner,
            stateFileOwnership: nil
        )
    }

    init(
        paths: KumoPaths,
        useServiceBackend: Bool,
        systemProxyCommandRunner: SystemProxyCommandRunner = .live,
        stateFileOwnership: StateFileOwnership? = nil,
        appUpdateInstaller: (any AppUpdateInstalling)? = nil
    ) {
        self.paths = paths
        let profilePaths: KumoPaths
        if let stateFileOwnership {
            profilePaths = KumoPaths(
                applicationSupportDirectory: paths
                    .privilegedRuntimeDirectory(userID: stateFileOwnership.userID)
                    .appendingPathComponent("profile-input-disabled", isDirectory: true),
                privilegedRuntimeRootDirectory: paths.privilegedRuntimeRootDirectory,
                privilegedServiceSupportDirectory: paths.privilegedServiceSupportDirectory
            )
        } else {
            profilePaths = paths
        }
        self.profileRepository = ProfileRepository(paths: profilePaths)
        self.overrideRepository = OverrideRepository(paths: paths)
        self.supervisor = CoreSupervisor(paths: paths, stateFileOwnership: stateFileOwnership)
        self.stateStore = CoreStateStore(paths: paths, ownership: stateFileOwnership)
        self.systemProxyController = SystemProxyController(
            paths: paths,
            commandRunner: systemProxyCommandRunner,
            stateFileOwnership: stateFileOwnership
        )
        self.coreInstaller = CoreInstaller(paths: paths)
        self.subStoreManager = SubStoreManager(paths: paths)
        self.backupManager = KumoBackupManager(paths: paths)
        self.appUpdateManager = AppUpdateManager()
        self.appUpdateInstaller = appUpdateInstaller ?? AppUpdateInstaller(paths: paths)
        self.preferencesStore = UserPreferencesStore(paths: paths)
        self.subStoreSupervisor = SubStoreSupervisor(paths: paths)
        self.serviceManager = KumoServiceManager(paths: paths)
        self.profileActivationCoordinator = ProfileActivationCoordinator()
        self.profileOperationGate = .shared
        self.profileOperationFileLock = ProfileOperationFileLock(url: paths.profileOperationLockFile)
        self.privilegedCoreDestination = stateFileOwnership.map {
            paths.privilegedManagedCoreExecutable(userID: $0.userID)
        }
        self.privilegedRuntimeOwnership = stateFileOwnership
        self.runtimeAuthority = useServiceBackend ? .serviceRequired : .supervisor
    }

    @_spi(KumoService)
    public init(
        servicePaths paths: KumoPaths,
        stateFileOwnership: StateFileOwnership,
        systemProxyCommandRunner: SystemProxyCommandRunner = .live
    ) {
        self.init(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: systemProxyCommandRunner,
            stateFileOwnership: stateFileOwnership
        )
    }

    public func status() throws -> CoreStatus {
        if runtimeAuthority == .serviceRequired {
            let serviceStatus = serviceManager.status()
            guard serviceStatus.isInstalled || serviceStatus.isRunning else {
                return try supervisor.status()
            }
            if var legacy = legacyLocalRuntimeStatus() {
                legacy.serviceModeStatus = serviceStatusBlockingPendingLegacyMigration(
                    serviceStatus
                )
                legacy.message = "Legacy Mihomo is still serving traffic. Complete Kumo Helper migration."
                return legacy
            }
            guard serviceStatus.isRunning,
                  let client = serviceManager.serviceClient() else {
                throw KumoError.serviceUnavailable("Kumo Helper is installed but unavailable.")
            }
            return try status(using: client)
        }
        return try supervisor.status()
    }

    public func currentProfile() throws -> ProfileSummary {
        try profileRepository.currentProfileSummary()
    }

    public func profiles() throws -> [ProfileSummary] {
        try profileRepository.listProfiles()
    }

    func setCurrentProfile(id: String) throws {
        try profileRepository.setCurrentProfile(id: id)
    }

    public func coreCandidates() throws -> [CoreCandidate] {
        if let client = runningServiceClient() {
            return try client.sendDecodable(client.coreCandidatesRequest(), as: [CoreCandidate].self)
        }
        let status = try stateStore.load()
        return supervisor.discoverCoreCandidates(configuredPath: status.corePath)
    }

    public func setCorePath(_ path: String) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw KumoError.coreNotFound(path)
            }
            if let _ = try self.serviceClientForMutation() {
                throw KumoError.serviceUnavailable(
                    "Custom core paths are unavailable while Kumo Helper is installed. The Helper always uses its protected managed core."
                )
            }
            let liveStatus = try self.supervisor.status()
            guard ProfileActivationCoordinator.isStrictlyStopped(liveStatus) else {
                throw KumoError.commandFailed("Stop Kumo before changing the core executable.")
            }
            var status = try self.stateStore.load()
            status.corePath = path
            try self.stateStore.save(status)
        }
    }

    /// Clear any explicit core path so the supervisor falls back to auto-discovery
    /// (managed core, env, $PATH, bundled binaries).
    public func clearCorePath() async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let serviceClient = try self.serviceClientForMutation()
            let liveStatus = try self.status(using: serviceClient)
            guard ProfileActivationCoordinator.isStrictlyStopped(liveStatus) else {
                throw KumoError.commandFailed("Stop Kumo before changing the core executable.")
            }
            var status = try self.stateStore.load()
            status.corePath = nil
            try self.stateStore.save(status)
        }
    }

    @discardableResult
    public func installManagedCore() async throws -> CoreInstallResult {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let serviceClient = try self.serviceClientForMutation()
            let liveStatus = try self.status(using: serviceClient)
            guard ProfileActivationCoordinator.isStrictlyStopped(liveStatus) else {
                throw KumoError.commandFailed("Stop Kumo before installing or replacing the core executable.")
            }
            if let serviceClient {
                return try serviceClient.sendDecodable(
                    serviceClient.installCoreRequest(),
                    as: CoreInstallResult.self
                )
            }
            let result = try await self.coreInstaller.installLatestMihomo(
                destinationURL: self.privilegedCoreDestination
            )
            var status = try self.stateStore.load()
            status.corePath = result.path
            try self.stateStore.save(status)
            return result
        }
    }

    @_spi(KumoService)
    @discardableResult
    public func installManagedCoreFromService() async throws -> CoreInstallResult {
        let liveStatus = try supervisor.status()
        guard ProfileActivationCoordinator.isStrictlyStopped(liveStatus) else {
            throw KumoError.commandFailed("Stop Kumo before installing or replacing the Helper core executable.")
        }
        return try await coreInstaller.installLatestMihomo(
            destinationURL: privilegedCoreDestination
        )
    }

    @discardableResult
    func start(corePath: String? = nil) throws -> CoreStatus {
        let currentStatus = try normalizedStatusForLaunch()
        let profileID = try profileRepository.currentProfileIDValue()
        let profile = try profileRepository.loadDefaultProfile()
        let overrideYAMLs = try overrideRepository.activeYAMLs(for: profileID)
        return try supervisor.start(
            configuration: CoreLaunchConfiguration(
                corePath: corePath ?? currentStatus.corePath,
                profileID: profileID,
                profile: profile,
                overrideYAMLs: overrideYAMLs,
                endpoint: currentStatus.endpoint,
                proxyPorts: currentStatus.proxyPorts,
                mode: currentStatus.mode,
                runtimeSettings: runtimeSettings(for: currentStatus),
                systemProxySettings: currentStatus.systemProxySettings
            )
        )
    }

    @discardableResult
    func stop() throws -> CoreStatus {
        return try supervisor.stop()
    }

    /// Best-effort shutdown of the single selected runtime backend. The
    /// Helper/local decision is held by the same transaction as proxy disable
    /// and core stop; a failed Helper call is never reinterpreted as authority
    /// to mutate a second in-process supervisor.
    @discardableResult
    public func shutdownActiveRuntime() async -> ShutdownResult {
        do {
            return try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
                await self.shutdownActiveRuntimeWithoutGate()
            }
        } catch {
            return ShutdownResult(
                status: (try? stateStore.load()) ?? CoreStatus(),
                diagnostics: [formatDiagnostic(stage: "transaction", error: error)]
            )
        }
    }

    func restart(corePath: String? = nil) throws -> CoreStatus {
        let currentStatus = try normalizedStatusForLaunch()
        let profileID = try profileRepository.currentProfileIDValue()
        let profile = try profileRepository.loadDefaultProfile()
        let overrideYAMLs = try overrideRepository.activeYAMLs(for: profileID)
        return try supervisor.restart(
            configuration: CoreLaunchConfiguration(
                corePath: corePath ?? currentStatus.corePath,
                profileID: profileID,
                profile: profile,
                overrideYAMLs: overrideYAMLs,
                endpoint: currentStatus.endpoint,
                proxyPorts: currentStatus.proxyPorts,
                mode: currentStatus.mode,
                runtimeSettings: runtimeSettings(for: currentStatus),
                systemProxySettings: currentStatus.systemProxySettings
            )
        )
    }

    public func setMode(_ mode: OutboundMode) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.setModeWithoutGate(mode)
        }
    }

    private func setModeWithoutGate(_ mode: OutboundMode) async throws {
        let previousPersisted = try stateStore.load()
        if let client = try serviceClientForMutation() {
            let liveStatus = try status(using: client)
            if liveStatus.isStrictlyStoppedProcessState {
                var persisted = previousPersisted
                persisted.mode = mode
                try stateStore.save(persisted)
                return
            }
            guard let generation = liveStatus.runtimeGeneration else {
                throw KumoError.commandFailed(
                    "Kumo cannot change mode without an exact runtime generation."
                )
            }
            let expectation = RuntimeGenerationExpectation.matching(generation)
            let backend = try ServiceRuntimeBackend(
                client: client,
                serviceStatusProvider: { self.serviceManager.status() }
            )
            let serviceStatus = try await backend.apply(
                .setMode(mode),
                expecting: expectation
            ).status
            guard serviceStatus.mode == mode else {
                throw KumoError.commandFailed("Mihomo did not confirm the requested mode.")
            }
            do {
                var persisted = previousPersisted
                persisted.mode = mode
                try stateStore.save(persisted)
            } catch {
                do {
                    _ = try await backend.apply(
                        .setMode(previousPersisted.mode),
                        expecting: expectation
                    )
                    try stateStore.save(previousPersisted)
                } catch {
                    throw KumoError.commandFailed(
                        "The mode change failed, and Kumo could not restore the previous Helper mode."
                    )
                }
                throw error
            }
            return
        }

        let liveStatus = try supervisor.status()
        let client = MihomoControllerClient(endpoint: liveStatus.endpoint)
        let runtimeIsRunning = liveStatus.state == .running
        do {
            if runtimeIsRunning {
                try await client.setMode(mode)
                guard try await client.currentMode() == mode else {
                    throw KumoError.commandFailed("Mihomo did not confirm the requested mode.")
                }
            }
            var persisted = previousPersisted
            persisted.mode = mode
            try stateStore.save(persisted)
        } catch {
            let modeError = error
            do {
                if runtimeIsRunning {
                    try await client.setMode(previousPersisted.mode)
                    guard try await client.currentMode() == previousPersisted.mode else {
                        throw KumoError.commandFailed("Mihomo did not restore the previous mode.")
                    }
                }
                try stateStore.save(previousPersisted)
            } catch {
                throw KumoError.commandFailed(
                    "The mode change failed, and Kumo could not restore the previous mode."
                )
            }
            throw modeError
        }
    }

    @_spi(KumoService)
    public func setModeFromService(_ mode: OutboundMode) async throws {
        try await setModeWithoutGate(mode)
    }

    @_spi(KumoService)
    public func applyRuntimeMutationFromService(
        _ request: RuntimeMutationRequest
    ) async throws -> CoreStatus {
        _ = try request.expectedGeneration.requiredMatchingGeneration()
        let before = try supervisor.status()
        try request.expectedGeneration.validate(
            actualGeneration: before.runtimeGeneration
        )
        guard before.state == .running, before.readiness == .controllerReady else {
            throw KumoError.coreNotRunning
        }

        switch request.mutation {
        case .setMode(let mode):
            try await setModeWithoutGate(mode)
        default:
            try await MihomoControllerClient(endpoint: before.endpoint)
                .apply(request.mutation)
        }

        let after = try supervisor.status()
        try request.expectedGeneration.validate(
            actualGeneration: after.runtimeGeneration
        )
        return after
    }

    public func updateRuntimeSettings(_ settings: CoreRuntimeSettings) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.updateRuntimeSettingsWithoutGate(settings)
        }
    }

    private func updateRuntimeSettingsWithoutGate(_ settings: CoreRuntimeSettings) async throws {
        var previousPersistedStatus = try stateStore.load()
        let liveStatus = try status()
        let runtimeWasPresentOrAmbiguous = !liveStatus.isStrictlyStoppedProcessState
        let systemProxyWasEnabledForRuntime = runtimeWasPresentOrAmbiguous
            && liveStatus.systemProxyEnabled
        if !runtimeWasPresentOrAmbiguous, liveStatus.systemProxyEnabled {
            // A stopped runtime cannot safely back System Proxy. Repair this
            // stale state before changing ports so no new setting is committed
            // while macOS still points at an unowned listener.
            _ = try await setSystemProxyWithoutGate(false)
            previousPersistedStatus = try stateStore.load()
        }
        var nextPersistedStatus = previousPersistedStatus
        nextPersistedStatus.runtimeSettings = settings
        nextPersistedStatus.proxyPorts.mixedPort = settings.mixedPort
        try stateStore.save(nextPersistedStatus)

        do {
            if runtimeWasPresentOrAmbiguous {
                _ = try await restartAndWaitWithoutGate(corePath: nil)
            }
            if systemProxyWasEnabledForRuntime {
                _ = try await setSystemProxyWithoutGate(true)
            }
        } catch {
            let updateError = error
            do {
                try stateStore.save(previousPersistedStatus)
            } catch {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try await self.makeSystemProxySafeAfterRuntimeFailure()
                    }.value
                } catch {
                    throw KumoError.commandFailed(
                        "The runtime settings failed, the previous settings could not be persisted, and System Proxy could not be made safe."
                    )
                }
                throw KumoError.commandFailed(
                    "The runtime settings failed, and Kumo could not persist the previous settings."
                )
            }
            let observed = try? status()
            let oldRuntimeIsStillLive = observed?.state == .running
                && observed?.runtimeGeneration == liveStatus.runtimeGeneration
                && observed?.proxyPorts.mixedPort == liveStatus.proxyPorts.mixedPort
            if runtimeWasPresentOrAmbiguous, !oldRuntimeIsStillLive {
                do {
                    _ = try await restartAndWaitWithoutGate(corePath: nil)
                } catch {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try await self.makeSystemProxySafeAfterRuntimeFailure()
                        }.value
                    } catch {
                        throw KumoError.commandFailed(
                            "The runtime settings failed, the previous generation could not be restored, and System Proxy could not be made safe."
                        )
                    }
                    throw KumoError.commandFailed(
                        "The runtime settings failed, and Kumo could not restore the previous Mihomo generation."
                    )
                }
            }
            if systemProxyWasEnabledForRuntime {
                do {
                    _ = try await setSystemProxyWithoutGate(true)
                } catch {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try await self.makeSystemProxySafeAfterRuntimeFailure()
                        }.value
                    } catch {
                        throw KumoError.commandFailed(
                            "The runtime settings failed, and Kumo could not restore or safely disable System Proxy."
                        )
                    }
                    throw KumoError.commandFailed(
                        "The runtime settings failed, and Kumo could not restore the previous system proxy port."
                    )
                }
            }
            throw updateError
        }
    }

    public func setControllerSecret(_ secret: String) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let serviceClient = try self.serviceClientForMutation()
            let liveStatus = try self.status(using: serviceClient)
            guard ProfileActivationCoordinator.isStrictlyStopped(liveStatus) else {
                throw KumoError.commandFailed("Stop Kumo before changing the controller secret.")
            }
            var status = try self.stateStore.load()
            status.endpoint.secret = secret
            try self.stateStore.save(status)
        }
    }

    public func proxyGroups() async throws -> [ProxyGroup] {
        let status = try status()
        let groups = try await MihomoControllerClient(endpoint: status.endpoint).proxyGroups()
        guard let configuredGroupNames = configuredProxyGroupNamesForOrdering() else {
            return groups
        }
        return ProxyGroupOrdering.matchingConfiguration(groups, configuredGroupNames: configuredGroupNames)
    }

    public func coreConfiguration() async throws -> CoreConfigurationSnapshot {
        let status = try status()
        return try await MihomoControllerClient(endpoint: status.endpoint).configuration()
    }

    private func configuredProxyGroupNamesForOrdering() -> [String]? {
        if let runtimeYAML = try? String(contentsOf: paths.runtimeConfigFile, encoding: .utf8),
           let runtimeGroupNames = try? ProfileNodeParser.parseProxyGroupNames(yaml: runtimeYAML),
           !runtimeGroupNames.isEmpty {
            return runtimeGroupNames
        }

        guard let profile = try? profileRepository.loadDefaultProfile(),
              let profileGroupNames = try? ProfileNodeParser.parseProxyGroupNames(yaml: profile.rawYAML),
              !profileGroupNames.isEmpty else {
            return nil
        }
        return profileGroupNames
    }

    func waitForControllerReady(
        maxAttempts: Int = 30,
        intervalNanoseconds: UInt64 = 200_000_000,
        expectedProfileID: String? = nil
    ) async throws {
        let status = try supervisor.status()
        if status.state == .running,
           status.readiness == .controllerReady,
           status.configurationDigest != nil,
           expectedProfileID == nil || status.activeProfileID == expectedProfileID {
            return
        }
        guard let launchID = status.runtimeGeneration else {
            throw KumoError.coreNotRunning
        }
        let client = MihomoControllerClient(endpoint: status.endpoint)
        var lastError: Error?

        do {
            for _ in 0..<maxAttempts {
                do {
                    try Task.checkCancellation()
                    let record = try supervisor.verifyListenerOwnership(expectedLaunchID: launchID)
                    _ = try await client.version()
                    let configuration = try await client.configuration()
                    guard configuration.mixedPort == record.mixedPort else {
                        throw KumoError.commandFailed("Mihomo reported a different mixed proxy port than the launched configuration.")
                    }
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                    _ = try supervisor.verifyListenerOwnership(expectedLaunchID: launchID)
                    _ = try supervisor.markControllerReady(
                        expectedLaunchID: launchID,
                        message: "Mihomo controller and proxy listener are ready."
                    )
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CoreListenerVerificationError {
                    lastError = error
                    if case .unexpectedOwner = error {
                        break
                    }
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    lastError = error
                }
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        } catch is CancellationError {
            supervisor.failStartup(
                expectedLaunchID: launchID,
                message: "Mihomo startup was cancelled before readiness was confirmed."
            )
            throw CancellationError()
        }

        let message = "Mihomo did not take ownership of its controller and proxy ports."
        supervisor.failStartup(expectedLaunchID: launchID, message: message)
        throw lastError ?? KumoError.commandFailed(message)
    }

    public func rules() async throws -> [RuleEntry] {
        let status = try status()
        return try await MihomoControllerClient(endpoint: status.endpoint).rules()
    }

    public func setRuleEnabled(index: Int, isEnabled: Bool) async throws {
        _ = try await applyRuntimeMutationThroughAuthority(
            .setRuleEnabled(index: index, isEnabled: isEnabled)
        )
    }

    public func connections() async throws -> [ConnectionEntry] {
        let status = try status()
        return try await MihomoControllerClient(endpoint: status.endpoint).connections()
    }

    public func closeConnection(id: String) async throws {
        _ = try await applyRuntimeMutationThroughAuthority(.closeConnection(id: id))
    }

    public func closeConnections(matchingProxy proxy: String? = nil) async throws {
        _ = try await applyRuntimeMutationThroughAuthority(
            .closeConnections(matchingProxy: proxy)
        )
    }

    public func selectProxy(group: String, name: String) async throws {
        _ = try await applyRuntimeMutationThroughAuthority(
            .selectProxy(group: group, name: name)
        )
    }

    public func proxyProviders() async throws -> [ProxyProviderEntry] {
        let status = try status()
        return try await MihomoControllerClient(endpoint: status.endpoint).proxyProviders()
    }

    public func updateProxyProvider(name: String) async throws {
        _ = try await applyRuntimeMutationThroughAuthority(.updateProxyProvider(name: name))
    }

    public func ruleProviders() async throws -> [RuleProviderEntry] {
        let status = try status()
        return try await MihomoControllerClient(endpoint: status.endpoint).ruleProviders()
    }

    public func updateRuleProvider(name: String) async throws {
        _ = try await applyRuntimeMutationThroughAuthority(.updateRuleProvider(name: name))
    }

    public func upgradeGeoData() async throws {
        _ = try await applyRuntimeMutationThroughAuthority(.upgradeGeoData)
    }

    private func applyRuntimeMutationThroughAuthority(
        _ mutation: RuntimeMutation
    ) async throws -> CoreStatus {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let status = try self.status()
            guard status.state == .running,
                  status.readiness == .controllerReady,
                  let generation = status.runtimeGeneration else {
                throw KumoError.coreNotRunning
            }
            return try await self.runtimeBackendForMutation().apply(
                mutation,
                expecting: .matching(generation)
            ).status
        }
    }

    public func testProxyDelay(proxy: String, testURL: String? = nil) async throws -> Int? {
        let status = try status()
        return try await MihomoControllerClient(endpoint: status.endpoint).proxyDelay(proxy: proxy, testURL: testURL)
    }

    public func testGroupDelay(group: ProxyGroup) async throws -> [ProxyNode] {
        let status = try status()
        return try await MihomoControllerClient(endpoint: status.endpoint).groupDelay(group: group)
    }

    public func refreshProfile(from url: URL, useProxy: Bool = false) async throws -> ProfileSummary {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let proxyPort: Int?
            if useProxy {
                let status = try self.status()
                proxyPort = status.state == .running ? status.proxyPorts.mixedPort : nil
            } else {
                proxyPort = nil
            }
            return try await self.profileRepository.saveRemoteProfile(
                from: url,
                useProxy: useProxy,
                proxyPort: proxyPort,
                makeCurrent: false
            )
        }
    }

    public func importProfile(from url: URL) async throws -> ProfileSummary {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let profile = try await self.profileRepository.importLocalProfile(from: url)
            return try self.profileRepository.saveProfile(profile, makeCurrent: false)
        }
    }

    public func profileContent(id: String) throws -> String {
        try profileRepository.profileContent(id: id)
    }

    public func overrides() throws -> [OverrideItem] {
        try overrideRepository.listOverrides()
    }

    public func overrideContent(id: String) throws -> String {
        try overrideRepository.content(id: id)
    }

    @discardableResult
    func updateProfile(
        id: String,
        name: String,
        remoteURL: URL?,
        autoUpdate: Bool,
        useProxy: Bool,
        rawYAML: String
    ) throws -> ProfileSummary {
        try profileRepository.updateProfile(
            id: id,
            name: name,
            remoteURL: remoteURL,
            autoUpdate: autoUpdate,
            useProxy: useProxy,
            rawYAML: rawYAML
        )
    }

    @discardableResult
    func deleteProfile(id: String) throws -> Bool {
        try profileRepository.deleteProfile(id: id)
    }

    @discardableResult
    func refreshProfile(id: String) async throws -> ProfileSummary {
        if let profile = try profileRepository.listProfiles().first(where: { $0.id == id }),
           profile.isSubStoreManaged {
            return try await refreshSubStoreProfile(id: id)
        }
        let status = try status()
        let proxyPort = status.state == .running ? status.proxyPorts.mixedPort : nil
        return try await profileRepository.refreshRemoteProfile(id: id, proxyPort: proxyPort)
    }

    public func dueProfileIDs(now: Date = Date()) throws -> [String] {
        try profileRepository.dueRemoteProfileIDs(now: now)
    }

    public func recentLogs(limit: Int = 300) throws -> [LogEntry] {
        if let client = runningServiceClient() {
            return try client.sendDecodable(client.recentLogsRequest(limit: limit), as: [LogEntry].self)
        }
        return try supervisor.recentCoreLogLines(limit: limit).enumerated().map { index, message in
            return LogEntry(
                id: "\(index)-\(message.hashValue)",
                level: logLevel(in: message),
                message: message
            )
        }
    }

    public func logStream(level: String = "info") throws -> AsyncThrowingStream<LogEntry, Error> {
        let status = try status()
        return MihomoControllerClient(endpoint: status.endpoint).logStream(level: level)
    }

    public func trafficStream() throws -> AsyncThrowingStream<TrafficSnapshot, Error> {
        let status = try status()
        return MihomoControllerClient(endpoint: status.endpoint).trafficStream()
    }

    public func memoryStream() throws -> AsyncThrowingStream<MemorySnapshot, Error> {
        let status = try status()
        return MihomoControllerClient(endpoint: status.endpoint).memoryStream()
    }

    public func runtimeEvents(limit: Int = 200) throws -> [RuntimeEventEntry] {
        if let client = runningServiceClient() {
            return try client.sendDecodable(
                client.runtimeEventsRequest(limit: limit),
                as: [RuntimeEventEntry].self
            )
        }
        return try supervisor.recentRuntimeEvents(limit: limit)
    }

    @discardableResult
    public func setSystemProxy(_ isEnabled: Bool, dryRun: Bool = false) async throws -> [ShellCommand] {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.setSystemProxyWithoutGate(isEnabled, dryRun: dryRun)
        }
    }

    @discardableResult
    func setSystemProxyWithoutGate(_ isEnabled: Bool, dryRun: Bool = false) async throws -> [ShellCommand] {
        if dryRun {
            return try await setSystemProxyLocally(isEnabled, dryRun: true)
        }
        if let client = try serviceClientForMutation() {
            return try setSystemProxyThroughService(isEnabled, client: client)
        }
        return try await setSystemProxyLocally(isEnabled)
    }

    public func availableNetworkServices() throws -> [String] {
        try systemProxyController.availableNetworkServices()
    }

    public func activeNetworkService() throws -> String {
        try systemProxyController.activeNetworkService()
    }

    public func updateSystemProxySettings(_ settings: SystemProxySettings) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.updateSystemProxySettingsWithoutGate(settings)
        }
    }

    func updateSystemProxySettingsWithoutGate(_ settings: SystemProxySettings) async throws {
        let previousStatus = try stateStore.load()
        let liveStatus = try status()
        var nextStatus = previousStatus
        nextStatus.systemProxySettings = settings
        try stateStore.save(nextStatus)

        guard liveStatus.systemProxyEnabled else { return }
        do {
            _ = try await setSystemProxyWithoutGate(true)
        } catch {
            let updateError = error
            try stateStore.save(previousStatus)
            do {
                _ = try await setSystemProxyWithoutGate(true)
            } catch {
                throw KumoError.commandFailed(
                    "The system proxy settings failed, and Kumo could not restore the previous settings."
                )
            }
            throw updateError
        }
    }

    @_spi(KumoService)
    @discardableResult
    public func setSystemProxyFromService(
        _ isEnabled: Bool,
        settings: SystemProxySettings? = nil
    ) async throws -> [ShellCommand] {
        let previousStatus = try stateStore.load()
        if let settings {
            var status = previousStatus
            status.systemProxySettings = settings
            try stateStore.save(status)
        }
        do {
            return try await setSystemProxyWithoutGate(isEnabled)
        } catch {
            try stateStore.save(previousStatus)
            throw error
        }
    }

    @_spi(KumoService)
    @discardableResult
    public func enableSystemProxyFromService(
        _ request: RuntimeSystemProxyEnableRequest
    ) async throws -> [ShellCommand] {
        _ = try request.expectedGeneration.requiredMatchingGeneration()
        let before = try supervisor.status()
        try request.expectedGeneration.validate(
            actualGeneration: before.runtimeGeneration
        )
        return try await RuntimeSystemProxyEnableCoordinator.enable(
            operations: RuntimeSystemProxyEnableOperations(
                applySystemProxy: {
                    try await self.setSystemProxyFromService(
                        true,
                        settings: request.settings
                    )
                },
                validatePostApplyGeneration: {
                    let after = try self.supervisor.status()
                    try request.expectedGeneration.validate(
                        actualGeneration: after.runtimeGeneration
                    )
                },
                disableUsingRecoveryJournal: {
                    // The local controller durably stages `.completeDisable`
                    // before restoring macOS proxy settings.
                    _ = try await self.setSystemProxyLocally(false)
                },
                recoveredStatus: {
                    try self.stateStore.load()
                }
            )
        )
    }

    public func serviceModeStatus() -> ServiceModeStatus {
        resolvedServiceModeStatus()
    }

    @discardableResult
    public func installServiceMode() async throws -> ServiceModeStatus {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let serviceBefore = self.serviceManager.status()
            if self.legacyLocalRuntimeStatus() != nil {
                return try await LegacyRuntimeServiceMigrationCoordinator.migrate(
                    operations: LegacyRuntimeServiceMigrationOperations(
                        localRuntimeStatus: {
                            let persisted = try self.stateStore.load()
                            var observed = try self.supervisor.status()
                            observed.systemProxyEnabled = persisted.systemProxyEnabled
                            observed.systemProxySettings = persisted.systemProxySettings
                            observed.previousSystemProxySnapshot = persisted.previousSystemProxySnapshot
                            observed.appliedSystemProxySnapshot = persisted.appliedSystemProxySnapshot
                            observed.systemProxyRecoveryAction = persisted.systemProxyRecoveryAction
                            return observed
                        },
                        installHelper: {
                            let latest = self.serviceManager.status()
                            if latest.isInstalled, latest.isRunning, latest.isAvailable {
                                return latest
                            }
                            return try self.serviceManager.installService(
                                resetProxyRecovery: latest.isInstalled || latest.isRunning
                            )
                        },
                        prepareHelperTakeover: {
                            try await self.prepareLegacyHelperTakeover()
                        },
                        disableLocalSystemProxy: {
                            _ = try await self.setSystemProxyLocally(false)
                        },
                        enableLocalSystemProxy: {
                            _ = try await self.setSystemProxyLocally(true)
                        },
                        stopLocalRuntime: {
                            _ = try self.supervisor.stop()
                        },
                        activateSelectedProfile: {
                            try await self.activateSelectedProfileForLegacyMigration()
                        },
                        enableHelperSystemProxy: {
                            _ = try await self.setSystemProxyWithoutGate(true)
                        },
                        disableHelperSystemProxy: {
                            _ = try await self.setSystemProxyWithoutGate(false)
                        },
                        persistServiceStatus: { status in
                            self.persistServiceStatus(status)
                        }
                    )
                )
            }

            let currentClient = self.runningServiceClient()
            let helperStatus: CoreStatus?
            if serviceBefore.isRunning, let currentClient {
                helperStatus = try? self.status(using: currentClient)
            } else {
                helperStatus = nil
            }
            let requiresUnreachableRepair = serviceBefore.isInstalled
                && (!serviceBefore.isAvailable || helperStatus == nil)

            if requiresUnreachableRepair {
                return try await UnreachableServiceRepairCoordinator.repair(
                    operations: UnreachableServiceRepairOperations(
                        localRuntimeStatus: {
                            let persisted = try self.stateStore.load()
                            var observed = (try? self.supervisor.status()) ?? persisted
                            observed.systemProxyEnabled = persisted.systemProxyEnabled
                            observed.systemProxySettings = persisted.systemProxySettings
                            observed.previousSystemProxySnapshot = persisted.previousSystemProxySnapshot
                            observed.appliedSystemProxySnapshot = persisted.appliedSystemProxySnapshot
                            observed.systemProxyRecoveryAction = persisted.systemProxyRecoveryAction
                            return observed
                        },
                        disableLocalSystemProxy: {
                            let persisted = try self.stateStore.load()
                            _ = try await self.systemProxyController.setEnabled(
                                false,
                                configuration: self.fallbackSystemProxyConfiguration(for: persisted)
                            )
                        },
                        installResettingProxyRecovery: {
                            try self.serviceManager.installService(resetProxyRecovery: true)
                        },
                        activateSelectedProfile: {
                            let profileID = try self.profileRepository.currentProfileIDValue()
                            _ = try await self.activateProfileWithoutGate(
                                id: profileID,
                                policy: .ensureRunning,
                                forceReload: true
                            )
                        },
                        enableHelperSystemProxy: {
                            _ = try await self.setSystemProxyWithoutGate(true)
                        },
                        disableHelperSystemProxy: {
                            _ = try await self.setSystemProxyWithoutGate(false)
                        },
                        persistServiceStatus: { status in
                            self.persistServiceStatus(status)
                        }
                    )
                )
            }

            let liveStatus = try self.status(using: currentClient)
            guard ProfileActivationCoordinator.isStrictlyStopped(liveStatus),
                  !liveStatus.systemProxyEnabled else {
                throw KumoError.commandFailed(
                    "Stop Kumo and disable System Proxy before installing Kumo Helper."
                )
            }
            let status = try self.serviceManager.installService()
            guard status.isInstalled, status.isRunning, status.isAvailable else {
                throw KumoError.serviceUnavailable(
                    "Kumo Helper installation finished without a verified compatible Helper. Run Install / Repair Service again."
                )
            }
            self.persistServiceStatus(status)
            return status
        }
    }

    @discardableResult
    public func uninstallServiceMode() async throws -> ServiceModeStatus {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let currentClient = self.runningServiceClient()
            let liveStatus = try self.status(using: currentClient)
            guard ProfileActivationCoordinator.isStrictlyStopped(liveStatus),
                  !liveStatus.systemProxyEnabled else {
                throw KumoError.commandFailed(
                    "Stop Kumo and disable System Proxy before uninstalling Kumo Helper."
                )
            }
            let status = try self.serviceManager.uninstallService()
            guard !status.isInstalled, !status.isRunning else {
                throw KumoError.serviceUnavailable("Kumo Helper could not be fully uninstalled.")
            }
            self.persistServiceStatus(status)
            return status
        }
    }

    public func tunStatus() throws -> TunStatus {
        let status = try self.status()
        let service = resolvedServiceModeStatus()
        let settings = status.runtimeSettings?.tun ?? TunSettings()
        let logPermissionError = recentTunPermissionError()
        return TunStatus(
            isEnabled: settings.isEnabled,
            isRunning: status.state == .running && settings.isEnabled && service.canManageTun,
            requiresService: !service.canManageTun,
            lastError: status.tunStatus?.lastError ?? logPermissionError
        )
    }

    public func dnsSettings() throws -> DnsSettings {
        let status = try stateStore.load()
        return status.runtimeSettings?.dns ?? DnsSettings()
    }

    @discardableResult
    public func applyDnsSettings(_ settings: DnsSettings) async throws -> DnsSettings {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.applyDnsSettingsWithoutGate(settings)
        }
    }

    private func applyDnsSettingsWithoutGate(_ settings: DnsSettings) async throws -> DnsSettings {
        let normalizedSettings = normalizedDnsSettings(settings)
        let status = try stateStore.load()
        var runtimeSettings = self.runtimeSettings(for: status)
        runtimeSettings.dns = normalizedSettings
        try await updateRuntimeSettingsWithoutGate(runtimeSettings)

        return normalizedSettings
    }

    @discardableResult
    public func setDnsEnabled(_ isEnabled: Bool) async throws -> DnsSettings {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.setDnsEnabledWithoutGate(isEnabled)
        }
    }

    private func setDnsEnabledWithoutGate(_ isEnabled: Bool) async throws -> DnsSettings {
        let status = try stateStore.load()
        var runtimeSettings = self.runtimeSettings(for: status)
        var dns = runtimeSettings.dns ?? DnsSettings()
        dns.isEnabled = isEnabled
        runtimeSettings.dns = dns
        try await updateRuntimeSettingsWithoutGate(runtimeSettings)

        return dns
    }

    public func snifferSettings() throws -> SnifferSettings {
        let status = try stateStore.load()
        return status.runtimeSettings?.sniffer ?? SnifferSettings()
    }

    @discardableResult
    public func applySnifferSettings(_ settings: SnifferSettings) async throws -> SnifferSettings {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.applySnifferSettingsWithoutGate(settings)
        }
    }

    private func applySnifferSettingsWithoutGate(_ settings: SnifferSettings) async throws -> SnifferSettings {
        let normalizedSettings = normalizedSnifferSettings(settings)
        let status = try stateStore.load()
        var runtimeSettings = self.runtimeSettings(for: status)
        runtimeSettings.sniffer = normalizedSettings
        try await updateRuntimeSettingsWithoutGate(runtimeSettings)

        return normalizedSettings
    }

    @discardableResult
    public func setSnifferEnabled(_ isEnabled: Bool) async throws -> SnifferSettings {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.setSnifferEnabledWithoutGate(isEnabled)
        }
    }

    private func setSnifferEnabledWithoutGate(_ isEnabled: Bool) async throws -> SnifferSettings {
        let status = try stateStore.load()
        var runtimeSettings = self.runtimeSettings(for: status)
        var sniffer = runtimeSettings.sniffer ?? SnifferSettings()
        sniffer.isEnabled = isEnabled
        runtimeSettings.sniffer = sniffer
        try await updateRuntimeSettingsWithoutGate(runtimeSettings)

        return sniffer
    }

    @discardableResult
    public func applyTunSettings(_ settings: TunSettings) async throws -> TunStatus {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.applyTunSettingsWithoutGate(settings)
        }
    }

    private func applyTunSettingsWithoutGate(_ settings: TunSettings) async throws -> TunStatus {
        let status = try stateStore.load()
        let service = resolvedServiceModeStatus()
        var runtimeSettings = runtimeSettings(for: status)
        let normalizedSettings = normalizedTunSettings(settings)

        if normalizedSettings.isEnabled, !service.canManageTun {
            let message = service.message ?? "TUN requires the Kumo privileged helper."
            var failedStatus = status
            failedStatus.tunStatus = TunStatus(
                isEnabled: runtimeSettings.tun?.isEnabled ?? false,
                isRunning: false,
                requiresService: true,
                lastError: message
            )
            try stateStore.save(failedStatus)
            throw KumoError.serviceUnavailable(message)
        }

        runtimeSettings.tun = normalizedSettings
        try await updateRuntimeSettingsWithoutGate(runtimeSettings)

        return try tunStatus()
    }

    @discardableResult
    public func setTunEnabled(_ isEnabled: Bool) async throws -> TunStatus {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.setTunEnabledWithoutGate(isEnabled)
        }
    }

    private func setTunEnabledWithoutGate(_ isEnabled: Bool) async throws -> TunStatus {
        let status = try stateStore.load()
        let runtimeSettings = runtimeSettings(for: status)
        var tun = runtimeSettings.tun ?? TunSettings()
        tun.isEnabled = isEnabled
        return try await applyTunSettingsWithoutGate(tun)
    }

    public func subStoreStatus() throws -> SubStoreStatus {
        try subStoreManager.status()
    }

    public func updateSubStoreStatus(_ status: SubStoreStatus) throws {
        try subStoreManager.updateStatus(status)
    }

    @discardableResult
    public func prepareSubStoreResources() throws -> SubStoreStatus {
        try subStoreManager.prepareResources()
    }

    public func subStoreRuntimeStatus() async throws -> SubStoreRuntimeStatus {
        let status = try subStoreManager.status()
        let backendURL = subStoreManager.backendURL(for: status)
        return SubStoreRuntimeStatus(
            configuration: status,
            isBackendRunning: await subStoreSupervisor.isRunning,
            backendPID: await subStoreSupervisor.pid,
            backendURL: backendURL,
            resourceVersion: status.installedResourceVersion,
            resourcesInstalled: subStoreManager.resourcesInstalled()
        )
    }

    @discardableResult
    public func setSubStoreEnabled(_ isEnabled: Bool) async throws -> SubStoreStatus {
        var status = try subStoreManager.markEnabled(isEnabled)
        if isEnabled {
            status = try await startSubStoreServices(status: status)
        } else {
            await subStoreSupervisor.stop()
        }
        return status
    }

    public func restartSubStoreService() async throws {
        let status = try subStoreManager.status()
        _ = try await startSubStoreServices(status: status, restartBackend: true)
    }

    public func stopSubStoreService() async {
        await subStoreSupervisor.stop()
    }

    public func subStoreServiceIsRunning() async -> Bool {
        await subStoreSupervisor.isRunning
    }

    public func subStoreLaunchPlan() throws -> SubStoreLaunchPlan {
        try subStoreManager.launchPlan(for: subStoreManager.status(), mixedPort: try? status().proxyPorts.mixedPort)
    }

    @discardableResult
    public func downloadSubStoreBundle(kind: SubStoreBundleKind, from url: URL) async throws -> SubStoreStatus {
        throw KumoError.invalidArguments("Sub-Store resources are bundled with Kumo. Update Kumo to update Sub-Store.")
    }

    /// Returns a configured `SubStoreClient` pointing at whichever backend is
    /// currently active (bundled Node sidecar or custom backend URL). Raises
    /// when no backend is reachable so callers can surface a clear error.
    public func subStoreClient() throws -> SubStoreClient {
        guard let backendURL = subStoreManager.backendURL(for: try subStoreManager.status()) else {
            throw KumoError.invalidArguments("Sub-Store backend is not configured.")
        }
        return SubStoreClient(baseURL: backendURL)
    }

    public func subStoreSubscriptions() async throws -> [SubStoreSubscription] {
        try await subStoreClient().subscriptions()
    }

    public func subStoreCollections() async throws -> [SubStoreCollection] {
        try await subStoreClient().collections()
    }

    public func subStoreEntries(kind: SubStoreEntryKind) async throws -> [SubStoreEntry] {
        let client = try subStoreClient()
        switch kind {
        case .subscription:
            return try await client.subscriptions().map {
                SubStoreEntry(name: $0.name, displayName: $0.displayName, icon: $0.icon, tags: $0.tag ?? [], kind: .subscription)
            }
        case .collection:
            return try await client.collections().map {
                SubStoreEntry(name: $0.name, displayName: $0.displayName, icon: $0.icon, tags: [], kind: .collection)
            }
        }
    }

    @discardableResult
    public func importSubStoreProfile(path subStorePath: String, name: String? = nil, useProxy: Bool = false) async throws -> ProfileSummary {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let url = try self.subStoreProfileDownloadURL(path: subStorePath, useProxy: useProxy)
            return try await self.profileRepository.saveSubStoreProfile(
                name: name ?? self.subStoreDisplayName(for: subStorePath),
                subStorePath: subStorePath,
                downloadURL: url,
                useProxy: useProxy,
                makeCurrent: false
            )
        }
    }

    @discardableResult
    func refreshSubStoreProfile(id: String) async throws -> ProfileSummary {
        let profile = try profileRepository.listProfiles().first { $0.id == id }
        guard let profile, profile.isSubStoreManaged, let subStorePath = profile.subStorePath else {
            throw KumoError.invalidArguments("This profile is not managed by Sub-Store.")
        }
        let url = try subStoreProfileDownloadURL(path: subStorePath, useProxy: profile.useProxy)
        return try await profileRepository.saveSubStoreProfile(
            name: profile.name,
            subStorePath: subStorePath,
            downloadURL: url,
            autoUpdate: profile.autoUpdate,
            useProxy: profile.useProxy,
            preferredID: id,
            makeCurrent: false
        )
    }

    @discardableResult
    public func exportBackup(to destination: URL) async throws -> KumoBackupResult {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try self.backupManager.exportBackup(to: destination)
        }
    }

    @discardableResult
    public func importBackup(from source: URL) async throws -> KumoBackupManifest {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let liveStatus = try self.status()
            guard ProfileActivationCoordinator.isStrictlyStopped(liveStatus),
                  !liveStatus.systemProxyEnabled else {
                throw KumoError.commandFailed(
                    "Stop Kumo and disable System Proxy before importing a backup."
                )
            }

            let rollbackDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("KumoBackupRollback", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: rollbackDirectory) }
            _ = try self.backupManager.exportBackup(to: rollbackDirectory)

            do {
                let manifest = try self.backupManager.importBackup(from: source)
                var importedStatus = try self.stateStore.load()
                importedStatus.state = .stopped
                importedStatus.pid = nil
                importedStatus.systemProxyEnabled = false
                importedStatus.previousSystemProxySnapshot = nil
                importedStatus.appliedSystemProxySnapshot = nil
                importedStatus.systemProxyRecoveryAction = nil
                importedStatus.readiness = nil
                importedStatus.activeProfileID = nil
                importedStatus.runtimeGeneration = nil
                importedStatus.configurationDigest = nil
                importedStatus.message = "Backup imported. Start Kumo to activate the selected profile."
                if var tunStatus = importedStatus.tunStatus {
                    tunStatus.isRunning = false
                    importedStatus.tunStatus = tunStatus
                }
                try self.stateStore.save(importedStatus)

                let selectedID = try self.profileRepository.currentProfileIDValue()
                let profile = try await self.profileRepository.normalizedProfile(id: selectedID)
                _ = try RuntimeConfigBuilder(
                    endpoint: importedStatus.endpoint,
                    proxyPorts: importedStatus.proxyPorts,
                    mode: importedStatus.mode,
                    runtimeSettings: self.runtimeSettings(for: importedStatus)
                ).build(
                    profile: profile,
                    profileID: selectedID,
                    overrideYAMLs: try self.overrideRepository.activeYAMLs(for: selectedID)
                )
                return manifest
            } catch {
                do {
                    _ = try self.backupManager.importBackup(from: rollbackDirectory)
                } catch {
                    throw KumoError.commandFailed(
                        "The backup import failed, and Kumo could not restore the previous local data."
                    )
                }
                throw error
            }
        }
    }

    public func checkAppUpdate(
        manifestURL: URL?,
        currentVersion: String,
        channel: AppUpdateChannel = .stable
    ) async throws -> AppUpdateCheckResult {
        try await appUpdateManager.checkForUpdate(
            manifestURL: manifestURL,
            currentVersion: currentVersion,
            channel: channel
        )
    }

    public func downloadAppUpdate(
        manifest: AppUpdateManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppUpdateDownloadResult {
        try await appUpdateManager.downloadUpdate(
            manifest: manifest,
            to: paths.appUpdateDownloadsDirectory,
            progress: progress
        )
    }

    public func installAppUpdate(
        dmgURL: URL,
        currentAppURL: URL,
        expectedVersion: String,
        processID: Int32
    ) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let shutdown = await self.shutdownActiveRuntimeWithoutGate()
            let confirmedStatus: CoreStatus
            do {
                confirmedStatus = try self.status()
            } catch {
                throw KumoError.commandFailed(
                    "Kumo could not confirm that its runtime and System Proxy were safe for update installation."
                )
            }
            guard confirmedStatus.isStrictlyStoppedRuntime,
                  !confirmedStatus.systemProxyEnabled,
                  confirmedStatus.previousSystemProxySnapshot == nil,
                  confirmedStatus.appliedSystemProxySnapshot == nil,
                  confirmedStatus.systemProxyRecoveryAction == nil else {
                let diagnostics = shutdown.diagnostics.isEmpty
                    ? "Runtime shutdown was not confirmed."
                    : shutdown.diagnostics.joined(separator: " ")
                throw KumoError.commandFailed(
                    "Kumo refused to install the update because its runtime or System Proxy is still active. \(diagnostics)"
                )
            }
            try self.appUpdateInstaller.installDMG(
                dmgURL: dmgURL,
                currentAppURL: currentAppURL,
                expectedVersion: expectedVersion,
                processID: processID
            )
        }
    }

    public func userPreferences() -> UserPreferences {
        preferencesStore.load()
    }

    public func updateUserPreferences(_ preferences: UserPreferences) throws {
        try preferencesStore.save(preferences)
    }

    /// Reports the on-disk state of the `kumo` CLI symlink. Always cheap; the
    /// shipping app calls this on every onboarding refresh and in Settings.
    public func cliLinkStatus() -> CLILinkStatus {
        CLILinkInstaller().status()
    }

    /// Creates the `kumo` CLI symlink at the default PATH location. Surfaces a
    /// macOS administrator authorization prompt when the target directory
    /// requires elevated privileges (the default `/usr/local/bin` does).
    @discardableResult
    public func installCLILink() throws -> CLILinkStatus {
        try CLILinkInstaller().install()
    }

    /// Removes the `kumo` CLI symlink. Refuses to delete a symlink that is not
    /// managed by Kumo to avoid removing a user-installed CLI shim.
    @discardableResult
    public func uninstallCLILink() throws -> CLILinkStatus {
        try CLILinkInstaller().uninstall()
    }

}
