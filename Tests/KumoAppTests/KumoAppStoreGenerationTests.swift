import XCTest
@testable import KumoApp
@testable import KumoCoreKit

final class KumoAppStoreGenerationTests: XCTestCase {
    func testIsolatedAppLaunchKeepsEveryPrivilegedPathUnderTestRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = KumoAppLaunchMode.makeController(isolatedRoot: root).paths

        XCTAssertTrue(paths.applicationSupportDirectory.path.hasPrefix(root.path))
        XCTAssertTrue(paths.privilegedRuntimeRootDirectory.path.hasPrefix(root.path))
        XCTAssertTrue(paths.privilegedServiceSupportDirectory.path.hasPrefix(root.path))
        XCTAssertTrue(paths.serviceExecutableFile.path.hasPrefix(root.path))
        XCTAssertTrue(paths.serviceLaunchDaemonPlistFile.path.hasPrefix(root.path))
    }

    func testOnboardingRequiresHelperBeforeOptionalIntegrations() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .helper, .cli, .skills, .done])
        XCTAssertEqual(OnboardingStep.helper.previous, .welcome)
        XCTAssertEqual(OnboardingStep.cli.previous, .helper)
        XCTAssertFalse(OnboardingStep.helper.allowsSkip)
        XCTAssertTrue(OnboardingStep.cli.allowsSkip)
        XCTAssertTrue(OnboardingStep.skills.allowsSkip)
    }

    @MainActor
    func testStartGuidanceDistinguishesMissingAndRepairableHelper() {
        XCTAssertEqual(
            KumoAppStore.helperSetupMessage(for: ServiceModeStatus()),
            "Install Kumo Helper before starting Mihomo."
        )
        XCTAssertEqual(
            KumoAppStore.helperSetupMessage(for: ServiceModeStatus(
                isInstalled: true,
                installationHealth: .partial
            )),
            "Repair Kumo Helper before starting Mihomo."
        )
        XCTAssertNil(KumoAppStore.helperSetupMessage(for: ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            installationHealth: .current
        )))
    }

    @MainActor
    func testInstallingUIStateDoesNotAuthorizeSkippingTerminationCleanup() {
        let store = KumoAppStore(appNotificationCoordinator: nil)

        store.isInstallingUpdate = true

        XCTAssertFalse(store.isUpdateInstallerReadyForTermination)
        store.isUpdateInstallerReadyForTermination = true
        XCTAssertTrue(store.isUpdateInstallerReadyForTermination)
    }

    @MainActor
    func testLateLogFailureCannotEraseLogsFromNewRuntimeGeneration() async {
        let loader = ControlledLogLoader()
        let store = KumoAppStore(recentLogsLoader: {
            try await loader.load()
        }, appNotificationCoordinator: nil)
        let currentLog = LogEntry(id: "new", message: "new runtime")

        let oldLoad = Task { @MainActor in
            await store.loadInspectData()
        }
        await loader.waitUntilStarted()
        _ = store.beginRuntimeTransition()
        store.logs = [currentLog]
        await loader.fail()
        await oldLoad.value

        XCTAssertEqual(store.logs, [currentLog])
    }

    @MainActor
    func testRuntimeTransitionClearsDelayTestingState() {
        let store = KumoAppStore(appNotificationCoordinator: nil)
        store.isTestingDelay = true

        _ = store.beginRuntimeTransition()

        XCTAssertFalse(store.isTestingDelay)
    }

    @MainActor
    func testAmbiguousFailedRuntimeRequiresPresentationTransition() {
        let status = CoreStatus(
            state: .failed,
            pid: 123,
            runtimeGeneration: UUID()
        )

        XCTAssertTrue(KumoAppStore.shouldTransitionRuntime(for: status))
        XCTAssertFalse(KumoAppStore.shouldTransitionRuntime(for: CoreStatus()))
    }

    @MainActor
    func testStoppedRuntimeWithEnabledSystemProxyStillRequiresReconciliation() {
        let status = CoreStatus(state: .stopped, systemProxyEnabled: true)

        XCTAssertTrue(KumoAppStore.shouldTransitionRuntime(for: status))
    }

    @MainActor
    func testOverrideListIncludesOnlyCurrentProfileAndGlobalItems() throws {
        let paths = KumoPaths(
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let profiles = ProfileRepository(paths: paths)
        _ = try profiles.saveProfile(
            Profile(
                name: "Profile A",
                source: .inline,
                rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
            ),
            preferredID: "profile-a",
            makeCurrent: false
        )
        _ = try profiles.saveProfile(
            Profile(
                name: "Profile B",
                source: .inline,
                rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
            ),
            preferredID: "profile-b",
            makeCurrent: true
        )
        let repository = OverrideRepository(paths: paths)
        _ = try repository.addLocalOverride(
            name: "A only",
            format: .yaml,
            content: "profile-marker: a",
            profileID: "profile-a"
        )
        _ = try repository.addLocalOverride(
            name: "B only",
            format: .yaml,
            content: "profile-marker: b",
            profileID: "profile-b"
        )
        _ = try repository.addLocalOverride(
            name: "Global",
            format: .yaml,
            content: "rules: []",
            isGlobal: true
        )
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let store = KumoAppStore(controller: controller, appNotificationCoordinator: nil)

        store.refreshOverrides()

        XCTAssertEqual(store.overrides.map(\.name), ["B only", "Global"])
    }
}

private actor ControlledLogLoader {
    private enum TestFailure: Error {
        case failed
    }

    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<[LogEntry], Error>?

    func load() async throws -> [LogEntry] {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func fail() {
        resultContinuation?.resume(throwing: TestFailure.failed)
        resultContinuation = nil
    }
}
