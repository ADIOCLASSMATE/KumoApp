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
        let privilegedRoot = temporaryDirectory()
        let serviceRoot = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: temporaryDirectory(),
            privilegedRuntimeRootDirectory: privilegedRoot,
            privilegedServiceSupportDirectory: serviceRoot
        )
        try FileManager.default.createDirectory(
            at: paths.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try prepareProxyJournalDirectory(paths)
        let store = CoreStateStore(
            paths: paths,
            ownership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )

        try store.save(CoreStatus(message: "first"))
        try store.save(CoreStatus(message: "second"))

        let privateStateFile = paths.privilegedRuntimeDirectory(userID: getuid())
            .appendingPathComponent("state.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: privateStateFile.path)
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
        let runtimeRoot = temporaryDirectory()
        let serviceRoot = temporaryDirectory()
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let symlinkDirectory = runtimeRoot.appendingPathComponent(String(getuid()), isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: realDirectory)
        let paths = KumoPaths(
            applicationSupportDirectory: temporaryDirectory(),
            privilegedRuntimeRootDirectory: runtimeRoot,
            privilegedServiceSupportDirectory: serviceRoot
        )
        try prepareProxyJournalDirectory(paths)
        let store = CoreStateStore(
            paths: paths,
            ownership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )

        XCTAssertThrowsError(try store.save(CoreStatus(message: "blocked")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: realDirectory.appendingPathComponent("state.json").path))
    }

    func testPrivilegedProxyJournalSurvivesRuntimeDirectoryLoss() throws {
        let runtimeRoot = temporaryDirectory()
        let serviceRoot = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: temporaryDirectory(),
            privilegedRuntimeRootDirectory: runtimeRoot,
            privilegedServiceSupportDirectory: serviceRoot
        )
        try prepareProxyJournalDirectory(paths)
        let store = CoreStateStore(
            paths: paths,
            ownership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )
        let snapshot = SystemProxySnapshot(
            networkService: "Wi-Fi",
            webProxy: "Enabled: Yes\nServer: proxy.example\nPort: 8080",
            secureWebProxy: "Enabled: No",
            socksProxy: "Enabled: No",
            bypassDomains: "localhost"
        )
        let status = CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi", port: 7890),
            previousSystemProxySnapshot: snapshot
        )
        try store.save(status)
        try FileManager.default.removeItem(
            at: paths.privilegedRuntimeDirectory(userID: getuid())
        )

        let recovered = try store.load()

        XCTAssertTrue(recovered.systemProxyEnabled)
        XCTAssertEqual(recovered.systemProxySettings, status.systemProxySettings)
        XCTAssertEqual(recovered.previousSystemProxySnapshot?.networkService, snapshot.networkService)
        XCTAssertEqual(recovered.previousSystemProxySnapshot?.webProxy, snapshot.webProxy)
        XCTAssertEqual(recovered.previousSystemProxySnapshot?.secureWebProxy, snapshot.secureWebProxy)
        XCTAssertEqual(recovered.previousSystemProxySnapshot?.socksProxy, snapshot.socksProxy)
        XCTAssertEqual(recovered.previousSystemProxySnapshot?.bypassDomains, snapshot.bypassDomains)
        XCTAssertEqual(recovered.state, .stopped)
        XCTAssertNil(recovered.pid)
    }

    func testPrivilegedDisableJournalSurvivesCrashAndRequestsDisableRecovery() throws {
        let runtimeRoot = temporaryDirectory()
        let serviceRoot = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: temporaryDirectory(),
            privilegedRuntimeRootDirectory: runtimeRoot,
            privilegedServiceSupportDirectory: serviceRoot
        )
        try prepareProxyJournalDirectory(paths)
        let store = CoreStateStore(
            paths: paths,
            ownership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )
        let original = SystemProxySnapshot(networkService: "Wi-Fi", webProxy: "Enabled: No")
        let applied = SystemProxySnapshot(
            networkService: "Wi-Fi",
            webProxy: "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890"
        )
        let status = CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi"),
            previousSystemProxySnapshot: original,
            appliedSystemProxySnapshot: applied
        )
        try store.save(status)
        try store.stageSystemProxyDisableJournal(status)

        // Model a crash/reboot that loses only /private/var/run state.
        try FileManager.default.removeItem(
            at: paths.privilegedRuntimeDirectory(userID: getuid())
        )
        let recovered = try store.load()

        XCTAssertTrue(recovered.systemProxyEnabled)
        XCTAssertEqual(recovered.systemProxyRecoveryAction, .completeDisable)
        XCTAssertEqual(recovered.previousSystemProxySnapshot?.networkService, original.networkService)
        XCTAssertEqual(recovered.previousSystemProxySnapshot?.webProxy, original.webProxy)
        XCTAssertEqual(recovered.appliedSystemProxySnapshot?.networkService, applied.networkService)
        XCTAssertEqual(recovered.appliedSystemProxySnapshot?.webProxy, applied.webProxy)
    }

    private func prepareProxyJournalDirectory(_ paths: KumoPaths) throws {
        let directory = paths.privilegedServiceUserDirectory(userID: getuid())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
