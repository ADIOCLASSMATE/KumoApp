import Foundation

struct UnreachableServiceRepairOperations: Sendable {
    var localRuntimeStatus: @Sendable () async throws -> CoreStatus
    var disableLocalSystemProxy: @Sendable () async throws -> Void
    var installResettingProxyRecovery: @Sendable () async throws -> ServiceModeStatus
    var activateSelectedProfile: @Sendable () async throws -> Void
    var enableHelperSystemProxy: @Sendable () async throws -> Void
    var disableHelperSystemProxy: @Sendable () async throws -> Void
    var persistServiceStatus: @Sendable (ServiceModeStatus) async throws -> Void
}

/// Repairs an installed Helper whose authenticated runtime API is unavailable.
/// The ordering is intentionally fail-safe: restore macOS proxy state first,
/// reset the privileged recovery journal as part of install, reconcile the
/// exact selected runtime, and only then opt back into System Proxy.
enum UnreachableServiceRepairCoordinator {
    static func repair(
        operations: UnreachableServiceRepairOperations
    ) async throws -> ServiceModeStatus {
        let legacy = try await operations.localRuntimeStatus()
        let runtimeWasPresentOrAmbiguous = !legacy.isStrictlyStoppedProcessState
        let proxyWasEnabled = legacy.systemProxyEnabled

        if proxyWasEnabled {
            try await operations.disableLocalSystemProxy()
            let verified = try await operations.localRuntimeStatus()
            guard !verified.systemProxyEnabled else {
                throw KumoError.commandFailed(
                    "Kumo could not verify that macOS System Proxy was restored before repairing the Helper."
                )
            }
        }

        let installed = try await operations.installResettingProxyRecovery()
        guard installed.isInstalled, installed.isRunning, installed.isAvailable else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper repair finished without a verified compatible Helper."
            )
        }

        do {
            if runtimeWasPresentOrAmbiguous {
                try await operations.activateSelectedProfile()
            }
            if proxyWasEnabled, runtimeWasPresentOrAmbiguous {
                try await operations.enableHelperSystemProxy()
            }
            try await operations.persistServiceStatus(installed)
            return installed
        } catch {
            let repairError = error
            do {
                try await operations.disableHelperSystemProxy()
            } catch {
                throw KumoError.commandFailed(
                    "Kumo Helper repair failed, and Kumo could not verify that System Proxy remained safely disabled."
                )
            }
            throw repairError
        }
    }
}
