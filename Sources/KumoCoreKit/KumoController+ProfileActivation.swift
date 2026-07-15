import Foundation

public extension KumoController {
    @discardableResult
    func startAndWait(corePath: String? = nil) async throws -> CoreStatus {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.startAndWaitWithoutGate(corePath: corePath)
        }
    }

    @discardableResult
    func restartAndWait(corePath: String? = nil) async throws -> CoreStatus {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.restartAndWaitWithoutGate(corePath: corePath)
        }
    }

    @discardableResult
    func stopSafely() async throws -> CoreStatus {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.stopSafelyWithoutGate()
        }
    }

    @discardableResult
    func activateProfile(
        id: String,
        policy: ProfileRunPolicy,
        forceReload: Bool = false
    ) async throws -> ProfileActivationResult {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.activateProfileWithoutGate(
                id: id,
                policy: policy,
                forceReload: forceReload
            )
        }
    }

    @discardableResult
    func updateProfileAndActivate(
        id: String,
        name: String,
        remoteURL: URL?,
        autoUpdate: Bool,
        useProxy: Bool,
        rawYAML: String
    ) async throws -> ProfileSummary {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.updateProfileAndActivateWithoutGate(
                id: id,
                name: name,
                remoteURL: remoteURL,
                autoUpdate: autoUpdate,
                useProxy: useProxy,
                rawYAML: rawYAML
            )
        }
    }

    @discardableResult
    func refreshProfileAndActivate(id: String) async throws -> ProfileSummary {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.refreshProfileAndActivateWithoutGate(id: id)
        }
    }

    @discardableResult
    func deleteProfileAndActivate(id: String) async throws -> Bool {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.deleteProfileAndActivateWithoutGate(id: id)
        }
    }

    @discardableResult
    func refreshDueProfiles() async throws -> [ProfileSummary] {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.refreshDueProfilesWithoutGate()
        }
    }

    @discardableResult
    func reconcileSelectedProfileRuntime(
        forceReload: Bool = false
    ) async throws -> ProfileActivationResult? {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let liveStatus = try self.status()
            guard !liveStatus.isStrictlyStoppedRuntime else { return nil }
            let selectedID = try self.profileRepository.currentProfileIDValue()
            return try await self.activateProfileWithoutGate(
                id: selectedID,
                policy: .preserveRunState,
                forceReload: forceReload
            )
        }
    }

    @discardableResult
    func addLocalOverride(
        name: String,
        format: OverrideFormat,
        content: String,
        isGlobal: Bool = false
    ) async throws -> OverrideItem {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.mutateOverridesWithoutGate(
                validateAllProfiles: isGlobal
            ) { profileID in
                try self.overrideRepository.addLocalOverride(
                    name: name,
                    format: format,
                    content: content,
                    isGlobal: isGlobal,
                    profileID: isGlobal ? nil : profileID
                )
            }
        }
    }

    @discardableResult
    func addRemoteOverride(
        url: URL,
        name: String? = nil,
        format: OverrideFormat = .yaml,
        fingerprint: String? = nil,
        isGlobal: Bool = false
    ) async throws -> OverrideItem {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            try await self.mutateOverridesWithoutGate(
                validateAllProfiles: isGlobal
            ) { profileID in
                try await self.overrideRepository.addRemoteOverride(
                    url: url,
                    name: name,
                    format: format,
                    fingerprint: fingerprint,
                    isGlobal: isGlobal,
                    profileID: isGlobal ? nil : profileID
                )
            }
        }
    }

    func updateOverride(_ item: OverrideItem, content: String? = nil) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let profileID = try self.profileRepository.currentProfileIDValue()
            guard let persistedItem = try self.overrideRepository.listOverrides()
                .first(where: { $0.id == item.id }) else {
                throw KumoError.invalidArguments("Override not found.")
            }
            let persistedProfileID = persistedItem.profileID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !persistedItem.isGlobal,
               let persistedProfileID,
               !persistedProfileID.isEmpty,
               persistedProfileID != profileID {
                throw KumoError.invalidArguments(
                    "Switch to the override's profile before editing it."
                )
            }

            try await self.mutateOverridesWithoutGate(
                validateAllProfiles: persistedItem.isGlobal || item.isGlobal
            ) { transactionProfileID in
                var scopedItem = item
                if scopedItem.isGlobal {
                    scopedItem.profileID = nil
                } else if persistedItem.isGlobal
                    || persistedProfileID?.isEmpty != false {
                    // Legacy unscoped items and items toggled from global become
                    // local to the profile that the user is currently editing.
                    scopedItem.profileID = transactionProfileID
                } else {
                    // Scope is repository-owned. Never trust a caller-provided
                    // profile identifier for an existing non-global override.
                    scopedItem.profileID = persistedProfileID
                }
                try self.overrideRepository.updateOverride(scopedItem, content: content)
            }
        }
    }

    func deleteOverride(id: String) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let profileID = try self.profileRepository.currentProfileIDValue()
            let persistedItem = try self.overrideRepository.listOverrides()
                .first(where: { $0.id == id })
            if let persistedItem,
               !persistedItem.isGlobal,
               let persistedProfileID = persistedItem.profileID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !persistedProfileID.isEmpty,
               persistedProfileID != profileID {
                throw KumoError.invalidArguments(
                    "Switch to the override's profile before deleting it."
                )
            }
            try await self.mutateOverridesWithoutGate(
                validateAllProfiles: persistedItem?.isGlobal == true
            ) { _ in
                try self.overrideRepository.deleteOverride(id: id)
            }
        }
    }

    func reorderOverrides(ids: [String]) async throws {
        try await profileOperationGate.perform(fileLock: profileOperationFileLock) {
            let profileID = try self.profileRepository.currentProfileIDValue()
            let items = try self.overrideRepository.listOverrides()
            var reordersGlobalOverride = false
            for id in ids {
                guard let item = items.first(where: { $0.id == id }) else {
                    throw KumoError.invalidArguments(
                        "Override order contains an unknown identifier."
                    )
                }
                if item.isGlobal {
                    reordersGlobalOverride = true
                } else if item.profileID != profileID {
                    throw KumoError.invalidArguments(
                        "Switch to the override's profile before reordering it."
                    )
                }
            }
            try await self.mutateOverridesWithoutGate(
                validateAllProfiles: reordersGlobalOverride
            ) { _ in
                try self.overrideRepository.reorderOverrides(ids: ids)
            }
        }
    }
}

extension KumoController {
    func startAndWaitWithoutGate(corePath: String?) async throws -> CoreStatus {
        if corePath != nil {
            _ = try runtimeBackendForMutation(corePath: corePath)
        }
        let profileID = try profileRepository.currentProfileIDValue()
        let profile = try await profileRepository.normalizedProfile(id: profileID)
        try await ensureServiceCoreAvailableIfNeeded()
        let runtimeSpec = try prepareRuntimeSpec(profile: profile, profileID: profileID)
        return try await launchAndWait(
            runtimeSpec: runtimeSpec,
            corePath: corePath,
            restart: false
        )
    }

    func restartAndWaitWithoutGate(corePath: String?) async throws -> CoreStatus {
        if corePath != nil {
            _ = try runtimeBackendForMutation(corePath: corePath)
        }
        let profileID = try profileRepository.currentProfileIDValue()
        let profile = try await profileRepository.normalizedProfile(id: profileID)
        try await ensureServiceCoreAvailableIfNeeded()
        let runtimeSpec = try prepareRuntimeSpec(profile: profile, profileID: profileID)
        return try await launchAndWait(
            runtimeSpec: runtimeSpec,
            corePath: corePath,
            restart: true
        )
    }

    func stopWithoutGate() async throws -> CoreStatus {
        try await stop(using: serviceClientForMutation())
    }

    func stopSafelyWithoutGate(
        expecting requestedExpectation: RuntimeGenerationExpectation? = nil
    ) async throws -> CoreStatus {
        let serviceClient: KumoServiceClient?
        do {
            serviceClient = try serviceClientForMutation()
        } catch {
            let serviceStatus = serviceManager.status()
            guard canRetireLegacyLocalRuntime(serviceStatus: serviceStatus) else {
                throw error
            }
            return try await retireLegacyLocalRuntime(
                expecting: requestedExpectation
            )
        }
        let liveStatus = try status(using: serviceClient)
        let expectation: RuntimeGenerationExpectation?
        if liveStatus.isStrictlyStoppedProcessState {
            expectation = nil
        } else if let requestedExpectation {
            expectation = requestedExpectation
        } else if let generation = liveStatus.runtimeGeneration {
            expectation = .matching(generation)
        } else {
            throw KumoError.commandFailed(
                "Kumo cannot stop Mihomo without an exact runtime generation."
            )
        }
        if let expectation {
            try expectation.validate(actualGeneration: liveStatus.runtimeGeneration)
        }
        let proxyWasEnabled = liveStatus.systemProxyEnabled
        if proxyWasEnabled {
            if let serviceClient {
                _ = try setSystemProxyThroughService(false, client: serviceClient)
            } else {
                _ = try await setSystemProxyLocally(false)
            }
        }

        do {
            let stopped = try await stop(using: serviceClient, expecting: expectation)
            guard !stopped.systemProxyEnabled else {
                throw KumoError.commandFailed("Kumo stopped Mihomo but could not confirm that system proxy is disabled.")
            }
            return stopped
        } catch {
            let stopError = error
            let observed = try? status(using: serviceClient)
            if proxyWasEnabled, observed.map({ !ProfileActivationCoordinator.isStrictlyStopped($0) }) == true {
                do {
                    if let serviceClient {
                        _ = try setSystemProxyThroughService(true, client: serviceClient)
                    } else {
                        _ = try await setSystemProxyLocally(true)
                    }
                } catch {
                    throw KumoError.commandFailed(
                        "Mihomo could not be stopped, and Kumo could not restore the previous system proxy state."
                    )
                }
            }
            throw stopError
        }
    }

    func activateProfileWithoutGate(
        id: String,
        policy: ProfileRunPolicy,
        forceReload: Bool = false
    ) async throws -> ProfileActivationResult {
        let operations = ProfileActivationOperations(
            currentProfileID: { try self.profileRepository.currentProfileIDValue() },
            loadProfile: { profileID in
                try await self.profileRepository.normalizedProfile(id: profileID)
            },
            prepareRuntime: { profile, profileID in
                try await self.ensureServiceCoreAvailableIfNeeded()
                return try self.prepareRuntimeSpec(profile: profile, profileID: profileID)
            },
            status: { try self.status() },
            startAndWait: { runtimeSpec in
                try await self.launchAndWait(
                    runtimeSpec: runtimeSpec,
                    corePath: nil,
                    restart: false,
                    cleanupProxyOnFailure: false
                )
            },
            restartAndWait: { runtimeSpec in
                try await self.launchAndWait(
                    runtimeSpec: runtimeSpec,
                    corePath: nil,
                    restart: true,
                    cleanupProxyOnFailure: false
                )
            },
            stop: { try await self.stopWithoutGate() },
            verifyRuntime: { runtimeSpec, launchedStatus in
                let serviceClient = try self.serviceClientForMutation()
                let observedStatus = try self.status(using: serviceClient)
                guard observedStatus.runtimeGeneration == launchedStatus.runtimeGeneration else {
                    throw KumoError.commandFailed(
                        "Mihomo runtime generation changed before profile activation could be committed."
                    )
                }
                _ = try observedStatus.activationReceipt(
                    expectedProfileID: runtimeSpec.profileID,
                    expectedConfigurationDigest: runtimeSpec.configurationDigest
                )
                _ = try await MihomoControllerClient(endpoint: observedStatus.endpoint).proxyGroups()
            },
            restoreSystemProxy: {
                _ = try await self.setSystemProxyWithoutGate(true)
            },
            setCurrentProfile: { profileID in
                try self.profileRepository.setCurrentProfile(id: profileID)
            }
        )

        do {
            return try await profileActivationCoordinator.activate(
                profileID: id,
                policy: policy,
                forceReload: forceReload,
                operations: operations
            )
        } catch {
            let activationError = error
            guard activationError is ProfileActivationRuntimeUncertainError else {
                // Candidate parsing/validation failures and failures whose
                // rollback was verified must not touch the healthy current
                // runtime or its System Proxy ownership.
                throw activationError
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await self.makeSystemProxySafeAfterRuntimeFailure()
                }.value
            } catch {
                throw KumoError.commandFailed(
                    "Profile activation failed, and Kumo could not make macOS System Proxy safe."
                )
            }
            throw activationError
        }
    }

    func updateProfileAndActivateWithoutGate(
        id: String,
        name: String,
        remoteURL: URL?,
        autoUpdate: Bool,
        useProxy: Bool,
        rawYAML: String
    ) async throws -> ProfileSummary {
        let snapshot = try profileRepository.snapshot(profileID: id)
        let runtimeWasRunning = try isRuntimeRunning()
        var activationAttempted = false

        do {
            let updated = try profileRepository.updateProfile(
                id: id,
                name: name,
                remoteURL: remoteURL,
                autoUpdate: autoUpdate,
                useProxy: useProxy,
                rawYAML: rawYAML
            )
            guard try profileRepository.currentProfileIDValue() == id else { return updated }
            activationAttempted = true
            _ = try await activateProfileWithoutGate(
                id: id,
                policy: .preserveRunState,
                forceReload: true
            )
            return try profileRepository.listProfiles().first(where: { $0.id == id }) ?? updated
        } catch {
            try await rollbackProfileMutation(
                snapshot,
                profileID: id,
                expectedCurrentID: id,
                restoreRuntime: activationAttempted,
                runtimeWasRunning: runtimeWasRunning,
                action: "update"
            )
            throw KumoError.commandFailed("The profile update could not be activated. The previous profile was restored.")
        }
    }

    func refreshProfileAndActivateWithoutGate(id: String) async throws -> ProfileSummary {
        let snapshot = try profileRepository.snapshot(profileID: id)
        let runtimeWasRunning = try isRuntimeRunning()
        var activationAttempted = false

        do {
            let refreshed = try await refreshProfile(id: id)
            // Selection may have changed while the remote request was in flight.
            // Only the profile that is current at commit time may alter the runtime.
            guard try profileRepository.currentProfileIDValue() == id else { return refreshed }
            activationAttempted = true
            _ = try await activateProfileWithoutGate(
                id: id,
                policy: .preserveRunState,
                forceReload: true
            )
            return try profileRepository.listProfiles().first(where: { $0.id == id }) ?? refreshed
        } catch {
            try await rollbackProfileMutation(
                snapshot,
                profileID: id,
                expectedCurrentID: id,
                restoreRuntime: activationAttempted,
                runtimeWasRunning: runtimeWasRunning,
                action: "refresh"
            )
            throw KumoError.commandFailed("The profile refresh could not be activated. The previous profile was restored.")
        }
    }

    func deleteProfileAndActivateWithoutGate(id: String) async throws -> Bool {
        let snapshot = try profileRepository.snapshot(profileID: id)
        let wasCurrent = try profileRepository.currentProfileIDValue() == id
        let runtimeWasRunning = try isRuntimeRunning()

        guard wasCurrent else {
            do {
                return try profileRepository.deleteProfile(id: id)
            } catch {
                try profileRepository.restore(snapshot)
                throw error
            }
        }

        let fallbackID = try profileRepository.fallbackProfileID(excluding: id)

        _ = try await activateProfileWithoutGate(
            id: fallbackID,
            policy: .preserveRunState,
            forceReload: false
        )

        do {
            _ = try profileRepository.deleteProfile(id: id)
            return true
        } catch {
            try await rollbackProfileMutation(
                snapshot,
                profileID: id,
                expectedCurrentID: fallbackID,
                restoreRuntime: true,
                runtimeWasRunning: runtimeWasRunning,
                action: "delete"
            )
            throw KumoError.commandFailed("The profile could not be deleted without changing the active runtime.")
        }
    }

    func refreshDueProfilesWithoutGate(now: Date = Date()) async throws -> [ProfileSummary] {
        let dueIDs = try profileRepository.dueRemoteProfileIDs(now: now)
        guard !dueIDs.isEmpty else { return [] }

        let snapshots = try Dictionary(
            uniqueKeysWithValues: dueIDs.map { id in
                (id, try profileRepository.snapshot(profileID: id))
            }
        )
        let runtimeWasRunning = try isRuntimeRunning()
        var refreshed: [ProfileSummary] = []
        var attemptedIDs: [String] = []

        do {
            for id in dueIDs {
                attemptedIDs.append(id)
                refreshed.append(try await refreshProfile(id: id))
            }
        } catch {
            do {
                for id in attemptedIDs.reversed() {
                    if let snapshot = snapshots[id] {
                        try profileRepository.restore(snapshot)
                    }
                }
            } catch {
                throw KumoError.commandFailed(
                    "Automatic profile refresh failed, and Kumo could not restore every profile it had already updated."
                )
            }
            throw error
        }

        let currentID = try profileRepository.currentProfileIDValue()
        guard refreshed.contains(where: { $0.id == currentID }),
              let currentSnapshot = snapshots[currentID] else {
            return refreshed
        }

        do {
            _ = try await activateProfileWithoutGate(
                id: currentID,
                policy: .preserveRunState,
                forceReload: true
            )
            return refreshed
        } catch {
            try await rollbackProfileMutation(
                currentSnapshot,
                profileID: currentID,
                expectedCurrentID: currentID,
                restoreRuntime: true,
                runtimeWasRunning: runtimeWasRunning,
                action: "automatic refresh"
            )
            throw KumoError.commandFailed(
                "The current profile could not be auto-updated. Its previous content and runtime were restored."
            )
        }
    }

    func rollbackProfileMutation(
        _ snapshot: ProfileRepositorySnapshot,
        profileID: String,
        expectedCurrentID: String,
        restoreRuntime: Bool,
        runtimeWasRunning: Bool,
        action: String
    ) async throws {
        do {
            try profileRepository.restore(snapshot)
        } catch {
            throw KumoError.commandFailed(
                "The profile \(action) failed, and Kumo could not restore the previous profile file."
            )
        }

        guard restoreRuntime,
              try profileRepository.currentProfileIDValue() == expectedCurrentID else {
            return
        }

        do {
            _ = try await activateProfileWithoutGate(
                id: profileID,
                policy: runtimeWasRunning ? .ensureRunning : .preserveRunState,
                forceReload: true
            )
        } catch {
            throw KumoError.commandFailed(
                "The previous profile file was restored, but Kumo could not restore its runtime after the \(action) failed."
            )
        }
    }

    func isRuntimeRunning() throws -> Bool {
        let runtimeStatus = try status()
        return runtimeStatus.state == .running || runtimeStatus.state == .starting
    }

    func mutateOverridesWithoutGate<Result: Sendable>(
        validateAllProfiles: Bool = false,
        _ mutation: @escaping @Sendable (String) async throws -> Result
    ) async throws -> Result {
        let profileID = try profileRepository.currentProfileIDValue()
        do {
            return try await OverrideMutationTransaction.perform(
                snapshot: {
                    try self.overrideRepository.snapshot()
                },
                runtimeNeedsReload: {
                    let liveStatus = try self.status()
                    return !ProfileActivationCoordinator.isStrictlyStopped(liveStatus)
                },
                mutate: {
                    try await mutation(profileID)
                },
                preflight: {
                    if validateAllProfiles {
                        try await self.preflightOverridesForAllProfiles()
                    } else {
                        try await self.preflightOverrides(for: profileID)
                    }
                },
                activateCandidate: {
                    _ = try await self.activateProfileWithoutGate(
                        id: profileID,
                        policy: .preserveRunState,
                        forceReload: true
                    )
                },
                restoreSnapshot: { snapshot in
                    try self.overrideRepository.restore(snapshot)
                },
                restoreRuntime: {
                    _ = try await self.activateProfileWithoutGate(
                        id: profileID,
                        policy: .ensureRunning,
                        forceReload: true
                    )
                }
            )
        } catch {
            let mutationError = error
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await self.makeSystemProxySafeAfterRuntimeFailure()
                }.value
            } catch {
                throw KumoError.commandFailed(
                    "The override update failed, and Kumo could not make macOS System Proxy safe."
                )
            }
            throw mutationError
        }
    }

    func preflightOverrides(for profileID: String) async throws {
        let (profile, _) = try await profileRepository.normalizedProfileForValidation(id: profileID)
        let status = try normalizedStatusForLaunch()
        _ = try RuntimeConfigBuilder(
            endpoint: status.endpoint,
            proxyPorts: status.proxyPorts,
            mode: status.mode,
            runtimeSettings: runtimeSettings(for: status)
        ).build(
            profile: profile,
            profileID: profileID,
            overrideYAMLs: try overrideRepository.activeYAMLs(for: profileID)
        )
    }

    func preflightOverridesForAllProfiles() async throws {
        for profile in try profileRepository.listProfiles() {
            try await preflightOverrides(for: profile.id)
        }
    }

    func prepareRuntimeSpec(profile: Profile, profileID: String) throws -> RuntimeSpec {
        let status = try normalizedStatusForLaunch()
        let serviceClient = try serviceClientForMutation()
        let overrideYAMLs = try overrideRepository.activeYAMLs(for: profileID)
        let runtimeSettings = runtimeSettings(for: status)
        let runtime = try RuntimeConfigBuilder(
            endpoint: status.endpoint,
            proxyPorts: status.proxyPorts,
            mode: status.mode,
            runtimeSettings: runtimeSettings,
            enforceManagedFeatureSettings: serviceClient != nil || privilegedRuntimeOwnership != nil
        ).build(
            profile: profile,
            profileID: profileID,
            overrideYAMLs: overrideYAMLs
        )
        return RuntimeSpec(
            profileID: profileID,
            profileYAML: profile.rawYAML,
            overrideYAMLs: overrideYAMLs,
            endpoint: status.endpoint,
            proxyPorts: status.proxyPorts,
            mode: status.mode,
            runtimeSettings: runtimeSettings,
            configurationDigest: runtime.configurationDigest
        )
    }

    func launchAndWait(
        runtimeSpec: RuntimeSpec,
        corePath: String?,
        restart: Bool,
        cleanupProxyOnFailure: Bool = true
    ) async throws -> CoreStatus {
        let status = try normalizedStatusForLaunch()
        let systemProxyWasEnabled = status.systemProxyEnabled
        let generationExpectation: RuntimeGenerationExpectation
        if restart {
            guard let generation = status.runtimeGeneration else {
                throw KumoError.commandFailed(
                    "Kumo cannot restart Mihomo without an exact runtime generation."
                )
            }
            generationExpectation = .matching(generation)
        } else {
            generationExpectation = .stopped
        }
        do {
            let backend = try runtimeBackendForMutation(
                corePath: corePath ?? (runtimeAuthority == .supervisor ? status.corePath : nil)
            )
            let launched = if restart {
                try await backend.restart(
                    runtimeSpec,
                    systemProxySettings: status.systemProxySettings,
                    expecting: generationExpectation
                )
            } else {
                try await backend.start(
                    runtimeSpec,
                    systemProxySettings: status.systemProxySettings,
                    expecting: generationExpectation
                )
            }

            let readyStatus: CoreStatus
            switch runtimeAuthority {
            case .serviceRequired:
                readyStatus = try persistServiceRuntimeMirror(launched.status)
            case .supervisor:
                try await waitForControllerReady(expectedProfileID: runtimeSpec.profileID)
                if systemProxyWasEnabled {
                    do {
                        _ = try await setSystemProxyLocally(
                            true,
                            expectedProfileID: runtimeSpec.profileID
                        )
                    } catch {
                        do {
                            _ = try await setSystemProxyLocally(false)
                        } catch {
                            throw KumoError.commandFailed(
                                "Mihomo restarted, but Kumo could not reapply or safely disable System Proxy."
                            )
                        }
                        throw error
                    }
                }
                readyStatus = try supervisor.status()
            }
            _ = try readyStatus.activationReceipt(
                expectedProfileID: runtimeSpec.profileID,
                expectedConfigurationDigest: runtimeSpec.configurationDigest
            )
            return readyStatus
        } catch {
            let launchError = error
            if launchError as? KumoError == .runtimeGenerationConflict {
                throw launchError
            }
            guard systemProxyWasEnabled, cleanupProxyOnFailure else {
                throw launchError
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await self.makeSystemProxySafeAfterRuntimeFailure()
                }.value
            } catch {
                throw KumoError.commandFailed(
                    "Mihomo failed to start, and Kumo could not make macOS System Proxy safe."
                )
            }
            throw launchError
        }
    }

    @_spi(KumoService)
    public func launchRuntimeAndWait(
        _ request: CoreRuntimeLaunchRequest,
        restart: Bool
    ) async throws -> CoreStatus {
        try ProfileContentNormalizer.validateMihomoYAML(request.spec.profileYAML)
        _ = try request.spec.validatedRuntimeConfig(enforceManagedFeatureSettings: true)
        if restart {
            _ = try request.expectedGeneration.requiredMatchingGeneration()
        } else {
            try request.expectedGeneration.requireStoppedOperation()
        }
        let systemProxyWasEnabled = try stateStore.load().systemProxyEnabled
        let configuration = request.launchConfiguration
        do {
            if restart {
                _ = try supervisor.restart(
                    configuration: configuration,
                    expecting: request.expectedGeneration
                )
            } else {
                _ = try supervisor.start(
                    configuration: configuration,
                    expecting: request.expectedGeneration
                )
            }
            try await waitForControllerReady(expectedProfileID: request.spec.profileID)
            let readyStatus = try supervisor.status()
            _ = try readyStatus.activationReceipt(
                expectedProfileID: request.spec.profileID,
                expectedConfigurationDigest: request.spec.configurationDigest
            )
            if systemProxyWasEnabled {
                do {
                    _ = try await setSystemProxyFromService(
                        true,
                        settings: request.systemProxySettings
                    )
                } catch {
                    do {
                        _ = try await setSystemProxyFromService(false)
                    } catch {
                        throw KumoError.commandFailed(
                            "Mihomo restarted, but Kumo Helper could not reapply or safely disable System Proxy."
                        )
                    }
                    throw error
                }
            }
            return try supervisor.status()
        } catch {
            let launchError = error
            if launchError as? KumoError == .runtimeGenerationConflict {
                throw launchError
            }
            if systemProxyWasEnabled {
                do {
                    try await makeSystemProxySafeAfterRuntimeFailure()
                } catch {
                    throw KumoError.commandFailed(
                        "Mihomo failed to start, and Kumo Helper could not make macOS System Proxy safe."
                    )
                }
            }
            throw launchError
        }
    }

    @_spi(KumoService)
    public func stopRuntimeFromService() async throws -> CoreStatus {
        try await stopSafelyWithoutGate()
    }

    @_spi(KumoService)
    public func stopRuntimeFromService(_ request: RuntimeStopRequest) async throws -> CoreStatus {
        _ = try request.expectedGeneration.requiredMatchingGeneration()
        return try await stopSafelyWithoutGate(expecting: request.expectedGeneration)
    }

    func ensureServiceCoreAvailableIfNeeded() async throws {
        guard let client = try serviceClientForMutation() else { return }
        let candidates = try client.sendDecodable(
            client.coreCandidatesRequest(),
            as: [CoreCandidate].self
        )
        guard candidates.isEmpty else { return }
        _ = try client.sendDecodable(client.installCoreRequest(), as: CoreInstallResult.self)
    }
}
