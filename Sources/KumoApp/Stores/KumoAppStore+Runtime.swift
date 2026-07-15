import Foundation
import KumoCoreKit

@MainActor
extension KumoAppStore {
    func refreshCoreCandidates() {
        do {
            coreCandidates = try controller.coreCandidates()
            if !coreCandidates.isEmpty {
                errorMessage = nil
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func setCorePath(_ path: String) {
        Task { @MainActor in
            do {
                try await controller.setCorePath(path)
                refreshStatus()
                refreshCoreCandidates()
                errorMessage = nil
            } catch {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func clearCorePath() {
        Task { @MainActor in
            do {
                try await controller.clearCorePath()
                refreshStatus()
                refreshCoreCandidates()
                errorMessage = nil
            } catch {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func installManagedCore() async {
        guard !isInstallingCore else { return }

        isInstallingCore = true
        defer { isInstallingCore = false }

        await performLoadingTask { [self] in
            let result = try await self.controller.installManagedCore()
            self.refreshCoreCandidates()
            self.refreshStatus()
            self.status.message = "Installed Mihomo core \(result.version)."
        }
    }

    func startCore() async {
        refreshServiceModeStatus()
        if let message = Self.helperSetupMessage(for: serviceModeStatus) {
            errorMessage = message
            showOnboarding = true
            appNotificationCoordinator?.postCoreStartFailed(error: message)
            return
        }

        beginLoading()
        defer { endLoading() }
        beginRuntimeTransition()

        do {
            let installResult = try await installManagedCoreIfNeeded()
            _ = try await controller.startAndWait()
            await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
            refreshOverrides()
            if let installResult {
                status.message = "Installed Mihomo core \(installResult.version) and started."
            }
            errorMessage = nil
            appNotificationCoordinator?.clearCoreStateNotifications()
        } catch {
            await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
            let message = displayMessage(for: error)
            errorMessage = message
            // Surface the failure as a system notification so users notice
            // it even when the main window is occluded or the menu bar
            // status item isn't visible.
            appNotificationCoordinator?.postCoreStartFailed(error: message)
        }
    }

    static func helperSetupMessage(for status: ServiceModeStatus) -> String? {
        guard !status.isAvailable else { return nil }
        return status.requiresRepair
            ? "Repair Kumo Helper before starting Mihomo."
            : "Install Kumo Helper before starting Mihomo."
    }

    func stopCore() async {
        beginLoading()
        defer { endLoading() }
        do {
            beginRuntimeTransition()
            status = try await controller.stopSafely()
            beginRuntimeTransition()
            proxyGroups = []
            rules = []
            connections = []
            proxyProviders = []
            ruleProviders = []
            coreConfiguration = CoreConfigurationSnapshot(mode: status.mode, mixedPort: status.proxyPorts.mixedPort)
            trafficSnapshot = TrafficSnapshot()
            trafficHistory = []
            refreshServiceModeStatus()
            refreshTunStatus()
            errorMessage = nil
            appNotificationCoordinator?.clearCoreStateNotifications()
        } catch {
            await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
            let message = displayMessage(for: error)
            errorMessage = message
            appNotificationCoordinator?.postCoreStopFailed(error: message)
        }
    }

    func prepareForTermination() async {
        stopUpdatePolling()
        stopTrafficStream()
        stopLogStream()
        proxyGeoTask?.cancel()
        proxyGeoTask = nil

        let result = await controller.shutdownActiveRuntime()
        status = result.status
        status.systemProxyEnabled = false
        proxyGroups = []
        rules = []
        connections = []
        proxyProviders = []
        ruleProviders = []
        coreConfiguration = CoreConfigurationSnapshot(mode: status.mode, mixedPort: status.proxyPorts.mixedPort)
        trafficSnapshot = TrafficSnapshot()
        trafficHistory = []
        refreshServiceModeStatus()
        refreshTunStatus()
        errorMessage = result.diagnostics.first
    }

    func setMode(_ mode: OutboundMode) async {
        guard mode != status.mode else { return }
        guard !isSwitchingMode else { return }

        let previousStatusMode = status.mode
        let previousConfigurationMode = coreConfiguration.mode
        var didApplyMode = false

        isSwitchingMode = true
        status.mode = mode
        coreConfiguration.mode = mode
        defer { isSwitchingMode = false }

        do {
            try await controller.setMode(mode)
            didApplyMode = true
            errorMessage = nil

            if status.state == .running {
                try await controller.closeConnections(matchingProxy: nil)
                connections = []
                await loadProxyGroups()
            }
        } catch {
            if !didApplyMode {
                status.mode = previousStatusMode
                coreConfiguration.mode = previousConfigurationMode
            }
            errorMessage = displayMessage(for: error)
        }
    }

    @discardableResult
    func beginRuntimeTransition() -> UInt64 {
        let generation = runtimeDataGeneration.beginTransition()
        isTestingDelay = false
        stopTrafficStream()
        stopLogStream()
        proxyGeoTask?.cancel()
        proxyGeoTask = nil
        proxyGroups = []
        rules = []
        connections = []
        proxyProviders = []
        ruleProviders = []
        return generation
    }

    func reconcileSelectedRuntimeIfNeeded() async {
        let forceReload = !hasReconciledSelectedRuntime
        guard !status.isStrictlyStoppedRuntime else {
            hasReconciledSelectedRuntime = true
            return
        }
        guard activatingProfileID == nil else { return }
        beginRuntimeTransition()
        do {
            _ = try await controller.reconcileSelectedProfileRuntime(forceReload: forceReload)
            hasReconciledSelectedRuntime = true
            refreshStatus()
            refreshProfiles()
        } catch {
            refreshStatus()
            refreshProfiles()
            errorMessage = displayMessage(for: error)
        }
    }

    func rehydrateRuntimePresentation(commitRuntimeGeneration: Bool = false) async {
        if commitRuntimeGeneration {
            beginRuntimeTransition()
        }
        refreshStatus()
        refreshProfiles()
        guard status.state == .running else { return }
        startTrafficStream()
        await loadProxyGroups()
        await loadCoreConfiguration()
        await loadInspectData()
        await loadResources()
    }

    func performRuntimeMutation<Result>(
        _ operation: @MainActor () async throws -> Result
    ) async throws -> (result: Result, didTransitionRuntime: Bool) {
        let liveStatus = try controller.status()
        let didTransitionRuntime = Self.shouldTransitionRuntime(for: liveStatus)
        if didTransitionRuntime {
            beginRuntimeTransition()
        }

        do {
            let result = try await operation()
            if didTransitionRuntime {
                await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
            } else {
                refreshStatus()
            }
            return (result, didTransitionRuntime)
        } catch {
            if didTransitionRuntime {
                await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
            } else {
                refreshStatus()
            }
            throw error
        }
    }

    static func shouldTransitionRuntime(for status: CoreStatus) -> Bool {
        !status.isStrictlyStoppedRuntime
    }

    @discardableResult
    func installManagedCoreIfNeeded() async throws -> CoreInstallResult? {
        let candidates = try controller.coreCandidates()
        coreCandidates = candidates

        let shouldInstall = candidates.isEmpty

        guard shouldInstall else {
            return nil
        }

        isInstallingCore = true
        defer { isInstallingCore = false }

        let result = try await controller.installManagedCore()
        coreCandidates = try controller.coreCandidates()
        return result
    }
}
