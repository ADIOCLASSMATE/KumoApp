import XCTest
@testable import KumoCoreKit

final class ProfileRepositoryTests: XCTestCase {
    func testProfileIdentifiersCannotEscapeTheProfilesDirectory() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = ProfileRepository(paths: paths)
        let profile = Profile(
            name: "Unsafe",
            source: .inline,
            rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
        )
        let escapedURL = paths.applicationSupportDirectory.appendingPathComponent("escaped.yaml")

        XCTAssertThrowsError(
            try repository.saveProfile(profile, preferredID: "../escaped")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
    }

    func testSignedRuntimeLaunchPayloadCarriesContentWithoutAUserFilePath() throws {
        let request = CoreRuntimeLaunchRequest(
            spec: RuntimeSpec(
                profileID: "normalized",
                profileYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n",
                overrideYAMLs: [],
                endpoint: ControllerEndpoint(),
                proxyPorts: ProxyPortConfiguration(),
                mode: .rule,
                runtimeSettings: CoreRuntimeSettings(),
                configurationDigest: String(repeating: "a", count: 64)
            ),
            expectedGeneration: .stopped
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CoreRuntimeLaunchRequest.self, from: encoded)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.spec.configurationDigest, String(repeating: "a", count: 64))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("/profiles/"))
    }

    func testProfileCRUDPersistsMetadataAndFallsBackAfterDelete() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = ProfileRepository(paths: paths)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/sub.yaml"))
        let profile = Profile(
            name: "Example Remote",
            source: .remote(remoteURL),
            rawYAML: "proxies: []",
            updatedAt: Date()
        )

        let saved = try repository.saveProfile(profile, preferredID: "example", makeCurrent: true)

        XCTAssertEqual(saved.kind, .remote)
        XCTAssertEqual(saved.remoteURL, remoteURL)
        XCTAssertTrue(saved.isCurrent)

        let updated = try repository.updateProfile(
            id: saved.id,
            name: "Renamed",
            remoteURL: remoteURL,
            autoUpdate: false,
            useProxy: true,
            rawYAML: "proxies:\n  - name: direct\n"
        )

        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.kind, .remote)
        XCTAssertFalse(updated.autoUpdate)
        XCTAssertTrue(updated.useProxy)
        XCTAssertEqual(try repository.profileContent(id: saved.id), "proxies:\n  - name: direct\n")

        let deletedCurrentProfile = try repository.deleteProfile(id: saved.id)

        XCTAssertTrue(deletedCurrentProfile)
        XCTAssertEqual(try repository.currentProfileSummary().id, "default")
    }

    func testSaveRejectsInvalidScalarBeforeChangingCurrentProfile() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = ProfileRepository(paths: paths)
        let valid = Profile(
            name: "Valid",
            source: .inline,
            rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
        )
        _ = try repository.saveProfile(valid, preferredID: "valid", makeCurrent: true)

        XCTAssertThrowsError(
            try repository.saveProfile(
                Profile(name: "Invalid", source: .inline, rawYAML: "plain scalar"),
                preferredID: "invalid"
            )
        )
        XCTAssertEqual(try repository.currentProfileSummary().id, "valid")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.profilesDirectory.appendingPathComponent("invalid.yaml").path
            )
        )
    }

    func testSnapshotRestoreDoesNotOverwriteAConcurrentSelectionOrOtherMetadata() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = ProfileRepository(paths: paths)
        let originalA = Profile(
            name: "A",
            source: .inline,
            rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
        )
        let originalB = Profile(
            name: "B",
            source: .inline,
            rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
        )
        _ = try repository.saveProfile(originalA, preferredID: "a", makeCurrent: true)
        _ = try repository.saveProfile(originalB, preferredID: "b", makeCurrent: false)
        let snapshot = try repository.snapshot(profileID: "a")

        _ = try repository.updateProfile(
            id: "a",
            name: "Changed A",
            remoteURL: nil,
            autoUpdate: false,
            useProxy: false,
            rawYAML: "proxies: []\nrules:\n  - MATCH,REJECT\n"
        )
        try repository.setCurrentProfile(id: "b")
        _ = try repository.updateProfile(
            id: "b",
            name: "Changed B",
            remoteURL: nil,
            autoUpdate: false,
            useProxy: false,
            rawYAML: originalB.rawYAML
        )

        try repository.restore(snapshot)

        XCTAssertEqual(try repository.currentProfileSummary().id, "b")
        XCTAssertEqual(try repository.listProfiles().first(where: { $0.id == "b" })?.name, "Changed B")
        XCTAssertEqual(try repository.profileContent(id: "a"), originalA.rawYAML)
    }

    func testValidationNormalizationDoesNotRewriteLegacySubscriptionFile() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let legacySubscription = "vless://test-id@example.com:443?security=tls#Example\n"
        let normalizedYAML = """
        proxies:
          - name: Example
            type: vless
            server: example.com
            port: 443
            uuid: test-id
        proxy-groups:
          - name: Proxy
            type: select
            proxies: [Example, DIRECT]
        rules:
          - MATCH,Proxy
        """
        try FileManager.default.createDirectory(
            at: paths.profilesDirectory,
            withIntermediateDirectories: true
        )
        let profileURL = paths.profilesDirectory.appendingPathComponent("legacy.yaml")
        try legacySubscription.write(to: profileURL, atomically: true, encoding: .utf8)
        let repository = ProfileRepository(
            paths: paths,
            subscriptionConverter: StaticSubscriptionConverter(output: normalizedYAML)
        )

        let (profile, wasChanged) = try await repository.normalizedProfileForValidation(id: "legacy")

        XCTAssertTrue(wasChanged)
        XCTAssertTrue(profile.rawYAML.contains("name: Example"))
        XCTAssertTrue(profile.rawYAML.contains("MATCH,Proxy"))
        XCTAssertEqual(try String(contentsOf: profileURL, encoding: .utf8), legacySubscription)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct StaticSubscriptionConverter: ProfileSubscriptionConverting {
    let output: String

    func convertSubscription(_ content: String) async throws -> String {
        _ = content
        return output
    }
}
