import Foundation
import XCTest
@testable import KumoCoreKit

final class ProfileActivationCoordinatorTests: XCTestCase {
    func testActivationValidatesCandidateBeforeTouchingRunningRuntime() async throws {
        let harness = ActivationHarness(currentID: "a", failValidationFor: "b")
        let coordinator = ProfileActivationCoordinator()
        let operations = await harness.operations

        await XCTAssertThrowsActivationError {
            _ = try await coordinator.activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: operations
            )
        }

        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.currentID, "a")
        XCTAssertEqual(snapshot.launches, [])
    }

    func testFailedTargetActivationRestoresPreviousRunningProfile() async throws {
        let harness = ActivationHarness(currentID: "a", failFirstLaunchFor: "b")
        let coordinator = ProfileActivationCoordinator()
        let operations = await harness.operations

        await XCTAssertThrowsActivationError {
            _ = try await coordinator.activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: operations
            )
        }

        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.currentID, "a")
        XCTAssertEqual(snapshot.launches, ["b", "a"])
    }

    func testSuccessfulActivationCommitsSelectionAfterRuntimeIsReady() async throws {
        let harness = ActivationHarness(currentID: "a")
        let coordinator = ProfileActivationCoordinator()
        let operations = await harness.operations

        let result = try await coordinator.activate(
            profileID: "b",
            policy: .preserveRunState,
            operations: operations
        )
        let snapshot = await harness.snapshot()

        XCTAssertEqual(result.profileID, "b")
        XCTAssertEqual(result.previousProfileID, "a")
        XCTAssertTrue(result.didRestart)
        XCTAssertEqual(snapshot.currentID, "b")
        XCTAssertEqual(snapshot.launches, ["b"])
        XCTAssertEqual(snapshot.events, ["validate:b", "launch:b", "verify:b", "commit:b"])
    }
}

private actor ActivationHarness {
    private(set) var currentID: String
    private(set) var launches: [String] = []
    private(set) var events: [String] = []
    private let failValidationFor: String?
    private let failFirstLaunchFor: String?
    private var didFailLaunch = false

    init(currentID: String, failValidationFor: String? = nil, failFirstLaunchFor: String? = nil) {
        self.currentID = currentID
        self.failValidationFor = failValidationFor
        self.failFirstLaunchFor = failFirstLaunchFor
    }

    var operations: ProfileActivationOperations {
        ProfileActivationOperations(
            currentProfileID: { await self.currentID },
            loadProfile: { id in
                Profile(
                    name: id.uppercased(),
                    source: .inline,
                    rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
                )
            },
            validateProfile: { profile, id in
                await self.record("validate:\(id)")
                if id == self.failValidationFor {
                    throw KumoError.invalidArguments("Invalid candidate profile.")
                }
                _ = profile
            },
            status: { CoreStatus(state: .running, pid: 42, readiness: .controllerReady) },
            startAndWait: { _, id in try await self.launch(id) },
            restartAndWait: { _, id in try await self.launch(id) },
            stop: { CoreStatus() },
            verifyRuntime: { id in await self.record("verify:\(id)") },
            setCurrentProfile: { id in await self.commit(id) }
        )
    }

    private func launch(_ id: String) throws -> CoreStatus {
        launches.append(id)
        events.append("launch:\(id)")
        if id == failFirstLaunchFor, !didFailLaunch {
            didFailLaunch = true
            throw KumoError.commandFailed("Target launch failed.")
        }
        return CoreStatus(state: .running, pid: Int32(100 + launches.count), readiness: .controllerReady)
    }

    private func record(_ event: String) {
        events.append(event)
    }

    private func commit(_ id: String) {
        currentID = id
        events.append("commit:\(id)")
    }

    func snapshot() -> (currentID: String, launches: [String], events: [String]) {
        (currentID, launches, events)
    }
}

private func XCTAssertThrowsActivationError(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
