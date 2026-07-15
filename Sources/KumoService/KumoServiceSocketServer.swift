import Darwin
import Foundation
@_spi(KumoService) import KumoCoreKit

private actor KumoServiceRequestAuthenticator {
    private let credentials: KumoServiceCredentials
    private var replayCache = KumoServiceReplayCache()

    init(credentials: KumoServiceCredentials) {
        self.credentials = credentials
    }

    func validate(_ request: KumoServiceSignedRequest) -> Bool {
        KumoServiceRequestSigner.validate(
            request,
            credentials: credentials,
            replayCache: &replayCache
        )
    }
}

final class KumoServiceSocketServer: @unchecked Sendable {
    private let paths: KumoPaths
    private let credentials: KumoServiceCredentials
    private let authorizedUser: StateFileOwnership
    private let controller: KumoController
    private let authenticator: KumoServiceRequestAuthenticator
    private let mutationGate = KumoServiceMutationGate()

    private static var helperVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
    }

    init(paths: KumoPaths, credentials: KumoServiceCredentials, authorizedUser: StateFileOwnership) {
        self.paths = paths
        self.credentials = credentials
        self.authorizedUser = authorizedUser
        self.authenticator = KumoServiceRequestAuthenticator(credentials: credentials)
        // Keep one controller for the daemon lifetime. In particular, its
        // PACServer actor must survive after an enable request returns so the
        // configured proxy.pac URL remains reachable until disable/reconfigure.
        self.controller = KumoController(
            servicePaths: paths,
            stateFileOwnership: authorizedUser
        )
    }

    func run() async throws {
        try await reconcilePersistedSystemProxyState()
        let serviceSocketFile = paths.privilegedServiceSocketFile(userID: authorizedUser.userID)
        try? FileManager.default.removeItem(at: serviceSocketFile)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Unable to create service socket.")
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let socketPath = serviceSocketFile.path
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            throw KumoError.serviceUnavailable("Service socket path is too long: \(socketPath)")
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                socketPath.withCString { source in
                    strncpy(buffer, source, maxPathLength - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw KumoError.serviceUnavailable("Unable to bind service socket at \(socketPath).")
        }
        try checkPOSIX(
            chmod(socketPath, S_IRUSR | S_IWUSR),
            operation: "set service socket permissions"
        )
        try checkPOSIX(
            chown(socketPath, authorizedUser.userID, authorizedUser.groupID),
            operation: "set service socket owner"
        )

        guard listen(descriptor, 16) == 0 else {
            throw KumoError.serviceUnavailable("Unable to listen on service socket.")
        }
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            guard (try? KumoSocketSafety.configureNoSigPipe(client)) != nil,
                  (try? configureSocketTimeouts(client, seconds: 15)) != nil else {
                close(client)
                continue
            }
            Task.detached(priority: .userInitiated) { [self] in
                let response = await handleConnection(client)
                try? writeResponse(response, to: client)
                close(client)
            }
        }
    }

    private func reconcilePersistedSystemProxyState() async throws {
        let runtime = try controller.status()
        if runtime.systemProxyRecoveryAction == .completeDisable {
            do {
                _ = try await controller.setSystemProxyFromService(false)
                let completed = try controller.status()
                guard !completed.systemProxyEnabled,
                      completed.systemProxyRecoveryAction == nil else {
                    throw KumoError.serviceUnavailable(
                        "Kumo Helper did not complete its interrupted system proxy disable."
                    )
                }
            } catch {
                throw KumoError.serviceUnavailable(
                    "Kumo Helper could not complete its interrupted system proxy disable: \(error.localizedDescription)"
                )
            }
            return
        }
        guard runtime.systemProxyEnabled else {
            return
        }
        guard let settings = runtime.systemProxySettings else {
            do {
                _ = try await controller.setSystemProxyFromService(false)
            } catch {
                throw KumoError.serviceUnavailable(
                    "Kumo Helper could not disable a stale system proxy configuration with missing settings."
                )
            }
            fputs("Kumo Helper disabled a stale system proxy configuration with missing settings.\n", stderr)
            return
        }
        do {
            // Revalidate the exact runtime generation before preserving any
            // system proxy after a Helper restart. PAC additionally recreates
            // its process-local listener and replaces the stale macOS URL.
            _ = try await controller.setSystemProxyFromService(true, settings: settings)
        } catch {
            // Never leave macOS pointing at a dead or unverified runtime.
            do {
                _ = try await controller.setSystemProxyFromService(false)
            } catch {
                throw KumoError.serviceUnavailable(
                    "Kumo Helper could not recover or safely disable its previous PAC configuration."
                )
            }
            fputs("Kumo Helper disabled a stale system proxy configuration: \(error.localizedDescription)\n", stderr)
        }
    }

    private func handleConnection(_ descriptor: Int32) async -> KumoServiceTransportResponse {
        do {
            let data = try readAll(from: descriptor)
            let transport = try JSONDecoder().decode(KumoServiceTransportRequest.self, from: data)
            let request = transport.signedRequest
            guard await authenticator.validate(request) else {
                return KumoServiceTransportResponse(status: 401, error: "Invalid Kumo service signature.")
            }
            return try await route(request)
        } catch KumoError.runtimeGenerationConflict {
            return KumoServiceTransportResponse(
                status: 409,
                error: KumoError.runtimeGenerationConflict.localizedDescription
            )
        } catch {
            return KumoServiceTransportResponse(status: 500, error: error.localizedDescription)
        }
    }

    private func route(_ request: KumoServiceSignedRequest) async throws -> KumoServiceTransportResponse {
        if request.method == "GET",
           let limit = pathInteger(suffixOf: "/logs/recent/", in: request.path) {
            return try json(controller.recentLogs(limit: limit))
        }
        if request.method == "GET",
           let limit = pathInteger(suffixOf: "/runtime/events/", in: request.path) {
            return try json(controller.runtimeEvents(limit: limit))
        }
        switch (request.method, request.path) {
        case ("GET", "/service/handshake"):
            return try json(KumoServiceHandshake.current(helperVersion: Self.helperVersion))
        case ("GET", "/service/status"):
            let handshake = KumoServiceHandshake.current(helperVersion: Self.helperVersion)
            let diskState = ServiceInstallationDiskClassifier(
                paths: paths,
                expectedAuthorizedUserID: authorizedUser.userID,
                inspectionScope: .privileged
            ).classify()
            return try json(KumoServiceManager.composePrivilegedStatus(
                diskState: diskState,
                handshake: handshake,
                isCurrentProcessPrivileged: geteuid() == 0,
                socketPath: paths.privilegedServiceSocketFile(userID: authorizedUser.userID).path
            ))
        case ("GET", "/status"), ("GET", "/sysproxy/status"):
            return try json(controller.status())
        case ("GET", "/core/candidates"):
            return try json(controller.coreCandidates())
        case ("GET", "/tun/status"):
            return try json(controller.tunStatus())
        case ("POST", "/core/install"),
             ("POST", "/core/start"),
             ("POST", "/core/stop"),
             ("POST", "/core/restart"),
             ("POST", "/runtime/mutate"),
             ("POST", "/sysproxy/enable"),
             ("POST", "/sysproxy/disable"):
            return try await mutationGate.perform { [self] in
                try await routeMutation(request)
            }
        default:
            return KumoServiceTransportResponse(status: 404, error: "Unknown Kumo service endpoint: \(request.method) \(request.path)")
        }
    }

    private func routeMutation(
        _ request: KumoServiceSignedRequest
    ) async throws -> KumoServiceTransportResponse {
        switch (request.method, request.path) {
        case ("POST", "/core/install"):
            return try json(try await controller.installManagedCoreFromService())
        case ("POST", "/core/start"):
            let launch = try JSONDecoder().decode(CoreRuntimeLaunchRequest.self, from: request.body)
            return try json(try await controller.launchRuntimeAndWait(launch, restart: false))
        case ("POST", "/core/stop"):
            let stop = try JSONDecoder().decode(RuntimeStopRequest.self, from: request.body)
            return try json(try await controller.stopRuntimeFromService(stop))
        case ("POST", "/core/restart"):
            let launch = try JSONDecoder().decode(CoreRuntimeLaunchRequest.self, from: request.body)
            return try json(try await controller.launchRuntimeAndWait(launch, restart: true))
        case ("POST", "/runtime/mutate"):
            let mutation = try JSONDecoder().decode(RuntimeMutationRequest.self, from: request.body)
            return try json(try await controller.applyRuntimeMutationFromService(mutation))
        case ("POST", "/sysproxy/enable"):
            let enable = try JSONDecoder().decode(
                RuntimeSystemProxyEnableRequest.self,
                from: request.body
            )
            _ = try await controller.enableSystemProxyFromService(enable)
            return try json(controller.status())
        case ("POST", "/sysproxy/disable"):
            _ = try await controller.setSystemProxyFromService(false)
            return try json(controller.status())
        default:
            return KumoServiceTransportResponse(
                status: 404,
                error: "Unknown Kumo service mutation: \(request.method) \(request.path)"
            )
        }
    }

    private func pathInteger(suffixOf prefix: String, in path: String) -> Int? {
        guard path.hasPrefix(prefix),
              let value = Int(path.dropFirst(prefix.count)) else { return nil }
        return max(0, min(value, 2_000))
    }

    private func json<T: Encodable>(_ value: T) throws -> KumoServiceTransportResponse {
        KumoServiceTransportResponse(status: 200, body: try JSONEncoder().encode(value))
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        let maximumRequestBytes = 40 * 1024 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return data
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw socketIOError("read service request")
            }
            guard data.count + count <= maximumRequestBytes else {
                throw KumoError.serviceUnavailable("Kumo service request exceeded the 40 MiB limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeResponse(_ response: KumoServiceTransportResponse, to descriptor: Int32) throws {
        let data = try JSONEncoder().encode(response)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw socketIOError("write service response")
                }
                bytesWritten += result
            }
        }
    }

    private func configureSocketTimeouts(_ descriptor: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        guard withUnsafePointer(to: &timeout, {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, length)
        }) == 0,
        withUnsafePointer(to: &timeout, {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, length)
        }) == 0 else {
            throw socketIOError("configure service socket timeouts")
        }
    }

    private func socketIOError(_ operation: String) -> KumoError {
        let message: String
        if errno == EAGAIN || errno == EWOULDBLOCK {
            message = "Timed out while attempting to \(operation)."
        } else {
            message = "Unable to \(operation): \(String(cString: strerror(errno)))."
        }
        return .serviceUnavailable(message)
    }
}
