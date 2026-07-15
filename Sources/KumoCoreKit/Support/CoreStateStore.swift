import Darwin
import Foundation

public struct StateFileOwnership: Sendable {
    public var userID: uid_t
    public var groupID: gid_t

    public init(userID: uid_t, groupID: gid_t) {
        self.userID = userID
        self.groupID = groupID
    }

    public static func authorizedUser(userID: uid_t) throws -> StateFileOwnership {
        guard userID != 0 else {
            throw KumoError.serviceUnavailable("Kumo Helper requires a non-root authorized user.")
        }
        guard let passwordEntry = getpwuid(userID) else {
            throw KumoError.serviceUnavailable("Kumo Helper could not resolve authorized user \(userID).")
        }
        return StateFileOwnership(userID: userID, groupID: passwordEntry.pointee.pw_gid)
    }
}

struct CoreStateStore: Sendable {
    private let paths: KumoPaths
    private let layout: CoreRuntimeLayout
    private let stateFile: URL
    private let ownership: StateFileOwnership?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: KumoPaths = KumoPaths(), ownership: StateFileOwnership? = nil) {
        self.paths = paths
        self.layout = CoreRuntimeLayout(paths: paths, ownership: ownership)
        self.stateFile = layout.stateFile
        self.ownership = ownership
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> CoreStatus {
        if ownership == nil {
            guard FileManager.default.fileExists(atPath: stateFile.path) else {
                return CoreStatus()
            }
            let data = try Data(contentsOf: stateFile)
            return try decoder.decode(CoreStatus.self, from: data)
        }

        var runtimeStatus = try loadPrivilegedRuntimeStatus()
        if let journal = try loadSystemProxyJournal() {
            journal.apply(to: &runtimeStatus)
        }
        return runtimeStatus
    }

    private func loadPrivilegedRuntimeStatus() throws -> CoreStatus {

        let directoryDescriptor = open(
            layout.rootDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryDescriptor < 0, errno == ENOENT {
            return CoreStatus()
        }
        guard directoryDescriptor >= 0 else {
            throw posixError(operation: "open private state directory", path: layout.rootDirectory.path)
        }
        defer { close(directoryDescriptor) }
        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unsafe private state directory.")
        }
        let descriptor = openat(
            directoryDescriptor,
            stateFile.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            return CoreStatus()
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open private state file", path: stateFile.path)
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= 4 * 1024 * 1024 else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unsafe private state file.")
        }
        let data = try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).readToEnd() ?? Data()
        return try decoder.decode(CoreStatus.self, from: data)
    }

    public func save(_ status: CoreStatus) throws {
        let data = try encoder.encode(status)
        guard ownership != nil else {
            try FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stateFile, options: .atomic)
            return
        }

        try saveSystemProxyJournal(status)
        try saveSecurely(data)
    }

    /// Writes the proxy recovery record before any `networksetup` mutation.
    /// A crash after this point therefore leaves enough durable information
    /// for the next Helper launch to restore the original macOS configuration.
    func stageSystemProxyJournal(_ status: CoreStatus) throws {
        guard ownership != nil else {
            try save(status)
            return
        }
        try saveSystemProxyJournal(status, phase: .enabled)
    }

    /// Records an in-progress disable before the first `networksetup`
    /// mutation. Loading this phase intentionally presents the proxy as
    /// enabled so Helper startup completes (or safely retries) the restore
    /// instead of re-enabling Kumo's proxy after a crash.
    func stageSystemProxyDisableJournal(_ status: CoreStatus) throws {
        var stagedStatus = status
        stagedStatus.systemProxyRecoveryAction = .completeDisable
        guard ownership != nil else {
            // The non-privileged store is already durable across app restarts;
            // preserve the recovery state there as well.
            try save(stagedStatus)
            return
        }
        try saveSystemProxyJournal(stagedStatus, phase: .disabling)
    }

    private func loadSystemProxyJournal() throws -> SystemProxyRecoveryJournal? {
        guard let ownership else { return nil }
        let journalURL = paths.privilegedSystemProxyJournalFile(userID: ownership.userID)
        let directoryURL = journalURL.deletingLastPathComponent()
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryDescriptor < 0, errno == ENOENT { return nil }
        guard directoryDescriptor >= 0 else {
            throw posixError(operation: "open proxy journal directory", path: directoryURL.path)
        }
        defer { close(directoryDescriptor) }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unsafe proxy journal directory.")
        }

        let descriptor = openat(
            directoryDescriptor,
            journalURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw posixError(operation: "open proxy journal", path: journalURL.path)
        }
        defer { close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_uid == geteuid(),
              fileStatus.st_nlink == 1,
              fileStatus.st_size >= 0,
              fileStatus.st_size <= 1024 * 1024 else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unsafe proxy recovery journal.")
        }
        let data = try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).readToEnd() ?? Data()
        return try decoder.decode(SystemProxyRecoveryJournal.self, from: data)
    }

    private func saveSystemProxyJournal(
        _ status: CoreStatus,
        phase: SystemProxyRecoveryPhase? = nil
    ) throws {
        guard let ownership else { return }
        let journalURL = paths.privilegedSystemProxyJournalFile(userID: ownership.userID)
        let data = try encoder.encode(SystemProxyRecoveryJournal(
            status: status,
            phase: phase ?? {
                if status.systemProxyRecoveryAction == .completeDisable { return .disabling }
                return status.systemProxyEnabled ? .enabled : .disabled
            }()
        ))
        try RootOwnedAtomicInstaller.installData(
            data,
            to: journalURL,
            requiredOwner: geteuid(),
            requiredGroup: getegid(),
            permissions: S_IRUSR | S_IWUSR
        )
    }

    private func saveSecurely(_ data: Data) throws {
        try layout.prepare(paths: paths)
        let destinationDirectory = layout.rootDirectory
        let destinationDescriptor = open(
            destinationDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationDescriptor >= 0 else {
            throw posixError(operation: "open state directory", path: destinationDirectory.path)
        }
        defer { close(destinationDescriptor) }

        var directoryStatus = stat()
        guard fstat(destinationDescriptor, &directoryStatus) == 0 else {
            throw posixError(operation: "inspect state directory", path: destinationDirectory.path)
        }
        guard directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper refused to write state outside its private runtime directory."
            )
        }

        let temporaryName = "kumo-state-\(UUID().uuidString).tmp"
        let temporaryDescriptor = openat(
            destinationDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard temporaryDescriptor >= 0 else {
            throw posixError(operation: "create secure temporary state file", path: temporaryName)
        }
        defer {
            close(temporaryDescriptor)
            unlinkat(destinationDescriptor, temporaryName, 0)
        }

        let handle = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(temporaryDescriptor) == 0 else {
            throw posixError(operation: "synchronize temporary state file", path: temporaryName)
        }

        guard fchown(temporaryDescriptor, geteuid(), getegid()) == 0 else {
            throw posixError(operation: "set owner of", path: stateFile.path)
        }
        guard fchmod(temporaryDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError(operation: "set permissions on", path: stateFile.path)
        }
        guard fsync(temporaryDescriptor) == 0 else {
            throw posixError(operation: "synchronize state file metadata", path: stateFile.path)
        }

        guard renameat(
            destinationDescriptor,
            temporaryName,
            destinationDescriptor,
            stateFile.lastPathComponent
        ) == 0 else {
            throw posixError(operation: "replace", path: stateFile.path)
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw posixError(operation: "synchronize state directory", path: destinationDirectory.path)
        }
    }

    private func posixError(operation: String, path: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Unable to \(operation) \(path): \(String(cString: strerror(code)))"]
        )
    }
}

private enum SystemProxyRecoveryPhase: String, Codable {
    case enabled
    case disabling
    case disabled
}

private struct SystemProxyRecoveryJournal: Codable, Equatable {
    var phase: SystemProxyRecoveryPhase?
    var isEnabled: Bool
    var settings: SystemProxySettings?
    var previousSnapshot: SystemProxySnapshot?
    var appliedSnapshot: SystemProxySnapshot?

    init(status: CoreStatus, phase: SystemProxyRecoveryPhase) {
        self.phase = phase
        self.isEnabled = status.systemProxyEnabled
        self.settings = status.systemProxySettings
        self.previousSnapshot = status.previousSystemProxySnapshot
        self.appliedSnapshot = status.appliedSystemProxySnapshot
    }

    func apply(to status: inout CoreStatus) {
        // Older journals have no phase and retain their legacy isEnabled
        // meaning. A disabling journal remains recoverable as enabled until
        // the controller has verified and committed the restore.
        switch phase {
        case .disabling:
            status.systemProxyEnabled = true
            status.systemProxyRecoveryAction = .completeDisable
        case .enabled:
            status.systemProxyEnabled = true
            status.systemProxyRecoveryAction = nil
        case .disabled:
            status.systemProxyEnabled = false
            status.systemProxyRecoveryAction = nil
        case nil:
            status.systemProxyEnabled = isEnabled
            status.systemProxyRecoveryAction = nil
        }
        status.systemProxySettings = settings
        status.previousSystemProxySnapshot = previousSnapshot
        status.appliedSystemProxySnapshot = appliedSnapshot
    }
}
