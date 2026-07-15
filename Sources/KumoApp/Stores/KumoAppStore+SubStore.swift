import Foundation
import KumoCoreKit

@MainActor
extension KumoAppStore {
    func refreshSubStoreStatus() {
        do {
            subStoreStatus = try controller.subStoreStatus()
            subStoreRuntimeStatus.configuration = subStoreStatus
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func refreshSubStoreRuntimeStatus() async {
        do {
            subStoreRuntimeStatus = try await controller.subStoreRuntimeStatus()
            subStoreStatus = subStoreRuntimeStatus.configuration
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func prepareSubStoreResources() {
        do {
            subStoreStatus = try controller.prepareSubStoreResources()
            subStoreRuntimeStatus.configuration = subStoreStatus
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func setSubStoreEnabled(_ isEnabled: Bool) async {
        await performLoadingTask { [self] in
            subStoreStatus = try await controller.setSubStoreEnabled(isEnabled)
            subStoreRuntimeStatus = try await controller.subStoreRuntimeStatus()
        }
    }

    func restartSubStoreService() async {
        await performLoadingTask { [self] in
            try await controller.restartSubStoreService()
            subStoreRuntimeStatus = try await controller.subStoreRuntimeStatus()
        }
    }

    func stopSubStoreService() async {
        await controller.stopSubStoreService()
        await refreshSubStoreRuntimeStatus()
    }

    func updateSubStoreStatus(_ status: SubStoreStatus) {
        do {
            try controller.updateSubStoreStatus(status)
            subStoreStatus = status
            subStoreRuntimeStatus.configuration = status
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func downloadSubStoreBundle(kind: SubStoreBundleKind, urlString: String) async {
        guard let url = URL(string: urlString) else {
            errorMessage = "Enter a valid Sub-Store bundle URL."
            return
        }

        await performLoadingTask { [self] in
            subStoreStatus = try await controller.downloadSubStoreBundle(kind: kind, from: url)
        }
    }

    func loadSubStoreEntries() async {
        do {
            async let subscriptions = controller.subStoreEntries(kind: .subscription)
            async let collections = controller.subStoreEntries(kind: .collection)
            let loadedSubscriptions = try await subscriptions
            let loadedCollections = try await collections
            subStoreEntries = loadedSubscriptions + loadedCollections
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func importSubStoreProfile(path: String, name: String?, useProxy: Bool) async {
        await performLoadingTask { [self] in
            let summary = try await controller.importSubStoreProfile(path: path, name: name, useProxy: useProxy)
            _ = try await installManagedCoreIfNeeded()
            refreshProfiles()
            try await activateProfileTransaction(
                id: summary.id,
                policy: .ensureRunning,
                message: "Imported Sub-Store profile and activated it."
            )
        }
    }

    var subStoreLogURL: URL {
        controller.paths.subStoreLogFile
    }
}
