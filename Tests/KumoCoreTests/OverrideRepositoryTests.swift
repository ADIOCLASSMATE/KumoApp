import XCTest
@testable import KumoCoreKit

final class OverrideRepositoryTests: XCTestCase {
    func testYAMLOverridesPersistContentAndOrder() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = OverrideRepository(paths: paths)

        let first = try repository.addLocalOverride(
            name: "First",
            format: .yaml,
            content: "mixed-port: 1",
            profileID: "profile-a"
        )
        let second = try repository.addLocalOverride(
            name: "Second",
            format: .yaml,
            content: "allow-lan: true",
            profileID: "profile-a"
        )
        try repository.reorderOverrides(ids: [second.id, first.id])

        let items = try repository.listOverrides()
        let yaml = try repository.activeYAMLs(for: "profile-a")

        XCTAssertEqual(items.map(\.id), [second.id, first.id])
        XCTAssertEqual(yaml, ["allow-lan: true", "mixed-port: 1"])
    }

    func testProfileSpecificOverridesDoNotLeakIntoAnotherProfile() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = OverrideRepository(paths: paths)

        _ = try repository.addLocalOverride(
            name: "iKuuu nodes",
            format: .yaml,
            content: "proxies: [ikuuu-node]",
            profileID: "ikuuu"
        )
        _ = try repository.addLocalOverride(
            name: "Other nodes",
            format: .yaml,
            content: "proxies: [other-node]",
            profileID: "other"
        )
        _ = try repository.addLocalOverride(
            name: "Global rules",
            format: .yaml,
            content: "rules: [MATCH,DIRECT]",
            isGlobal: true
        )

        XCTAssertEqual(
            try repository.activeYAMLs(for: "other"),
            ["proxies: [other-node]", "rules: [MATCH,DIRECT]"]
        )
        XCTAssertEqual(
            try repository.activeYAMLs(for: "ikuuu"),
            ["proxies: [ikuuu-node]", "rules: [MATCH,DIRECT]"]
        )
    }

    func testProfileSpecificOverridesAreAppliedBeforeGlobalOverrides() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = OverrideRepository(paths: paths)

        _ = try repository.addLocalOverride(
            name: "Global first in metadata",
            format: .yaml,
            content: "value: global-first",
            isGlobal: true
        )
        _ = try repository.addLocalOverride(
            name: "Profile first",
            format: .yaml,
            content: "value: profile-first",
            profileID: "profile-a"
        )
        _ = try repository.addLocalOverride(
            name: "Global second",
            format: .yaml,
            content: "value: global-second",
            isGlobal: true
        )
        _ = try repository.addLocalOverride(
            name: "Profile second",
            format: .yaml,
            content: "value: profile-second",
            profileID: "profile-a"
        )

        XCTAssertEqual(
            try repository.activeYAMLs(for: "profile-a"),
            [
                "value: profile-first",
                "value: profile-second",
                "value: global-first",
                "value: global-second"
            ]
        )
    }

    func testLegacyNonGlobalOverrideDecodesButIsNotActivated() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        try paths.prepare()
        let legacyMetadata = """
        [
          {
            "id": "legacy-override",
            "name": "Legacy non-global",
            "kind": "local",
            "format": "yaml",
            "updatedAt": "2026-07-14T00:00:00Z",
            "isGlobal": false
          }
        ]
        """
        try Data(legacyMetadata.utf8).write(to: paths.overridesMetadataFile, options: .atomic)
        try Data("proxies: [legacy-ikuuu-node]".utf8).write(
            to: paths.overrideFilesDirectory.appendingPathComponent("legacy-override.yaml"),
            options: .atomic
        )
        let repository = OverrideRepository(paths: paths)

        let item = try XCTUnwrap(repository.listOverrides().first)

        XCTAssertNil(item.profileID)
        XCTAssertEqual(try repository.activeYAMLs(for: "other"), [])
        XCTAssertEqual(try repository.activeYAMLs(), [])
    }

    func testSnapshotRestoreReinstatesMetadataOrderScopeAndEveryContentFile() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = OverrideRepository(paths: paths)
        let profileItem = try repository.addLocalOverride(
            name: "Profile",
            format: .yaml,
            content: "proxies: [profile-original]",
            profileID: "profile-a"
        )
        let globalItem = try repository.addLocalOverride(
            name: "Global",
            format: .yaml,
            content: "rules: [MATCH,DIRECT]",
            isGlobal: true
        )
        let javascriptItem = try repository.addLocalOverride(
            name: "Script",
            format: .javascript,
            content: "module.exports = {}",
            profileID: "profile-a"
        )
        try repository.reorderOverrides(ids: [profileItem.id, javascriptItem.id, globalItem.id])
        let originalItems = try repository.listOverrides()
        let snapshot = try repository.snapshot()

        var changedProfileItem = profileItem
        changedProfileItem.name = "Changed"
        changedProfileItem.profileID = "profile-b"
        try repository.updateOverride(changedProfileItem, content: "proxies: [mutated]")
        try repository.deleteOverride(id: globalItem.id)
        let addedItem = try repository.addLocalOverride(
            name: "Added after snapshot",
            format: .yaml,
            content: "proxies: [unexpected]",
            isGlobal: true
        )

        try repository.restore(snapshot)

        XCTAssertEqual(try repository.listOverrides(), originalItems)
        XCTAssertEqual(try repository.content(id: profileItem.id), "proxies: [profile-original]")
        XCTAssertEqual(try repository.content(id: javascriptItem.id), "module.exports = {}")
        XCTAssertEqual(
            try repository.activeYAMLs(for: "profile-a"),
            ["proxies: [profile-original]", "rules: [MATCH,DIRECT]"]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.overrideFilesDirectory
                    .appendingPathComponent(addedItem.id)
                    .appendingPathExtension("yaml")
                    .path
            )
        )
    }

    func testSnapshotRestoreRemovesRepositoryCreatedAfterEmptySnapshot() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = OverrideRepository(paths: paths)
        let snapshot = try repository.snapshot()
        _ = try repository.addLocalOverride(
            name: "Added later",
            format: .yaml,
            content: "proxies: [unexpected]",
            isGlobal: true
        )

        try repository.restore(snapshot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.overridesDirectory.path))
        XCTAssertTrue(try repository.listOverrides().isEmpty)
    }

    func testDeleteOverrideRemovesMetadata() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = OverrideRepository(paths: paths)
        let item = try repository.addLocalOverride(name: "Delete Me", format: .yaml, content: "rules: []")

        try repository.deleteOverride(id: item.id)

        XCTAssertTrue(try repository.listOverrides().isEmpty)
    }

    func testReorderRejectsDuplicateAndUnknownIdentifiersWithoutChangingMetadata() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let repository = OverrideRepository(paths: paths)
        let first = try repository.addLocalOverride(
            name: "First",
            format: .yaml,
            content: "rules: []",
            profileID: "profile-a"
        )
        let second = try repository.addLocalOverride(
            name: "Second",
            format: .yaml,
            content: "proxies: []",
            profileID: "profile-a"
        )
        let originalIDs = try repository.listOverrides().map(\.id)

        XCTAssertThrowsError(
            try repository.reorderOverrides(ids: [first.id, first.id])
        )
        XCTAssertEqual(try repository.listOverrides().map(\.id), originalIDs)

        XCTAssertThrowsError(
            try repository.reorderOverrides(ids: [second.id, "missing-override"])
        )
        XCTAssertEqual(try repository.listOverrides().map(\.id), originalIDs)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
