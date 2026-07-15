import Darwin
import CryptoKit
import Foundation
@_spi(KumoService) import KumoCoreKit

enum KumoServiceCommands {
    static func run(arguments: [String]) async throws {
        guard arguments.first == "service" else {
            print("Usage: KumoService service <install|uninstall|status|run>")
            return
        }
        let command = arguments.dropFirst().first ?? "status"
        let remaining = Array(arguments.dropFirst(2))
        switch command {
        case "install":
            try await install(arguments: remaining)
        case "uninstall":
            try await uninstall(arguments: remaining)
        case "status":
            try printStatus(arguments: remaining)
        case "run":
            try await runDaemon(arguments: remaining)
        default:
            throw KumoError.invalidArguments("Unknown service command: \(command)")
        }
    }

    private static func install(arguments: [String]) async throws {
        guard geteuid() == 0 else {
            throw KumoError.serviceUnavailable("KumoService install must run with administrator privileges.")
        }
        guard let source = value(after: "--source", in: arguments),
              let appSupport = value(after: "--app-support", in: arguments),
              let authorizedUID = value(after: "--authorized-uid", in: arguments).flatMap(uid_t.init),
              let keyID = value(after: "--key-id", in: arguments),
              let sharedSecret = value(after: "--shared-secret", in: arguments) else {
            throw KumoError.invalidArguments("Usage: KumoService service install --source <path> --app-support <path> --authorized-uid <uid> --key-id <id> --shared-secret <secret> [--repair-reset-proxy]")
        }
        let authorizedUser = try StateFileOwnership.authorizedUser(userID: authorizedUID)
        let expectedAppSupport = try authorizedApplicationSupport(userID: authorizedUID)
        guard URL(fileURLWithPath: appSupport, isDirectory: true).standardizedFileURL
            == expectedAppSupport.standardizedFileURL else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unexpected user data directory.")
        }
        let sourceURL = URL(fileURLWithPath: source)
        guard sourceURL.path.hasPrefix("/var/root/.kumo-helper.") else {
            throw KumoError.serviceUnavailable("Kumo Helper installation requires a root-private staged executable.")
        }

        let paths = KumoPaths(applicationSupportDirectory: expectedAppSupport)
        try preparePrivilegedDirectories(paths: paths, ownership: authorizedUser)
        try FileManager.default.createDirectory(
            at: paths.serviceExecutableFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let credentials = KumoServiceCredentials(keyID: keyID, sharedSecret: sharedSecret)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let credentialsData = try encoder.encode(credentials)
        let credentialsURL = paths.privilegedServiceCredentialsFile(userID: authorizedUID)
        let executablePermissions = mode_t(
            S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
        )
        let credentialsPermissions = mode_t(S_IRUSR | S_IWUSR)
        let launchDaemonPermissions = mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        let manifestPermissions = launchDaemonPermissions
        let diskState = ServiceInstallationDiskClassifier(
            paths: paths,
            expectedAuthorizedUserID: authorizedUID
        ).classify()
        switch diskState {
        case let .foreignUser(installedUserID):
            throw KumoError.serviceUnavailable(
                "Kumo Helper belongs to user \(installedUserID); refusing to replace another user's privileged service."
            )
        case .unsafe:
            throw KumoError.serviceUnavailable(
                "Kumo Helper refused to replace unsafe privileged installation files."
            )
        case .absent, .legacyComplete, .current, .partial:
            break
        }

        let launchDaemonData = try launchDaemonPlist(paths: paths, authorizedUID: authorizedUID)
        let executableData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let expectedHandshake = KumoServiceHandshake.current(helperVersion: helperVersion)
        let transactionID = UUID()
        let makeManifest: @Sendable (ServiceInstallationManifest.Phase) -> ServiceInstallationManifest = { phase in
            ServiceInstallationManifest(
                transactionID: transactionID,
                phase: phase,
                serviceLabel: KumoServiceManager.launchDaemonLabel,
                authorizedUserID: authorizedUID,
                helperVersion: expectedHandshake.helperVersion,
                protocolVersion: expectedHandshake.protocolVersion,
                capabilities: expectedHandshake.capabilities,
                executableSHA256: sha256(executableData),
                launchDaemonSHA256: sha256(launchDaemonData),
                credentialKeyID: keyID,
                updatedAt: Date()
            )
        }
        let writeManifest: @Sendable (ServiceInstallationManifest.Phase) throws -> Void = { phase in
            let manifestEncoder = JSONEncoder()
            manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try RootOwnedAtomicInstaller.installData(
                try manifestEncoder.encode(makeManifest(phase)),
                to: paths.serviceInstallationManifestFile,
                permissions: manifestPermissions
            )
        }
        let wasLaunchDaemonLoaded = launchDaemonIsLoaded()
        let executableSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: paths.serviceExecutableFile,
            requiredGroup: 0,
            requiredPermissions: executablePermissions,
            maximumBytes: 64 * 1024 * 1024
        )
        let credentialsSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: credentialsURL,
            requiredGroup: 0,
            requiredPermissions: credentialsPermissions,
            maximumBytes: 1024 * 1024
        )
        let launchDaemonSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: paths.serviceLaunchDaemonPlistFile,
            requiredGroup: 0,
            requiredPermissions: launchDaemonPermissions,
            maximumBytes: 1024 * 1024
        )
        let manifestSnapshot = try RootOwnedAtomicInstaller.snapshotFile(
            at: paths.serviceInstallationManifestFile,
            requiredGroup: 0,
            requiredPermissions: manifestPermissions,
            maximumBytes: 1024 * 1024
        )
        let snapshots = [
            executableSnapshot,
            credentialsSnapshot,
            launchDaemonSnapshot,
            manifestSnapshot
        ]
        let updateStrategy: RootOwnedAtomicInstaller.UpdateStrategy
        if case .partial = diskState {
            updateStrategy = .convergentRepair
        } else {
            updateStrategy = RootOwnedAtomicInstaller.updateStrategy(
                wasLoaded: wasLaunchDaemonLoaded,
                executableSnapshot: executableSnapshot,
                launchDaemonSnapshot: launchDaemonSnapshot,
                predecessorCredentialsMatchCandidate: RootOwnedAtomicInstaller
                    .credentialsSnapshot(credentialsSnapshot, matches: credentials)
            )
        }
        let shouldResetProxyForRepair = arguments.contains(
            KumoServiceManager.repairResetProxyArgument
        )
        let installCandidateFiles: @Sendable () throws -> Void = {
            try RootOwnedAtomicInstaller.installExecutable(
                from: sourceURL,
                to: paths.serviceExecutableFile
            )
            try RootOwnedAtomicInstaller.installData(
                credentialsData,
                to: credentialsURL,
                permissions: credentialsPermissions
            )
            try RootOwnedAtomicInstaller.installData(
                launchDaemonData,
                to: paths.serviceLaunchDaemonPlistFile,
                permissions: launchDaemonPermissions
            )
        }
        let startAndValidateCandidate: @Sendable () throws -> Void = {
            try runCommand(
                "/bin/launchctl",
                ["bootstrap", "system", paths.serviceLaunchDaemonPlistFile.path]
            )
            try runCommand(
                "/bin/launchctl",
                ["kickstart", "-k", "system/\(KumoServiceManager.launchDaemonLabel)"]
            )
            let handshake = try waitForAuthenticatedService(
                socketPath: paths.privilegedServiceSocketFile(userID: authorizedUID).path,
                credentials: credentials
            )
            guard handshake == expectedHandshake else {
                throw KumoError.serviceUnavailable(
                    "The newly installed Kumo Helper did not report the expected version and protocol capabilities."
                )
            }
        }

        switch updateStrategy {
        case .rollbackCapable:
            try await RootOwnedAtomicInstaller.performTransaction(
                restoring: snapshots,
                operation: {
                    try writeManifest(.installing)
                    try bootoutLaunchDaemonIfLoaded()
                    if shouldResetProxyForRepair {
                        try await resetPersistedProxyForRepair(
                            paths: paths,
                            ownership: authorizedUser
                        )
                    }
                    try installCandidateFiles()
                    try startAndValidateCandidate()
                    try writeManifest(.installed)
                },
                prepareForRollback: {
                    try bootoutLaunchDaemonIfLoaded()
                },
                completeRollback: {
                    try RootOwnedAtomicInstaller.restoreMissingCredentialForLoadedService(
                        wasLoaded: wasLaunchDaemonLoaded,
                        credentialsSnapshot: credentialsSnapshot,
                        data: credentialsData,
                        permissions: credentialsPermissions
                    )
                    try restoreLaunchDaemonState(
                        wasLoaded: wasLaunchDaemonLoaded,
                        plistURL: paths.serviceLaunchDaemonPlistFile
                    )
                }
            )
        case .convergentRepair:
            // A partially deleted service has no coherent predecessor to roll
            // back to. Stop it first, disable any stale system proxy, replace
            // the complete artifact set, and make every retry converge on the
            // same installed state.
            try await ServiceInstallationCoordinator.converge(
                operations: ConvergentServiceInstallationOperations(
                    writeManifestPhase: writeManifest,
                    stopLoadedService: {
                        try bootoutLaunchDaemonIfLoaded()
                    },
                    makeSystemProxySafe: {
                        try await resetPersistedProxyForRepair(
                            paths: paths,
                            ownership: authorizedUser
                        )
                    },
                    installCandidateFiles: installCandidateFiles,
                    startAndValidateCandidate: startAndValidateCandidate
                )
            )
        }
    }

    private static func uninstall(arguments: [String]) async throws {
        guard geteuid() == 0 else {
            throw KumoError.serviceUnavailable("KumoService uninstall must run with administrator privileges.")
        }
        guard let authorizedUID = value(after: "--authorized-uid", in: arguments).flatMap(uid_t.init) else {
            throw KumoError.invalidArguments("KumoService uninstall requires --authorized-uid <uid>.")
        }
        let authorizedUser = try StateFileOwnership.authorizedUser(userID: authorizedUID)
        let paths = KumoPaths(
            applicationSupportDirectory: try authorizedApplicationSupport(userID: authorizedUID)
        )
        try bootoutLaunchDaemonIfLoaded()
        let controller = KumoController(
            servicePaths: paths,
            stateFileOwnership: authorizedUser
        )
        do {
            var runtime = try controller.status()
            if runtime.systemProxyEnabled {
                _ = try await controller.setSystemProxyFromService(false)
                runtime = try controller.status()
            }
            if !runtime.isStrictlyStoppedRuntime {
                _ = try await controller.stopRuntimeFromService()
            }
            let stopped = try controller.status()
            guard stopped.isStrictlyStoppedRuntime, !stopped.systemProxyEnabled else {
                throw KumoError.serviceUnavailable(
                    "Kumo Helper refused to uninstall while its runtime or system proxy was still active."
                )
            }
        } catch {
            // The Helper files are still intact. Restore the daemon so a
            // failed cleanup attempt cannot strand service mode offline.
            _ = try? runCommand(
                "/bin/launchctl",
                ["bootstrap", "system", paths.serviceLaunchDaemonPlistFile.path]
            )
            _ = try? runCommand(
                "/bin/launchctl",
                ["kickstart", "-k", "system/\(KumoServiceManager.launchDaemonLabel)"]
            )
            throw error
        }
        try? FileManager.default.removeItem(at: paths.serviceLaunchDaemonPlistFile)
        try? FileManager.default.removeItem(at: paths.serviceExecutableFile)
        try? FileManager.default.removeItem(at: paths.privilegedServiceSocketFile(userID: authorizedUID))
        try? FileManager.default.removeItem(at: paths.privilegedServiceCredentialsFile(userID: authorizedUID))
        try? FileManager.default.removeItem(at: paths.serviceInstallationManifestFile)
    }

    private static func printStatus(arguments: [String]) throws {
        let authorizedUID = value(after: "--authorized-uid", in: arguments).flatMap(uid_t.init) ?? getuid()
        let paths = KumoPaths(
            applicationSupportDirectory: try authorizedApplicationSupport(userID: authorizedUID)
        )
        let socketFile = paths.privilegedServiceSocketFile(userID: authorizedUID)
        let status = ServiceModeStatus(
            isInstalled: FileManager.default.fileExists(atPath: paths.serviceLaunchDaemonPlistFile.path),
            isRunning: FileManager.default.fileExists(atPath: socketFile.path),
            isAvailable: geteuid() == 0 || FileManager.default.fileExists(atPath: socketFile.path),
            isCurrentProcessPrivileged: geteuid() == 0,
            socketPath: socketFile.path
        )
        let data = try JSONEncoder().encode(status)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func runDaemon(arguments: [String]) async throws {
        guard let appSupport = value(after: "--app-support", in: arguments) else {
            throw KumoError.invalidArguments("KumoService service run requires --app-support <path>.")
        }
        guard let authorizedUID = value(after: "--authorized-uid", in: arguments).flatMap(uid_t.init) else {
            throw KumoError.invalidArguments("KumoService service run requires a valid --authorized-uid <uid>.")
        }
        let authorizedUser = try StateFileOwnership.authorizedUser(userID: authorizedUID)
        let expectedAppSupport = try authorizedApplicationSupport(userID: authorizedUID)
        guard URL(fileURLWithPath: appSupport, isDirectory: true).standardizedFileURL
            == expectedAppSupport.standardizedFileURL else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unexpected user data directory.")
        }
        let paths = KumoPaths(applicationSupportDirectory: expectedAppSupport)
        try preparePrivilegedDirectories(paths: paths, ownership: authorizedUser)
        let credentialsData = try Data(
            contentsOf: paths.privilegedServiceCredentialsFile(userID: authorizedUID)
        )
        let credentials = try JSONDecoder().decode(KumoServiceCredentials.self, from: credentialsData)
        let server = KumoServiceSocketServer(paths: paths, credentials: credentials, authorizedUser: authorizedUser)
        try await server.run()
    }

    private static func launchDaemonPlist(paths: KumoPaths, authorizedUID: uid_t) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": KumoServiceManager.launchDaemonLabel,
                "ProgramArguments": [
                    paths.serviceExecutableFile.path,
                    "service",
                    "run",
                    "--app-support",
                    paths.applicationSupportDirectory.path,
                    "--authorized-uid",
                    "\(authorizedUID)"
                ],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardOutPath": paths.privilegedServiceLogFile.path,
                "StandardErrorPath": paths.privilegedServiceLogFile.path
            ],
            format: .xml,
            options: 0
        )
    }

    private static var helperVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func runCommand(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw KumoError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func bootoutLaunchDaemonIfLoaded() throws {
        let serviceTarget = "system/\(KumoServiceManager.launchDaemonLabel)"
        let bootoutError: Error?
        do {
            _ = try runCommand("/bin/launchctl", ["bootout", serviceTarget])
            bootoutError = nil
        } catch {
            bootoutError = error
        }

        if (try? runCommand("/bin/launchctl", ["print", serviceTarget])) != nil {
            if let bootoutError {
                throw bootoutError
            }
            throw KumoError.serviceUnavailable(
                "Kumo Helper is still loaded after launchctl bootout."
            )
        }
        // `bootout` reports a non-zero status when the daemon was already
        // unloaded. A failed `print` confirms that this is safe to proceed.
    }

    private static func launchDaemonIsLoaded() -> Bool {
        (try? runCommand(
            "/bin/launchctl",
            ["print", "system/\(KumoServiceManager.launchDaemonLabel)"]
        )) != nil
    }

    private static func restoreLaunchDaemonState(wasLoaded: Bool, plistURL: URL) throws {
        try bootoutLaunchDaemonIfLoaded()
        guard wasLoaded else { return }
        try runCommand("/bin/launchctl", ["bootstrap", "system", plistURL.path])
        try runCommand(
            "/bin/launchctl",
            ["kickstart", "-k", "system/\(KumoServiceManager.launchDaemonLabel)"]
        )
        guard launchDaemonIsLoaded() else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper could not restore the previous launchd loaded state."
            )
        }
    }

    private static func resetPersistedProxyForRepair(
        paths: KumoPaths,
        ownership: StateFileOwnership
    ) async throws {
        let controller = KumoController(
            servicePaths: paths,
            stateFileOwnership: ownership
        )
        _ = try await controller.setSystemProxyFromService(false)
        let disabled = try controller.status()
        guard !disabled.systemProxyEnabled,
              disabled.systemProxyRecoveryAction == nil else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper repair could not persist a disabled system proxy state."
            )
        }
    }

    private static func waitForAuthenticatedService(
        socketPath: String,
        credentials: KumoServiceCredentials,
        maximumAttempts: Int = 20
    ) throws -> KumoServiceHandshake {
        var lastError: Error?
        for attempt in 0..<maximumAttempts {
            do {
                return try authenticatedServiceHealthCheck(
                    socketPath: socketPath,
                    credentials: credentials
                )
            } catch {
                lastError = error
            }
            if attempt + 1 < maximumAttempts {
                usleep(100_000)
            }
        }
        let detail = lastError?.localizedDescription ?? "unknown health-check error"
        throw KumoError.serviceUnavailable(
            "The newly installed Kumo Helper did not pass its authenticated health check: \(detail)"
        )
    }

    private static func authenticatedServiceHealthCheck(
        socketPath: String,
        credentials: KumoServiceCredentials
    ) throws -> KumoServiceHandshake {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw serviceHealthError("create health-check socket")
        }
        defer { close(descriptor) }
        try KumoSocketSafety.configureNoSigPipe(descriptor)
        try configureHealthCheckTimeouts(descriptor, seconds: 1)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maximumPathLength else {
            throw KumoError.serviceUnavailable("Kumo Helper socket path is too long.")
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maximumPathLength) { buffer in
                socketPath.withCString { source in
                    strncpy(buffer, source, maximumPathLength - 1)
                }
            }
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connectResult == 0 else {
            throw serviceHealthError("connect to newly installed Helper")
        }

        let request = KumoServiceRequestSigner(credentials: credentials).signedRequest(
            method: "GET",
            path: "/service/handshake"
        )
        let payload = try JSONEncoder().encode(KumoServiceTransportRequest(request: request))
        try writeHealthCheckPayload(payload, to: descriptor)
        shutdown(descriptor, SHUT_WR)
        let responseData = try readHealthCheckResponse(from: descriptor)
        let response = try JSONDecoder().decode(KumoServiceTransportResponse.self, from: responseData)
        guard (200..<300).contains(response.status) else {
            throw KumoError.serviceUnavailable(
                response.error ?? "Kumo Helper rejected its authenticated health check."
            )
        }
        let handshake = try JSONDecoder().decode(KumoServiceHandshake.self, from: response.body)
        guard handshake.isCompatible else {
            throw KumoError.serviceUnavailable(
                "The newly installed Kumo Helper reported an incompatible protocol."
            )
        }
        return handshake
    }

    private static func configureHealthCheckTimeouts(
        _ descriptor: Int32,
        seconds: Int
    ) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        guard withUnsafePointer(to: &timeout, {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, length)
        }) == 0,
        withUnsafePointer(to: &timeout, {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, length)
        }) == 0 else {
            throw serviceHealthError("configure health-check socket timeouts")
        }
    }

    private static func writeHealthCheckPayload(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw serviceHealthError("write authenticated health-check request")
                }
                bytesWritten += result
            }
        }
    }

    private static func readHealthCheckResponse(from descriptor: Int32) throws -> Data {
        let maximumResponseBytes = 1024 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw serviceHealthError("read authenticated health-check response")
            }
            guard data.count + count <= maximumResponseBytes else {
                throw KumoError.serviceUnavailable("Kumo Helper health-check response was too large.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func serviceHealthError(_ operation: String) -> KumoError {
        let detail: String
        if errno == EAGAIN || errno == EWOULDBLOCK {
            detail = "timed out"
        } else {
            detail = String(cString: strerror(errno))
        }
        return .serviceUnavailable("Unable to \(operation): \(detail).")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}
