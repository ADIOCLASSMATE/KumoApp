import Darwin
import Foundation
import os

struct CoreLaunchConfiguration: Sendable {
    public var corePath: String?
    public var profileID: String?
    public var profile: Profile
    public var overrideYAMLs: [String]
    public var endpoint: ControllerEndpoint
    public var proxyPorts: ProxyPortConfiguration
    public var mode: OutboundMode
    public var runtimeSettings: CoreRuntimeSettings
    public var systemProxySettings: SystemProxySettings?
    public var expectedConfigurationDigest: String?

    public init(
        corePath: String? = nil,
        profileID: String? = nil,
        profile: Profile,
        overrideYAMLs: [String] = [],
        endpoint: ControllerEndpoint = ControllerEndpoint(),
        proxyPorts: ProxyPortConfiguration = ProxyPortConfiguration(),
        mode: OutboundMode = .rule,
        runtimeSettings: CoreRuntimeSettings = CoreRuntimeSettings(),
        systemProxySettings: SystemProxySettings? = nil,
        expectedConfigurationDigest: String? = nil
    ) {
        self.corePath = corePath
        self.profileID = profileID
        self.profile = profile
        self.overrideYAMLs = overrideYAMLs
        self.endpoint = endpoint
        self.proxyPorts = proxyPorts
        self.mode = mode
        self.runtimeSettings = runtimeSettings
        self.systemProxySettings = systemProxySettings
        self.expectedConfigurationDigest = expectedConfigurationDigest
    }
}

struct CoreSupervisor: Sendable {
    private let paths: KumoPaths
    private let runtimeLayout: CoreRuntimeLayout
    private let stateStore: CoreStateStore
    private let instanceStore: CoreInstanceStore
    private let lifecycleLock: CoreLifecycleLock
    private let processSystem: DarwinCoreProcessSystem
    private let stateFileOwnership: StateFileOwnership?

    private var instanceConfigurationsDirectory: URL {
        runtimeLayout.instancesDirectory
    }

    public init(paths: KumoPaths = KumoPaths(), stateFileOwnership: StateFileOwnership? = nil) {
        self.paths = paths
        self.runtimeLayout = CoreRuntimeLayout(paths: paths, ownership: stateFileOwnership)
        self.stateStore = CoreStateStore(paths: paths, ownership: stateFileOwnership)
        self.instanceStore = CoreInstanceStore(paths: paths, ownership: stateFileOwnership)
        self.lifecycleLock = CoreLifecycleLock(paths: paths, ownership: stateFileOwnership)
        self.processSystem = DarwinCoreProcessSystem()
        self.stateFileOwnership = stateFileOwnership
    }

    @discardableResult
    public func start(configuration: CoreLaunchConfiguration) throws -> CoreStatus {
        try lifecycleLock.withLock {
            try startUnlocked(configuration: configuration)
        }
    }

    @discardableResult
    func start(
        configuration: CoreLaunchConfiguration,
        expecting expectation: RuntimeGenerationExpectation
    ) throws -> CoreStatus {
        try lifecycleLock.withLock {
            try expectation.requireStoppedOperation()
            try expectation.validate(actualGeneration: statusUnlocked().runtimeGeneration)
            return try startUnlocked(configuration: configuration)
        }
    }

    @discardableResult
    public func restart(configuration: CoreLaunchConfiguration) throws -> CoreStatus {
        try lifecycleLock.withLock {
            try restartUnlocked(configuration: configuration)
        }
    }

    @discardableResult
    func restart(
        configuration: CoreLaunchConfiguration,
        expecting expectation: RuntimeGenerationExpectation
    ) throws -> CoreStatus {
        try lifecycleLock.withLock {
            _ = try expectation.requiredMatchingGeneration()
            try expectation.validate(actualGeneration: statusUnlocked().runtimeGeneration)
            return try restartUnlocked(configuration: configuration)
        }
    }

    @discardableResult
    public func stop() throws -> CoreStatus {
        try lifecycleLock.withLock {
            try stopUnlocked()
        }
    }

    @discardableResult
    func stop(expecting expectation: RuntimeGenerationExpectation) throws -> CoreStatus {
        try lifecycleLock.withLock {
            _ = try expectation.requiredMatchingGeneration()
            try expectation.validate(actualGeneration: statusUnlocked().runtimeGeneration)
            return try stopUnlocked()
        }
    }

    private func startUnlocked(configuration: CoreLaunchConfiguration) throws -> CoreStatus {
        let prepared = try prepareLaunch(configuration: configuration)
        do {
            try reconcileBeforeStart(corePath: prepared.corePath)
            return try launchPrepared(prepared)
        } catch {
            removeInstanceDirectory(launchID: prepared.launchID)
            throw error
        }
    }

    private func restartUnlocked(configuration: CoreLaunchConfiguration) throws -> CoreStatus {
        let prepared = try prepareLaunch(configuration: configuration)
        do {
            _ = try stopUnlocked()
            return try launchPrepared(prepared)
        } catch {
            removeInstanceDirectory(launchID: prepared.launchID)
            throw error
        }
    }

    private struct PreparedLaunch {
        var configuration: CoreLaunchConfiguration
        var corePath: String
        var executableIdentity: ExecutableFileIdentity
        var launchID: UUID
        var configURL: URL
        var runtime: RuntimeConfig
    }

    private struct ExecutableFileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
    }

    private func reconcileBeforeStart(corePath: String) throws {
        let currentStatus = try stateStore.load()
        let classifier = ownedProcessClassifier(status: currentStatus, extraCorePath: corePath)

        for pid in recordedPIDs(status: currentStatus) {
            if let snapshot = processSystem.inspect(pid: pid) {
                if classifier.classify(snapshot) == .owned {
                    throw KumoError.coreAlreadyRunning(pid)
                }
            } else if isProcessAlive(pid) {
                throw KumoError.commandFailed(
                    "Kumo cannot inspect the recorded Mihomo process \(pid); refusing to start another core."
                )
            }
        }
        if let record = try instanceStore.load() {
            if trustedOwnedSnapshot(for: record, status: currentStatus) != nil {
                throw KumoError.coreAlreadyRunning(record.processIdentity.pid)
            }
            if processSystem.inspect(pid: record.processIdentity.pid) == nil,
               isProcessAlive(record.processIdentity.pid) {
                throw KumoError.commandFailed(
                    "Kumo cannot inspect the recorded Mihomo instance; refusing to start another core."
                )
            }
        }

        let orphans = processSystem.inventory().filter { classifier.classify($0) == .owned }
        try terminateOwnedProcesses(orphans, context: "before starting Mihomo")
        try removeCorePIDFile()
        try instanceStore.clear()
    }

    private func prepareLaunch(configuration: CoreLaunchConfiguration) throws -> PreparedLaunch {
        try runtimeLayout.prepare(paths: paths)
        let corePath = try resolveCorePath(configuration.corePath)
        let executableIdentity = try executableFileIdentity(at: corePath)
        let launchID = UUID()
        try FileManager.default.createDirectory(
            at: instanceConfigurationsDirectory,
            withIntermediateDirectories: true
        )
        try protectInstanceDirectory(instanceConfigurationsDirectory)
        let instanceDirectory = instanceConfigurationsDirectory
            .appendingPathComponent(launchID.uuidString, isDirectory: true)
        let instanceConfigURL = instanceDirectory.appendingPathComponent("config.yaml")
        try FileManager.default.createDirectory(at: instanceDirectory, withIntermediateDirectories: true)
        try protectInstanceDirectory(instanceDirectory)

        do {
            let runtime = try RuntimeConfigBuilder(
                endpoint: configuration.endpoint,
                proxyPorts: configuration.proxyPorts,
                mode: configuration.mode,
                runtimeSettings: configuration.runtimeSettings,
                enforceManagedFeatureSettings: stateFileOwnership != nil
            ).write(
                profile: configuration.profile,
                profileID: configuration.profileID,
                overrideYAMLs: configuration.overrideYAMLs,
                to: instanceConfigURL
            )
            if let expectedDigest = configuration.expectedConfigurationDigest,
               runtime.configurationDigest != expectedDigest {
                throw KumoError.commandFailed(
                    "The generated runtime configuration did not match the requested configuration digest."
                )
            }
            try protectInstanceFile(instanceConfigURL)
            try validateStagedConfiguration(
                corePath: corePath,
                configURL: instanceConfigURL
            )
            return PreparedLaunch(
                configuration: configuration,
                corePath: corePath,
                executableIdentity: executableIdentity,
                launchID: launchID,
                configURL: instanceConfigURL,
                runtime: runtime
            )
        } catch {
            removeInstanceDirectory(launchID: launchID)
            throw error
        }
    }

    private func validateStagedConfiguration(corePath: String, configURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = [
            "-t",
            "-d", runtimeLayout.workDirectory.path,
            "-f", configURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw KumoError.commandFailed(
                "Kumo could not run Mihomo's configuration preflight: \(error.localizedDescription)"
            )
        }

        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminationDeadline {
                usleep(10_000)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw KumoError.commandFailed(
                "Mihomo's configuration preflight timed out before the running core was changed."
            )
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw KumoError.commandFailed(
                "Mihomo rejected the candidate runtime configuration before the running core was changed."
            )
        }
    }

    private func launchPrepared(_ prepared: PreparedLaunch) throws -> CoreStatus {
        let currentStatus = try stateStore.load()
        guard try executableFileIdentity(at: prepared.corePath) == prepared.executableIdentity else {
            throw KumoError.commandFailed("The Mihomo executable changed after launch preflight.")
        }
        try appendRuntimeEvent(kind: "core.starting", message: "Starting Mihomo core at \(prepared.corePath).")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: prepared.corePath)
        process.arguments = launchArguments(for: prepared.runtime, configURL: prepared.configURL)
        let logHandle: FileHandle
        do {
            logHandle = try logFileHandle()
        } catch {
            removeInstanceDirectory(launchID: prepared.launchID)
            try recordStartFailure(currentStatus: currentStatus, message: "Failed to open the Mihomo log safely.")
            throw error
        }
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            removeInstanceDirectory(launchID: prepared.launchID)
            try recordStartFailure(currentStatus: currentStatus, message: "Failed to start Mihomo core.")
            throw error
        }
        try? logHandle.close()

        let processID = Int32(process.processIdentifier)
        guard let identity = waitForProcessIdentity(pid: processID) else {
            process.terminate()
            process.waitUntilExit()
            removeInstanceDirectory(launchID: prepared.launchID)
            try recordStartFailure(currentStatus: currentStatus, message: "Mihomo process identity could not be verified.")
            throw KumoError.commandFailed("Mihomo process identity could not be verified.")
        }
        CoreLaunchedProcessRegistry.shared.register(process, identity: identity)

        let record = CoreInstanceRecord(
            launchID: prepared.launchID,
            processIdentity: identity,
            executablePath: prepared.corePath,
            workDirectoryPath: runtimeLayout.workDirectory.path,
            configPath: prepared.configURL.path,
            controllerHost: prepared.runtime.endpoint.host,
            controllerPort: prepared.runtime.endpoint.port,
            mixedPort: prepared.runtime.proxyPorts.mixedPort,
            profileID: prepared.configuration.profileID,
            configurationDigest: prepared.runtime.configurationDigest,
            startedAt: Date()
        )

        do {
            try writeCorePID(processID)
            try instanceStore.save(record)
            let status = CoreStatus(
                state: .starting,
                pid: processID,
                corePath: prepared.corePath,
                mode: prepared.configuration.mode,
                endpoint: prepared.runtime.endpoint,
                proxyPorts: prepared.runtime.proxyPorts,
                systemProxyEnabled: currentStatus.systemProxyEnabled,
                runtimeSettings: prepared.configuration.runtimeSettings,
                systemProxySettings: prepared.configuration.systemProxySettings
                    ?? currentStatus.systemProxySettings,
                previousSystemProxySnapshot: currentStatus.previousSystemProxySnapshot,
                appliedSystemProxySnapshot: currentStatus.appliedSystemProxySnapshot,
                systemProxyRecoveryAction: currentStatus.systemProxyRecoveryAction,
                serviceModeStatus: currentStatus.serviceModeStatus,
                tunStatus: currentStatus.tunStatus,
                readiness: .processLaunched,
                activeProfileID: currentStatus.activeProfileID,
                runtimeGeneration: prepared.launchID,
                configurationDigest: prepared.runtime.configurationDigest,
                message: "Mihomo core is starting."
            )
            try stateStore.save(status)
            try appendRuntimeEvent(kind: "core.started", message: "Mihomo core launched with pid \(processID).")
            return status
        } catch {
            _ = processSystem.terminate(expected: identity)
            try? removeCorePIDFile()
            try? instanceStore.clear()
            removeInstanceDirectory(launchID: prepared.launchID)
            try? recordStartFailure(currentStatus: currentStatus, message: "Failed to record Mihomo process state.")
            throw error
        }
    }

    private func stopUnlocked() throws -> CoreStatus {
        var status = try stateStore.load()
        let record = try instanceStore.load()
        let classifier = ownedProcessClassifier(status: status, extraCorePath: record?.executablePath)
        var owned = processSystem.inventory().filter { classifier.classify($0) == .owned }
        var seen = Set(owned.map(\.identity))

        for pid in recordedPIDs(status: status) {
            if let snapshot = waitForProcessSnapshot(pid: pid, timeout: 0.25) {
                if classifier.classify(snapshot) == .owned, seen.insert(snapshot.identity).inserted {
                    owned.append(snapshot)
                }
            } else if isProcessAlive(pid) {
                status.state = .failed
                status.message = "Kumo cannot inspect the recorded Mihomo process \(pid); refusing to signal an unverified PID."
                try stateStore.save(status)
                throw KumoError.commandFailed(status.message ?? "Mihomo process identity is unavailable.")
            }
        }

        if let record {
            let snapshot = waitForProcessSnapshot(
                pid: record.processIdentity.pid,
                timeout: 0.25
            )
            if let snapshot,
               snapshot.identity == record.processIdentity,
               isTrustedRecordStructure(record),
               seen.insert(snapshot.identity).inserted {
                owned.append(snapshot)
            } else if snapshot == nil, isProcessAlive(record.processIdentity.pid) {
                status.state = .failed
                status.message = "Kumo cannot inspect the tracked Mihomo instance; refusing to signal it."
                try stateStore.save(status)
                throw KumoError.commandFailed(status.message ?? "Mihomo process identity is unavailable.")
            }
        }

        try terminateOwnedProcesses(owned, context: "while stopping Mihomo")

        status.state = .stopped
        status.pid = nil
        status.readiness = nil
        status.activeProfileID = nil
        status.runtimeGeneration = nil
        status.configurationDigest = nil
        status.message = "Mihomo core stopped."
        try removeCorePIDFile()
        try instanceStore.clear()
        if let record {
            removeInstanceDirectoryIfTrusted(record)
        }
        try stateStore.save(status)
        try appendRuntimeEvent(kind: "core.stopped", message: "Mihomo core stopped.")
        return status
    }

    public func status() throws -> CoreStatus {
        try lifecycleLock.withLock {
            try statusUnlocked()
        }
    }

    private func statusUnlocked() throws -> CoreStatus {
        var status = try stateStore.load()
        let storedRecord = try instanceStore.load()
        if let record = storedRecord,
           trustedOwnedSnapshot(for: record, status: status) != nil {
            if let generation = status.runtimeGeneration, generation != record.launchID {
                status.state = .failed
                status.pid = record.processIdentity.pid
                status.readiness = nil
                status.message = "Mihomo instance state does not match the active launch generation."
                try stateStore.save(status)
                return status
            }
            if status.runtimeGeneration == nil {
                status.state = .starting
                status.pid = record.processIdentity.pid
                status.readiness = .processLaunched
                status.activeProfileID = record.profileID
                status.runtimeGeneration = record.launchID
                status.configurationDigest = record.configurationDigest
                status.message = "Recovered the tracked Mihomo process; verifying its listeners."
                try stateStore.save(status)
                return status
            }
            status.pid = record.processIdentity.pid
            if status.readiness == .controllerReady {
                guard status.activeProfileID == record.profileID,
                      status.runtimeGeneration == record.launchID,
                      status.configurationDigest == record.configurationDigest,
                      record.profileID?.isEmpty == false,
                      record.configurationDigest?.isEmpty == false else {
                    status.state = .failed
                    status.readiness = nil
                    status.activeProfileID = nil
                    status.configurationDigest = nil
                    status.message = "Mihomo runtime identity does not match its instance record."
                    try stateStore.save(status)
                    return status
                }
                do {
                    _ = try verifyListenerOwnershipUnlocked(
                        expectedLaunchID: record.launchID,
                        status: status
                    )
                    status.state = .running
                } catch {
                    status.state = .failed
                    status.readiness = nil
                    status.activeProfileID = nil
                    status.configurationDigest = nil
                    status.message = "Mihomo no longer owns its recorded controller and proxy ports."
                    try stateStore.save(status)
                }
            } else {
                status.state = .starting
                status.activeProfileID = record.profileID
                status.runtimeGeneration = record.launchID
                status.configurationDigest = record.configurationDigest
            }
            return status
        }

        if let record = storedRecord,
           processSystem.inspect(pid: record.processIdentity.pid) == nil,
           isProcessAlive(record.processIdentity.pid) {
            status.state = .failed
            status.pid = record.processIdentity.pid
            status.readiness = nil
            status.message = "Kumo cannot inspect the recorded Mihomo process; Helper verification is required."
            try stateStore.save(status)
            return status
        }

        let classifier = ownedProcessClassifier(status: status, extraCorePath: nil)
        let owned = processSystem.inventory().filter { classifier.classify($0) == .owned }
        if let legacy = owned.first(where: { recordedPIDs(status: status).contains($0.identity.pid) }) {
            let launchID = UUID()
            let record = CoreInstanceRecord(
                schemaVersion: 1,
                launchID: launchID,
                processIdentity: legacy.identity,
                executablePath: legacy.executablePath,
                workDirectoryPath: runtimeLayout.workDirectory.path,
                configPath: runtimeLayout.runtimeConfigFile.path,
                controllerHost: status.endpoint.host,
                controllerPort: status.endpoint.port,
                mixedPort: status.proxyPorts.mixedPort,
                profileID: status.activeProfileID,
                configurationDigest: nil,
                startedAt: Date()
            )
            try instanceStore.save(record)
            status.state = .starting
            status.pid = legacy.identity.pid
            status.readiness = .processLaunched
            status.runtimeGeneration = launchID
            status.message = "Recovered a legacy Kumo Mihomo process; verifying its listeners."
            try stateStore.save(status)
            try appendRuntimeEvent(kind: "core.pid_recovered", message: "Recovered Mihomo pid \(legacy.identity.pid).")
            return status
        }

        if !owned.isEmpty {
            status.state = .failed
            status.pid = nil
            status.readiness = nil
            status.message = "Kumo found untracked Mihomo processes. Stop or start Kumo to reconcile them safely."
            try stateStore.save(status)
            return status
        }

        let recorded = recordedPIDs(status: status)
        if let inaccessiblePID = recorded.first(where: {
            processSystem.inspect(pid: $0) == nil && isProcessAlive($0)
        }) {
            status.state = .failed
            status.pid = inaccessiblePID
            status.readiness = nil
            status.message = "Kumo cannot inspect the recorded Mihomo process \(inaccessiblePID); refusing to clear its state."
            try stateStore.save(status)
            return status
        }

        if !recorded.isEmpty || status.pid != nil {
            status.state = .stopped
            status.pid = nil
            status.readiness = nil
            status.activeProfileID = nil
            status.runtimeGeneration = nil
            status.configurationDigest = nil
            status.message = "Mihomo core is not running."
            try removeCorePIDFile()
            try instanceStore.clear()
            try stateStore.save(status)
            try appendRuntimeEvent(kind: "core.stale_pid", message: "Cleared stale Mihomo pid records.")
        }
        return status
    }

    func updateReadiness(_ readiness: CoreReadiness, message: String? = nil) throws -> CoreStatus {
        var status = try stateStore.load()
        status.readiness = readiness
        status.message = message ?? status.message
        try stateStore.save(status)
        try appendRuntimeEvent(kind: "core.readiness", message: message ?? "Core readiness changed to \(readiness.rawValue).")
        return status
    }

    func isRecordedProcessRunning() throws -> Bool {
        if let record = try instanceStore.load() {
            return processSystem.inspect(pid: record.processIdentity.pid)?.identity == record.processIdentity
        }
        let status = try stateStore.load()
        let classifier = ownedProcessClassifier(status: status, extraCorePath: nil)
        return recordedPIDs(status: status).contains { pid in
            guard let snapshot = processSystem.inspect(pid: pid) else { return false }
            return classifier.classify(snapshot) == .owned
        }
    }

    /// Reports only processes that match this supervisor's exact executable
    /// and user-owned runtime layout. Persisted App state may mirror a
    /// Helper-owned root process, so a recorded PID by itself is deliberately
    /// not evidence of a legacy local runtime.
    func hasOwnedRuntimeProcess() throws -> Bool {
        try lifecycleLock.withLock {
            let status = try stateStore.load()
            let record = try instanceStore.load()
            let classifier = ownedProcessClassifier(
                status: status,
                extraCorePath: record?.executablePath
            )

            if processSystem.inventory().contains(where: {
                classifier.classify($0) == .owned
            }) {
                return true
            }
            if let record,
               trustedOwnedSnapshot(for: record, status: status) != nil {
                return true
            }
            return recordedPIDs(status: status).contains { pid in
                guard let snapshot = waitForProcessSnapshot(pid: pid, timeout: 0.25) else {
                    return false
                }
                return classifier.classify(snapshot) == .owned
            }
        }
    }

    func currentInstanceRecord() throws -> CoreInstanceRecord? {
        try instanceStore.load()
    }

    func verifyListenerOwnership(expectedLaunchID: UUID) throws -> CoreInstanceRecord {
        try verifyListenerOwnershipUnlocked(
            expectedLaunchID: expectedLaunchID,
            status: stateStore.load()
        )
    }

    private func verifyListenerOwnershipUnlocked(
        expectedLaunchID: UUID,
        status: CoreStatus
    ) throws -> CoreInstanceRecord {
        guard let record = try instanceStore.load(), record.launchID == expectedLaunchID else {
            throw KumoError.commandFailed("Mihomo startup was superseded by another lifecycle operation.")
        }
        guard trustedOwnedSnapshot(for: record, status: status) != nil else {
            throw KumoError.coreNotRunning
        }
        let listeners = try processSystem.listenerSnapshot(
            ports: [record.controllerPort, record.mixedPort]
        )
        try CoreReadinessVerifier(
            controllerPort: record.controllerPort,
            mixedPort: record.mixedPort
        ).verify(expected: record.processIdentity, listeners: listeners)
        return record
    }

    @discardableResult
    func markControllerReady(
        expectedLaunchID: UUID,
        message: String
    ) throws -> CoreStatus {
        try lifecycleLock.withLock {
            let record = try verifyListenerOwnership(expectedLaunchID: expectedLaunchID)
            if trustedInstanceConfigURL(for: record) != nil {
                let data = try readInstanceConfiguration(record)
                try writeRuntimeProjection(data)
            }
            var status = try stateStore.load()
            guard status.runtimeGeneration == expectedLaunchID,
                  status.pid == record.processIdentity.pid,
                  let profileID = record.profileID,
                  !profileID.isEmpty,
                  let configurationDigest = record.configurationDigest,
                  !configurationDigest.isEmpty else {
                throw KumoError.commandFailed("Mihomo startup was superseded before readiness could be committed.")
            }
            status.state = .running
            status.readiness = .controllerReady
            status.activeProfileID = profileID
            status.configurationDigest = configurationDigest
            status.message = message
            try stateStore.save(status)
            try appendRuntimeEvent(kind: "core.readiness", message: message)
            return status
        }
    }

    func failStartup(expectedLaunchID: UUID, message: String) {
        do {
            try lifecycleLock.withLock {
                guard let record = try instanceStore.load(),
                      record.launchID == expectedLaunchID,
                      isTrustedRecordStructure(record) else { return }
                var status = try stateStore.load()
                guard status.runtimeGeneration == expectedLaunchID else { return }

                if let snapshot = processSystem.inspect(pid: record.processIdentity.pid),
                   snapshot.identity == record.processIdentity {
                    guard processSystem.terminate(expected: record.processIdentity) else {
                        status.state = .failed
                        status.pid = record.processIdentity.pid
                        status.readiness = nil
                        status.message = "\(message) Kumo could not stop the failed Mihomo process."
                        try stateStore.save(status)
                        try appendRuntimeEvent(kind: "core.stop_failed", message: status.message ?? message)
                        return
                    }
                } else if processSystem.inspect(pid: record.processIdentity.pid) == nil,
                          isProcessAlive(record.processIdentity.pid) {
                    status.state = .failed
                    status.pid = record.processIdentity.pid
                    status.readiness = nil
                    status.message = "\(message) Kumo could not verify the failed Mihomo process identity."
                    try stateStore.save(status)
                    try appendRuntimeEvent(kind: "core.stop_failed", message: status.message ?? message)
                    return
                }

                try removeCorePIDFile()
                try instanceStore.clear()
                removeInstanceDirectoryIfTrusted(record)
                status.state = .failed
                status.pid = nil
                status.readiness = nil
                status.activeProfileID = nil
                status.runtimeGeneration = nil
                status.configurationDigest = nil
                status.message = message
                try stateStore.save(status)
                try appendRuntimeEvent(kind: "core.failed", message: message)
            }
        } catch {
            // The original startup error remains the caller-visible failure. Any
            // cleanup failure deliberately leaves the instance record in place
            // so a later stop can reconcile it instead of creating an orphan.
        }
    }

    public func recentRuntimeEvents(limit: Int = 200) throws -> [RuntimeEventEntry] {
        guard FileManager.default.fileExists(atPath: runtimeLayout.runtimeEventsFile.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let content = try String(contentsOf: runtimeLayout.runtimeEventsFile, encoding: .utf8)
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .compactMap { line -> RuntimeEventEntry? in
                guard let data = String(line).data(using: .utf8) else {
                    return nil
                }
                return try? decoder.decode(RuntimeEventEntry.self, from: data)
            }
    }

    func recentCoreLogLines(limit: Int = 300) throws -> [String] {
        guard FileManager.default.fileExists(atPath: runtimeLayout.coreLogFile.path) else {
            return []
        }
        return try String(contentsOf: runtimeLayout.coreLogFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(max(0, min(limit, 2_000)))
            .map(String.init)
    }

    public func discoverCoreCandidates(configuredPath: String? = nil) -> [CoreCandidate] {
        if let stateFileOwnership {
            let protectedURL = paths.privilegedManagedCoreExecutable(userID: stateFileOwnership.userID)
            guard isTrustedPrivilegedCore(at: protectedURL) else { return [] }
            return [
                CoreCandidate(
                    name: protectedURL.lastPathComponent,
                    path: protectedURL.path,
                    sourceDescription: "Kumo Helper"
                )
            ]
        }

        let fileManager = FileManager.default
        let names = ["mihomo", "mihomo-alpha", "clash", "clash-meta"]
        var candidates: [CoreCandidate] = []
        var seen = Set<String>()

        func append(_ path: String?, source: String) {
            guard let path, !path.isEmpty else {
                return
            }
            guard fileManager.isExecutableFile(atPath: path), !seen.contains(path) else {
                return
            }
            seen.insert(path)
            candidates.append(
                CoreCandidate(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    path: path,
                    sourceDescription: source
                )
            )
        }

        append(configuredPath, source: "Selected")
        append(paths.managedCoreExecutable.path, source: "Managed")
        append(ProcessInfo.processInfo.environment["KUMO_MIHOMO_PATH"], source: "Environment")

        for name in names {
            append(Bundle.main.url(forResource: name, withExtension: nil)?.path, source: "Bundled")
        }

        for directory in searchDirectories() {
            for name in names {
                append(URL(fileURLWithPath: directory).appendingPathComponent(name).path, source: directory)
            }
            appendMatchingExecutables(in: directory, seen: &seen, candidates: &candidates)
        }

        return candidates
    }

    private func resolveCorePath(_ configuredPath: String?) throws -> String {
        if let stateFileOwnership {
            let protectedURL = paths.privilegedManagedCoreExecutable(userID: stateFileOwnership.userID)
            guard isTrustedPrivilegedCore(at: protectedURL) else {
                throw KumoError.coreNotFound(protectedURL.path)
            }
            return protectedURL.path
        }
        if let candidate = discoverCoreCandidates(configuredPath: configuredPath).first {
            return candidate.path
        }

        throw KumoError.coreNotFound(configuredPath ?? "mihomo")
    }

    private func executableFileIdentity(at path: String) throws -> ExecutableFileIdentity {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw KumoError.coreNotFound(path)
        }
        defer { close(descriptor) }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1,
              fileStatus.st_mode & mode_t(S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            throw KumoError.commandFailed("Kumo refused an unsafe Mihomo executable.")
        }
        return ExecutableFileIdentity(
            device: fileStatus.st_dev,
            inode: fileStatus.st_ino,
            size: fileStatus.st_size,
            modifiedSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec)
        )
    }

    private func isTrustedPrivilegedCore(at url: URL) -> Bool {
        let logger = Logger(subsystem: "io.kumo.KumoApp", category: "core-supervisor")
        logger.debug("isTrustedPrivilegedCore: checking \(url.path, privacy: .public)")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            logger.error("isTrustedPrivilegedCore: open failed errno=\(errno) path=\(url.path, privacy: .public)")
            return false
        }
        defer { close(descriptor) }
        var executableStatus = stat()
        guard fstat(descriptor, &executableStatus) == 0 else {
            logger.error("isTrustedPrivilegedCore: fstat failed errno=\(errno) path=\(url.path, privacy: .public)")
            return false
        }
        let isReg = executableStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        let uidMatch = executableStatus.st_uid == geteuid()
        let nlinkOne = executableStatus.st_nlink == 1
        let noGroupOtherWrite = executableStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        let isExec = executableStatus.st_mode & mode_t(S_IXUSR | S_IXGRP | S_IXOTH) != 0
        guard isReg, uidMatch, nlinkOne, noGroupOtherWrite, isExec else {
            logger.error("isTrustedPrivilegedCore: file check failed isReg=\(isReg) uid=\(executableStatus.st_uid) euid=\(geteuid()) nlink=\(executableStatus.st_nlink) noGroupOtherWrite=\(noGroupOtherWrite) isExec=\(isExec) mode=\(String(executableStatus.st_mode, radix: 8))")
            return false
        }

        let trustRoot = paths.privilegedServiceSupportDirectory.standardizedFileURL.path
        logger.debug("isTrustedPrivilegedCore: trustRoot=\(trustRoot, privacy: .public)")
        var directory = url.deletingLastPathComponent()
        while directory.standardizedFileURL.path == trustRoot
            || directory.standardizedFileURL.path.hasPrefix(trustRoot + "/") {
            let directoryDescriptor = open(
                directory.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directoryDescriptor >= 0 else {
                logger.error("isTrustedPrivilegedCore: open dir failed errno=\(errno) path=\(directory.path, privacy: .public)")
                return false
            }
            var directoryStatus = stat()
            let dirFstatOK = fstat(directoryDescriptor, &directoryStatus) == 0
            let dirUIDMatch = directoryStatus.st_uid == geteuid()
            let dirNoGroupOtherWrite = directoryStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
            let trusted = dirFstatOK && dirUIDMatch && dirNoGroupOtherWrite
            close(directoryDescriptor)
            guard trusted else {
                logger.error("isTrustedPrivilegedCore: dir check failed fstatOK=\(dirFstatOK) uid=\(directoryStatus.st_uid) euid=\(geteuid()) noGroupOtherWrite=\(dirNoGroupOtherWrite) mode=\(String(directoryStatus.st_mode, radix: 8)) path=\(directory.path, privacy: .public)")
                return false
            }
            if directory.standardizedFileURL.path == trustRoot { break }
            directory.deleteLastPathComponent()
        }
        let reached = directory.standardizedFileURL.path == trustRoot
        if !reached {
            logger.error("isTrustedPrivilegedCore: dir chain did not reach trustRoot last=\(directory.standardizedFileURL.path, privacy: .public) trustRoot=\(trustRoot, privacy: .public)")
        }
        return reached
    }

    private func launchArguments(for runtime: RuntimeConfig, configURL: URL) -> [String] {
        var arguments = [
            "-d",
            runtimeLayout.workDirectory.path,
            "-f",
            configURL.path,
            "-ext-ctl",
            "\(runtime.endpoint.host):\(runtime.endpoint.port)"
        ]

        if !runtime.endpoint.secret.isEmpty {
            arguments.append(contentsOf: ["-secret", runtime.endpoint.secret])
        }

        return arguments
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        let result = Darwin.kill(pid, 0)
        return Self.processExists(killResult: result, errorNumber: errno)
    }

    static func processExists(killResult: Int32, errorNumber: Int32) -> Bool {
        killResult == 0 || errorNumber == EPERM
    }

    private func trustedOwnedSnapshot(
        for record: CoreInstanceRecord,
        status: CoreStatus
    ) -> CoreProcessSnapshot? {
        guard isTrustedRecordStructure(record),
              let snapshot = waitForProcessSnapshot(
                pid: record.processIdentity.pid,
                timeout: 0.25
              ),
              snapshot.identity == record.processIdentity else {
            return nil
        }
        let classifier = ownedProcessClassifier(status: status, extraCorePath: record.executablePath)
        return classifier.classify(snapshot) == .owned ? snapshot : nil
    }

    private func waitForProcessSnapshot(
        pid: Int32,
        timeout: TimeInterval
    ) -> CoreProcessSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = processSystem.inspect(pid: pid) {
                return snapshot
            }
            usleep(10_000)
        }
        return processSystem.inspect(pid: pid)
    }

    private func isTrustedRecordStructure(_ record: CoreInstanceRecord) -> Bool {
        guard (1...2).contains(record.schemaVersion),
              record.processIdentity.pid > 0,
              (1...65_535).contains(record.controllerPort),
              (1...65_535).contains(record.mixedPort),
              standardizedPath(record.workDirectoryPath) == standardizedPath(runtimeLayout.workDirectory.path),
              !record.executablePath.isEmpty else {
            return false
        }
        let configPath = standardizedPath(record.configPath)
        return configPath == standardizedPath(runtimeLayout.runtimeConfigFile.path)
            || configPath == standardizedPath(expectedInstanceConfigURL(launchID: record.launchID).path)
    }

    private func expectedInstanceConfigURL(launchID: UUID) -> URL {
        instanceConfigurationsDirectory
            .appendingPathComponent(launchID.uuidString, isDirectory: true)
            .appendingPathComponent("config.yaml")
    }

    private func trustedInstanceConfigURL(for record: CoreInstanceRecord) -> URL? {
        guard isTrustedRecordStructure(record) else { return nil }
        let expected = expectedInstanceConfigURL(launchID: record.launchID)
        return standardizedPath(record.configPath) == standardizedPath(expected.path) ? expected : nil
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func readInstanceConfiguration(_ record: CoreInstanceRecord) throws -> Data {
        guard trustedInstanceConfigURL(for: record) != nil else {
            throw KumoError.serviceUnavailable("Kumo refused an untrusted Mihomo instance configuration path.")
        }
        let parentDescriptor = open(
            instanceConfigurationsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not open the Mihomo instances directory safely.")
        }
        defer { close(parentDescriptor) }

        let instanceName = record.launchID.uuidString
        let instanceDescriptor = openat(
            parentDescriptor,
            instanceName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard instanceDescriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not open the Mihomo instance directory safely.")
        }
        defer { close(instanceDescriptor) }

        let configDescriptor = openat(
            instanceDescriptor,
            "config.yaml",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard configDescriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not open the Mihomo instance configuration safely.")
        }
        defer { close(configDescriptor) }
        try validateRegularFile(configDescriptor)
        return try FileHandle(
            fileDescriptor: configDescriptor,
            closeOnDealloc: false
        ).readToEnd() ?? Data()
    }

    private func removeInstanceDirectoryIfTrusted(_ record: CoreInstanceRecord) {
        guard trustedInstanceConfigURL(for: record) != nil else { return }
        removeInstanceDirectory(launchID: record.launchID)
    }

    private func removeInstanceDirectory(launchID: UUID) {
        let parentDescriptor = open(
            instanceConfigurationsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { return }
        defer { close(parentDescriptor) }

        let instanceName = launchID.uuidString
        var itemStatus = stat()
        guard fstatat(parentDescriptor, instanceName, &itemStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            return
        }
        guard itemStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            _ = unlinkat(parentDescriptor, instanceName, 0)
            return
        }

        let instanceDescriptor = openat(
            parentDescriptor,
            instanceName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard instanceDescriptor >= 0 else { return }
        _ = unlinkat(instanceDescriptor, "config.yaml", 0)
        close(instanceDescriptor)
        _ = unlinkat(parentDescriptor, instanceName, AT_REMOVEDIR)
    }

    private func ownedProcessClassifier(
        status: CoreStatus,
        extraCorePath: String?
    ) -> CoreOwnedProcessClassifier {
        var pathsToTrust = Set(
            discoverCoreCandidates(configuredPath: status.corePath).map(\.path)
        )
        if let configuredPath = status.corePath, !configuredPath.isEmpty {
            pathsToTrust.insert(configuredPath)
        }
        if let extraCorePath {
            pathsToTrust.insert(extraCorePath)
        }
        pathsToTrust.insert(paths.managedCoreExecutable.path)
        var allowedUserIDs: Set<uid_t> = [0, getuid()]
        if let stateFileOwnership {
            allowedUserIDs.insert(stateFileOwnership.userID)
        }
        return CoreOwnedProcessClassifier(
            workDirectory: runtimeLayout.workDirectory.path,
            additionalWorkDirectories: Set(
                [runtimeLayout.legacyWorkDirectory?.path].compactMap { $0 }
            ),
            instanceConfigurationsDirectory: instanceConfigurationsDirectory.path,
            additionalInstanceConfigurationDirectories: Set(
                [runtimeLayout.legacyInstancesDirectory?.path].compactMap { $0 }
            ),
            allowedExecutablePaths: pathsToTrust,
            legacyExecutableNames: stateFileOwnership == nil
                ? []
                : ["mihomo", "mihomo-alpha", "clash", "clash-meta"],
            endpoint: status.endpoint,
            allowedUserIDs: allowedUserIDs
        )
    }

    private func terminateOwnedProcesses(
        _ processes: [CoreProcessSnapshot],
        context: String
    ) throws {
        let failed = processes.filter { !processSystem.terminate(expected: $0.identity) }
        guard failed.isEmpty else {
            let pids = failed.map { String($0.identity.pid) }.joined(separator: ", ")
            var status = try stateStore.load()
            status.state = .failed
            status.message = "Failed to stop Kumo-owned Mihomo process \(pids) \(context)."
            try stateStore.save(status)
            try appendRuntimeEvent(
                kind: "core.stop_failed",
                message: status.message ?? "Failed to stop Mihomo."
            )
            throw KumoError.commandFailed(status.message ?? "Failed to stop Mihomo.")
        }
    }

    private func waitForProcessIdentity(pid: Int32) -> CoreProcessIdentity? {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let identity = processSystem.inspect(pid: pid)?.identity {
                return identity
            }
            usleep(20_000)
        }
        return processSystem.inspect(pid: pid)?.identity
    }

    private func recordStartFailure(currentStatus: CoreStatus, message: String) throws {
        var failedStatus = currentStatus
        failedStatus.state = .failed
        failedStatus.pid = nil
        failedStatus.readiness = nil
        failedStatus.runtimeGeneration = nil
        failedStatus.configurationDigest = nil
        failedStatus.message = message
        try stateStore.save(failedStatus)
        try appendRuntimeEvent(kind: "core.failed", message: message)
    }

    private func recordedPIDs(status: CoreStatus) -> [Int32] {
        var result: [Int32] = []
        var seen = Set<Int32>()

        func append(_ pid: Int32?) {
            guard let pid, pid > 0, seen.insert(pid).inserted else {
                return
            }
            result.append(pid)
        }

        append(status.pid)
        append(readCorePID())
        return result
    }

    private func readCorePID() -> Int32? {
        guard let content = try? String(contentsOf: runtimeLayout.pidFile, encoding: .utf8) else {
            return nil
        }
        return Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func writeCorePID(_ pid: Int32) throws {
        try FileManager.default.createDirectory(at: runtimeLayout.pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: runtimeLayout.pidFile, options: .atomic)
        let descriptor = open(runtimeLayout.pidFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not open the Mihomo PID file safely.")
        }
        defer { close(descriptor) }
        try validateRegularFile(descriptor)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw KumoError.serviceUnavailable("Kumo could not set Mihomo PID file permissions.")
        }
        if stateFileOwnership != nil,
           fchown(descriptor, geteuid(), getegid()) != 0 {
            throw KumoError.serviceUnavailable("Kumo Helper could not protect the Mihomo PID file ownership.")
        }
    }

    private func removeCorePIDFile() throws {
        guard FileManager.default.fileExists(atPath: runtimeLayout.pidFile.path) else {
            return
        }
        try FileManager.default.removeItem(at: runtimeLayout.pidFile)
    }

    private func logFileHandle() throws -> FileHandle {
        try secureAppendFileHandle(at: runtimeLayout.coreLogFile)
    }

    private func appendRuntimeEvent(kind: String, message: String) throws {
        try FileManager.default.createDirectory(at: runtimeLayout.logsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(RuntimeEventEntry(kind: kind, message: message))
        var line = data
        line.append(0x0A)

        let handle = try secureAppendFileHandle(at: runtimeLayout.runtimeEventsFile)
        defer { try? handle.close() }
        try handle.write(contentsOf: line)
    }

    private func writeRuntimeProjection(_ data: Data) throws {
        try data.write(to: runtimeLayout.runtimeConfigFile, options: .atomic)
        let descriptor = open(
            runtimeLayout.runtimeConfigFile.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not protect the runtime configuration projection.")
        }
        defer { close(descriptor) }
        try validateRegularFile(descriptor)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw KumoError.serviceUnavailable("Kumo could not protect the runtime configuration projection.")
        }
        if stateFileOwnership != nil,
           fchown(descriptor, geteuid(), getegid()) != 0 {
            throw KumoError.serviceUnavailable("Kumo Helper could not own the runtime configuration projection.")
        }
    }

    private func protectInstanceDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not protect the Mihomo instance directory.")
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, S_IRWXU) == 0 else {
            throw KumoError.serviceUnavailable("Kumo could not set Mihomo instance directory permissions.")
        }
        if stateFileOwnership != nil,
           fchown(descriptor, geteuid(), getegid()) != 0 {
            throw KumoError.serviceUnavailable("Kumo Helper could not own the Mihomo instance directory.")
        }
    }

    private func protectInstanceFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not protect the Mihomo instance configuration.")
        }
        defer { close(descriptor) }
        try validateRegularFile(descriptor)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw KumoError.serviceUnavailable("Kumo could not set Mihomo instance configuration permissions.")
        }
        if stateFileOwnership != nil,
           fchown(descriptor, geteuid(), getegid()) != 0 {
            throw KumoError.serviceUnavailable("Kumo Helper could not own the Mihomo instance configuration.")
        }
    }

    private func secureAppendFileHandle(at url: URL) throws -> FileHandle {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not open a runtime log safely.")
        }
        do {
            try validateRegularFile(descriptor)
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw KumoError.serviceUnavailable("Kumo could not set runtime log permissions.")
            }
            if stateFileOwnership != nil,
               fchown(descriptor, geteuid(), getegid()) != 0 {
                throw KumoError.serviceUnavailable("Kumo Helper could not protect runtime log ownership.")
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateRegularFile(_ descriptor: Int32) throws {
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1 else {
            throw KumoError.serviceUnavailable("Kumo refused an unsafe runtime file.")
        }
    }

    private func searchDirectories() -> [String] {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.local/bin",
            "\(home)/bin"
        ]

        return Array(Set(pathDirectories + commonDirectories))
            .filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
            }
            .sorted()
    }

    private func appendMatchingExecutables(
        in directory: String,
        seen: inout Set<String>,
        candidates: inout [CoreCandidate]
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }

        for file in files where file.hasPrefix("mihomo") || file.hasPrefix("clash") {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(file).path
            guard FileManager.default.isExecutableFile(atPath: path), !seen.contains(path) else {
                continue
            }
            seen.insert(path)
            candidates.append(CoreCandidate(name: file, path: path, sourceDescription: directory))
        }
    }
}
