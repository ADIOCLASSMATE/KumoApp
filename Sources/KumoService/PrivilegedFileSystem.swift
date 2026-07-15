import Darwin
import Foundation
@_spi(KumoService) import KumoCoreKit

func checkPOSIX(_ result: Int32, operation: String) throws {
    guard result == 0 else {
        throw posixError(operation: operation)
    }
}

func preparePrivilegedDirectories(
    paths: KumoPaths,
    ownership: StateFileOwnership
) throws {
    let runtimeDirectory = paths.privilegedRuntimeDirectory(userID: ownership.userID)
    let serviceUserDirectory = paths.privilegedServiceCredentialsFile(userID: ownership.userID)
        .deletingLastPathComponent()
    let directories: [(URL, mode_t)] = [
        (paths.privilegedServiceSupportDirectory, S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH),
        (paths.privilegedServiceSupportDirectory.appendingPathComponent("users", isDirectory: true), S_IRWXU | S_IXGRP | S_IXOTH),
        (serviceUserDirectory, S_IRWXU),
        (paths.privilegedRuntimeRootDirectory, S_IRWXU | S_IXGRP | S_IXOTH),
        (runtimeDirectory, S_IRWXU | S_IXGRP | S_IXOTH)
    ]

    for (directory, permissions) in directories {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError(operation: "open private Helper directory")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == 0,
              fchown(descriptor, 0, 0) == 0,
              fchmod(descriptor, permissions) == 0 else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unsafe privileged directory.")
        }
    }
}

func authorizedApplicationSupport(userID: uid_t) throws -> URL {
    guard userID != 0, let passwordEntry = getpwuid(userID) else {
        throw KumoError.serviceUnavailable("Kumo Helper could not resolve its authorized user.")
    }
    let home = URL(
        fileURLWithPath: String(cString: passwordEntry.pointee.pw_dir),
        isDirectory: true
    )
    return home
        .appendingPathComponent("Library/Application Support", isDirectory: true)
        .appendingPathComponent("Kumo", isDirectory: true)
}

private func posixError(operation: String) -> NSError {
    let code = errno
    return NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"]
    )
}
