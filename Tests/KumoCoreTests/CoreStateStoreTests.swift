import Darwin
import XCTest
@testable import KumoCoreKit

final class CoreStateStoreTests: XCTestCase {
    func testStateStorePersistsStatus() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let store = CoreStateStore(paths: paths)
        let status = CoreStatus(
            state: .running,
            pid: 42,
            mode: .direct,
            systemProxyEnabled: true,
            message: "ok"
        )

        try store.save(status)

        XCTAssertEqual(try store.load(), status)
    }

    func testStateStoreAppliesConfiguredOwnershipAfterReplacingStateFile() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        try FileManager.default.createDirectory(
            at: paths.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        let store = CoreStateStore(
            paths: paths,
            ownership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )

        try store.save(CoreStatus(message: "first"))
        try store.save(CoreStatus(message: "second"))

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.stateFile.path)
        XCTAssertEqual(attributes[.ownerAccountID] as? NSNumber, NSNumber(value: getuid()))
        XCTAssertEqual(attributes[.groupOwnerAccountID] as? NSNumber, NSNumber(value: getgid()))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try store.load().message, "second")
    }

    func testAuthorizedUserOwnershipRejectsRootAndResolvesCurrentUser() throws {
        XCTAssertThrowsError(try StateFileOwnership.authorizedUser(userID: 0))

        if getuid() != 0 {
            let ownership = try StateFileOwnership.authorizedUser(userID: getuid())
            XCTAssertEqual(ownership.userID, getuid())
            XCTAssertEqual(ownership.groupID, getpwuid(getuid())?.pointee.pw_gid)
        }
    }

    func testPrivilegedStateWriteRejectsSymlinkedStateDirectory() throws {
        let realDirectory = temporaryDirectory()
        let symlinkDirectory = temporaryDirectory()
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: realDirectory)
        let store = CoreStateStore(
            paths: KumoPaths(applicationSupportDirectory: symlinkDirectory),
            ownership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )

        XCTAssertThrowsError(try store.save(CoreStatus(message: "blocked")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: realDirectory.appendingPathComponent("state.json").path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
