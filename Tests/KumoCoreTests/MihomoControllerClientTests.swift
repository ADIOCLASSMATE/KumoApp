import XCTest
@testable import KumoCoreKit

final class MihomoControllerClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testProxyGroupsMapControllerResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/proxies")
            let data = Data(
                """
                {
                  "proxies": {
                    "Proxy": { "type": "Selector", "now": "HK", "all": ["HK", "US"] },
                    "HK": { "type": "Shadowsocks", "history": [{ "delay": 120 }] },
                    "US": { "type": "Shadowsocks", "history": [{ "delay": 200 }] },
                    "Hidden": { "type": "Selector", "hidden": true, "all": ["HK"] }
                  }
                }
                """.utf8
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = MihomoControllerClient(session: mockSession())

        let groups = try await client.proxyGroups()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Proxy")
        XCTAssertEqual(groups.first?.selectedProxyName, "HK")
        XCTAssertEqual(groups.first?.proxies.map(\.delay), [120, 200])
    }

    func testTrafficStreamParserMapsMihomoMetaPayload() throws {
        // Mihomo Meta emits per-second speeds as `up`/`down` and cumulative totals as
        // `upTotal`/`downTotal`. Verify the WS parser routes them into the right fields so the
        // overview's traffic card stops permanently displaying zero.
        let payload = """
        {"up":1234,"down":5678,"upTotal":111,"downTotal":222}
        """
        let snapshot = try parseTrafficSnapshot(payload)
        XCTAssertEqual(snapshot.uploadSpeed, 1234)
        XCTAssertEqual(snapshot.downloadSpeed, 5678)
        XCTAssertEqual(snapshot.upload, 111)
        XCTAssertEqual(snapshot.download, 222)
    }

    func testTrafficStreamParserFallsBackToLegacyFieldNames() throws {
        // Older mihomo builds (and some forks) only emit `{up, down}` without totals.
        let payload = """
        {"up":42,"down":99}
        """
        let snapshot = try parseTrafficSnapshot(payload)
        XCTAssertEqual(snapshot.uploadSpeed, 42)
        XCTAssertEqual(snapshot.downloadSpeed, 99)
        XCTAssertEqual(snapshot.upload, 0)
        XCTAssertEqual(snapshot.download, 0)
    }

    func testConnectionsMapControllerResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/connections")
            let data = Data(
                """
                {
                  "connections": [
                    {
                      "id": "abc",
                      "metadata": {
                        "host": "example.com",
                        "process": "Safari",
                        "processPath": "/Applications/Safari.app/Contents/MacOS/Safari"
                      },
                      "rule": "MATCH",
                      "chains": ["Proxy", "HK"],
                      "upload": 10,
                      "download": 20
                    }
                  ]
                }
                """.utf8
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = MihomoControllerClient(session: mockSession())

        let connections = try await client.connections()

        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections.first?.id, "abc")
        XCTAssertEqual(connections.first?.host, "example.com")
        XCTAssertEqual(connections.first?.process, "Safari")
        XCTAssertEqual(connections.first?.processPath, "/Applications/Safari.app/Contents/MacOS/Safari")
        XCTAssertEqual(connections.first?.chain, ["Proxy", "HK"])
    }

    func testRuntimeMutationsMapToExpectedMihomoRoutes() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var received: [(method: String, path: String, body: Data?)] = []
        MockURLProtocol.requestHandler = { request in
            lock.withLock {
                received.append((
                    request.httpMethod ?? "",
                    request.url?.path ?? "",
                    request.bodyData
                ))
            }
            let data: Data
            if request.httpMethod == "GET", request.url?.path == "/configs" {
                data = Data(#"{"mode":"direct"}"#.utf8)
            } else {
                data = Data("{}".utf8)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data
            )
        }
        let client = MihomoControllerClient(session: mockSession())

        try await client.apply(.setMode(.direct))
        try await client.apply(.selectProxy(group: "Proxy", name: "Node B"))
        try await client.apply(.setRuleEnabled(index: 7, isEnabled: false))
        try await client.apply(.closeConnection(id: "connection-1"))
        try await client.apply(.closeConnections(matchingProxy: nil))
        try await client.apply(.updateProxyProvider(name: "provider-a"))
        try await client.apply(.updateRuleProvider(name: "rules-a"))
        try await client.apply(.upgradeGeoData)

        XCTAssertEqual(
            lock.withLock { received.map { "\($0.method) \($0.path)" } },
            [
                "PATCH /configs",
                "GET /configs",
                "PUT /proxies/Proxy",
                "PATCH /rules/disable",
                "DELETE /connections/connection-1",
                "DELETE /connections",
                "PUT /providers/proxies/provider-a",
                "PUT /providers/rules/rules-a",
                "POST /upgrade/geo"
            ]
        )
        let routed = lock.withLock { received }
        let selectionBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(routed[2].body))
                as? [String: String]
        )
        XCTAssertEqual(selectionBody, ["name": "Node B"])
        let ruleBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(routed[3].body))
                as? [String: Bool]
        )
        XCTAssertEqual(ruleBody, ["7": true])
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func parseTrafficSnapshot(_ text: String) throws -> TrafficSnapshot {
        let client = MihomoControllerClient()
        let snapshot = client.trafficSnapshot(from: text)
        return try XCTUnwrap(snapshot)
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: KumoError.invalidArguments("Missing mock request handler."))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
