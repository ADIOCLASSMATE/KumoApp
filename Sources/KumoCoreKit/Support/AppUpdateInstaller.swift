import Foundation

protocol AppUpdateInstalling: Sendable {
    func installDMG(
        dmgURL: URL,
        currentAppURL: URL,
        expectedVersion: String,
        processID: Int32
    ) throws
}

struct AppUpdateInstallerCommandRunner: Sendable {
    let captureOutput: @Sendable (ShellCommand) throws -> String

    init(_ captureOutput: @escaping @Sendable (ShellCommand) throws -> String) {
        self.captureOutput = captureOutput
    }

    static let live = AppUpdateInstallerCommandRunner { command in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let environment = command.environment {
            process.environment = environment
        }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw KumoError.commandFailed(text.isEmpty ? "Command failed: \(command.executable)" : text)
        }
        return text
    }
}

struct AppUpdateInstallerLauncher: Sendable {
    let launch: @Sendable (URL, [String]) throws -> Void

    init(_ launch: @escaping @Sendable (URL, [String]) throws -> Void) {
        self.launch = launch
    }

    static let live = AppUpdateInstallerLauncher { scriptURL, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [scriptURL.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

public struct AppUpdateInstaller: AppUpdateInstalling, Sendable {
    static let expectedBundleIdentifier = "io.kumo.KumoApp"
    static let expectedNodeTeamIdentifier = "HX7739G8FX"

    private let paths: KumoPaths
    private let commandRunner: AppUpdateInstallerCommandRunner
    private let launcher: AppUpdateInstallerLauncher
    private let identifierProvider: @Sendable () -> UUID

    public init(paths: KumoPaths = KumoPaths()) {
        self.init(
            paths: paths,
            commandRunner: .live,
            launcher: .live,
            identifierProvider: UUID.init
        )
    }

    init(
        paths: KumoPaths,
        commandRunner: AppUpdateInstallerCommandRunner,
        launcher: AppUpdateInstallerLauncher,
        identifierProvider: @escaping @Sendable () -> UUID
    ) {
        self.paths = paths
        self.commandRunner = commandRunner
        self.launcher = launcher
        self.identifierProvider = identifierProvider
    }

    public func installDMG(
        dmgURL: URL,
        currentAppURL: URL,
        expectedVersion: String,
        processID: Int32
    ) throws {
        let fileManager = FileManager.default
        let targetAppURL = currentAppURL.standardizedFileURL
        let targetParentURL = targetAppURL.deletingLastPathComponent()
        let trimmedVersion = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetAppURL.pathExtension == "app" else {
            throw validationError("Automatic installation requires Kumo to run from a .app bundle.")
        }
        guard processID > 0 else {
            throw validationError("Automatic installation requires a valid Kumo process identifier.")
        }
        guard !trimmedVersion.isEmpty, trimmedVersion == expectedVersion else {
            throw validationError("The update manifest does not contain a valid expected version.")
        }
        try validateDirectory(targetAppURL, label: "installed Kumo application")
        try validateRegularFile(dmgURL, executable: false, label: "downloaded update")
        guard dmgURL.pathExtension.localizedCaseInsensitiveCompare("dmg") == .orderedSame else {
            throw validationError("Automatic installation requires a DMG update.")
        }
        guard fileManager.isWritableFile(atPath: targetParentURL.path) else {
            throw validationError(
                "Kumo cannot replace itself in \(targetParentURL.path). Move Kumo.app to a writable location or install the update manually."
            )
        }

        let installedMetadata = try bundleMetadata(at: targetAppURL)
        guard installedMetadata.bundleIdentifier == Self.expectedBundleIdentifier else {
            throw validationError("The installed application has an unexpected bundle identifier.")
        }
        try verifyCodeSignature(at: targetAppURL, deep: true, label: "installed application")
        let installedIdentity = try signingIdentity(at: targetAppURL, label: "installed application")
        try validateKumoSigningIdentity(installedIdentity, expectedTeam: installedIdentity.teamIdentifier)

        try validateDMG(dmgURL, expectedTeam: installedIdentity.teamIdentifier)
        try paths.prepare()

        let identifier = identifierProvider().uuidString
        let stagedAppURL = targetParentURL.appendingPathComponent(
            ".Kumo-update-\(identifier).staged.app",
            isDirectory: true
        )
        let backupAppURL = targetParentURL.appendingPathComponent(
            ".Kumo-update-\(identifier).backup.app",
            isDirectory: true
        )
        let mountURL = paths.appUpdatesDirectory.appendingPathComponent(
            "mount-\(identifier)",
            isDirectory: true
        )
        let scriptURL = paths.appUpdatesDirectory.appendingPathComponent("install-update-\(identifier).sh")
        guard !itemExists(at: stagedAppURL),
              !itemExists(at: backupAppURL),
              !itemExists(at: mountURL),
              !itemExists(at: scriptURL) else {
            throw validationError("Kumo refused to reuse an existing update staging path.")
        }

        var shouldRemoveStage = true
        defer {
            if shouldRemoveStage {
                try? fileManager.removeItem(at: stagedAppURL)
            }
            try? fileManager.removeItem(at: mountURL)
        }

        try stageCandidate(from: dmgURL, mountURL: mountURL, stagedAppURL: stagedAppURL)
        try validateCandidate(
            stagedAppURL,
            expectedVersion: trimmedVersion,
            expectedTeam: installedIdentity.teamIdentifier
        )

        try Self.installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        do {
            try launcher.launch(scriptURL, [
                stagedAppURL.path,
                targetAppURL.path,
                backupAppURL.path,
                String(processID),
                paths.appUpdateInstallerLogFile.path,
                "/usr/bin/open",
                Self.expectedBundleIdentifier,
                trimmedVersion,
                installedIdentity.teamIdentifier,
                Self.expectedNodeTeamIdentifier,
                "/usr/bin/codesign",
                "/usr/bin/lipo",
                "/usr/sbin/spctl",
                "/usr/libexec/PlistBuddy"
            ])
            shouldRemoveStage = false
        } catch {
            try? fileManager.removeItem(at: scriptURL)
            throw error
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func validateDMG(_ dmgURL: URL, expectedTeam: String) throws {
        _ = try run(
            "/usr/bin/hdiutil",
            ["verify", dmgURL.path],
            label: "DMG integrity"
        )
        try verifyCodeSignature(at: dmgURL, deep: false, label: "DMG")
        let identity = try signingIdentity(at: dmgURL, label: "DMG")
        guard identity.teamIdentifier == expectedTeam, identity.isDeveloperID else {
            throw validationError("The update DMG is not Developer ID signed by the installed Kumo team.")
        }
        _ = try run(
            "/usr/bin/xcrun",
            ["stapler", "validate", dmgURL.path],
            label: "DMG notarization ticket"
        )
        _ = try run(
            "/usr/sbin/spctl",
            ["--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", dmgURL.path],
            label: "DMG Gatekeeper assessment"
        )
    }

    private func stageCandidate(from dmgURL: URL, mountURL: URL, stagedAppURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)
        var isMounted = false
        do {
            _ = try run(
                "/usr/bin/hdiutil",
                [
                    "attach", dmgURL.path,
                    "-nobrowse", "-readonly", "-noautoopen",
                    "-mountpoint", mountURL.path
                ],
                label: "DMG mount"
            )
            isMounted = true
            let sourceAppURL = mountURL.appendingPathComponent("Kumo.app", isDirectory: true)
            try validateDirectory(sourceAppURL, label: "DMG Kumo application")
            _ = try run(
                "/usr/bin/ditto",
                [sourceAppURL.path, stagedAppURL.path],
                label: "same-volume update staging"
            )
            try validateDirectory(stagedAppURL, label: "staged Kumo application")
            _ = try run(
                "/usr/bin/hdiutil",
                ["detach", mountURL.path, "-quiet"],
                label: "DMG detach"
            )
            isMounted = false
        } catch {
            if isMounted {
                _ = try? commandRunner.captureOutput(ShellCommand(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", mountURL.path, "-quiet", "-force"]
                ))
            }
            throw error
        }
    }

    private func validateCandidate(
        _ appURL: URL,
        expectedVersion: String,
        expectedTeam: String
    ) throws {
        let metadata = try bundleMetadata(at: appURL)
        guard metadata.bundleIdentifier == Self.expectedBundleIdentifier else {
            throw validationError("The update candidate has an unexpected bundle identifier.")
        }
        guard metadata.version == expectedVersion else {
            throw validationError(
                "The update candidate version \(metadata.version) does not match expected version \(expectedVersion)."
            )
        }

        try verifyCodeSignature(at: appURL, deep: true, label: "candidate application")
        let appIdentity = try signingIdentity(at: appURL, label: "candidate application")
        try validateKumoSigningIdentity(appIdentity, expectedTeam: expectedTeam)

        let executables = CandidateExecutables(appURL: appURL)
        let kumoSignedExecutables = [
            (executables.app, "candidate application executable"),
            (executables.helper, "candidate Helper"),
            (executables.cli, "candidate CLI")
        ]
        for (executable, label) in kumoSignedExecutables {
            try validateArm64Executable(executable, label: label)
            try verifyCodeSignature(at: executable, deep: true, label: label)
            let identity = try signingIdentity(at: executable, label: label)
            try validateKumoSigningIdentity(identity, expectedTeam: expectedTeam)
        }

        try validateArm64Executable(executables.node, label: "candidate Node runtime")
        try verifyCodeSignature(at: executables.node, deep: true, label: "candidate Node runtime")
        let nodeIdentity = try signingIdentity(at: executables.node, label: "candidate Node runtime")
        guard nodeIdentity.teamIdentifier == Self.expectedNodeTeamIdentifier,
              nodeIdentity.isDeveloperID,
              nodeIdentity.hasHardenedRuntime else {
            throw validationError(
                "The bundled Node runtime is not hardened-runtime Developer ID code from the Node.js Foundation team."
            )
        }

        _ = try run(
            "/usr/sbin/spctl",
            ["--assess", "--type", "execute", "--verbose=4", appURL.path],
            label: "candidate application Gatekeeper assessment"
        )
    }

    private func validateArm64Executable(_ url: URL, label: String) throws {
        try validateRegularFile(url, executable: true, label: label)
        let architectures = try run(
            "/usr/bin/lipo",
            ["-archs", url.path],
            label: "\(label) architecture"
        )
        guard architectures == "arm64" else {
            throw validationError("The \(label) must contain exactly one arm64 architecture slice.")
        }
    }

    private func verifyCodeSignature(at url: URL, deep: Bool, label: String) throws {
        var arguments = ["--verify", "--strict"]
        if deep {
            arguments.append(contentsOf: ["--deep", "--all-architectures"])
        }
        arguments.append(url.path)
        _ = try run("/usr/bin/codesign", arguments, label: "\(label) code signature")
    }

    private func signingIdentity(at url: URL, label: String) throws -> SigningIdentity {
        let output = try run(
            "/usr/bin/codesign",
            ["-dv", "--verbose=4", url.path],
            label: "\(label) signing identity"
        )
        guard let teamLine = output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw validationError("The \(label) does not declare a signing Team ID.")
        }
        let teamIdentifier = String(teamLine.dropFirst("TeamIdentifier=".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard teamIdentifier.count == 10,
              teamIdentifier.unicodeScalars.allSatisfy({
                  CharacterSet.uppercaseLetters.union(.decimalDigits).contains($0)
              }) else {
            throw validationError("The \(label) has an invalid signing Team ID.")
        }
        return SigningIdentity(
            teamIdentifier: teamIdentifier,
            isDeveloperID: output.split(whereSeparator: \.isNewline).contains(where: {
                $0.hasPrefix("Authority=Developer ID Application:")
            }),
            hasHardenedRuntime: output.split(whereSeparator: \.isNewline).contains(where: {
                $0.hasPrefix("CodeDirectory ") && $0.contains("(runtime)")
            })
        )
    }

    private func validateKumoSigningIdentity(
        _ identity: SigningIdentity,
        expectedTeam: String
    ) throws {
        guard identity.teamIdentifier == expectedTeam,
              identity.isDeveloperID,
              identity.hasHardenedRuntime else {
            throw validationError(
                "Kumo, its Helper, and CLI must use hardened-runtime Developer ID signatures from the installed application team."
            )
        }
    }

    private func bundleMetadata(at appURL: URL) throws -> BundleMetadata {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data: Data
        do {
            data = try Data(contentsOf: infoURL, options: [.mappedIfSafe])
        } catch {
            throw validationError("The application does not contain a readable Info.plist.")
        }
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw validationError("The application contains an invalid Info.plist.")
        }
        guard let values = propertyList as? [String: Any],
              let bundleIdentifier = values["CFBundleIdentifier"] as? String,
              let version = values["CFBundleShortVersionString"] as? String,
              !bundleIdentifier.isEmpty,
              !version.isEmpty else {
            throw validationError("The application Info.plist is missing identity or version metadata.")
        }
        return BundleMetadata(bundleIdentifier: bundleIdentifier, version: version)
    }

    private func validateDirectory(_ url: URL, label: String) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw validationError("The \(label) was not found.")
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw validationError("The \(label) is not a regular directory.")
        }
    }

    private func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func validateRegularFile(_ url: URL, executable: Bool, label: String) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw validationError("The \(label) was not found.")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw validationError("The \(label) is not a regular file.")
        }
        if executable, !FileManager.default.isExecutableFile(atPath: url.path) {
            throw validationError("The \(label) is not executable.")
        }
    }

    private func run(_ executable: String, _ arguments: [String], label: String) throws -> String {
        do {
            return try commandRunner.captureOutput(ShellCommand(
                executable: executable,
                arguments: arguments
            ))
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw validationError("Update validation failed during \(label): \(detail)")
        }
    }

    private func validationError(_ message: String) -> KumoError {
        .invalidArguments(message)
    }

    static let installScript = #"""
    #!/bin/zsh
    set -uo pipefail

    STAGED_APP="$1"
    TARGET_APP="$2"
    BACKUP_APP="$3"
    TARGET_PID="$4"
    LOG_PATH="$5"
    OPEN_TOOL="$6"
    EXPECTED_BUNDLE_ID="$7"
    EXPECTED_VERSION="$8"
    EXPECTED_TEAM="$9"
    EXPECTED_NODE_TEAM="${10}"
    CODESIGN_TOOL="${11}"
    LIPO_TOOL="${12}"
    SPCTL_TOOL="${13}"
    PLIST_TOOL="${14}"
    SCRIPT_PATH="$0"
    FAILED_APP="${STAGED_APP}.failed"
    INSTALL_STATE="prepared"

    /bin/mkdir -p "$(/usr/bin/dirname "$LOG_PATH")"
    exec >> "$LOG_PATH" 2>&1

    finish() {
      exit_code="$1"
      trap - EXIT HUP INT TERM
      if [[ "$exit_code" -ne 0 && "$INSTALL_STATE" != "prepared" && -d "$BACKUP_APP" ]]; then
        rollback_ready=1
        if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
          /bin/mv "$TARGET_APP" "$FAILED_APP" || rollback_ready=0
        fi
        if [[ "$rollback_ready" -eq 1 ]] && /bin/mv "$BACKUP_APP" "$TARGET_APP"; then
          /bin/rm -rf -- "$FAILED_APP" "$STAGED_APP"
          "$OPEN_TOOL" "$TARGET_APP" || true
          echo "[$(/bin/date)] Restored the previous Kumo.app after update failure"
        else
          echo "[$(/bin/date)] Automatic rollback failed; recovery artifacts were preserved"
        fi
      fi
      if [[ "$exit_code" -ne 0 && "$INSTALL_STATE" == "prepared" ]]; then
        /bin/rm -rf -- "$STAGED_APP"
      fi
      if [[ "$exit_code" -eq 0 || ! -e "$BACKUP_APP" ]]; then
        /bin/rm -f -- "$SCRIPT_PATH"
      fi
      exit "$exit_code"
    }

    trap 'finish 129' HUP
    trap 'finish 130' INT
    trap 'finish 143' TERM

    signing_info() {
      "$CODESIGN_TOOL" -dv --verbose=4 "$1" 2>&1
    }

    validate_identity() {
      item="$1"
      expected_team="$2"
      info="$(signing_info "$item")" || return 1
      team="$(/usr/bin/printf '%s\n' "$info" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
      developer_id="$(/usr/bin/printf '%s\n' "$info" | /usr/bin/awk '/^Authority=Developer ID Application:/{print "yes"; exit}')"
      hardened_runtime="$(/usr/bin/printf '%s\n' "$info" | /usr/bin/awk '/^CodeDirectory .*flags=.*\(.*runtime.*\)/{print "yes"; exit}')"
      [[ "$team" == "$expected_team" && "$developer_id" == "yes" && "$hardened_runtime" == "yes" ]] || return 1
    }

    validate_binary() {
      binary="$1"
      expected_team="$2"
      [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || return 1
      [[ "$("$LIPO_TOOL" -archs "$binary")" == "arm64" ]] || return 1
      "$CODESIGN_TOOL" --verify --strict --deep --all-architectures "$binary" || return 1
      validate_identity "$binary" "$expected_team" || return 1
    }

    validate_app_identity() {
      app="$1"
      info_plist="$app/Contents/Info.plist"
      [[ -d "$app" && ! -L "$app" && -f "$info_plist" && ! -L "$info_plist" ]] || return 1
      [[ "$("$PLIST_TOOL" -c 'Print :CFBundleIdentifier' "$info_plist")" == "$EXPECTED_BUNDLE_ID" ]] || return 1
      "$CODESIGN_TOOL" --verify --strict --deep --all-architectures "$app" || return 1
      validate_identity "$app" "$EXPECTED_TEAM" || return 1
    }

    validate_staged_candidate() {
      validate_app_identity "$STAGED_APP" || return 1
      info_plist="$STAGED_APP/Contents/Info.plist"
      [[ "$("$PLIST_TOOL" -c 'Print :CFBundleShortVersionString' "$info_plist")" == "$EXPECTED_VERSION" ]] || return 1
      validate_binary "$STAGED_APP/Contents/MacOS/Kumo" "$EXPECTED_TEAM" || return 1
      validate_binary "$STAGED_APP/Contents/MacOS/KumoService" "$EXPECTED_TEAM" || return 1
      validate_binary "$STAGED_APP/Contents/Helpers/kumo" "$EXPECTED_TEAM" || return 1
      validate_binary "$STAGED_APP/Contents/Resources/Kumo_KumoCoreKit.bundle/Contents/Resources/SubStore/node/bin/node" "$EXPECTED_NODE_TEAM" || return 1
      "$SPCTL_TOOL" --assess --type execute --verbose=4 "$STAGED_APP" || return 1
    }

    echo "[$(/bin/date)] Waiting for Kumo pid $TARGET_PID before installing staged update"
    while /bin/kill -0 "$TARGET_PID" 2>/dev/null; do
      /bin/sleep 0.2
    done

    if [[ ! -d "$STAGED_APP" || -L "$STAGED_APP" || ! -d "$TARGET_APP" || -L "$TARGET_APP" || -e "$BACKUP_APP" || -L "$BACKUP_APP" ]]; then
      echo "Prepared update paths are no longer safe"
      finish 1
    fi

    validate_app_identity "$TARGET_APP" || finish 1
    validate_staged_candidate || finish 1

    /bin/mv "$TARGET_APP" "$BACKUP_APP" || finish 1
    INSTALL_STATE="target-backed-up"
    /bin/mv "$STAGED_APP" "$TARGET_APP" || finish 1
    INSTALL_STATE="candidate-installed"
    "$OPEN_TOOL" "$TARGET_APP" || finish 1
    /bin/rm -rf -- "$BACKUP_APP" || finish 1
    INSTALL_STATE="complete"
    echo "[$(/bin/date)] Kumo update installation finished"
    finish 0
    """#
}

private struct SigningIdentity {
    var teamIdentifier: String
    var isDeveloperID: Bool
    var hasHardenedRuntime: Bool
}

private struct BundleMetadata {
    var bundleIdentifier: String
    var version: String
}

private struct CandidateExecutables {
    var app: URL
    var helper: URL
    var cli: URL
    var node: URL

    init(appURL: URL) {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        self.app = contents.appendingPathComponent("MacOS/Kumo")
        self.helper = contents.appendingPathComponent("MacOS/KumoService")
        self.cli = contents.appendingPathComponent("Helpers/kumo")
        self.node = contents.appendingPathComponent(
            "Resources/Kumo_KumoCoreKit.bundle/Contents/Resources/SubStore/node/bin/node"
        )
    }
}
