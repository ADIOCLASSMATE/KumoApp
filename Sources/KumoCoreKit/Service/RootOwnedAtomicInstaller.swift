import Darwin
import Foundation

@_spi(KumoService)
public enum RootOwnedAtomicInstaller {
    public enum UpdateStrategy: Equatable, Sendable {
        /// Both prior launchd artifacts are either present or absent, so a
        /// failed update can restore one coherent predecessor state.
        case rollbackCapable

        /// The disk state cannot be restored into a coherent service. Replace
        /// the complete set and leave it explicitly repairable on failure.
        case convergentRepair
    }

    public struct FileSnapshot: Sendable {
        fileprivate enum Contents: Sendable {
            case missing
            case regular(data: Data, owner: uid_t, group: gid_t, permissions: mode_t)
        }

        public let destinationURL: URL
        fileprivate let requiredDirectoryOwner: uid_t
        fileprivate let contents: Contents

        public var existed: Bool {
            if case .regular = contents { return true }
            return false
        }
    }

    public static func snapshotFile(
        at destinationURL: URL,
        requiredOwner: uid_t = 0,
        requiredGroup: gid_t? = nil,
        requiredPermissions: mode_t? = nil,
        maximumBytes: Int64 = 64 * 1024 * 1024
    ) throws -> FileSnapshot {
        let directoryDescriptor = try openSafeDirectory(
            destinationURL.deletingLastPathComponent(),
            requiredOwner: requiredOwner
        )
        defer { close(directoryDescriptor) }
        let destinationName = try safeName(destinationURL)
        let descriptor = openat(
            directoryDescriptor,
            destinationName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            return FileSnapshot(
                destinationURL: destinationURL,
                requiredDirectoryOwner: requiredOwner,
                contents: .missing
            )
        }
        guard descriptor >= 0 else {
            throw posixError("open existing privileged file for snapshot")
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixError("inspect existing privileged file for snapshot")
        }
        let permissions = status.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO)
        guard
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1,
              status.st_uid == requiredOwner,
              requiredGroup.map({ status.st_gid == $0 }) ?? true,
              requiredPermissions.map({ permissions == $0 }) ?? true,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw KumoError.serviceUnavailable("Kumo refused to snapshot an unsafe privileged file.")
        }
        let data = try read(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            operation: "read existing privileged file snapshot"
        )
        return FileSnapshot(
            destinationURL: destinationURL,
            requiredDirectoryOwner: requiredOwner,
            contents: .regular(
                data: data,
                owner: status.st_uid,
                group: status.st_gid,
                permissions: permissions
            )
        )
    }

    public static func restore(_ snapshot: FileSnapshot) throws {
        switch snapshot.contents {
        case .missing:
            try removeInstalledFile(
                at: snapshot.destinationURL,
                requiredOwner: snapshot.requiredDirectoryOwner
            )
        case let .regular(data, owner, group, permissions):
            try installData(
                data,
                to: snapshot.destinationURL,
                requiredOwner: owner,
                requiredGroup: group,
                permissions: permissions
            )
        }
    }

    public static func performTransaction(
        restoring snapshots: [FileSnapshot],
        operation: () async throws -> Void,
        prepareForRollback: () async throws -> Void = {},
        completeRollback: () async throws -> Void = {}
    ) async throws {
        do {
            try await operation()
        } catch {
            let operationError = error
            var rollbackFailures: [String] = []
            do {
                try await prepareForRollback()
            } catch {
                rollbackFailures.append("prepare rollback: \(error.localizedDescription)")
            }
            for snapshot in snapshots.reversed() {
                do {
                    try restore(snapshot)
                } catch {
                    rollbackFailures.append(
                        "restore \(snapshot.destinationURL.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
            do {
                try await completeRollback()
            } catch {
                rollbackFailures.append("restore service state: \(error.localizedDescription)")
            }
            guard !rollbackFailures.isEmpty else {
                throw operationError
            }
            throw KumoError.serviceUnavailable(
                "Kumo Helper installation failed (\(operationError.localizedDescription)) and rollback was incomplete: \(rollbackFailures.joined(separator: "; "))."
            )
        }
    }

    public static func updateStrategy(
        wasLoaded: Bool,
        executableSnapshot: FileSnapshot,
        launchDaemonSnapshot: FileSnapshot,
        predecessorCredentialsMatchCandidate: Bool = true
    ) -> UpdateStrategy {
        let hasCoherentDiskState = executableSnapshot.existed == launchDaemonSnapshot.existed
        if !hasCoherentDiskState {
            return .convergentRepair
        }
        if wasLoaded, !executableSnapshot.existed {
            // launchd may still hold a deleted executable/plist in memory, but
            // there is no restorable on-disk service. Treat it as damaged.
            return .convergentRepair
        }
        let hasPredecessor = wasLoaded
            || executableSnapshot.existed
            || launchDaemonSnapshot.existed
        if hasPredecessor, !predecessorCredentialsMatchCandidate {
            // Rolling back to a Helper whose credential no longer matches the
            // App would leave a running service that the App cannot
            // authenticate. Credential rotation must converge forward.
            return .convergentRepair
        }
        return .rollbackCapable
    }

    public static func credentialsSnapshot(
        _ snapshot: FileSnapshot,
        matches expected: KumoServiceCredentials
    ) -> Bool {
        guard case let .regular(data, _, _, _) = snapshot.contents,
              let credentials = try? JSONDecoder().decode(
                KumoServiceCredentials.self,
                from: data
              ) else {
            return false
        }
        return credentials == expected
    }

    public static func restoreMissingCredentialForLoadedService(
        wasLoaded: Bool,
        credentialsSnapshot: FileSnapshot,
        data: Data,
        requiredOwner: uid_t = 0,
        requiredGroup: gid_t = 0,
        permissions: mode_t
    ) throws {
        guard wasLoaded, !credentialsSnapshot.existed else { return }
        try installData(
            data,
            to: credentialsSnapshot.destinationURL,
            requiredOwner: requiredOwner,
            requiredGroup: requiredGroup,
            permissions: permissions
        )
    }

    public static func installExecutable(
        from sourceURL: URL,
        to destinationURL: URL,
        requiredOwner: uid_t = 0,
        requiredGroup: gid_t = 0,
        maximumBytes: Int64 = 64 * 1024 * 1024
    ) throws {
        let sourceParent = try openSafeDirectory(
            sourceURL.deletingLastPathComponent(),
            requiredOwner: requiredOwner
        )
        defer { close(sourceParent) }
        let sourceName = try safeName(sourceURL)
        let sourceDescriptor = openat(
            sourceParent,
            sourceName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            throw posixError("open staged Helper source")
        }
        defer { close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              sourceStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              sourceStatus.st_nlink == 1,
              sourceStatus.st_uid == requiredOwner,
              sourceStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              sourceStatus.st_mode & mode_t(S_IXUSR) != 0,
              sourceStatus.st_size > 0,
              sourceStatus.st_size <= maximumBytes else {
            throw KumoError.serviceUnavailable("Kumo refused an unsafe staged Helper executable.")
        }

        try install(
            to: destinationURL,
            requiredOwner: requiredOwner,
            requiredGroup: requiredGroup,
            permissions: S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
        ) { destinationDescriptor in
            try copy(
                sourceDescriptor: sourceDescriptor,
                destinationDescriptor: destinationDescriptor,
                maximumBytes: maximumBytes
            )
        }
    }

    public static func installData(
        _ data: Data,
        to destinationURL: URL,
        requiredOwner: uid_t = 0,
        requiredGroup: gid_t = 0,
        permissions: mode_t
    ) throws {
        try install(
            to: destinationURL,
            requiredOwner: requiredOwner,
            requiredGroup: requiredGroup,
            permissions: permissions
        ) { descriptor in
            try write(data, to: descriptor)
        }
    }

    private static func install(
        to destinationURL: URL,
        requiredOwner: uid_t,
        requiredGroup: gid_t,
        permissions: mode_t,
        populate: (Int32) throws -> Void
    ) throws {
        let destinationDirectoryURL = destinationURL.deletingLastPathComponent()
        let directoryDescriptor = try openSafeDirectory(
            destinationDirectoryURL,
            requiredOwner: requiredOwner
        )
        defer { close(directoryDescriptor) }
        let destinationName = try safeName(destinationURL)
        let temporaryName = ".\(destinationName).installing-\(UUID().uuidString)"
        let temporaryURL = destinationDirectoryURL.appendingPathComponent(temporaryName)
        var shouldRemoveTemporary = true
        var descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw posixError("create staged privileged file")
        }
        defer {
            if descriptor >= 0 { close(descriptor) }
            if shouldRemoveTemporary {
                unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        try populate(descriptor)
        guard fchown(descriptor, requiredOwner, requiredGroup) == 0,
              fchmod(descriptor, permissions) == 0,
              fsync(descriptor) == 0 else {
            throw posixError("protect staged privileged file")
        }
        close(descriptor)
        descriptor = -1

        var destinationStatus = stat()
        let destinationExists = fstatat(
            directoryDescriptor,
            destinationName,
            &destinationStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0
        if !destinationExists, errno != ENOENT {
            throw posixError("inspect privileged destination")
        }

        if destinationExists {
            guard renamex_np(
                temporaryURL.path,
                destinationURL.path,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw posixError("atomically replace privileged file")
            }
            guard fsync(directoryDescriptor) == 0 else {
                let rollback = renamex_np(
                    temporaryURL.path,
                    destinationURL.path,
                    UInt32(RENAME_SWAP)
                )
                if rollback != 0 {
                    shouldRemoveTemporary = false
                }
                throw posixError("synchronize privileged file replacement")
            }
        } else {
            guard renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                destinationName
            ) == 0 else {
                throw posixError("install privileged file")
            }
            guard fsync(directoryDescriptor) == 0 else {
                _ = renameat(
                    directoryDescriptor,
                    destinationName,
                    directoryDescriptor,
                    temporaryName
                )
                throw posixError("synchronize privileged file installation")
            }
        }
    }

    private static func removeInstalledFile(
        at destinationURL: URL,
        requiredOwner: uid_t
    ) throws {
        let directoryDescriptor = try openSafeDirectory(
            destinationURL.deletingLastPathComponent(),
            requiredOwner: requiredOwner
        )
        defer { close(directoryDescriptor) }
        let destinationName = try safeName(destinationURL)
        if unlinkat(directoryDescriptor, destinationName, 0) != 0 {
            guard errno == ENOENT else {
                throw posixError("remove privileged file created during failed installation")
            }
            return
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw posixError("synchronize privileged file removal")
        }
    }

    private static func openSafeDirectory(_ url: URL, requiredOwner: uid_t) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError("open privileged directory")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == requiredOwner,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            close(descriptor)
            throw KumoError.serviceUnavailable("Kumo refused an unsafe privileged directory.")
        }
        return descriptor
    }

    private static func safeName(_ url: URL) throws -> String {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw KumoError.serviceUnavailable("Kumo refused an invalid privileged filename.")
        }
        return name
    }

    private static func copy(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        maximumBytes: Int64
    ) throws {
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(sourceDescriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError("read staged Helper source") }
            guard count > 0 else { break }
            total += Int64(count)
            guard total <= maximumBytes else {
                throw KumoError.serviceUnavailable("The staged Helper executable is too large.")
            }
            try buffer.withUnsafeBytes { pointer in
                guard let base = pointer.baseAddress else { return }
                try writeAll(
                    base: base,
                    count: count,
                    descriptor: destinationDescriptor
                )
            }
        }
    }

    private static func read(
        descriptor: Int32,
        maximumBytes: Int64,
        operation: String
    ) throws -> Data {
        var data = Data()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError(operation) }
            guard count > 0 else { return data }
            total += Int64(count)
            guard total <= maximumBytes else {
                throw KumoError.serviceUnavailable("The privileged file snapshot is too large.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            try writeAll(base: base, count: pointer.count, descriptor: descriptor)
        }
    }

    private static func writeAll(
        base: UnsafeRawPointer,
        count: Int,
        descriptor: Int32
    ) throws {
        var offset = 0
        while offset < count {
            let written = Darwin.write(
                descriptor,
                base.advanced(by: offset),
                count - offset
            )
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw posixError("write staged privileged file") }
            offset += written
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "Unable to \(operation): \(String(cString: strerror(code)))"
            ]
        )
    }
}
