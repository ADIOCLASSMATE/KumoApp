import Foundation
import KumoCoreKit

@MainActor
extension KumoAppStore {
    func refreshProfiles() {
        do {
            profiles = try controller.profiles()
            currentProfile = try controller.currentProfile()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
        refreshProfilePreview()
    }

    func importRemoteProfile(urlString: String, useProxy: Bool) async {
        guard let url = URL(string: urlString), !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a valid profile URL."
            return
        }

        isImportingProfile = true
        defer { isImportingProfile = false }

        await performLoadingTask { [self] in
            let summary = try await controller.refreshProfile(from: url, useProxy: useProxy)
            let installResult = try await installManagedCoreIfNeeded()
            refreshProfiles()
            try await activateProfileTransaction(
                id: summary.id,
                policy: .ensureRunning,
                message: installResult.map {
                    "Imported profile, installed Mihomo core \($0.version), and activated it."
                } ?? "Imported profile and activated it."
            )
        }
    }

    func importLocalProfile(from url: URL) async {
        await performLoadingTask { [self] in
            let summary = try await controller.importProfile(from: url)
            let installResult = try await installManagedCoreIfNeeded()
            refreshProfiles()
            try await activateProfileTransaction(
                id: summary.id,
                policy: .ensureRunning,
                message: installResult.map {
                    "Imported profile, installed Mihomo core \($0.version), and activated it."
                } ?? "Imported profile and activated it."
            )
        }
    }

    func profileContent(id: String) -> String? {
        do {
            return try controller.profileContent(id: id)
        } catch {
            errorMessage = displayMessage(for: error)
            return nil
        }
    }

    func refreshOverrides() {
        do {
            let currentProfileID = try controller.currentProfile().id
            overrides = try controller.overrides().filter {
                $0.isGlobal || $0.profileID == currentProfileID
            }
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func overrideContent(id: String) -> String? {
        do {
            return try controller.overrideContent(id: id)
        } catch {
            errorMessage = displayMessage(for: error)
            return nil
        }
    }

    func addLocalOverride(
        name: String,
        format: OverrideFormat,
        content: String,
        isGlobal: Bool
    ) async {
        await performLoadingTask { [self] in
            _ = try await performOverrideMutation {
                try await controller.addLocalOverride(
                    name: name,
                    format: format,
                    content: content,
                    isGlobal: isGlobal
                )
            }
        }
    }

    func addRemoteOverride(urlString: String, format: OverrideFormat, isGlobal: Bool) async {
        guard let url = URL(string: urlString) else {
            errorMessage = "Enter a valid override URL."
            return
        }

        await performLoadingTask { [self] in
            _ = try await performOverrideMutation {
                try await controller.addRemoteOverride(url: url, format: format, isGlobal: isGlobal)
            }
        }
    }

    func updateOverride(_ item: OverrideItem, content: String?) async {
        await performLoadingTask { [self] in
            _ = try await performOverrideMutation {
                try await controller.updateOverride(item, content: content)
            }
        }
    }

    func deleteOverride(_ item: OverrideItem) async {
        await performLoadingTask { [self] in
            _ = try await performOverrideMutation {
                try await controller.deleteOverride(id: item.id)
            }
        }
    }

    func reorderOverrides(ids: [String]) async {
        await performLoadingTask { [self] in
            _ = try await performOverrideMutation {
                try await controller.reorderOverrides(ids: ids)
            }
        }
    }

    func updateProfile(
        id: String,
        name: String,
        remoteURLString: String?,
        autoUpdate: Bool,
        useProxy: Bool,
        rawYAML: String
    ) async {
        await performLoadingTask { [self] in
            let trimmedURL = remoteURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let remoteURL = trimmedURL.isEmpty ? nil : URL(string: trimmedURL)
            if !trimmedURL.isEmpty, remoteURL == nil {
                throw KumoError.invalidArguments("Enter a valid subscription URL.")
            }

            guard self.activatingProfileID == nil else {
                throw KumoError.commandFailed("Another profile operation is already in progress.")
            }
            let wasCurrent = try self.controller.currentProfile().id == id
            self.activatingProfileID = id
            defer { self.activatingProfileID = nil }
            if wasCurrent { self.beginRuntimeTransition() }

            do {
                _ = try await self.controller.updateProfileAndActivate(
                    id: id,
                    name: name,
                    remoteURL: remoteURL,
                    autoUpdate: autoUpdate,
                    useProxy: useProxy,
                    rawYAML: rawYAML
                )
                await self.rehydrateRuntimePresentation(commitRuntimeGeneration: wasCurrent)
                self.status.message = "Profile updated."
            } catch {
                if wasCurrent {
                    await self.rehydrateRuntimePresentation(commitRuntimeGeneration: true)
                } else {
                    self.refreshProfiles()
                }
                throw error
            }
        }
    }

    func refreshProfile(_ profile: ProfileSummary) async {
        await performLoadingTask { [self] in
            guard self.activatingProfileID == nil else {
                throw KumoError.commandFailed("Another profile operation is already in progress.")
            }
            let wasCurrent = try self.controller.currentProfile().id == profile.id
            self.activatingProfileID = profile.id
            defer { self.activatingProfileID = nil }
            if wasCurrent { self.beginRuntimeTransition() }

            do {
                _ = try await self.controller.refreshProfileAndActivate(id: profile.id)
                await self.rehydrateRuntimePresentation(commitRuntimeGeneration: wasCurrent)
                self.status.message = "Profile refreshed."
            } catch {
                if wasCurrent {
                    await self.rehydrateRuntimePresentation(commitRuntimeGeneration: true)
                } else {
                    self.refreshProfiles()
                }
                throw error
            }
        }
    }

    func deleteProfile(_ profile: ProfileSummary) async {
        await performLoadingTask { [self] in
            guard self.activatingProfileID == nil else {
                throw KumoError.commandFailed("Another profile operation is already in progress.")
            }
            let wasCurrent = try self.controller.currentProfile().id == profile.id
            self.activatingProfileID = profile.id
            defer { self.activatingProfileID = nil }
            if wasCurrent { self.beginRuntimeTransition() }

            do {
                _ = try await self.controller.deleteProfileAndActivate(id: profile.id)
                await self.rehydrateRuntimePresentation(commitRuntimeGeneration: wasCurrent)
                self.status.message = "Profile deleted."
            } catch {
                if wasCurrent {
                    await self.rehydrateRuntimePresentation(commitRuntimeGeneration: true)
                } else {
                    self.refreshProfiles()
                }
                throw error
            }
        }
    }

    func selectProfile(_ profile: ProfileSummary) async {
        await performLoadingTask { [self] in
            try await self.activateProfileTransaction(
                id: profile.id,
                policy: .preserveRunState,
                message: "Profile activated."
            )
        }
    }

    func refreshDueProfiles() async {
        guard activatingProfileID == nil else { return }
        var needsRuntimeRehydration = false
        do {
            let dueIDs = try controller.dueProfileIDs()
            guard !dueIDs.isEmpty else { return }
            let currentID = try controller.currentProfile().id
            let liveStatus = try controller.status()
            needsRuntimeRehydration = dueIDs.contains(currentID)
                && Self.shouldTransitionRuntime(for: liveStatus)
            if needsRuntimeRehydration {
                beginRuntimeTransition()
            }

            let refreshed = try await controller.refreshDueProfiles()
            guard !refreshed.isEmpty else {
                if needsRuntimeRehydration {
                    await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
                }
                return
            }

            await rehydrateRuntimePresentation(commitRuntimeGeneration: needsRuntimeRehydration)
            status.message = "Profiles auto-updated."
        } catch {
            if needsRuntimeRehydration {
                await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
            } else {
                refreshProfiles()
            }
            errorMessage = displayMessage(for: error)
        }
    }

    private func performOverrideMutation<Result>(
        _ operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        do {
            let (result, _) = try await performRuntimeMutation(operation)
            refreshOverrides()
            return result
        } catch {
            refreshOverrides()
            throw error
        }
    }

    func activateProfileTransaction(
        id: String,
        policy: ProfileRunPolicy,
        forceReload: Bool = false,
        message: String
    ) async throws {
        guard activatingProfileID == nil else {
            throw KumoError.commandFailed("Another profile activation is already in progress.")
        }
        activatingProfileID = id
        beginRuntimeTransition()
        defer { activatingProfileID = nil }

        do {
            _ = try await controller.activateProfile(
                id: id,
                policy: policy,
                forceReload: forceReload
            )
            await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
            status.message = message
        } catch {
            await rehydrateRuntimePresentation(commitRuntimeGeneration: true)
            throw error
        }
    }
}
