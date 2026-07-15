import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class BoundedChildProcessTerminatorTests: XCTestCase {
    func testStopReturnsPromptlyForChildThatAlreadyExited() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertFalse(process.isRunning)

        let startedAt = Date()
        BoundedChildProcessTerminator.stop(process)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
    }

    func testStopBoundsTerminationOfChildThatIgnoresTerm() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do :; done"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        defer {
            if Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }

        let startedAt = Date()
        BoundedChildProcessTerminator.stop(
            process,
            gracefulTimeout: 0.05,
            forcedTimeout: 0.1
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }
}
