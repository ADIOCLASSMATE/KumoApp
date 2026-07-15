import Foundation
import os

extension KumoController {
    func runtimeBackendForMutation(
        corePath: String? = nil
    ) throws -> any RuntimeBackend {
        switch runtimeAuthority {
        case .serviceRequired:
            guard corePath == nil else {
                throw KumoError.invalidArguments(
                    "Custom Mihomo paths cannot be used by the production runtime. Kumo Helper only launches its protected managed core."
                )
            }
            if legacyLocalRuntimeStatus() != nil {
                throw KumoError.serviceUnavailable(
                    "Complete Kumo Helper migration before changing the runtime."
                )
            }
            return try ServiceRuntimeBackend(serviceManager: serviceManager)
        case .supervisor:
            return SupervisorRuntimeBackend(
                supervisor: supervisor,
                corePath: corePath
            )
        }
    }

    func shutdownActiveRuntimeWithoutGate() async -> ShutdownResult {
        var diagnostics: [String] = []
        let serviceClient: KumoServiceClient?
        do {
            serviceClient = try serviceClientForMutation()
        } catch {
            let backendError = error
            let serviceStatus = serviceManager.status()
            if canRetireLegacyLocalRuntime(serviceStatus: serviceStatus) {
                do {
                    let stopped = try await retireLegacyLocalRuntime()
                    return ShutdownResult(status: stopped)
                } catch {
                    diagnostics.append(
                        formatDiagnostic(stage: "legacy-local-cleanup", error: error)
                    )
                }
            }
            diagnostics.append(
                formatDiagnostic(stage: "runtime-backend", error: backendError)
            )
            var persisted = (try? stateStore.load()) ?? CoreStatus()
            if persisted.systemProxyEnabled {
                do {
                    let configuration = fallbackSystemProxyConfiguration(for: persisted)
                    _ = try systemProxyController.disableSynchronously(configuration: configuration)
                    persisted.systemProxyEnabled = false
                } catch {
                    diagnostics.append(formatDiagnostic(stage: "system-proxy-fallback", error: error))
                }
            }
            // An installed but unreachable Helper may still own a root Mihomo
            // child. Never treat that situation as permission to stop or start
            // a separate local supervisor.
            return ShutdownResult(status: persisted, diagnostics: diagnostics)
        }

        var latestStatus: CoreStatus
        do {
            latestStatus = try status(using: serviceClient)
        } catch {
            diagnostics.append(formatDiagnostic(stage: "status", error: error))
            latestStatus = (try? stateStore.load()) ?? CoreStatus()
        }

        var proxyIsSafeForCoreStop = !latestStatus.systemProxyEnabled
        if latestStatus.systemProxyEnabled {
            do {
                if let serviceClient {
                    _ = try setSystemProxyThroughService(false, client: serviceClient)
                } else {
                    _ = try await setSystemProxyLocally(false)
                }
                latestStatus.systemProxyEnabled = false
                proxyIsSafeForCoreStop = true
            } catch {
                diagnostics.append(formatDiagnostic(stage: "system-proxy", error: error))
                do {
                    let configuration = fallbackSystemProxyConfiguration(for: latestStatus)
                    _ = try systemProxyController.disableSynchronously(configuration: configuration)
                    latestStatus.systemProxyEnabled = false
                    proxyIsSafeForCoreStop = true
                } catch {
                    diagnostics.append(formatDiagnostic(stage: "system-proxy-fallback", error: error))
                }
            }
        }

        latestStatus = (try? status(using: serviceClient)) ?? latestStatus
        if !latestStatus.isStrictlyStoppedProcessState {
            if !proxyIsSafeForCoreStop {
                diagnostics.append(
                    "stop-skipped: Mihomo was left running because macOS System Proxy could not be safely restored or disabled."
                )
            } else {
                do {
                    latestStatus = try await stop(using: serviceClient)
                } catch {
                    diagnostics.append(formatDiagnostic(stage: "stop", error: error))
                }
            }
        }

        latestStatus = (try? status(using: serviceClient)) ?? latestStatus
        return ShutdownResult(status: latestStatus, diagnostics: diagnostics)
    }

    /// After a failed restart/rollback, System Proxy may only remain enabled
    /// when the selected profile's exact runtime generation still owns both
    /// listeners. Otherwise restore the user's original macOS proxy state (or
    /// at minimum disable Kumo's proxy) before surfacing the runtime error.
    func makeSystemProxySafeAfterRuntimeFailure() async throws {
        let persisted = try stateStore.load()
        let observed = try? status()
        guard persisted.systemProxyEnabled || observed?.systemProxyEnabled == true else {
            return
        }

        do {
            _ = try await setSystemProxyWithoutGate(true)
            return
        } catch {
            do {
                _ = try await setSystemProxyWithoutGate(false)
                return
            } catch {
                let configuration = fallbackSystemProxyConfiguration(for: persisted)
                do {
                    _ = try systemProxyController.disableSynchronously(configuration: configuration)
                } catch {
                    throw KumoError.commandFailed(
                        "The runtime failed, and Kumo could not restore or disable macOS System Proxy."
                    )
                }
            }
        }
    }

    func formatDiagnostic(stage: String, error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let line = "\(stage): \(message)"
        return line
    }

    func fallbackSystemProxyConfiguration(for status: CoreStatus) -> SystemProxyConfiguration {
        let storedSettings = status.systemProxySettings
        let stored = storedSettings?.networkService
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedService: String
        if let stored, !stored.isEmpty, stored != "Automatic" {
            resolvedService = stored
        } else if let active = try? systemProxyController.activeNetworkService(),
                  !active.isEmpty {
            resolvedService = active
        } else {
            resolvedService = "Wi-Fi"
        }
        return SystemProxyConfiguration(
            networkService: resolvedService,
            host: storedSettings?.host ?? status.endpoint.host,
            port: storedSettings?.port ?? status.proxyPorts.mixedPort,
            bypassList: storedSettings?.bypassList ?? SystemProxySettings.defaultBypassList,
            mode: storedSettings?.mode ?? .manual,
            pacScript: storedSettings?.pacScript ?? SystemProxySettings.defaultPACScript
        )
    }

    func logLevel(in message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("error") { return "error" }
        if lowercased.contains("warn") { return "warning" }
        if lowercased.contains("debug") { return "debug" }
        return "info"
    }

    func recentTunPermissionError() -> String? {
        guard let logs = try? recentLogs(limit: 80) else {
            return nil
        }
        let permissionError = "Start TUN listening error: configure tun interface: operation not permitted"
        return logs.last(where: { $0.message.contains(permissionError) }).map { _ in
            "TUN could not create the macOS network interface. Install or repair the privileged helper, then enable TUN again."
        }
    }

    func runtimeSettings(for status: CoreStatus) -> CoreRuntimeSettings {
        var settings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
        settings.mixedPort = status.proxyPorts.mixedPort
        return settings
    }

    func normalizedStatusForLaunch() throws -> CoreStatus {
        _ = try serviceClientForMutation()
        var status = try stateStore.load()
        let service = resolvedServiceModeStatus()
        status.serviceModeStatus = service
        if var runtimeSettings = status.runtimeSettings,
           var tun = runtimeSettings.tun,
           tun.isEnabled,
           !service.canManageTun {
            tun.isEnabled = false
            runtimeSettings.tun = tun
            status.runtimeSettings = runtimeSettings
            status.tunStatus = TunStatus(
                isEnabled: false,
                isRunning: false,
                requiresService: true,
                lastError: service.message
            )
            try stateStore.save(status)
        }
        return status
    }

    func effectiveSystemProxySettings(for status: CoreStatus) throws -> SystemProxySettings {
        let runtimePort = runtimeSettings(for: status).mixedPort
        var settings = status.systemProxySettings ?? SystemProxySettings(
            networkService: (try? systemProxyController.activeNetworkService()) ?? "Wi-Fi",
            host: status.endpoint.host,
            port: runtimePort
        )
        if settings.networkService.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || settings.networkService == "Automatic" {
            settings.networkService = try systemProxyController.activeNetworkService()
        }
        settings.port = runtimePort
        return settings
    }

    func persistServiceStatus(_ serviceStatus: ServiceModeStatus) {
        do {
            var status = try stateStore.load()
            status.serviceModeStatus = serviceStatus
            try stateStore.save(status)
        } catch {
            // Status refresh should not fail user-facing operations.
        }
    }

    @discardableResult
    func persistServiceRuntimeMirror(_ runtime: CoreStatus) throws -> CoreStatus {
        let persisted = try stateStore.load()
        var mirror = runtime
        // A custom local core path remains a local-mode preference. The Helper
        // always executes its protected managed core.
        mirror.corePath = persisted.corePath
        mirror.systemProxySettings = mergedSystemProxySettings(
            observed: runtime,
            persisted: persisted
        )
        mirror.serviceModeStatus = resolvedServiceModeStatus()
        try stateStore.save(mirror)
        return runtime
    }

    /// Returns the exact user-owned runtime left by pre-Helper releases. A
    /// Helper runtime mirrored into the App state file is not enough: the
    /// process must match this supervisor's user runtime layout.
    func legacyLocalRuntimeStatus() -> CoreStatus? {
        guard runtimeAuthority == .serviceRequired,
              (try? supervisor.hasOwnedRuntimeProcess()) == true,
              let observed = try? supervisor.status(),
              !observed.isStrictlyStoppedProcessState else {
            return nil
        }
        return observed
    }

    func serviceStatusBlockingPendingLegacyMigration(
        _ status: ServiceModeStatus
    ) -> ServiceModeStatus {
        guard (status.isInstalled || status.isRunning),
              legacyLocalRuntimeStatus() != nil else {
            return status
        }
        var blocked = status
        blocked.isAvailable = false
        blocked.message = "Complete Kumo Helper migration before starting or changing Mihomo."
        return blocked
    }

    /// Selects the runtime backend for a state-changing operation. Once the
    /// privileged Helper is installed, silently falling back to an in-process
    /// supervisor can leave two independent Mihomo processes alive. Mutations
    /// therefore fail closed until the installed Helper is reachable again.
    func serviceClientForMutation() throws -> KumoServiceClient? {
        guard runtimeAuthority == .serviceRequired else { return nil }
        let serviceStatus = serviceManager.status()
        guard serviceStatus.isInstalled || serviceStatus.isRunning else {
            throw KumoError.serviceUnavailable(
                "Install Kumo Helper before starting or changing the runtime."
            )
        }
        guard serviceStatus.isAvailable else {
            throw KumoError.serviceUnavailable(
                serviceStatus.message
                    ?? "Kumo Helper is not safe for runtime mutations. Repair the Helper before changing the runtime."
            )
        }
        guard legacyLocalRuntimeStatus() == nil else {
            throw KumoError.serviceUnavailable(
                "Complete Kumo Helper migration before starting or changing Mihomo."
            )
        }
        guard serviceStatus.isRunning,
              let client = serviceManager.serviceClient() else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper is installed but unreachable. Repair or uninstall the Helper before changing the runtime."
            )
        }
        _ = try client.compatibleHandshake()
        return client
    }

    /// The migration transaction is the only production path allowed to talk
    /// to Helper while a verified legacy local runtime still exists. Normal
    /// mutations remain blocked by `serviceClientForMutation()`.
    func serviceClientForLegacyMigration() throws -> KumoServiceClient {
        let serviceStatus = serviceManager.status()
        guard serviceStatus.isInstalled,
              serviceStatus.isRunning,
              serviceStatus.isAvailable,
              let client = serviceManager.serviceClient() else {
            throw KumoError.serviceUnavailable(
                serviceStatus.message
                    ?? "Kumo Helper is not ready to complete legacy runtime migration."
            )
        }
        _ = try client.compatibleHandshake()
        return client
    }

    func prepareLegacyHelperTakeover() async throws {
        let client = try serviceClientForLegacyMigration()
        try ensureServiceCoreAvailableForLegacyMigration(client: client)
        _ = try await legacyMigrationRuntimeSpec()
    }

    func activateSelectedProfileForLegacyMigration() async throws {
        let client = try serviceClientForLegacyMigration()
        try ensureServiceCoreAvailableForLegacyMigration(client: client)
        let (spec, desiredStatus) = try await legacyMigrationRuntimeSpec()
        let backend = try ServiceRuntimeBackend(
            client: client,
            serviceStatusProvider: { self.serviceManager.status() }
        )
        let before = try await backend.status().status
        let launched: CoreStatus
        if before.isStrictlyStoppedRuntime {
            launched = try await backend.start(
                spec,
                systemProxySettings: desiredStatus.systemProxySettings,
                expecting: .stopped
            ).status
        } else if let generation = before.runtimeGeneration {
            launched = try await backend.restart(
                spec,
                systemProxySettings: desiredStatus.systemProxySettings,
                expecting: .matching(generation)
            ).status
        } else {
            throw KumoError.commandFailed(
                "Kumo Helper runtime is ambiguous and cannot safely complete migration."
            )
        }
        _ = try launched.activationReceipt(
            expectedProfileID: spec.profileID,
            expectedConfigurationDigest: spec.configurationDigest
        )
        _ = try await MihomoControllerClient(endpoint: launched.endpoint).proxyGroups()
        _ = try persistServiceRuntimeMirror(launched)
    }

    private func ensureServiceCoreAvailableForLegacyMigration(
        client: KumoServiceClient
    ) throws {
        let candidates = try client.sendDecodable(
            client.coreCandidatesRequest(),
            as: [CoreCandidate].self
        )
        guard candidates.isEmpty else { return }
        _ = try client.sendDecodable(
            client.installCoreRequest(),
            as: CoreInstallResult.self
        )
    }

    private func legacyMigrationRuntimeSpec() async throws -> (RuntimeSpec, CoreStatus) {
        let profileID = try profileRepository.currentProfileIDValue()
        let profile = try await profileRepository.normalizedProfile(id: profileID)
        let desiredStatus = try stateStore.load()
        let overrideYAMLs = try overrideRepository.activeYAMLs(for: profileID)
        let settings = runtimeSettings(for: desiredStatus)
        let runtime = try RuntimeConfigBuilder(
            endpoint: desiredStatus.endpoint,
            proxyPorts: desiredStatus.proxyPorts,
            mode: desiredStatus.mode,
            runtimeSettings: settings,
            enforceManagedFeatureSettings: true
        ).build(
            profile: profile,
            profileID: profileID,
            overrideYAMLs: overrideYAMLs
        )
        return (
            RuntimeSpec(
                profileID: profileID,
                profileYAML: profile.rawYAML,
                overrideYAMLs: overrideYAMLs,
                endpoint: desiredStatus.endpoint,
                proxyPorts: desiredStatus.proxyPorts,
                mode: desiredStatus.mode,
                runtimeSettings: settings,
                configurationDigest: runtime.configurationDigest
            ),
            desiredStatus
        )
    }

    /// Production never starts or mutates a local runtime. The one permitted
    /// local operation is retiring a verified legacy runtime. Before Helper
    /// installation that is inherently safe; after a partial migration it is
    /// allowed only when the reachable Helper proves its own runtime stopped.
    func canRetireLegacyLocalRuntime(
        serviceStatus: ServiceModeStatus
    ) -> Bool {
        guard runtimeAuthority == .serviceRequired else {
            return false
        }
        if serviceStatus.installationHealth == .absent,
           !serviceStatus.isInstalled,
           !serviceStatus.isRunning {
            return true
        }
        guard serviceStatus.isAvailable,
              serviceStatus.isRunning,
              let client = serviceManager.serviceClient(),
              let helperStatus = try? status(using: client) else {
            return false
        }
        return Self.helperAllowsLegacyRuntimeRetirement(
            serviceStatus: serviceStatus,
            helperStatus: helperStatus
        )
    }

    static func helperAllowsLegacyRuntimeRetirement(
        serviceStatus: ServiceModeStatus,
        helperStatus: CoreStatus
    ) -> Bool {
        serviceStatus.isInstalled
            && serviceStatus.isRunning
            && serviceStatus.isAvailable
            && helperStatus.isStrictlyStoppedProcessState
    }

    func retireLegacyLocalRuntime(
        expecting requestedExpectation: RuntimeGenerationExpectation? = nil
    ) async throws -> CoreStatus {
        let serviceStatus = serviceManager.status()
        guard canRetireLegacyLocalRuntime(serviceStatus: serviceStatus) else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper may own the runtime. Complete or repair Helper migration before stopping it."
            )
        }

        var liveStatus = try supervisor.status()
        if let requestedExpectation {
            try requestedExpectation.validate(
                actualGeneration: liveStatus.runtimeGeneration
            )
        }
        if liveStatus.systemProxyEnabled {
            _ = try await setSystemProxyLocally(false)
            liveStatus = try supervisor.status()
        }
        if !liveStatus.isStrictlyStoppedProcessState {
            liveStatus = try supervisor.stop()
        }
        guard liveStatus.isStrictlyStoppedRuntime else {
            throw KumoError.commandFailed(
                "Kumo could not fully retire the legacy local runtime before Helper migration."
            )
        }
        return liveStatus
    }

    func status(using serviceClient: KumoServiceClient?) throws -> CoreStatus {
        guard let serviceClient else {
            return try supervisor.status()
        }
        var runtime = try serviceClient.sendDecodable(
            serviceClient.statusRequest(),
            as: CoreStatus.self
        )
        let persisted = try stateStore.load()
        if ProfileActivationCoordinator.isStrictlyStopped(runtime) {
            runtime.corePath = persisted.corePath
            runtime.mode = persisted.mode
            runtime.endpoint = persisted.endpoint
            runtime.proxyPorts = persisted.proxyPorts
            runtime.runtimeSettings = persisted.runtimeSettings
        }
        runtime.systemProxySettings = mergedSystemProxySettings(
            observed: runtime,
            persisted: persisted
        )
        return runtime
    }

    /// The Helper owns observed proxy state. User state is only a desired
    /// fallback after the Helper has confirmed that no runtime or proxy is
    /// active; it must never overwrite a live root-owned recovery journal.
    func mergedSystemProxySettings(
        observed: CoreStatus,
        persisted: CoreStatus
    ) -> SystemProxySettings? {
        guard observed.isStrictlyStoppedRuntime else {
            return observed.systemProxySettings
        }
        return observed.systemProxySettings ?? persisted.systemProxySettings
    }

    @discardableResult
    func setSystemProxyThroughService(
        _ isEnabled: Bool,
        client: KumoServiceClient
    ) throws -> [ShellCommand] {
        let persistedBefore = try stateStore.load()
        let helperBefore = try client.sendDecodable(
            client.systemProxyStatusRequest(),
            as: CoreStatus.self
        )
        if isEnabled {
            try validateRuntimeForSystemProxy(
                helperBefore,
                expectedProfileID: try profileRepository.currentProfileIDValue(),
                verifyListenerOwnership: false
            )
        }
        let settings = isEnabled
            ? try effectiveSystemProxySettings(for: persistedBefore)
            : nil
        let expectedGeneration: RuntimeGenerationExpectation?
        if isEnabled {
            guard let generation = helperBefore.runtimeGeneration else {
                throw KumoError.commandFailed(
                    "Kumo cannot enable System Proxy without an exact runtime generation."
                )
            }
            expectedGeneration = .matching(generation)
        } else {
            expectedGeneration = nil
        }
        let helperAfter = try client.sendDecodable(
            try client.setSystemProxyEnabledRequest(
                isEnabled,
                settings: settings,
                expectedGeneration: expectedGeneration
            ),
            as: CoreStatus.self
        )
        guard helperAfter.systemProxyEnabled == isEnabled else {
            throw KumoError.commandFailed("Kumo Helper did not confirm the requested system proxy state.")
        }
        do {
            var mirror = persistedBefore
            mirror.systemProxyEnabled = helperAfter.systemProxyEnabled
            mirror.systemProxySettings = settings ?? persistedBefore.systemProxySettings
            mirror.previousSystemProxySnapshot = helperAfter.previousSystemProxySnapshot
            mirror.appliedSystemProxySnapshot = helperAfter.appliedSystemProxySnapshot
            mirror.systemProxyRecoveryAction = helperAfter.systemProxyRecoveryAction
            try stateStore.save(mirror)
        } catch {
            do {
                let rollbackSettings = helperBefore.systemProxyEnabled
                    ? helperBefore.systemProxySettings ?? persistedBefore.systemProxySettings
                    : nil
                let rollbackExpectation = helperBefore.runtimeGeneration.map {
                    RuntimeGenerationExpectation.matching($0)
                }
                _ = try client.sendDecodable(
                    try client.setSystemProxyEnabledRequest(
                        helperBefore.systemProxyEnabled,
                        settings: rollbackSettings,
                        expectedGeneration: rollbackExpectation
                    ),
                    as: CoreStatus.self
                )
                try stateStore.save(persistedBefore)
            } catch {
                throw KumoError.commandFailed(
                    "The system proxy change failed, and Kumo could not restore the previous Helper state."
                )
            }
            throw error
        }
        return []
    }

    @discardableResult
    func setSystemProxyLocally(
        _ isEnabled: Bool,
        dryRun: Bool = false,
        expectedProfileID: String? = nil
    ) async throws -> [ShellCommand] {
        if isEnabled, !dryRun {
            let runtime = try supervisor.status()
            let verifiedProfileID: String?
            if let expectedProfileID {
                verifiedProfileID = expectedProfileID
            } else if privilegedRuntimeOwnership == nil {
                verifiedProfileID = try profileRepository.currentProfileIDValue()
            } else {
                verifiedProfileID = runtime.activeProfileID
            }
            try validateRuntimeForSystemProxy(
                runtime,
                expectedProfileID: verifiedProfileID,
                verifyListenerOwnership: true
            )
        }
        let status = try stateStore.load()
        let settings = try effectiveSystemProxySettings(for: status)
        return try await systemProxyController.setEnabled(
            isEnabled,
            configuration: SystemProxyConfiguration(
                networkService: settings.networkService,
                host: settings.host,
                port: settings.port,
                bypassList: settings.bypassList,
                mode: settings.mode,
                pacScript: settings.pacScript
            ),
            dryRun: dryRun
        )
    }

    func validateRuntimeForSystemProxy(
        _ runtime: CoreStatus,
        expectedProfileID: String?,
        verifyListenerOwnership: Bool
    ) throws {
        guard runtime.state == .running,
              runtime.readiness == .controllerReady,
              let generation = runtime.runtimeGeneration,
              let activeProfileID = runtime.activeProfileID,
              !activeProfileID.isEmpty,
              runtime.configurationDigest?.isEmpty == false,
              expectedProfileID == nil || activeProfileID == expectedProfileID else {
            throw KumoError.commandFailed(
                "System Proxy can only be enabled for the verified runtime generation of the selected profile."
            )
        }
        if verifyListenerOwnership {
            _ = try supervisor.verifyListenerOwnership(expectedLaunchID: generation)
        }
    }

    @discardableResult
    func stop(
        using serviceClient: KumoServiceClient?,
        expecting requestedExpectation: RuntimeGenerationExpectation? = nil
    ) async throws -> CoreStatus {
        let observed = try status(using: serviceClient)
        if observed.isStrictlyStoppedProcessState {
            return observed
        }
        let expectation: RuntimeGenerationExpectation
        if let requestedExpectation {
            expectation = requestedExpectation
        } else if let generation = observed.runtimeGeneration {
            expectation = .matching(generation)
        } else {
            throw KumoError.commandFailed(
                "Kumo cannot stop Mihomo without an exact runtime generation."
            )
        }
        let backend: any RuntimeBackend
        if let serviceClient {
            backend = try ServiceRuntimeBackend(
                client: serviceClient,
                serviceStatusProvider: { self.serviceManager.status() }
            )
        } else {
            backend = SupervisorRuntimeBackend(supervisor: supervisor)
        }
        let stopped = try await backend.stop(expecting: expectation).status
        return serviceClient == nil ? stopped : try persistServiceRuntimeMirror(stopped)
    }

    func resolvedServiceModeStatus() -> ServiceModeStatus {
        if let ownership = privilegedRuntimeOwnership {
            let socketPath = paths.privilegedServiceSocketFile(userID: ownership.userID).path
            return ServiceModeStatus(
                isInstalled: true,
                isRunning: true,
                isAvailable: true,
                isCurrentProcessPrivileged: true,
                socketPath: socketPath,
                message: "Kumo Helper is running."
            )
        }
        guard runtimeAuthority == .serviceRequired else {
            let isPrivileged = geteuid() == 0
            return ServiceModeStatus(
                isInstalled: false,
                isRunning: false,
                isAvailable: isPrivileged,
                isCurrentProcessPrivileged: isPrivileged,
                message: isPrivileged ? "Current process is privileged." : "Kumo Helper is unavailable."
            )
        }
        return serviceStatusBlockingPendingLegacyMigration(serviceManager.status())
    }

    func runningServiceClient() -> KumoServiceClient? {
        guard runtimeAuthority == .serviceRequired,
              let client = serviceManager.serviceClient(),
              serviceManager.status().isRunning else {
            return nil
        }
        return client
    }
}
