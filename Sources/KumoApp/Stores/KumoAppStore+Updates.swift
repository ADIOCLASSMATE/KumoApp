import AppKit
import Foundation
import KumoCoreKit

private let updatePollingIntervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

private enum AppUpdateCheckSource {
    case manual
    case polling
}

@MainActor
extension KumoAppStore {
    func startUpdatePolling() {
        guard updatePollingTask == nil else { return }
        updatePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: updatePollingIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.checkForUpdate(source: .polling)
            }
        }
    }

    func stopUpdatePolling() {
        updatePollingTask?.cancel()
        updatePollingTask = nil
    }

    func checkForUpdate() async {
        await checkForUpdate(source: .manual)
    }

    private func checkForUpdate(source: AppUpdateCheckSource) async {
        guard !isCheckingForUpdates, !isPollingForUpdates else { return }
        guard !isDownloadingUpdate, !isInstallingUpdate else { return }

        switch source {
        case .manual:
            isCheckingForUpdates = true
        case .polling:
            isPollingForUpdates = true
        }
        defer {
            switch source {
            case .manual:
                isCheckingForUpdates = false
            case .polling:
                isPollingForUpdates = false
            }
        }

        do {
            let result = try await controller.checkAppUpdate(
                manifestURL: preferences.updateManifestURL,
                currentVersion: bundleShortVersion,
                channel: preferences.updateChannel
            )
            lastUpdateCheckResult = result
            if source == .manual {
                updateStatusMessage = result.update == nil ? "Kumo is up to date." : nil
            }
            if let update = result.update {
                appNotificationCoordinator?.postUpdateAvailable(manifest: update)
            } else {
                appNotificationCoordinator?.clearUpdateNotifications()
            }
            if source == .manual {
                errorMessage = nil
            }
        } catch {
            if source == .manual {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func downloadAndInstallUpdate(_ manifest: AppUpdateManifest) async {
        guard !isDownloadingUpdate, !isInstallingUpdate else { return }
        guard manifest.canInstallAutomatically else {
            NSWorkspace.shared.open(manifest.downloadURL)
            return
        }

        isDownloadingUpdate = true
        updateDownloadProgress = 0
        lastNotifiedDownloadBucket = 0
        updateStatusMessage = "Downloading \(manifest.version)..."
        appNotificationCoordinator?.postUpdateProgress(
            manifest: manifest,
            message: "Downloading Kumo \(manifest.version)... 0%"
        )
        defer {
            isDownloadingUpdate = false
            updateDownloadProgress = nil
            lastNotifiedDownloadBucket = nil
        }

        do {
            let downloaded = try await controller.downloadAppUpdate(manifest: manifest) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateDownloadProgress = progress
                    let percent = Int(progress * 100)
                    let bucket = max(0, min(10, percent / 10))
                    if bucket != self.lastNotifiedDownloadBucket {
                        self.lastNotifiedDownloadBucket = bucket
                        self.appNotificationCoordinator?.postUpdateProgress(
                            manifest: manifest,
                            message: "Downloading Kumo \(manifest.version)... \(bucket * 10)%"
                        )
                    }
                }
            }

            updateStatusMessage = "Installing \(manifest.version)..."
            appNotificationCoordinator?.postUpdateProgress(
                manifest: manifest,
                message: "Installing Kumo \(manifest.version)..."
            )
            isUpdateInstallerReadyForTermination = false
            isInstallingUpdate = true
            try await controller.installAppUpdate(
                dmgURL: downloaded.fileURL,
                currentAppURL: Bundle.main.bundleURL,
                expectedVersion: downloaded.manifest.version,
                processID: ProcessInfo.processInfo.processIdentifier
            )
            isUpdateInstallerReadyForTermination = true
            updateStatusMessage = "Kumo will relaunch after installing \(manifest.version)."
            appNotificationCoordinator?.postRestartReady(manifest: manifest)
            NSApplication.shared.terminate(nil)
        } catch {
            isInstallingUpdate = false
            isUpdateInstallerReadyForTermination = false
            updateStatusMessage = nil
            appNotificationCoordinator?.clearUpdateNotifications()
            errorMessage = displayMessage(for: error)
        }
    }

    func handleNotificationAction(
        actionIdentifier: String,
        manifest: AppUpdateManifest?,
        version: String?
    ) async {
        let action = AppNotificationCoordinator.decodeAction(from: actionIdentifier)
        switch action {
        case .startUpdate:
            if let manifest = lastUpdateCheckResult?.update {
                await downloadAndInstallUpdate(manifest)
            } else if let manifest {
                await downloadAndInstallUpdate(manifest)
            } else {
                KumoAppContext.shared.openSettings()
            }
        case .remindLater:
            let version = version ?? lastUpdateCheckResult?.update?.version
            if let version {
                appNotificationCoordinator?.snoozeReminder(for: version)
                updateStatusMessage = "Kumo \(version) reminder snoozed for 6 hours."
            }
        case .restartNow:
            NSApplication.shared.terminate(nil)
        case .openApp:
            KumoAppContext.shared.openMainWindow()
        }
    }

    private var bundleShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}
