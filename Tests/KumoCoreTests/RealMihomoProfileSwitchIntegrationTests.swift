import Darwin
import CryptoKit
import Foundation
import XCTest
import Yams
@testable import KumoCoreKit

final class RealMihomoProfileSwitchIntegrationTests: XCTestCase {
    func testRealMihomoSwitchesExactProfilesAndActivatesBase64Subscription() async throws {
        guard let corePath = ProcessInfo.processInfo.environment["KUMO_REAL_MIHOMO_PATH"],
              FileManager.default.isExecutableFile(atPath: corePath) else {
            throw XCTSkip("Set KUMO_REAL_MIHOMO_PATH to run the isolated real-Mihomo integration test.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-real-switch-\(UUID().uuidString)", isDirectory: true)
        let paths = KumoPaths(applicationSupportDirectory: root)
        let providerServer = try LocalProviderHTTPServer(
            responses: [
                "/proxy-a.yaml": """
                proxies:
                  - {name: Provider-A, type: http, server: 127.0.0.1, port: 65530}
                """,
                "/proxy-b.yaml": """
                proxies:
                  - {name: Provider-B, type: http, server: 127.0.0.1, port: 65531}
                """,
                "/rule-a.yaml": "payload: ['DOMAIN-SUFFIX,a.provider.test']",
                "/rule-b.yaml": "payload: ['DOMAIN-SUFFIX,b.provider.test']"
            ]
        )
        providerServer.start()
        defer { providerServer.stop() }
        let controllerPort = try await SubStorePortAllocator.availablePort(
            startingAt: Int.random(in: 41_000...44_000),
            allowLAN: false
        )
        let mixedPort = try await SubStorePortAllocator.availablePort(
            startingAt: Int.random(in: 45_000...48_000),
            allowLAN: false
        )
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(
            CoreStatus(
                corePath: corePath,
                endpoint: ControllerEndpoint(port: controllerPort),
                proxyPorts: ProxyPortConfiguration(mixedPort: mixedPort),
                runtimeSettings: CoreRuntimeSettings(mixedPort: mixedPort)
            )
        )
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            directProfile(name: "Profile A"),
            preferredID: "profile-a",
            makeCurrent: true
        )
        _ = try repository.saveProfile(
            directProfile(name: "Profile B"),
            preferredID: "profile-b"
        )
        let providerProfileA = httpProviderProfile(
            name: "Provider Profile A",
            proxyURL: providerServer.url(path: "/proxy-a.yaml"),
            ruleURL: providerServer.url(path: "/rule-a.yaml")
        )
        let providerProfileB = httpProviderProfile(
            name: "Provider Profile B",
            proxyURL: providerServer.url(path: "/proxy-b.yaml"),
            ruleURL: providerServer.url(path: "/rule-b.yaml")
        )
        _ = try repository.saveProfile(
            providerProfileA,
            preferredID: "provider-a"
        )
        _ = try repository.saveProfile(
            providerProfileB,
            preferredID: "provider-b"
        )
        let controller = KumoController(paths: paths, useServiceBackend: false)

        do {
            _ = try await controller.activateProfile(id: "profile-a", policy: .ensureRunning)
            let statusA = try controller.status()
            let groupsA = try await controller.proxyGroups()
            XCTAssertEqual(statusA.activeProfileID, "profile-a")
            XCTAssertEqual(statusA.readiness, .controllerReady)
            try assertRuntimeConfigurationDigest(statusA, paths: paths)
            XCTAssertTrue(groupsA.contains { $0.name == "Profile A" })
            XCTAssertFalse(groupsA.contains { $0.name == "Profile B" })

            _ = try await controller.activateProfile(id: "profile-b", policy: .preserveRunState)
            let statusB = try controller.status()
            let groupsB = try await controller.proxyGroups()
            XCTAssertEqual(statusB.activeProfileID, "profile-b")
            XCTAssertEqual(statusB.readiness, .controllerReady)
            try assertRuntimeConfigurationDigest(statusB, paths: paths)
            XCTAssertNotEqual(statusB.runtimeGeneration, statusA.runtimeGeneration)
            XCTAssertNotEqual(statusB.configurationDigest, statusA.configurationDigest)
            XCTAssertTrue(groupsB.contains { $0.name == "Profile B" })
            XCTAssertFalse(groupsB.contains { $0.name == "Profile A" })

            _ = try await controller.activateProfile(id: "provider-a", policy: .preserveRunState)
            let providerStatusA = try controller.status()
            let providerGroupsA = try await controller.proxyGroups()
            XCTAssertEqual(providerStatusA.activeProfileID, "provider-a")
            try assertRuntimeConfigurationDigest(providerStatusA, paths: paths)
            XCTAssertTrue(providerGroupsA.flatMap(\.proxies).contains { $0.name == "Provider-A" })
            XCTAssertFalse(providerGroupsA.flatMap(\.proxies).contains { $0.name == "Provider-B" })
            try await waitForProviderRequests(
                ["/proxy-a.yaml"],
                from: providerServer
            )
            try assertProxyProviderCacheExists(
                profile: providerProfileA,
                profileID: "provider-a",
                paths: paths,
                controllerPort: controllerPort,
                mixedPort: mixedPort
            )

            _ = try await controller.activateProfile(id: "provider-b", policy: .preserveRunState)
            let providerStatusB = try controller.status()
            let providerGroupsB = try await controller.proxyGroups()
            XCTAssertEqual(providerStatusB.activeProfileID, "provider-b")
            try assertRuntimeConfigurationDigest(providerStatusB, paths: paths)
            XCTAssertNotEqual(providerStatusB.runtimeGeneration, providerStatusA.runtimeGeneration)
            XCTAssertNotEqual(providerStatusB.configurationDigest, providerStatusA.configurationDigest)
            XCTAssertTrue(providerGroupsB.flatMap(\.proxies).contains { $0.name == "Provider-B" })
            XCTAssertFalse(providerGroupsB.flatMap(\.proxies).contains { $0.name == "Provider-A" })
            try await waitForProviderRequests(
                ["/proxy-b.yaml"],
                from: providerServer
            )
            try assertProxyProviderCacheExists(
                profile: providerProfileB,
                profileID: "provider-b",
                paths: paths,
                controllerPort: controllerPort,
                mixedPort: mixedPort
            )

            let uri = "vless://00000000-0000-4000-8000-000000000000@example.com:443?encryption=none&security=tls#Base64-Node"
            let encoded = Data(uri.utf8).base64EncodedString()
            let normalized = try await ProfileContentNormalizer(
                converter: IsolatedSubStoreSubscriptionConverter()
            ).normalize(encoded)
            _ = try repository.saveProfile(
                Profile(name: "Base64", source: .inline, rawYAML: normalized),
                preferredID: "base64"
            )

            _ = try await controller.activateProfile(id: "base64", policy: .preserveRunState)
            let base64Status = try controller.status()
            let base64Groups = try await controller.proxyGroups()
            XCTAssertEqual(base64Status.activeProfileID, "base64")
            try assertRuntimeConfigurationDigest(base64Status, paths: paths)
            XCTAssertNotEqual(base64Status.runtimeGeneration, providerStatusB.runtimeGeneration)
            XCTAssertNotEqual(base64Status.configurationDigest, providerStatusB.configurationDigest)
            XCTAssertTrue(base64Groups.flatMap(\.proxies).contains { $0.name == "Base64-Node" })

            let stopped = try await controller.stopSafely()
            XCTAssertTrue(stopped.isStrictlyStoppedRuntime)
        } catch {
            _ = try? await controller.stopSafely()
            try? FileManager.default.removeItem(at: root)
            throw error
        }

        try? FileManager.default.removeItem(at: root)
    }

    private func directProfile(name: String) -> Profile {
        Profile(
            name: name,
            source: .inline,
            rawYAML: """
            proxies: []
            proxy-groups:
              - name: \(name)
                type: select
                proxies:
                  - DIRECT
            rules:
              - MATCH,\(name)
            """
        )
    }

    private func httpProviderProfile(name: String, proxyURL: URL, ruleURL: URL) -> Profile {
        Profile(
            name: name,
            source: .inline,
            rawYAML: """
            proxy-providers:
              shared:
                type: http
                url: \(proxyURL.absoluteString)
                path: ./providers/shared-proxy.yaml
                interval: 3600
                health-check: {enable: false}
            rule-providers:
              shared-rules:
                type: http
                behavior: domain
                format: yaml
                url: \(ruleURL.absoluteString)
                path: ./providers/shared-rule.yaml
                interval: 3600
            proxy-groups:
              - name: \(name)
                type: select
                use: [shared]
            rules:
              - RULE-SET,shared-rules,\(name)
              - MATCH,\(name)
            """
        )
    }

    private func waitForProviderRequests(
        _ expectedPaths: Set<String>,
        from server: LocalProviderHTTPServer
    ) async throws {
        for _ in 0..<50 {
            if expectedPaths.isSubset(of: server.requestedPaths) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let actualPaths = server.requestedPaths.sorted().joined(separator: ", ")
        throw KumoError.commandFailed(
            "Mihomo did not fetch the expected provider URLs: \(expectedPaths.sorted().joined(separator: ", ")); "
                + "observed: \(actualPaths.isEmpty ? "none" : actualPaths)."
        )
    }

    private func assertProxyProviderCacheExists(
        profile: Profile,
        profileID: String,
        paths: KumoPaths,
        controllerPort: Int,
        mixedPort: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let runtime = try RuntimeConfigBuilder(
            endpoint: ControllerEndpoint(port: controllerPort),
            proxyPorts: ProxyPortConfiguration(mixedPort: mixedPort),
            runtimeSettings: CoreRuntimeSettings(mixedPort: mixedPort)
        ).build(profile: profile, profileID: profileID)
        let mapping = try XCTUnwrap(Yams.load(yaml: runtime.yaml) as? [String: Any], file: file, line: line)
        let providers = try XCTUnwrap(mapping["proxy-providers"] as? [String: Any], file: file, line: line)
        let provider = try XCTUnwrap(providers["shared"] as? [String: Any], file: file, line: line)
        let relativePath = try XCTUnwrap(provider["path"] as? String, file: file, line: line)
            .replacingOccurrences(of: "./", with: "", options: .anchored)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.workDirectory.appendingPathComponent(relativePath).path
            ),
            "Mihomo did not persist the proxy provider in the generated profile namespace.",
            file: file,
            line: line
        )
    }

    private func assertRuntimeConfigurationDigest(
        _ status: CoreStatus,
        paths: KumoPaths,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let observedDigest = try XCTUnwrap(
            status.configurationDigest,
            "A controller-ready runtime must expose its exact configuration digest.",
            file: file,
            line: line
        )
        let projectedConfiguration = try Data(contentsOf: paths.runtimeConfigFile)
        let expectedDigest = SHA256.hash(data: projectedConfiguration)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            observedDigest,
            expectedDigest,
            "The observed runtime identity must match the exact YAML projected for this generation.",
            file: file,
            line: line
        )
    }
}

private final class LocalProviderHTTPServer: @unchecked Sendable {
    private let responses: [String: Data]
    private let queue = DispatchQueue(label: "io.kumo.tests.provider-http-server")
    private let lock = NSLock()
    private var descriptor: Int32
    private var stopped = false
    private var recordedPaths = Set<String>()
    let port: Int

    init(responses: [String: String]) throws {
        self.responses = responses.mapValues { Data($0.utf8) }
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw POSIXError(.EIO)
        }

        var reuseAddress: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, 8) == 0 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(.EIO)
        }
        descriptor = socketDescriptor
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    var requestedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func start() {
        queue.async { [self] in
            while true {
                let client = Darwin.accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                handle(client: client)
                Darwin.close(client)
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let socket = descriptor
        descriptor = -1
        lock.unlock()
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func handle(client: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while request.count < 16_384 {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(contentsOf: buffer.prefix(Int(count)))
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let requestText = String(data: request, encoding: .utf8),
              let target = requestText.split(separator: " ").dropFirst().first else {
            return
        }
        let path = URL(string: String(target))?.path ?? String(target)
        lock.lock()
        recordedPaths.insert(path)
        lock.unlock()

        let body = responses[path]
        let status = body == nil ? "404 Not Found" : "200 OK"
        let payload = body ?? Data()
        var response = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: text/yaml\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8
        )
        response.append(payload)
        response.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}
