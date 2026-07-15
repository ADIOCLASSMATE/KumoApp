import Darwin
import Foundation
import XCTest
@testable @_spi(KumoService) import KumoCoreKit

final class RootOwnedAtomicInstallerTests: XCTestCase {
    func testSnapshotRestoresExistingFileContentsAndPermissions() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("helper")
        try Data("known-good".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: destination.path)
        let snapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: destination,
            requiredOwner: getuid()
        )

        try RootOwnedAtomicInstaller.installData(
            Data("candidate".utf8),
            to: destination,
            requiredOwner: getuid(),
            requiredGroup: getgid(),
            permissions: 0o600
        )
        try RootOwnedAtomicInstaller.restore(snapshot)

        XCTAssertTrue(snapshot.existed)
        XCTAssertEqual(try Data(contentsOf: destination), Data("known-good".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o750)
    }

    func testSnapshotOfMissingFileRemovesCandidateDuringRestore() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("credentials.json")
        let snapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: destination,
            requiredOwner: getuid()
        )
        try RootOwnedAtomicInstaller.installData(
            Data("candidate".utf8),
            to: destination,
            requiredOwner: getuid(),
            requiredGroup: getgid(),
            permissions: 0o600
        )

        try RootOwnedAtomicInstaller.restore(snapshot)

        XCTAssertFalse(snapshot.existed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSnapshotRejectsSymlinkWithoutReadingItsTarget() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim")
        let destination = root.appendingPathComponent("helper")
        try Data("private".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)

        XCTAssertThrowsError(try RootOwnedAtomicInstaller.snapshotFile(
            at: destination,
            requiredOwner: getuid()
        ))
        XCTAssertEqual(try Data(contentsOf: victim), Data("private".utf8))
    }

    func testTransactionRestoresEveryFileForFailuresAtEveryInstallPhase() async throws {
        enum Phase: String, CaseIterable {
            case executable
            case credentials
            case plist
            case bootout
            case bootstrap
            case kickstart
            case authenticatedHealthCheck
        }

        for phase in Phase.allCases {
            let root = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let files = ["helper", "credentials.json", "service.plist"].map(root.appendingPathComponent)
            for (index, file) in files.enumerated() {
                try Data("old-\(index)".utf8).write(to: file)
            }
            let snapshots = try files.map {
                try RootOwnedAtomicInstaller.snapshotFile(at: $0, requiredOwner: getuid())
            }
            var rollbackEvents: [String] = []

            do {
                try await RootOwnedAtomicInstaller.performTransaction(
                    restoring: snapshots,
                    operation: {
                        for (index, file) in files.enumerated() {
                            try RootOwnedAtomicInstaller.installData(
                                Data("new-\(index)".utf8),
                                to: file,
                                requiredOwner: getuid(),
                                requiredGroup: getgid(),
                                permissions: 0o600
                            )
                            let filePhase: Phase = [.executable, .credentials, .plist][index]
                            if phase == filePhase { throw TestFailure(phase.rawValue) }
                        }
                        let commandPhases: [Phase] = [
                            .bootout,
                            .bootstrap,
                            .kickstart,
                            .authenticatedHealthCheck
                        ]
                        for commandPhase in commandPhases {
                            if phase == commandPhase { throw TestFailure(phase.rawValue) }
                        }
                    },
                    prepareForRollback: {
                        rollbackEvents.append("prepare")
                    },
                    completeRollback: {
                        rollbackEvents.append("complete")
                    }
                )
                XCTFail("Expected simulated \(phase.rawValue) failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, TestFailure(phase.rawValue).localizedDescription)
            }

            for (index, file) in files.enumerated() {
                XCTAssertEqual(
                    try Data(contentsOf: file),
                    Data("old-\(index)".utf8),
                    "Failed to restore \(file.lastPathComponent) after \(phase.rawValue)"
                )
            }
            XCTAssertEqual(rollbackEvents, ["prepare", "complete"])
        }
    }

    func testLoadedLegacyServiceCanMigrateWhenOnlyPrivilegedCredentialsAreMissing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("helper")
        let credentials = root.appendingPathComponent("credentials.json")
        let launchDaemon = root.appendingPathComponent("service.plist")
        try Data("legacy-helper".utf8).write(to: executable)
        try Data("legacy-plist".utf8).write(to: launchDaemon)

        let executableSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: executable,
            requiredOwner: getuid()
        )
        let credentialsSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: credentials,
            requiredOwner: getuid()
        )
        let launchDaemonSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: launchDaemon,
            requiredOwner: getuid()
        )

        XCTAssertFalse(credentialsSnapshot.existed)
        XCTAssertEqual(RootOwnedAtomicInstaller.updateStrategy(
            wasLoaded: true,
            executableSnapshot: executableSnapshot,
            launchDaemonSnapshot: launchDaemonSnapshot
        ), .rollbackCapable)
    }

    func testLoadedPartialServiceUsesConvergentRepairInsteadOfRejectingTheUpdate() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("helper")
        let launchDaemon = root.appendingPathComponent("service.plist")
        try Data("legacy-helper".utf8).write(to: executable)

        let existingExecutable = try RootOwnedAtomicInstaller.snapshotFile(
            at: executable,
            requiredOwner: getuid()
        )
        let missingLaunchDaemon = try RootOwnedAtomicInstaller.snapshotFile(
            at: launchDaemon,
            requiredOwner: getuid()
        )

        XCTAssertEqual(RootOwnedAtomicInstaller.updateStrategy(
            wasLoaded: true,
            executableSnapshot: existingExecutable,
            launchDaemonSnapshot: missingLaunchDaemon
        ), .convergentRepair)

        try FileManager.default.removeItem(at: executable)
        try Data("legacy-plist".utf8).write(to: launchDaemon)
        let missingExecutable = try RootOwnedAtomicInstaller.snapshotFile(
            at: executable,
            requiredOwner: getuid()
        )
        let existingLaunchDaemon = try RootOwnedAtomicInstaller.snapshotFile(
            at: launchDaemon,
            requiredOwner: getuid()
        )
        XCTAssertEqual(RootOwnedAtomicInstaller.updateStrategy(
            wasLoaded: true,
            executableSnapshot: missingExecutable,
            launchDaemonSnapshot: existingLaunchDaemon
        ), .convergentRepair)
    }

    func testCredentialRotationUsesConvergentRepairInsteadOfRestoringUnauthenticatedPredecessor() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("helper")
        let launchDaemon = root.appendingPathComponent("service.plist")
        let credentialsFile = root.appendingPathComponent("credentials.json")
        try Data("old-helper".utf8).write(to: executable)
        try Data("old-plist".utf8).write(to: launchDaemon)
        let oldCredentials = KumoServiceCredentials(
            keyID: "old-key",
            sharedSecret: "old-secret"
        )
        try JSONEncoder().encode(oldCredentials).write(to: credentialsFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialsFile.path
        )

        let executableSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: executable,
            requiredOwner: getuid()
        )
        let launchDaemonSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: launchDaemon,
            requiredOwner: getuid()
        )
        let credentialsSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: credentialsFile,
            requiredOwner: getuid(),
            requiredGroup: getgid(),
            requiredPermissions: 0o600
        )
        let replacementCredentials = KumoServiceCredentials(
            keyID: "replacement-key",
            sharedSecret: "replacement-secret"
        )

        XCTAssertTrue(RootOwnedAtomicInstaller.credentialsSnapshot(
            credentialsSnapshot,
            matches: oldCredentials
        ))
        XCTAssertFalse(RootOwnedAtomicInstaller.credentialsSnapshot(
            credentialsSnapshot,
            matches: replacementCredentials
        ))
        XCTAssertEqual(
            RootOwnedAtomicInstaller.updateStrategy(
                wasLoaded: true,
                executableSnapshot: executableSnapshot,
                launchDaemonSnapshot: launchDaemonSnapshot,
                predecessorCredentialsMatchCandidate: false
            ),
            .convergentRepair
        )
    }

    func testCompleteOrAbsentServiceKeepsRollbackCapableUpdate() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("helper")
        let launchDaemon = root.appendingPathComponent("service.plist")

        let missingExecutable = try RootOwnedAtomicInstaller.snapshotFile(
            at: executable,
            requiredOwner: getuid()
        )
        let missingLaunchDaemon = try RootOwnedAtomicInstaller.snapshotFile(
            at: launchDaemon,
            requiredOwner: getuid()
        )
        XCTAssertEqual(RootOwnedAtomicInstaller.updateStrategy(
            wasLoaded: false,
            executableSnapshot: missingExecutable,
            launchDaemonSnapshot: missingLaunchDaemon
        ), .rollbackCapable)
        XCTAssertEqual(RootOwnedAtomicInstaller.updateStrategy(
            wasLoaded: true,
            executableSnapshot: missingExecutable,
            launchDaemonSnapshot: missingLaunchDaemon
        ), .convergentRepair)

        try Data("legacy-helper".utf8).write(to: executable)
        try Data("legacy-plist".utf8).write(to: launchDaemon)
        let existingExecutable = try RootOwnedAtomicInstaller.snapshotFile(
            at: executable,
            requiredOwner: getuid()
        )
        let existingLaunchDaemon = try RootOwnedAtomicInstaller.snapshotFile(
            at: launchDaemon,
            requiredOwner: getuid()
        )
        XCTAssertEqual(RootOwnedAtomicInstaller.updateStrategy(
            wasLoaded: true,
            executableSnapshot: existingExecutable,
            launchDaemonSnapshot: existingLaunchDaemon
        ), .rollbackCapable)
    }

    func testLoadedServiceRollbackRecreatesOnlyMissingPrivilegedCredentials() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = root.appendingPathComponent("credentials.json")
        let missingSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: credentials,
            requiredOwner: getuid()
        )

        try RootOwnedAtomicInstaller.restoreMissingCredentialForLoadedService(
            wasLoaded: true,
            credentialsSnapshot: missingSnapshot,
            data: Data("current-credentials".utf8),
            requiredOwner: getuid(),
            requiredGroup: getgid(),
            permissions: 0o600
        )

        XCTAssertEqual(try Data(contentsOf: credentials), Data("current-credentials".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: credentials.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let existingSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: credentials,
            requiredOwner: getuid()
        )
        try RootOwnedAtomicInstaller.restoreMissingCredentialForLoadedService(
            wasLoaded: true,
            credentialsSnapshot: existingSnapshot,
            data: Data("replacement".utf8),
            requiredOwner: getuid(),
            requiredGroup: getgid(),
            permissions: 0o600
        )
        XCTAssertEqual(try Data(contentsOf: credentials), Data("current-credentials".utf8))
    }

    func testExecutableInstallRejectsSourceSymlinkAndPreservesOldDestination() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let realSource = sourceDirectory.appendingPathComponent("real-helper")
        let source = sourceDirectory.appendingPathComponent("helper")
        let destination = destinationDirectory.appendingPathComponent("helper")
        try Data("candidate".utf8).write(to: realSource)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: realSource.path)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: realSource)
        try Data("known-good".utf8).write(to: destination)

        XCTAssertThrowsError(try RootOwnedAtomicInstaller.installExecutable(
            from: source,
            to: destination,
            requiredOwner: getuid(),
            requiredGroup: getgid()
        ))
        XCTAssertEqual(try Data(contentsOf: destination), Data("known-good".utf8))
    }

    func testExecutableInstallReplacesDestinationSymlinkWithoutTouchingVictim() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("helper")
        let destination = destinationDirectory.appendingPathComponent("helper")
        let victim = root.appendingPathComponent("victim")
        try Data("candidate".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        try Data("unchanged".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)

        try RootOwnedAtomicInstaller.installExecutable(
            from: source,
            to: destination,
            requiredOwner: getuid(),
            requiredGroup: getgid()
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("candidate".utf8))
        XCTAssertEqual(try Data(contentsOf: victim), Data("unchanged".utf8))
        var status = stat()
        XCTAssertEqual(lstat(destination.path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-root-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

private struct TestFailure: LocalizedError {
    let phase: String

    init(_ phase: String) {
        self.phase = phase
    }

    var errorDescription: String? {
        "Simulated \(phase) failure."
    }
}
