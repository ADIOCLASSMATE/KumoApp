import Foundation
import Observation
import KumoCoreKit

@MainActor
@Observable
final class KumoAppStore {
    var status = CoreStatus()
    var proxyGroups: [ProxyGroup] = []
    /// Read-only proxy groups parsed from the current profile YAML, used as
    /// a fallback render source for the Overview sidebar while the core is
    /// stopped. Refreshed alongside `refreshProfiles()` and after every
    /// `loadProxyGroups()` call so the preview is always current.
    var profilePreviewGroups: [ProxyGroup] = []
    var profiles: [ProfileSummary] = []
    var currentProfile: ProfileSummary?
    var coreConfiguration = CoreConfigurationSnapshot()
    var trafficSnapshot = TrafficSnapshot()
    /// Rolling 60-sample buffer of throughput data points (~60 s at
    /// mihomo's 1 Hz `/traffic` stream). Used by the Overview Traffic card
    /// to render a sparkline when expanded. Reset whenever the core stops
    /// or the stream errors out.
    var trafficHistory: [TrafficSample] = []
    var rules: [RuleEntry] = []
    var connections: [ConnectionEntry] = []
    var logs: [LogEntry] = []
    var proxyProviders: [ProxyProviderEntry] = []
    var ruleProviders: [RuleProviderEntry] = []
    var overrides: [OverrideItem] = []
    var subStoreStatus = SubStoreStatus()
    var subStoreRuntimeStatus = SubStoreRuntimeStatus()
    var subStoreEntries: [SubStoreEntry] = []
    var serviceModeStatus = ServiceModeStatus()
    var tunStatus = TunStatus()
    var coreCandidates: [CoreCandidate] = []
    var preferences = UserPreferences()
    /// Reference to the localization manager so `loadPreferences()` can sync
    /// the language preference when it is refreshed from disk.
    var localizationManager: LocalizationManager?
    /// Drives the first-run onboarding sheet attached at the root view.
    /// `loadPreferences()` flips this on when `preferences.hasCompletedOnboarding`
    /// is false; `completeOnboarding()` and `reopenOnboarding()` are the only
    /// authorized state transitions.
    var showOnboarding = false
    var errorMessage: String?
    var isLoading = false
    var isSwitchingMode = false
    var isImportingProfile = false
    var isInstallingCore = false
    var isTestingDelay = false
    var isStreamingLogs = false
    var isCheckingForUpdates = false
    var isDownloadingUpdate = false
    var isInstallingUpdate = false
    /// Only becomes true after the detached installer has been successfully
    /// scheduled. `isInstallingUpdate` starts earlier for UI progress and must
    /// never by itself authorize AppKit to skip normal runtime shutdown.
    var isUpdateInstallerReadyForTermination = false
    var updateDownloadProgress: Double?
    var updateStatusMessage: String?
    var lastUpdateCheckResult: AppUpdateCheckResult?
    var activatingProfileID: String?

    let controller: KumoController
    let recentLogsLoader: @Sendable () async throws -> [LogEntry]
    let appNotificationCoordinator: AppNotificationCoordinator?
    let proxyGeoLookup: ProxyGeoLookup

    private var loadingTaskCount = 0
    var trafficStreamTask: Task<Void, Never>?
    var logStreamTask: Task<Void, Never>?
    var lastNotifiedDownloadBucket: Int?
    var proxyGeoTask: Task<Void, Never>?
    var updatePollingTask: Task<Void, Never>?
    var isPollingForUpdates = false
    var hasReconciledSelectedRuntime = false
    var runtimeDataGeneration = RuntimeDataGeneration()

    init(
        controller: KumoController = KumoController(),
        recentLogsLoader: (@Sendable () async throws -> [LogEntry])? = nil,
        appNotificationCoordinator: AppNotificationCoordinator? = .shared
    ) {
        self.controller = controller
        self.recentLogsLoader = recentLogsLoader ?? { try controller.recentLogs() }
        self.appNotificationCoordinator = appNotificationCoordinator
        self.proxyGeoLookup = ProxyGeoLookup(cacheURL: controller.paths.proxyGeoCacheFile)
    }

    func refreshAll() async {
        refreshStatus()
        refreshProfiles()
        await reconcileSelectedRuntimeIfNeeded()
        syncTrafficStreamWithStatus()
        await refreshDueProfiles()
        let automaticRefreshError = errorMessage
        refreshCoreCandidates()
        refreshProfiles()
        loadPreferences()
        await loadProxyGroups()
        await loadCoreConfiguration()
        await loadInspectData()
        await loadResources()
        refreshOverrides()
        await refreshSubStoreRuntimeStatus()
        refreshServiceModeStatus()
        refreshTunStatus()
        if let automaticRefreshError {
            errorMessage = automaticRefreshError
        }
    }

    func refreshStatus() {
        do {
            status = try controller.status()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func performLoadingTask(_ operation: @MainActor () async throws -> Void) async {
        beginLoading()
        defer { endLoading() }

        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func beginLoading() {
        loadingTaskCount += 1
        isLoading = true
    }

    func endLoading() {
        loadingTaskCount = max(0, loadingTaskCount - 1)
        isLoading = loadingTaskCount > 0
    }

    func displayMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
