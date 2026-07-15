import Foundation
import Network

private final class ConnectionProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ value: Bool, connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        connection.cancel()
        continuation.resume(returning: value)
    }
}

public struct ShellCommand: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public struct SystemProxyCommandRunner: Sendable {
    public var run: @Sendable (ShellCommand) throws -> Void
    public var captureOutput: @Sendable (ShellCommand) throws -> String

    init(
        run: @escaping @Sendable (ShellCommand) throws -> Void,
        captureOutput: @escaping @Sendable (ShellCommand) throws -> String
    ) {
        self.run = run
        self.captureOutput = captureOutput
    }

    public static let live = SystemProxyCommandRunner(
        run: { command in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments

            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                throw KumoError.commandFailed(String(decoding: data, as: UTF8.self))
            }
        },
        captureOutput: { command in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = error.fileHandleForReading.readDataToEndOfFile()
                throw KumoError.commandFailed(String(decoding: data, as: UTF8.self))
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    )
}

public struct SystemProxyConfiguration: Codable, Equatable, Sendable {
    public var networkService: String
    public var host: String
    public var port: Int
    public var bypassList: [String]
    public var mode: SystemProxyMode
    public var pacScript: String

    public init(
        networkService: String = "Wi-Fi",
        host: String = "127.0.0.1",
        port: Int = 7890,
        bypassList: [String] = SystemProxySettings.defaultBypassList,
        mode: SystemProxyMode = .manual,
        pacScript: String = ""
    ) {
        self.networkService = networkService
        self.host = host
        self.port = port
        self.bypassList = bypassList
        self.mode = mode
        self.pacScript = pacScript
    }
}

public struct SystemProxyController: Sendable {
    private let stateStore: CoreStateStore
    private let pacServer: PACServer
    private let commandRunner: SystemProxyCommandRunner

    public init(
        paths: KumoPaths = KumoPaths(),
        commandRunner: SystemProxyCommandRunner = .live,
        stateFileOwnership: StateFileOwnership? = nil
    ) {
        self.stateStore = CoreStateStore(paths: paths, ownership: stateFileOwnership)
        self.pacServer = PACServer()
        self.commandRunner = commandRunner
    }

    public func availableNetworkServices() throws -> [String] {
        let output = try commandRunner.captureOutput(
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-listallnetworkservices"])
        )
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }
            .map { service in
                var normalized = service
                if normalized.hasPrefix("*") {
                    normalized.removeFirst()
                }
                return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    public func activeNetworkService() throws -> String {
        let routeOutput = try commandRunner.captureOutput(
            ShellCommand(executable: "/sbin/route", arguments: ["-n", "get", "default"])
        )
        guard let interface = routeOutput
            .split(separator: "\n")
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.hasPrefix("interface:") })?
            .split(separator: " ")
            .last
            .map(String.init) else {
            throw KumoError.commandFailed("Unable to determine active network interface.")
        }

        let orderOutput = try commandRunner.captureOutput(
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-listnetworkserviceorder"])
        )
        return try Self.networkService(in: orderOutput, matchingDevice: interface)
    }

    public static func networkService(in serviceOrderOutput: String, matchingDevice device: String) throws -> String {
        let blocks = serviceOrderOutput.components(separatedBy: "\n\n")
        guard let block = blocks.first(where: { $0.contains("Device: \(device)") }) else {
            throw KumoError.commandFailed("Unable to find a network service for interface \(device).")
        }

        for line in block.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("("), let closeIndex = trimmed.firstIndex(of: ")") else {
                continue
            }
            return String(trimmed[trimmed.index(after: closeIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw KumoError.commandFailed("Unable to parse network service for interface \(device).")
    }

    public func snapshot(networkService: String) throws -> SystemProxySnapshot {
        try SystemProxySnapshot(
            networkService: networkService,
            webProxy: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getwebproxy", networkService])
            ),
            secureWebProxy: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getsecurewebproxy", networkService])
            ),
            socksProxy: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getsocksfirewallproxy", networkService])
            ),
            bypassDomains: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getproxybypassdomains", networkService])
            ),
            autoProxy: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getautoproxyurl", networkService])
            )
        )
    }

    /// Manual proxy enable commands (web / secure web / socks + bypass).
    public func enableCommands(configuration: SystemProxyConfiguration) -> [ShellCommand] {
        var commands = [
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setwebproxy", configuration.networkService, configuration.host, "\(configuration.port)"]
            ),
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setsecurewebproxy", configuration.networkService, configuration.host, "\(configuration.port)"]
            ),
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setsocksfirewallproxy", configuration.networkService, configuration.host, "\(configuration.port)"]
            )
        ]
        if !configuration.bypassList.isEmpty {
            commands.append(
                ShellCommand(
                    executable: "/usr/sbin/networksetup",
                    arguments: ["-setproxybypassdomains", configuration.networkService] + configuration.bypassList
                )
            )
        }
        return commands
    }

    /// Disable manual web/secure/socks proxies. Used both when turning off
    /// system proxy entirely and when switching from manual to PAC.
    public func disableCommands(networkService: String = "Wi-Fi") -> [ShellCommand] {
        [
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-setwebproxystate", networkService, "off"]),
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-setsecurewebproxystate", networkService, "off"]),
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-setsocksfirewallproxystate", networkService, "off"])
        ]
    }

    /// PAC enable commands (set autoproxy URL + turn autoproxy state on).
    public func pacEnableCommands(networkService: String, pacURL: String) -> [ShellCommand] {
        [
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setautoproxyurl", networkService, pacURL]
            ),
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setautoproxystate", networkService, "on"]
            )
        ]
    }

    /// PAC disable commands (turn autoproxy state off).
    public func pacDisableCommands(networkService: String) -> [ShellCommand] {
        [
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setautoproxystate", networkService, "off"]
            )
        ]
    }

    /// Apply system proxy settings, branching on `configuration.mode`.
    /// PAC mode starts a local `PACServer` and points macOS at it via
    /// `-setautoproxyurl`; manual mode uses the legacy `-setwebproxy` family.
    /// In `dryRun` no PAC server is started and no commands are executed,
    /// but the would-be commands are returned for inspection.
    @discardableResult
    func setEnabled(
        _ isEnabled: Bool,
        configuration: SystemProxyConfiguration = SystemProxyConfiguration(),
        dryRun: Bool = false
    ) async throws -> [ShellCommand] {
        if dryRun {
            return plannedCommands(
                isEnabled: isEnabled,
                configuration: configuration,
                pacURL: "http://127.0.0.1:0/proxy.pac"
            )
        }

        let previousStatus = try stateStore.load()
        let previousSettings = previousStatus.systemProxySettings
        let previousService = previousSettings?.networkService ?? configuration.networkService
        let isServiceMigration = isEnabled
            && previousStatus.systemProxyEnabled
            && previousService != configuration.networkService
        let beforeTarget = try snapshot(networkService: configuration.networkService)
        let beforePreviousService = isServiceMigration
            ? try snapshot(networkService: previousService)
            : nil
        let beforeOriginalService: SystemProxySnapshot?
        if !isEnabled,
           let original = previousStatus.previousSystemProxySnapshot,
           original.networkService != configuration.networkService {
            beforeOriginalService = try snapshot(networkService: original.networkService)
        } else {
            beforeOriginalService = nil
        }
        if let previousSnapshot = previousStatus.previousSystemProxySnapshot {
            try Self.validateRestorableSnapshot(previousSnapshot)
        }
        if isEnabled {
            try Self.validateRestorableSnapshot(beforeTarget)
            if let beforePreviousService {
                try Self.validateRestorableSnapshot(beforePreviousService)
            }
        }
        let originalSnapshot: SystemProxySnapshot
        if isServiceMigration || !previousStatus.systemProxyEnabled {
            originalSnapshot = beforeTarget
        } else {
            originalSnapshot = previousStatus.previousSystemProxySnapshot ?? beforeTarget
        }
        let previousPACScript = previousStatus.systemProxyEnabled
            && previousSettings?.mode == .pac
            ? Self.renderPACScript(previousSettings?.pacScript ?? "", port: previousSettings?.port ?? configuration.port)
            : nil
        var commands: [ShellCommand] = []
        var pacURL: String?

        // Disabling without a committed Kumo ownership record must be a
        // no-op. Blindly running the generic "off" commands here would turn
        // off a proxy configured by the user or another application.
        if !isEnabled, !previousStatus.systemProxyEnabled {
            await pacServer.stop()
            return []
        }

        if previousStatus.systemProxyEnabled {
            if isServiceMigration {
                guard let beforePreviousService, let previousSettings else {
                    throw KumoError.commandFailed(
                        "Kumo cannot verify ownership of the previous network service before migrating System Proxy."
                    )
                }
                let previousConfiguration = SystemProxyConfiguration(
                    networkService: previousService,
                    host: previousSettings.host,
                    port: previousSettings.port,
                    bypassList: previousSettings.bypassList,
                    mode: previousSettings.mode,
                    pacScript: previousSettings.pacScript
                )
                try verifyKumoOwnership(
                    observed: beforePreviousService,
                    status: previousStatus,
                    configuration: previousConfiguration
                )
            } else if !isEnabled,
                      let snapshot = previousStatus.previousSystemProxySnapshot,
                      snapshot.networkService == configuration.networkService,
                      snapshotsHaveSameSettings(beforeTarget, snapshot) {
                // A previous disable reached macOS but crashed before its
                // final state commit. Finish the journal transition without
                // mutating the already-restored external configuration.
                var completed = previousStatus
                completed.systemProxyEnabled = false
                completed.previousSystemProxySnapshot = nil
                completed.appliedSystemProxySnapshot = nil
                completed.systemProxyRecoveryAction = nil
                try stateStore.save(completed)
                await pacServer.stop()
                return []
            } else {
                try verifyKumoOwnership(
                    observed: beforeTarget,
                    status: previousStatus,
                    configuration: configuration
                )
            }
        }

        if !isEnabled,
           let snapshot = previousStatus.previousSystemProxySnapshot,
           snapshot.networkService != configuration.networkService,
           let beforeOriginalService,
           !snapshotsHaveSameSettings(beforeOriginalService, snapshot) {
            throw KumoError.commandFailed(
                "System Proxy changed outside Kumo on \(snapshot.networkService). Kumo preserved the newer settings instead of overwriting them."
            )
        }

        if isEnabled {
            var pendingStatus = previousStatus
            pendingStatus.systemProxyEnabled = true
            var pendingSettings = SystemProxySettings(
                networkService: configuration.networkService,
                host: configuration.host,
                port: configuration.port,
                bypassList: configuration.bypassList
            )
            pendingSettings.mode = configuration.mode
            pendingSettings.pacScript = configuration.pacScript
            pendingStatus.systemProxySettings = pendingSettings
            pendingStatus.previousSystemProxySnapshot = originalSnapshot
            pendingStatus.appliedSystemProxySnapshot = nil
            try stateStore.stageSystemProxyJournal(pendingStatus)
        } else {
            try stateStore.stageSystemProxyDisableJournal(previousStatus)
        }

        do {
            if isServiceMigration {
                if let snapshot = previousStatus.previousSystemProxySnapshot,
                   snapshot.networkService == previousService {
                    try restore(snapshot)
                    try verifyRestored(snapshot)
                } else {
                    let cleanup = disableCommands(networkService: previousService)
                        + pacDisableCommands(networkService: previousService)
                    try cleanup.forEach(commandRunner.run)
                    try verifyAppliedState(
                        isEnabled: false,
                        configuration: SystemProxyConfiguration(networkService: previousService),
                        pacURL: nil
                    )
                }
            }

            if isEnabled {
                try await verifyTargetPort(configuration: configuration)
                if configuration.mode == .pac {
                    let port = try await pacServer.start(
                        script: Self.renderPACScript(configuration.pacScript, port: configuration.port)
                    )
                    pacURL = "http://127.0.0.1:\(port)/proxy.pac"
                }
                commands = plannedCommands(
                    isEnabled: true,
                    configuration: configuration,
                    pacURL: pacURL
                )
                try commands.forEach(commandRunner.run)
                try verifyAppliedState(isEnabled: true, configuration: configuration, pacURL: pacURL)
                if configuration.mode == .manual {
                    await pacServer.stop()
                }
            } else if let snapshot = previousStatus.previousSystemProxySnapshot {
                if snapshot.networkService != configuration.networkService {
                    let cleanup = disableCommands(networkService: configuration.networkService)
                        + pacDisableCommands(networkService: configuration.networkService)
                    try cleanup.forEach(commandRunner.run)
                    try verifyAppliedState(
                        isEnabled: false,
                        configuration: configuration,
                        pacURL: nil
                    )
                    commands += cleanup
                }
                commands += try restore(snapshot)
                try verifyRestored(snapshot)
                await pacServer.stop()
            } else {
                commands = plannedCommands(
                    isEnabled: false,
                    configuration: configuration,
                    pacURL: nil
                )
                try commands.forEach(commandRunner.run)
                try verifyAppliedState(isEnabled: false, configuration: configuration, pacURL: nil)
                await pacServer.stop()
            }

            let appliedSnapshot = isEnabled
                ? try snapshot(networkService: configuration.networkService)
                : nil
            var status = previousStatus
            status.systemProxyEnabled = isEnabled
            var settings = SystemProxySettings(
                networkService: configuration.networkService,
                host: configuration.host,
                port: configuration.port,
                bypassList: configuration.bypassList
            )
            settings.mode = configuration.mode
            settings.pacScript = configuration.pacScript
            status.systemProxySettings = settings
            status.previousSystemProxySnapshot = isEnabled ? originalSnapshot : nil
            status.appliedSystemProxySnapshot = appliedSnapshot
            status.systemProxyRecoveryAction = nil
            try stateStore.save(status)
        } catch {
            let applyError = error
            do {
                try restore(beforeTarget)
                if let beforePreviousService {
                    try restore(beforePreviousService)
                }
                if let beforeOriginalService {
                    try restore(beforeOriginalService)
                }
                if let previousPACScript, let previousSettings {
                    let port = try await pacServer.start(script: previousPACScript)
                    let recoveredPACURL = "http://127.0.0.1:\(port)/proxy.pac"
                    try pacEnableCommands(
                        networkService: previousService,
                        pacURL: recoveredPACURL
                    ).forEach(commandRunner.run)
                    var recoveredConfiguration = SystemProxyConfiguration(
                        networkService: previousService,
                        host: previousSettings.host,
                        port: previousSettings.port,
                        bypassList: previousSettings.bypassList,
                        mode: .pac,
                        pacScript: previousSettings.pacScript
                    )
                    recoveredConfiguration.mode = .pac
                    try verifyAppliedState(
                        isEnabled: true,
                        configuration: recoveredConfiguration,
                        pacURL: recoveredPACURL
                    )
                } else {
                    await pacServer.stop()
                }
                try stateStore.save(previousStatus)
            } catch {
                throw KumoError.commandFailed(
                    "System proxy update failed, and Kumo could not restore the previous macOS proxy settings."
                )
            }
            throw applyError
        }

        return commands
    }

    private func plannedCommands(
        isEnabled: Bool,
        configuration: SystemProxyConfiguration,
        pacURL: String?
    ) -> [ShellCommand] {
        guard isEnabled else {
            return disableCommands(networkService: configuration.networkService)
                + pacDisableCommands(networkService: configuration.networkService)
        }
        switch configuration.mode {
        case .manual:
            return enableCommands(configuration: configuration)
                + pacDisableCommands(networkService: configuration.networkService)
        case .pac:
            return disableCommands(networkService: configuration.networkService)
                + pacEnableCommands(
                    networkService: configuration.networkService,
                    pacURL: pacURL ?? "http://127.0.0.1:0/proxy.pac"
                )
        }
    }

    @discardableResult
    func disableSynchronously(configuration: SystemProxyConfiguration = SystemProxyConfiguration()) throws -> [ShellCommand] {
        let previousStatus = try stateStore.load()
        guard previousStatus.systemProxyEnabled else { return [] }
        let originalSnapshot = previousStatus.previousSystemProxySnapshot
        let beforeCurrent = try snapshot(networkService: configuration.networkService)
        let beforeOriginalService: SystemProxySnapshot?
        if let originalSnapshot,
           originalSnapshot.networkService != configuration.networkService {
            beforeOriginalService = try snapshot(networkService: originalSnapshot.networkService)
        } else {
            beforeOriginalService = nil
        }
        var commands: [ShellCommand] = []

        if let originalSnapshot {
            try Self.validateRestorableSnapshot(originalSnapshot)
        }

        if let originalSnapshot,
           originalSnapshot.networkService == configuration.networkService,
           snapshotsHaveSameSettings(beforeCurrent, originalSnapshot) {
            var completed = previousStatus
            completed.systemProxyEnabled = false
            completed.previousSystemProxySnapshot = nil
            completed.appliedSystemProxySnapshot = nil
            completed.systemProxyRecoveryAction = nil
            try stateStore.save(completed)
            return []
        }

        try verifyKumoOwnership(
            observed: beforeCurrent,
            status: previousStatus,
            configuration: configuration
        )
        if let originalSnapshot,
           let beforeOriginalService,
           !snapshotsHaveSameSettings(beforeOriginalService, originalSnapshot) {
            throw KumoError.commandFailed(
                "System Proxy changed outside Kumo on \(originalSnapshot.networkService). Kumo preserved the newer settings instead of overwriting them."
            )
        }
        try stateStore.stageSystemProxyDisableJournal(previousStatus)

        do {
            if let originalSnapshot {
                if originalSnapshot.networkService != configuration.networkService {
                    let cleanup = disableCommands(networkService: configuration.networkService)
                        + pacDisableCommands(networkService: configuration.networkService)
                    try cleanup.forEach(commandRunner.run)
                    try verifyAppliedState(
                        isEnabled: false,
                        configuration: configuration,
                        pacURL: nil
                    )
                    commands += cleanup
                }
                commands += try restore(originalSnapshot)
                try verifyRestored(originalSnapshot)
            } else {
                commands = disableCommands(networkService: configuration.networkService)
                    + pacDisableCommands(networkService: configuration.networkService)
                try commands.forEach(commandRunner.run)
                try verifyAppliedState(isEnabled: false, configuration: configuration, pacURL: nil)
            }

            var status = previousStatus
            status.systemProxyEnabled = false
            status.previousSystemProxySnapshot = nil
            status.appliedSystemProxySnapshot = nil
            status.systemProxyRecoveryAction = nil
            try stateStore.save(status)
            return commands
        } catch {
            do {
                try restore(beforeCurrent)
                if let beforeOriginalService {
                    try restore(beforeOriginalService)
                }
                try stateStore.save(previousStatus)
            } catch {
                throw KumoError.commandFailed(
                    "System proxy shutdown failed, and Kumo could not restore the previous macOS proxy settings."
                )
            }
            throw error
        }
    }

    public static func renderPACScript(_ script: String, port: Int) -> String {
        script.replacingOccurrences(of: "%mixed-port%", with: "\(port)")
    }

    @discardableResult
    private func restore(_ snapshot: SystemProxySnapshot) throws -> [ShellCommand] {
        try Self.validateRestorableSnapshot(snapshot)
        let service = snapshot.networkService
        var commands: [ShellCommand] = []
        commands += try restoreProxy(snapshot.webProxy, setCommand: "-setwebproxy", stateCommand: "-setwebproxystate", service: service)
        commands += try restoreProxy(snapshot.secureWebProxy, setCommand: "-setsecurewebproxy", stateCommand: "-setsecurewebproxystate", service: service)
        commands += try restoreProxy(snapshot.socksProxy, setCommand: "-setsocksfirewallproxy", stateCommand: "-setsocksfirewallproxystate", service: service)

        let bypass = snapshot.bypassDomains
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("aren't any bypass domains") }
        let bypassCommand = ShellCommand(
            executable: "/usr/sbin/networksetup",
            arguments: ["-setproxybypassdomains", service] + (bypass.isEmpty ? ["Empty"] : bypass)
        )
        try commandRunner.run(bypassCommand)
        commands.append(bypassCommand)

        let auto = parseProxyOutput(snapshot.autoProxy ?? "")
        if let url = auto["url"], !url.isEmpty {
            let urlCommand = ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setautoproxyurl", service, url]
            )
            try commandRunner.run(urlCommand)
            commands.append(urlCommand)
        }
        let stateCommand = ShellCommand(
            executable: "/usr/sbin/networksetup",
            arguments: [
                "-setautoproxystate",
                service,
                auto["enabled"]?.lowercased() == "yes" ? "on" : "off"
            ]
        )
        try commandRunner.run(stateCommand)
        commands.append(stateCommand)
        return commands
    }

    private func restoreProxy(
        _ output: String,
        setCommand: String,
        stateCommand: String,
        service: String
    ) throws -> [ShellCommand] {
        var commands: [ShellCommand] = []
        let fields = parseProxyOutput(output)
        if let server = fields["server"],
           let port = fields["port"],
           Int(port) != nil {
            let command = ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: [setCommand, service, server, port]
            )
            try commandRunner.run(command)
            commands.append(command)
        }
        let command = ShellCommand(
            executable: "/usr/sbin/networksetup",
            arguments: [
                stateCommand,
                service,
                fields["enabled"]?.lowercased() == "yes" ? "on" : "off"
            ]
        )
        try commandRunner.run(command)
        commands.append(command)
        return commands
    }

    private func parseProxyOutput(_ output: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line in
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            return (
                String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        })
    }

    static func validateRestorableSnapshot(_ snapshot: SystemProxySnapshot) throws {
        let outputs = [snapshot.webProxy, snapshot.secureWebProxy, snapshot.socksProxy]
        let containsAuthenticatedProxy = outputs.contains { output in
            let fields = output.split(separator: "\n").reduce(into: [String: String]()) { result, line in
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2 else { return }
                let key = String(pieces[0])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                result[key] = String(pieces[1])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            guard let value = fields["authenticated proxy enabled"] else { return false }
            return ["1", "yes", "true", "on"].contains(value)
        }
        guard !containsAuthenticatedProxy else {
            throw KumoError.commandFailed(
                "Kumo cannot safely replace this network service's authenticated proxy because macOS does not expose credentials for exact restoration. Disable that authenticated proxy first."
            )
        }
    }

    private func verifyKumoOwnership(
        observed: SystemProxySnapshot,
        status: CoreStatus,
        configuration: SystemProxyConfiguration
    ) throws {
        if let committed = status.appliedSystemProxySnapshot,
           committed.networkService == observed.networkService,
           snapshotsHaveSameSettings(observed, committed) {
            return
        }

        // Backward-compatible adoption for state written before Kumo stored
        // the exact applied snapshot. Adoption is deliberately strict and is
        // only allowed when every observable field matches Kumo's settings.
        if status.appliedSystemProxySnapshot == nil,
           snapshotMatchesConfiguration(observed, configuration: configuration) {
            return
        }

        throw KumoError.commandFailed(
            "System Proxy changed outside Kumo on \(observed.networkService). Kumo preserved the newer settings instead of overwriting them."
        )
    }

    private func snapshotsHaveSameSettings(
        _ lhs: SystemProxySnapshot,
        _ rhs: SystemProxySnapshot
    ) -> Bool {
        guard lhs.networkService == rhs.networkService else { return false }
        return normalizedProxyFields(lhs.webProxy) == normalizedProxyFields(rhs.webProxy)
            && normalizedProxyFields(lhs.secureWebProxy) == normalizedProxyFields(rhs.secureWebProxy)
            && normalizedProxyFields(lhs.socksProxy) == normalizedProxyFields(rhs.socksProxy)
            && normalizedBypassDomains(lhs.bypassDomains) == normalizedBypassDomains(rhs.bypassDomains)
            && normalizedAutoProxyFields(lhs.autoProxy) == normalizedAutoProxyFields(rhs.autoProxy)
    }

    private func snapshotMatchesConfiguration(
        _ snapshot: SystemProxySnapshot,
        configuration: SystemProxyConfiguration
    ) -> Bool {
        guard snapshot.networkService == configuration.networkService else { return false }
        let web = normalizedProxyFields(snapshot.webProxy)
        let secure = normalizedProxyFields(snapshot.secureWebProxy)
        let socks = normalizedProxyFields(snapshot.socksProxy)
        let auto = normalizedProxyFields(snapshot.autoProxy ?? "")
        let manual = [web, secure, socks]

        switch configuration.mode {
        case .manual:
            let expectedHost = configuration.host.lowercased()
            let expectedPort = String(configuration.port)
            guard manual.allSatisfy({ fields in
                fields["enabled"] == "yes"
                    && fields["server"]?.lowercased() == expectedHost
                    && fields["port"] == expectedPort
            }), auto["enabled"] == "no" else {
                return false
            }
            return normalizedBypassDomains(snapshot.bypassDomains)
                == Set(configuration.bypassList.map { $0.lowercased() })
        case .pac:
            guard manual.allSatisfy({ $0["enabled"] == "no" }),
                  auto["enabled"] == "yes",
                  let rawURL = auto["url"],
                  let url = URL(string: rawURL),
                  url.scheme?.lowercased() == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? ""),
                  url.port != nil,
                  url.path == "/proxy.pac" else {
                return false
            }
            return true
        }
    }

    private func normalizedProxyFields(_ output: String) -> [String: String] {
        parseProxyOutput(output).reduce(into: [String: String]()) { result, entry in
            let key = entry.key.lowercased()
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = key == "url" ? value : value.lowercased()
        }
    }

    private func normalizedAutoProxyFields(_ output: String?) -> [String: String] {
        var fields = parseProxyOutput(output ?? "")
        let isEnabled = ["1", "yes", "true", "on"].contains(
            fields["enabled"]?.lowercased() ?? ""
        )
        guard isEnabled else {
            return ["enabled": "no"]
        }
        fields["enabled"] = "yes"
        if fields["url"]?.isEmpty == true || fields["url"] == "(null)" {
            fields.removeValue(forKey: "url")
        }
        return fields
    }

    private func normalizedBypassDomains(_ output: String) -> Set<String> {
        Set(output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter {
                !$0.isEmpty
                    && !$0.contains("aren't any bypass domains")
                    && $0 != "empty"
            })
    }

    private func verifyRestored(_ expected: SystemProxySnapshot) throws {
        let observed = try snapshot(networkService: expected.networkService)
        func normalized(_ value: String?) -> String {
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard normalized(observed.webProxy) == normalized(expected.webProxy),
              normalized(observed.secureWebProxy) == normalized(expected.secureWebProxy),
              normalized(observed.socksProxy) == normalized(expected.socksProxy),
              normalized(observed.bypassDomains) == normalized(expected.bypassDomains),
              normalizedAutoProxyFields(observed.autoProxy) == normalizedAutoProxyFields(expected.autoProxy) else {
            throw KumoError.commandFailed("macOS did not restore the previous proxy snapshot.")
        }
    }

    private func verifyTargetPort(configuration: SystemProxyConfiguration) async throws {
        guard configuration.port > 0 else {
            throw KumoError.commandFailed("System proxy port must be greater than zero.")
        }
        let canConnect = await canConnect(to: configuration.host, port: configuration.port)
        guard canConnect else {
            throw KumoError.commandFailed("System proxy target \(configuration.host):\(configuration.port) is not accepting connections.")
        }
    }

    private func verifyAppliedState(isEnabled: Bool, configuration: SystemProxyConfiguration, pacURL: String?) throws {
        let webProxy = try commandRunner.captureOutput(
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getwebproxy", configuration.networkService])
        )
        let secureWebProxy = try commandRunner.captureOutput(
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getsecurewebproxy", configuration.networkService])
        )
        let socksProxy = try commandRunner.captureOutput(
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getsocksfirewallproxy", configuration.networkService])
        )
        let autoProxy = try commandRunner.captureOutput(
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getautoproxyurl", configuration.networkService])
        )

        if !isEnabled {
            guard [webProxy, secureWebProxy, socksProxy, autoProxy].allSatisfy({ $0.contains("Enabled: No") }) else {
                throw KumoError.commandFailed("macOS did not disable every Kumo-managed proxy setting for \(configuration.networkService).")
            }
            return
        }

        switch configuration.mode {
        case .manual:
            let expected = [webProxy, secureWebProxy, socksProxy]
            guard expected.allSatisfy({ output in
                output.contains("Enabled: Yes")
                    && output.contains("Server: \(configuration.host)")
                    && output.contains("Port: \(configuration.port)")
            }) else {
                throw KumoError.commandFailed("macOS did not apply manual proxy \(configuration.host):\(configuration.port) to \(configuration.networkService).")
            }
            guard autoProxy.contains("Enabled: No") else {
                throw KumoError.commandFailed("macOS auto proxy is still enabled after applying manual proxy.")
            }
        case .pac:
            guard [webProxy, secureWebProxy, socksProxy].allSatisfy({ $0.contains("Enabled: No") }) else {
                throw KumoError.commandFailed("macOS manual proxies are still enabled after applying PAC mode.")
            }
            guard let pacURL,
                  autoProxy.contains("Enabled: Yes"),
                  autoProxy.contains(pacURL) else {
                throw KumoError.commandFailed("macOS did not apply PAC proxy URL for \(configuration.networkService).")
            }
        }
    }

    private func canConnect(to host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let probeState = ConnectionProbeState()
            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    probeState.resumeOnce(true, connection: connection, continuation: continuation)
                case .failed, .cancelled:
                    probeState.resumeOnce(false, connection: connection, continuation: continuation)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                probeState.resumeOnce(false, connection: connection, continuation: continuation)
            }
        }
    }

}
