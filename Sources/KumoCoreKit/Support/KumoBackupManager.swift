import Foundation

public struct KumoBackupManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var appName: String

    public init(formatVersion: Int = 1, createdAt: Date = Date(), appName: String = "Kumo") {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appName = appName
    }
}

public struct KumoBackupResult: Codable, Equatable, Sendable {
    public var destinationPath: String
    public var manifest: KumoBackupManifest

    public init(destinationPath: String, manifest: KumoBackupManifest) {
        self.destinationPath = destinationPath
        self.manifest = manifest
    }
}

struct KumoBackupManager: Sendable {
    private let paths: KumoPaths

    init(paths: KumoPaths = KumoPaths()) {
        self.paths = paths
    }

    @discardableResult
    func exportBackup(to destination: URL) throws -> KumoBackupResult {
        try paths.prepare()
        try prepareEmptyDirectory(destination)

        let manifest = KumoBackupManifest()
        try makeEncoder().encode(manifest).write(to: manifestURL(in: destination), options: .atomic)

        try copyIfPresent(paths.profilesDirectory, to: destination.appendingPathComponent("profiles", isDirectory: true))
        try copyIfPresent(paths.overridesDirectory, to: destination.appendingPathComponent("overrides", isDirectory: true))
        try copyIfPresent(paths.subStoreDirectory, to: destination.appendingPathComponent("substore", isDirectory: true))
        try copyIfPresent(paths.stateFile, to: destination.appendingPathComponent("state.json"))

        return KumoBackupResult(destinationPath: destination.path, manifest: manifest)
    }

    @discardableResult
    func importBackup(from source: URL) throws -> KumoBackupManifest {
        let manifest = try makeDecoder().decode(KumoBackupManifest.self, from: Data(contentsOf: manifestURL(in: source)))
        guard manifest.formatVersion == 1 else {
            throw KumoError.invalidArguments("Unsupported backup format version \(manifest.formatVersion).")
        }

        try paths.prepare()
        try replaceExactly(source.appendingPathComponent("profiles", isDirectory: true), with: paths.profilesDirectory)
        try replaceExactly(source.appendingPathComponent("overrides", isDirectory: true), with: paths.overridesDirectory)
        try replaceExactly(source.appendingPathComponent("substore", isDirectory: true), with: paths.subStoreDirectory)
        try replaceExactly(source.appendingPathComponent("state.json"), with: paths.stateFile)
        return manifest
    }

    private func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private func prepareEmptyDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func copyIfPresent(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            return
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func replaceExactly(_ source: URL, with destination: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).backup-import-\(UUID().uuidString)"
        )
        let displaced = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).backup-previous-\(UUID().uuidString)"
        )
        let sourceExists = fileManager.fileExists(atPath: source.path)
        if sourceExists {
            try validateBackupEntry(source)
            try fileManager.copyItem(at: source, to: staged)
        }
        var displacedExisting = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: displaced)
                displacedExisting = true
            }
            if sourceExists {
                try fileManager.moveItem(at: staged, to: destination)
            }
            if displacedExisting {
                try? fileManager.removeItem(at: displaced)
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            if displacedExisting {
                try? fileManager.moveItem(at: displaced, to: destination)
            }
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    private func validateBackupEntry(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else {
            throw KumoError.invalidArguments("Backups may not contain symbolic links.")
        }
        if values.isDirectory == true {
            for child in try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) {
                try validateBackupEntry(child)
            }
        } else if values.isRegularFile != true {
            throw KumoError.invalidArguments("The backup contains an unsupported filesystem entry.")
        }
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
