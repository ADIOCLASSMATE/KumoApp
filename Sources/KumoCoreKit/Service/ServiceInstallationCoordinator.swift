import Foundation

@_spi(KumoService)
public struct ConvergentServiceInstallationOperations: Sendable {
    public var writeManifestPhase: @Sendable (ServiceInstallationManifest.Phase) throws -> Void
    public var stopLoadedService: @Sendable () throws -> Void
    public var makeSystemProxySafe: @Sendable () async throws -> Void
    public var installCandidateFiles: @Sendable () throws -> Void
    public var startAndValidateCandidate: @Sendable () throws -> Void

    public init(
        writeManifestPhase: @escaping @Sendable (ServiceInstallationManifest.Phase) throws -> Void,
        stopLoadedService: @escaping @Sendable () throws -> Void,
        makeSystemProxySafe: @escaping @Sendable () async throws -> Void,
        installCandidateFiles: @escaping @Sendable () throws -> Void,
        startAndValidateCandidate: @escaping @Sendable () throws -> Void
    ) {
        self.writeManifestPhase = writeManifestPhase
        self.stopLoadedService = stopLoadedService
        self.makeSystemProxySafe = makeSystemProxySafe
        self.installCandidateFiles = installCandidateFiles
        self.startAndValidateCandidate = startAndValidateCandidate
    }
}

/// Installs over a service whose previous files do not form a coherent state.
/// There is deliberately no rollback to that partial predecessor: every retry
/// replaces the whole set and either commits `installed` or records
/// `repairRequired` after making the machine safe.
@_spi(KumoService)
public enum ServiceInstallationCoordinator {
    public static func converge(
        operations: ConvergentServiceInstallationOperations
    ) async throws {
        do {
            try operations.writeManifestPhase(.installing)
            try operations.stopLoadedService()
            try await operations.makeSystemProxySafe()
            try operations.installCandidateFiles()
            try operations.startAndValidateCandidate()
            try operations.writeManifestPhase(.installed)
        } catch {
            let installationError = error
            var safetyFailures: [String] = []

            do {
                try operations.stopLoadedService()
            } catch {
                safetyFailures.append("stop Helper: \(error.localizedDescription)")
            }
            do {
                try await operations.makeSystemProxySafe()
            } catch {
                safetyFailures.append("secure System Proxy: \(error.localizedDescription)")
            }
            do {
                try operations.writeManifestPhase(.repairRequired)
            } catch {
                safetyFailures.append("record repair state: \(error.localizedDescription)")
            }

            guard safetyFailures.isEmpty else {
                throw KumoError.serviceUnavailable(
                    "Kumo Helper repair failed (\(installationError.localizedDescription)) and the failed state could not be fully secured: \(safetyFailures.joined(separator: "; "))."
                )
            }
            throw installationError
        }
    }
}
