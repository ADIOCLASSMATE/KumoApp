import Darwin
import XCTest
@_spi(KumoService) @testable import KumoCoreKit

final class KumoServiceClientTests: XCTestCase {
    func testHelperMutationGateSerializesAsyncMutations() async throws {
        let gate = KumoServiceMutationGate()
        let probe = ServiceMutationProbe()

        async let first: Void = gate.perform {
            await probe.enter()
            try await Task.sleep(for: .milliseconds(80))
            await probe.leave()
        }
        async let second: Void = gate.perform {
            await probe.enter()
            await probe.leave()
        }
        _ = try await (first, second)

        let maximumConcurrentCount = await probe.maximumConcurrentCount
        XCTAssertEqual(maximumConcurrentCount, 1)
    }

    func testProductionControllerRequiresHelperAndNeverSelectsLocalMutationAuthority() throws {
        let paths = KumoPaths(
            applicationSupportDirectory: temporaryDirectory()
                .appendingPathComponent("production-authority", isDirectory: true),
            privilegedRuntimeRootDirectory: temporaryDirectory()
                .appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: temporaryDirectory()
                .appendingPathComponent("service", isDirectory: true)
        )
        let production = KumoController(paths: paths)
        let isolatedSupervisor = KumoController(paths: paths, useServiceBackend: false)

        XCTAssertThrowsError(try production.serviceClientForMutation())
        XCTAssertNil(try isolatedSupervisor.serviceClientForMutation())
    }

    func testServiceSocketWritesDisableSIGPIPE() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        try KumoSocketSafety.configureNoSigPipe(descriptors[0])

        var enabled: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, &length),
            0
        )
        XCTAssertEqual(enabled, 1)
    }

    func testSignedRequestIncludesCanonicalAuthHeaders() {
        let signer = KumoServiceRequestSigner(
            credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        )
        let request = signer.signedRequest(
            method: "post",
            path: "/core/start",
            body: Data("{}".utf8),
            timestamp: Date(timeIntervalSince1970: 0),
            nonce: "nonce"
        )

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/core/start")
        XCTAssertEqual(request.headers["X-Kumo-Auth-Version"], "1")
        XCTAssertEqual(request.headers["X-Kumo-Key-ID"], "test-key")
        XCTAssertEqual(request.headers["X-Kumo-Nonce"], "nonce")
        XCTAssertNotNil(request.headers["X-Kumo-Content-SHA256"])
        XCTAssertNotNil(request.headers["X-Kumo-Signature"])
    }

    func testServiceClientBuildsRuntimeEndpointRequests() throws {
        let client = KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: "/tmp/kumo.sock"),
            credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        )
        let launch = CoreRuntimeLaunchRequest(
            spec: RuntimeSpec(
                profileID: "profile",
                profileYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n",
                overrideYAMLs: [],
                endpoint: ControllerEndpoint(),
                proxyPorts: ProxyPortConfiguration(),
                mode: .rule,
                runtimeSettings: CoreRuntimeSettings(),
                configurationDigest: String(repeating: "b", count: 64)
            ),
            expectedGeneration: .stopped
        )
        let stoppedGeneration = UUID()
        let restartLaunch = CoreRuntimeLaunchRequest(
            spec: launch.spec,
            expectedGeneration: .matching(stoppedGeneration)
        )

        XCTAssertEqual(client.statusRequest().path, "/status")
        let startRequest = try client.startCoreRequest(launch)
        XCTAssertEqual(startRequest.path, "/core/start")
        XCTAssertEqual(
            try JSONDecoder().decode(CoreRuntimeLaunchRequest.self, from: startRequest.body)
                .expectedGeneration,
            .stopped
        )
        XCTAssertEqual(client.installCoreRequest().path, "/core/install")
        XCTAssertEqual(client.coreCandidatesRequest().path, "/core/candidates")
        let stopRequest = try client.stopCoreRequest(RuntimeStopRequest(
            expectedGeneration: .matching(stoppedGeneration)
        ))
        XCTAssertEqual(stopRequest.path, "/core/stop")
        XCTAssertEqual(
            try JSONDecoder().decode(RuntimeStopRequest.self, from: stopRequest.body),
            RuntimeStopRequest(expectedGeneration: .matching(stoppedGeneration))
        )
        let restartRequest = try client.restartCoreRequest(restartLaunch)
        XCTAssertEqual(restartRequest.path, "/core/restart")
        XCTAssertEqual(
            try JSONDecoder().decode(CoreRuntimeLaunchRequest.self, from: restartRequest.body)
                .expectedGeneration,
            .matching(stoppedGeneration)
        )
        XCTAssertEqual(client.recentLogsRequest(limit: 25).path, "/logs/recent/25")
        XCTAssertEqual(client.runtimeEventsRequest(limit: 25).path, "/runtime/events/25")
        let runtimeMutation = RuntimeMutationRequest(
            mutation: .setMode(.direct),
            expectedGeneration: .matching(stoppedGeneration)
        )
        let runtimeMutationRequest = try client.runtimeMutationRequest(runtimeMutation)
        XCTAssertEqual(runtimeMutationRequest.path, "/runtime/mutate")
        XCTAssertEqual(
            try JSONDecoder().decode(RuntimeMutationRequest.self, from: runtimeMutationRequest.body),
            runtimeMutation
        )
        XCTAssertEqual(client.systemProxyStatusRequest().path, "/sysproxy/status")
        let proxySettings = SystemProxySettings(
            networkService: "USB 10/100/1000 LAN",
            host: "127.0.0.1",
            port: 7_890,
            mode: .manual,
            bypassList: ["localhost", "*.local"]
        )
        let enableRequest = try client.setSystemProxyEnabledRequest(
            true,
            settings: proxySettings,
            expectedGeneration: .matching(stoppedGeneration)
        )
        XCTAssertEqual(enableRequest.path, "/sysproxy/enable")
        XCTAssertEqual(
            try JSONDecoder().decode(RuntimeSystemProxyEnableRequest.self, from: enableRequest.body),
            RuntimeSystemProxyEnableRequest(
                settings: proxySettings,
                expectedGeneration: .matching(stoppedGeneration)
            )
        )
        XCTAssertThrowsError(
            try client.setSystemProxyEnabledRequest(true, settings: proxySettings)
        )
        let disableRequest = try client.setSystemProxyEnabledRequest(false, settings: nil)
        XCTAssertEqual(disableRequest.path, "/sysproxy/disable")
        XCTAssertTrue(disableRequest.body.isEmpty)
        XCTAssertEqual(client.serviceStatusRequest().path, "/service/status")
        XCTAssertEqual(client.handshakeRequest().path, "/service/handshake")
        XCTAssertEqual(client.tunStatusRequest().path, "/tun/status")
    }

    func testHandshakeRequiresRuntimeSafetyCapabilities() {
        let privilegedHealth = KumoServiceCapability.privilegedInstallationHealth
        let routedMutations = KumoServiceCapability.routedRuntimeMutations
        let compatible = KumoServiceHandshake(
            protocolVersion: KumoServiceProtocol.currentVersion,
            helperVersion: "test",
            capabilities: [
                .runtimeActivationReceipt,
                .atomicRuntimeGenerationCAS,
                privilegedHealth,
                routedMutations
            ]
        )
        let missingCAS = KumoServiceHandshake(
            protocolVersion: KumoServiceProtocol.currentVersion,
            helperVersion: "test",
            capabilities: [.runtimeActivationReceipt, privilegedHealth, routedMutations]
        )
        let missingReceipt = KumoServiceHandshake(
            protocolVersion: KumoServiceProtocol.currentVersion,
            helperVersion: "test",
            capabilities: [.atomicRuntimeGenerationCAS, privilegedHealth, routedMutations]
        )
        let missingPrivilegedHealth = KumoServiceHandshake(
            protocolVersion: KumoServiceProtocol.currentVersion,
            helperVersion: "test",
            capabilities: [.runtimeActivationReceipt, .atomicRuntimeGenerationCAS, routedMutations]
        )
        let missingRoutedMutations = KumoServiceHandshake(
            protocolVersion: KumoServiceProtocol.currentVersion,
            helperVersion: "test",
            capabilities: [.runtimeActivationReceipt, .atomicRuntimeGenerationCAS, privilegedHealth]
        )

        XCTAssertTrue(compatible.isCompatible)
        XCTAssertFalse(missingCAS.isCompatible)
        XCTAssertFalse(missingReceipt.isCompatible)
        XCTAssertFalse(missingPrivilegedHealth.isCompatible)
        XCTAssertFalse(missingRoutedMutations.isCompatible)
    }

    func testSignedRequestValidationRejectsReplayAndTampering() {
        let credentials = KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        let signer = KumoServiceRequestSigner(credentials: credentials)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let request = signer.signedRequest(
            method: "GET",
            path: "/service/status",
            timestamp: timestamp,
            nonce: "nonce"
        )
        var seenNonces = Set<String>()

        XCTAssertTrue(KumoServiceRequestSigner.validate(
            request,
            credentials: credentials,
            now: timestamp,
            seenNonces: &seenNonces
        ))
        XCTAssertFalse(KumoServiceRequestSigner.validate(
            request,
            credentials: credentials,
            now: timestamp,
            seenNonces: &seenNonces
        ))

        var tampered = request
        tampered.path = "/tun/enable"
        seenNonces.removeAll()
        XCTAssertFalse(KumoServiceRequestSigner.validate(
            tampered,
            credentials: credentials,
            now: timestamp,
            seenNonces: &seenNonces
        ))
    }

    func testReplayCacheRejectsWindowReplayAndEvictsExpiredOrOverflowEntries() {
        let credentials = KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        let signer = KumoServiceRequestSigner(credentials: credentials)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = signer.signedRequest(
            method: "GET",
            path: "/status",
            timestamp: start,
            nonce: "reusable-after-window"
        )
        var cache = KumoServiceReplayCache(maximumEntries: 2)

        XCTAssertTrue(KumoServiceRequestSigner.validate(
            first,
            credentials: credentials,
            now: start,
            replayCache: &cache
        ))
        XCTAssertFalse(KumoServiceRequestSigner.validate(
            first,
            credentials: credentials,
            now: start,
            replayCache: &cache
        ))

        let afterWindow = start.addingTimeInterval(301)
        let reused = signer.signedRequest(
            method: "GET",
            path: "/status",
            timestamp: afterWindow,
            nonce: "reusable-after-window"
        )
        XCTAssertTrue(KumoServiceRequestSigner.validate(
            reused,
            credentials: credentials,
            now: afterWindow,
            replayCache: &cache
        ))
        for nonce in ["second", "third"] {
            let request = signer.signedRequest(
                method: "GET",
                path: "/status",
                timestamp: afterWindow,
                nonce: nonce
            )
            XCTAssertTrue(KumoServiceRequestSigner.validate(
                request,
                credentials: credentials,
                now: afterWindow,
                replayCache: &cache
            ))
        }
        XCTAssertEqual(cache.count, 2)
    }

    func testTransportRequestRoundTripsSignedBody() throws {
        let signer = KumoServiceRequestSigner(
            credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        )
        let request = signer.signedRequest(method: "POST", path: "/sysproxy/enable", body: Data("{}".utf8))

        let transport = KumoServiceTransportRequest(request: request)
        let decoded = try JSONDecoder().decode(
            KumoServiceTransportRequest.self,
            from: JSONEncoder().encode(transport)
        ).signedRequest

        XCTAssertEqual(decoded.method, request.method)
        XCTAssertEqual(decoded.path, request.path)
        XCTAssertEqual(decoded.body, request.body)
        XCTAssertEqual(decoded.headers, request.headers)
    }

    func testControllerStatusUsesRunningServiceBackend() throws {
        let root = URL(
            fileURLWithPath: "/tmp/kumo-service-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("user", isDirectory: true),
            privilegedRuntimeRootDirectory: root.appendingPathComponent("run", isDirectory: true)
        )
        let credentials = try KumoServiceManager(paths: paths).ensureCredentials()
        let socketFile = paths.privilegedServiceSocketFile(userID: getuid())
        try FileManager.default.createDirectory(
            at: socketFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistedSettings = SystemProxySettings(
            networkService: "Stale Wi-Fi",
            port: 7890
        )
        try CoreStateStore(paths: paths).save(CoreStatus(
            systemProxySettings: persistedSettings
        ))
        let helperSettings = SystemProxySettings(
            networkService: "Helper Ethernet",
            port: 8899
        )
        let coreStatus = CoreStatus(
            state: .running,
            pid: 42,
            systemProxyEnabled: true,
            systemProxySettings: helperSettings,
            message: "from fake service"
        )
        let fakeService = FakeKumoService(
            socketPath: socketFile.path,
            credentials: credentials,
            responses: [
                "/service/handshake": try JSONEncoder().encode(KumoServiceHandshake.current(
                    helperVersion: "test"
                )),
                "/service/status": try JSONEncoder().encode(ServiceModeStatus(
                    isInstalled: true,
                    isRunning: true,
                    isAvailable: true,
                    isCurrentProcessPrivileged: true,
                    socketPath: socketFile.path,
                    installationHealth: .current
                )),
                "/status": try JSONEncoder().encode(coreStatus)
            ]
        )
        try fakeService.start(expectedRequestCount: 3)
        defer { fakeService.stop() }

        let status = try KumoController(paths: paths).status()

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 42)
        XCTAssertEqual(status.message, "from fake service")
        XCTAssertEqual(status.systemProxySettings, helperSettings)
    }

    func testServiceModeStatusConsumesPrivilegedInstallationHealthAfterHandshake() throws {
        let root = URL(
            fileURLWithPath: "/tmp/kumo-health-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("user", isDirectory: true),
            privilegedRuntimeRootDirectory: root.appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: root.appendingPathComponent("service", isDirectory: true),
            serviceExecutableFile: root.appendingPathComponent("helper/KumoService"),
            serviceLaunchDaemonPlistFile: root.appendingPathComponent("launchd/io.kumo.KumoService.plist")
        )
        let manager = KumoServiceManager(paths: paths)
        let credentials = try manager.ensureCredentials()
        let socketFile = paths.privilegedServiceSocketFile(userID: getuid())
        try FileManager.default.createDirectory(
            at: socketFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let privilegedStatus = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: false,
            isCurrentProcessPrivileged: true,
            socketPath: socketFile.path,
            installationHealth: .partial,
            message: "Privileged installation inspection found missing credentials."
        )
        let fakeService = FakeKumoService(
            socketPath: socketFile.path,
            credentials: credentials,
            responses: [
                "/service/handshake": try JSONEncoder().encode(KumoServiceHandshake.current(
                    helperVersion: "test"
                )),
                "/service/status": try JSONEncoder().encode(privilegedStatus)
            ]
        )
        try fakeService.start(expectedRequestCount: 2)
        defer { fakeService.stop() }

        let status = manager.status()

        XCTAssertTrue(status.isInstalled)
        XCTAssertTrue(status.isRunning)
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(status.installationHealth, .partial)
        XCTAssertTrue(status.requiresRepair)
    }

    func testServiceRuntimeMirrorKeepsObservedSettingsUntilRuntimeIsFullyStopped() throws {
        let paths = KumoPaths(
            applicationSupportDirectory: temporaryDirectory()
                .appendingPathComponent("runtime-mirror", isDirectory: true),
            privilegedRuntimeRootDirectory: temporaryDirectory()
                .appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: temporaryDirectory()
                .appendingPathComponent("service", isDirectory: true)
        )
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let desired = SystemProxySettings(networkService: "Desired Wi-Fi", port: 7890)
        let observed = SystemProxySettings(networkService: "Observed Ethernet", port: 8899)
        try controller.stateStore.save(CoreStatus(systemProxySettings: desired))

        _ = try controller.persistServiceRuntimeMirror(CoreStatus(
            state: .running,
            pid: 42,
            systemProxyEnabled: true,
            systemProxySettings: observed
        ))
        XCTAssertEqual(try controller.stateStore.load().systemProxySettings, observed)

        try controller.stateStore.save(CoreStatus(systemProxySettings: desired))
        _ = try controller.persistServiceRuntimeMirror(CoreStatus())
        XCTAssertEqual(try controller.stateStore.load().systemProxySettings, desired)
    }

    func testPrivilegedControllerServiceStatusDoesNotTouchUserApplicationSupport() throws {
        let root = temporaryDirectory()
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        let userSupport = root.appendingPathComponent("user-support", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: userSupport, withDestinationURL: victim)
        let paths = KumoPaths(
            applicationSupportDirectory: userSupport,
            privilegedRuntimeRootDirectory: root.appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: root.appendingPathComponent("service", isDirectory: true)
        )
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            stateFileOwnership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )

        let status = controller.serviceModeStatus()

        XCTAssertTrue(status.isCurrentProcessPrivileged)
        XCTAssertEqual(
            status.socketPath,
            paths.privilegedServiceSocketFile(userID: getuid()).path
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor ServiceMutationProbe {
    private var concurrentCount = 0
    private(set) var maximumConcurrentCount = 0

    func enter() {
        concurrentCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, concurrentCount)
    }

    func leave() {
        concurrentCount -= 1
    }
}

final class FakeKumoService: @unchecked Sendable {
    private let socketPath: String
    private let credentials: KumoServiceCredentials
    private let responses: [String: Data]
    private let statusCodes: [String: Int]
    private let ready = DispatchSemaphore(value: 0)
    private let requestsLock = NSLock()
    private var recordedRequests: [KumoServiceSignedRequest] = []
    private var descriptor: Int32 = -1

    var requests: [KumoServiceSignedRequest] {
        requestsLock.withLock { recordedRequests }
    }

    init(
        socketPath: String,
        credentials: KumoServiceCredentials,
        responses: [String: Data],
        statusCodes: [String: Int] = [:]
    ) {
        self.socketPath = socketPath
        self.credentials = credentials
        self.responses = responses
        self.statusCodes = statusCodes
    }

    func start(expectedRequestCount: Int) throws {
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Unable to create fake service socket.")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
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
        guard bindResult == 0, listen(descriptor, 4) == 0 else {
            throw KumoError.serviceUnavailable("Unable to bind fake service socket.")
        }

        DispatchQueue.global().async {
            self.ready.signal()
            var seenNonces = Set<String>()
            for _ in 0..<expectedRequestCount {
                let client = accept(self.descriptor, nil, nil)
                guard client >= 0 else { continue }
                defer { close(client) }
                let response = self.handle(client: client, seenNonces: &seenNonces)
                try? self.write(response: response, to: client)
            }
        }
        ready.wait()
    }

    func stop() {
        if descriptor >= 0 {
            close(descriptor)
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func handle(client: Int32, seenNonces: inout Set<String>) -> KumoServiceTransportResponse {
        do {
            let data = try readAll(from: client)
            let request = try JSONDecoder().decode(KumoServiceTransportRequest.self, from: data).signedRequest
            guard KumoServiceRequestSigner.validate(request, credentials: credentials, seenNonces: &seenNonces) else {
                return KumoServiceTransportResponse(status: 401, error: "invalid signature")
            }
            requestsLock.withLock {
                recordedRequests.append(request)
            }
            guard let body = responses[request.path] else {
                return KumoServiceTransportResponse(status: 404, error: request.path)
            }
            let status = statusCodes[request.path] ?? 200
            return KumoServiceTransportResponse(
                status: status,
                body: body,
                error: status == 409 ? KumoError.runtimeGenerationConflict.localizedDescription : nil
            )
        } catch {
            return KumoServiceTransportResponse(status: 500, error: error.localizedDescription)
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            guard count > 0 else {
                throw KumoError.serviceUnavailable("fake read failed")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func write(response: KumoServiceTransportResponse, to descriptor: Int32) throws {
        let data = try JSONEncoder().encode(response)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)
                guard result > 0 else { throw KumoError.serviceUnavailable("fake write failed") }
                bytesWritten += result
            }
        }
    }
}
