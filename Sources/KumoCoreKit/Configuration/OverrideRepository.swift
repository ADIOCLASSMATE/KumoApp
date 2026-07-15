import Foundation

struct OverrideRepositorySnapshot: Sendable {
    var rootExisted: Bool
    var directories: [String]
    var files: [String: Data]
}

public struct OverrideRepository: Sendable {
    private let paths: KumoPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: KumoPaths = KumoPaths()) {
        self.paths = paths
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func listOverrides() throws -> [OverrideItem] {
        try loadItems()
    }

    public func content(id: String) throws -> String {
        guard let item = try loadItems().first(where: { $0.id == id }) else {
            throw KumoError.invalidArguments("Override not found.")
        }
        return try String(contentsOf: fileURL(for: item), encoding: .utf8)
    }

    @discardableResult
    func addLocalOverride(
        name: String,
        format: OverrideFormat,
        content: String,
        isGlobal: Bool = false,
        profileID: String? = nil
    ) throws -> OverrideItem {
        try prepare()
        let item = OverrideItem(
            name: name,
            kind: .local,
            format: format,
            isGlobal: isGlobal,
            profileID: normalizedProfileID(profileID, isGlobal: isGlobal)
        )
        try content.data(using: .utf8)?.write(to: fileURL(for: item), options: .atomic)
        var items = try loadItems()
        items.append(item)
        try saveItems(items)
        return item
    }

    @discardableResult
    func addRemoteOverride(
        url: URL,
        name: String? = nil,
        format: OverrideFormat = .yaml,
        fingerprint: String? = nil,
        isGlobal: Bool = false,
        profileID: String? = nil
    ) async throws -> OverrideItem {
        try prepare()
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw KumoError.invalidArguments("Remote override is not valid UTF-8 text.")
        }
        let item = OverrideItem(
            name: name ?? url.deletingPathExtension().lastPathComponent,
            kind: .remote,
            format: format,
            isGlobal: isGlobal,
            profileID: normalizedProfileID(profileID, isGlobal: isGlobal),
            remoteURL: url,
            fingerprint: fingerprint
        )
        try content.data(using: .utf8)?.write(to: fileURL(for: item), options: .atomic)
        var items = try loadItems()
        items.append(item)
        try saveItems(items)
        return item
    }

    func updateOverride(_ item: OverrideItem, content: String? = nil) throws {
        var items = try loadItems()
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw KumoError.invalidArguments("Override not found.")
        }
        var updatedItem = item
        updatedItem.profileID = normalizedProfileID(
            updatedItem.profileID,
            isGlobal: updatedItem.isGlobal
        )
        updatedItem.updatedAt = Date()
        items[index] = updatedItem
        if let content {
            try content.data(using: .utf8)?.write(to: fileURL(for: updatedItem), options: .atomic)
        }
        try saveItems(items)
    }

    func deleteOverride(id: String) throws {
        var items = try loadItems()
        guard let item = items.first(where: { $0.id == id }) else {
            return
        }
        items.removeAll { $0.id == id }
        try saveItems(items)
        try? FileManager.default.removeItem(at: fileURL(for: item))
    }

    func reorderOverrides(ids: [String]) throws {
        let items = try loadItems()
        let itemIDs = items.map(\.id)
        guard Set(itemIDs).count == itemIDs.count else {
            throw KumoError.commandFailed("The override repository contains duplicate identifiers.")
        }
        guard Set(ids).count == ids.count else {
            throw KumoError.invalidArguments("Override order contains duplicate identifiers.")
        }
        let knownIDs = Set(itemIDs)
        guard Set(ids).isSubset(of: knownIDs) else {
            throw KumoError.invalidArguments("Override order contains an unknown identifier.")
        }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let requestedIDs = Set(ids)
        let ordered = ids.compactMap { byID[$0] }
        let remainder = items.filter { !requestedIDs.contains($0.id) }
        try saveItems(ordered + remainder)
    }

    public func activeYAMLs(for profileID: String) throws -> [String] {
        try activeYAMLs(matching: normalizedProfileID(profileID, isGlobal: false))
    }

    /// Compatibility entry point for callers that do not yet carry a selected
    /// profile identifier. Only explicitly global overrides are safe to apply.
    public func activeYAMLs() throws -> [String] {
        try activeYAMLs(matching: nil)
    }

    func snapshot() throws -> OverrideRepositorySnapshot {
        let fileManager = FileManager.default
        let root = paths.overridesDirectory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return OverrideRepositorySnapshot(rootExisted: false, directories: [], files: [:])
        }
        guard isDirectory.boolValue else {
            throw KumoError.commandFailed("The overrides repository is not a directory.")
        }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else {
            throw KumoError.commandFailed("Kumo refused to snapshot a symbolic-link overrides repository.")
        }

        var directories: [String] = []
        var files: [String: Data] = [:]
        try captureContents(
            of: root,
            relativeComponents: [],
            directories: &directories,
            files: &files
        )
        return OverrideRepositorySnapshot(
            rootExisted: true,
            directories: directories,
            files: files
        )
    }

    func restore(_ snapshot: OverrideRepositorySnapshot) throws {
        let fileManager = FileManager.default
        let root = paths.overridesDirectory
        let parent = root.deletingLastPathComponent()
        let stagingRoot = parent.appendingPathComponent(
            ".overrides-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        let displacedRoot = parent.appendingPathComponent(
            ".overrides-displaced-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if snapshot.rootExisted {
            try write(snapshot, to: stagingRoot)
        }
        var displacedCurrentRepository = false
        do {
            if fileManager.fileExists(atPath: root.path) {
                try fileManager.moveItem(at: root, to: displacedRoot)
                displacedCurrentRepository = true
            }
            if snapshot.rootExisted {
                try fileManager.moveItem(at: stagingRoot, to: root)
            }
            if displacedCurrentRepository {
                try? fileManager.removeItem(at: displacedRoot)
            }
        } catch {
            try? fileManager.removeItem(at: root)
            if displacedCurrentRepository {
                try? fileManager.moveItem(at: displacedRoot, to: root)
            }
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    private func write(_ snapshot: OverrideRepositorySnapshot, to root: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try writeSnapshotContents(snapshot, to: root)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func writeSnapshotContents(
        _ snapshot: OverrideRepositorySnapshot,
        to root: URL
    ) throws {
        let fileManager = FileManager.default
        for relativePath in snapshot.directories.sorted(by: directorySort) {
            let destination = try snapshotDestination(
                relativePath: relativePath,
                root: root
            )
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        }
        for relativePath in snapshot.files.keys.sorted() {
            guard let data = snapshot.files[relativePath] else { continue }
            let destination = try snapshotDestination(
                relativePath: relativePath,
                root: root
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        }
    }

    private func loadItems() throws -> [OverrideItem] {
        guard FileManager.default.fileExists(atPath: paths.overridesMetadataFile.path) else {
            return []
        }
        let data = try Data(contentsOf: paths.overridesMetadataFile)
        return try decoder.decode([OverrideItem].self, from: data)
    }

    private func saveItems(_ items: [OverrideItem]) throws {
        try prepare()
        let data = try encoder.encode(items)
        try data.write(to: paths.overridesMetadataFile, options: .atomic)
    }

    private func fileURL(for item: OverrideItem) -> URL {
        let fileExtension = item.format == .yaml ? "yaml" : "js"
        return paths.overrideFilesDirectory.appendingPathComponent(item.id).appendingPathExtension(fileExtension)
    }

    private func prepare() throws {
        try paths.prepare()
    }

    private func activeYAMLs(matching profileID: String?) throws -> [String] {
        let yamlItems = try loadItems().filter { $0.format == .yaml }
        let profileItems: [OverrideItem]
        if let profileID {
            profileItems = yamlItems.filter {
                !$0.isGlobal && $0.profileID == profileID
            }
        } else {
            profileItems = []
        }
        let globalItems = yamlItems.filter(\.isGlobal)
        return try (profileItems + globalItems).map {
            try String(contentsOf: fileURL(for: $0), encoding: .utf8)
        }
    }

    private func normalizedProfileID(_ profileID: String?, isGlobal: Bool) -> String? {
        guard !isGlobal else { return nil }
        let value = profileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func captureContents(
        of directory: URL,
        relativeComponents: [String],
        directories: inout [String],
        files: inout [String: Data]
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        for child in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) {
            let values = try child.resourceValues(forKeys: keys)
            let childComponents = relativeComponents + [child.lastPathComponent]
            let relativePath = childComponents.joined(separator: "/")
            guard values.isSymbolicLink != true else {
                throw KumoError.commandFailed(
                    "Kumo refused to snapshot a symbolic link inside the overrides repository."
                )
            }
            if values.isDirectory == true {
                directories.append(relativePath)
                try captureContents(
                    of: child,
                    relativeComponents: childComponents,
                    directories: &directories,
                    files: &files
                )
            } else if values.isRegularFile == true {
                files[relativePath] = try Data(contentsOf: child)
            } else {
                throw KumoError.commandFailed(
                    "Kumo refused an unsupported entry inside the overrides repository."
                )
            }
        }
    }

    private func snapshotDestination(relativePath: String, root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw KumoError.commandFailed("The override snapshot contains an unsafe path.")
        }
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func directorySort(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = lhs.split(separator: "/").count
        let rhsDepth = rhs.split(separator: "/").count
        if lhsDepth == rhsDepth {
            return lhs < rhs
        }
        return lhsDepth < rhsDepth
    }
}
