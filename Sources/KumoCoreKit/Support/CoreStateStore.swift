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

public struct CoreStateStore: Sendable {
    private let stateFile: URL
    private let ownership: StateFileOwnership?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: KumoPaths = KumoPaths(), ownership: StateFileOwnership? = nil) {
        self.stateFile = paths.stateFile
        self.ownership = ownership
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> CoreStatus {
        guard FileManager.default.fileExists(atPath: stateFile.path) else {
            return CoreStatus()
        }

        let data = try Data(contentsOf: stateFile)
        return try decoder.decode(CoreStatus.self, from: data)
    }

    public func save(_ status: CoreStatus) throws {
        let data = try encoder.encode(status)
        guard let ownership else {
            try FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stateFile, options: .atomic)
            return
        }

        try saveSecurely(data, ownership: ownership)
    }

    private func saveSecurely(_ data: Data, ownership: StateFileOwnership) throws {
        let destinationDirectory = stateFile.deletingLastPathComponent()
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
        guard directoryStatus.st_uid == ownership.userID else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper refused to write state into a directory not owned by authorized user \(ownership.userID)."
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let temporaryDirectoryDescriptor = open(
            temporaryDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard temporaryDirectoryDescriptor >= 0 else {
            throw posixError(operation: "open secure temporary directory", path: temporaryDirectory.path)
        }
        defer { close(temporaryDirectoryDescriptor) }

        var temporaryDirectoryStatus = stat()
        guard fstat(temporaryDirectoryDescriptor, &temporaryDirectoryStatus) == 0 else {
            throw posixError(operation: "inspect secure temporary directory", path: temporaryDirectory.path)
        }
        guard temporaryDirectoryStatus.st_uid == geteuid() else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper refused to stage state in a temporary directory owned by another user."
            )
        }
        let writableByOthers = temporaryDirectoryStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
        let hasStickyBit = temporaryDirectoryStatus.st_mode & mode_t(S_ISVTX) != 0
        guard !writableByOthers || hasStickyBit else {
            throw KumoError.serviceUnavailable(
                "Kumo Helper refused to stage state in an insecure temporary directory."
            )
        }

        let temporaryName = "kumo-state-\(UUID().uuidString).tmp"
        let temporaryDescriptor = openat(
            temporaryDirectoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard temporaryDescriptor >= 0 else {
            throw posixError(operation: "create secure temporary state file", path: temporaryName)
        }
        defer {
            close(temporaryDescriptor)
            unlinkat(temporaryDirectoryDescriptor, temporaryName, 0)
        }

        let handle = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(temporaryDescriptor) == 0 else {
            throw posixError(operation: "synchronize temporary state file", path: temporaryName)
        }

        guard renameat(
            temporaryDirectoryDescriptor,
            temporaryName,
            destinationDescriptor,
            stateFile.lastPathComponent
        ) == 0 else {
            throw posixError(operation: "replace", path: stateFile.path)
        }
        guard fchown(temporaryDescriptor, ownership.userID, ownership.groupID) == 0 else {
            throw posixError(operation: "set owner of", path: stateFile.path)
        }
        guard fchmod(temporaryDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError(operation: "set permissions on", path: stateFile.path)
        }
        guard fsync(temporaryDescriptor) == 0 else {
            throw posixError(operation: "synchronize state file metadata", path: stateFile.path)
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
