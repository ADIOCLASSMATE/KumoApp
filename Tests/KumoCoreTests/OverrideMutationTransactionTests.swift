import Foundation
import XCTest
@testable import KumoCoreKit

final class OverrideMutationTransactionTests: XCTestCase {
    func testLocalOverrideBindsToCurrentProfileAndRejectsInvalidCandidate() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let profiles = ProfileRepository(paths: paths)
        _ = try profiles.saveProfile(
            Profile(
                name: "Other",
                source: .inline,
                rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
            ),
            preferredID: "other",
            makeCurrent: true
        )
        let controller = KumoController(paths: paths, useServiceBackend: false)

        let item = try await controller.addLocalOverride(
            name: "Other only",
            format: .yaml,
            content: "profile-marker: other\n"
        )

        XCTAssertEqual(item.profileID, "other")
        XCTAssertEqual(try controller.overrides().map(\.id), [item.id])

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.addLocalOverride(
                name: "Invalid",
                format: .yaml,
                content: "rules: ["
            )
        }

        XCTAssertEqual(try controller.overrides().map(\.id), [item.id])
        XCTAssertEqual(try controller.overrideContent(id: item.id), "profile-marker: other\n")
    }

    func testUpdatingLegacyNonGlobalOverrideBindsItToCurrentProfile() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let profiles = ProfileRepository(paths: paths)
        _ = try profiles.saveProfile(
            Profile(
                name: "Other",
                source: .inline,
                rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
            ),
            preferredID: "other",
            makeCurrent: true
        )
        let repository = OverrideRepository(paths: paths)
        let legacy = try repository.addLocalOverride(
            name: "Legacy",
            format: .yaml,
            content: "profile-marker: legacy\n"
        )
        XCTAssertNil(legacy.profileID)

        let controller = KumoController(paths: paths, useServiceBackend: false)
        try await controller.updateOverride(legacy, content: "profile-marker: rebound\n")

        let rebound = try XCTUnwrap(controller.overrides().first)
        XCTAssertEqual(rebound.profileID, "other")
        XCTAssertFalse(rebound.isGlobal)
        XCTAssertEqual(try controller.overrideContent(id: rebound.id), "profile-marker: rebound\n")
    }

    func testCannotEditOrReorderOverrideOwnedByAnotherProfile() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let profiles = ProfileRepository(paths: paths)
        _ = try profiles.saveProfile(
            Profile(
                name: "Profile A",
                source: .inline,
                rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
            ),
            preferredID: "profile-a",
            makeCurrent: false
        )
        _ = try profiles.saveProfile(
            Profile(
                name: "Profile B",
                source: .inline,
                rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
            ),
            preferredID: "profile-b",
            makeCurrent: true
        )
        let repository = OverrideRepository(paths: paths)
        let profileAItem = try repository.addLocalOverride(
            name: "Profile A only",
            format: .yaml,
            content: "profile-marker: profile-a\n",
            profileID: "profile-a"
        )
        let controller = KumoController(paths: paths, useServiceBackend: false)
        var forgedEdit = profileAItem
        forgedEdit.name = "Edited while B is selected"
        forgedEdit.profileID = "profile-b"

        await XCTAssertThrowsErrorAsync {
            try await controller.updateOverride(
                forgedEdit,
                content: "profile-marker: leaked\n"
            )
        }
        await XCTAssertThrowsErrorAsync {
            try await controller.reorderOverrides(ids: [profileAItem.id])
        }

        let persisted = try XCTUnwrap(controller.overrides().first)
        XCTAssertEqual(persisted.name, "Profile A only")
        XCTAssertEqual(persisted.profileID, "profile-a")
        XCTAssertEqual(
            try controller.overrideContent(id: profileAItem.id),
            "profile-marker: profile-a\n"
        )
    }

    func testRuntimeStartUsesOnlyOverridesForSelectedProfile() throws {
        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/usr/bin:/bin", 1)
        defer {
            if let previousPath {
                setenv("PATH", previousPath, 1)
            } else {
                unsetenv("PATH")
            }
        }
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let profiles = ProfileRepository(paths: paths)
        _ = try profiles.saveProfile(
            Profile(
                name: "Other",
                source: .inline,
                rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
            ),
            preferredID: "other",
            makeCurrent: true
        )
        let overrides = OverrideRepository(paths: paths)
        _ = try overrides.addLocalOverride(
            name: "iKuuu only",
            format: .yaml,
            content: "profile-marker: ikuuu\n",
            profileID: "ikuuu"
        )
        _ = try overrides.addLocalOverride(
            name: "Other only",
            format: .yaml,
            content: "profile-marker: other\n",
            profileID: "other"
        )
        let corePath = try makeLongRunningTestCore(in: paths.applicationSupportDirectory)
        let controller = KumoController(paths: paths, useServiceBackend: false)

        _ = try controller.start(corePath: corePath)
        defer { _ = try? controller.stop() }

        let configPath = try XCTUnwrap(controller.supervisor.currentInstanceRecord()?.configPath)
        let runtimeYAML = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(runtimeYAML.contains("profile-marker: other"))
        XCTAssertFalse(runtimeYAML.contains("profile-marker: ikuuu"))
    }

    func testFailedCandidateActivationRestoresSnapshotBeforePreviousRuntime() async throws {
        let recorder = OverrideTransactionRecorder()

        await XCTAssertThrowsErrorAsync {
            _ = try await OverrideMutationTransaction.perform(
                snapshot: {
                    await recorder.record("snapshot")
                    return "old-overrides"
                },
                runtimeNeedsReload: {
                    await recorder.record("status")
                    return true
                },
                mutate: {
                    await recorder.record("mutate")
                    return "result"
                },
                preflight: {
                    await recorder.record("preflight")
                },
                activateCandidate: {
                    await recorder.record("activate-candidate")
                    throw KumoError.commandFailed("candidate failed")
                },
                restoreSnapshot: { snapshot in
                    await recorder.record("restore-snapshot:\(snapshot)")
                },
                restoreRuntime: {
                    await recorder.record("restore-runtime")
                }
            )
        }

        let events = await recorder.events
        XCTAssertEqual(
            events,
            [
                "snapshot",
                "status",
                "mutate",
                "preflight",
                "activate-candidate",
                "restore-snapshot:old-overrides",
                "restore-runtime"
            ]
        )
    }

    func testProductionRuntimeAuthorityRejectsCustomCorePathInsteadOfFallingBackLocally() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let production = KumoController(paths: paths)
        let isolatedSupervisor = KumoController(paths: paths, useServiceBackend: false)

        XCTAssertThrowsError(
            try production.runtimeBackendForMutation(corePath: "/tmp/custom-mihomo")
        )
        XCTAssertNoThrow(
            try isolatedSupervisor.runtimeBackendForMutation(corePath: "/tmp/custom-mihomo")
        )
    }

    private func makeLongRunningTestCore(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-mihomo")
        let script = """
        #!/bin/sh
        if [ "$1" = "-t" ]; then
          exit 0
        fi
        while true; do
          sleep 1
        done
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor OverrideTransactionRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
