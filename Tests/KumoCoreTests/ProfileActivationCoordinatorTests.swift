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

    func testPreflightFailureDoesNotRequestRuntimeSafetyCleanup() async throws {
        let harness = ActivationHarness(currentID: "a", failValidationFor: "b")

        do {
            _ = try await ProfileActivationCoordinator().activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: await harness.operations
            )
            XCTFail("Expected candidate validation to fail")
        } catch {
            XCTAssertFalse(error is ProfileActivationRuntimeUncertainError)
        }
    }

    func testInvalidCandidateDoesNotTouchHealthySystemProxyController() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "rules: [MATCH,DIRECT]"),
            preferredID: "current",
            makeCurrent: true
        )
        _ = try repository.saveProfile(
            Profile(
                name: "Invalid",
                source: .inline,
                rawYAML: "proxy-providers: invalid\nrules: [MATCH,DIRECT]"
            ),
            preferredID: "invalid"
        )
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            pid: 42,
            systemProxyEnabled: true,
            readiness: .controllerReady,
            activeProfileID: "current",
            runtimeGeneration: UUID()
        ))
        let counter = ProxyOperationCounter()
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: counter.runner
        )

        do {
            _ = try await controller.activateProfile(id: "invalid", policy: .preserveRunState)
            XCTFail("Expected invalid profile preflight to fail")
        } catch {
            // Expected.
        }

        XCTAssertEqual(counter.operationCount, 0)
        XCTAssertEqual(try repository.currentProfileIDValue(), "current")
        XCTAssertTrue(try CoreStateStore(paths: paths).load().systemProxyEnabled)
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
        XCTAssertEqual(snapshot.restarts, ["b", "a"])
        XCTAssertEqual(snapshot.starts, [])
    }

    func testFailedTargetRestartStartsPreviousProfileWhenRuntimeIsNowStrictlyStopped() async throws {
        let harness = ActivationHarness(
            currentID: "a",
            failFirstLaunchFor: "b",
            statusAfterFailedLaunch: CoreStatus()
        )

        await XCTAssertThrowsActivationError {
            _ = try await ProfileActivationCoordinator().activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: await harness.operations
            )
        }

        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.currentID, "a")
        XCTAssertEqual(snapshot.launches, ["b", "a"])
        XCTAssertEqual(snapshot.restarts, ["b"])
        XCTAssertEqual(snapshot.starts, ["a"])
    }

    func testFailedTargetRestartStartsPreviousProfileWhenCleanupLeavesFailedStateWithoutGeneration() async throws {
        let previousGeneration = UUID()
        let harness = ActivationHarness(
            currentID: "a",
            initialStatus: CoreStatus(
                state: .running,
                pid: 42,
                systemProxyEnabled: true,
                readiness: .controllerReady,
                activeProfileID: "a",
                runtimeGeneration: previousGeneration,
                configurationDigest: "a"
            ),
            failFirstLaunchFor: "b",
            statusAfterFailedLaunch: CoreStatus(
                state: .failed,
                systemProxyEnabled: true,
                message: "Candidate startup failed after its process was cleaned up."
            )
        )

        await XCTAssertThrowsActivationError {
            _ = try await ProfileActivationCoordinator().activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: await harness.operations
            )
        }

        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.currentID, "a")
        XCTAssertEqual(snapshot.launches, ["b", "a"])
        XCTAssertEqual(snapshot.restarts, ["b"])
        XCTAssertEqual(snapshot.starts, ["a"])
        XCTAssertEqual(snapshot.systemProxyRestores, 1)
    }

    func testVerifiedRollbackDoesNotRequestRuntimeSafetyCleanup() async throws {
        let harness = ActivationHarness(currentID: "a", failFirstLaunchFor: "b")

        do {
            _ = try await ProfileActivationCoordinator().activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: await harness.operations
            )
            XCTFail("Expected target activation to fail")
        } catch {
            XCTAssertFalse(error is ProfileActivationRuntimeUncertainError)
        }
    }

    func testFailedRollbackRequestsRuntimeSafetyCleanup() async throws {
        let harness = ActivationHarness(
            currentID: "a",
            failFirstLaunchFor: "b",
            failRollback: true
        )

        do {
            _ = try await ProfileActivationCoordinator().activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: await harness.operations
            )
            XCTFail("Expected rollback to fail")
        } catch {
            XCTAssertTrue(error is ProfileActivationRuntimeUncertainError)
        }
    }

    func testFailedTargetActivationRestoresPreviousSystemProxyAfterRuntimeRollback() async throws {
        let harness = ActivationHarness(
            currentID: "a",
            initialStatus: CoreStatus(
                state: .running,
                pid: 42,
                systemProxyEnabled: true,
                readiness: .controllerReady,
                activeProfileID: "a"
            ),
            failFirstLaunchFor: "b"
        )

        await XCTAssertThrowsActivationError {
            _ = try await ProfileActivationCoordinator().activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: await harness.operations
            )
        }

        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.currentID, "a")
        XCTAssertEqual(snapshot.launches, ["b", "a"])
        XCTAssertEqual(snapshot.systemProxyRestores, 1)
        XCTAssertEqual(
            snapshot.events,
            ["validate:b", "validate:a", "launch:b", "launch:a", "verify:a", "restore-system-proxy"]
        )
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
        XCTAssertEqual(snapshot.events, ["validate:b", "validate:a", "launch:b", "verify:b", "commit:b"])
    }

    func testSameProfileWithMismatchedLiveGenerationIsReconciledBeforeSuccess() async throws {
        let harness = ActivationHarness(
            currentID: "a",
            initialStatus: CoreStatus(
                state: .running,
                pid: 42,
                readiness: .controllerReady,
                activeProfileID: "ikuuu"
            )
        )

        let result = try await ProfileActivationCoordinator().activate(
            profileID: "a",
            policy: .preserveRunState,
            operations: await harness.operations
        )
        let snapshot = await harness.snapshot()

        XCTAssertTrue(result.didRestart)
        XCTAssertEqual(snapshot.launches, ["a"])
        XCTAssertEqual(snapshot.events, ["validate:a", "launch:a", "verify:a", "commit:a"])
    }

    func testForceReloadRestartsEvenWhenSameProfileLooksHealthy() async throws {
        let harness = ActivationHarness(
            currentID: "same",
            initialStatus: CoreStatus(
                state: .running,
                pid: 42,
                readiness: .controllerReady,
                activeProfileID: "same"
            )
        )

        let result = try await ProfileActivationCoordinator().activate(
            profileID: "same",
            policy: .preserveRunState,
            forceReload: true,
            operations: await harness.operations
        )
        let snapshot = await harness.snapshot()

        XCTAssertTrue(result.didRestart)
        XCTAssertEqual(snapshot.restarts, ["same"])
        XCTAssertEqual(snapshot.currentID, "same")
    }

    func testSameHealthyProfileIsVerifiedBeforeFastPathReturns() async throws {
        let harness = ActivationHarness(
            currentID: "a",
            initialStatus: CoreStatus(
                state: .running,
                pid: 42,
                readiness: .controllerReady,
                activeProfileID: "a"
            )
        )

        let result = try await ProfileActivationCoordinator().activate(
            profileID: "a",
            policy: .preserveRunState,
            operations: await harness.operations
        )
        let snapshot = await harness.snapshot()

        XCTAssertFalse(result.didRestart)
        XCTAssertEqual(snapshot.launches, [])
        XCTAssertEqual(snapshot.events, ["validate:a", "verify:a"])
    }

    func testSameStoppedProfileWithEnsureRunningStartsRuntime() async throws {
        let harness = ActivationHarness(currentID: "a", initialStatus: CoreStatus())

        let result = try await ProfileActivationCoordinator().activate(
            profileID: "a",
            policy: .ensureRunning,
            operations: await harness.operations
        )
        let snapshot = await harness.snapshot()

        XCTAssertTrue(result.didRestart)
        XCTAssertEqual(snapshot.starts, ["a"])
        XCTAssertEqual(snapshot.restarts, [])
    }

    func testFailedUntrackedRuntimeIsRestartedBeforeSelectionCommits() async throws {
        let harness = ActivationHarness(
            currentID: "a",
            initialStatus: CoreStatus(
                state: .failed,
                message: "Kumo found untracked Mihomo processes."
            )
        )

        _ = try await ProfileActivationCoordinator().activate(
            profileID: "b",
            policy: .preserveRunState,
            operations: await harness.operations
        )
        let snapshot = await harness.snapshot()

        XCTAssertEqual(snapshot.currentID, "b")
        XCTAssertEqual(snapshot.starts, [])
        XCTAssertEqual(snapshot.restarts, ["b"])
        XCTAssertEqual(snapshot.events, ["validate:b", "validate:a", "launch:b", "verify:b", "commit:b"])
    }

    func testStoppedStatusWithStaleIdentityIsReconciledInsteadOfCommitOnly() async throws {
        let harness = ActivationHarness(
            currentID: "a",
            initialStatus: CoreStatus(
                state: .stopped,
                pid: 42,
                readiness: .processLaunched,
                runtimeGeneration: UUID()
            )
        )

        _ = try await ProfileActivationCoordinator().activate(
            profileID: "b",
            policy: .preserveRunState,
            operations: await harness.operations
        )
        let snapshot = await harness.snapshot()

        XCTAssertEqual(snapshot.restarts, ["b"])
        XCTAssertEqual(snapshot.currentID, "b")
    }

    func testStoppedStatusWithEnabledSystemProxyIsReconciledInsteadOfCommitOnly() async throws {
        let harness = ActivationHarness(
            currentID: "a",
            initialStatus: CoreStatus(
                state: .stopped,
                systemProxyEnabled: true
            )
        )

        _ = try await ProfileActivationCoordinator().activate(
            profileID: "b",
            policy: .preserveRunState,
            operations: await harness.operations
        )
        let snapshot = await harness.snapshot()

        XCTAssertEqual(snapshot.restarts, ["b"])
        XCTAssertEqual(snapshot.currentID, "b")
    }

    func testCancelledQueuedRuntimeOperationDoesNotExecuteAfterLockBecomesAvailable() async throws {
        let gate = ProfileOperationGate()
        let probe = GateProbe()
        let first = Task {
            try await gate.perform {
                await probe.markFirstEntered()
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        while !(await probe.firstEntered) {
            await Task.yield()
        }

        let second = Task {
            try await gate.perform {
                await probe.markSecondExecuted()
            }
        }
        second.cancel()

        try await first.value
        do {
            try await second.value
            XCTFail("Expected the queued operation to observe cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let secondExecuted = await probe.secondExecuted
        XCTAssertFalse(secondExecuted)
    }

    func testIndependentProfileFileLocksSerializeTheWholeTransaction() async throws {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profile-operation.lock")
        let locks = [
            ProfileOperationFileLock(url: lockURL),
            ProfileOperationFileLock(url: lockURL)
        ]
        let probe = FileLockProbe()

        async let first: Void = locks[0].perform {
            await probe.enter()
            try await Task.sleep(nanoseconds: 150_000_000)
            await probe.leave()
        }
        while !(await probe.hasEntered) {
            await Task.yield()
        }
        async let second: Void = locks[1].perform {
            await probe.enter()
            await probe.leave()
        }
        _ = try await (first, second)

        let maximumConcurrentCount = await probe.maximumConcurrentCount
        XCTAssertEqual(maximumConcurrentCount, 1)
    }

    func testControllersShareTheInProcessProfileGate() {
        let first = KumoController(paths: KumoPaths(applicationSupportDirectory: temporaryDirectory()))
        let second = KumoController(paths: KumoPaths(applicationSupportDirectory: temporaryDirectory()))

        XCTAssertTrue(first.profileOperationGate === second.profileOperationGate)
    }

    func testCancellationAfterCandidateLaunchRestoresPreviousRuntimeOutsideCancelledTask() async throws {
        let harness = CancellationActivationHarness()
        let task = Task {
            try await ProfileActivationCoordinator().activate(
                profileID: "b",
                policy: .preserveRunState,
                operations: await harness.operations
            )
        }

        await harness.waitForCandidateLaunch()
        task.cancel()
        await harness.releaseCandidateLaunch()

        do {
            _ = try await task.value
            XCTFail("Expected activation cancellation")
        } catch is CancellationError {
            // Expected after the detached rollback has completed.
        }

        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.currentID, "a")
        XCTAssertEqual(snapshot.launches, ["b", "a"])
        XCTAssertEqual(snapshot.verified, ["a"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class ProxyOperationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var operationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var runner: SystemProxyCommandRunner {
        SystemProxyCommandRunner(
            run: { [self] _ in increment() },
            captureOutput: { [self] _ in
                increment()
                return ""
            }
        )
    }

    private func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private actor GateProbe {
    private(set) var firstEntered = false
    private(set) var secondExecuted = false

    func markFirstEntered() {
        firstEntered = true
    }

    func markSecondExecuted() {
        secondExecuted = true
    }
}

private actor FileLockProbe {
    private var activeCount = 0
    private(set) var maximumConcurrentCount = 0
    private(set) var hasEntered = false

    func enter() {
        activeCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, activeCount)
        hasEntered = true
    }

    func leave() {
        activeCount -= 1
    }
}

private actor CancellationActivationHarness {
    private var currentID = "a"
    private var launches: [String] = []
    private var verified: [String] = []
    private var candidateLaunchEntered = false
    private var candidateContinuation: CheckedContinuation<Void, Never>?

    var operations: ProfileActivationOperations {
        ProfileActivationOperations(
            currentProfileID: { await self.currentID },
            loadProfile: { id in
                Profile(name: id, source: .inline, rawYAML: "rules: [MATCH,DIRECT]")
            },
            prepareRuntime: { profile, id in Self.runtimeSpec(profile: profile, id: id) },
            status: {
                CoreStatus(
                    state: .running,
                    pid: 42,
                    readiness: .controllerReady,
                    activeProfileID: "a"
                )
            },
            startAndWait: { spec in await self.launch(spec.profileID) },
            restartAndWait: { spec in await self.launch(spec.profileID) },
            stop: { CoreStatus() },
            verifyRuntime: { spec, _ in await self.verify(spec.profileID) },
            restoreSystemProxy: {},
            setCurrentProfile: { id in await self.commit(id) }
        )
    }

    func waitForCandidateLaunch() async {
        while !candidateLaunchEntered {
            await Task.yield()
        }
    }

    func releaseCandidateLaunch() {
        candidateContinuation?.resume()
        candidateContinuation = nil
    }

    private func launch(_ id: String) async -> CoreStatus {
        launches.append(id)
        if id == "b" {
            candidateLaunchEntered = true
            await withCheckedContinuation { continuation in
                candidateContinuation = continuation
            }
        }
        return CoreStatus(
            state: .running,
            pid: Int32(100 + launches.count),
            readiness: .controllerReady,
            activeProfileID: id
        )
    }

    private func verify(_ id: String) {
        verified.append(id)
    }

    private func commit(_ id: String) {
        currentID = id
    }

    private static func runtimeSpec(profile: Profile, id: String) -> RuntimeSpec {
        RuntimeSpec(
            profileID: id,
            profileYAML: profile.rawYAML,
            overrideYAMLs: [],
            endpoint: ControllerEndpoint(),
            proxyPorts: ProxyPortConfiguration(),
            mode: .rule,
            runtimeSettings: CoreRuntimeSettings(),
            configurationDigest: id
        )
    }

    func snapshot() -> (currentID: String, launches: [String], verified: [String]) {
        (currentID, launches, verified)
    }
}

private actor ActivationHarness {
    private(set) var currentID: String
    private(set) var launches: [String] = []
    private(set) var starts: [String] = []
    private(set) var restarts: [String] = []
    private(set) var events: [String] = []
    private(set) var systemProxyRestores = 0
    private let initialStatus: CoreStatus
    private let failValidationFor: String?
    private let failFirstLaunchFor: String?
    private let failRollback: Bool
    private let statusAfterFailedLaunch: CoreStatus?
    private var didFailLaunch = false

    init(
        currentID: String,
        initialStatus: CoreStatus = CoreStatus(
            state: .running,
            pid: 42,
            readiness: .controllerReady,
            activeProfileID: "a"
        ),
        failValidationFor: String? = nil,
        failFirstLaunchFor: String? = nil,
        failRollback: Bool = false,
        statusAfterFailedLaunch: CoreStatus? = nil
    ) {
        self.currentID = currentID
        self.initialStatus = initialStatus
        self.failValidationFor = failValidationFor
        self.failFirstLaunchFor = failFirstLaunchFor
        self.failRollback = failRollback
        self.statusAfterFailedLaunch = statusAfterFailedLaunch
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
            prepareRuntime: { profile, id in
                await self.record("validate:\(id)")
                if id == self.failValidationFor {
                    throw KumoError.invalidArguments("Invalid candidate profile.")
                }
                return Self.runtimeSpec(profile: profile, id: id)
            },
            status: { await self.runtimeStatus() },
            startAndWait: { spec in try await self.launch(spec.profileID, kind: .start) },
            restartAndWait: { spec in try await self.launch(spec.profileID, kind: .restart) },
            stop: { CoreStatus() },
            verifyRuntime: { spec, _ in await self.record("verify:\(spec.profileID)") },
            restoreSystemProxy: { await self.restoreSystemProxy() },
            setCurrentProfile: { id in await self.commit(id) }
        )
    }

    private enum LaunchKind {
        case start
        case restart
    }

    private func runtimeStatus() -> CoreStatus {
        if didFailLaunch, let statusAfterFailedLaunch {
            return statusAfterFailedLaunch
        }
        return initialStatus
    }

    private static func runtimeSpec(profile: Profile, id: String) -> RuntimeSpec {
        RuntimeSpec(
            profileID: id,
            profileYAML: profile.rawYAML,
            overrideYAMLs: [],
            endpoint: ControllerEndpoint(),
            proxyPorts: ProxyPortConfiguration(),
            mode: .rule,
            runtimeSettings: CoreRuntimeSettings(),
            configurationDigest: id
        )
    }

    private func launch(_ id: String, kind: LaunchKind) throws -> CoreStatus {
        launches.append(id)
        switch kind {
        case .start:
            starts.append(id)
        case .restart:
            restarts.append(id)
        }
        events.append("launch:\(id)")
        if id == failFirstLaunchFor, !didFailLaunch {
            didFailLaunch = true
            throw KumoError.commandFailed("Target launch failed.")
        }
        if failRollback, didFailLaunch, id == currentID {
            throw KumoError.commandFailed("Rollback launch failed.")
        }
        return CoreStatus(state: .running, pid: Int32(100 + launches.count), readiness: .controllerReady)
    }

    private func record(_ event: String) {
        events.append(event)
    }

    private func restoreSystemProxy() {
        systemProxyRestores += 1
        events.append("restore-system-proxy")
    }

    private func commit(_ id: String) {
        currentID = id
        events.append("commit:\(id)")
    }

    func snapshot() -> (
        currentID: String,
        launches: [String],
        starts: [String],
        restarts: [String],
        events: [String],
        systemProxyRestores: Int
    ) {
        (currentID, launches, starts, restarts, events, systemProxyRestores)
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
