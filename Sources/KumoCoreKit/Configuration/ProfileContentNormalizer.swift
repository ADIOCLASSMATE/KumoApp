import Darwin
import Foundation
import Yams

public protocol ProfileSubscriptionConverting: Sendable {
    func convertSubscription(_ content: String) async throws -> String
}

public struct ProfileContentNormalizer: Sendable {
    private static let maximumDocumentBytes = 16 * 1024 * 1024
    private static let meaningfulKeys: Set<String> = [
        "proxies",
        "proxy-providers",
        "proxy-groups",
        "rules",
        "rule-providers"
    ]

    private let converter: any ProfileSubscriptionConverting

    public init(converter: any ProfileSubscriptionConverting) {
        self.converter = converter
    }

    public func normalize(_ content: String) async throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw invalidContent("The profile is empty.")
        }
        guard content.utf8.count <= Self.maximumDocumentBytes else {
            throw invalidContent("The profile is too large to import safely.")
        }
        guard !looksLikeHTML(trimmed) else {
            throw invalidContent("The profile URL returned a web page instead of a subscription.")
        }

        if let mapping = try yamlMapping(from: content) {
            try validateMeaningfulMapping(mapping)
            if needsCompletion(mapping) {
                return try completedDocument(from: mapping, requireUsableProxies: true)
            }
            return content
        }

        guard isNodeSubscription(trimmed) else {
            throw invalidContent("The profile is neither Mihomo YAML nor a supported node subscription.")
        }

        let converted: String
        do {
            converted = try await converter.convertSubscription(content)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw invalidContent("The bundled subscription parser could not convert this profile.")
        }

        guard let mapping = try yamlMapping(from: converted) else {
            throw invalidContent("The bundled subscription parser returned an invalid profile.")
        }
        return try completedDocument(from: mapping, requireUsableProxies: true)
    }

    public static func validateMihomoYAML(_ content: String) throws {
        let converter = RejectingSubscriptionConverter()
        let normalizer = ProfileContentNormalizer(converter: converter)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.utf8.count <= Self.maximumDocumentBytes,
              !trimmed.isEmpty,
              !normalizer.looksLikeHTML(trimmed),
              let mapping = try normalizer.yamlMapping(from: content) else {
            throw KumoError.invalidArguments("The profile must be a Mihomo YAML mapping.")
        }
        try normalizer.validateMeaningfulMapping(mapping)
    }

    private func yamlMapping(from content: String) throws -> [String: Any]? {
        guard let loaded = try Yams.load(yaml: content) else {
            return nil
        }
        return loaded as? [String: Any]
    }

    private func validateMeaningfulMapping(_ mapping: [String: Any]) throws {
        guard !Self.meaningfulKeys.isDisjoint(with: mapping.keys) else {
            throw invalidContent("The YAML does not contain proxies, providers, groups, or rules.")
        }
    }

    private func needsCompletion(_ mapping: [String: Any]) -> Bool {
        guard let proxies = mapping["proxies"] as? [Any], !proxies.isEmpty else {
            return false
        }
        let hasGroups = !(mapping["proxy-groups"] as? [Any] ?? []).isEmpty
        let hasRules = !(mapping["rules"] as? [Any] ?? []).isEmpty
        return !hasGroups || !hasRules
    }

    private func completedDocument(
        from source: [String: Any],
        requireUsableProxies: Bool
    ) throws -> String {
        var mapping = source
        let proxyEntries = mapping["proxies"] as? [Any] ?? []
        let proxyNames = try validatedProxyNames(proxyEntries)
        if requireUsableProxies, proxyNames.isEmpty {
            throw invalidContent("The subscription did not contain any usable proxy nodes.")
        }

        if (mapping["proxy-groups"] as? [Any] ?? []).isEmpty {
            let groupName = uniqueGroupName(avoiding: Set(proxyNames))
            mapping["proxy-groups"] = [[
                "name": groupName,
                "type": "select",
                "proxies": proxyNames + ["DIRECT"]
            ]]
            if (mapping["rules"] as? [Any] ?? []).isEmpty {
                mapping["rules"] = ["MATCH,\(groupName)"]
            }
        } else if (mapping["rules"] as? [Any] ?? []).isEmpty,
                  let groupName = firstGroupName(in: mapping) {
            mapping["rules"] = ["MATCH,\(groupName)"]
        }

        try validateMeaningfulMapping(mapping)
        return try Yams.dump(object: mapping)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
    }

    private func validatedProxyNames(_ entries: [Any]) throws -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        for entry in entries {
            guard let proxy = entry as? [String: Any],
                  let rawName = proxy["name"] as? String,
                  let rawType = proxy["type"] as? String,
                  let rawServer = proxy["server"],
                  proxy["port"] != nil else {
                continue
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            let server = String(describing: rawServer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !type.isEmpty, !server.isEmpty else {
                continue
            }
            guard seen.insert(name).inserted else {
                throw invalidContent("The converted subscription contains duplicate proxy names.")
            }
            names.append(name)
        }
        return names
    }

    private func uniqueGroupName(avoiding names: Set<String>) -> String {
        let base = "Kumo Subscription"
        guard names.contains(base) else { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func firstGroupName(in mapping: [String: Any]) -> String? {
        guard let groups = mapping["proxy-groups"] as? [Any] else { return nil }
        return groups.compactMap { entry in
            (entry as? [String: Any])?["name"] as? String
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
    }

    private func isNodeSubscription(_ content: String) -> Bool {
        if isNodeURIList(content) {
            return true
        }
        guard let decoded = decodedBase64(content) else {
            return false
        }
        return isNodeURIList(decoded)
    }

    private func isNodeURIList(_ content: String) -> Bool {
        let lines = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return false }

        return lines.allSatisfy { line in
            guard let separator = line.range(of: "://") else { return false }
            let scheme = line[..<separator.lowerBound]
            guard let first = scheme.unicodeScalars.first,
                  CharacterSet.letters.contains(first) else {
                return false
            }
            return scheme.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+.-")).contains($0)
            }
        }
    }

    private func decodedBase64(_ content: String) -> String? {
        var normalized = content
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty else { return nil }
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: normalized),
              data.count <= Self.maximumDocumentBytes else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func looksLikeHTML(_ content: String) -> Bool {
        let prefix = content.prefix(256).lowercased()
        return prefix.contains("<!doctype html") || prefix.contains("<html")
    }

    private func invalidContent(_ message: String) -> KumoError {
        KumoError.invalidArguments(message)
    }
}

private struct RejectingSubscriptionConverter: ProfileSubscriptionConverting {
    func convertSubscription(_ content: String) async throws -> String {
        _ = content
        throw KumoError.invalidArguments("Subscription conversion is not available in this context.")
    }
}

public actor IsolatedSubStoreSubscriptionConverter: ProfileSubscriptionConverting {
    private let temporaryRoot: URL

    public init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
    }

    public func convertSubscription(_ content: String) async throws -> String {
        try Task.checkCancellation()
        let resources = try bundledResources()

        for _ in 0..<3 {
            let port = try await SubStorePortAllocator.availablePort(
                startingAt: Int.random(in: 49_152...64_000),
                allowLAN: false
            )
            let workingDirectory = temporaryRoot
                .appendingPathComponent("KumoProfileConversion", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let dataDirectory = workingDirectory.appendingPathComponent("data", isDirectory: true)
            try prepareTemporaryDirectory(workingDirectory, dataDirectory: dataDirectory)

            let process = Process()
            process.executableURL = resources.node
            process.arguments = [resources.backend.path]
            process.environment = [
                "HOME": workingDirectory.path,
                "TMPDIR": workingDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "SUB_STORE_BACKEND_API_PORT": "\(port)",
                "SUB_STORE_BACKEND_API_HOST": "127.0.0.1",
                "SUB_STORE_DATA_BASE_PATH": dataDirectory.path,
                "SUB_STORE_BACKEND_CUSTOM_NAME": "Kumo Profile Converter",
                "SUB_STORE_BACKEND_SYNC_CRON": "",
                "SUB_STORE_BACKEND_DOWNLOAD_CRON": "",
                "SUB_STORE_BACKEND_UPLOAD_CRON": ""
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: workingDirectory)
                throw KumoError.commandFailed("The bundled subscription parser could not start.")
            }
            defer {
                stop(process)
                try? FileManager.default.removeItem(at: workingDirectory)
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 1
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            let client = SubStoreClient(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                session: session,
                timeout: 20
            )

            do {
                try await waitUntilReady(process: process, client: client)
                try Task.checkCancellation()
                return try await client.parseProxies(data: content, platform: "ClashMeta").par_res
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !process.isRunning {
                    continue
                }
                throw KumoError.invalidArguments("The bundled subscription parser could not convert this profile.")
            }
        }

        throw KumoError.commandFailed("The bundled subscription parser could not reserve a local port.")
    }

    private func bundledResources() throws -> (node: URL, backend: URL) {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw KumoError.commandFailed("Bundled subscription parser resources are missing.")
        }
        let root = resourceURL.appendingPathComponent("SubStore", isDirectory: true)
        let node = root.appendingPathComponent("node/bin/node")
        let backend = root.appendingPathComponent("backend/sub-store.bundle.js")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: backend.path) else {
            throw KumoError.commandFailed("Bundled subscription parser resources are incomplete.")
        }
        return (node, backend)
    }

    private func prepareTemporaryDirectory(_ directory: URL, dataDirectory: URL) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
    }

    private func waitUntilReady(process: Process, client: SubStoreClient) async throws {
        var lastError: Error?
        for _ in 0..<60 {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw KumoError.commandFailed("The bundled subscription parser exited during startup.")
            }
            do {
                _ = try await client.settings()
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        _ = lastError
        throw KumoError.commandFailed("The bundled subscription parser timed out during startup.")
    }

    private func stop(_ process: Process) {
        BoundedChildProcessTerminator.stop(process)
    }
}

/// Foundation's `Process.waitUntilExit()` can remain blocked after a short-lived
/// Node child has already disappeared. Subscription conversion runs on an
/// application task, so an unbounded reap would leave profile import spinning
/// forever. `Process` owns the dispatch source that reaps its child; this helper
/// only bounds the signalling phase and deliberately never waits indefinitely.
enum BoundedChildProcessTerminator {
    static func stop(
        _ process: Process,
        gracefulTimeout: TimeInterval = 1,
        forcedTimeout: TimeInterval = 0.25
    ) {
        guard process.isRunning else { return }

        process.terminate()
        waitWhileRunning(process, timeout: gracefulTimeout)
        guard process.isRunning else { return }

        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        waitWhileRunning(process, timeout: forcedTimeout)
    }

    private static func waitWhileRunning(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
    }
}
