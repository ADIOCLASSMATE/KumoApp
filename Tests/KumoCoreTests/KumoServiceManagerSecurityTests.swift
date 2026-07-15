import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class KumoServiceManagerSecurityTests: XCTestCase {
    func testCandidateSearchNeverUsesCurrentWorkingDirectory() {
        let bundle = URL(fileURLWithPath: "/Applications/Kumo.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Kumo")

        let candidates = KumoServiceManager.helperCandidateURLs(
            bundleURL: bundle,
            executableURL: executable
        )

        XCTAssertTrue(candidates.contains(
            bundle.appendingPathComponent("Contents/MacOS/KumoService")
        ))
        XCTAssertFalse(candidates.contains {
            $0.path == FileManager.default.currentDirectoryPath + "/KumoService"
                || $0.path.contains("/.build/")
        })
    }

    func testHelperValidationRejectsSymlinkAndGroupWritableFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("KumoService")
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775],
            ofItemAtPath: helper.path
        )

        XCTAssertThrowsError(try KumoServiceManager.validateHelperFile(
            at: helper,
            allowedOwnerIDs: [getuid()]
        ))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        let symlinkURL = root.appendingPathComponent("KumoService-link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: helper)
        XCTAssertThrowsError(try KumoServiceManager.validateHelperFile(
            at: symlinkURL,
            allowedOwnerIDs: [getuid()]
        ))
    }

    func testHelperValidationPinsRegularSingleLinkContentDigest() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("KumoService")
        try Data("known helper".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let validated = try KumoServiceManager.validateHelperFile(
            at: helper,
            allowedOwnerIDs: [getuid()]
        )

        XCTAssertEqual(validated.url, helper)
        XCTAssertEqual(
            validated.sha256,
            "71cd98075d43c824adf2593fd264c8b21e31f480eef1c4de097c6f576fef2c27"
        )

        let hardLink = root.appendingPathComponent("KumoService-hardlink")
        XCTAssertEqual(link(helper.path, hardLink.path), 0)
        XCTAssertThrowsError(try KumoServiceManager.validateHelperFile(
            at: helper,
            allowedOwnerIDs: [getuid()]
        ))
    }

    func testAuthorizationScriptExecutesOnlyDigestPinnedRootStage() {
        let manager = KumoServiceManager()
        let original = "/Applications/Kumo App.app/Contents/MacOS/KumoService"

        let script = manager.rootStagingScript(
            source: ValidatedServiceHelper(
                url: URL(fileURLWithPath: original),
                sha256: String(repeating: "a", count: 64)
            ),
            arguments: [
                "service", "install", "--source", original,
                "--authorized-uid", "501"
            ]
        )

        XCTAssertTrue(script.contains("/bin/cp '/Applications/Kumo App.app/Contents/MacOS/KumoService' \"$stage\""))
        XCTAssertTrue(script.contains("\"$stage\" 'service' 'install' '--source' \"$stage\""))
        XCTAssertFalse(script.contains("\n        '\(original)' 'service'"))
        XCTAssertTrue(script.contains("codesign --verify --strict --all-architectures \"$stage\""))
    }

    func testRepairInstallUsesHelperRecognizedProxyRecoveryFlag() {
        let arguments = KumoServiceManager.installArguments(
            sourceURL: URL(fileURLWithPath: "/Applications/Kumo.app/Contents/MacOS/KumoService"),
            applicationSupportDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support/Kumo"),
            authorizedUID: 501,
            credentials: KumoServiceCredentials(keyID: "key", sharedSecret: "secret"),
            resetProxyRecovery: true
        )

        XCTAssertTrue(arguments.contains("--repair-reset-proxy"))
        XCTAssertFalse(arguments.contains("--reset-proxy-recovery"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-helper-test-\(UUID().uuidString)", isDirectory: true)
    }
}
