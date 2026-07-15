import Darwin
import Foundation

struct ProfileRepositorySnapshot: Sendable {
    var profileID: String
    var profileData: Data?
    var metadataData: Data?
}

public struct ProfileRepository: Sendable {
    private let profilesDirectory: URL
    private let currentProfileFile: URL
    private let metadataFile: URL
    private let contentNormalizer: ProfileContentNormalizer

    public init(paths: KumoPaths = KumoPaths()) {
        self.init(
            paths: paths,
            subscriptionConverter: IsolatedSubStoreSubscriptionConverter()
        )
    }

    init(
        paths: KumoPaths,
        subscriptionConverter: any ProfileSubscriptionConverting
    ) {
        self.profilesDirectory = paths.profilesDirectory
        self.currentProfileFile = paths.profilesDirectory.appendingPathComponent("current.txt")
        self.metadataFile = paths.profilesDirectory.appendingPathComponent("profiles-metadata.json")
        self.contentNormalizer = ProfileContentNormalizer(converter: subscriptionConverter)
    }

    public func loadDefaultProfile() throws -> Profile {
        try loadProfile(id: currentProfileID())
    }

    public func listProfiles() throws -> [ProfileSummary] {
        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true
        )

        let currentID = try currentProfileID()
        let metadata = try loadMetadata()
        var summaries = try profileFileURLs()
            .map { url -> ProfileSummary in
                let id = url.deletingPathExtension().lastPathComponent
                return try summary(for: id, url: url, metadata: metadata[id], currentID: currentID)
            }
            .sorted(by: profileSort)

        if summaries.isEmpty {
            summaries = [
                ProfileSummary(
                    id: "default",
                    name: "Default",
                    sourceDescription: "Generated direct profile",
                    updatedAt: nil,
                    isCurrent: currentID == "default"
                )
            ]
        }

        return summaries
    }

    public func currentProfileSummary() throws -> ProfileSummary {
        try listProfiles().first(where: \.isCurrent)
            ?? ProfileSummary(id: "default", name: "Default", sourceDescription: "Generated direct profile", isCurrent: true)
    }

    func setCurrentProfile(id: String) throws {
        try validateProfileID(id)
        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true
        )
        guard id == "default" || FileManager.default.fileExists(atPath: profileURL(for: id).path) else {
            throw KumoError.invalidArguments("The selected profile no longer exists.")
        }
        guard let data = id.data(using: .utf8) else {
            throw KumoError.invalidArguments("The profile identifier could not be encoded as UTF-8.")
        }
        try writeOwnedData(data, to: currentProfileFile, permissions: 0o600)
    }

    public func currentProfileIDValue() throws -> String {
        try currentProfileID()
    }

    public func loadProfile(id: String) throws -> Profile {
        try validateProfileID(id)
        let profileURL = profileURL(for: id)
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            if id != "default" {
                return try loadProfile(id: "default")
            }
            return Profile(
                name: "Empty Profile",
                source: .inline,
                rawYAML: defaultProfileYAML(),
                updatedAt: Date()
            )
        }

        let yaml = try readUTF8(at: profileURL)
        let metadata = try loadMetadata()[id]
        let source: ProfileSource
        if metadata?.kind == .remote, let remoteURL = metadata?.remoteURL {
            source = .remote(remoteURL)
        } else {
            source = .file(profileURL)
        }
        return Profile(
            name: metadata?.name ?? displayName(for: profileURL),
            source: source,
            rawYAML: yaml,
            updatedAt: metadata?.updatedAt ?? modificationDate(for: profileURL)
        )
    }

    public func legacyLoadDefaultProfile() throws -> Profile {
        let url = profilesDirectory.appendingPathComponent("default.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Profile(
                name: "Empty Profile",
                source: .inline,
                rawYAML: defaultProfileYAML(),
                updatedAt: Date()
            )
        }

        let yaml = try String(contentsOf: url, encoding: .utf8)
        return Profile(name: "Default", source: .file(url), rawYAML: yaml, updatedAt: Date())
    }

    public func saveDefaultProfile(_ profile: Profile) throws {
        try ProfileContentNormalizer.validateMihomoYAML(profile.rawYAML)
        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true
        )
        let url = profilesDirectory.appendingPathComponent("default.yaml")
        try writeProfileYAML(profile.rawYAML, to: url)
    }

    @discardableResult
    func saveProfile(_ profile: Profile, preferredID: String? = nil, makeCurrent: Bool = false) throws -> ProfileSummary {
        try ProfileContentNormalizer.validateMihomoYAML(profile.rawYAML)
        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true
        )
        let id = preferredID ?? stableProfileID(for: profile)
        try validateProfileID(id)
        let url = profileURL(for: id)
        try writeProfileYAML(profile.rawYAML, to: url)
        var metadata = try loadMetadata()
        let existing = metadata[id]
        metadata[id] = ProfileMetadata(
            id: id,
            name: profile.name,
            kind: kind(for: profile.source),
            remoteURL: remoteURL(for: profile.source),
            homeURL: existing?.homeURL,
            updatedAt: profile.updatedAt ?? Date(),
            autoUpdate: existing?.autoUpdate ?? true,
            useProxy: existing?.useProxy ?? false,
            updateIntervalSeconds: existing?.updateIntervalSeconds,
            subscriptionUserInfo: existing?.subscriptionUserInfo,
            isSubStoreManaged: existing?.isSubStoreManaged ?? false,
            subStorePath: existing?.subStorePath
        )
        try saveMetadata(metadata)
        if makeCurrent {
            try setCurrentProfile(id: id)
        }
        return try summary(for: id, url: url, metadata: metadata[id], currentID: makeCurrent ? id : currentProfileID())
    }

    public func importLocalProfile(from url: URL, name: String? = nil) async throws -> Profile {
        let rawContent = try String(contentsOf: url, encoding: .utf8)
        let yaml = try await contentNormalizer.normalize(rawContent)
        return Profile(
            name: name ?? url.deletingPathExtension().lastPathComponent,
            source: .file(url),
            rawYAML: yaml,
            updatedAt: Date()
        )
    }

    public func fetchRemoteProfile(from url: URL, name: String? = nil) async throws -> Profile {
        let document = try await fetchRemoteProfileDocument(from: url, name: name, proxyPort: nil)
        return Profile(
            name: document.name,
            source: .remote(url),
            rawYAML: document.yaml,
            updatedAt: Date()
        )
    }

    @discardableResult
    public func saveRemoteProfile(
        from url: URL,
        name: String? = nil,
        autoUpdate: Bool = true,
        useProxy: Bool = false,
        proxyPort: Int? = nil,
        preferredID: String? = nil,
        makeCurrent: Bool = false
    ) async throws -> ProfileSummary {
        if useProxy, proxyPort == nil || proxyPort == 0 {
            throw KumoError.invalidArguments("Start Kumo before updating this profile through the local proxy.")
        }

        let document = try await fetchRemoteProfileDocument(
            from: url,
            name: name,
            proxyPort: useProxy ? proxyPort : nil
        )
        let profile = Profile(
            name: document.name,
            source: .remote(url),
            rawYAML: document.yaml,
            updatedAt: Date()
        )
        let id = preferredID ?? stableProfileID(for: profile)
        try validateProfileID(id)
        let profileURL = profileURL(for: id)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try writeProfileYAML(document.yaml, to: profileURL)

        var metadata = try loadMetadata()
        metadata[id] = ProfileMetadata(
            id: id,
            name: document.name,
            kind: .remote,
            remoteURL: url,
            homeURL: document.homeURL,
            updatedAt: Date(),
            autoUpdate: autoUpdate,
            useProxy: useProxy,
            updateIntervalSeconds: document.updateIntervalSeconds,
            subscriptionUserInfo: document.subscriptionUserInfo,
            isSubStoreManaged: false,
            subStorePath: nil
        )
        try saveMetadata(metadata)

        if makeCurrent {
            try setCurrentProfile(id: id)
        }

        return try summary(for: id, url: profileURL, metadata: metadata[id], currentID: makeCurrent ? id : currentProfileID())
    }

    @discardableResult
    public func saveSubStoreProfile(
        name: String,
        subStorePath: String,
        downloadURL: URL,
        autoUpdate: Bool = true,
        useProxy: Bool = false,
        preferredID: String? = nil,
        makeCurrent: Bool = false
    ) async throws -> ProfileSummary {
        let document = try await fetchRemoteProfileDocument(from: downloadURL, name: name, proxyPort: nil)
        let profile = Profile(
            name: document.name,
            source: .remote(downloadURL),
            rawYAML: document.yaml,
            updatedAt: Date()
        )
        let id = preferredID ?? stableProfileID(for: profile)
        try validateProfileID(id)
        let profileURL = profileURL(for: id)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try writeProfileYAML(document.yaml, to: profileURL)

        var metadata = try loadMetadata()
        metadata[id] = ProfileMetadata(
            id: id,
            name: document.name,
            kind: .remote,
            remoteURL: downloadURL,
            homeURL: document.homeURL,
            updatedAt: Date(),
            autoUpdate: autoUpdate,
            useProxy: useProxy,
            updateIntervalSeconds: document.updateIntervalSeconds,
            subscriptionUserInfo: document.subscriptionUserInfo,
            isSubStoreManaged: true,
            subStorePath: subStorePath
        )
        try saveMetadata(metadata)

        if makeCurrent {
            try setCurrentProfile(id: id)
        }

        return try summary(for: id, url: profileURL, metadata: metadata[id], currentID: makeCurrent ? id : currentProfileID())
    }

    @discardableResult
    public func refreshRemoteProfile(id: String, proxyPort: Int? = nil) async throws -> ProfileSummary {
        try validateProfileID(id)
        let metadata = try loadMetadata()
        guard let item = metadata[id], item.kind == .remote, let remoteURL = item.remoteURL else {
            throw KumoError.invalidArguments("This profile does not have a remote subscription URL.")
        }

        return try await saveRemoteProfile(
            from: remoteURL,
            name: item.name,
            autoUpdate: item.autoUpdate,
            useProxy: item.useProxy,
            proxyPort: proxyPort,
            preferredID: id,
            makeCurrent: false
        )
    }

    @discardableResult
    public func refreshDueRemoteProfiles(now: Date = Date(), proxyPort: Int? = nil) async throws -> [ProfileSummary] {
        var refreshed: [ProfileSummary] = []
        for id in try dueRemoteProfileIDs(now: now) {
            refreshed.append(try await refreshRemoteProfile(id: id, proxyPort: proxyPort))
        }

        return refreshed
    }

    func dueRemoteProfileIDs(now: Date = Date()) throws -> [String] {
        try loadMetadata().values.compactMap { item -> String? in
            guard item.kind == .remote,
                  item.autoUpdate,
                  let interval = item.updateIntervalSeconds,
                  interval > 0 else {
                return nil
            }
            let updatedAt = item.updatedAt ?? .distantPast
            return now.timeIntervalSince(updatedAt) >= TimeInterval(interval) ? item.id : nil
        }
        .sorted()
    }

    public func profileContent(id: String) throws -> String {
        try loadProfile(id: id).rawYAML
    }

    func snapshot(profileID: String) throws -> ProfileRepositorySnapshot {
        try validateProfileID(profileID)
        return ProfileRepositorySnapshot(
            profileID: profileID,
            profileData: try optionalData(at: profileURL(for: profileID)),
            metadataData: try optionalData(at: metadataFile)
        )
    }

    func restore(_ snapshot: ProfileRepositorySnapshot) throws {
        try validateProfileID(snapshot.profileID)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try restore(snapshot.profileData, at: profileURL(for: snapshot.profileID), permissions: 0o600)
        var metadata = try loadMetadata()
        let previousMetadata = try snapshot.metadataData.map(decodeMetadata)?[snapshot.profileID]
        metadata[snapshot.profileID] = previousMetadata
        try saveMetadata(metadata)
    }

    func fallbackProfileID(excluding profileID: String) throws -> String {
        try validateProfileID(profileID)
        return try nextProfileID(afterDeleting: profileID)
    }

    public func normalizedProfile(id: String) async throws -> Profile {
        let (profile, wasChanged) = try await normalizedProfileForValidation(id: id)
        guard wasChanged else {
            return profile
        }

        try writeProfileYAML(profile.rawYAML, to: profileURL(for: id))
        return profile
    }

    func normalizedProfileForValidation(id: String) async throws -> (Profile, Bool) {
        let profile = try loadExistingProfile(id: id)
        let normalizedYAML = try await contentNormalizer.normalize(profile.rawYAML)
        guard normalizedYAML != profile.rawYAML else {
            return (profile, false)
        }

        return (
            Profile(
                id: profile.id,
                name: profile.name,
                source: profile.source,
                rawYAML: normalizedYAML,
                updatedAt: profile.updatedAt
            ),
            true
        )
    }

    @discardableResult
    func updateProfile(
        id: String,
        name: String,
        remoteURL: URL?,
        autoUpdate: Bool,
        useProxy: Bool,
        rawYAML: String
    ) throws -> ProfileSummary {
        try validateProfileID(id)
        try ProfileContentNormalizer.validateMihomoYAML(rawYAML)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let url = profileURL(for: id)
        try writeProfileYAML(rawYAML, to: url)

        var metadata = try loadMetadata()
        let existing = metadata[id]
        let nextKind: ProfileKind = remoteURL == nil ? (existing?.kind == .remote ? .local : existing?.kind ?? .local) : .remote
        metadata[id] = ProfileMetadata(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? displayName(for: url) : name,
            kind: nextKind,
            remoteURL: remoteURL,
            homeURL: existing?.homeURL,
            updatedAt: Date(),
            autoUpdate: autoUpdate,
            useProxy: useProxy,
            updateIntervalSeconds: existing?.updateIntervalSeconds,
            subscriptionUserInfo: existing?.subscriptionUserInfo,
            isSubStoreManaged: existing?.isSubStoreManaged ?? false,
            subStorePath: existing?.subStorePath
        )
        try saveMetadata(metadata)
        return try summary(for: id, url: url, metadata: metadata[id], currentID: currentProfileID())
    }

    @discardableResult
    func deleteProfile(id: String) throws -> Bool {
        try validateProfileID(id)
        guard id != "default" else {
            throw KumoError.invalidArguments("The default profile cannot be deleted.")
        }

        let wasCurrent = try currentProfileID() == id
        let url = profileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KumoError.invalidArguments("The selected profile no longer exists.")
        }
        try FileManager.default.removeItem(at: url)
        var metadata = try loadMetadata()
        metadata[id] = nil
        try saveMetadata(metadata)

        if wasCurrent {
            try setCurrentProfile(id: nextProfileID(afterDeleting: id))
        }

        return wasCurrent
    }

    private func defaultProfileYAML() -> String {
        """
        proxies: []
        proxy-groups:
          - name: Proxy
            type: select
            proxies:
              - DIRECT
        rules:
          - MATCH,DIRECT
        """
    }

    private func profileFileURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            ["yaml", "yml"].contains($0.pathExtension.lowercased())
                && isSafeRegularFile(at: $0)
        }
    }

    private func profileURL(for id: String) -> URL {
        profilesDirectory.appendingPathComponent("\(id).yaml")
    }

    private func currentProfileID() throws -> String {
        guard FileManager.default.fileExists(atPath: currentProfileFile.path) else {
            return "default"
        }
        let value = try readUTF8(at: currentProfileFile)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = value.isEmpty ? "default" : value
        try validateProfileID(id)
        return id
    }

    private func displayName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if stem == "default" {
            return "Default"
        }
        return stem.replacingOccurrences(of: "-", with: " ")
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func summary(
        for id: String,
        url: URL,
        metadata: ProfileMetadata?,
        currentID: String
    ) throws -> ProfileSummary {
        let kind = metadata?.kind ?? (id == "default" ? .inline : .local)
        return ProfileSummary(
            id: id,
            name: metadata?.name ?? displayName(for: url),
            sourceDescription: sourceDescription(kind: kind, remoteURL: metadata?.remoteURL),
            updatedAt: metadata?.updatedAt ?? modificationDate(for: url),
            isCurrent: id == currentID,
            kind: kind,
            remoteURL: metadata?.remoteURL,
            homeURL: metadata?.homeURL,
            autoUpdate: metadata?.autoUpdate ?? true,
            useProxy: metadata?.useProxy ?? false,
            updateIntervalSeconds: metadata?.updateIntervalSeconds,
            subscriptionUserInfo: metadata?.subscriptionUserInfo,
            isSubStoreManaged: metadata?.isSubStoreManaged ?? false,
            subStorePath: metadata?.subStorePath
        )
    }

    private func profileSort(_ left: ProfileSummary, _ right: ProfileSummary) -> Bool {
        if left.id == "default" { return true }
        if right.id == "default" { return false }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    private func stableProfileID(for profile: Profile) -> String {
        let base = profile.name.isEmpty ? "profile" : profile.name
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = base
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? profile.id.uuidString : "\(slug)-\(profile.id.uuidString.prefix(8))"
    }

    private func sourceDescription(for source: ProfileSource) -> String {
        switch source {
        case .remote(let url):
            url.host ?? "Remote"
        case .file:
            "Local YAML"
        case .inline:
            "Inline"
        }
    }

    private func sourceDescription(kind: ProfileKind, remoteURL: URL?) -> String {
        switch kind {
        case .remote:
            remoteURL?.host ?? "Remote"
        case .local:
            "Local YAML"
        case .inline:
            "Generated direct profile"
        }
    }

    private func kind(for source: ProfileSource) -> ProfileKind {
        switch source {
        case .remote:
            .remote
        case .file:
            .local
        case .inline:
            .inline
        }
    }

    private func remoteURL(for source: ProfileSource) -> URL? {
        if case .remote(let url) = source {
            return url
        }
        return nil
    }

    private func loadMetadata() throws -> [String: ProfileMetadata] {
        guard FileManager.default.fileExists(atPath: metadataFile.path) else {
            return [:]
        }
        return try decodeMetadata(readRegularFileData(at: metadataFile))
    }

    private func decodeMetadata(_ data: Data) throws -> [String: ProfileMetadata] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: ProfileMetadata].self, from: data)
    }

    private func saveMetadata(_ metadata: [String: ProfileMetadata]) throws {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try writeOwnedData(data, to: metadataFile, permissions: 0o600)
    }

    private func fetchRemoteProfileDocument(from url: URL, name: String?, proxyPort: Int?) async throws -> RemoteProfileDocument {
        let session = URLSession(configuration: urlSessionConfiguration(proxyPort: proxyPort))
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Clash.Meta", forHTTPHeaderField: "User-Agent")
        request.setValue("application/yaml, text/yaml, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw KumoError.controllerResponse(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
        }

        let headers = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        guard let rawContent = String(data: data, encoding: .utf8) else {
            throw KumoError.invalidArguments("The profile response is not valid UTF-8 text.")
        }
        let yaml = try await contentNormalizer.normalize(rawContent)
        return RemoteProfileDocument(
            name: name ?? filename(from: headers) ?? url.host ?? "Remote Profile",
            yaml: yaml,
            homeURL: headerValue(suffix: "profile-web-page-url", in: headers).flatMap(URL.init(string:)),
            updateIntervalSeconds: headerValue(suffix: "profile-update-interval", in: headers)
                .flatMap(Int.init)
                .map { $0 * 60 },
            subscriptionUserInfo: headerValue(suffix: "subscription-userinfo", in: headers)
                .flatMap(parseSubscriptionUserInfo)
        )
    }

    private func urlSessionConfiguration(proxyPort: Int?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        guard let proxyPort, proxyPort > 0 else {
            return configuration
        }

        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: proxyPort
        ]
        return configuration
    }

    private func headerValue(suffix: String, in headers: [AnyHashable: Any]) -> String? {
        headers.first { key, _ in
            String(describing: key).lowercased().hasSuffix(suffix)
        }
        .map { String(describing: $0.value) }
    }

    private func filename(from headers: [AnyHashable: Any]) -> String? {
        guard let value = headerValue(suffix: "content-disposition", in: headers) else {
            return nil
        }
        if let range = value.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            return String(value[range.upperBound...]).removingPercentEncoding
        }
        guard let range = value.range(of: "filename=", options: .caseInsensitive) else {
            return nil
        }
        return String(value[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private func parseSubscriptionUserInfo(_ value: String) -> SubscriptionUserInfo? {
        let fields = value.split(separator: ";").reduce(into: [String: Int]()) { result, part in
            let pieces = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pieces.count == 2, let intValue = Int(pieces[1]) else {
                return
            }
            result[pieces[0].lowercased()] = intValue
        }
        guard !fields.isEmpty else {
            return nil
        }
        return SubscriptionUserInfo(
            upload: fields["upload"] ?? 0,
            download: fields["download"] ?? 0,
            total: fields["total"] ?? 0,
            expire: fields["expire"]
        )
    }

    private func nextProfileID(afterDeleting deletedID: String) throws -> String {
        try validateProfileID(deletedID)
        let remaining = try profileFileURLs()
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != deletedID }
            .sorted()
        return remaining.first ?? "default"
    }

    private func loadExistingProfile(id: String) throws -> Profile {
        try validateProfileID(id)
        if id == "default", !FileManager.default.fileExists(atPath: profileURL(for: id).path) {
            return Profile(
                name: "Empty Profile",
                source: .inline,
                rawYAML: defaultProfileYAML(),
                updatedAt: Date()
            )
        }
        guard FileManager.default.fileExists(atPath: profileURL(for: id).path) else {
            throw KumoError.invalidArguments("The selected profile no longer exists.")
        }
        return try loadProfile(id: id)
    }

    private func writeProfileYAML(_ yaml: String, to url: URL) throws {
        guard let data = yaml.data(using: .utf8) else {
            throw KumoError.invalidArguments("The profile could not be encoded as UTF-8.")
        }
        try writeOwnedData(data, to: url, permissions: 0o600)
    }

    private func optionalData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readRegularFileData(at: url)
    }

    private func validateProfileID(_ id: String) throws {
        guard !id.isEmpty,
              id != ".",
              id != "..",
              id.utf8.count <= 255,
              !id.contains("/"),
              !id.contains("\\"),
              id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw KumoError.invalidArguments("The profile identifier is invalid.")
        }
    }

    private func isSafeRegularFile(at url: URL) -> Bool {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1 else {
            return false
        }
        return true
    }

    private func readUTF8(at url: URL) throws -> String {
        let data = try readRegularFileData(at: url)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KumoError.invalidArguments("The profile file is not valid UTF-8 text.")
        }
        return value
    }

    private func readRegularFileData(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not open a profile file safely.")
        }
        defer { close(descriptor) }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1,
              fileStatus.st_size >= 0,
              fileStatus.st_size <= 32 * 1024 * 1024 else {
            throw KumoError.serviceUnavailable("Kumo refused an unsafe profile file.")
        }
        return try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).readToEnd() ?? Data()
    }

    private func restore(_ data: Data?, at url: URL, permissions: Int) throws {
        guard let data else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try writeOwnedData(data, to: url, permissions: permissions)
    }

    private func writeOwnedData(_ data: Data, to url: URL, permissions: Int) throws {
        try data.write(to: url, options: .atomic)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Kumo could not open a profile file safely.")
        }
        defer { close(descriptor) }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1,
              fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw KumoError.serviceUnavailable("Kumo refused an unsafe profile file.")
        }
    }
}

private struct ProfileMetadata: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: ProfileKind
    var remoteURL: URL?
    var homeURL: URL?
    var updatedAt: Date?
    var autoUpdate: Bool
    var useProxy: Bool
    var updateIntervalSeconds: Int?
    var subscriptionUserInfo: SubscriptionUserInfo?
    var isSubStoreManaged: Bool?
    var subStorePath: String?
}

private struct RemoteProfileDocument: Sendable {
    var name: String
    var yaml: String
    var homeURL: URL?
    var updateIntervalSeconds: Int?
    var subscriptionUserInfo: SubscriptionUserInfo?
}
