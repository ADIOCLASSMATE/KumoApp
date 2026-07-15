import Darwin
import CryptoKit
import Foundation
import Security

struct ValidatedServiceHelper: Sendable {
    var url: URL
    var sha256: String
}

public struct KumoServiceManager: Sendable {
    public static let launchDaemonLabel = "io.kumo.KumoService"
    @_spi(KumoService) public static let repairResetProxyArgument = "--repair-reset-proxy"

    private let paths: KumoPaths

    init(paths: KumoPaths = KumoPaths()) {
        self.paths = paths
    }

    func status() -> ServiceModeStatus {
        let isPrivileged = geteuid() == 0
        let socketPath = paths.privilegedServiceSocketFile(userID: getuid()).path
        let diskState = ServiceInstallationDiskClassifier(
            paths: paths,
            expectedAuthorizedUserID: getuid(),
            inspectionScope: .appVisible
        ).classify()
        let client = serviceClient()
        let handshake = client.flatMap {
            try? $0.sendDecodable($0.handshakeRequest(), as: KumoServiceHandshake.self)
        }
        // The App cannot inspect the root-only credential safely. Always ask
        // the authenticated Helper for its privileged installation view,
        // including after a successful handshake.
        let serviceStatus = client.flatMap {
            try? $0.sendDecodable($0.serviceStatusRequest(), as: ServiceModeStatus.self)
        }
        return Self.composeStatus(
            diskState: diskState,
            handshake: handshake,
            legacyServiceResponded: handshake == nil && serviceStatus?.isRunning == true,
            helperReportedStatus: serviceStatus,
            requiresHelperReportedStatus: true,
            serviceEndpointPresent: FileManager.default.fileExists(atPath: socketPath),
            isCurrentProcessPrivileged: isPrivileged,
            socketPath: socketPath,
        )
    }

    @discardableResult
    func installService(resetProxyRecovery: Bool = false) throws -> ServiceModeStatus {
        let credentials = try ensureCredentials()
        let source = try helperExecutableCandidate()
        let arguments = Self.installArguments(
            sourceURL: source.url,
            applicationSupportDirectory: paths.applicationSupportDirectory,
            authorizedUID: getuid(),
            credentials: credentials,
            resetProxyRecovery: resetProxyRecovery
        )
        try runServiceCommandWithAuthorization(
            source: source,
            arguments: arguments,
            prompt: "Install Kumo Helper"
        )
        let status = status()
        try saveInstalledFlag(status)
        return status
    }

    static func installArguments(
        sourceURL: URL,
        applicationSupportDirectory: URL,
        authorizedUID: uid_t,
        credentials: KumoServiceCredentials,
        resetProxyRecovery: Bool
    ) -> [String] {
        var arguments = [
            "service",
            "install",
            "--source", sourceURL.path,
            "--app-support", applicationSupportDirectory.path,
            "--authorized-uid", "\(authorizedUID)",
            "--key-id", credentials.keyID,
            "--shared-secret", credentials.sharedSecret
        ]
        if resetProxyRecovery {
            arguments.append(Self.repairResetProxyArgument)
        }
        return arguments
    }

    @discardableResult
    func uninstallService() throws -> ServiceModeStatus {
        // Never execute the installed copy while trying to remove or repair
        // it: a partial or tampered installation must not control cleanup.
        let source = try helperExecutableCandidate()
        try runServiceCommandWithAuthorization(
            source: source,
            arguments: [
                "service", "uninstall",
                "--app-support", paths.applicationSupportDirectory.path,
                "--authorized-uid", "\(getuid())"
            ],
            prompt: "Uninstall Kumo Helper"
        )
        try? FileManager.default.removeItem(at: paths.serviceCredentialsFile)
        let next = status()
        try saveInstalledFlag(next)
        return next
    }

    func serviceClient() -> KumoServiceClient? {
        guard let credentials = try? loadCredentials() else {
            return nil
        }
        return KumoServiceClient(
            endpoint: KumoServiceEndpoint(
                socketPath: paths.privilegedServiceSocketFile(userID: getuid()).path
            ),
            credentials: credentials
        )
    }

    func ensureCredentials() throws -> KumoServiceCredentials {
        if let credentials = try? loadCredentials() {
            return credentials
        }
        let credentials = KumoServiceCredentials(
            keyID: UUID().uuidString,
            sharedSecret: UUID().uuidString + UUID().uuidString
        )
        try FileManager.default.createDirectory(
            at: paths.serviceCredentialsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(credentials).write(to: paths.serviceCredentialsFile, options: .atomic)
        chmod(paths.serviceCredentialsFile.path, S_IRUSR | S_IWUSR)
        return credentials
    }

    func loadCredentials() throws -> KumoServiceCredentials {
        let data = try Data(contentsOf: paths.serviceCredentialsFile)
        return try JSONDecoder().decode(KumoServiceCredentials.self, from: data)
    }

    private func saveInstalledFlag(_ status: ServiceModeStatus) throws {
        try FileManager.default.createDirectory(
            at: paths.serviceStatusFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(status).write(to: paths.serviceStatusFile, options: .atomic)
    }

    static func composeStatus(
        diskState: ServiceInstallationDiskState,
        handshake: KumoServiceHandshake?,
        legacyServiceResponded: Bool,
        helperReportedStatus: ServiceModeStatus? = nil,
        requiresHelperReportedStatus: Bool = false,
        serviceEndpointPresent: Bool = false,
        isCurrentProcessPrivileged: Bool,
        socketPath: String
    ) -> ServiceModeStatus {
        let installationHealth = mergedInstallationHealth(
            appVisible: installationHealth(for: diskState),
            helperReported: helperReportedStatus?.installationHealth
        )
        let diskCanRun = installationHealth == .current
            || installationHealth == .legacyComplete
        let isRunning = handshake != nil
            || legacyServiceResponded
            || helperReportedStatus?.isRunning == true
        let helperAllowsAvailability: Bool
        if requiresHelperReportedStatus {
            helperAllowsAvailability = helperReportedStatus?.isAvailable == true
                && helperReportedStatus?.installationHealth != nil
        } else {
            helperAllowsAvailability = helperReportedStatus?.isAvailable ?? true
        }
        let isAvailable = diskCanRun
            && handshake?.isCompatible == true
            && helperAllowsAvailability
        // A socket without readable App credentials is still evidence that a
        // Helper may own the runtime. Treat it as installed-but-unreachable so
        // production never falls back to a second local authority.
        let isInstalled = installationHealth != .absent
            || isRunning
            || helperReportedStatus?.isInstalled == true
            || serviceEndpointPresent
        return ServiceModeStatus(
            isInstalled: isInstalled,
            isRunning: isRunning,
            isAvailable: isAvailable,
            isCurrentProcessPrivileged: isCurrentProcessPrivileged,
            socketPath: socketPath,
            installationHealth: installationHealth,
            helperProtocolVersion: handshake?.protocolVersion
                ?? helperReportedStatus?.helperProtocolVersion,
            helperVersion: handshake?.helperVersion
                ?? helperReportedStatus?.helperVersion,
            helperCapabilities: handshake?.capabilities
                ?? helperReportedStatus?.helperCapabilities,
            message: statusMessage(
                installationHealth: installationHealth,
                isInstalled: isInstalled,
                isRunning: isRunning,
                isAvailable: isAvailable,
                isPrivileged: isCurrentProcessPrivileged
            )
        )
    }

    @_spi(KumoService)
    public static func composePrivilegedStatus(
        diskState: ServiceInstallationDiskState,
        handshake: KumoServiceHandshake,
        isCurrentProcessPrivileged: Bool,
        socketPath: String
    ) -> ServiceModeStatus {
        composeStatus(
            diskState: diskState,
            handshake: handshake,
            legacyServiceResponded: false,
            isCurrentProcessPrivileged: isCurrentProcessPrivileged,
            socketPath: socketPath
        )
    }

    private static func installationHealth(
        for diskState: ServiceInstallationDiskState
    ) -> ServiceInstallationHealth {
        switch diskState {
        case .absent: .absent
        case .legacyComplete: .legacyComplete
        case .current: .current
        case .partial: .partial
        case .foreignUser: .foreignUser
        case .unsafe: .unsafe
        }
    }

    private static func mergedInstallationHealth(
        appVisible: ServiceInstallationHealth,
        helperReported: ServiceInstallationHealth?
    ) -> ServiceInstallationHealth {
        guard let helperReported else {
            return appVisible
        }
        // Neither side may upgrade the other side's safety verdict. The App
        // protects the public executable/plist/manifest surface, while the
        // privileged Helper additionally protects its root-only credential.
        return healthPriority(appVisible) <= healthPriority(helperReported)
            ? appVisible
            : helperReported
    }

    private static func healthPriority(_ health: ServiceInstallationHealth) -> Int {
        switch health {
        case .unsafe: 0
        case .foreignUser: 1
        case .partial: 2
        case .absent: 3
        case .legacyComplete: 4
        case .current: 5
        }
    }

    private static func statusMessage(
        installationHealth: ServiceInstallationHealth,
        isInstalled: Bool,
        isRunning: Bool,
        isAvailable: Bool,
        isPrivileged: Bool
    ) -> String? {
        switch installationHealth {
        case .partial:
            return "Kumo Helper installation is incomplete. Use Install / Repair Service."
        case .foreignUser:
            return "Kumo Helper is registered for another user and cannot be controlled from this account."
        case .unsafe:
            return "Kumo Helper files failed the privileged installation safety checks."
        case .legacyComplete:
            if isAvailable {
                return "Kumo Helper is running with a legacy installation. Repair it to record the verified file manifest."
            }
        case .absent, .current:
            break
        }
        if isRunning, isAvailable {
            return "Kumo Helper is running. System proxy service mode and TUN can use the privileged backend."
        }
        if isRunning {
            return "Kumo Helper is running with an incompatible protocol. Use Install / Repair Service."
        }
        if isPrivileged {
            return "Current process is privileged. TUN can run without the helper, but installing Kumo Helper is recommended."
        }
        if isInstalled {
            return "Kumo Helper is installed but not reachable. Use Install / Repair Service to reload it."
        }
        return "Kumo Helper is required before starting Mihomo."
    }

    private func helperExecutableCandidate() throws -> ValidatedServiceHelper {
        let bundle = Bundle.main
        let candidates = Self.helperCandidateURLs(
            bundleURL: bundle.bundleURL,
            executableURL: bundle.executableURL
        )

        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let validated = try Self.validateHelperFile(
                at: candidate,
                allowedOwnerIDs: [getuid(), 0]
            )
            try validateHelperSignature(candidate)
            return validated
        }

        throw KumoError.serviceUnavailable(
            "KumoService executable was not found in Kumo's sealed application bundle. Rebuild or reinstall Kumo before installing the Helper."
        )
    }

    static func helperCandidateURLs(bundleURL: URL, executableURL: URL?) -> [URL] {
        let executableDirectory = executableURL?.deletingLastPathComponent()
        var candidates = [
            bundleURL.appendingPathComponent("Contents/MacOS/KumoService"),
            bundleURL.appendingPathComponent("Contents/Helpers/KumoService")
        ]
        if executableDirectory?.lastPathComponent == "Helpers" {
            let inferredAppBundle = executableDirectory!
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(inferredAppBundle.appendingPathComponent("Contents/MacOS/KumoService"))
        }
        #if DEBUG
        if let executableDirectory {
            // `swift run` places all products in one build directory. This is
            // the only non-bundle fallback, and it is never compiled into a
            // Release build.
            candidates.append(executableDirectory.appendingPathComponent("KumoService"))
        }
        #endif
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func runServiceCommandWithAuthorization(
        source: ValidatedServiceHelper,
        arguments: [String],
        prompt: String
    ) throws {
        let stageScript = rootStagingScript(source: source, arguments: arguments)
        if geteuid() == 0 {
            try run(executable: "/bin/sh", arguments: ["-c", stageScript])
            return
        }

        let command = ["/bin/sh", "-c", stageScript].map(shellQuote).joined(separator: " ")
        let script = #"do shell script "\#(appleScriptQuote(command))" with administrator privileges with prompt "\#(appleScriptQuote(prompt))""#
        try run(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }

    func rootStagingScript(
        source: ValidatedServiceHelper,
        arguments: [String]
    ) -> String {
        var stagedArguments = arguments
        if let sourceFlag = stagedArguments.firstIndex(of: "--source"),
           stagedArguments.indices.contains(stagedArguments.index(after: sourceFlag)) {
            stagedArguments[stagedArguments.index(after: sourceFlag)] = "$stage"
        }
        let invocation = (["$stage"] + stagedArguments).map { value in
            value == "$stage" ? "\"$stage\"" : shellQuote(value)
        }.joined(separator: " ")
        return """
        set -eu
        umask 077
        stage_dir=$(/usr/bin/mktemp -d /var/root/.kumo-helper.XXXXXX)
        trap '/bin/rm -rf "$stage_dir"' EXIT HUP INT TERM
        stage="$stage_dir/KumoService"
        /bin/cp \(shellQuote(source.url.path)) "$stage"
        /usr/sbin/chown 0:0 "$stage"
        /bin/chmod 0700 "$stage"
        actual=$(/usr/bin/shasum -a 256 "$stage" | /usr/bin/awk '{print $1}')
        test "$actual" = \(shellQuote(source.sha256))
        /usr/bin/codesign --verify --strict --all-architectures "$stage"
        \(invocation)
        """
    }

    static func validateHelperFile(
        at url: URL,
        allowedOwnerIDs: Set<uid_t>
    ) throws -> ValidatedServiceHelper {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw helperValidationError("Kumo refused a symbolic-link or unreadable Helper candidate.")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1,
              allowedOwnerIDs.contains(status.st_uid),
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              status.st_mode & mode_t(S_IXUSR | S_IXGRP | S_IXOTH) != 0,
              status.st_size > 0,
              status.st_size <= 64 * 1024 * 1024 else {
            throw helperValidationError("Kumo refused an unsafe Helper candidate.")
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw helperValidationError("Kumo could not read the Helper candidate safely.")
            }
            guard count > 0 else { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return ValidatedServiceHelper(
            url: url,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func validateHelperSignature(_ url: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                nil
              ) == errSecSuccess else {
            throw Self.helperValidationError("KumoService failed code-signature validation.")
        }

        #if !DEBUG
        let helperTeam = try Self.teamIdentifier(for: staticCode)
        var appCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &appCode) == errSecSuccess,
              let appCode,
              SecStaticCodeCheckValidity(
                appCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                nil
              ) == errSecSuccess,
              let appTeam = try Self.teamIdentifier(for: appCode),
              !appTeam.isEmpty,
              helperTeam == appTeam else {
            throw Self.helperValidationError(
                "Kumo Helper installation requires a release signed by Kumo's application signing team."
            )
        }
        #endif
    }

    private static func teamIdentifier(for code: SecStaticCode) throws -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess else {
            throw helperValidationError("Kumo could not inspect the Helper signing identity.")
        }
        let dictionary = information as? [String: Any]
        return dictionary?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func helperValidationError(_ message: String) -> KumoError {
        .serviceUnavailable(message)
    }

    private func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw KumoError.serviceUnavailable(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
