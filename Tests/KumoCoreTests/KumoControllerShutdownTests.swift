import Foundation
import XCTest
@testable import KumoCoreKit

final class KumoControllerShutdownTests: XCTestCase {
    func testShutdownActiveRuntimeStopsRunningCore() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let running = try controller.start(corePath: corePath)
        let pid = try XCTUnwrap(running.pid)
        let processIdentity = try XCTUnwrap(DarwinCoreProcessSystem().inspect(pid: pid)?.identity)

        let result = await controller.shutdownActiveRuntime()

        XCTAssertEqual(result.status.state, .stopped)
        XCTAssertNil(result.status.pid)
        XCTAssertNotEqual(
            DarwinCoreProcessSystem().inspect(pid: pid)?.identity,
            processIdentity,
            "the exact Mihomo process generation should have exited"
        )
        XCTAssertTrue(result.diagnostics.isEmpty, "unexpected diagnostics: \(result.diagnostics)")
    }

    func testProductionRetiresLegacyLocalRuntimeBeforeFirstHelperInstallation() async throws {
        let root = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("user", isDirectory: true),
            privilegedRuntimeRootDirectory: root.appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: root.appendingPathComponent("service", isDirectory: true),
            serviceExecutableFile: root.appendingPathComponent("system/KumoService"),
            serviceLaunchDaemonPlistFile: root.appendingPathComponent("system/io.kumo.KumoService.plist")
        )
        let legacyController = KumoController(paths: paths, useServiceBackend: false)
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let running = try legacyController.start(corePath: corePath)
        let pid = try XCTUnwrap(running.pid)
        let processIdentity = try XCTUnwrap(
            try CoreInstanceStore(paths: paths, ownership: nil).load()?.processIdentity
        )
        defer { _ = try? legacyController.stop() }

        let disabledOutput = "Enabled: No\nServer:\nPort: 0\n"
        var persisted = try CoreStateStore(paths: paths).load()
        persisted.systemProxyEnabled = true
        persisted.systemProxySettings = SystemProxySettings(networkService: "Wi-Fi")
        persisted.appliedSystemProxySnapshot = SystemProxySnapshot(
            networkService: "Wi-Fi",
            webProxy: disabledOutput,
            secureWebProxy: disabledOutput,
            socksProxy: disabledOutput,
            bypassDomains: disabledOutput,
            autoProxy: disabledOutput
        )
        try CoreStateStore(paths: paths).save(persisted)

        let recorder = RecordingCommandRunner()
        recorder.stubCapture(for: "/usr/sbin/networksetup", with: disabledOutput)
        let productionController = KumoController(
            paths: paths,
            useServiceBackend: true,
            systemProxyCommandRunner: recorder.makeRunner()
        )

        let stopped = try await productionController.stopSafely()

        XCTAssertTrue(stopped.isStrictlyStoppedRuntime)
        XCTAssertNotEqual(
            DarwinCoreProcessSystem().inspect(pid: pid)?.identity,
            processIdentity,
            "the legacy local generation must exit before Helper installation"
        )
        XCTAssertTrue(
            recorder.runArguments().contains(["-setwebproxystate", "Wi-Fi", "off"])
        )
        XCTAssertTrue(
            productionController.canRetireLegacyLocalRuntime(
                serviceStatus: productionController.serviceModeStatus()
            )
        )
    }

    func testInstalledHelperCannotHideOrMutatePendingLegacyRuntime() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let legacyController = KumoController(paths: paths, useServiceBackend: false)
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let running = try legacyController.start(corePath: corePath)
        defer { _ = try? legacyController.stop() }

        let productionController = KumoController(paths: paths, useServiceBackend: true)
        let currentHelper = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            installationHealth: .current
        )

        let blocked = productionController.serviceStatusBlockingPendingLegacyMigration(
            currentHelper
        )

        XCTAssertFalse(blocked.isAvailable)
        XCTAssertTrue(blocked.message?.contains("Complete Kumo Helper migration") == true)
        XCTAssertEqual(productionController.legacyLocalRuntimeStatus()?.pid, running.pid)
        XCTAssertThrowsError(try productionController.runtimeBackendForMutation()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Complete Kumo Helper migration"))
        }
    }

    func testQuitMayRetirePendingLegacyRuntimeOnlyWhenHelperIsStopped() {
        let currentHelper = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            installationHealth: .current
        )
        let stoppedHelperRuntime = CoreStatus()
        let runningHelperRuntime = CoreStatus(
            state: .running,
            pid: 42,
            readiness: .controllerReady,
            activeProfileID: "profile-a",
            runtimeGeneration: UUID(),
            configurationDigest: String(repeating: "a", count: 64)
        )

        XCTAssertTrue(KumoController.helperAllowsLegacyRuntimeRetirement(
            serviceStatus: currentHelper,
            helperStatus: stoppedHelperRuntime
        ))
        XCTAssertFalse(KumoController.helperAllowsLegacyRuntimeRetirement(
            serviceStatus: currentHelper,
            helperStatus: runningHelperRuntime
        ))
        var unavailable = currentHelper
        unavailable.isAvailable = false
        XCTAssertFalse(KumoController.helperAllowsLegacyRuntimeRetirement(
            serviceStatus: unavailable,
            helperStatus: stoppedHelperRuntime
        ))
    }

    func testShutdownActiveRuntimeDoesNotMutateStoppedTunPreference() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: true)),
            tunStatus: TunStatus(isEnabled: true, isRunning: false, requiresService: false)
        ))

        let result = await controller.shutdownActiveRuntime()

        XCTAssertEqual(result.status.state, .stopped)
        XCTAssertTrue(result.status.runtimeSettings?.tun?.isEnabled ?? false)
    }

    func testShutdownActiveRuntimeDisablesSystemProxy() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let stateStore = CoreStateStore(paths: paths)
        let disabledOutput = "Enabled: No\nServer:\nPort: 0\n"
        try stateStore.save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi"),
            appliedSystemProxySnapshot: SystemProxySnapshot(
                networkService: "Wi-Fi",
                webProxy: disabledOutput,
                secureWebProxy: disabledOutput,
                socksProxy: disabledOutput,
                bypassDomains: disabledOutput,
                autoProxy: disabledOutput
            )
        ))

        let recorder = RecordingCommandRunner()
        // `setSystemProxy(false)` ends with `verifyAppliedState`, which reads
        // each proxy state via `networksetup -get…` and requires the output
        // to contain "Enabled: No" before considering the disable applied.
        recorder.stubCapture(for: "/usr/sbin/networksetup", with: disabledOutput)
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: recorder.makeRunner()
        )

        let result = await controller.shutdownActiveRuntime()

        XCTAssertTrue(result.diagnostics.isEmpty, "unexpected diagnostics: \(result.diagnostics)")
        XCTAssertFalse(result.status.systemProxyEnabled)
        let runArgs = recorder.runArguments()
        XCTAssertTrue(
            runArgs.contains(["-setwebproxystate", "Wi-Fi", "off"]),
            "expected web proxy disable; ran: \(runArgs)"
        )
        XCTAssertTrue(
            runArgs.contains(["-setsecurewebproxystate", "Wi-Fi", "off"]),
            "expected secure web proxy disable; ran: \(runArgs)"
        )
        XCTAssertTrue(
            runArgs.contains(["-setsocksfirewallproxystate", "Wi-Fi", "off"]),
            "expected SOCKS proxy disable; ran: \(runArgs)"
        )
        XCTAssertTrue(
            runArgs.contains(["-setautoproxystate", "Wi-Fi", "off"]),
            "expected PAC autoproxy disable; ran: \(runArgs)"
        )
    }

    func testShutdownActiveRuntimeCollectsBothProxyErrors() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi")
        ))

        let recorder = RecordingCommandRunner()
        recorder.runError = KumoError.commandFailed("simulated networksetup failure")
        recorder.stubCapture(for: "/usr/sbin/networksetup", with: "")
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: recorder.makeRunner()
        )

        let result = await controller.shutdownActiveRuntime()

        XCTAssertEqual(
            result.diagnostics.count, 2,
            "expected both system-proxy stages to report a diagnostic; got: \(result.diagnostics)"
        )
        XCTAssertTrue(
            result.diagnostics[0].hasPrefix("system-proxy:"),
            "first diagnostic should be the helper/async path; got: \(result.diagnostics)"
        )
        XCTAssertTrue(
            result.diagnostics[1].hasPrefix("system-proxy-fallback:"),
            "second diagnostic should be the synchronous fallback; got: \(result.diagnostics)"
        )
    }

    func testShutdownLeavesCoreRunningWhenSystemProxyCannotBeMadeSafe() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let recorder = RecordingCommandRunner()
        recorder.runError = KumoError.commandFailed("simulated networksetup failure")
        recorder.stubCapture(for: "/usr/sbin/networksetup", with: "")
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: recorder.makeRunner()
        )
        let running = try controller.start(corePath: corePath)
        let pid = try XCTUnwrap(running.pid)
        var persisted = try CoreStateStore(paths: paths).load()
        persisted.systemProxyEnabled = true
        persisted.systemProxySettings = SystemProxySettings(networkService: "Wi-Fi")
        try CoreStateStore(paths: paths).save(persisted)
        defer { _ = try? controller.stop() }

        let result = await controller.shutdownActiveRuntime()

        XCTAssertNotEqual(result.status.state, .stopped)
        XCTAssertEqual(result.status.pid, pid)
        XCTAssertTrue(result.diagnostics.contains(where: { $0.hasPrefix("stop-skipped:") }))
        XCTAssertNotNil(DarwinCoreProcessSystem().inspect(pid: pid))
    }

    func testShutdownActiveRuntimeIsNoOpWhenAlreadyStopped() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(state: .stopped, pid: nil, systemProxyEnabled: false))

        let recorder = RecordingCommandRunner()
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: recorder.makeRunner()
        )

        let result = await controller.shutdownActiveRuntime()

        XCTAssertTrue(result.diagnostics.isEmpty, "unexpected diagnostics: \(result.diagnostics)")
        XCTAssertEqual(result.status.state, .stopped)
        XCTAssertNil(result.status.pid)
        XCTAssertTrue(recorder.runArguments().isEmpty, "no commands should have run; ran: \(recorder.runArguments())")
    }

    func testAppUpdateInstallationRequiresConfirmedStoppedSafeRuntime() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            state: .stopped,
            pid: nil,
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi")
        ))
        let commandRecorder = RecordingCommandRunner()
        commandRecorder.runError = KumoError.commandFailed("simulated networksetup failure")
        commandRecorder.stubCapture(for: "/usr/sbin/networksetup", with: "")
        let installer = RecordingAppUpdateInstaller()
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: commandRecorder.makeRunner(),
            appUpdateInstaller: installer
        )

        do {
            try await controller.installAppUpdate(
                dmgURL: paths.applicationSupportDirectory.appendingPathComponent("update.dmg"),
                currentAppURL: paths.applicationSupportDirectory.appendingPathComponent("Kumo.app"),
                expectedVersion: "2.0.0",
                processID: 42
            )
            XCTFail("unsafe runtime state must abort update installation")
        } catch {
            XCTAssertTrue(installer.invocations.isEmpty)
        }
    }

    func testAppUpdateInstallationSchedulesInstallerAfterFreshSafeStatus() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .stopped,
            pid: nil,
            systemProxyEnabled: false
        ))
        let installer = RecordingAppUpdateInstaller()
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            appUpdateInstaller: installer
        )
        let dmgURL = paths.applicationSupportDirectory.appendingPathComponent("update.dmg")
        let currentAppURL = paths.applicationSupportDirectory.appendingPathComponent("Kumo.app")

        try await controller.installAppUpdate(
            dmgURL: dmgURL,
            currentAppURL: currentAppURL,
            expectedVersion: "2.0.0",
            processID: 42
        )

        XCTAssertEqual(installer.invocations.count, 1)
        XCTAssertEqual(installer.invocations.first?.dmgURL, dmgURL)
        XCTAssertEqual(installer.invocations.first?.currentAppURL, currentAppURL)
        XCTAssertEqual(installer.invocations.first?.expectedVersion, "2.0.0")
        XCTAssertEqual(installer.invocations.first?.processID, 42)
    }

    func testDisableSynchronouslyClearsPersistedState() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi"),
            previousSystemProxySnapshot: SystemProxySnapshot(networkService: "Wi-Fi")
        ))

        let recorder = RecordingCommandRunner()
        let controller = SystemProxyController(paths: paths, commandRunner: recorder.makeRunner())

        let commands = try controller.disableSynchronously(
            configuration: SystemProxyConfiguration(networkService: "Wi-Fi")
        )

        XCTAssertTrue(commands.isEmpty, "an already-restored snapshot should only finalize persisted state")
        let stored = try stateStore.load()
        XCTAssertFalse(stored.systemProxyEnabled)
        XCTAssertNil(stored.previousSystemProxySnapshot)

        XCTAssertTrue(recorder.runArguments().isEmpty)
    }

    // MARK: - Helpers

    private func makeLongRunningCore(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-mihomo")
        try """
        #!/bin/sh
        if [ "$1" = "-t" ]; then exit 0; fi
        child=""
        trap 'if [ -n "$child" ]; then kill "$child" 2>/dev/null; fi; exit 0' INT TERM
        /bin/sleep 600 &
        child=$!
        wait "$child"
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

}

private final class RecordingAppUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
    struct Invocation {
        var dmgURL: URL
        var currentAppURL: URL
        var expectedVersion: String
        var processID: Int32
    }

    private let lock = NSLock()
    private var recordedInvocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    func installDMG(
        dmgURL: URL,
        currentAppURL: URL,
        expectedVersion: String,
        processID: Int32
    ) throws {
        lock.withLock {
            recordedInvocations.append(Invocation(
                dmgURL: dmgURL,
                currentAppURL: currentAppURL,
                expectedVersion: expectedVersion,
                processID: processID
            ))
        }
    }
}

/// Records every command issued through a `SystemProxyCommandRunner` and
/// optionally fails them with a configured error. Access is guarded by an
/// NSLock so the closures are safe to call from any executor — the public
/// surface looks ordinary but mutation is mediated.
private final class RecordingCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var _ranCommands: [ShellCommand] = []
    private var _capturedCommands: [ShellCommand] = []
    private var _captureStubs: [String: String] = [:]
    private var _runError: Error?

    var runError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _runError }
        set { lock.lock(); _runError = newValue; lock.unlock() }
    }

    func stubCapture(for executable: String, with output: String) {
        lock.lock()
        _captureStubs[executable] = output
        lock.unlock()
    }

    func runArguments() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _ranCommands.map { $0.arguments }
    }

    func makeRunner() -> SystemProxyCommandRunner {
        SystemProxyCommandRunner(
            run: { [self] command in
                self.lock.lock()
                self._ranCommands.append(command)
                let error = self._runError
                self.lock.unlock()
                if let error { throw error }
            },
            captureOutput: { [self] command in
                self.lock.lock()
                self._capturedCommands.append(command)
                let stub = self._captureStubs[command.executable] ?? ""
                self.lock.unlock()
                return stub
            }
        )
    }
}
