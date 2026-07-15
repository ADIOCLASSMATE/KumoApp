import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class StartupCancellationTests: XCTestCase {
    func testCancellingDirectStartCleansLaunchedGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = KumoPaths(applicationSupportDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coreURL = root.appendingPathComponent("fake-mihomo")
        let script = """
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = "-t" ]; then
            exit 0
          fi
        done
        while :; do :; done
        """
        try Data(script.utf8).write(to: coreURL)
        XCTAssertEqual(chmod(coreURL.path, 0o700), 0)
        let controllerPort = try await SubStorePortAllocator.availablePort(
            startingAt: Int.random(in: 43_000...44_000),
            allowLAN: false
        )
        let mixedPort = try await SubStorePortAllocator.availablePort(
            startingAt: Int.random(in: 44_001...45_000),
            allowLAN: false
        )
        try CoreStateStore(paths: paths).save(
            CoreStatus(
                corePath: coreURL.path,
                endpoint: ControllerEndpoint(port: controllerPort),
                proxyPorts: ProxyPortConfiguration(mixedPort: mixedPort),
                runtimeSettings: CoreRuntimeSettings(mixedPort: mixedPort)
            )
        )
        let controller = KumoController(paths: paths, useServiceBackend: false)
        defer {
            _ = try? controller.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let start = Task {
            try await controller.startAndWait()
        }

        let deadline = Date().addingTimeInterval(2)
        while try controller.status().runtimeGeneration == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let launchedPID = try XCTUnwrap(try controller.status().pid)
        start.cancel()

        do {
            _ = try await start.value
            XCTFail("Expected startup cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let stopped = try controller.status()
        XCTAssertNil(stopped.pid)
        XCTAssertNil(stopped.runtimeGeneration)
        XCTAssertFalse(isAlive(launchedPID))
    }

    private func isAlive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
