import Darwin
import Foundation
import XCTest
@_spi(KumoService) @testable import KumoCoreKit

final class RuntimeBackendTests: XCTestCase {
    func testRuntimeSnapshotExposesIdentityOnlyForConfirmedRuntime() {
        let generation = UUID()
        let digest = String(repeating: "a", count: 64)

        let starting = RuntimeSnapshot(status: CoreStatus(
            state: .starting,
            readiness: .processLaunched,
            activeProfileID: "profile-a",
            runtimeGeneration: generation,
            configurationDigest: digest
        ))
        let ready = RuntimeSnapshot(status: CoreStatus(
            state: .running,
            readiness: .controllerReady,
            activeProfileID: "profile-a",
            runtimeGeneration: generation,
            configurationDigest: digest
        ))

        XCTAssertNil(starting.identity)
        XCTAssertEqual(
            ready.identity,
            RuntimeIdentity(
                profileID: "profile-a",
                generation: generation,
                configurationDigest: digest
            )
        )
    }

    func testRuntimeGenerationExpectationHasStableTaggedEncoding() throws {
        let generation = UUID()
        let expectation = RuntimeGenerationExpectation.matching(generation)

        let data = try JSONEncoder().encode(expectation)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        XCTAssertEqual(object["kind"], "matching")
        XCTAssertEqual(object["generation"], generation.uuidString)
        XCTAssertEqual(
            try JSONDecoder().decode(RuntimeGenerationExpectation.self, from: data),
            expectation
        )
    }

    func testRuntimeMutationHasStableTaggedEncoding() throws {
        let fixtures: [(RuntimeMutation, String)] = [
            (.setMode(.direct), #"{"kind":"setMode","mode":"direct"}"#),
            (
                .selectProxy(group: "Proxy", name: "Node B"),
                #"{"group":"Proxy","kind":"selectProxy","name":"Node B"}"#
            ),
            (
                .setRuleEnabled(index: 7, isEnabled: false),
                #"{"index":7,"isEnabled":false,"kind":"setRuleEnabled"}"#
            ),
            (.closeConnection(id: "connection-1"), #"{"id":"connection-1","kind":"closeConnection"}"#),
            (
                .closeConnections(matchingProxy: "Node B"),
                #"{"kind":"closeConnections","matchingProxy":"Node B"}"#
            ),
            (.closeConnections(matchingProxy: nil), #"{"kind":"closeConnections"}"#),
            (
                .updateProxyProvider(name: "provider-a"),
                #"{"kind":"updateProxyProvider","name":"provider-a"}"#
            ),
            (
                .updateRuleProvider(name: "rules-a"),
                #"{"kind":"updateRuleProvider","name":"rules-a"}"#
            ),
            (.upgradeGeoData, #"{"kind":"upgradeGeoData"}"#)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (mutation, expectedJSON) in fixtures {
            let data = try encoder.encode(mutation)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), expectedJSON)
            XCTAssertEqual(try JSONDecoder().decode(RuntimeMutation.self, from: data), mutation)
        }
    }

    func testLaunchRequestWithoutGenerationExpectationIsRejected() throws {
        let spec = try runtimeSpec(profileID: "profile-a")
        let legacyPayload = try JSONSerialization.data(withJSONObject: [
            "spec": try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec))
        ])

        XCTAssertThrowsError(
            try JSONDecoder().decode(CoreRuntimeLaunchRequest.self, from: legacyPayload)
        )
    }

    func testServiceBackendReturnsConfirmedIdentityAfterCompatibleHandshake() async throws {
        let socketPath = "/tmp/kumo-rb-\(UUID().uuidString.prefix(8)).sock"
        let credentials = KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        let spec = try runtimeSpec(profileID: "profile-a")
        let generation = UUID()
        let readyStatus = CoreStatus(
            state: .running,
            pid: 42,
            mode: spec.mode,
            endpoint: spec.endpoint,
            proxyPorts: spec.proxyPorts,
            readiness: .controllerReady,
            activeProfileID: spec.profileID,
            runtimeGeneration: generation,
            configurationDigest: spec.configurationDigest
        )
        let service = FakeKumoService(
            socketPath: socketPath,
            credentials: credentials,
            responses: [
                "/service/handshake": try JSONEncoder().encode(
                    KumoServiceHandshake.current(helperVersion: "test")
                ),
                "/core/start": try JSONEncoder().encode(readyStatus)
            ]
        )
        try service.start(expectedRequestCount: 2)
        defer { service.stop() }
        let serviceStatus = availableServiceStatus(socketPath: socketPath)
        let backend = try ServiceRuntimeBackend(
            client: KumoServiceClient(
                endpoint: KumoServiceEndpoint(socketPath: socketPath),
                credentials: credentials
            ),
            serviceStatusProvider: { serviceStatus }
        )

        let snapshot = try await backend.start(
            spec,
            systemProxySettings: nil,
            expecting: .stopped
        )

        XCTAssertEqual(
            snapshot.identity,
            RuntimeIdentity(
                profileID: spec.profileID,
                generation: generation,
                configurationDigest: spec.configurationDigest
            )
        )
    }

    func testServiceBackendSurfacesGenerationConflictWithoutFallbackMutation() async throws {
        let socketPath = "/tmp/kumo-rb-\(UUID().uuidString.prefix(8)).sock"
        let credentials = KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        let service = FakeKumoService(
            socketPath: socketPath,
            credentials: credentials,
            responses: [
                "/service/handshake": try JSONEncoder().encode(
                    KumoServiceHandshake.current(helperVersion: "test")
                ),
                "/core/stop": Data()
            ],
            statusCodes: ["/core/stop": 409]
        )
        try service.start(expectedRequestCount: 2)
        defer { service.stop() }
        let serviceStatus = availableServiceStatus(socketPath: socketPath)
        let backend = try ServiceRuntimeBackend(
            client: KumoServiceClient(
                endpoint: KumoServiceEndpoint(socketPath: socketPath),
                credentials: credentials
            ),
            serviceStatusProvider: { serviceStatus }
        )

        do {
            _ = try await backend.stop(expecting: .matching(UUID()))
            XCTFail("Expected a generation conflict")
        } catch let error as KumoError {
            XCTAssertEqual(error, .runtimeGenerationConflict)
        }
    }

    func testServiceBackendAppliesRuntimeMutationWithExactGeneration() async throws {
        let socketPath = "/tmp/kumo-rb-\(UUID().uuidString.prefix(8)).sock"
        let credentials = KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        let generation = UUID()
        let readyStatus = CoreStatus(
            state: .running,
            pid: 42,
            readiness: .controllerReady,
            activeProfileID: "profile-a",
            runtimeGeneration: generation,
            configurationDigest: String(repeating: "a", count: 64)
        )
        let service = FakeKumoService(
            socketPath: socketPath,
            credentials: credentials,
            responses: [
                "/service/handshake": try JSONEncoder().encode(
                    KumoServiceHandshake.current(helperVersion: "test")
                ),
                "/runtime/mutate": try JSONEncoder().encode(readyStatus)
            ]
        )
        try service.start(expectedRequestCount: 2)
        defer { service.stop() }
        let serviceStatus = availableServiceStatus(socketPath: socketPath)
        let backend = try ServiceRuntimeBackend(
            client: KumoServiceClient(
                endpoint: KumoServiceEndpoint(socketPath: socketPath),
                credentials: credentials
            ),
            serviceStatusProvider: { serviceStatus }
        )

        let snapshot = try await backend.apply(
            .selectProxy(group: "Proxy", name: "Node B"),
            expecting: .matching(generation)
        )

        XCTAssertEqual(snapshot.status.runtimeGeneration, generation)
    }

    func testServiceBackendRoutesEveryRuntimeMutationWithExactGeneration() async throws {
        let socketPath = "/tmp/kumo-rb-\(UUID().uuidString.prefix(8)).sock"
        let credentials = KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        let generation = UUID()
        let readyStatus = CoreStatus(
            state: .running,
            pid: 42,
            readiness: .controllerReady,
            activeProfileID: "profile-a",
            runtimeGeneration: generation,
            configurationDigest: String(repeating: "a", count: 64)
        )
        let mutations: [RuntimeMutation] = [
            .setMode(.global),
            .selectProxy(group: "Proxy", name: "Node B"),
            .setRuleEnabled(index: 3, isEnabled: false),
            .closeConnection(id: "connection-1"),
            .closeConnections(matchingProxy: "Node B"),
            .updateProxyProvider(name: "provider-a"),
            .updateRuleProvider(name: "rules-a"),
            .upgradeGeoData
        ]
        let service = FakeKumoService(
            socketPath: socketPath,
            credentials: credentials,
            responses: [
                "/service/handshake": try JSONEncoder().encode(
                    KumoServiceHandshake.current(helperVersion: "test")
                ),
                "/runtime/mutate": try JSONEncoder().encode(readyStatus)
            ]
        )
        try service.start(expectedRequestCount: mutations.count * 2)
        defer { service.stop() }
        let serviceStatus = availableServiceStatus(socketPath: socketPath)
        let backend = try ServiceRuntimeBackend(
            client: KumoServiceClient(
                endpoint: KumoServiceEndpoint(socketPath: socketPath),
                credentials: credentials
            ),
            serviceStatusProvider: { serviceStatus }
        )

        for mutation in mutations {
            _ = try await backend.apply(mutation, expecting: .matching(generation))
        }

        let routedRequests = service.requests.filter { $0.path == "/runtime/mutate" }
        let decoded = try routedRequests.map {
            try JSONDecoder().decode(RuntimeMutationRequest.self, from: $0.body)
        }
        XCTAssertEqual(decoded.map(\.mutation), mutations)
        XCTAssertEqual(
            decoded.map(\.expectedGeneration),
            Array(repeating: .matching(generation), count: mutations.count)
        )
    }

    func testServiceBackendRejectsStaleRuntimeMutationWithoutRetryingAnotherRoute() async throws {
        let socketPath = "/tmp/kumo-rb-\(UUID().uuidString.prefix(8)).sock"
        let credentials = KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        let service = FakeKumoService(
            socketPath: socketPath,
            credentials: credentials,
            responses: [
                "/service/handshake": try JSONEncoder().encode(
                    KumoServiceHandshake.current(helperVersion: "test")
                ),
                "/runtime/mutate": Data()
            ],
            statusCodes: ["/runtime/mutate": 409]
        )
        try service.start(expectedRequestCount: 2)
        defer { service.stop() }
        let serviceStatus = availableServiceStatus(socketPath: socketPath)
        let backend = try ServiceRuntimeBackend(
            client: KumoServiceClient(
                endpoint: KumoServiceEndpoint(socketPath: socketPath),
                credentials: credentials
            ),
            serviceStatusProvider: { serviceStatus }
        )

        do {
            _ = try await backend.apply(
                .upgradeGeoData,
                expecting: .matching(UUID())
            )
            XCTFail("Expected a generation conflict")
        } catch let error as KumoError {
            XCTAssertEqual(error, .runtimeGenerationConflict)
        }

        XCTAssertEqual(service.requests.map(\.path), ["/service/handshake", "/runtime/mutate"])
    }

    func testServiceBackendRejectsUnavailableInstallationBeforeAnyMutation() {
        let client = KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: "/tmp/does-not-exist.sock"),
            credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        )
        let partial = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: false,
            socketPath: client.endpoint.socketPath,
            installationHealth: .partial,
            message: "Kumo Helper installation is incomplete."
        )

        XCTAssertThrowsError(try ServiceRuntimeBackend(
            client: client,
            serviceStatusProvider: { partial }
        ))
    }

    func testServiceBackendRechecksInstallationHealthBeforeEveryRequest() async throws {
        let socketPath = "/tmp/does-not-exist.sock"
        let statusBox = LockedServiceStatus(availableServiceStatus(socketPath: socketPath))
        let backend = try ServiceRuntimeBackend(
            client: KumoServiceClient(
                endpoint: KumoServiceEndpoint(socketPath: socketPath),
                credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
            ),
            serviceStatusProvider: { statusBox.value }
        )
        statusBox.value = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: false,
            socketPath: socketPath,
            installationHealth: .unsafe,
            message: "Kumo Helper installation is unsafe."
        )

        do {
            _ = try await backend.status()
            XCTFail("Expected unsafe installation state to block the request")
        } catch let error as KumoError {
            guard case .serviceUnavailable(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("unsafe"))
        }
    }

    func testSupervisorBackendRejectsStaleStopWithoutMutatingRuntime() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let backend = SupervisorRuntimeBackend(
            supervisor: CoreSupervisor(paths: paths),
            corePath: corePath
        )

        let started = try await backend.start(
            runtimeSpec(profileID: "profile-a"),
            systemProxySettings: nil,
            expecting: .stopped
        )
        let generation = try XCTUnwrap(started.status.runtimeGeneration)
        let pid = try XCTUnwrap(started.status.pid)
        defer {
            _ = try? CoreSupervisor(paths: paths).stop()
        }

        do {
            _ = try await backend.stop(expecting: .matching(UUID()))
            XCTFail("Expected stale generation to be rejected")
        } catch let error as KumoError {
            XCTAssertEqual(error, .runtimeGenerationConflict)
        }

        let observed = try await backend.status()
        XCTAssertEqual(observed.status.runtimeGeneration, generation)
        XCTAssertEqual(observed.status.pid, pid)
        XCTAssertTrue(processIsAlive(pid))

        let stopped = try await backend.stop(expecting: .matching(generation))
        XCTAssertTrue(stopped.status.isStrictlyStoppedProcessState)
        XCTAssertFalse(processIsAlive(pid))
    }

    func testSupervisorBackendRejectsStaleRestartBeforeStoppingCurrentRuntime() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let backend = SupervisorRuntimeBackend(
            supervisor: CoreSupervisor(paths: paths),
            corePath: corePath
        )

        let started = try await backend.start(
            runtimeSpec(profileID: "profile-a"),
            systemProxySettings: nil,
            expecting: .stopped
        )
        let generation = try XCTUnwrap(started.status.runtimeGeneration)
        let pid = try XCTUnwrap(started.status.pid)
        defer {
            _ = try? CoreSupervisor(paths: paths).stop()
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await backend.restart(
                self.runtimeSpec(profileID: "profile-b"),
                systemProxySettings: nil,
                expecting: .matching(UUID())
            )
        }

        let observed = try await backend.status()
        XCTAssertEqual(observed.status.runtimeGeneration, generation)
        XCTAssertEqual(observed.status.pid, pid)
        XCTAssertTrue(processIsAlive(pid))
    }

    func testHelperRuntimeMutationRejectsStaleGenerationBeforeControllerRequest() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let started = try controller.supervisor.start(
            configuration: CoreLaunchConfiguration(
                corePath: corePath,
                profileID: "profile-a",
                profile: Profile(
                    name: "profile-a",
                    source: .inline,
                    rawYAML: "proxies: []\nrules: [MATCH,DIRECT]\n"
                )
            )
        )
        let generation = try XCTUnwrap(started.runtimeGeneration)
        let pid = try XCTUnwrap(started.pid)
        defer { _ = try? controller.supervisor.stop() }

        do {
            _ = try await controller.applyRuntimeMutationFromService(
                RuntimeMutationRequest(
                    mutation: .upgradeGeoData,
                    expectedGeneration: .matching(UUID())
                )
            )
            XCTFail("Expected a generation conflict")
        } catch let error as KumoError {
            XCTAssertEqual(error, .runtimeGenerationConflict)
        }

        let observed = try controller.supervisor.status()
        XCTAssertEqual(observed.runtimeGeneration, generation)
        XCTAssertEqual(observed.pid, pid)
        XCTAssertTrue(processIsAlive(pid))
    }

    private func runtimeSpec(profileID: String) throws -> RuntimeSpec {
        let profileYAML = """
        proxies: []
        proxy-groups:
          - name: Proxy
            type: select
            proxies: [DIRECT]
        rules: [MATCH,DIRECT]
        """
        let endpoint = ControllerEndpoint(port: 19_097)
        let ports = ProxyPortConfiguration(mixedPort: 17_890)
        let settings = CoreRuntimeSettings(mixedPort: ports.mixedPort)
        let runtime = try RuntimeConfigBuilder(
            endpoint: endpoint,
            proxyPorts: ports,
            mode: .rule,
            runtimeSettings: settings
        ).build(
            profile: Profile(name: profileID, source: .inline, rawYAML: profileYAML),
            profileID: profileID
        )
        return RuntimeSpec(
            profileID: profileID,
            profileYAML: profileYAML,
            overrideYAMLs: [],
            endpoint: endpoint,
            proxyPorts: ports,
            mode: .rule,
            runtimeSettings: settings,
            configurationDigest: runtime.configurationDigest
        )
    }

    private func availableServiceStatus(socketPath: String) -> ServiceModeStatus {
        ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            socketPath: socketPath,
            installationHealth: .current,
            helperProtocolVersion: KumoServiceProtocol.currentVersion,
            helperVersion: "test",
            helperCapabilities: [
                .runtimeActivationReceipt,
                .atomicRuntimeGenerationCAS,
                .privilegedInstallationHealth,
                .routedRuntimeMutations
            ]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-runtime-backend-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeLongRunningCore(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-mihomo")
        let script = """
        #!/bin/sh
        if [ "$1" = "-t" ]; then
          exit 0
        fi
        trap 'exit 0' TERM INT
        while true; do sleep 1; done
        """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
        return url.path
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

private func processIsAlive(_ pid: Int32) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private final class LockedServiceStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ServiceModeStatus

    init(_ value: ServiceModeStatus) {
        self.storedValue = value
    }

    var value: ServiceModeStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
