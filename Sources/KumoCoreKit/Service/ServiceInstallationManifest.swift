import CryptoKit
import Darwin
import Foundation

/// Root-owned record of the exact files which make up one Helper installation.
/// It intentionally contains no credential secret.
@_spi(KumoService)
public struct ServiceInstallationManifest: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Equatable, Sendable {
        case installing
        case installed
        case repairRequired
    }

    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let transactionID: UUID
    public let phase: Phase
    public let serviceLabel: String
    public let authorizedUserID: UInt32
    public let helperVersion: String
    public let protocolVersion: Int
    public let capabilities: [KumoServiceCapability]
    public let executableSHA256: String
    public let launchDaemonSHA256: String
    public let credentialKeyID: String
    public let updatedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        transactionID: UUID,
        phase: Phase,
        serviceLabel: String,
        authorizedUserID: UInt32,
        helperVersion: String,
        protocolVersion: Int,
        capabilities: [KumoServiceCapability],
        executableSHA256: String,
        launchDaemonSHA256: String,
        credentialKeyID: String,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.phase = phase
        self.serviceLabel = serviceLabel
        self.authorizedUserID = authorizedUserID
        self.helperVersion = helperVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.executableSHA256 = executableSHA256
        self.launchDaemonSHA256 = launchDaemonSHA256
        self.credentialKeyID = credentialKeyID
        self.updatedAt = updatedAt
    }
}

@_spi(KumoService)
public struct ServiceInstallationArtifactPaths: Equatable, Sendable {
    public let applicationSupportDirectory: URL
    public let executableFile: URL
    public let launchDaemonFile: URL
    public let credentialsFile: URL
    public let manifestFile: URL

    public init(
        applicationSupportDirectory: URL,
        executableFile: URL,
        launchDaemonFile: URL,
        credentialsFile: URL,
        manifestFile: URL
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.executableFile = executableFile.standardizedFileURL
        self.launchDaemonFile = launchDaemonFile.standardizedFileURL
        self.credentialsFile = credentialsFile.standardizedFileURL
        self.manifestFile = manifestFile.standardizedFileURL
    }

    public init(paths: KumoPaths, authorizedUserID: UInt32) {
        self.init(
            applicationSupportDirectory: paths.applicationSupportDirectory,
            executableFile: paths.serviceExecutableFile,
            launchDaemonFile: paths.serviceLaunchDaemonPlistFile,
            credentialsFile: paths.privilegedServiceCredentialsFile(userID: authorizedUserID),
            manifestFile: paths.serviceInstallationManifestFile
        )
    }
}

@_spi(KumoService)
public enum ServiceInstallationArtifact: String, Codable, Equatable, Hashable, Sendable {
    case executable
    case launchDaemon
    case credentials
    case manifest
}

@_spi(KumoService)
public enum ServiceInstallationUnsafeViolation: String, Codable, Equatable, Hashable, Sendable {
    case symbolicLink
    case nonRegularFile
    case hardLinked
    case tooLarge
    case unreadable
    case changedDuringInspection
    case wrongOwner
    case wrongGroup
    case wrongPermissions
    case unexpectedServiceIdentity
}

@_spi(KumoService)
public struct ServiceInstallationUnsafeIssue: Codable, Equatable, Hashable, Sendable {
    public let artifact: ServiceInstallationArtifact
    public let violation: ServiceInstallationUnsafeViolation

    public init(
        artifact: ServiceInstallationArtifact,
        violation: ServiceInstallationUnsafeViolation
    ) {
        self.artifact = artifact
        self.violation = violation
    }
}

@_spi(KumoService)
public enum ServiceInstallationPartialReason: String, Codable, Equatable, Hashable, Sendable {
    case missingExecutable
    case missingLaunchDaemon
    case missingCredentials
    case invalidExecutable
    case invalidLaunchDaemon
    case malformedCredentials
    case malformedManifest
    case unsupportedManifestSchema
    case installationInterrupted
    case repairRequired
    case executableDigestMismatch
    case launchDaemonDigestMismatch
    case credentialKeyMismatch
}

@_spi(KumoService)
public enum ServiceInstallationDiskState: Equatable, Sendable {
    case absent
    case legacyComplete
    case current(ServiceInstallationManifest)
    case partial([ServiceInstallationPartialReason])
    case foreignUser(installedUserID: UInt32)
    case unsafe([ServiceInstallationUnsafeIssue])
}

@_spi(KumoService)
public struct ServiceInstallationFileMetadata: Equatable, Sendable {
    public var ownerUserID: UInt32
    public var ownerGroupID: UInt32
    public var permissions: UInt16
    public var linkCount: UInt64
    public var byteCount: Int64

    public init(
        ownerUserID: UInt32,
        ownerGroupID: UInt32,
        permissions: UInt16,
        linkCount: UInt64,
        byteCount: Int64
    ) {
        self.ownerUserID = ownerUserID
        self.ownerGroupID = ownerGroupID
        self.permissions = permissions
        self.linkCount = linkCount
        self.byteCount = byteCount
    }
}

@_spi(KumoService)
public enum ServiceInstallationFileObservation: Equatable, Sendable {
    case missing
    case regular(data: Data, metadata: ServiceInstallationFileMetadata)
    case unsafe(ServiceInstallationUnsafeViolation)
}

@_spi(KumoService)
public struct ServiceInstallationFileReader: Sendable {
    public typealias Inspection = @Sendable (URL, Int64) -> ServiceInstallationFileObservation

    private let inspection: Inspection

    public init(_ inspection: @escaping Inspection) {
        self.inspection = inspection
    }

    public func inspect(_ url: URL, _ maximumBytes: Int64) -> ServiceInstallationFileObservation {
        inspection(url, maximumBytes)
    }

    public static let live = ServiceInstallationFileReader { url, maximumBytes in
        inspectRegularFile(at: url, maximumBytes: maximumBytes)
    }
}

@_spi(KumoService)
public struct ServiceInstallationDiskClassifier: Sendable {
    public enum InspectionScope: Sendable {
        /// Files a normal App process can safely inspect. The root-owned
        /// credential is deliberately excluded; a successful authenticated
        /// Helper handshake proves that the App and Helper share the key.
        case appVisible

        /// Complete on-disk validation used only by the privileged installer
        /// and Helper process.
        case privileged
    }

    private struct ArtifactPolicy: Sendable {
        let artifact: ServiceInstallationArtifact
        let url: URL
        let permissions: UInt16
        let maximumBytes: Int64
    }

    private struct LaunchDaemonIdentity: Sendable {
        let label: String
        let executablePath: String
        let applicationSupportPath: String
        let authorizedUserID: UInt32
    }

    private let paths: ServiceInstallationArtifactPaths
    private let expectedAuthorizedUserID: UInt32
    private let requiredOwnerUserID: UInt32
    private let requiredOwnerGroupID: UInt32
    private let reader: ServiceInstallationFileReader
    private let inspectionScope: InspectionScope

    public init(
        paths: ServiceInstallationArtifactPaths,
        expectedAuthorizedUserID: UInt32,
        requiredOwnerUserID: UInt32 = 0,
        requiredOwnerGroupID: UInt32 = 0,
        inspectionScope: InspectionScope = .privileged,
        reader: ServiceInstallationFileReader = .live
    ) {
        self.paths = paths
        self.expectedAuthorizedUserID = expectedAuthorizedUserID
        self.requiredOwnerUserID = requiredOwnerUserID
        self.requiredOwnerGroupID = requiredOwnerGroupID
        self.inspectionScope = inspectionScope
        self.reader = reader
    }

    public init(
        paths: KumoPaths,
        expectedAuthorizedUserID: UInt32,
        inspectionScope: InspectionScope = .privileged,
        reader: ServiceInstallationFileReader = .live
    ) {
        self.init(
            paths: ServiceInstallationArtifactPaths(
                paths: paths,
                authorizedUserID: expectedAuthorizedUserID
            ),
            expectedAuthorizedUserID: expectedAuthorizedUserID,
            inspectionScope: inspectionScope,
            reader: reader
        )
    }

    public func classify() -> ServiceInstallationDiskState {
        let policies = artifactPolicies
        var observations: [ServiceInstallationArtifact: ServiceInstallationFileObservation] = [:]
        var unsafeIssues: [ServiceInstallationUnsafeIssue] = []

        for policy in policies {
            let observation = reader.inspect(policy.url, policy.maximumBytes)
            observations[policy.artifact] = observation
            switch observation {
            case .missing:
                break
            case let .unsafe(violation):
                unsafeIssues.append(.init(artifact: policy.artifact, violation: violation))
            case let .regular(_, metadata):
                if metadata.linkCount != 1 {
                    unsafeIssues.append(.init(artifact: policy.artifact, violation: .hardLinked))
                }
                if metadata.ownerUserID != requiredOwnerUserID {
                    unsafeIssues.append(.init(artifact: policy.artifact, violation: .wrongOwner))
                }
                if metadata.ownerGroupID != requiredOwnerGroupID {
                    unsafeIssues.append(.init(artifact: policy.artifact, violation: .wrongGroup))
                }
                if metadata.permissions != policy.permissions {
                    unsafeIssues.append(.init(artifact: policy.artifact, violation: .wrongPermissions))
                }
            }
        }

        if !unsafeIssues.isEmpty {
            return .unsafe(sortedUnsafeIssues(unsafeIssues))
        }

        let executableData = observations[.executable]?.regularData
        let launchDaemonData = observations[.launchDaemon]?.regularData
        let credentialsData = observations[.credentials]?.regularData
        let manifestData = observations[.manifest]?.regularData

        if let manifestData {
            return classifyManifestInstallation(
                manifestData: manifestData,
                executableData: executableData,
                launchDaemonData: launchDaemonData,
                credentialsData: credentialsData
            )
        }

        return classifyLegacyInstallation(
            executableData: executableData,
            launchDaemonData: launchDaemonData,
            credentialsData: credentialsData
        )
    }

    private var artifactPolicies: [ArtifactPolicy] {
        var policies = [
            ArtifactPolicy(
                artifact: .executable,
                url: paths.executableFile,
                permissions: 0o755,
                maximumBytes: 64 * 1024 * 1024
            ),
            ArtifactPolicy(
                artifact: .launchDaemon,
                url: paths.launchDaemonFile,
                permissions: 0o644,
                maximumBytes: 1024 * 1024
            ),
            ArtifactPolicy(
                artifact: .manifest,
                url: paths.manifestFile,
                permissions: 0o644,
                maximumBytes: 1024 * 1024
            )
        ]
        if inspectionScope == .privileged {
            policies.insert(
                ArtifactPolicy(
                    artifact: .credentials,
                    url: paths.credentialsFile,
                    permissions: 0o600,
                    maximumBytes: 1024 * 1024
                ),
                at: 2
            )
        }
        return policies
    }

    private func classifyManifestInstallation(
        manifestData: Data,
        executableData: Data?,
        launchDaemonData: Data?,
        credentialsData: Data?
    ) -> ServiceInstallationDiskState {
        guard let manifest = try? JSONDecoder().decode(
            ServiceInstallationManifest.self,
            from: manifestData
        ) else {
            if let launchDaemonData {
                switch validateLaunchDaemonIdentity(launchDaemonData) {
                case .valid, .invalid:
                    break
                case .unsafe:
                    return .unsafe([
                        .init(artifact: .launchDaemon, violation: .unexpectedServiceIdentity)
                    ])
                case let .foreign(userID):
                    return .foreignUser(installedUserID: userID)
                }
            }
            return .partial(sortedPartialReasons(
                [.malformedManifest] + missingReasons(
                    executableData: executableData,
                    launchDaemonData: launchDaemonData,
                    credentialsData: credentialsData
                )
            ))
        }

        guard manifest.serviceLabel == KumoServiceManager.launchDaemonLabel else {
            return .unsafe([
                .init(artifact: .manifest, violation: .unexpectedServiceIdentity)
            ])
        }
        guard manifest.authorizedUserID != 0 else {
            return .partial(sortedPartialReasons(
                [.malformedManifest] + missingReasons(
                    executableData: executableData,
                    launchDaemonData: launchDaemonData,
                    credentialsData: credentialsData
                )
            ))
        }
        guard manifest.authorizedUserID == expectedAuthorizedUserID else {
            return .foreignUser(installedUserID: manifest.authorizedUserID)
        }

        var reasons = manifestValidationReasons(manifest)
        reasons.append(contentsOf: missingReasons(
            executableData: executableData,
            launchDaemonData: launchDaemonData,
            credentialsData: credentialsData
        ))

        if let executableData {
            if executableData.isEmpty {
                reasons.append(.invalidExecutable)
            }
            if digest(executableData) != manifest.executableSHA256 {
                reasons.append(.executableDigestMismatch)
            }
        }

        if let launchDaemonData {
            switch validateLaunchDaemonIdentity(launchDaemonData) {
            case .valid:
                break
            case .invalid:
                reasons.append(.invalidLaunchDaemon)
            case .unsafe:
                return .unsafe([
                    .init(artifact: .launchDaemon, violation: .unexpectedServiceIdentity)
                ])
            case .foreign:
                return .unsafe([
                    .init(artifact: .launchDaemon, violation: .unexpectedServiceIdentity)
                ])
            }
            if digest(launchDaemonData) != manifest.launchDaemonSHA256 {
                reasons.append(.launchDaemonDigestMismatch)
            }
        }

        if let credentialsData {
            if let credentials = validCredentials(credentialsData) {
                if credentials.keyID != manifest.credentialKeyID {
                    reasons.append(.credentialKeyMismatch)
                }
            } else {
                reasons.append(.malformedCredentials)
            }
        }

        switch manifest.phase {
        case .installing:
            reasons.append(.installationInterrupted)
        case .repairRequired:
            reasons.append(.repairRequired)
        case .installed:
            break
        }

        let normalizedReasons = sortedPartialReasons(reasons)
        guard normalizedReasons.isEmpty else {
            return .partial(normalizedReasons)
        }
        return .current(manifest)
    }

    private func classifyLegacyInstallation(
        executableData: Data?,
        launchDaemonData: Data?,
        credentialsData: Data?
    ) -> ServiceInstallationDiskState {
        guard executableData != nil || launchDaemonData != nil || credentialsData != nil else {
            return .absent
        }

        if let launchDaemonData {
            switch validateLaunchDaemonIdentity(launchDaemonData) {
            case .valid:
                break
            case .invalid:
                break
            case .unsafe:
                return .unsafe([
                    .init(artifact: .launchDaemon, violation: .unexpectedServiceIdentity)
                ])
            case let .foreign(userID):
                return .foreignUser(installedUserID: userID)
            }
        }

        var reasons = missingReasons(
            executableData: executableData,
            launchDaemonData: launchDaemonData,
            credentialsData: credentialsData
        )
        if executableData?.isEmpty == true {
            reasons.append(.invalidExecutable)
        }
        if let launchDaemonData,
           case .invalid = validateLaunchDaemonIdentity(launchDaemonData) {
            reasons.append(.invalidLaunchDaemon)
        }
        if let credentialsData, validCredentials(credentialsData) == nil {
            reasons.append(.malformedCredentials)
        }

        let normalizedReasons = sortedPartialReasons(reasons)
        return normalizedReasons.isEmpty ? .legacyComplete : .partial(normalizedReasons)
    }

    private enum LaunchDaemonValidation {
        case valid
        case invalid
        case unsafe
        case foreign(UInt32)
    }

    private func validateLaunchDaemonIdentity(_ data: Data) -> LaunchDaemonValidation {
        guard let identity = launchDaemonIdentity(data) else {
            return .invalid
        }
        guard identity.label == KumoServiceManager.launchDaemonLabel,
              URL(fileURLWithPath: identity.executablePath).standardizedFileURL == paths.executableFile else {
            return .unsafe
        }
        guard identity.authorizedUserID == expectedAuthorizedUserID else {
            return .foreign(identity.authorizedUserID)
        }
        guard URL(fileURLWithPath: identity.applicationSupportPath, isDirectory: true).standardizedFileURL
                == paths.applicationSupportDirectory else {
            return .unsafe
        }
        return .valid
    }

    private func launchDaemonIdentity(_ data: Data) -> LaunchDaemonIdentity? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let dictionary = propertyList as? [String: Any],
        let label = dictionary["Label"] as? String,
        let arguments = dictionary["ProgramArguments"] as? [String],
        arguments.count >= 7,
        arguments[1] == "service",
        arguments[2] == "run",
        let appSupportFlag = arguments.firstIndex(of: "--app-support"),
        arguments.indices.contains(arguments.index(after: appSupportFlag)),
        let authorizedUserFlag = arguments.firstIndex(of: "--authorized-uid"),
        arguments.indices.contains(arguments.index(after: authorizedUserFlag)),
        let authorizedUserID = UInt32(arguments[arguments.index(after: authorizedUserFlag)]) else {
            return nil
        }
        return LaunchDaemonIdentity(
            label: label,
            executablePath: arguments[0],
            applicationSupportPath: arguments[arguments.index(after: appSupportFlag)],
            authorizedUserID: authorizedUserID
        )
    }

    private func manifestValidationReasons(
        _ manifest: ServiceInstallationManifest
    ) -> [ServiceInstallationPartialReason] {
        var reasons: [ServiceInstallationPartialReason] = []
        if manifest.schemaVersion != ServiceInstallationManifest.currentSchemaVersion {
            reasons.append(.unsupportedManifestSchema)
        }
        if manifest.authorizedUserID == 0
            || manifest.helperVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || manifest.protocolVersion <= 0
            || manifest.capabilities.isEmpty
            || manifest.capabilities.contains(where: {
                $0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            || Set(manifest.capabilities).count != manifest.capabilities.count
            || !isCanonicalSHA256(manifest.executableSHA256)
            || !isCanonicalSHA256(manifest.launchDaemonSHA256)
            || manifest.credentialKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append(.malformedManifest)
        }
        return reasons
    }

    private func missingReasons(
        executableData: Data?,
        launchDaemonData: Data?,
        credentialsData: Data?
    ) -> [ServiceInstallationPartialReason] {
        var reasons: [ServiceInstallationPartialReason] = []
        if executableData == nil { reasons.append(.missingExecutable) }
        if launchDaemonData == nil { reasons.append(.missingLaunchDaemon) }
        if inspectionScope == .privileged, credentialsData == nil {
            reasons.append(.missingCredentials)
        }
        return reasons
    }

    private func validCredentials(_ data: Data) -> KumoServiceCredentials? {
        guard let credentials = try? JSONDecoder().decode(KumoServiceCredentials.self, from: data),
              !credentials.keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return credentials
    }

    private func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character)
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sortedPartialReasons(
        _ reasons: [ServiceInstallationPartialReason]
    ) -> [ServiceInstallationPartialReason] {
        Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
    }

    private func sortedUnsafeIssues(
        _ issues: [ServiceInstallationUnsafeIssue]
    ) -> [ServiceInstallationUnsafeIssue] {
        Array(Set(issues)).sorted {
            ($0.artifact.rawValue, $0.violation.rawValue)
                < ($1.artifact.rawValue, $1.violation.rawValue)
        }
    }
}

private extension ServiceInstallationFileObservation {
    var regularData: Data? {
        guard case let .regular(data, _) = self else { return nil }
        return data
    }
}

private func inspectRegularFile(
    at url: URL,
    maximumBytes: Int64
) -> ServiceInstallationFileObservation {
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0 else {
        return errno == ENOENT ? .missing : .unsafe(.unreadable)
    }
    let fileType = pathStatus.st_mode & mode_t(S_IFMT)
    if fileType == mode_t(S_IFLNK) {
        return .unsafe(.symbolicLink)
    }
    guard fileType == mode_t(S_IFREG) else {
        return .unsafe(.nonRegularFile)
    }
    guard pathStatus.st_nlink == 1 else {
        return .unsafe(.hardLinked)
    }
    guard pathStatus.st_size >= 0, pathStatus.st_size <= maximumBytes else {
        return .unsafe(.tooLarge)
    }

    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        return .unsafe(errno == ELOOP ? .symbolicLink : .unreadable)
    }
    defer { close(descriptor) }

    var openedStatus = stat()
    guard fstat(descriptor, &openedStatus) == 0 else {
        return .unsafe(.unreadable)
    }
    guard openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          openedStatus.st_dev == pathStatus.st_dev,
          openedStatus.st_ino == pathStatus.st_ino,
          openedStatus.st_nlink == 1,
          openedStatus.st_size >= 0,
          openedStatus.st_size <= maximumBytes else {
        return .unsafe(.changedDuringInspection)
    }

    var data = Data()
    data.reserveCapacity(Int(openedStatus.st_size))
    var totalBytes: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { return .unsafe(.unreadable) }
        guard count > 0 else { break }
        totalBytes += Int64(count)
        guard totalBytes <= maximumBytes else { return .unsafe(.tooLarge) }
        data.append(contentsOf: buffer.prefix(count))
    }
    guard totalBytes == openedStatus.st_size else {
        return .unsafe(.changedDuringInspection)
    }

    let permissions = openedStatus.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO | S_ISUID | S_ISGID)
    return .regular(
        data: data,
        metadata: ServiceInstallationFileMetadata(
            ownerUserID: openedStatus.st_uid,
            ownerGroupID: openedStatus.st_gid,
            permissions: UInt16(permissions),
            linkCount: UInt64(openedStatus.st_nlink),
            byteCount: openedStatus.st_size
        )
    )
}
