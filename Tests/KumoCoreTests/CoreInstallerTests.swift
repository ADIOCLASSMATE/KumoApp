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
        let html = """
        <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-arm64-go130-v1.19.26.gz">future</a>
        <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-windows-amd64-v1.19.26.zip">windows</a>
        <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-arm64-v1.19.26.gz">plain</a>
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
    }

    func testExpandedAssetsRanksOptimizedAmd64BeforeCompatibleFallback() throws {
        let html = """
        <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-amd64-compatible-v1.19.26.gz">compatible</a>
        <a href="/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-amd64-v4-v1.19.26.gz">v4</a>
        """

        let assets = try CoreInstaller.releaseAssets(
            fromExpandedAssetsHTML: Data(html.utf8),
            version: "v1.19.26",
            architecture: "amd64"
        )

        XCTAssertEqual(assets.map(\.name), [
            "mihomo-darwin-amd64-v4-v1.19.26.gz",
            "mihomo-darwin-amd64-compatible-v1.19.26.gz"
        ])
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
}
