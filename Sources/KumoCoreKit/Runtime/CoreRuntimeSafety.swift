import Darwin
import Foundation

struct CoreRuntimeLayout: Sendable {
    let rootDirectory: URL
    let workDirectory: URL
    let logsDirectory: URL
    let instancesDirectory: URL
    let stateFile: URL
    let pidFile: URL
    let instanceRecordFile: URL
    let lifecycleLockFile: URL
    let runtimeConfigFile: URL
    let coreLogFile: URL
    let runtimeEventsFile: URL
    let isPrivileged: Bool
    let legacyWorkDirectory: URL?
    let legacyInstancesDirectory: URL?

    init(paths: KumoPaths, ownership: StateFileOwnership?) {
        if let ownership {
            let root = paths.privilegedRuntimeDirectory(userID: ownership.userID)
            let work = paths.privilegedRuntimeWorkDirectory(userID: ownership.userID)
            let logs = paths.privilegedRuntimeLogsDirectory(userID: ownership.userID)
            let instances = paths.privilegedCoreInstancesDirectory(userID: ownership.userID)
            self.rootDirectory = root
            self.workDirectory = work
            self.logsDirectory = logs
            self.instancesDirectory = instances
            self.stateFile = root.appendingPathComponent("state.json")
            self.pidFile = root.appendingPathComponent("core.pid")
            self.instanceRecordFile = root.appendingPathComponent("core-instance.json")
            self.lifecycleLockFile = root.appendingPathComponent("core-lifecycle.lock")
            self.runtimeConfigFile = root.appendingPathComponent("config.yaml")
            self.coreLogFile = logs.appendingPathComponent("core.log")
            self.runtimeEventsFile = logs.appendingPathComponent("runtime-events.jsonl")
            self.isPrivileged = true
            self.legacyWorkDirectory = paths.workDirectory
            self.legacyInstancesDirectory = paths.coreInstancesDirectory
        } else {
            self.rootDirectory = paths.applicationSupportDirectory
            self.workDirectory = paths.workDirectory
            self.logsDirectory = paths.logsDirectory
            self.instancesDirectory = paths.coreInstancesDirectory
            self.stateFile = paths.stateFile
            self.pidFile = paths.corePIDFile
            self.instanceRecordFile = paths.coreInstanceFile
            self.lifecycleLockFile = paths.coreLifecycleLockFile
            self.runtimeConfigFile = paths.runtimeConfigFile
            self.coreLogFile = paths.coreLogFile
            self.runtimeEventsFile = paths.runtimeEventsFile
            self.isPrivileged = false
            self.legacyWorkDirectory = nil
            self.legacyInstancesDirectory = nil
        }
    }

    func prepare(paths: KumoPaths) throws {
        guard isPrivileged else {
            try paths.prepare()
            return
        }

        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let rootDescriptor = open(
            rootDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unsafe private runtime directory.")
        }
        defer { close(rootDescriptor) }
        try Self.validatePrivateDirectory(rootDescriptor, permissions: S_IRWXU | S_IXGRP | S_IXOTH)

        try createPrivateSubdirectory(named: "work", under: rootDescriptor)
        try createPrivateSubdirectory(named: "logs", under: rootDescriptor)
        try createPrivateSubdirectory(named: "instances", under: rootDescriptor)
    }

    private func createPrivateSubdirectory(named name: String, under parent: Int32) throws {
        if mkdirat(parent, name, S_IRWXU) != 0, errno != EEXIST {
            throw Self.posixError("create private runtime directory \(name)")
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw Self.posixError("open private runtime directory \(name)")
        }
        defer { close(descriptor) }
        try Self.validatePrivateDirectory(descriptor, permissions: S_IRWXU)
    }

    private static func validatePrivateDirectory(_ descriptor: Int32, permissions: mode_t) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              fchmod(descriptor, permissions) == 0 else {
            throw KumoError.serviceUnavailable("Kumo Helper refused an unsafe private runtime directory.")
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Unable to \(operation): \(String(cString: strerror(code)))"]
        )
    }
}

public struct CoreProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var birthToken: UInt64

    public init(pid: Int32, birthToken: UInt64) {
        self.pid = pid
        self.birthToken = birthToken
    }
}

public struct CoreProcessSnapshot: Equatable, Sendable {
    public var identity: CoreProcessIdentity
    public var executablePath: String
    public var arguments: [String]
    public var userID: uid_t

    public init(
        identity: CoreProcessIdentity,
        executablePath: String,
        arguments: [String],
        userID: uid_t
    ) {
        self.identity = identity
        self.executablePath = executablePath
        self.arguments = arguments
        self.userID = userID
    }
}

/// Retains `Process` handles created by this process until Foundation has
/// reaped the child. Process identity checks intentionally treat an exited
/// child as gone before its zombie entry necessarily disappears; keeping the
/// handle lets `terminate` wait for the corresponding child without ever
/// waiting on, or signalling, a reused PID.
final class CoreLaunchedProcessRegistry: @unchecked Sendable {
    static let shared = CoreLaunchedProcessRegistry()

    private let lock = NSLock()
    private var processes: [CoreProcessIdentity: Process] = [:]

    private init() {}

    func register(_ process: Process, identity: CoreProcessIdentity) {
        lock.lock()
        processes[identity] = process
        lock.unlock()

        process.terminationHandler = { [weak self] _ in
            self?.remove(identity)
        }
    }

    func reapIfTracked(_ identity: CoreProcessIdentity) {
        lock.lock()
        let process = processes[identity]
        lock.unlock()

        process?.waitUntilExit()
        remove(identity)
    }

    private func remove(_ identity: CoreProcessIdentity) {
        lock.lock()
        processes.removeValue(forKey: identity)
        lock.unlock()
    }
}

public enum CoreProcessOwnership: Equatable, Sendable {
    case owned
    case foreign
    case ambiguous
}

public struct CoreOwnedProcessClassifier: Sendable {
    private let primaryWorkDirectory: String
    private let legacyWorkDirectories: Set<String>
    private let primaryInstanceConfigurationDirectory: String
    private let legacyInstanceConfigurationDirectories: Set<String>
    private let allowedExecutablePaths: Set<String>
    private let legacyExecutableNames: Set<String>
    private let endpointArgument: String
    private let allowedUserIDs: Set<uid_t>

    public init(
        workDirectory: String,
        additionalWorkDirectories: Set<String> = [],
        instanceConfigurationsDirectory: String? = nil,
        additionalInstanceConfigurationDirectories: Set<String> = [],
        allowedExecutablePaths: Set<String>,
        legacyExecutableNames: Set<String> = [],
        endpoint: ControllerEndpoint,
        allowedUserIDs: Set<uid_t> = [0, getuid()]
    ) {
        self.primaryWorkDirectory = Self.canonical(workDirectory)
        self.legacyWorkDirectories = Set(additionalWorkDirectories.map(Self.canonical))
        let primaryInstanceDirectory = instanceConfigurationsDirectory
            ?? URL(fileURLWithPath: workDirectory)
                .appendingPathComponent("instances", isDirectory: true).path
        self.primaryInstanceConfigurationDirectory = Self.canonical(primaryInstanceDirectory)
        self.legacyInstanceConfigurationDirectories = Set(
            additionalInstanceConfigurationDirectories.map(Self.canonical)
        )
        self.allowedExecutablePaths = Set(allowedExecutablePaths.map(Self.canonical))
        self.legacyExecutableNames = Set(legacyExecutableNames.map { $0.lowercased() })
        self.endpointArgument = "\(endpoint.host):\(endpoint.port)"
        self.allowedUserIDs = allowedUserIDs.union([0])
    }

    public func classify(_ process: CoreProcessSnapshot) -> CoreProcessOwnership {
        guard allowedUserIDs.contains(process.userID) else {
            return .foreign
        }

        guard let rawWorkDirectory = argument(after: "-d", in: process.arguments) else {
            return .foreign
        }
        let workDirectory = Self.canonical(rawWorkDirectory)
        let usesPrimaryRuntime = workDirectory == primaryWorkDirectory
        let usesLegacyRuntime = legacyWorkDirectories.contains(workDirectory)
        guard usesPrimaryRuntime || usesLegacyRuntime else {
            return .foreign
        }

        let invocationCandidates = [process.executablePath] + Array(process.arguments.prefix(2))
        let hasExactExecutable = invocationCandidates
            .map(Self.canonical)
            .contains(where: allowedExecutablePaths.contains)
        let hasRecognizedLegacyExecutable = usesLegacyRuntime && invocationCandidates.contains {
            legacyExecutableNames.contains(
                URL(fileURLWithPath: $0).lastPathComponent.lowercased()
            )
        }
        guard hasExactExecutable || hasRecognizedLegacyExecutable else { return .foreign }

        if let configPath = argument(after: "-f", in: process.arguments) {
            let canonicalConfig = Self.canonical(configPath)
            if usesPrimaryRuntime {
                return canonicalConfig.hasPrefix(primaryInstanceConfigurationDirectory + "/")
                    ? .owned
                    : .foreign
            }
            let isLegacyInstance = legacyInstanceConfigurationDirectories.contains {
                canonicalConfig.hasPrefix($0 + "/")
            }
            let isLegacyProjection = legacyWorkDirectories.contains {
                canonicalConfig == $0 + "/config.yaml"
            }
            return isLegacyInstance || isLegacyProjection ? .owned : .foreign
        }

        guard argument(after: "-ext-ctl", in: process.arguments) == endpointArgument else {
            return .foreign
        }
        return .owned
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func canonical(_ path: String) -> String {
        // Process ownership is based on the literal Kumo launch contract. Do
        // not resolve user-controlled legacy symlinks: doing so could make a
        // foreign root Mihomo directory compare equal to Kumo's old work path.
        let standardized = URL(fileURLWithPath: path).standardized.path
        if standardized == "/var" || standardized.hasPrefix("/var/") {
            return "/private" + standardized
        }
        return standardized
    }
}

public struct CoreListenerSnapshot: Equatable, Sendable {
    public var ownersByPort: [Int: Set<CoreProcessIdentity>]

    public init(ownersByPort: [Int: Set<CoreProcessIdentity>] = [:]) {
        self.ownersByPort = ownersByPort
    }
}

public enum CoreListenerVerificationError: LocalizedError, Equatable, Sendable {
    case missingListener(Int)
    case unexpectedOwner(Int)

    public var errorDescription: String? {
        switch self {
        case .missingListener(let port):
            "Mihomo has not started listening on port \(port) yet."
        case .unexpectedOwner(let port):
            "Port \(port) is owned by a different process."
        }
    }
}

public struct CoreReadinessVerifier: Sendable {
    public var controllerPort: Int
    public var mixedPort: Int

    public init(controllerPort: Int, mixedPort: Int) {
        self.controllerPort = controllerPort
        self.mixedPort = mixedPort
    }

    public func verify(expected: CoreProcessIdentity, listeners: CoreListenerSnapshot) throws {
        try verify(port: controllerPort, expected: expected, listeners: listeners)
        try verify(port: mixedPort, expected: expected, listeners: listeners)
    }

    private func verify(
        port: Int,
        expected: CoreProcessIdentity,
        listeners: CoreListenerSnapshot
    ) throws {
        let owners = listeners.ownersByPort[port] ?? []
        guard !owners.isEmpty else {
            throw CoreListenerVerificationError.missingListener(port)
        }
        guard owners == [expected] else {
            throw CoreListenerVerificationError.unexpectedOwner(port)
        }
    }
}

public struct RuntimeDataGeneration: Equatable, Sendable {
    private var value: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func beginTransition() -> UInt64 {
        value &+= 1
        return value
    }

    public func accepts(_ candidate: UInt64) -> Bool {
        candidate == value
    }

    public var current: UInt64 { value }
}

struct CoreInstanceRecord: Codable, Equatable, Sendable {
    var schemaVersion: Int = 2
    var launchID: UUID
    var processIdentity: CoreProcessIdentity
    var executablePath: String
    var workDirectoryPath: String
    var configPath: String
    var controllerHost: String
    var controllerPort: Int
    var mixedPort: Int
    var profileID: String?
    var configurationDigest: String?
    var startedAt: Date
}

struct CoreInstanceStore: Sendable {
    private let url: URL
    private let ownership: StateFileOwnership?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(paths: KumoPaths, ownership: StateFileOwnership?) {
        self.url = CoreRuntimeLayout(paths: paths, ownership: ownership).instanceRecordFile
        self.ownership = ownership
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> CoreInstanceRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not open the Mihomo instance record safely.")
        }
        defer { close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            throw KumoError.serviceUnavailable("Kumo refused an unsafe Mihomo instance record.")
        }
        if ownership != nil, fileStatus.st_uid != geteuid() {
            // A user-mode Kumo instance may have left its own record before
            // Helper mode took over. Treat that projection as untrusted and
            // reconcile the actual process through the strict argv classifier.
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        return try decoder.decode(CoreInstanceRecord.self, from: data)
    }

    func save(_ record: CoreInstanceRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try protectPrivilegedDirectoryIfNeeded()
        try encoder.encode(record).write(to: url, options: .atomic)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not protect the Mihomo instance record.")
        }
        defer { close(descriptor) }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw KumoError.serviceUnavailable("Kumo refused an unsafe Mihomo instance record.")
        }
        if ownership != nil,
           fchown(descriptor, geteuid(), getegid()) != 0 {
            throw KumoError.serviceUnavailable("Kumo Helper could not protect the Mihomo instance record.")
        }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func protectPrivilegedDirectoryIfNeeded() throws {
        guard ownership != nil else { return }
        let descriptor = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo Helper could not open its private runtime directory.")
        }
        defer { close(descriptor) }
        guard fchown(descriptor, geteuid(), getegid()) == 0,
              fchmod(descriptor, S_IRWXU | S_IXGRP | S_IXOTH) == 0 else {
            throw KumoError.serviceUnavailable("Kumo Helper could not protect its private runtime directory.")
        }
    }
}

struct CoreLifecycleLock: Sendable {
    private let url: URL
    private let ownership: StateFileOwnership?

    init(paths: KumoPaths, ownership: StateFileOwnership?) {
        self.url = CoreRuntimeLayout(paths: paths, ownership: ownership).lifecycleLockFile
        self.ownership = ownership
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if ownership != nil {
            let directoryDescriptor = open(
                url.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directoryDescriptor >= 0 else {
                throw posixError("open the private Mihomo runtime directory")
            }
            defer { close(directoryDescriptor) }
            guard fchown(directoryDescriptor, geteuid(), getegid()) == 0,
                  fchmod(directoryDescriptor, S_IRWXU | S_IXGRP | S_IXOTH) == 0 else {
                throw posixError("protect the private Mihomo runtime directory")
            }
        }
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw posixError("open the Mihomo lifecycle lock")
        }
        defer { close(descriptor) }
        if ownership != nil {
            guard fchown(descriptor, geteuid(), getegid()) == 0,
                  fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw posixError("set the Mihomo lifecycle lock ownership")
            }
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw posixError("acquire the Mihomo lifecycle lock")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Unable to \(operation): \(String(cString: strerror(code)))"]
        )
    }
}

struct DarwinCoreProcessSystem: Sendable {
    func inspect(pid: Int32) -> CoreProcessSnapshot? {
        guard pid > 0 else { return nil }
        var initialInfo = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &initialInfo, expectedSize) == expectedSize,
              let arguments = processArguments(pid: pid),
              let executablePath = processPath(pid: pid) else {
            return nil
        }
        var finalInfo = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &finalInfo, expectedSize) == expectedSize else {
            return nil
        }
        let initialToken = birthToken(initialInfo)
        let finalToken = birthToken(finalInfo)
        guard initialToken == finalToken else { return nil }
        return CoreProcessSnapshot(
            identity: CoreProcessIdentity(pid: pid, birthToken: finalToken),
            executablePath: executablePath,
            arguments: arguments,
            userID: finalInfo.pbi_uid
        )
    }

    private func birthToken(_ info: proc_bsdinfo) -> UInt64 {
        (UInt64(info.pbi_start_tvsec) << 20) ^ UInt64(info.pbi_start_tvusec)
    }

    func inventory() -> [CoreProcessSnapshot] {
        let requestedCount = max(Int(proc_listallpids(nil, 0)) + 128, 256)
        var pids = [pid_t](repeating: 0, count: requestedCount)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actualCount = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, byteCount)
        }
        guard actualCount > 0 else { return [] }
        return pids.prefix(Int(actualCount)).compactMap { inspect(pid: $0) }
    }

    func listenerSnapshot(ports: Set<Int>) throws -> CoreListenerSnapshot {
        var ownersByPort: [Int: Set<CoreProcessIdentity>] = [:]
        for port in ports {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            if process.terminationStatus != 0 && output.isEmpty {
                ownersByPort[port] = []
                continue
            }
            let identities = output
                .split(separator: "\n")
                .compactMap { line -> CoreProcessIdentity? in
                    guard line.first == "p", let pid = Int32(line.dropFirst()) else { return nil }
                    return inspect(pid: pid)?.identity
                }
            ownersByPort[port] = Set(identities)
        }
        return CoreListenerSnapshot(ownersByPort: ownersByPort)
    }

    func terminate(expected: CoreProcessIdentity) -> Bool {
        let steps: [(signal: Int32, timeout: TimeInterval)] = [
            (SIGINT, 1.0),
            (SIGTERM, 2.0),
            (SIGKILL, 1.0)
        ]
        for step in steps {
            guard inspect(pid: expected.pid)?.identity == expected else {
                CoreLaunchedProcessRegistry.shared.reapIfTracked(expected)
                return true
            }
            guard Darwin.kill(expected.pid, step.signal) == 0 || errno == ESRCH else {
                return false
            }
            if waitForExit(expected: expected, timeout: step.timeout) {
                CoreLaunchedProcessRegistry.shared.reapIfTracked(expected)
                return true
            }
        }
        let stopped = inspect(pid: expected.pid)?.identity != expected
        if stopped {
            CoreLaunchedProcessRegistry.shared.reapIfTracked(expected)
        }
        return stopped
    }

    private func waitForExit(expected: CoreProcessIdentity, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if inspect(pid: expected.pid)?.identity != expected {
                return true
            }
            usleep(50_000)
        }
        return inspect(pid: expected.pid)?.identity != expected
    }

    private func processPath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private func processArguments(pid: Int32) -> [String]? {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, u_int(query.count), &buffer, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size else {
            return nil
        }

        let argumentCount = buffer.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: Int32.self)
        }
        guard argumentCount > 0 else { return [] }
        var index = MemoryLayout<Int32>.size

        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < size, arguments.count < Int(argumentCount) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            if index > start,
               let value = String(bytes: buffer[start..<index], encoding: .utf8) {
                arguments.append(value)
            }
            while index < size, buffer[index] == 0 { index += 1 }
        }
        return arguments
    }
}
