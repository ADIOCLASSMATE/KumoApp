import Foundation

struct OverrideMutationTransaction {
    static func perform<Snapshot: Sendable, Result: Sendable>(
        snapshot: @Sendable () async throws -> Snapshot,
        runtimeNeedsReload: @Sendable () async throws -> Bool,
        mutate: @Sendable () async throws -> Result,
        preflight: @Sendable () async throws -> Void,
        activateCandidate: @Sendable () async throws -> Void,
        restoreSnapshot: @escaping @Sendable (Snapshot) async throws -> Void,
        restoreRuntime: @escaping @Sendable () async throws -> Void
    ) async throws -> Result {
        let previousSnapshot = try await snapshot()
        var candidateActivationAttempted = false

        do {
            let shouldReloadRuntime = try await runtimeNeedsReload()
            let result = try await mutate()
            try await preflight()

            if shouldReloadRuntime {
                candidateActivationAttempted = true
                try await activateCandidate()
            }
            return result
        } catch {
            let operationError = error
            let shouldRestoreRuntime = candidateActivationAttempted
            do {
                try await Task.detached {
                    try await restoreSnapshot(previousSnapshot)
                    if shouldRestoreRuntime {
                        try await restoreRuntime()
                    }
                }.value
            } catch {
                if shouldRestoreRuntime {
                    throw KumoError.commandFailed(
                        "The override change failed, and Kumo could not restore the previous overrides and runtime."
                    )
                }
                throw KumoError.commandFailed(
                    "The override change failed, and Kumo could not restore the previous override files."
                )
            }

            if operationError is CancellationError {
                throw CancellationError()
            }
            throw operationError
        }
    }
}
