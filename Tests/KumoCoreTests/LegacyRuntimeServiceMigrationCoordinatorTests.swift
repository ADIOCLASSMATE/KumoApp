import XCTest
@testable import KumoCoreKit

final class LegacyRuntimeServiceMigrationCoordinatorTests: XCTestCase {
    func testAuthorizationCompletesBeforeLegacyTrafficIsInterrupted() async throws {
        let harness = LegacyMigrationHarness()

        let result = try await LegacyRuntimeServiceMigrationCoordinator.migrate(
            operations: await harness.operations
        )

        XCTAssertTrue(result.isAvailable)
        let events = await harness.events
        XCTAssertEqual(events, [
            "status",
            "install-helper",
            "prepare-helper",
            "disable-local-proxy",
            "status",
            "stop-local",
            "status",
            "activate-helper",
            "enable-helper-proxy",
            "persist"
        ])
    }

    func testFailedTakeoverPreparationLeavesLegacyTrafficUntouched() async throws {
        let harness = LegacyMigrationHarness(failPreparationAttempts: 1)

        do {
            _ = try await LegacyRuntimeServiceMigrationCoordinator.migrate(
                operations: await harness.operations
            )
            XCTFail("Expected takeover preparation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("preflight failed"))
        }

        let events = await harness.events
        XCTAssertEqual(events, ["status", "install-helper", "prepare-helper", "status"])
        let status = await harness.status
        XCTAssertEqual(status.state, .running)
        XCTAssertTrue(status.systemProxyEnabled)
    }

    func testRetryAfterInstalledHelperCompletesLegacyTakeover() async throws {
        let harness = LegacyMigrationHarness(failPreparationAttempts: 1)

        do {
            _ = try await LegacyRuntimeServiceMigrationCoordinator.migrate(
                operations: await harness.operations
            )
            XCTFail("Expected the first takeover preparation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("preflight failed"))
        }

        let result = try await LegacyRuntimeServiceMigrationCoordinator.migrate(
            operations: await harness.operations
        )

        XCTAssertTrue(result.isAvailable)
        let status = await harness.status
        XCTAssertTrue(status.isStrictlyStoppedRuntime)
        let events = await harness.events
        XCTAssertEqual(events.filter { $0 == "install-helper" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "stop-local" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "activate-helper" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "persist" }.count, 1)
    }

    func testFailedAuthorizationDoesNotTouchLegacyRuntimeOrProxy() async throws {
        let harness = LegacyMigrationHarness(failInstall: true)

        do {
            _ = try await LegacyRuntimeServiceMigrationCoordinator.migrate(
                operations: await harness.operations
            )
            XCTFail("Expected installation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("authorization failed"))
        }

        let events = await harness.events
        XCTAssertEqual(events, ["status", "install-helper"])
        let status = await harness.status
        XCTAssertEqual(status.state, .running)
        XCTAssertTrue(status.systemProxyEnabled)
    }

    func testFailedLocalStopRestoresLegacySystemProxy() async throws {
        let harness = LegacyMigrationHarness(failStop: true)

        do {
            _ = try await LegacyRuntimeServiceMigrationCoordinator.migrate(
                operations: await harness.operations
            )
            XCTFail("Expected legacy stop to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stop failed"))
        }

        let events = await harness.events
        XCTAssertEqual(events, [
            "status",
            "install-helper",
            "prepare-helper",
            "disable-local-proxy",
            "status",
            "stop-local",
            "status",
            "enable-local-proxy"
        ])
        let status = await harness.status
        XCTAssertEqual(status.state, .running)
        XCTAssertTrue(status.systemProxyEnabled)
    }

    func testAmbiguousFailureInspectionStillAttemptsLegacyProxyRestore() async throws {
        let harness = LegacyMigrationHarness(
            failStop: true,
            failFailureStatusInspection: true
        )

        do {
            _ = try await LegacyRuntimeServiceMigrationCoordinator.migrate(
                operations: await harness.operations
            )
            XCTFail("Expected legacy stop to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stop failed"))
        }

        let events = await harness.events
        XCTAssertEqual(events.last, "enable-local-proxy")
        let status = await harness.status
        XCTAssertTrue(status.systemProxyEnabled)
    }

    func testFailedHelperActivationLeavesSystemProxyDisabled() async throws {
        let harness = LegacyMigrationHarness(failActivation: true)

        do {
            _ = try await LegacyRuntimeServiceMigrationCoordinator.migrate(
                operations: await harness.operations
            )
            XCTFail("Expected activation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("activation failed"))
        }

        let events = await harness.events
        XCTAssertEqual(events.suffix(3), ["activate-helper", "status", "disable-helper-proxy"])
        let status = await harness.status
        XCTAssertTrue(status.isStrictlyStoppedRuntime)
    }
}

private actor LegacyMigrationHarness {
    private(set) var status = CoreStatus(
        state: .running,
        pid: 42,
        systemProxyEnabled: true,
        readiness: .controllerReady,
        activeProfileID: "profile-a",
        runtimeGeneration: UUID(),
        configurationDigest: "digest"
    )
    private(set) var events: [String] = []
    private let failInstall: Bool
    private var remainingPreparationFailures: Int
    private let failStop: Bool
    private let failActivation: Bool
    private let failFailureStatusInspection: Bool
    private var statusCallCount = 0

    init(
        failInstall: Bool = false,
        failPreparationAttempts: Int = 0,
        failStop: Bool = false,
        failActivation: Bool = false,
        failFailureStatusInspection: Bool = false
    ) {
        self.failInstall = failInstall
        self.remainingPreparationFailures = max(0, failPreparationAttempts)
        self.failStop = failStop
        self.failActivation = failActivation
        self.failFailureStatusInspection = failFailureStatusInspection
    }

    var operations: LegacyRuntimeServiceMigrationOperations {
        LegacyRuntimeServiceMigrationOperations(
            localRuntimeStatus: {
                await self.record("status")
                if await self.shouldFailStatusInspection() {
                    throw KumoError.commandFailed("status inspection failed")
                }
                return await self.status
            },
            installHelper: {
                await self.record("install-helper")
                if self.failInstall {
                    throw KumoError.commandFailed("authorization failed")
                }
                return ServiceModeStatus(
                    isInstalled: true,
                    isRunning: true,
                    isAvailable: true,
                    installationHealth: .current
                )
            },
            prepareHelperTakeover: {
                await self.record("prepare-helper")
                if await self.consumePreparationFailure() {
                    throw KumoError.commandFailed("preflight failed")
                }
            },
            disableLocalSystemProxy: {
                await self.record("disable-local-proxy")
                await self.setProxyEnabled(false)
            },
            enableLocalSystemProxy: {
                await self.record("enable-local-proxy")
                await self.setProxyEnabled(true)
            },
            stopLocalRuntime: {
                await self.record("stop-local")
                if self.failStop {
                    throw KumoError.commandFailed("stop failed")
                }
                await self.markStopped()
            },
            activateSelectedProfile: {
                await self.record("activate-helper")
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

    private func consumePreparationFailure() -> Bool {
        guard remainingPreparationFailures > 0 else { return false }
        remainingPreparationFailures -= 1
        return true
    }

    private func shouldFailStatusInspection() -> Bool {
        statusCallCount += 1
        return failFailureStatusInspection && statusCallCount >= 3
    }

    private func setProxyEnabled(_ enabled: Bool) {
        status.systemProxyEnabled = enabled
    }

    private func markStopped() {
        status.state = .stopped
        status.pid = nil
        status.readiness = nil
        status.activeProfileID = nil
        status.runtimeGeneration = nil
        status.configurationDigest = nil
    }
}
