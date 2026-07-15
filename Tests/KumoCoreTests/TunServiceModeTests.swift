import XCTest
@testable import KumoCoreKit

final class TunServiceModeTests: XCTestCase {
    func testUnreachableHelperRepairRestoresProxyBeforeRuntimeTakeover() async throws {
        let harness = ServiceRepairHarness(
            status: CoreStatus(
                state: .failed,
                pid: 42,
                systemProxyEnabled: true,
                message: "legacy runtime"
            )
        )

        let result = try await UnreachableServiceRepairCoordinator.repair(
            operations: await harness.operations
        )

        XCTAssertTrue(result.isRunning)
        let events = await harness.events
        XCTAssertEqual(
            events,
            ["status", "disable-local-proxy", "status", "install-reset", "activate", "enable-helper-proxy", "persist"]
        )
    }

    func testUnreachableHelperRepairLeavesProxyOffWhenTakeoverFails() async throws {
        let harness = ServiceRepairHarness(
            status: CoreStatus(
                state: .failed,
                pid: 42,
                systemProxyEnabled: true,
                message: "legacy runtime"
            ),
            failActivation: true
        )

        do {
            _ = try await UnreachableServiceRepairCoordinator.repair(
                operations: await harness.operations
            )
            XCTFail("Expected repair activation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("activation failed"))
        }
        let events = await harness.events
        XCTAssertEqual(
            events,
            ["status", "disable-local-proxy", "status", "install-reset", "activate", "disable-helper-proxy"]
        )
    }

    func testUnreachableHelperRepairRejectsRunningButUnavailableInstallation() async throws {
        let harness = ServiceRepairHarness(
            status: CoreStatus(),
            installedStatus: ServiceModeStatus(
                isInstalled: true,
                isRunning: true,
                isAvailable: false,
                installationHealth: .partial
            )
        )

        do {
            _ = try await UnreachableServiceRepairCoordinator.repair(
                operations: await harness.operations
            )
            XCTFail("Expected repair to reject an unavailable Helper")
        } catch KumoError.serviceUnavailable(let message) {
            XCTAssertTrue(message.contains("verified compatible Helper"))
        }

        let events = await harness.events
        XCTAssertEqual(events, ["status", "install-reset"])
    }

    func testSetTunEnabledFailsAndRollsBackWhenServiceUnavailable() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = KumoController(paths: paths, useServiceBackend: false)

        do {
            _ = try await controller.setTunEnabled(true)
            XCTFail("Expected TUN enable to require service mode.")
        } catch KumoError.serviceUnavailable {
            let status = try controller.status()
            XCTAssertFalse(status.runtimeSettings?.tun?.isEnabled ?? false)
            XCTAssertTrue(status.tunStatus?.requiresService ?? false)
            XCTAssertNotNil(status.tunStatus?.lastError)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor ServiceRepairHarness {
    private var status: CoreStatus
    private let failActivation: Bool
    private let installedStatus: ServiceModeStatus
    private(set) var events: [String] = []

    init(
        status: CoreStatus,
        failActivation: Bool = false,
        installedStatus: ServiceModeStatus = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true
        )
    ) {
        self.status = status
        self.failActivation = failActivation
        self.installedStatus = installedStatus
    }

    var operations: UnreachableServiceRepairOperations {
        UnreachableServiceRepairOperations(
            localRuntimeStatus: {
                await self.record("status")
                return await self.status
            },
            disableLocalSystemProxy: {
                await self.record("disable-local-proxy")
                await self.markProxyDisabled()
            },
            installResettingProxyRecovery: {
                await self.record("install-reset")
                return self.installedStatus
            },
            activateSelectedProfile: {
                await self.record("activate")
                if self.failActivation {
                    throw KumoError.commandFailed("activation failed")
                }
            },
            enableHelperSystemProxy: {
                await self.record("enable-helper-proxy")
            },
            disableHelperSystemProxy: {
                await self.record("disable-helper-proxy")
            },
            persistServiceStatus: { _ in
                await self.record("persist")
            }
        )
    }

    private func record(_ event: String) {
        events.append(event)
    }

    private func markProxyDisabled() {
        status.systemProxyEnabled = false
    }
}
