import CryptoKit
import Darwin
import Foundation
import zlib

private final class BoundedHTTPDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let context: String
    private let temporaryURL: URL
    private var descriptor: Int32
    private var bytesReceived: Int64 = 0
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var terminalError: Error?

    private init(maximumBytes: Int64, context: String, temporaryURL: URL, descriptor: Int32) {
        self.maximumBytes = maximumBytes
        self.context = context
        self.temporaryURL = temporaryURL
        self.descriptor = descriptor
    }

    static func run(
        configuration: URLSessionConfiguration,
        request: URLRequest,
        maximumBytes: Int64,
        context: String
    ) async throws -> (URL, URLResponse) {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-http-\(UUID().uuidString)")
            .appendingPathExtension("download")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw posixDownloadError("create bounded \(context) download")
        }
        let download = BoundedHTTPDownload(
            maximumBytes: maximumBytes,
            context: context,
            temporaryURL: temporaryURL,
            descriptor: descriptor
        )
        return try await download.start(configuration: configuration, request: request)
    }

    private func start(
        configuration: URLSessionConfiguration,
        request: URLRequest
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: queue
            )
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        if response.expectedContentLength > maximumBytes {
            terminalError = limitError()
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard terminalError == nil else { return }
        guard bytesReceived <= maximumBytes - Int64(data.count) else {
            terminalError = limitError()
            dataTask.cancel()
            return
        }

        do {
            try data.withUnsafeBytes { pointer in
                guard let base = pointer.baseAddress else { return }
                var offset = 0
                while offset < pointer.count {
                    let written = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        pointer.count - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw Self.posixDownloadError("write bounded \(context) download")
                    }
                    offset += written
                }
            }
            bytesReceived += Int64(data.count)
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let continuation else { return }
        self.continuation = nil
        let closeError: Error?
        if descriptor >= 0 {
            closeError = fsync(descriptor) == 0
                ? nil
                : Self.posixDownloadError("synchronize bounded \(context) download")
            close(descriptor)
            descriptor = -1
        } else {
            closeError = nil
        }
        self.session?.finishTasksAndInvalidate()
        self.session = nil

        if let failure = terminalError ?? error ?? closeError {
            try? FileManager.default.removeItem(at: temporaryURL)
            continuation.resume(throwing: failure)
            return
        }
        guard let response else {
            try? FileManager.default.removeItem(at: temporaryURL)
            continuation.resume(throwing: KumoError.coreInstallFailed(
                "\(context) completed without an HTTP response."
            ))
            return
        }
        continuation.resume(returning: (temporaryURL, response))
    }

    private func limitError() -> KumoError {
        .coreInstallFailed("\(context) exceeds Kumo's \(maximumBytes)-byte safety limit.")
    }

    private static func posixDownloadError(_ operation: String) -> NSError {
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
    var sha256: String
}

internal struct CoreInstallerHTTPError: LocalizedError {
    var statusCode: Int
    var message: String

    var errorDescription: String? { message }
}

public struct CoreInstaller: Sendable {
    private static let githubBaseURL = URL(string: "https://github.com")!

    /// When set via the `KUMO_MIHOMO_DOWNLOAD_MIRROR` environment variable,
    /// all GitHub requests are rewritten through this prefix. Use a mirror
    /// like `https://mirror.ghproxy.com/` to bypass network restrictions.
    private static var downloadMirror: String? {
        if let raw = ProcessInfo.processInfo.environment["KUMO_MIHOMO_DOWNLOAD_MIRROR"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func resolvedURL(_ url: URL) -> URL {
        guard let mirror = downloadMirror else { return url }
        return URL(string: mirror + url.absoluteString) ?? url
    }
    private static let maximumMetadataBytes: Int64 = 8 * 1024 * 1024
    private static let maximumArchiveBytes: Int64 = 96 * 1024 * 1024
    private static let maximumExecutableBytes: Int64 = 256 * 1024 * 1024
    private static let maximumMachOLoadCommandBytes: Int64 = 16 * 1024 * 1024
    private let paths: KumoPaths
    private let session: URLSession

    public init(paths: KumoPaths = KumoPaths()) {
        self.paths = paths
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: configuration)
    }

    internal init(paths: KumoPaths = KumoPaths(), session: URLSession) {
        self.paths = paths
        self.session = session
    }

    public func installLatestMihomo(destinationURL: URL? = nil) async throws -> CoreInstallResult {
        let version = try await latestStableReleaseTag()
        let assets = try await releaseAssets(version: version)
        let archiveURL = try await downloadFirstAvailableAsset(assets, version: version)

        if destinationURL == nil {
            try paths.prepare()
        }
        let installedURL = try installGzipArchive(
            archiveURL,
            destinationURL: destinationURL ?? paths.managedCoreExecutable,
            architecture: currentArchitecture
        )
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
        #error("Kumo supports Apple Silicon only.")
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
                return try await download(asset: asset)
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
        let (temporaryURL, response) = try await boundedDownload(
            request,
            maximumBytes: Self.maximumMetadataBytes,
            context: context
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let errorData = Self.errorResponseData(from: temporaryURL)
        try Self.validateHTTPResponse(response, data: errorData, context: context)
        try Self.validateExpectedContentLength(
            response,
            maximumBytes: Self.maximumMetadataBytes,
            context: context
        )
        try Self.validateFileSize(
            at: temporaryURL,
            maximumBytes: Self.maximumMetadataBytes,
            context: context
        )
        return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
    }

    private func download(asset: CoreReleaseAsset) async throws -> URL {
        let request = Self.githubRequest(url: asset.downloadURL)
        let (temporaryURL, response) = try await boundedDownload(
            request,
            maximumBytes: Self.maximumArchiveBytes,
            context: "Mihomo archive"
        )
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        let responseData = Self.errorResponseData(from: temporaryURL)
        try Self.validateHTTPResponse(response, data: responseData, context: "Asset download")
        try Self.validateExpectedContentLength(
            response,
            maximumBytes: Self.maximumArchiveBytes,
            context: "Mihomo archive"
        )
        try Self.validateFileSize(
            at: temporaryURL,
            maximumBytes: Self.maximumArchiveBytes,
            context: "Mihomo archive"
        )
        try Self.verifySHA256(of: temporaryURL, expected: asset.sha256)

        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("kumo-\(UUID().uuidString)")
            .appendingPathExtension("gz")
        try fileManager.moveItem(at: temporaryURL, to: destination)
        shouldRemoveTemporaryFile = false
        return destination
    }

    internal func boundedDownload(
        _ request: URLRequest,
        maximumBytes: Int64,
        context: String
    ) async throws -> (URL, URLResponse) {
        try await BoundedHTTPDownload.run(
            configuration: session.configuration,
            request: request,
            maximumBytes: maximumBytes,
            context: context
        )
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
        guard architecture.lowercased() == "arm64" else {
            throw KumoError.coreInstallFailed("Kumo supports Apple Silicon Mihomo assets only.")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw KumoError.coreInstallFailed("GitHub expanded assets page is not valid UTF-8.")
        }

        let escapedVersion = NSRegularExpression.escapedPattern(for: version)
        let itemRegex = try NSRegularExpression(
            pattern: #"<li\b[^>]*>.*?</li>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let assetRegex = try NSRegularExpression(
            pattern: #"href="([^"]*/MetaCubeX/mihomo/releases/download/\#(escapedVersion)/([^"]+\.gz))""#,
            options: [.caseInsensitive]
        )
        let digestRegex = try NSRegularExpression(
            pattern: #"value="sha256:([0-9a-f]{64})""#,
            options: [.caseInsensitive]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var seenNames = Set<String>()
        var assets: [CoreReleaseAsset] = []

        for itemMatch in itemRegex.matches(in: html, range: range) {
            guard let match = assetRegex.firstMatch(in: html, range: itemMatch.range),
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            let name = String(html[nameRange])
            let lowercased = name.lowercased()
            guard lowercased.hasPrefix("mihomo-darwin-\(architecture.lowercased())"),
                  lowercased.hasSuffix("-\(version.lowercased()).gz"),
                  !lowercased.contains("metacubexd") else {
                continue
            }
            guard let digestMatch = digestRegex.firstMatch(in: html, range: itemMatch.range),
                  let digestRange = Range(digestMatch.range(at: 1), in: html) else {
                throw KumoError.coreInstallFailed(
                    "GitHub did not publish a valid SHA-256 digest for \(name)."
                )
            }
            guard seenNames.insert(name).inserted,
                  let url = URL(string: String(html[hrefRange]), relativeTo: githubBaseURL)?.absoluteURL else {
                continue
            }
            assets.append(CoreReleaseAsset(
                name: name,
                downloadURL: url,
                sha256: String(html[digestRange]).lowercased()
            ))
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
        var request = URLRequest(url: resolvedURL(url))
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

    private static func validateExpectedContentLength(
        _ response: URLResponse,
        maximumBytes: Int64,
        context: String
    ) throws {
        let expected = response.expectedContentLength
        guard expected < 0 || expected <= maximumBytes else {
            throw KumoError.coreInstallFailed(
                "\(context) exceeds Kumo's \(maximumBytes)-byte safety limit."
            )
        }
    }

    private static func errorResponseData(from url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 512)) ?? Data()
    }

    internal static func validateFileSize(
        at url: URL,
        maximumBytes: Int64,
        context: String
    ) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixInstallError("open \(context)")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1,
              status.st_size >= 0 else {
            throw KumoError.coreInstallFailed("\(context) is not a safe regular file.")
        }
        guard status.st_size <= maximumBytes else {
            throw KumoError.coreInstallFailed(
                "\(context) exceeds Kumo's \(maximumBytes)-byte safety limit."
            )
        }
    }

    internal static func verifySHA256(of url: URL, expected: String) throws {
        guard expected.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
            throw KumoError.coreInstallFailed("The published Mihomo SHA-256 digest is invalid.")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixInstallError("open Mihomo archive for verification")
        }
        defer { close(descriptor) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw posixInstallError("read Mihomo archive for verification")
            }
            guard count > 0 else { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw KumoError.coreInstallFailed(
                "The downloaded Mihomo archive failed SHA-256 verification."
            )
        }
    }

    internal static func isSupportedMachOHeader(_ data: Data, architecture: String) -> Bool {
        guard data.count >= 32 else { return false }
        guard architecture.lowercased() == "arm64" else { return false }
        let expectedCPUType: UInt32 = 0x0100_000c

        let bytes = [UInt8](data)
        let magic = Array(bytes.prefix(4))
        if magic == [0xcf, 0xfa, 0xed, 0xfe] {
            return isExecutableMachO(
                bytes,
                expectedCPUType: expectedCPUType,
                littleEndian: true
            )
        }
        if magic == [0xfe, 0xed, 0xfa, 0xcf] {
            return isExecutableMachO(
                bytes,
                expectedCPUType: expectedCPUType,
                littleEndian: false
            )
        }
        return false
    }

    private static func isExecutableMachO(
        _ bytes: [UInt8],
        expectedCPUType: UInt32,
        littleEndian: Bool
    ) -> Bool {
        guard uint32(bytes, offset: 4, littleEndian: littleEndian) == expectedCPUType,
              uint32(bytes, offset: 12, littleEndian: littleEndian) == 2,
              let commandCount = uint32(bytes, offset: 16, littleEndian: littleEndian),
              let commandBytes = uint32(bytes, offset: 20, littleEndian: littleEndian),
              commandCount > 0,
              commandCount <= 16_384,
              commandBytes > 0,
              Int64(commandBytes) <= maximumMachOLoadCommandBytes,
              32 + Int(commandBytes) <= bytes.count else {
            return false
        }

        let commandRegionEnd = 32 + Int(commandBytes)
        var offset = 32
        for _ in 0..<commandCount {
            guard let commandSize = uint32(
                bytes,
                offset: offset + 4,
                littleEndian: littleEndian
            ),
            commandSize >= 8,
            commandSize % 4 == 0,
            offset <= commandRegionEnd - Int(commandSize) else {
                return false
            }
            offset += Int(commandSize)
        }
        return offset == commandRegionEnd
    }

    private static func declaredMachOMinimumSize(_ data: Data) -> Int64? {
        guard data.count >= 32 else { return nil }
        let bytes = [UInt8](data)
        let magic = Array(bytes.prefix(4))
        let littleEndian: Bool
        if magic == [0xcf, 0xfa, 0xed, 0xfe] {
            littleEndian = true
        } else if magic == [0xfe, 0xed, 0xfa, 0xcf] {
            littleEndian = false
        } else {
            return nil
        }
        guard let commandBytes = uint32(bytes, offset: 20, littleEndian: littleEndian) else {
            return nil
        }
        return 32 + Int64(commandBytes)
    }

    private static func uint32(
        _ bytes: [UInt8],
        offset: Int,
        littleEndian: Bool
    ) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let slice = bytes[offset..<(offset + 4)].map(UInt32.init)
        if littleEndian {
            return slice[0] | slice[1] << 8 | slice[2] << 16 | slice[3] << 24
        }
        return slice[0] << 24 | slice[1] << 16 | slice[2] << 8 | slice[3]
    }

    internal func installGzipArchive(
        _ archiveURL: URL,
        destinationURL: URL,
        architecture: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        defer { try? fileManager.removeItem(at: archiveURL) }
        try Self.validateFileSize(
            at: archiveURL,
            maximumBytes: Self.maximumArchiveBytes,
            context: "Mihomo archive"
        )
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let directoryDescriptor = open(
            destinationDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw Self.posixInstallError("open protected Mihomo directory")
        }
        defer { close(directoryDescriptor) }
        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            throw KumoError.coreInstallFailed("Kumo refused an unsafe Mihomo destination directory.")
        }

        let destinationName = destinationURL.lastPathComponent
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/") else {
            throw KumoError.coreInstallFailed("The Mihomo destination name is invalid.")
        }
        let installingName = ".mihomo-installing-\(UUID().uuidString)"
        let installingURL = destinationDirectory.appendingPathComponent(installingName)
        var shouldRemoveInstallingFile = true
        var installingDescriptor = openat(
            directoryDescriptor,
            installingName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR | S_IXUSR
        )
        guard installingDescriptor >= 0 else {
            throw Self.posixInstallError("create staged Mihomo executable")
        }
        defer {
            if installingDescriptor >= 0 { close(installingDescriptor) }
            if shouldRemoveInstallingFile {
                unlinkat(directoryDescriptor, installingName, 0)
            }
        }

        try Self.decompressGzip(
            archiveURL,
            to: installingDescriptor,
            maximumBytes: Self.maximumExecutableBytes
        )
        var executableStatus = stat()
        guard fstat(installingDescriptor, &executableStatus) == 0,
              executableStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              executableStatus.st_nlink == 1 else {
            throw KumoError.coreInstallFailed(
                "The downloaded Mihomo executable is not a valid \(architecture) Mach-O binary."
            )
        }
        var fixedHeader = [UInt8](repeating: 0, count: 32)
        guard try Self.preadAll(
            descriptor: installingDescriptor,
            into: &fixedHeader,
            offset: 0
        ),
        let declaredMinimumSize = Self.declaredMachOMinimumSize(Data(fixedHeader)),
        declaredMinimumSize <= Self.maximumMachOLoadCommandBytes + 32,
        executableStatus.st_size >= declaredMinimumSize else {
            throw KumoError.coreInstallFailed(
                "The downloaded Mihomo executable is not a valid \(architecture) Mach-O binary."
            )
        }
        var headerAndCommands = [UInt8](
            repeating: 0,
            count: Int(declaredMinimumSize)
        )
        guard try Self.preadAll(
            descriptor: installingDescriptor,
            into: &headerAndCommands,
            offset: 0
        ),
        Self.isSupportedMachOHeader(
            Data(headerAndCommands),
            architecture: architecture
        ) else {
            throw KumoError.coreInstallFailed(
                "The downloaded Mihomo executable is not a valid \(architecture) Mach-O binary."
            )
        }
        guard fchmod(
            installingDescriptor,
            S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
        ) == 0 else {
            throw Self.posixInstallError("set Mihomo executable permissions")
        }
        if geteuid() == 0, fchown(installingDescriptor, 0, 0) != 0 {
            throw Self.posixInstallError("protect Mihomo executable ownership")
        }
        guard fsync(installingDescriptor) == 0 else {
            throw Self.posixInstallError("synchronize staged Mihomo executable")
        }
        close(installingDescriptor)
        installingDescriptor = -1

        var destinationStatus = stat()
        let destinationExists = fstatat(
            directoryDescriptor,
            destinationName,
            &destinationStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0
        if !destinationExists, errno != ENOENT {
            throw Self.posixInstallError("inspect existing Mihomo executable")
        }

        if destinationExists {
            guard renamex_np(
                installingURL.path,
                destinationURL.path,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw Self.posixInstallError("atomically replace Mihomo executable")
            }
            guard fsync(directoryDescriptor) == 0 else {
                let rollbackResult = renamex_np(
                    installingURL.path,
                    destinationURL.path,
                    UInt32(RENAME_SWAP)
                )
                if rollbackResult != 0 {
                    // After the first swap, the previous known-good executable
                    // lives at installingName. Preserve it if rollback cannot
                    // restore the destination so a repair can recover it.
                    shouldRemoveInstallingFile = false
                }
                throw Self.posixInstallError("synchronize Mihomo executable replacement")
            }
        } else {
            guard renameat(
                directoryDescriptor,
                installingName,
                directoryDescriptor,
                destinationName
            ) == 0 else {
                throw Self.posixInstallError("install Mihomo executable")
            }
            guard fsync(directoryDescriptor) == 0 else {
                _ = renameat(
                    directoryDescriptor,
                    destinationName,
                    directoryDescriptor,
                    installingName
                )
                throw Self.posixInstallError("synchronize Mihomo executable installation")
            }
        }
        return destinationURL
    }

    private static func decompressGzip(
        _ archiveURL: URL,
        to destinationDescriptor: Int32,
        maximumBytes: Int64
    ) throws {
        guard let stream = archiveURL.path.withCString({ gzopen($0, "rb") }) else {
            throw KumoError.coreInstallFailed("Unable to open the Mihomo gzip archive.")
        }
        defer { gzclose(stream) }

        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                gzread(stream, pointer.baseAddress, UInt32(pointer.count))
            }
            if count < 0 {
                var errorCode: Int32 = 0
                let message = gzerror(stream, &errorCode).map(String.init(cString:))
                    ?? "The gzip archive could not be decompressed."
                throw KumoError.coreInstallFailed(message)
            }
            guard count > 0 else { break }
            total += Int64(count)
            guard total <= maximumBytes else {
                throw KumoError.coreInstallFailed(
                    "The decompressed Mihomo executable exceeds Kumo's \(maximumBytes)-byte safety limit."
                )
            }
            try writeAll(
                buffer,
                count: Int(count),
                to: destinationDescriptor
            )
        }
        guard total > 0 else {
            throw KumoError.coreInstallFailed("The Mihomo gzip archive is empty.")
        }
    }

    private static func writeAll(
        _ bytes: [UInt8],
        count: Int,
        to descriptor: Int32
    ) throws {
        try bytes.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw posixInstallError("write staged Mihomo executable")
                }
                offset += written
            }
        }
    }

    private static func preadAll(
        descriptor: Int32,
        into bytes: inout [UInt8],
        offset: off_t
    ) throws -> Bool {
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes { pointer in
                pread(
                    descriptor,
                    pointer.baseAddress?.advanced(by: total),
                    pointer.count - total,
                    offset + off_t(total)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw posixInstallError("read staged Mihomo executable")
            }
            guard count > 0 else { return false }
            total += count
        }
        return true
    }

    private static func posixInstallError(_ operation: String) -> NSError {
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
