import Foundation
import XCTest
@testable @_spi(KumoService) import KumoCoreKit

final class ServiceInstallationCoordinatorTests: XCTestCase {
    func testSuccessfulConvergentRepairUsesFailSafeCommitOrder() async throws {
        let harness = InstallationHarness()

        try await ServiceInstallationCoordinator.converge(
            operations: harness.operations()
        )

        XCTAssertEqual(
            harness.events,
            [.manifestInstalling, .stop, .proxySafe, .installFiles, .start, .manifestInstalled]
        )
    }

    func testEveryInterruptedStageRecordsRepairRequiredAndRetryConverges() async throws {
        for stage in InstallationEvent.installationStages {
            let harness = InstallationHarness(failOnceAt: stage)

            do {
                try await ServiceInstallationCoordinator.converge(
                    operations: harness.operations()
                )
                XCTFail("Expected simulated failure at \(stage)")
            } catch {
                XCTAssertEqual(
                    harness.events.last,
                    .manifestRepairRequired,
                    "An interrupted \(stage) stage did not leave an explicit repair state."
                )
            }

            harness.clearEvents()
            try await ServiceInstallationCoordinator.converge(
                operations: harness.operations()
            )
            XCTAssertEqual(
                harness.events,
                [.manifestInstalling, .stop, .proxySafe, .installFiles, .start, .manifestInstalled],
                "Retry did not converge after a simulated \(stage) interruption."
            )
        }
    }
}

private enum InstallationEvent: String, CaseIterable, Sendable {
    case manifestInstalling
    case stop
    case proxySafe
    case installFiles
    case start
    case manifestInstalled
    case manifestRepairRequired

    static let installationStages: [InstallationEvent] = [
        .manifestInstalling,
        .stop,
        .proxySafe,
        .installFiles,
        .start,
        .manifestInstalled
    ]
}

private final class InstallationHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [InstallationEvent] = []
    private var failOnceAt: InstallationEvent?

    init(failOnceAt: InstallationEvent? = nil) {
        self.failOnceAt = failOnceAt
    }

    var events: [InstallationEvent] {
        lock.withLock { recordedEvents }
    }

    func clearEvents() {
        lock.withLock { recordedEvents.removeAll() }
    }

    func operations() -> ConvergentServiceInstallationOperations {
        ConvergentServiceInstallationOperations(
            writeManifestPhase: { [self] phase in
                switch phase {
                case .installing:
                    try record(.manifestInstalling)
                case .installed:
                    try record(.manifestInstalled)
                case .repairRequired:
                    try record(.manifestRepairRequired)
                }
            },
            stopLoadedService: { [self] in
                try record(.stop)
            },
            makeSystemProxySafe: { [self] in
                try record(.proxySafe)
            },
            installCandidateFiles: { [self] in
                try record(.installFiles)
            },
            startAndValidateCandidate: { [self] in
                try record(.start)
            }
        )
    }

    private func record(_ event: InstallationEvent) throws {
        let shouldFail = lock.withLock { () -> Bool in
            recordedEvents.append(event)
            guard failOnceAt == event else { return false }
            failOnceAt = nil
            return true
        }
        if shouldFail {
            throw InstallationFailure(event: event)
        }
    }
}

private struct InstallationFailure: LocalizedError {
    let event: InstallationEvent

    var errorDescription: String? {
        "Simulated installation failure at \(event.rawValue)."
    }
}
