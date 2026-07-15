import Darwin
import Foundation
import XCTest
import Yams
@testable import KumoCoreKit

final class CoreSupervisorTests: XCTestCase {
    func testProcessExistsWhenSignalProbeIsDenied() {
        XCTAssertTrue(CoreSupervisor.processExists(killResult: -1, errorNumber: EPERM))
        XCTAssertFalse(CoreSupervisor.processExists(killResult: -1, errorNumber: ESRCH))
    }

    func testStartWritesPIDFileAndStopTerminatesProcess() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)

        let status = try supervisor.start(configuration: launchConfiguration(corePath: corePath))
        let pid = try XCTUnwrap(status.pid)

        XCTAssertEqual(try String(contentsOf: paths.corePIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "\(pid)")

        let stopped = try supervisor.stop()

        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.corePIDFile.path))
        XCTAssertFalse(isProcessAlive(pid))
    }

    func testStopUsesPIDFileWhenStatePIDIsMissing() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)
        let stateStore = CoreStateStore(paths: paths)

        let status = try supervisor.start(configuration: launchConfiguration(corePath: corePath))
        let pid = try XCTUnwrap(status.pid)
        try FileManager.default.removeItem(at: paths.coreInstanceFile)
        let sentinel = paths.workDirectory.appendingPathComponent("keep-after-legacy-stop")
        try Data("keep".utf8).write(to: sentinel)
        try stateStore.save(CoreStatus(corePath: corePath))

        let stopped = try supervisor.stop()

        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.corePIDFile.path))
        XCTAssertFalse(isProcessAlive(pid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testStatusRecoversRunningPIDFromPIDFileWhenStatePIDIsMissing() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)
        let stateStore = CoreStateStore(paths: paths)

        let status = try supervisor.start(configuration: launchConfiguration(corePath: corePath))
        let pid = try XCTUnwrap(status.pid)
        try FileManager.default.removeItem(at: paths.coreInstanceFile)
        try stateStore.save(CoreStatus(corePath: corePath))

        let recovered = try supervisor.status()

        XCTAssertEqual(recovered.state, .starting)
        XCTAssertEqual(recovered.pid, pid)
        _ = try supervisor.stop()
    }

    func testStartPassesControllerEndpointToMihomoArguments() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let argumentsFile = paths.applicationSupportDirectory.appendingPathComponent("core-arguments.txt")
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory, recordedArgumentsURL: argumentsFile)
        let supervisor = CoreSupervisor(paths: paths)

        let status = try supervisor.start(
            configuration: launchConfiguration(
                corePath: corePath,
                endpoint: ControllerEndpoint(port: 19097, secret: "test-secret")
            )
        )
        defer { _ = try? supervisor.stop() }

        XCTAssertEqual(status.endpoint.port, 19097)
        let arguments = try recordedArguments(at: argumentsFile)
        XCTAssertEqual(Array(arguments[0...1]), ["-d", paths.workDirectory.path])
        XCTAssertEqual(arguments[2], "-f")
        XCTAssertTrue(arguments[3].hasPrefix(paths.coreInstancesDirectory.path + "/"))
        XCTAssertEqual(
            Array(arguments[4...]),
            ["-ext-ctl", "127.0.0.1:19097", "-secret", "test-secret"]
        )
    }

    func testLaunchUsesRepositoryProfileIDForProviderCacheNamespace() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)
        let profile = Profile(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            name: "Remote",
            source: .inline,
            rawYAML: """
            proxy-providers:
              shared:
                type: http
                url: https://example.com/provider.yaml
                path: ./providers/shared.yaml
            rules: [MATCH,DIRECT]
            """
        )

        _ = try supervisor.start(
            configuration: CoreLaunchConfiguration(
                corePath: corePath,
                profileID: "profile-a",
                profile: profile
            )
        )
        let firstRecord = try XCTUnwrap(try supervisor.currentInstanceRecord())
        let firstPath = try proxyProviderPath(in: URL(fileURLWithPath: firstRecord.configPath))
        _ = try supervisor.stop()

        _ = try supervisor.start(
            configuration: CoreLaunchConfiguration(
                corePath: corePath,
                profileID: "profile-b",
                profile: profile
            )
        )
        defer { _ = try? supervisor.stop() }
        let secondRecord = try XCTUnwrap(try supervisor.currentInstanceRecord())
        let secondPath = try proxyProviderPath(in: URL(fileURLWithPath: secondRecord.configPath))

        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertTrue(firstPath.hasPrefix("./providers/proxy/"))
        XCTAssertTrue(secondPath.hasPrefix("./providers/proxy/"))
    }

    func testRecordedProcessRunningBecomesFalseAfterChildExits() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeShortLivedCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)

        _ = try supervisor.start(configuration: launchConfiguration(corePath: corePath))
        XCTAssertTrue(try supervisor.isRecordedProcessRunning())

        let deadline = Date().addingTimeInterval(2)
        while try supervisor.isRecordedProcessRunning(), Date() < deadline {
            usleep(50_000)
        }
        XCTAssertFalse(try supervisor.isRecordedProcessRunning())
    }

    func testOwnedRuntimeProbeIgnoresMirroredForeignPID() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            pid: getpid(),
            corePath: paths.managedCoreExecutable.path,
            readiness: .controllerReady,
            activeProfileID: "profile-a",
            runtimeGeneration: UUID(),
            configurationDigest: String(repeating: "a", count: 64)
        ))

        XCTAssertFalse(try CoreSupervisor(paths: paths).hasOwnedRuntimeProcess())
    }

    func testOwnedRuntimeProbeTracksExactLocalProcess() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)

        _ = try supervisor.start(configuration: launchConfiguration(corePath: corePath))
        XCTAssertTrue(try supervisor.hasOwnedRuntimeProcess())

        _ = try supervisor.stop()
        XCTAssertFalse(try supervisor.hasOwnedRuntimeProcess())
    }

    func testStopTerminatesUntrackedKumoOwnedProcess() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        try CoreStateStore(paths: paths).save(CoreStatus(corePath: corePath))
        let process = try launchDetachedCore(
            corePath: corePath,
            workDirectory: paths.workDirectory.path,
            endpoint: "127.0.0.1:9097"
        )
        defer { terminateForCleanup(process) }

        _ = try CoreSupervisor(paths: paths).stop()

        XCTAssertFalse(process.isRunning)
    }

    func testPrivilegedStopTerminatesLegacyKumoRuntimeFromDiscoveredCore() throws {
        let root = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("user", isDirectory: true),
            privilegedRuntimeRootDirectory: root.appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: root.appendingPathComponent("service", isDirectory: true)
        )
        let legacyWork = paths.workDirectory
        try FileManager.default.createDirectory(at: legacyWork, withIntermediateDirectories: true)
        let legacyConfig = legacyWork.appendingPathComponent("config.yaml")
        try Data("rules: [MATCH,DIRECT]\n".utf8).write(to: legacyConfig)
        let legacyCore = try makeLongRunningCore(
            at: root.appendingPathComponent("homebrew/mihomo")
        )
        let process = try launchDetachedCore(
            corePath: legacyCore,
            workDirectory: legacyWork.path,
            endpoint: "127.0.0.1:9097",
            configPath: legacyConfig.path
        )
        defer { terminateForCleanup(process) }
        let supervisor = CoreSupervisor(
            paths: paths,
            stateFileOwnership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )
        try FileManager.default.createDirectory(
            at: paths.privilegedServiceUserDirectory(userID: getuid()),
            withIntermediateDirectories: true
        )

        _ = try supervisor.stop()

        XCTAssertFalse(process.isRunning)
    }

    func testStopDoesNotTerminateSimilarProcessUsingDifferentWorkDirectory() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        try CoreStateStore(paths: paths).save(CoreStatus(corePath: corePath))
        let process = try launchDetachedCore(
            corePath: corePath,
            workDirectory: "/tmp/not-kumo-work",
            endpoint: "127.0.0.1:9097"
        )
        defer { terminateForCleanup(process) }

        _ = try CoreSupervisor(paths: paths).stop()

        XCTAssertTrue(process.isRunning)
    }

    func testStartRefusesSymlinkedCoreLogWithoutTouchingTarget() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        try paths.prepare()
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let victim = paths.applicationSupportDirectory.appendingPathComponent("victim.txt")
        try Data("unchanged".utf8).write(to: victim)
        XCTAssertEqual(symlink(victim.path, paths.coreLogFile.path), 0)

        XCTAssertThrowsError(
            try CoreSupervisor(paths: paths).start(
                configuration: launchConfiguration(corePath: corePath)
            )
        )
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "unchanged")
    }

    func testRestartPreflightsProtectedCoreBeforeStoppingExistingRuntime() throws {
        let root = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("user", isDirectory: true),
            privilegedRuntimeRootDirectory: root.appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: root.appendingPathComponent("service", isDirectory: true)
        )
        let ownership = StateFileOwnership(userID: getuid(), groupID: getgid())
        let coreURL = paths.privilegedManagedCoreExecutable(userID: getuid())
        let corePath = try makeLongRunningCore(at: coreURL)
        let supervisor = CoreSupervisor(paths: paths, stateFileOwnership: ownership)
        let running = try supervisor.start(configuration: launchConfiguration(corePath: corePath))
        let runningPID = try XCTUnwrap(running.pid)
        defer { _ = try? supervisor.stop() }

        try FileManager.default.removeItem(at: coreURL)

        XCTAssertThrowsError(
            try supervisor.restart(configuration: launchConfiguration(corePath: corePath))
        )
        XCTAssertTrue(isProcessAlive(runningPID))
        XCTAssertEqual(try supervisor.status().pid, runningPID)
    }

    func testRestartRejectsMihomoSchemaFailureBeforeStoppingExistingRuntime() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let validationFailureMarker = paths.applicationSupportDirectory
            .appendingPathComponent("reject-config")
        let corePath = try makeLongRunningCore(
            in: paths.applicationSupportDirectory,
            validationFailureMarkerURL: validationFailureMarker
        )
        let supervisor = CoreSupervisor(paths: paths)
        let running = try supervisor.start(configuration: launchConfiguration(corePath: corePath))
        let runningPID = try XCTUnwrap(running.pid)
        defer { _ = try? supervisor.stop() }
        try Data().write(to: validationFailureMarker)

        XCTAssertThrowsError(
            try supervisor.restart(configuration: launchConfiguration(corePath: corePath))
        )
        XCTAssertTrue(isProcessAlive(runningPID))
        XCTAssertEqual(try supervisor.status().pid, runningPID)
    }

    func testPrivilegedRuntimeUsesOnlyPrivateWorkAndLogDirectories() throws {
        let root = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("user", isDirectory: true),
            privilegedRuntimeRootDirectory: root.appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: root.appendingPathComponent("service", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        let workVictim = root.appendingPathComponent("work-victim", isDirectory: true)
        let logVictim = root.appendingPathComponent("log-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: workVictim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logVictim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.workDirectory, withDestinationURL: workVictim)
        try FileManager.default.createSymbolicLink(at: paths.logsDirectory, withDestinationURL: logVictim)

        let argumentsFile = root.appendingPathComponent("arguments.txt")
        let coreURL = paths.privilegedManagedCoreExecutable(userID: getuid())
        let corePath = try makeLongRunningCore(at: coreURL, recordedArgumentsURL: argumentsFile)
        let supervisor = CoreSupervisor(
            paths: paths,
            stateFileOwnership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )

        _ = try supervisor.start(configuration: launchConfiguration(corePath: corePath))
        defer { _ = try? supervisor.stop() }
        let arguments = try recordedArguments(at: argumentsFile)
        let privateRuntime = paths.privilegedRuntimeDirectory(userID: getuid())

        XCTAssertEqual(Array(arguments[0...1]), ["-d", privateRuntime.appendingPathComponent("work").path])
        XCTAssertTrue(arguments[3].hasPrefix(privateRuntime.appendingPathComponent("instances").path + "/"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workVictim.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logVictim.path).isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: privateRuntime.appendingPathComponent("logs/core.log").path
            )
        )
    }

    func testRestartWithNewMixedPortCreatesMatchingInstanceGeneration() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)

        let first = try supervisor.start(
            configuration: launchConfiguration(corePath: corePath, mixedPort: 17_890)
        )
        let second = try supervisor.restart(
            configuration: launchConfiguration(corePath: corePath, mixedPort: 17_891)
        )
        defer { _ = try? supervisor.stop() }

        XCTAssertNotEqual(first.runtimeGeneration, second.runtimeGeneration)
        XCTAssertEqual(second.proxyPorts.mixedPort, 17_891)
        XCTAssertEqual(try supervisor.currentInstanceRecord()?.mixedPort, 17_891)
        let observed = try supervisor.status()
        XCTAssertEqual(observed.state, .starting, observed.message ?? "missing status message")
        XCTAssertEqual(observed.proxyPorts.mixedPort, 17_891)
        XCTAssertEqual(observed.runtimeGeneration, second.runtimeGeneration)
    }

    private func launchConfiguration(
        corePath: String,
        endpoint: ControllerEndpoint = ControllerEndpoint(),
        mixedPort: Int = 7_890
    ) -> CoreLaunchConfiguration {
        CoreLaunchConfiguration(
            corePath: corePath,
            profile: Profile(
                name: "Test",
                source: .inline,
                rawYAML: """
                proxies: []
                proxy-groups:
                  - name: Proxy
                    type: select
                    proxies:
                      - DIRECT
                rules:
                  - MATCH,DIRECT
                """
            ),
            endpoint: endpoint,
            proxyPorts: ProxyPortConfiguration(mixedPort: mixedPort),
            runtimeSettings: CoreRuntimeSettings(mixedPort: mixedPort)
        )
    }

    private func proxyProviderPath(in configURL: URL) throws -> String {
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        let mapping = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        let providers = try XCTUnwrap(mapping["proxy-providers"] as? [String: Any])
        let provider = try XCTUnwrap(providers["shared"] as? [String: Any])
        return try XCTUnwrap(provider["path"] as? String)
    }

    private func makeLongRunningCore(
        in directory: URL,
        recordedArgumentsURL: URL? = nil,
        validationFailureMarkerURL: URL? = nil
    ) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-mihomo")
        return try makeLongRunningCore(
            at: url,
            recordedArgumentsURL: recordedArgumentsURL,
            validationFailureMarkerURL: validationFailureMarkerURL
        )
    }

    private func makeLongRunningCore(
        at url: URL,
        recordedArgumentsURL: URL? = nil,
        validationFailureMarkerURL: URL? = nil
    ) throws -> String {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script: String
        let validationGuard: String
        if let validationFailureMarkerURL {
            let escapedMarker = validationFailureMarkerURL.path
                .replacingOccurrences(of: "'", with: "'\\''")
            validationGuard = """
            if [ "$1" = "-t" ]; then
              if [ -e '\(escapedMarker)' ]; then exit 1; fi
              exit 0
            fi
            """
        } else {
            validationGuard = """
            if [ "$1" = "-t" ]; then exit 0; fi
            """
        }
        if let recordedArgumentsURL {
            let escapedPath = recordedArgumentsURL.path.replacingOccurrences(of: "'", with: "'\\''")
            script = """
            #!/bin/sh
            \(validationGuard)
            printf '%s\\n' "$@" > '\(escapedPath)'
            while true; do /bin/sleep 1; done
            """
        } else {
            script = """
            #!/bin/sh
            \(validationGuard)
            while true; do /bin/sleep 1; done
            """
        }
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func launchDetachedCore(
        corePath: String,
        workDirectory: String,
        endpoint: String,
        configPath: String? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        var arguments = ["-d", workDirectory]
        if let configPath {
            arguments.append(contentsOf: ["-f", configPath])
        }
        arguments.append(contentsOf: ["-ext-ctl", endpoint])
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        usleep(100_000)
        return process
    }

    private func terminateForCleanup(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func recordedArguments(at url: URL) throws -> [String] {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n")
                    .map(String.init)
            }
            usleep(50_000)
        }

        XCTFail("Timed out waiting for recorded core arguments")
        return []
    }

    private func makeShortLivedCore(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("short-lived-mihomo")
        try "#!/bin/sh\nif [ \"$1\" = \"-t\" ]; then exit 0; fi\nsleep 0.1\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}
