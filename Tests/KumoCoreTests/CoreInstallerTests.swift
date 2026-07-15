import XCTest
@testable import KumoCoreKit

final class CoreInstallerTests: XCTestCase {
    func testLatestStableReleaseTagSkipsPrereleaseAlpha() throws {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Release notes from mihomo</title>
          <entry>
            <title>Prerelease-Alpha</title>
          </entry>
          <entry>
            <title>v1.19.26</title>
          </entry>
          <entry>
            <title>v1.19.25</title>
          </entry>
        </feed>
        """

        let tag = try CoreInstaller.latestStableReleaseTag(fromAtomFeed: Data(feed.utf8))

        XCTAssertEqual(tag, "v1.19.26")
    }

    func testExpandedAssetsSelectsAllMatchingArmAssetsAndPrefersPlainBuild() throws {
        let plainDigest = String(repeating: "a", count: 64)
        let futureDigest = String(repeating: "b", count: 64)
        let html = """
        <li>
          <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-arm64-go130-v1.19.26.gz">future</a>
          <clipboard-copy value="sha256:\(futureDigest)"></clipboard-copy>
        </li>
        <li><a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-windows-arm64-v1.19.26.zip">windows</a></li>
        <li>
          <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-arm64-v1.19.26.gz">plain</a>
          <clipboard-copy value="sha256:\(plainDigest)"></clipboard-copy>
        </li>
        """

        let assets = try CoreInstaller.releaseAssets(
            fromExpandedAssetsHTML: Data(html.utf8),
            version: "v1.19.26",
            architecture: "arm64"
        )

        XCTAssertEqual(assets.map(\.name), [
            "mihomo-darwin-arm64-v1.19.26.gz",
            "mihomo-darwin-arm64-go130-v1.19.26.gz"
        ])
        XCTAssertEqual(assets.map(\.sha256), [plainDigest, futureDigest])
    }

    func testExpandedAssetsRejectsMatchingAssetWithoutPublishedDigest() throws {
        let html = """
        <li>
          <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-arm64-v1.19.26.gz">plain</a>
        </li>
        """

        XCTAssertThrowsError(try CoreInstaller.releaseAssets(
            fromExpandedAssetsHTML: Data(html.utf8),
            version: "v1.19.26",
            architecture: "arm64"
        ))
    }

    func testExpandedAssetsRejectsUnsupportedArchitecture() throws {
        let html = """
        <li>
          <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-amd64-v1.19.26.gz">unsupported</a>
          <clipboard-copy value="sha256:\(String(repeating: "a", count: 64))"></clipboard-copy>
        </li>
        """

        XCTAssertThrowsError(try CoreInstaller.releaseAssets(
            fromExpandedAssetsHTML: Data(html.utf8),
            version: "v1.19.26",
            architecture: "amd64"
        ))
    }

    func testSHA256VerificationRejectsTamperedArchive() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-core-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("tampered".utf8).write(to: file)

        XCTAssertThrowsError(try CoreInstaller.verifySHA256(
            of: file,
            expected: String(repeating: "0", count: 64)
        ))
    }

    func testBoundedFileCheckRejectsOversizedPayload() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-core-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0, count: 9).write(to: file)

        XCTAssertThrowsError(try CoreInstaller.validateFileSize(
            at: file,
            maximumBytes: 8,
            context: "test payload"
        ))
    }

    func testBoundedDownloadCancelsChunkedBodyBeforeWritingPastLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedBodyURLProtocol.self]
        let installer = CoreInstaller(
            session: URLSession(configuration: configuration)
        )
        let request = URLRequest(url: URL(string: "https://oversized.test/archive")!)

        do {
            let (url, _) = try await installer.boundedDownload(
                request,
                maximumBytes: 8,
                context: "test archive"
            )
            try? FileManager.default.removeItem(at: url)
            XCTFail("Expected the streaming size limit to cancel the download")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("8-byte safety limit"))
        }
    }

    func testMachOValidationRequiresExpectedArchitecture() {
        let arm64 = machOHeader(cpuType: [0x0c, 0x00, 0x00, 0x01])
        let otherCPU = machOHeader(cpuType: [0x07, 0x00, 0x00, 0x01])

        XCTAssertTrue(CoreInstaller.isSupportedMachOHeader(arm64, architecture: "arm64"))
        XCTAssertFalse(CoreInstaller.isSupportedMachOHeader(arm64, architecture: "amd64"))
        XCTAssertFalse(CoreInstaller.isSupportedMachOHeader(arm64, architecture: "unknown"))
        XCTAssertFalse(CoreInstaller.isSupportedMachOHeader(otherCPU, architecture: "arm64"))
        XCTAssertFalse(CoreInstaller.isSupportedMachOHeader(Data("script".utf8), architecture: "arm64"))
    }

    func testMachOValidationRejectsZeroSizedLoadCommand() {
        var malformed = machOHeader(cpuType: [0x0c, 0x00, 0x00, 0x01])
        malformed.replaceSubrange(36..<40, with: [0, 0, 0, 0])

        XCTAssertFalse(CoreInstaller.isSupportedMachOHeader(malformed, architecture: "arm64"))
    }

    func testInvalidDownloadedCoreDoesNotReplaceExistingExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-core-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("mihomo")
        let source = root.appendingPathComponent("invalid")
        let archive = root.appendingPathComponent("invalid.gz")
        try Data("known-good-core".utf8).write(to: destination)
        try Data("not-a-mach-o".utf8).write(to: source)
        try gzip(source: source, destination: archive)

        let installer = CoreInstaller(
            paths: KumoPaths(applicationSupportDirectory: root),
            session: .shared
        )
        XCTAssertThrowsError(try installer.installGzipArchive(
            archive,
            destinationURL: destination,
            architecture: "arm64"
        ))
        XCTAssertEqual(try Data(contentsOf: destination), Data("known-good-core".utf8))
    }

    func testValidatedDownloadedCoreAtomicallyReplacesExistingExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-core-replace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("mihomo")
        let source = root.appendingPathComponent("valid")
        let archive = root.appendingPathComponent("valid.gz")
        let header = machOHeader(cpuType: [0x0c, 0x00, 0x00, 0x01])
        let candidate = header + Data(repeating: 0, count: 64)
        try Data("old-core".utf8).write(to: destination)
        try candidate.write(to: source)
        try gzip(source: source, destination: archive)

        let installer = CoreInstaller(
            paths: KumoPaths(applicationSupportDirectory: root),
            session: .shared
        )
        _ = try installer.installGzipArchive(
            archive,
            destinationURL: destination,
            architecture: "arm64"
        )

        XCTAssertEqual(try Data(contentsOf: destination), candidate)
    }

    func testOnlyMissingAssetHTTPResponsesAllowFallback() {
        XCTAssertTrue(CoreInstaller.isMissingAssetError(
            CoreInstallerHTTPError(statusCode: 404, message: "missing")
        ))
        XCTAssertFalse(CoreInstaller.isMissingAssetError(
            CoreInstallerHTTPError(statusCode: 500, message: "server error")
        ))
        XCTAssertFalse(CoreInstaller.isMissingAssetError(CancellationError()))
    }

    private func gzip(source: URL, destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "CoreInstallerTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        data: errors.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "gzip failed"
                ]
            )
        }
    }

    private func machOHeader(cpuType: [UInt8]) -> Data {
        precondition(cpuType.count == 4)
        var bytes: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe]
        bytes.append(contentsOf: cpuType)
        bytes.append(contentsOf: [0, 0, 0, 0]) // CPU subtype
        bytes.append(contentsOf: [2, 0, 0, 0]) // MH_EXECUTE
        bytes.append(contentsOf: [1, 0, 0, 0]) // one load command
        bytes.append(contentsOf: [24, 0, 0, 0]) // load command bytes
        bytes.append(contentsOf: [0, 0, 0, 0]) // flags
        bytes.append(contentsOf: [0, 0, 0, 0]) // reserved
        bytes.append(contentsOf: [0x1b, 0, 0, 0]) // LC_UUID
        bytes.append(contentsOf: [24, 0, 0, 0]) // cmdsize
        bytes.append(contentsOf: Array(repeating: 0, count: 16)) // UUID
        return Data(bytes)
    }
}

private final class OversizedBodyURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "oversized.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Transfer-Encoding": "chunked"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x5a, count: 16))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
