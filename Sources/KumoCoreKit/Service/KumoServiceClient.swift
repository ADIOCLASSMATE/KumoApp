import CryptoKit
import Darwin
import Foundation

public struct KumoServiceEndpoint: Codable, Equatable, Sendable {
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }
}

public struct KumoServiceCredentials: Codable, Equatable, Sendable {
    public var keyID: String
    public var sharedSecret: String

    public init(keyID: String, sharedSecret: String) {
        self.keyID = keyID
        self.sharedSecret = sharedSecret
    }
}

public struct KumoServiceSignedRequest: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var body: Data
    public var headers: [String: String]

    public init(method: String, path: String, body: Data = Data(), headers: [String: String]) {
        self.method = method
        self.path = path
        self.body = body
        self.headers = headers
    }
}

public struct KumoServiceTransportRequest: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var bodyBase64: String

    public init(request: KumoServiceSignedRequest) {
        self.method = request.method
        self.path = request.path
        self.headers = request.headers
        self.bodyBase64 = request.body.base64EncodedString()
    }

    public var signedRequest: KumoServiceSignedRequest {
        KumoServiceSignedRequest(
            method: method,
            path: path,
            body: Data(base64Encoded: bodyBase64) ?? Data(),
            headers: headers
        )
    }
}

public struct KumoServiceTransportResponse: Codable, Equatable, Sendable {
    public var status: Int
    public var bodyBase64: String
    public var error: String?

    public init(status: Int, body: Data = Data(), error: String? = nil) {
        self.status = status
        self.bodyBase64 = body.base64EncodedString()
        self.error = error
    }

    public var body: Data {
        Data(base64Encoded: bodyBase64) ?? Data()
    }
}

@_spi(KumoService)
public struct KumoServiceReplayCache: Sendable {
    private var acceptedAtByNonce: [String: Date] = [:]
    private let maximumEntries: Int

    public init(maximumEntries: Int = 4_096) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public var count: Int { acceptedAtByNonce.count }

    mutating func prune(now: Date, allowedClockSkew: TimeInterval) {
        let oldestAcceptedDate = now.addingTimeInterval(-allowedClockSkew)
        acceptedAtByNonce = acceptedAtByNonce.filter { $0.value >= oldestAcceptedDate }
        if acceptedAtByNonce.count >= maximumEntries {
            let overflow = acceptedAtByNonce.count - maximumEntries + 1
            for (nonce, _) in acceptedAtByNonce.sorted(by: { $0.value < $1.value }).prefix(overflow) {
                acceptedAtByNonce.removeValue(forKey: nonce)
            }
        }
    }

    func contains(_ nonce: String) -> Bool {
        acceptedAtByNonce[nonce] != nil
    }

    mutating func insert(_ nonce: String, acceptedAt: Date) {
        acceptedAtByNonce[nonce] = acceptedAt
    }
}

public struct KumoServiceRequestSigner: Sendable {
    public var credentials: KumoServiceCredentials

    public init(credentials: KumoServiceCredentials) {
        self.credentials = credentials
    }

    public func signedRequest(
        method: String,
        path: String,
        query: String = "",
        body: Data = Data(),
        timestamp: Date = Date(),
        nonce: String = UUID().uuidString
    ) -> KumoServiceSignedRequest {
        let canonicalMethod = method.uppercased()
        let bodyHash = SHA256.hash(data: body).hexString
        let timestampValue = Self.timestampString(from: timestamp)
        let canonical = Self.canonicalString(
            timestamp: timestampValue,
            nonce: nonce,
            keyID: credentials.keyID,
            method: canonicalMethod,
            path: path,
            query: query,
            bodyHash: bodyHash
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: SymmetricKey(data: Data(credentials.sharedSecret.utf8))
        ).hexString

        return KumoServiceSignedRequest(
            method: canonicalMethod,
            path: path,
            body: body,
            headers: [
                "X-Kumo-Auth-Version": "1",
                "X-Kumo-Key-ID": credentials.keyID,
                "X-Kumo-Timestamp": timestampValue,
                "X-Kumo-Nonce": nonce,
                "X-Kumo-Content-SHA256": bodyHash,
                "X-Kumo-Signature": signature
            ]
        )
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func validate(
        _ request: KumoServiceSignedRequest,
        credentials: KumoServiceCredentials,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 300,
        seenNonces: inout Set<String>
    ) -> Bool {
        guard request.headers["X-Kumo-Auth-Version"] == "1",
              request.headers["X-Kumo-Key-ID"] == credentials.keyID,
              let timestamp = request.headers["X-Kumo-Timestamp"],
              let nonce = request.headers["X-Kumo-Nonce"],
              let contentHash = request.headers["X-Kumo-Content-SHA256"],
              let signature = request.headers["X-Kumo-Signature"],
              contentHash == SHA256.hash(data: request.body).hexString,
              !seenNonces.contains(nonce) else {
            return false
        }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: timestamp),
              abs(now.timeIntervalSince(date)) <= allowedClockSkew else {
            return false
        }

        let canonical = canonicalString(
            timestamp: timestamp,
            nonce: nonce,
            keyID: credentials.keyID,
            method: request.method.uppercased(),
            path: request.path,
            query: "",
            bodyHash: contentHash
        )
        let expectedSignature = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: SymmetricKey(data: Data(credentials.sharedSecret.utf8))
        ).hexString

        guard constantTimeEquals(signature, expectedSignature) else {
            return false
        }
        seenNonces.insert(nonce)
        return true
    }

    @_spi(KumoService)
    public static func validate(
        _ request: KumoServiceSignedRequest,
        credentials: KumoServiceCredentials,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 300,
        replayCache: inout KumoServiceReplayCache
    ) -> Bool {
        replayCache.prune(now: now, allowedClockSkew: allowedClockSkew)
        guard let nonce = request.headers["X-Kumo-Nonce"],
              !replayCache.contains(nonce) else {
            return false
        }
        var acceptedNonces = Set<String>()
        guard validate(
            request,
            credentials: credentials,
            now: now,
            allowedClockSkew: allowedClockSkew,
            seenNonces: &acceptedNonces
        ) else {
            return false
        }
        replayCache.insert(nonce, acceptedAt: now)
        return true
    }

    private static func canonicalString(
        timestamp: String,
        nonce: String,
        keyID: String,
        method: String,
        path: String,
        query: String,
        bodyHash: String
    ) -> String {
        [
            "KUMO-AUTH-V1",
            timestamp,
            nonce,
            keyID,
            method,
            path.isEmpty ? "/" : path,
            query,
            bodyHash
        ].joined(separator: "\n")
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}

struct KumoServiceClient: Sendable {
    public var endpoint: KumoServiceEndpoint
    public var signer: KumoServiceRequestSigner

    public init(endpoint: KumoServiceEndpoint, credentials: KumoServiceCredentials) {
        self.endpoint = endpoint
        self.signer = KumoServiceRequestSigner(credentials: credentials)
    }

    public func signedRequest(method: String, path: String, body: Data = Data()) -> KumoServiceSignedRequest {
        signer.signedRequest(method: method, path: path, body: body)
    }

    public func serviceStatusRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/service/status")
    }

    public func handshakeRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/service/handshake")
    }

    public func tunStatusRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/tun/status")
    }

    public func statusRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/status")
    }

    public func startCoreRequest(_ launch: CoreRuntimeLaunchRequest) throws -> KumoServiceSignedRequest {
        signedRequest(
            method: "POST",
            path: "/core/start",
            body: try JSONEncoder().encode(launch)
        )
    }

    public func installCoreRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "POST", path: "/core/install")
    }

    public func coreCandidatesRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/core/candidates")
    }

    public func stopCoreRequest(_ request: RuntimeStopRequest) throws -> KumoServiceSignedRequest {
        signedRequest(
            method: "POST",
            path: "/core/stop",
            body: try JSONEncoder().encode(request)
        )
    }

    public func restartCoreRequest(_ launch: CoreRuntimeLaunchRequest) throws -> KumoServiceSignedRequest {
        signedRequest(
            method: "POST",
            path: "/core/restart",
            body: try JSONEncoder().encode(launch)
        )
    }

    public func recentLogsRequest(limit: Int) -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/logs/recent/\(max(0, min(limit, 2_000)))")
    }

    public func runtimeEventsRequest(limit: Int) -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/runtime/events/\(max(0, min(limit, 2_000)))")
    }

    public func runtimeMutationRequest(
        _ mutation: RuntimeMutationRequest
    ) throws -> KumoServiceSignedRequest {
        signedRequest(
            method: "POST",
            path: "/runtime/mutate",
            body: try JSONEncoder().encode(mutation)
        )
    }

    public func systemProxyStatusRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/sysproxy/status")
    }

    public func setSystemProxyEnabledRequest(
        _ isEnabled: Bool,
        settings: SystemProxySettings?,
        expectedGeneration: RuntimeGenerationExpectation? = nil
    ) throws -> KumoServiceSignedRequest {
        let path = isEnabled ? "/sysproxy/enable" : "/sysproxy/disable"
        let body: Data
        if isEnabled {
            guard let settings, let expectedGeneration else {
                throw KumoError.invalidArguments(
                    "Enabling System Proxy requires settings and an exact runtime generation."
                )
            }
            _ = try expectedGeneration.requiredMatchingGeneration()
            body = try JSONEncoder().encode(RuntimeSystemProxyEnableRequest(
                settings: settings,
                expectedGeneration: expectedGeneration
            ))
        } else {
            body = Data()
        }
        return signedRequest(
            method: "POST",
            path: path,
            body: body
        )
    }

    public func send(_ request: KumoServiceSignedRequest) throws -> KumoServiceTransportResponse {
        let transportRequest = KumoServiceTransportRequest(request: request)
        let payload = try JSONEncoder().encode(transportRequest)
        let responseData = try send(
            payload: payload,
            toSocketAt: endpoint.socketPath,
            timeoutSeconds: timeoutSeconds(for: request.path)
        )
        let response = try JSONDecoder().decode(KumoServiceTransportResponse.self, from: responseData)
        if response.status == 409 {
            throw KumoError.runtimeGenerationConflict
        }
        guard (200..<300).contains(response.status) else {
            throw KumoError.serviceUnavailable(response.error ?? "Kumo service returned status \(response.status).")
        }
        return response
    }

    public func sendDecodable<T: Decodable & Sendable>(
        _ request: KumoServiceSignedRequest,
        as type: T.Type
    ) throws -> T {
        let response = try send(request)
        return try JSONDecoder().decode(T.self, from: response.body)
    }

    public func ping() -> Bool {
        (try? compatibleHandshake()) != nil
    }

    public func compatibleHandshake() throws -> KumoServiceHandshake {
        let handshake = try sendDecodable(handshakeRequest(), as: KumoServiceHandshake.self)
        guard handshake.isCompatible else {
            throw KumoError.serviceUnavailable(
                "The installed Kumo Helper protocol is incompatible. Repair the Helper before changing the runtime."
            )
        }
        return handshake
    }

    private func send(payload: Data, toSocketAt path: String, timeoutSeconds: Int) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Unable to create Kumo service socket.")
        }
        defer { close(descriptor) }
        try KumoSocketSafety.configureNoSigPipe(descriptor)
        try configureTimeouts(descriptor: descriptor, seconds: timeoutSeconds)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            throw KumoError.serviceUnavailable("Kumo service socket path is too long: \(path)")
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                path.withCString { source in
                    strncpy(buffer, source, maxPathLength - 1)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw KumoError.serviceUnavailable("Kumo service is not reachable at \(path).")
        }

        try writeAll(payload, to: descriptor)
        shutdown(descriptor, SHUT_WR)
        return try readAll(from: descriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    data.count - bytesWritten
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw socketIOError("write request to Kumo service")
                }
                bytesWritten += result
            }
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        let maximumResponseBytes = 64 * 1024 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return data
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw socketIOError("read response from Kumo service")
            }
            guard data.count + count <= maximumResponseBytes else {
                throw KumoError.serviceUnavailable("Kumo service response exceeded the 64 MiB limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func timeoutSeconds(for path: String) -> Int {
        switch path {
        case "/core/install":
            return 240
        case "/core/start", "/core/restart":
            return 60
        default:
            return 15
        }
    }

    private func configureTimeouts(descriptor: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        guard withUnsafePointer(to: &timeout, {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, length)
        }) == 0,
        withUnsafePointer(to: &timeout, {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, length)
        }) == 0 else {
            throw socketIOError("configure Kumo service socket timeouts")
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

/// `Darwin.write` raises SIGPIPE by default when the peer closes a Unix
/// socket. A thrown Swift error cannot catch that signal, so both the app and
/// Helper must opt every connected descriptor out before writing.
@_spi(KumoService)
public enum KumoSocketSafety {
    public static func configureNoSigPipe(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        let result = withUnsafePointer(to: &enabled) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard result == 0 else {
            let code = errno
            throw KumoError.serviceUnavailable(
                "Unable to protect Kumo service socket writes: \(String(cString: strerror(code)))"
            )
        }
    }
}

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension HMAC<SHA256>.MAC {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
