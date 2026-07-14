import Foundation
import XCTest
@testable import KumoCoreKit

final class ProfileContentNormalizerTests: XCTestCase {
    func testValidMihomoYAMLPassesThroughWithoutCallingConverter() async throws {
        let converter = RecordingSubscriptionConverter(output: "")
        let normalizer = ProfileContentNormalizer(converter: converter)
        let input = """
        proxy-providers:
          remote:
            type: http
            url: https://example.com/provider.yaml
            path: ./providers/remote.yaml
        proxy-groups:
          - name: Proxy
            type: select
            use:
              - remote
        rules:
          - MATCH,Proxy
        """

        let output = try await normalizer.normalize(input)
        let snapshot = await converter.snapshot()

        XCTAssertEqual(output, input)
        XCTAssertEqual(snapshot.callCount, 0)
    }

    func testBase64SubscriptionIsConvertedAndCompletedForMihomo() async throws {
        let converter = RecordingSubscriptionConverter(output: convertedProxyYAML)
        let normalizer = ProfileContentNormalizer(converter: converter)
        let uriList = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#Alpha"
        let encoded = Data(uriList.utf8).base64EncodedString()

        let output = try await normalizer.normalize(encoded)
        let snapshot = await converter.snapshot()

        XCTAssertEqual(snapshot.callCount, 1)
        XCTAssertEqual(snapshot.lastInput, encoded)
        XCTAssertEqual(try ProfileNodeParser.parseNodes(yaml: output).keys.sorted(), ["Alpha"])
        XCTAssertFalse(try ProfileNodeParser.parseProxyGroupNames(yaml: output).isEmpty)
        XCTAssertTrue(output.contains("MATCH,"))
    }

    func testPlainNodeURIListUsesSameConversionPath() async throws {
        let converter = RecordingSubscriptionConverter(output: convertedProxyYAML)
        let normalizer = ProfileContentNormalizer(converter: converter)
        let input = """
        vless://00000000-0000-0000-0000-000000000000@example.com:443#Alpha
        hysteria2://password@example.net:8443#Beta
        """

        _ = try await normalizer.normalize(input)
        let snapshot = await converter.snapshot()

        XCTAssertEqual(snapshot.callCount, 1)
        XCTAssertEqual(snapshot.lastInput, input)
    }

    func testUnsupportedScalarIsRejectedWithoutLeakingItsContents() async {
        let secret = "not-a-profile-secret-value"
        let converter = RecordingSubscriptionConverter(output: convertedProxyYAML)
        let normalizer = ProfileContentNormalizer(converter: converter)

        do {
            _ = try await normalizer.normalize(secret)
            XCTFail("Expected unsupported profile content to fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }

        let snapshot = await converter.snapshot()
        XCTAssertEqual(snapshot.callCount, 0)
    }

    func testConvertedDocumentMustContainUsableProxies() async {
        let converter = RecordingSubscriptionConverter(output: "proxies: []")
        let normalizer = ProfileContentNormalizer(converter: converter)

        await XCTAssertThrowsNormalizationError {
            _ = try await normalizer.normalize(
                Data("ss://example".utf8).base64EncodedString()
            )
        }
    }

    private var convertedProxyYAML: String {
        """
        proxies:
          - name: Alpha
            type: ss
            server: example.com
            port: 443
            cipher: aes-128-gcm
            password: test
        """
    }
}

private actor RecordingSubscriptionConverter: ProfileSubscriptionConverting {
    private(set) var callCount = 0
    private(set) var lastInput: String?
    private let output: String

    init(output: String) {
        self.output = output
    }

    func convertSubscription(_ content: String) async throws -> String {
        callCount += 1
        lastInput = content
        return output
    }

    func snapshot() -> (callCount: Int, lastInput: String?) {
        (callCount, lastInput)
    }
}

private func XCTAssertThrowsNormalizationError(
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
