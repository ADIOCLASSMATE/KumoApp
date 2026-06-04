import Darwin
import Foundation

public struct CoreInstallResult: Codable, Equatable, Sendable {
    public var version: String
    public var path: String

    public init(version: String, path: String) {
        self.version = version
        self.path = path
    }
}

internal struct CoreReleaseAsset: Equatable, Sendable {
    var name: String
    var downloadURL: URL
}

internal struct CoreInstallerHTTPError: LocalizedError {
    var statusCode: Int
    var message: String

    var errorDescription: String? { message }
}

public struct CoreInstaller: Sendable {
    private static let githubBaseURL = URL(string: "https://github.com")!
    private let paths: KumoPaths
    private let session: URLSession

    public init(paths: KumoPaths = KumoPaths()) {
        self.paths = paths
        self.session = .shared
    }

    internal init(paths: KumoPaths = KumoPaths(), session: URLSession) {
        self.paths = paths
        self.session = session
    }

    public func installLatestMihomo() async throws -> CoreInstallResult {
        let version = try await latestStableReleaseTag()
        let assets = try await releaseAssets(version: version)
        let archiveURL = try await downloadFirstAvailableAsset(assets, version: version)

        try paths.prepare()
        let installedURL = try installGzipArchive(archiveURL)
        return CoreInstallResult(version: version, path: installedURL.path)
    }

    private func latestStableReleaseTag() async throws -> String {
        let data = try await data(
            from: Self.githubBaseURL
                .appendingPathComponent("MetaCubeX")
                .appendingPathComponent("mihomo")
                .appendingPathComponent("releases.atom"),
            context: "GitHub release feed"
        )
        return try Self.latestStableReleaseTag(fromAtomFeed: data)
    }

    private var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    private func releaseAssets(version: String) async throws -> [CoreReleaseAsset] {
        let expandedAssetsURL = Self.githubBaseURL
            .appendingPathComponent("MetaCubeX")
            .appendingPathComponent("mihomo")
            .appendingPathComponent("releases")
            .appendingPathComponent("expanded_assets")
            .appendingPathComponent(version)
        let data = try await data(from: expandedAssetsURL, context: "GitHub expanded assets page")
        let assets = try Self.releaseAssets(
            fromExpandedAssetsHTML: data,
            version: version,
            architecture: currentArchitecture
        )
        guard !assets.isEmpty else {
            throw KumoError.coreInstallFailed(
                "No macOS \(currentArchitecture) mihomo assets were listed for \(version)."
            )
        }
        return assets
    }

    private func downloadFirstAvailableAsset(
        _ assets: [CoreReleaseAsset],
        version: String
    ) async throws -> URL {
        var failures: [String] = []
        for asset in assets {
            do {
                return try await download(from: asset.downloadURL)
            } catch {
                guard Self.isMissingAssetError(error) else {
                    throw error
                }
                failures.append(asset.name)
            }
        }

        throw KumoError.coreInstallFailed(
            "All listed macOS \(currentArchitecture) mihomo assets were missing for \(version): \(failures.joined(separator: ", "))."
        )
    }

    private func data(from url: URL, context: String) async throws -> Data {
        let request = Self.githubRequest(url: url)
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTPResponse(response, data: data, context: context)
        return data
    }

    private func download(from url: URL) async throws -> URL {
        let request = Self.githubRequest(url: url)
        let (temporaryURL, response) = try await session.download(for: request)
        let responseData: Data
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let handle = try? FileHandle(forReadingFrom: temporaryURL)
            responseData = (try? handle?.read(upToCount: 512)) ?? Data()
            try? handle?.close()
        } else {
            responseData = Data()
        }
        try Self.validateHTTPResponse(response, data: responseData, context: "Asset download")

        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("kumo-\(UUID().uuidString)")
            .appendingPathExtension("gz")
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    internal static func latestStableReleaseTag(fromAtomFeed data: Data) throws -> String {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw KumoError.coreInstallFailed("GitHub releases feed is not valid UTF-8.")
        }

        let pattern = #"<title>(v[0-9]+(?:\.[0-9]+)+)</title>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, range: range),
              let titleRange = Range(match.range(at: 1), in: xml) else {
            throw KumoError.coreInstallFailed("No stable Mihomo release tag found in GitHub releases feed.")
        }
        return String(xml[titleRange])
    }

    internal static func releaseAssets(
        fromExpandedAssetsHTML data: Data,
        version: String,
        architecture: String
    ) throws -> [CoreReleaseAsset] {
        guard let html = String(data: data, encoding: .utf8) else {
            throw KumoError.coreInstallFailed("GitHub expanded assets page is not valid UTF-8.")
        }

        let escapedVersion = NSRegularExpression.escapedPattern(for: version)
        let pattern = #"href="([^"]*/MetaCubeX/mihomo/releases/download/\#(escapedVersion)/([^"]+\.gz))""#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var seenNames = Set<String>()
        var assets: [CoreReleaseAsset] = []

        for match in regex.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            let name = String(html[nameRange])
            let lowercased = name.lowercased()
            guard lowercased.hasPrefix("mihomo-darwin-\(architecture.lowercased())"),
                  lowercased.hasSuffix("-\(version.lowercased()).gz"),
                  !lowercased.contains("metacubexd"),
                  seenNames.insert(name).inserted,
                  let url = URL(string: String(html[hrefRange]), relativeTo: githubBaseURL)?.absoluteURL else {
                continue
            }
            assets.append(CoreReleaseAsset(name: name, downloadURL: url))
        }

        return assets.sorted {
            let lhsScore = assetScore($0.name, version: version, architecture: architecture)
            let rhsScore = assetScore($1.name, version: version, architecture: architecture)
            return lhsScore == rhsScore ? $0.name < $1.name : lhsScore > rhsScore
        }
    }

    internal static func isMissingAssetError(_ error: Error) -> Bool {
        (error as? CoreInstallerHTTPError)?.statusCode == 404
    }

    private static func assetScore(_ name: String, version: String, architecture: String) -> Int {
        let lowercased = name.lowercased()
        let exactName = "mihomo-darwin-\(architecture.lowercased())-\(version.lowercased()).gz"
        if lowercased == exactName {
            return 1_000
        }

        var score = 500
        if !lowercased.contains("-go") {
            score += 100
        }
        if lowercased.contains("compatible") {
            score -= 100
        }
        if let versionPattern = try? NSRegularExpression(pattern: #"-v([0-9]+)(?:-|\.gz)"#),
           let match = versionPattern.firstMatch(
               in: lowercased,
               range: NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
           ),
           let valueRange = Range(match.range(at: 1), in: lowercased),
           let value = Int(lowercased[valueRange]) {
            score += min(value, 20)
        }
        return score
    }

    private static func githubRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Kumo", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, context: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(httpResponse.statusCode) else { return }

        let body = String(data: data.prefix(512), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limitReset = httpResponse.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0).formatted(.dateTime.hour().minute().second()) }
        let resetMessage = limitReset.map { " Rate limit resets at \($0)." } ?? ""
        let bodyMessage = body.map { " \($0)" } ?? ""
        throw CoreInstallerHTTPError(
            statusCode: httpResponse.statusCode,
            message: "\(context) returned HTTP \(httpResponse.statusCode).\(resetMessage)\(bodyMessage)"
        )
    }

    private func installGzipArchive(_ archiveURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let installingURL = paths.managedCoreDirectory.appendingPathComponent("mihomo.installing")
        let destinationURL = paths.managedCoreExecutable

        try? fileManager.removeItem(at: installingURL)
        fileManager.createFile(atPath: installingURL.path, contents: nil)

        let output = try FileHandle(forWritingTo: installingURL)
        defer {
            try? output.close()
            try? fileManager.removeItem(at: archiveURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", archiveURL.path]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = (process.standardError as? Pipe)
                .flatMap { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) }
                ?? "gunzip failed with status \(process.terminationStatus)."
            throw KumoError.coreInstallFailed(message)
        }

        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: installingURL, to: destinationURL)
        chmod(destinationURL.path, S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
        return destinationURL
    }
}
