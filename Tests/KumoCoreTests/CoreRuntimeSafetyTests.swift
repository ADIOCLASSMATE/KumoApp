import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class CoreRuntimeSafetyTests: XCTestCase {
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
}
