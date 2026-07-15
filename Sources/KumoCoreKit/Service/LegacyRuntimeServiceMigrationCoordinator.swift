import Foundation

struct LegacyRuntimeServiceMigrationOperations: Sendable {
    var localRuntimeStatus: @Sendable () async throws -> CoreStatus
    var installHelper: @Sendable () async throws -> ServiceModeStatus
    var prepareHelperTakeover: @Sendable () async throws -> Void
    var disableLocalSystemProxy: @Sendable () async throws -> Void
    var enableLocalSystemProxy: @Sendable () async throws -> Void
    var stopLocalRuntime: @Sendable () async throws -> Void
    var activateSelectedProfile: @Sendable () async throws -> Void
    var enableHelperSystemProxy: @Sendable () async throws -> Void
    var disableHelperSystemProxy: @Sendable () async throws -> Void
    var persistServiceStatus: @Sendable (ServiceModeStatus) async throws -> Void
}

/// Moves the last user-owned runtime to the required Helper without dropping
/// the existing proxy while macOS is still waiting for administrator approval.
enum LegacyRuntimeServiceMigrationCoordinator {
    static func migrate(
        operations: LegacyRuntimeServiceMigrationOperations
    ) async throws -> ServiceModeStatus {
        let legacy = try await operations.localRuntimeStatus()
        let runtimeWasPresent = !legacy.isStrictlyStoppedProcessState
        let proxyWasEnabled = legacy.systemProxyEnabled

        // Installing and authenticating the Helper does not touch the legacy
        // Mihomo process. Keep it serving traffic until authorization succeeds.
        let installed = try await operations.installHelper()
        guard installed.isInstalled, installed.isRunning, installed.isAvailable else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper installation finished without a verified compatible Helper."
            )
        }

        var localProxyWasDisabled = false
        do {
            if runtimeWasPresent {
                try await operations.prepareHelperTakeover()
            }

            if proxyWasEnabled {
                try await operations.disableLocalSystemProxy()
                localProxyWasDisabled = true
                let safe = try await operations.localRuntimeStatus()
                guard !safe.systemProxyEnabled else {
                    throw KumoError.commandFailed(
                        "Kumo could not verify System Proxy before transferring the runtime to Helper."
                    )
                }
            }

            if runtimeWasPresent {
                try await operations.stopLocalRuntime()
                let stopped = try await operations.localRuntimeStatus()
                guard stopped.isStrictlyStoppedProcessState else {
                    throw KumoError.commandFailed(
                        "Kumo could not verify that the legacy runtime stopped before Helper takeover."
                    )
                }
                try await operations.activateSelectedProfile()
                if proxyWasEnabled {
                    try await operations.enableHelperSystemProxy()
                }
            }

            try await operations.persistServiceStatus(installed)
            return installed
        } catch {
            let migrationError = error
            let localAfterFailure = try? await operations.localRuntimeStatus()
            let localCanContinue = runtimeWasPresent
                && localAfterFailure?.isStrictlyStoppedProcessState != true

            if localCanContinue {
                if proxyWasEnabled, localProxyWasDisabled {
                    do {
                        try await operations.enableLocalSystemProxy()
                    } catch {
                        throw KumoError.commandFailed(
                            "Kumo Helper migration failed, and the legacy System Proxy could not be restored: \(error.localizedDescription)"
                        )
                    }
                }
                throw migrationError
            }

            do {
                try await operations.disableHelperSystemProxy()
            } catch {
                throw KumoError.commandFailed(
                    "Kumo Helper migration failed, and Kumo could not verify that System Proxy remained disabled."
                )
            }
            throw migrationError
        }
    }
}
