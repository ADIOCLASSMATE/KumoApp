import XCTest
@testable import KumoCoreKit

final class KumoBackupManagerTests: XCTestCase {
    func testExportAndImportBackupRoundTripsProfilesAndState() throws {
        let sourcePaths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let profileRepository = ProfileRepository(paths: sourcePaths)
        let stateStore = CoreStateStore(paths: sourcePaths)
        _ = try profileRepository.saveProfile(
            Profile(name: "Backup", source: .inline, rawYAML: "proxies: []"),
            preferredID: "backup",
            makeCurrent: true
        )
        try stateStore.save(CoreStatus(state: .running, pid: 42, mode: .global))

        let backupDirectory = temporaryDirectory()
        let exported = try KumoBackupManager(paths: sourcePaths).exportBackup(to: backupDirectory)

        let destinationPaths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let manifest = try KumoBackupManager(paths: destinationPaths).importBackup(from: URL(fileURLWithPath: exported.destinationPath))

        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(try ProfileRepository(paths: destinationPaths).currentProfileSummary().id, "backup")
        XCTAssertEqual(try CoreStateStore(paths: destinationPaths).load().mode, .global)
    }

    func testImportExactlyRemovesStateThatIsAbsentFromBackup() throws {
        let sourcePaths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let backupDirectory = temporaryDirectory()
        _ = try KumoBackupManager(paths: sourcePaths).exportBackup(to: backupDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDirectory.appendingPathComponent("state.json").path))

        let destinationPaths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        try CoreStateStore(paths: destinationPaths).save(CoreStatus(mode: .global))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationPaths.stateFile.path))

        _ = try KumoBackupManager(paths: destinationPaths).importBackup(from: backupDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPaths.stateFile.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
