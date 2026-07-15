import XCTest
@testable import KumoCoreKit

final class SystemProxyControllerTests: XCTestCase {
    func testSystemProxyEnableCommandsUseMixedPort() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = SystemProxyController(paths: paths)

        let commands = try await controller.setEnabled(
            true,
            configuration: SystemProxyConfiguration(networkService: "Wi-Fi", host: "127.0.0.1", port: 17890),
            dryRun: true
        )

        XCTAssertTrue(commands.allSatisfy { $0.executable == "/usr/sbin/networksetup" })
        XCTAssertTrue(commands.contains { $0.arguments.contains("-setwebproxy") })
        XCTAssertTrue(commands.contains { $0.arguments.contains("17890") })
        XCTAssertTrue(commands.contains { $0.arguments.contains("-setproxybypassdomains") })
        // Manual mode should also assert PAC mode is off.
        XCTAssertTrue(commands.contains { $0.arguments.contains("-setautoproxystate") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateFile.path))
    }

    func testSystemProxyDisableCommandsTurnServicesOff() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = SystemProxyController(paths: paths)

        let commands = try await controller.setEnabled(false, dryRun: true)

        XCTAssertTrue(commands.allSatisfy { $0.arguments.last == "off" })
        XCTAssertTrue(commands.contains { $0.arguments.contains("-setwebproxystate") })
        XCTAssertTrue(commands.contains { $0.arguments.contains("-setautoproxystate") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateFile.path))
    }

    func testSystemProxyPACModeUsesAutoProxyURL() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = SystemProxyController(paths: paths)

        let commands = try await controller.setEnabled(
            true,
            configuration: SystemProxyConfiguration(
                networkService: "Wi-Fi",
                host: "127.0.0.1",
                port: 17890,
                mode: .pac,
                pacScript: "function FindProxyForURL() { return 'DIRECT'; }"
            ),
            dryRun: true
        )

        XCTAssertTrue(commands.contains { $0.arguments.contains("-setautoproxyurl") })
        XCTAssertTrue(commands.contains { args in
            args.arguments.contains("-setautoproxystate") && args.arguments.last == "on"
        })
        // PAC mode should also turn manual proxies off.
        XCTAssertTrue(commands.contains { args in
            args.arguments.contains("-setwebproxystate") && args.arguments.last == "off"
        })
    }

    func testRenderPACScriptReplacesMixedPortPlaceholder() {
        let script = "return \"PROXY 127.0.0.1:%mixed-port%; SOCKS5 127.0.0.1:%mixed-port%; DIRECT;\";"

        let rendered = SystemProxyController.renderPACScript(script, port: 17890)

        XCTAssertFalse(rendered.contains("%mixed-port%"))
        XCTAssertTrue(rendered.contains("127.0.0.1:17890"))
    }

    func testNetworkServiceParserMatchesDefaultInterface() throws {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)

        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        """

        let service = try SystemProxyController.networkService(in: output, matchingDevice: "en0")

        XCTAssertEqual(service, "Wi-Fi")
    }

    func testDisableCleansCurrentServiceBeforeRestoringLegacySnapshotFromAnotherService() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let disabledProxy = "Enabled: No\nServer: \nPort: 0"
        let disabledAutoProxy = "URL: \nEnabled: No"
        let applied = manualSnapshot(
            networkService: "USB 10/100/1000 LAN",
            host: "127.0.0.1",
            port: 7890
        )
        let original = SystemProxySnapshot(
            networkService: "Wi-Fi",
            webProxy: disabledProxy,
            secureWebProxy: disabledProxy,
            socksProxy: disabledProxy,
            bypassDomains: "There aren't any bypass domains set on Wi-Fi.",
            autoProxy: disabledAutoProxy
        )
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "USB 10/100/1000 LAN"),
            previousSystemProxySnapshot: original,
            appliedSystemProxySnapshot: applied
        ))
        let environment = MutableProxyEnvironment(snapshots: [applied, original])
        let controller = SystemProxyController(paths: paths, commandRunner: environment.runner)

        _ = try await controller.setEnabled(
            false,
            configuration: SystemProxyConfiguration(networkService: "USB 10/100/1000 LAN")
        )

        let arguments = environment.commands.map(\.arguments)
        XCTAssertTrue(arguments.contains(["-setwebproxystate", "USB 10/100/1000 LAN", "off"]))
        XCTAssertTrue(arguments.contains(["-setsecurewebproxystate", "USB 10/100/1000 LAN", "off"]))
        XCTAssertTrue(arguments.contains(["-setsocksfirewallproxystate", "USB 10/100/1000 LAN", "off"]))
        XCTAssertTrue(arguments.contains(["-setwebproxystate", "Wi-Fi", "off"]))
        XCTAssertFalse(try stateStore.load().systemProxyEnabled)
    }

    func testSynchronousDisableRestoresPACURLWithoutChangingCase() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let pacURL = "https://Proxy.Example/MyProxy.PAC?Token=AbC123"
        let disabledProxy = "Enabled: No\nServer: \nPort: 0"
        let originalAutoProxy = "URL: \(pacURL)\nEnabled: Yes"
        let applied = manualSnapshot(networkService: "Wi-Fi", host: "127.0.0.1", port: 7890)
        let original = SystemProxySnapshot(
            networkService: "Wi-Fi",
            webProxy: disabledProxy,
            secureWebProxy: disabledProxy,
            socksProxy: disabledProxy,
            bypassDomains: "There aren't any bypass domains set on Wi-Fi.",
            autoProxy: originalAutoProxy
        )
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi"),
            previousSystemProxySnapshot: original,
            appliedSystemProxySnapshot: applied
        ))
        let environment = MutableProxyEnvironment(snapshots: [applied])
        let controller = SystemProxyController(paths: paths, commandRunner: environment.runner)

        _ = try controller.disableSynchronously(
            configuration: SystemProxyConfiguration(networkService: "Wi-Fi")
        )

        XCTAssertTrue(environment.commands.contains {
            $0.arguments == ["-setautoproxyurl", "Wi-Fi", pacURL]
        })
        XCTAssertTrue(environment.commands.contains {
            $0.arguments == ["-setautoproxystate", "Wi-Fi", "on"]
        })
    }

    func testSynchronousDisableRefusesToStopCoreWhenCurrentServiceStillHasProxy() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let disabledProxy = "Enabled: No\nServer: \nPort: 0"
        let enabledProxy = "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890"
        let disabledAutoProxy = "URL: \nEnabled: No"
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "USB LAN"),
            previousSystemProxySnapshot: SystemProxySnapshot(
                networkService: "Wi-Fi",
                webProxy: disabledProxy,
                secureWebProxy: disabledProxy,
                socksProxy: disabledProxy,
                bypassDomains: "There aren't any bypass domains set on Wi-Fi.",
                autoProxy: disabledAutoProxy
            ),
            appliedSystemProxySnapshot: SystemProxySnapshot(
                networkService: "USB LAN",
                webProxy: enabledProxy,
                secureWebProxy: enabledProxy,
                socksProxy: enabledProxy,
                bypassDomains: "There aren't any bypass domains set on USB LAN.",
                autoProxy: disabledAutoProxy
            )
        ))
        let recorder = ProxyCommandRecorder(capturedOutput: { command in
            let service = command.arguments.last ?? ""
            switch command.arguments.first {
            case "-getproxybypassdomains":
                return "There aren't any bypass domains set on \(service)."
            case "-getautoproxyurl":
                return disabledAutoProxy
            default:
                return service == "USB LAN" ? enabledProxy : disabledProxy
            }
        })
        let controller = SystemProxyController(paths: paths, commandRunner: recorder.runner)

        XCTAssertThrowsError(
            try controller.disableSynchronously(
                configuration: SystemProxyConfiguration(networkService: "USB LAN")
            )
        )
        XCTAssertTrue(try stateStore.load().systemProxyEnabled)
    }

    func testDisablePreservesProxyChangedByAnotherApplication() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let original = disabledSnapshot(networkService: "Wi-Fi")
        let applied = manualSnapshot(networkService: "Wi-Fi", host: "127.0.0.1", port: 7890)
        let external = manualSnapshot(networkService: "Wi-Fi", host: "127.0.0.2", port: 8888)
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi"),
            previousSystemProxySnapshot: original,
            appliedSystemProxySnapshot: applied
        ))
        let environment = MutableProxyEnvironment(snapshots: [external])
        let controller = SystemProxyController(paths: paths, commandRunner: environment.runner)

        do {
            _ = try await controller.setEnabled(
                false,
                configuration: SystemProxyConfiguration(networkService: "Wi-Fi")
            )
            XCTFail("Expected external proxy ownership conflict")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed outside Kumo"))
        }

        XCTAssertTrue(environment.commands.isEmpty)
        XCTAssertEqual(environment.currentSnapshot(for: "Wi-Fi"), external)
        XCTAssertTrue(try stateStore.load().systemProxyEnabled)
    }

    func testDisableRestoresLegacySnapshotWithoutAutoProxyField() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let applied = manualSnapshot(networkService: "Wi-Fi", host: "127.0.0.1", port: 7890)
        let legacyDisabledProxy = "Enabled: No\nServer: 127.0.0.1\nPort: 7890"
        let legacyOriginal = SystemProxySnapshot(
            networkService: "Wi-Fi",
            webProxy: legacyDisabledProxy,
            secureWebProxy: legacyDisabledProxy,
            socksProxy: legacyDisabledProxy,
            bypassDomains: SystemProxySettings.defaultBypassList.joined(separator: "\n"),
            autoProxy: nil
        )
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi"),
            previousSystemProxySnapshot: legacyOriginal,
            appliedSystemProxySnapshot: nil
        ))
        let environment = MutableProxyEnvironment(snapshots: [applied])
        let controller = SystemProxyController(paths: paths, commandRunner: environment.runner)

        _ = try await controller.setEnabled(
            false,
            configuration: SystemProxyConfiguration(networkService: "Wi-Fi")
        )

        XCTAssertFalse(try stateStore.load().systemProxyEnabled)
        XCTAssertEqual(
            environment.currentSnapshot(for: "Wi-Fi")?.autoProxy,
            "URL: \nEnabled: No"
        )
    }

    func testRuntimeProxyValidationUsesExplicitCandidateProfileDuringActivation() throws {
        let controller = KumoController(
            paths: KumoPaths(applicationSupportDirectory: temporaryDirectory()),
            useServiceBackend: false
        )
        let candidateRuntime = CoreStatus(
            state: .running,
            pid: 42,
            readiness: .controllerReady,
            activeProfileID: "profile-b",
            runtimeGeneration: UUID(),
            configurationDigest: String(repeating: "a", count: 64)
        )

        XCTAssertNoThrow(
            try controller.validateRuntimeForSystemProxy(
                candidateRuntime,
                expectedProfileID: "profile-b",
                verifyListenerOwnership: false
            )
        )
        XCTAssertThrowsError(
            try controller.validateRuntimeForSystemProxy(
                candidateRuntime,
                expectedProfileID: "profile-a",
                verifyListenerOwnership: false
            )
        )
        var unverifiedRuntime = candidateRuntime
        unverifiedRuntime.configurationDigest = nil
        XCTAssertThrowsError(
            try controller.validateRuntimeForSystemProxy(
                unverifiedRuntime,
                expectedProfileID: "profile-b",
                verifyListenerOwnership: false
            )
        )
    }

    func testAuthenticatedProxyIsRejectedBeforeAnyMutation() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let authenticatedProxy = """
        Enabled: Yes
        Server: corporate.example
        Port: 8080
        Authenticated Proxy Enabled: 1
        """
        let recorder = ProxyCommandRecorder(capturedOutput: { command in
            switch command.arguments.first {
            case "-getproxybypassdomains":
                return "There aren't any bypass domains set on Wi-Fi."
            case "-getautoproxyurl":
                return "URL: \nEnabled: No"
            default:
                return authenticatedProxy
            }
        })
        let controller = SystemProxyController(paths: paths, commandRunner: recorder.runner)

        do {
            _ = try await controller.setEnabled(
                true,
                configuration: SystemProxyConfiguration(
                    networkService: "Wi-Fi",
                    host: "127.0.0.1",
                    port: 17890
                )
            )
            XCTFail("Expected authenticated proxy protection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("authenticated proxy"))
        }

        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateFile.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func manualSnapshot(
        networkService: String,
        host: String,
        port: Int
    ) -> SystemProxySnapshot {
        let output = "Enabled: Yes\nServer: \(host)\nPort: \(port)"
        return SystemProxySnapshot(
            networkService: networkService,
            webProxy: output,
            secureWebProxy: output,
            socksProxy: output,
            bypassDomains: SystemProxySettings.defaultBypassList.joined(separator: "\n"),
            autoProxy: "URL: \nEnabled: No"
        )
    }

    private func disabledSnapshot(networkService: String) -> SystemProxySnapshot {
        let output = "Enabled: No\nServer: \nPort: 0"
        return SystemProxySnapshot(
            networkService: networkService,
            webProxy: output,
            secureWebProxy: output,
            socksProxy: output,
            bypassDomains: "There aren't any bypass domains set on \(networkService).",
            autoProxy: "URL: \nEnabled: No"
        )
    }
}

private final class ProxyCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ShellCommand] = []
    private let output: @Sendable (ShellCommand) -> String

    init(capturedOutput: @escaping @Sendable (ShellCommand) -> String) {
        self.output = capturedOutput
    }

    var commands: [ShellCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var runner: SystemProxyCommandRunner {
        SystemProxyCommandRunner(
            run: { [self] command in
                lock.lock()
                recorded.append(command)
                lock.unlock()
            },
            captureOutput: { [self] command in output(command) }
        )
    }
}

private final class MutableProxyEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: SystemProxySnapshot]
    private var recorded: [ShellCommand] = []

    init(snapshots: [SystemProxySnapshot]) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.networkService, $0) })
    }

    var commands: [ShellCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func currentSnapshot(for service: String) -> SystemProxySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[service]
    }

    var runner: SystemProxyCommandRunner {
        SystemProxyCommandRunner(
            run: { [self] command in try apply(command) },
            captureOutput: { [self] command in try capture(command) }
        )
    }

    private func capture(_ command: ShellCommand) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard command.arguments.count >= 2,
              let snapshot = snapshots[command.arguments[1]] else {
            throw KumoError.commandFailed("Missing proxy test state")
        }
        switch command.arguments[0] {
        case "-getwebproxy": return snapshot.webProxy
        case "-getsecurewebproxy": return snapshot.secureWebProxy
        case "-getsocksfirewallproxy": return snapshot.socksProxy
        case "-getproxybypassdomains": return snapshot.bypassDomains
        case "-getautoproxyurl": return snapshot.autoProxy ?? "URL: \nEnabled: No"
        default: throw KumoError.commandFailed("Unexpected proxy capture command")
        }
    }

    private func apply(_ command: ShellCommand) throws {
        lock.lock()
        defer { lock.unlock() }
        guard command.arguments.count >= 2 else {
            throw KumoError.commandFailed("Malformed proxy test command")
        }
        recorded.append(command)
        let flag = command.arguments[0]
        let service = command.arguments[1]
        var snapshot = snapshots[service] ?? SystemProxySnapshot(networkService: service)

        switch flag {
        case "-setwebproxy", "-setsecurewebproxy", "-setsocksfirewallproxy":
            guard command.arguments.count >= 4 else { throw KumoError.commandFailed("Malformed proxy command") }
            let output = Self.proxyOutput(
                enabled: true,
                server: command.arguments[2],
                port: command.arguments[3]
            )
            if flag == "-setwebproxy" { snapshot.webProxy = output }
            if flag == "-setsecurewebproxy" { snapshot.secureWebProxy = output }
            if flag == "-setsocksfirewallproxy" { snapshot.socksProxy = output }
        case "-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate":
            guard command.arguments.count >= 3 else { throw KumoError.commandFailed("Malformed proxy state command") }
            let enabled = command.arguments[2].lowercased() == "on"
            if flag == "-setwebproxystate" {
                snapshot.webProxy = Self.proxyOutput(snapshot.webProxy, enabled: enabled)
            } else if flag == "-setsecurewebproxystate" {
                snapshot.secureWebProxy = Self.proxyOutput(snapshot.secureWebProxy, enabled: enabled)
            } else {
                snapshot.socksProxy = Self.proxyOutput(snapshot.socksProxy, enabled: enabled)
            }
        case "-setproxybypassdomains":
            let domains = Array(command.arguments.dropFirst(2))
            snapshot.bypassDomains = domains == ["Empty"]
                ? "There aren't any bypass domains set on \(service)."
                : domains.joined(separator: "\n")
        case "-setautoproxyurl":
            guard command.arguments.count >= 3 else { throw KumoError.commandFailed("Malformed PAC URL command") }
            let enabled = Self.fields(snapshot.autoProxy ?? "")["enabled"]?.lowercased() == "yes"
            snapshot.autoProxy = "URL: \(command.arguments[2])\nEnabled: \(enabled ? "Yes" : "No")"
        case "-setautoproxystate":
            guard command.arguments.count >= 3 else { throw KumoError.commandFailed("Malformed PAC state command") }
            let url = Self.fields(snapshot.autoProxy ?? "")["url"] ?? ""
            let enabled = command.arguments[2].lowercased() == "on"
            snapshot.autoProxy = "URL: \(url)\nEnabled: \(enabled ? "Yes" : "No")"
        default:
            throw KumoError.commandFailed("Unexpected proxy mutation command")
        }
        snapshots[service] = snapshot
    }

    private static func proxyOutput(_ current: String, enabled: Bool) -> String {
        let values = fields(current)
        return proxyOutput(
            enabled: enabled,
            server: values["server"] ?? "",
            port: values["port"] ?? "0"
        )
    }

    private static func proxyOutput(enabled: Bool, server: String, port: String) -> String {
        "Enabled: \(enabled ? "Yes" : "No")\nServer: \(server)\nPort: \(port)"
    }

    private static func fields(_ output: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line in
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            return (
                String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        })
    }
}
