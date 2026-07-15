import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(KumoService) @testable import KumoCoreKit

final class ServiceInstallationDiskClassifierTests: XCTestCase {
    func testServiceStatusDecodesLegacyPayloadAndDerivesRepairRequirement() throws {
        let legacyPayload = Data(#"{"isInstalled":true,"isRunning":false,"isAvailable":false,"isCurrentProcessPrivileged":false,"socketPath":"/tmp/kumo.sock"}"#.utf8)

        let decoded = try JSONDecoder().decode(ServiceModeStatus.self, from: legacyPayload)

        XCTAssertNil(decoded.installationHealth)
        XCTAssertTrue(decoded.requiresRepair)
        XCTAssertTrue(ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            installationHealth: .legacyComplete
        ).requiresRepair)
        XCTAssertFalse(ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            installationHealth: .current
        ).requiresRepair)
    }

    func testServiceStatusRequiresSafeDiskAndCompatibleHandshake() {
        let compatible = KumoServiceHandshake.current(helperVersion: "test")
        let incompatible = KumoServiceHandshake(
            protocolVersion: KumoServiceProtocol.currentVersion + 1,
            helperVersion: "old",
            capabilities: []
        )

        let current = KumoServiceManager.composeStatus(
            diskState: .current(manifest(
                phase: .installed,
                capabilities: compatible.capabilities
            )),
            handshake: compatible,
            legacyServiceResponded: false,
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo.sock"
        )
        XCTAssertTrue(current.isRunning)
        XCTAssertTrue(current.isAvailable)
        XCTAssertFalse(current.requiresRepair)

        let partial = KumoServiceManager.composeStatus(
            diskState: .partial([.installationInterrupted]),
            handshake: compatible,
            legacyServiceResponded: false,
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo.sock"
        )
        XCTAssertTrue(partial.isRunning)
        XCTAssertFalse(partial.isAvailable)
        XCTAssertTrue(partial.requiresRepair)

        let incompatibleRuntime = KumoServiceManager.composeStatus(
            diskState: .current(manifest(
                phase: .installed,
                capabilities: compatible.capabilities
            )),
            handshake: incompatible,
            legacyServiceResponded: false,
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo.sock"
        )
        XCTAssertTrue(incompatibleRuntime.isRunning)
        XCTAssertFalse(incompatibleRuntime.isAvailable)
        XCTAssertTrue(incompatibleRuntime.requiresRepair)

        let orphanedEndpoint = KumoServiceManager.composeStatus(
            diskState: .absent,
            handshake: nil,
            legacyServiceResponded: false,
            serviceEndpointPresent: true,
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo.sock"
        )
        XCTAssertTrue(orphanedEndpoint.isInstalled)
        XCTAssertFalse(orphanedEndpoint.isRunning)
        XCTAssertFalse(orphanedEndpoint.isAvailable)
        XCTAssertTrue(orphanedEndpoint.requiresRepair)

        let absent = KumoServiceManager.composeStatus(
            diskState: .absent,
            handshake: nil,
            legacyServiceResponded: false,
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo.sock"
        )
        XCTAssertEqual(absent.message, "Kumo Helper is required before starting Mihomo.")
    }

    func testServiceStatusMergeNeverUpgradesEitherDiskSafetyVerdict() {
        let compatible = KumoServiceHandshake.current(helperVersion: "test")
        let helperCurrent = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            installationHealth: .current
        )
        let appFoundPartial = KumoServiceManager.composeStatus(
            diskState: .partial([.missingExecutable]),
            handshake: compatible,
            legacyServiceResponded: false,
            helperReportedStatus: helperCurrent,
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo.sock"
        )
        XCTAssertEqual(appFoundPartial.installationHealth, .partial)
        XCTAssertFalse(appFoundPartial.isAvailable)

        let helperFoundPartial = KumoServiceManager.composeStatus(
            diskState: .current(manifest(
                phase: .installed,
                capabilities: compatible.capabilities
            )),
            handshake: compatible,
            legacyServiceResponded: false,
            helperReportedStatus: ServiceModeStatus(
                isInstalled: true,
                isRunning: true,
                isAvailable: false,
                installationHealth: .partial
            ),
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo.sock"
        )
        XCTAssertEqual(helperFoundPartial.installationHealth, .partial)
        XCTAssertFalse(helperFoundPartial.isAvailable)

        let helperOmittedHealth = KumoServiceManager.composeStatus(
            diskState: .current(manifest(
                phase: .installed,
                capabilities: compatible.capabilities
            )),
            handshake: compatible,
            legacyServiceResponded: false,
            helperReportedStatus: ServiceModeStatus(
                isInstalled: true,
                isRunning: true,
                isAvailable: true,
                installationHealth: nil
            ),
            requiresHelperReportedStatus: true,
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo.sock"
        )
        XCTAssertFalse(helperOmittedHealth.isAvailable)
        XCTAssertTrue(helperOmittedHealth.requiresRepair)
    }

    func testPrivilegedServiceStatusReflectsClassifierState() {
        let status = KumoServiceManager.composePrivilegedStatus(
            diskState: .partial([.missingCredentials]),
            handshake: KumoServiceHandshake.current(helperVersion: "test"),
            isCurrentProcessPrivileged: true,
            socketPath: "/tmp/kumo.sock"
        )

        XCTAssertEqual(status.installationHealth, .partial)
        XCTAssertTrue(status.isRunning)
        XCTAssertFalse(status.isAvailable)
        XCTAssertTrue(status.requiresRepair)
    }

    func testAbsentWhenEveryInstallationArtifactIsMissing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertEqual(try fixture.classify(), .absent)
    }

    func testLegacyCompleteWhenSafeArtifactsExistWithoutManifest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacyArtifacts()

        XCTAssertEqual(try fixture.classify(), .legacyComplete)
    }

    func testCurrentWhenInstalledManifestMatchesExactArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = try fixture.writeCurrentInstallation()

        XCTAssertEqual(try fixture.classify(), .current(manifest))
    }

    func testAppVisibleClassificationDoesNotReadRootOnlyCredentials() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = try fixture.writeCurrentInstallation()
        let liveReader = ServiceInstallationFileReader.live
        let rootOnlyReader = ServiceInstallationFileReader { url, maximumBytes in
            if url == fixture.paths.credentialsFile {
                return .unsafe(.unreadable)
            }
            return liveReader.inspect(url, maximumBytes)
        }

        XCTAssertEqual(
            try fixture.classify(scope: .appVisible, reader: rootOnlyReader),
            .current(manifest)
        )
        guard case let .unsafe(issues) = try fixture.classify(
            scope: .privileged,
            reader: rootOnlyReader
        ) else {
            return XCTFail("Privileged classification must still validate credentials.")
        }
        XCTAssertTrue(issues.contains(
            ServiceInstallationUnsafeIssue(artifact: .credentials, violation: .unreadable)
        ))
    }

    func testAppVisibleClassificationMatchesRootOnlyDirectoryPermissions() throws {
        try XCTSkipIf(geteuid() == 0, "Root can traverse a 000 test directory.")
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = try fixture.writeCurrentInstallation()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.paths.credentialsFile.deletingLastPathComponent().path
        )

        XCTAssertEqual(
            try fixture.classify(scope: .appVisible),
            .current(manifest)
        )
        guard case let .unsafe(issues) = try fixture.classify(scope: .privileged) else {
            return XCTFail("Privileged inspection should observe the inaccessible credential.")
        }
        XCTAssertTrue(issues.contains(
            ServiceInstallationUnsafeIssue(artifact: .credentials, violation: .unreadable)
        ))
    }

    func testMissingArtifactAndInterruptedManifestArePartial() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var manifest = try fixture.writeCurrentInstallation()
        try FileManager.default.removeItem(at: fixture.paths.executableFile)
        manifest = manifest.withPhase(.installing)
        try fixture.writeManifest(manifest)

        guard case let .partial(reasons) = try fixture.classify() else {
            return XCTFail("Expected a repairable partial installation.")
        }
        XCTAssertTrue(reasons.contains(.missingExecutable))
        XCTAssertTrue(reasons.contains(.installationInterrupted))
    }

    func testCredentialKeyMismatchIsPartial() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.writeCurrentInstallation()
        try fixture.write(fixture.credentialsData(keyID: "replacement-key"), to: fixture.paths.credentialsFile, permissions: 0o600)

        guard case let .partial(reasons) = try fixture.classify() else {
            return XCTFail("Expected a repairable partial installation.")
        }
        XCTAssertTrue(reasons.contains(.credentialKeyMismatch))
    }

    func testManifestForAnotherUserIsForeignUserEvenWhenFilesAreIncomplete() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let foreignUserID = fixture.userID &+ 1
        let manifest = fixture.manifest(
            authorizedUserID: foreignUserID,
            executableSHA256: fixture.digest(Data("missing helper".utf8)),
            launchDaemonSHA256: fixture.digest(Data("missing plist".utf8))
        )
        try fixture.writeManifest(manifest)

        XCTAssertEqual(
            try fixture.classify(),
            .foreignUser(installedUserID: foreignUserID)
        )
    }

    func testLegacyPlistForAnotherUserIsForeignUser() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let foreignUserID = fixture.userID &+ 1
        try fixture.write(fixture.helperData, to: fixture.paths.executableFile, permissions: 0o755)
        try fixture.write(
            fixture.launchDaemonData(authorizedUserID: foreignUserID),
            to: fixture.paths.launchDaemonFile,
            permissions: 0o644
        )

        XCTAssertEqual(
            try fixture.classify(),
            .foreignUser(installedUserID: foreignUserID)
        )
    }

    func testSymlinkIsUnsafeWithoutFollowingItsTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacyArtifacts()
        let victim = fixture.root.appendingPathComponent("victim")
        try Data("must not be read as the Helper".utf8).write(to: victim)
        try FileManager.default.removeItem(at: fixture.paths.executableFile)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.executableFile,
            withDestinationURL: victim
        )

        guard case let .unsafe(issues) = try fixture.classify() else {
            return XCTFail("Expected a symlink to make the installation unsafe.")
        }
        XCTAssertTrue(issues.contains(
            ServiceInstallationUnsafeIssue(artifact: .executable, violation: .symbolicLink)
        ))
        XCTAssertEqual(try Data(contentsOf: victim), Data("must not be read as the Helper".utf8))
    }

    func testInjectedWrongOwnerAndPermissionsAreUnsafe() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacyArtifacts()
        let liveReader = ServiceInstallationFileReader.live
        let injectedReader = ServiceInstallationFileReader { url, maximumBytes in
            let observation = liveReader.inspect(url, maximumBytes)
            guard case let .regular(data, original) = observation else { return observation }
            var metadata = original
            if url == fixture.paths.executableFile {
                metadata.ownerUserID = fixture.userID &+ 1
            }
            if url == fixture.paths.launchDaemonFile {
                metadata.permissions = 0o666
            }
            return .regular(data: data, metadata: metadata)
        }

        guard case let .unsafe(issues) = try fixture.classify(reader: injectedReader) else {
            return XCTFail("Expected foreign ownership and writable metadata to be unsafe.")
        }
        XCTAssertTrue(issues.contains(
            ServiceInstallationUnsafeIssue(artifact: .executable, violation: .wrongOwner)
        ))
        XCTAssertTrue(issues.contains(
            ServiceInstallationUnsafeIssue(artifact: .launchDaemon, violation: .wrongPermissions)
        ))
    }

    private func manifest(
        phase: ServiceInstallationManifest.Phase,
        capabilities: [KumoServiceCapability]
    ) -> ServiceInstallationManifest {
        ServiceInstallationManifest(
            transactionID: UUID(),
            phase: phase,
            serviceLabel: KumoServiceManager.launchDaemonLabel,
            authorizedUserID: getuid(),
            helperVersion: "test",
            protocolVersion: KumoServiceProtocol.currentVersion,
            capabilities: capabilities,
            executableSHA256: String(repeating: "a", count: 64),
            launchDaemonSHA256: String(repeating: "b", count: 64),
            credentialKeyID: "key",
            updatedAt: Date()
        )
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let userID = getuid()
    let groupID = getgid()
    let paths: ServiceInstallationArtifactPaths
    let helperData = Data("arm64 KumoService".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-service-installation-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("user/Kumo", isDirectory: true)
        let privilegedSupport = root.appendingPathComponent("privileged", isDirectory: true)
        paths = ServiceInstallationArtifactPaths(
            applicationSupportDirectory: appSupport,
            executableFile: root.appendingPathComponent("helper/KumoService"),
            launchDaemonFile: root.appendingPathComponent("launchd/io.kumo.KumoService.plist"),
            credentialsFile: privilegedSupport.appendingPathComponent("users/\(userID)/service-credentials.json"),
            manifestFile: privilegedSupport.appendingPathComponent("installation-manifest.json")
        )
        for directory in [
            paths.executableFile.deletingLastPathComponent(),
            paths.launchDaemonFile.deletingLastPathComponent(),
            paths.credentialsFile.deletingLastPathComponent(),
            paths.manifestFile.deletingLastPathComponent(),
            appSupport
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    func remove() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.credentialsFile.deletingLastPathComponent().path
        )
        try? FileManager.default.removeItem(at: root)
    }

    func classify(
        scope: ServiceInstallationDiskClassifier.InspectionScope = .privileged,
        reader: ServiceInstallationFileReader = .live
    ) throws -> ServiceInstallationDiskState {
        ServiceInstallationDiskClassifier(
            paths: paths,
            expectedAuthorizedUserID: userID,
            requiredOwnerUserID: userID,
            requiredOwnerGroupID: groupID,
            inspectionScope: scope,
            reader: reader
        ).classify()
    }

    func writeLegacyArtifacts() throws {
        try write(helperData, to: paths.executableFile, permissions: 0o755)
        try write(launchDaemonData(), to: paths.launchDaemonFile, permissions: 0o644)
        try write(credentialsData(), to: paths.credentialsFile, permissions: 0o600)
    }

    @discardableResult
    func writeCurrentInstallation() throws -> ServiceInstallationManifest {
        try writeLegacyArtifacts()
        let manifest = manifest(
            executableSHA256: digest(helperData),
            launchDaemonSHA256: digest(launchDaemonData())
        )
        try writeManifest(manifest)
        return manifest
    }

    func manifest(
        authorizedUserID: uid_t? = nil,
        executableSHA256: String,
        launchDaemonSHA256: String
    ) -> ServiceInstallationManifest {
        ServiceInstallationManifest(
            transactionID: UUID(uuidString: "3437E09E-7337-43FC-B484-E6CA70856336")!,
            phase: .installed,
            serviceLabel: KumoServiceManager.launchDaemonLabel,
            authorizedUserID: authorizedUserID ?? userID,
            helperVersion: "1.2.3",
            protocolVersion: KumoServiceProtocol.currentVersion,
            capabilities: [.runtimeActivationReceipt],
            executableSHA256: executableSHA256,
            launchDaemonSHA256: launchDaemonSHA256,
            credentialKeyID: "fixture-key",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func writeManifest(_ manifest: ServiceInstallationManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(manifest), to: paths.manifestFile, permissions: 0o644)
    }

    func launchDaemonData(authorizedUserID: uid_t? = nil) -> Data {
        let userID = authorizedUserID ?? self.userID
        return try! PropertyListSerialization.data(
            fromPropertyList: [
                "Label": KumoServiceManager.launchDaemonLabel,
                "ProgramArguments": [
                    paths.executableFile.path,
                    "service",
                    "run",
                    "--app-support",
                    paths.applicationSupportDirectory.path,
                    "--authorized-uid",
                    "\(userID)"
                ]
            ],
            format: .xml,
            options: 0
        )
    }

    func credentialsData(keyID: String = "fixture-key") -> Data {
        try! JSONEncoder().encode(
            KumoServiceCredentials(keyID: keyID, sharedSecret: "fixture-secret")
        )
    }

    func write(_ data: Data, to url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension ServiceInstallationManifest {
    func withPhase(_ phase: Phase) -> ServiceInstallationManifest {
        ServiceInstallationManifest(
            schemaVersion: schemaVersion,
            transactionID: transactionID,
            phase: phase,
            serviceLabel: serviceLabel,
            authorizedUserID: authorizedUserID,
            helperVersion: helperVersion,
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            executableSHA256: executableSHA256,
            launchDaemonSHA256: launchDaemonSHA256,
            credentialKeyID: credentialKeyID,
            updatedAt: updatedAt
        )
    }
}
