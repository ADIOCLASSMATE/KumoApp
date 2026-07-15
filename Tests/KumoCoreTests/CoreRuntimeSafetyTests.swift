import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class CoreRuntimeSafetyTests: XCTestCase {
    func testPrivilegedClassifierRecognizesPrivateRuntimeAndLegacyRuntimeForCleanup() {
        let privateWork = "/private/var/run/io.kumo/501/work"
        let privateInstances = "/private/var/run/io.kumo/501/instances"
        let legacyWork = "/Users/test/Library/Application Support/Kumo/work"
        let legacyInstances = legacyWork + "/instances"
        let executable = "/Library/Application Support/io.kumo.KumoService/users/501/mihomo"
        let classifier = CoreOwnedProcessClassifier(
            workDirectory: privateWork,
            additionalWorkDirectories: [legacyWork],
            instanceConfigurationsDirectory: privateInstances,
            additionalInstanceConfigurationDirectories: [legacyInstances],
            allowedExecutablePaths: [executable],
            legacyExecutableNames: ["mihomo", "mihomo-alpha", "clash", "clash-meta"],
            endpoint: ControllerEndpoint(port: 9097),
            allowedUserIDs: [0]
        )
        let privateRuntime = CoreProcessSnapshot(
            identity: CoreProcessIdentity(pid: 40, birthToken: 6),
            executablePath: executable,
            arguments: [
                "mihomo", "-d", privateWork,
                "-f", privateInstances + "/launch/config.yaml"
            ],
            userID: 0
        )
        let legacyRuntime = CoreProcessSnapshot(
            identity: CoreProcessIdentity(pid: 41, birthToken: 7),
            executablePath: "/opt/homebrew/bin/mihomo",
            arguments: [
                "/opt/homebrew/bin/mihomo", "-d", legacyWork,
                "-f", legacyWork + "/config.yaml"
            ],
            userID: 0
        )

        XCTAssertEqual(classifier.classify(privateRuntime), .owned)
        XCTAssertEqual(classifier.classify(legacyRuntime), .owned)
    }

    func testOwnedProcessUsesExplicitPrivateInstanceConfigurationDirectory() {
        let classifier = CoreOwnedProcessClassifier(
            workDirectory: "/Users/test/Library/Application Support/Kumo/work",
            instanceConfigurationsDirectory: "/var/run/io.kumo/501/instances",
            allowedExecutablePaths: ["/Library/Application Support/io.kumo.KumoService/users/501/mihomo"],
            endpoint: ControllerEndpoint(port: 9097),
            allowedUserIDs: [0]
        )
        let privateConfig = CoreProcessSnapshot(
            identity: CoreProcessIdentity(pid: 42, birthToken: 7),
            executablePath: "/Library/Application Support/io.kumo.KumoService/users/501/mihomo",
            arguments: [
                "mihomo",
                "-d", "/Users/test/Library/Application Support/Kumo/work",
                "-f", "/var/run/io.kumo/501/instances/launch/config.yaml"
            ],
            userID: 0
        )
        var userDirectoryConfig = privateConfig
        userDirectoryConfig.arguments = [
            "mihomo",
            "-d", "/Users/test/Library/Application Support/Kumo/work",
            "-f", "/Users/test/Library/Application Support/Kumo/work/instances/launch/config.yaml"
        ]

        XCTAssertEqual(classifier.classify(privateConfig), .owned)
        XCTAssertEqual(classifier.classify(userDirectoryConfig), .foreign)
    }

    func testOwnedProcessRequiresExactKumoWorkDirectory() {
        let workDirectory = "/Users/test/Library/Application Support/Kumo/work"
        let executable = "/Users/test/Library/Application Support/Kumo/cores/mihomo"
        let classifier = CoreOwnedProcessClassifier(
            workDirectory: workDirectory,
            allowedExecutablePaths: [executable],
            endpoint: ControllerEndpoint()
        )
        let owned = CoreProcessSnapshot(
            identity: CoreProcessIdentity(pid: 101, birthToken: 1),
            executablePath: executable,
            arguments: [executable, "-d", workDirectory, "-ext-ctl", "127.0.0.1:9097"],
            userID: getuid()
        )
        let foreign = CoreProcessSnapshot(
            identity: CoreProcessIdentity(pid: 102, birthToken: 2),
            executablePath: executable,
            arguments: [executable, "-d", "/tmp/someone-else", "-ext-ctl", "127.0.0.1:9097"],
            userID: getuid()
        )

        XCTAssertEqual(classifier.classify(owned), .owned)
        XCTAssertEqual(classifier.classify(foreign), .foreign)
    }

    func testLegacySymlinkCannotClaimForeignRootRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyWork = root.appendingPathComponent("legacy-work", isDirectory: true)
        let foreignWork = root.appendingPathComponent("foreign-root-work", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignWork, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: legacyWork, withDestinationURL: foreignWork)
        let classifier = CoreOwnedProcessClassifier(
            workDirectory: "/private/var/run/io.kumo/501/work",
            additionalWorkDirectories: [legacyWork.path],
            additionalInstanceConfigurationDirectories: [legacyWork.appendingPathComponent("instances").path],
            allowedExecutablePaths: ["/Library/Application Support/io.kumo.KumoService/users/501/mihomo"],
            legacyExecutableNames: ["mihomo"],
            endpoint: ControllerEndpoint(),
            allowedUserIDs: [0]
        )
        let foreign = CoreProcessSnapshot(
            identity: CoreProcessIdentity(pid: 77, birthToken: 9),
            executablePath: "/usr/local/bin/mihomo",
            arguments: [
                "mihomo", "-d", foreignWork.path,
                "-f", foreignWork.appendingPathComponent("config.yaml").path
            ],
            userID: 0
        )

        XCTAssertEqual(classifier.classify(foreign), .foreign)
    }

    func testReadinessRequiresBothPortsToBelongToExpectedBirthIdentity() throws {
        let expected = CoreProcessIdentity(pid: 200, birthToken: 10)
        let old = CoreProcessIdentity(pid: 100, birthToken: 5)
        let verifier = CoreReadinessVerifier(controllerPort: 9097, mixedPort: 7890)

        XCTAssertThrowsError(
            try verifier.verify(
                expected: expected,
                listeners: CoreListenerSnapshot(ownersByPort: [9097: [old], 7890: [old]])
            )
        )
        XCTAssertThrowsError(
            try verifier.verify(
                expected: expected,
                listeners: CoreListenerSnapshot(ownersByPort: [9097: [expected], 7890: [old]])
            )
        )
        XCTAssertNoThrow(
            try verifier.verify(
                expected: expected,
                listeners: CoreListenerSnapshot(ownersByPort: [9097: [expected], 7890: [expected]])
            )
        )
    }

    func testSamePIDWithDifferentBirthTokenIsNotTheExpectedProcess() {
        let original = CoreProcessIdentity(pid: 300, birthToken: 1)
        let reused = CoreProcessIdentity(pid: 300, birthToken: 2)

        XCTAssertNotEqual(original, reused)
    }

    func testRuntimeGenerationRejectsResultsFromEarlierRuntime() {
        var generation = RuntimeDataGeneration()
        let first = generation.beginTransition()
        let second = generation.beginTransition()

        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
    }

    func testLifecycleLockSerializesIndependentCallers() {
        let paths = KumoPaths(
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let locks = [
            CoreLifecycleLock(paths: paths, ownership: nil),
            CoreLifecycleLock(paths: paths, ownership: nil)
        ]
        let probe = CriticalSectionProbe()

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try locks[index].withLock {
                    probe.enter()
                    usleep(100_000)
                    probe.leave()
                }
            } catch {
                probe.record(error)
            }
        }

        XCTAssertEqual(probe.maximumConcurrentCount, 1)
        XCTAssertTrue(probe.errors.isEmpty)
    }
}

private final class CriticalSectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private(set) var maximumConcurrentCount = 0
    private(set) var errors: [Error] = []

    func enter() {
        lock.lock()
        activeCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, activeCount)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        activeCount -= 1
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}
