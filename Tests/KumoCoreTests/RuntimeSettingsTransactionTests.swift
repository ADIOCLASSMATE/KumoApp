import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class RuntimeSettingsTransactionTests: XCTestCase {
    func testMixedPortIsNotCommittedWhenStaleSystemProxyCleanupFails() async throws {
        let oldListener = try ListeningSocket()
        let newListener = try ListeningSocket()
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let stateStore = CoreStateStore(paths: paths)
        let oldSettings = CoreRuntimeSettings(mixedPort: oldListener.port)
        let appliedProxyOutput = "Enabled: Yes\nServer: 127.0.0.1\nPort: \(oldListener.port)"
        try stateStore.save(CoreStatus(
            state: .stopped,
            proxyPorts: ProxyPortConfiguration(mixedPort: oldListener.port),
            systemProxyEnabled: true,
            runtimeSettings: oldSettings,
            systemProxySettings: SystemProxySettings(
                networkService: "Wi-Fi",
                host: "127.0.0.1",
                port: oldListener.port
            ),
            appliedSystemProxySnapshot: SystemProxySnapshot(
                networkService: "Wi-Fi",
                webProxy: appliedProxyOutput,
                secureWebProxy: appliedProxyOutput,
                socksProxy: appliedProxyOutput,
                bypassDomains: appliedProxyOutput,
                autoProxy: "Enabled: No\nURL:"
            )
        ))
        let recorder = ProxyReapplyRecorder(initialPort: oldListener.port)
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: recorder.runner
        )

        var nextSettings = oldSettings
        nextSettings.mixedPort = newListener.port
        do {
            try await controller.updateRuntimeSettings(nextSettings)
            XCTFail("Expected the first system proxy apply to fail")
        } catch {
            // Expected. The rollback apply is configured to succeed.
        }

        let stored = try stateStore.load()
        XCTAssertEqual(stored.proxyPorts.mixedPort, oldListener.port)
        XCTAssertEqual(stored.runtimeSettings?.mixedPort, oldListener.port)
        XCTAssertEqual(recorder.failedPort, oldListener.port)
        XCTAssertEqual(recorder.appliedPort, oldListener.port)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class ProxyReapplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true
    private var currentPort: Int
    private(set) var failedPort: Int?

    init(initialPort: Int) {
        self.currentPort = initialPort
    }

    var appliedPort: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentPort
    }

    var runner: SystemProxyCommandRunner {
        SystemProxyCommandRunner(
            run: { [self] command in
                lock.lock()
                defer { lock.unlock() }
                if command.arguments.first == "-setwebproxy",
                   let port = command.arguments.last.flatMap(Int.init) {
                    if shouldFail {
                        shouldFail = false
                        failedPort = port
                        throw KumoError.commandFailed("simulated networksetup failure")
                    }
                    currentPort = port
                }
            },
            captureOutput: { [self] command in
                lock.lock()
                defer { lock.unlock() }
                if command.arguments.first == "-getautoproxyurl" {
                    return "Enabled: No\nURL:"
                }
                return "Enabled: Yes\nServer: 127.0.0.1\nPort: \(currentPort)"
            }
        )
    }
}

private final class ListeningSocket: @unchecked Sendable {
    let descriptor: Int32
    let port: Int

    init() throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(socketDescriptor, 8) == 0 else {
            close(socketDescriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketDescriptor)
            throw POSIXError(.EIO)
        }
        descriptor = socketDescriptor
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    deinit {
        close(descriptor)
    }
}
