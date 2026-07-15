import Foundation

/// Serializes state-changing Helper requests while allowing read-only
/// handshake and status requests to remain responsive.
@_spi(KumoService)
public actor KumoServiceMutationGate {
    private var mutationInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func perform<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            mutationInProgress = false
            return
        }
        waiters.removeFirst().resume()
    }
}
