import Foundation
import XCTest
@testable import KumoCoreKit

final class AppUpdateInstallerTests: XCTestCase {
    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(
            AppUpdateInstaller.shellQuote("Kumo's DMG"),
            "'Kumo'\\''s DMG'"
        )
    }

    func testShellQuoteWrapsPathsWithSpaces() {
        XCTAssertEqual(
            AppUpdateInstaller.shellQuote("/Applications/Kumo App/Kumo.app"),
            "'/Applications/Kumo App/Kumo.app'"
        )
    }

    func testInstallerValidatesAndStagesTrustedArm64Update() throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let commandRecorder = UpdateCommandRecorder(candidateAppURL: fixture.candidateAppURL)
        let launchRecorder = UpdateLaunchRecorder()
        let installer = AppUpdateInstaller(
            paths: fixture.paths,
            commandRunner: commandRecorder.runner,
            launcher: launchRecorder.launcher,
            identifierProvider: { fixture.identifier }
        )

        try installer.installDMG(
            dmgURL: fixture.dmgURL,
            currentAppURL: fixture.currentAppURL,
            expectedVersion: fixture.version,
            processID: 42
        )

        let launch = try XCTUnwrap(launchRecorder.invocations.first)
        XCTAssertEqual(launch.arguments.count, 14)
        let stagedAppURL = URL(fileURLWithPath: launch.arguments[0])
        let backupAppURL = URL(fileURLWithPath: launch.arguments[2])
        XCTAssertEqual(
            stagedAppURL.deletingLastPathComponent().standardizedFileURL,
            fixture.currentAppURL.deletingLastPathComponent().standardizedFileURL
        )
        XCTAssertEqual(
            backupAppURL.deletingLastPathComponent().standardizedFileURL,
            fixture.currentAppURL.deletingLastPathComponent().standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedAppURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.currentAppURL.path))

        let commands = commandRecorder.commands
        XCTAssertTrue(commands.contains(ShellCommand(
            executable: "/usr/bin/hdiutil",
            arguments: ["verify", fixture.dmgURL.path]
        )))
        XCTAssertTrue(commands.contains(where: {
            $0.executable == "/usr/bin/codesign"
                && $0.arguments == ["--verify", "--strict", fixture.dmgURL.path]
        }))
        XCTAssertTrue(commands.contains(where: {
            $0.executable == "/usr/bin/xcrun"
                && $0.arguments == ["stapler", "validate", fixture.dmgURL.path]
        }))
        XCTAssertTrue(commands.contains(where: {
            $0.executable == "/usr/sbin/spctl"
                && $0.arguments.contains(fixture.dmgURL.path)
                && $0.arguments.contains("open")
        }))
        XCTAssertTrue(commands.contains(where: {
            $0.executable == "/usr/sbin/spctl"
                && $0.arguments.contains(stagedAppURL.path)
                && $0.arguments.contains("execute")
        }))

        let requiredExecutableSuffixes = [
            "/Contents/MacOS/Kumo",
            "/Contents/MacOS/KumoService",
            "/Contents/Helpers/kumo",
            "/Contents/Resources/Kumo_KumoCoreKit.bundle/Contents/Resources/SubStore/node/bin/node"
        ]
        for suffix in requiredExecutableSuffixes {
            XCTAssertTrue(commands.contains(where: {
                $0.executable == "/usr/bin/lipo"
                    && $0.arguments.first == "-archs"
                    && $0.arguments.last?.hasSuffix(suffix) == true
            }), "missing arm64 validation for \(suffix)")
            XCTAssertTrue(commands.contains(where: {
                $0.executable == "/usr/bin/codesign"
                    && $0.arguments.contains("--verify")
                    && $0.arguments.contains("--strict")
                    && $0.arguments.contains("--deep")
                    && $0.arguments.last?.hasSuffix(suffix) == true
            }), "missing strict code-signature validation for \(suffix)")
        }
        XCTAssertFalse(commands.contains(where: {
            $0.executable.localizedCaseInsensitiveContains("xattr")
                || $0.arguments.contains(where: { $0.localizedCaseInsensitiveContains("quarantine") })
        }))
    }

    func testInstallerRejectsUnexpectedCandidateVersionBeforeLaunch() throws {
        let fixture = try UpdateFixture(candidateVersion: "9.9.9")
        defer { fixture.remove() }
        let commandRecorder = UpdateCommandRecorder(candidateAppURL: fixture.candidateAppURL)
        let launchRecorder = UpdateLaunchRecorder()
        let installer = AppUpdateInstaller(
            paths: fixture.paths,
            commandRunner: commandRecorder.runner,
            launcher: launchRecorder.launcher,
            identifierProvider: { fixture.identifier }
        )

        XCTAssertThrowsError(try installer.installDMG(
            dmgURL: fixture.dmgURL,
            currentAppURL: fixture.currentAppURL,
            expectedVersion: fixture.version,
            processID: 42
        ))
        XCTAssertTrue(launchRecorder.invocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagedAppURL.path))
    }

    func testInstallerRejectsHelperFromDifferentTeamBeforeLaunch() throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let commandRecorder = UpdateCommandRecorder(
            candidateAppURL: fixture.candidateAppURL,
            helperTeamIdentifier: "ATTACKER01"
        )
        let launchRecorder = UpdateLaunchRecorder()
        let installer = AppUpdateInstaller(
            paths: fixture.paths,
            commandRunner: commandRecorder.runner,
            launcher: launchRecorder.launcher,
            identifierProvider: { fixture.identifier }
        )

        XCTAssertThrowsError(try installer.installDMG(
            dmgURL: fixture.dmgURL,
            currentAppURL: fixture.currentAppURL,
            expectedVersion: fixture.version,
            processID: 42
        ))
        XCTAssertTrue(launchRecorder.invocations.isEmpty)
    }

    func testInstallerRejectsNonArm64NodeBeforeLaunch() throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let commandRecorder = UpdateCommandRecorder(
            candidateAppURL: fixture.candidateAppURL,
            nodeArchitectures: "arm64 x86_64"
        )
        let launchRecorder = UpdateLaunchRecorder()
        let installer = AppUpdateInstaller(
            paths: fixture.paths,
            commandRunner: commandRecorder.runner,
            launcher: launchRecorder.launcher,
            identifierProvider: { fixture.identifier }
        )

        XCTAssertThrowsError(try installer.installDMG(
            dmgURL: fixture.dmgURL,
            currentAppURL: fixture.currentAppURL,
            expectedVersion: fixture.version,
            processID: 42
        ))
        XCTAssertTrue(launchRecorder.invocations.isEmpty)
    }

    func testInstallerRejectsDMGFromDifferentTeamBeforeLaunch() throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let commandRecorder = UpdateCommandRecorder(
            candidateAppURL: fixture.candidateAppURL,
            dmgTeamIdentifier: "ATTACKER01"
        )
        let launchRecorder = UpdateLaunchRecorder()
        let installer = AppUpdateInstaller(
            paths: fixture.paths,
            commandRunner: commandRecorder.runner,
            launcher: launchRecorder.launcher,
            identifierProvider: { fixture.identifier }
        )

        XCTAssertThrowsError(try installer.installDMG(
            dmgURL: fixture.dmgURL,
            currentAppURL: fixture.currentAppURL,
            expectedVersion: fixture.version,
            processID: 42
        ))
        XCTAssertTrue(launchRecorder.invocations.isEmpty)
    }

    func testInstallerRejectsHelperWithoutDeveloperIDBeforeLaunch() throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let commandRecorder = UpdateCommandRecorder(
            candidateAppURL: fixture.candidateAppURL,
            helperUsesDeveloperID: false
        )
        let launchRecorder = UpdateLaunchRecorder()
        let installer = AppUpdateInstaller(
            paths: fixture.paths,
            commandRunner: commandRecorder.runner,
            launcher: launchRecorder.launcher,
            identifierProvider: { fixture.identifier }
        )

        XCTAssertThrowsError(try installer.installDMG(
            dmgURL: fixture.dmgURL,
            currentAppURL: fixture.currentAppURL,
            expectedVersion: fixture.version,
            processID: 42
        ))
        XCTAssertTrue(launchRecorder.invocations.isEmpty)
    }

    func testInstallerRejectsHelperWithoutHardenedRuntimeBeforeLaunch() throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let commandRecorder = UpdateCommandRecorder(
            candidateAppURL: fixture.candidateAppURL,
            helperHasHardenedRuntime: false
        )
        let launchRecorder = UpdateLaunchRecorder()
        let installer = AppUpdateInstaller(
            paths: fixture.paths,
            commandRunner: commandRecorder.runner,
            launcher: launchRecorder.launcher,
            identifierProvider: { fixture.identifier }
        )

        XCTAssertThrowsError(try installer.installDMG(
            dmgURL: fixture.dmgURL,
            currentAppURL: fixture.currentAppURL,
            expectedVersion: fixture.version,
            processID: 42
        ))
        XCTAssertTrue(launchRecorder.invocations.isEmpty)
    }

    func testInstallerFailsClosedWhenGatekeeperRejectsCandidate() throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let commandRecorder = UpdateCommandRecorder(
            candidateAppURL: fixture.candidateAppURL,
            rejectCandidateGatekeeperAssessment: true
        )
        let launchRecorder = UpdateLaunchRecorder()
        let installer = AppUpdateInstaller(
            paths: fixture.paths,
            commandRunner: commandRecorder.runner,
            launcher: launchRecorder.launcher,
            identifierProvider: { fixture.identifier }
        )

        XCTAssertThrowsError(try installer.installDMG(
            dmgURL: fixture.dmgURL,
            currentAppURL: fixture.currentAppURL,
            expectedVersion: fixture.version,
            processID: 42
        ))
        XCTAssertTrue(launchRecorder.invocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagedAppURL.path))
    }

    func testInstallScriptAtomicallyReplacesStagedAppAndRemovesBackup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Kumo.app", isDirectory: true)
        let staged = root.appendingPathComponent(".Kumo-update.staged.app", isDirectory: true)
        let backup = root.appendingPathComponent(".Kumo-update.backup.app", isDirectory: true)
        let script = root.appendingPathComponent("install-update.sh")
        let log = root.appendingPathComponent("install.log")
        let tools = try makeScriptValidationTools(in: root)
        try writeMarker("old", appURL: target)
        try writeMarker("new", appURL: staged)
        try AppUpdateInstaller.installScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let status = try runScript(
            script,
            arguments: scriptArguments(
                staged: staged,
                target: target,
                backup: backup,
                log: log,
                openTool: "/usr/bin/true",
                tools: tools
            )
        )

        XCTAssertEqual(status, 0)
        XCTAssertEqual(try readMarker(appURL: target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testInstallScriptRollsBackWhenRelaunchFails() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Kumo.app", isDirectory: true)
        let staged = root.appendingPathComponent(".Kumo-update.staged.app", isDirectory: true)
        let backup = root.appendingPathComponent(".Kumo-update.backup.app", isDirectory: true)
        let script = root.appendingPathComponent("install-update.sh")
        let log = root.appendingPathComponent("install.log")
        let tools = try makeScriptValidationTools(in: root)
        try writeMarker("old", appURL: target)
        try writeMarker("new", appURL: staged)
        try AppUpdateInstaller.installScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let status = try runScript(
            script,
            arguments: scriptArguments(
                staged: staged,
                target: target,
                backup: backup,
                log: log,
                openTool: "/usr/bin/false",
                tools: tools
            )
        )

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try readMarker(appURL: target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testInstallScriptRevalidatesCandidateAfterWaitBeforeReplacement() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Kumo.app", isDirectory: true)
        let staged = root.appendingPathComponent(".Kumo-update.staged.app", isDirectory: true)
        let backup = root.appendingPathComponent(".Kumo-update.backup.app", isDirectory: true)
        let script = root.appendingPathComponent("install-update.sh")
        let log = root.appendingPathComponent("install.log")
        let tools = try makeScriptValidationTools(in: root, architectures: "arm64 x86_64")
        try writeMarker("old", appURL: target)
        try writeMarker("tampered", appURL: staged)
        try AppUpdateInstaller.installScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let status = try runScript(
            script,
            arguments: scriptArguments(
                staged: staged,
                target: target,
                backup: backup,
                log: log,
                openTool: "/usr/bin/true",
                tools: tools
            )
        )

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try readMarker(appURL: target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    private func runScript(_ script: URL, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path] + arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func writeMarker(_ value: String, appURL: URL) throws {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try value.write(
            to: appURL.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": AppUpdateInstaller.expectedBundleIdentifier,
            "CFBundleShortVersionString": "2.0.0"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        for relativePath in [
            "MacOS/Kumo",
            "MacOS/KumoService",
            "Helpers/kumo",
            "Resources/Kumo_KumoCoreKit.bundle/Contents/Resources/SubStore/node/bin/node"
        ] {
            let executable = contents.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }

    private func makeScriptValidationTools(
        in root: URL,
        architectures: String = "arm64"
    ) throws -> ScriptValidationTools {
        let toolsDirectory = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        let codesign = toolsDirectory.appendingPathComponent("codesign")
        let lipo = toolsDirectory.appendingPathComponent("lipo")
        let spctl = toolsDirectory.appendingPathComponent("spctl")
        let plist = toolsDirectory.appendingPathComponent("PlistBuddy")
        try writeTool(
            """
            #!/bin/sh
            if [ "$1" = "-dv" ]; then
              case "$*" in
                *SubStore/node/bin/node*) team="HX7739G8FX" ;;
                *) team="KUMOTEAM01" ;;
              esac
              echo "Authority=Developer ID Application: Trusted Publisher ($team)" >&2
              echo "TeamIdentifier=$team" >&2
              echo "CodeDirectory v=20500 flags=0x10000(runtime)" >&2
            fi
            exit 0
            """,
            to: codesign
        )
        try writeTool("#!/bin/sh\necho '\(architectures)'\n", to: lipo)
        try writeTool("#!/bin/sh\nexit 0\n", to: spctl)
        try writeTool(
            """
            #!/bin/sh
            case "$2" in
              *CFBundleIdentifier*) echo "io.kumo.KumoApp" ;;
              *CFBundleShortVersionString*) echo "2.0.0" ;;
              *) exit 1 ;;
            esac
            """,
            to: plist
        )
        return ScriptValidationTools(codesign: codesign, lipo: lipo, spctl: spctl, plist: plist)
    }

    private func writeTool(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func scriptArguments(
        staged: URL,
        target: URL,
        backup: URL,
        log: URL,
        openTool: String,
        tools: ScriptValidationTools
    ) -> [String] {
        [
            staged.path,
            target.path,
            backup.path,
            "999999",
            log.path,
            openTool,
            AppUpdateInstaller.expectedBundleIdentifier,
            "2.0.0",
            UpdateFixture.teamIdentifier,
            UpdateFixture.nodeTeamIdentifier,
            tools.codesign.path,
            tools.lipo.path,
            tools.spctl.path,
            tools.plist.path
        ]
    }

    private func readMarker(appURL: URL) throws -> String {
        try String(contentsOf: appURL.appendingPathComponent("marker"), encoding: .utf8)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct ScriptValidationTools {
    var codesign: URL
    var lipo: URL
    var spctl: URL
    var plist: URL
}

private struct UpdateFixture {
    static let teamIdentifier = "KUMOTEAM01"
    static let nodeTeamIdentifier = "HX7739G8FX"

    let root: URL
    let paths: KumoPaths
    let currentAppURL: URL
    let candidateAppURL: URL
    let dmgURL: URL
    let identifier: UUID
    let version: String

    init(candidateVersion: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let candidateRoot = root.appendingPathComponent("Candidate", isDirectory: true)
        let currentAppURL = applications.appendingPathComponent("Kumo.app", isDirectory: true)
        let candidateAppURL = candidateRoot.appendingPathComponent("Kumo.app", isDirectory: true)
        let dmgURL = root.appendingPathComponent("Kumo.dmg")
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let version = "2.0.0"

        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        try Self.makeApp(at: currentAppURL, version: "1.0.0")
        try Self.makeApp(at: candidateAppURL, version: candidateVersion ?? version)
        try Data("fake dmg".utf8).write(to: dmgURL)

        self.root = root
        self.paths = KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("Support", isDirectory: true)
        )
        self.currentAppURL = currentAppURL
        self.candidateAppURL = candidateAppURL
        self.dmgURL = dmgURL
        self.identifier = identifier
        self.version = version
    }

    var stagedAppURL: URL {
        currentAppURL.deletingLastPathComponent().appendingPathComponent(
            ".Kumo-update-\(identifier.uuidString).staged.app",
            isDirectory: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeApp(at appURL: URL, version: String) throws {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "io.kumo.KumoApp",
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Kumo"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let relativeExecutables = [
            "MacOS/Kumo",
            "MacOS/KumoService",
            "Helpers/kumo",
            "Resources/Kumo_KumoCoreKit.bundle/Contents/Resources/SubStore/node/bin/node"
        ]
        for relativePath in relativeExecutables {
            let executable = contents.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }
}

private final class UpdateCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let candidateAppURL: URL
    private let helperTeamIdentifier: String
    private let dmgTeamIdentifier: String
    private let helperUsesDeveloperID: Bool
    private let helperHasHardenedRuntime: Bool
    private let nodeArchitectures: String
    private let rejectCandidateGatekeeperAssessment: Bool
    private var recordedCommands: [ShellCommand] = []

    init(
        candidateAppURL: URL,
        helperTeamIdentifier: String = UpdateFixture.teamIdentifier,
        dmgTeamIdentifier: String = UpdateFixture.teamIdentifier,
        helperUsesDeveloperID: Bool = true,
        helperHasHardenedRuntime: Bool = true,
        nodeArchitectures: String = "arm64",
        rejectCandidateGatekeeperAssessment: Bool = false
    ) {
        self.candidateAppURL = candidateAppURL
        self.helperTeamIdentifier = helperTeamIdentifier
        self.dmgTeamIdentifier = dmgTeamIdentifier
        self.helperUsesDeveloperID = helperUsesDeveloperID
        self.helperHasHardenedRuntime = helperHasHardenedRuntime
        self.nodeArchitectures = nodeArchitectures
        self.rejectCandidateGatekeeperAssessment = rejectCandidateGatekeeperAssessment
    }

    var commands: [ShellCommand] {
        lock.withLock { recordedCommands }
    }

    var runner: AppUpdateInstallerCommandRunner {
        AppUpdateInstallerCommandRunner { [self] command in
            try handle(command)
        }
    }

    private func handle(_ command: ShellCommand) throws -> String {
        lock.withLock { recordedCommands.append(command) }

        if command.executable == "/usr/bin/hdiutil",
           command.arguments.first == "attach",
           let mountIndex = command.arguments.firstIndex(of: "-mountpoint"),
           command.arguments.indices.contains(mountIndex + 1) {
            let mountURL = URL(fileURLWithPath: command.arguments[mountIndex + 1], isDirectory: true)
            let mountedApp = mountURL.appendingPathComponent("Kumo.app", isDirectory: true)
            try FileManager.default.copyItem(at: candidateAppURL, to: mountedApp)
            return ""
        }
        if command.executable == "/usr/bin/ditto",
           command.arguments.count == 2 {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: command.arguments[0]),
                to: URL(fileURLWithPath: command.arguments[1])
            )
            return ""
        }
        if command.executable == "/usr/bin/lipo" {
            let target = command.arguments.last ?? ""
            return target.hasSuffix("/SubStore/node/bin/node") ? nodeArchitectures : "arm64"
        }
        if command.executable == "/usr/bin/codesign",
           command.arguments.contains("-dv") {
            return signingInformation(for: command.arguments.last ?? "")
        }
        if command.executable == "/usr/sbin/spctl",
           rejectCandidateGatekeeperAssessment,
           command.arguments.contains("execute") {
            throw KumoError.commandFailed("candidate rejected by Gatekeeper")
        }
        return ""
    }

    private func signingInformation(for path: String) -> String {
        let team: String
        if path.hasSuffix("/SubStore/node/bin/node") {
            team = UpdateFixture.nodeTeamIdentifier
        } else if path.hasSuffix("/Contents/MacOS/KumoService") {
            team = helperTeamIdentifier
        } else if path.hasSuffix(".dmg") {
            team = dmgTeamIdentifier
        } else {
            team = UpdateFixture.teamIdentifier
        }
        let authority = path.hasSuffix("/Contents/MacOS/KumoService") && !helperUsesDeveloperID
            ? "Authority=Apple Development: Untrusted Publisher (\(team))"
            : "Authority=Developer ID Application: Trusted Publisher (\(team))"
        let flags = path.hasSuffix("/Contents/MacOS/KumoService") && !helperHasHardenedRuntime
            ? "flags=0x0(none)"
            : "flags=0x10000(runtime)"
        return """
        \(authority)
        TeamIdentifier=\(team)
        CodeDirectory v=20500 size=1 \(flags) hashes=1+1 location=embedded
        """
    }
}

private final class UpdateLaunchRecorder: @unchecked Sendable {
    struct Invocation {
        var scriptURL: URL
        var arguments: [String]
    }

    private let lock = NSLock()
    private var recordedInvocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    var launcher: AppUpdateInstallerLauncher {
        AppUpdateInstallerLauncher { [self] scriptURL, arguments in
            lock.withLock {
                recordedInvocations.append(Invocation(scriptURL: scriptURL, arguments: arguments))
            }
        }
    }
}
