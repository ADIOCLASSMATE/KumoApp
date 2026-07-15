import Darwin
import Foundation

public enum ProfileRunPolicy: String, Codable, Equatable, Sendable {
    case preserveRunState
    case ensureRunning
}

public struct ProfileActivationRequest: Codable, Equatable, Sendable {
    public var profileID: String
    public var policy: ProfileRunPolicy
    public var forceReload: Bool

    public init(profileID: String, policy: ProfileRunPolicy, forceReload: Bool = false) {
        self.profileID = profileID
        self.policy = policy
        self.forceReload = forceReload
    }
}

public struct ProfileActivationResult: Codable, Equatable, Sendable {
    public var profileID: String
    public var previousProfileID: String
    public var status: CoreStatus
    public var didRestart: Bool

    public init(
        profileID: String,
        previousProfileID: String,
        status: CoreStatus,
        didRestart: Bool
    ) {
        self.profileID = profileID
        self.previousProfileID = previousProfileID
        self.status = status
        self.didRestart = didRestart
    }
}

/// Marks the narrow failure class where the activation coordinator could not
/// prove that rollback/cleanup completed. Callers may perform last-resort
/// System Proxy safety handling for this error only; preflight failures and
/// successfully rolled-back activations must leave a healthy proxy untouched.
struct ProfileActivationRuntimeUncertainError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

struct ProfileActivationOperations: Sendable {
    var currentProfileID: @Sendable () async throws -> String
    var loadProfile: @Sendable (String) async throws -> Profile
    var prepareRuntime: @Sendable (Profile, String) async throws -> RuntimeSpec
    var status: @Sendable () async throws -> CoreStatus
    var startAndWait: @Sendable (RuntimeSpec) async throws -> CoreStatus
    var restartAndWait: @Sendable (RuntimeSpec) async throws -> CoreStatus
    var stop: @Sendable () async throws -> CoreStatus
    var verifyRuntime: @Sendable (RuntimeSpec, CoreStatus) async throws -> Void
    var restoreSystemProxy: @Sendable () async throws -> Void
    var setCurrentProfile: @Sendable (String) async throws -> Void
}

struct ProfileOperationFileLock: Sendable {
    let url: URL

    func perform<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw KumoError.commandFailed("Kumo could not open the profile transaction lock safely.")
        }
        defer { close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1,
              fileStatus.st_uid == geteuid(),
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw KumoError.commandFailed("Kumo refused an unsafe profile transaction lock.")
        }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                throw KumoError.commandFailed("Kumo could not acquire the profile transaction lock.")
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { flock(descriptor, LOCK_UN) }

        try Task.checkCancellation()
        return try await operation()
    }
}

actor ProfileOperationGate {
    static let shared = ProfileOperationGate()

    private var operationInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<Result: Sendable>(
        fileLock: ProfileOperationFileLock? = nil,
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if let fileLock {
            return try await fileLock.perform(operation)
        }
        return try await operation()
    }

    private func acquire() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            operationInProgress = false
            return
        }
        waiters.removeFirst().resume()
    }
}

actor ProfileActivationCoordinator {
    private var activationInProgress = false

    func activate(
        profileID: String,
        policy: ProfileRunPolicy,
        forceReload: Bool = false,
        operations: ProfileActivationOperations
    ) async throws -> ProfileActivationResult {
        guard !activationInProgress else {
            throw KumoError.commandFailed("Another profile activation is already in progress.")
        }
        activationInProgress = true
        defer { activationInProgress = false }

        let previousID = try await operations.currentProfileID()
        let previousProfile = try await operations.loadProfile(previousID)
        let candidate = try await operations.loadProfile(profileID)
        let candidateRuntime = try await operations.prepareRuntime(candidate, profileID)
        let previousRuntime = previousID == profileID
            ? candidateRuntime
            : try await operations.prepareRuntime(previousProfile, previousID)

        let previousStatus = try await operations.status()
        let isStrictlyStopped = Self.isStrictlyStopped(previousStatus)
        let runtimeWasPresentOrAmbiguous = !isStrictlyStopped

        if profileID == previousID, !forceReload {
            let isHealthyRequestedRuntime = previousStatus.state == .running
                && previousStatus.readiness == .controllerReady
                && previousStatus.activeProfileID == profileID
            if isHealthyRequestedRuntime {
                do {
                    try await operations.verifyRuntime(candidateRuntime, previousStatus)
                    return ProfileActivationResult(
                        profileID: profileID,
                        previousProfileID: previousID,
                        status: previousStatus,
                        didRestart: false
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A status snapshot is not sufficient proof that traffic is
                    // using this profile. Reconcile the runtime below.
                }
            } else if isStrictlyStopped, policy == .preserveRunState {
                return ProfileActivationResult(
                    profileID: profileID,
                    previousProfileID: previousID,
                    status: previousStatus,
                    didRestart: false
                )
            }
        }

        let shouldRun = runtimeWasPresentOrAmbiguous || policy == .ensureRunning
        guard shouldRun else {
            try await operations.setCurrentProfile(profileID)
            return ProfileActivationResult(
                profileID: profileID,
                previousProfileID: previousID,
                status: previousStatus,
                didRestart: false
            )
        }

        do {
            let status: CoreStatus
            if runtimeWasPresentOrAmbiguous {
                status = try await operations.restartAndWait(candidateRuntime)
            } else {
                status = try await operations.startAndWait(candidateRuntime)
            }
            try Task.checkCancellation()
            try await operations.verifyRuntime(candidateRuntime, status)
            try await operations.setCurrentProfile(profileID)
            return ProfileActivationResult(
                profileID: profileID,
                previousProfileID: previousID,
                status: status,
                didRestart: true
            )
        } catch {
            let activationWasCancelled = error is CancellationError
            if runtimeWasPresentOrAmbiguous {
                let restored = await Task.detached(priority: .userInitiated) {
                    do {
                        let currentStatus = try await operations.status()
                        let restoredStatus: CoreStatus
                        if Self.canStartWithoutRuntimeGeneration(currentStatus) {
                            restoredStatus = try await operations.startAndWait(previousRuntime)
                        } else {
                            restoredStatus = try await operations.restartAndWait(previousRuntime)
                        }
                        try await operations.verifyRuntime(previousRuntime, restoredStatus)
                        if previousStatus.systemProxyEnabled {
                            try await operations.restoreSystemProxy()
                        }
                        return true
                    } catch {
                        return false
                    }
                }.value
                guard restored else {
                    throw ProfileActivationRuntimeUncertainError(
                        message: "The new profile could not be activated, and Kumo could not restore the previous runtime."
                    )
                }
            } else {
                let stopped = await Task.detached(priority: .userInitiated) {
                    do {
                        _ = try await operations.stop()
                        return true
                    } catch {
                        return false
                    }
                }.value
                guard stopped else {
                    throw ProfileActivationRuntimeUncertainError(
                        message: "The new profile could not be activated, and Kumo could not stop the incomplete runtime."
                    )
                }
            }

            if activationWasCancelled {
                throw CancellationError()
            }
            throw KumoError.commandFailed(
                "The new profile could not be activated. The previous profile was restored."
            )
        }
    }

    static func isStrictlyStopped(_ status: CoreStatus) -> Bool {
        status.isStrictlyStoppedRuntime
    }

    /// A failed candidate can be fully cleaned up while the authoritative
    /// status intentionally remains `.failed`. With no process identity,
    /// readiness, or generation left, rollback must use the stopped-generation
    /// start path; restart cannot provide the exact generation CAS it requires.
    static func canStartWithoutRuntimeGeneration(_ status: CoreStatus) -> Bool {
        (status.state == .stopped || status.state == .failed)
            && status.pid == nil
            && status.runtimeGeneration == nil
            && status.readiness == nil
    }
}
