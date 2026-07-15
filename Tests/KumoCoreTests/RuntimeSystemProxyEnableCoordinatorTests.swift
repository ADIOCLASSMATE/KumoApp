import XCTest
@testable import KumoCoreKit

final class RuntimeSystemProxyEnableCoordinatorTests: XCTestCase {
    func testPostApplyGenerationConflictDisablesProxyAndRethrowsConflict() async throws {
        let harness = RuntimeSystemProxyEnableHarness(
            validationError: KumoError.runtimeGenerationConflict,
            recoveredStatus: CoreStatus(
                systemProxyEnabled: false,
                systemProxyRecoveryAction: nil
            )
        )

        do {
            _ = try await RuntimeSystemProxyEnableCoordinator.enable(
                operations: await harness.operations
            )
            XCTFail("Expected the generation conflict to be rethrown")
        } catch let error as KumoError {
            XCTAssertEqual(error, .runtimeGenerationConflict)
        }

        let events = await harness.events
        XCTAssertEqual(events, ["apply", "validate", "disable-with-journal", "status"])
    }

    func testFailedPostApplyRecoveryThrowsExplicitSafetyError() async throws {
        let harness = RuntimeSystemProxyEnableHarness(
            validationError: KumoError.runtimeGenerationConflict,
            recoveryError: KumoError.commandFailed("restore failed")
        )

        do {
            _ = try await RuntimeSystemProxyEnableCoordinator.enable(
                operations: await harness.operations
            )
            XCTFail("Expected a safety error")
        } catch KumoError.commandFailed(let message) {
            XCTAssertTrue(message.contains("safe disabled recovery state"))
        }

        let events = await harness.events
        XCTAssertEqual(events, ["apply", "validate", "disable-with-journal"])
    }

    func testIncompletePostApplyRecoveryIsRejected() async throws {
        let harness = RuntimeSystemProxyEnableHarness(
            validationError: KumoError.runtimeGenerationConflict,
            recoveredStatus: CoreStatus(
                systemProxyEnabled: false,
                systemProxyRecoveryAction: .completeDisable
            )
        )

        do {
            _ = try await RuntimeSystemProxyEnableCoordinator.enable(
                operations: await harness.operations
            )
            XCTFail("Expected a safety error")
        } catch KumoError.commandFailed(let message) {
            XCTAssertTrue(message.contains("safe disabled recovery state"))
        }

        let events = await harness.events
        XCTAssertEqual(events, ["apply", "validate", "disable-with-journal", "status"])
    }

    func testPostApplyRecoveryThatLeavesProxyEnabledIsRejected() async throws {
        let harness = RuntimeSystemProxyEnableHarness(
            validationError: KumoError.runtimeGenerationConflict,
            recoveredStatus: CoreStatus(
                systemProxyEnabled: true,
                systemProxyRecoveryAction: nil
            )
        )

        do {
            _ = try await RuntimeSystemProxyEnableCoordinator.enable(
                operations: await harness.operations
            )
            XCTFail("Expected a safety error")
        } catch KumoError.commandFailed(let message) {
            XCTAssertTrue(message.contains("safe disabled recovery state"))
        }

        let events = await harness.events
        XCTAssertEqual(events, ["apply", "validate", "disable-with-journal", "status"])
    }
}

private actor RuntimeSystemProxyEnableHarness {
    private let validationError: Error
    private let recoveryError: Error?
    private let finalStatus: CoreStatus
    private(set) var events: [String] = []

    init(
        validationError: Error,
        recoveryError: Error? = nil,
        recoveredStatus: CoreStatus = CoreStatus(systemProxyEnabled: true)
    ) {
        self.validationError = validationError
        self.recoveryError = recoveryError
        self.finalStatus = recoveredStatus
    }

    var operations: RuntimeSystemProxyEnableOperations {
        RuntimeSystemProxyEnableOperations(
            applySystemProxy: {
                await self.record("apply")
                return []
            },
            validatePostApplyGeneration: {
                await self.record("validate")
                throw self.validationError
            },
            disableUsingRecoveryJournal: {
                await self.record("disable-with-journal")
                if let recoveryError = self.recoveryError {
                    throw recoveryError
                }
            },
            recoveredStatus: {
                await self.record("status")
                return self.finalStatus
            }
        )
    }

    private func record(_ event: String) {
        events.append(event)
    }
}
