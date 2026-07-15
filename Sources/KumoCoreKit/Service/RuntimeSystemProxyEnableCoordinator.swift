import Foundation

struct RuntimeSystemProxyEnableOperations: Sendable {
    let applySystemProxy: @Sendable () async throws -> [ShellCommand]
    let validatePostApplyGeneration: @Sendable () async throws -> Void
    let disableUsingRecoveryJournal: @Sendable () async throws -> Void
    let recoveredStatus: @Sendable () async throws -> CoreStatus
}

enum RuntimeSystemProxyEnableCoordinator {
    static func enable(
        operations: RuntimeSystemProxyEnableOperations
    ) async throws -> [ShellCommand] {
        let commands = try await operations.applySystemProxy()
        do {
            try await operations.validatePostApplyGeneration()
        } catch {
            let postApplyError = error
            do {
                try await operations.disableUsingRecoveryJournal()
                let recovered = try await operations.recoveredStatus()
                guard !recovered.systemProxyEnabled,
                      recovered.systemProxyRecoveryAction == nil else {
                    throw KumoError.commandFailed(
                        "Kumo did not confirm the completed System Proxy recovery."
                    )
                }
            } catch {
                throw KumoError.commandFailed(
                    "System Proxy lost its Mihomo runtime generation guarantee, and Kumo could not confirm a safe disabled recovery state."
                )
            }
            throw postApplyError
        }
        return commands
    }
}
