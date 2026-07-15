import Darwin
import XCTest
@_spi(KumoService) @testable import KumoCoreKit

final class RuntimeActivationReceiptTests: XCTestCase {
    func testRunningStatusProducesReceiptOnlyForExactProfileAndConfiguration() throws {
        let generation = UUID()
        let digest = String(repeating: "c", count: 64)
        let status = CoreStatus(
            state: .running,
            pid: 42,
            readiness: .controllerReady,
            activeProfileID: "profile-b",
            runtimeGeneration: generation,
            configurationDigest: digest
        )

        let receipt = try status.activationReceipt(
            expectedProfileID: "profile-b",
            expectedConfigurationDigest: digest
        )

        XCTAssertEqual(receipt.profileID, "profile-b")
        XCTAssertEqual(receipt.runtimeGeneration, generation)
        XCTAssertEqual(receipt.configurationDigest, digest)
    }

    func testReceiptRejectsCorrectProfileLabelWithWrongConfiguration() {
        let status = CoreStatus(
            state: .running,
            pid: 42,
            readiness: .controllerReady,
            activeProfileID: "profile-b",
            runtimeGeneration: UUID(),
            configurationDigest: String(repeating: "d", count: 64)
        )

        XCTAssertThrowsError(
            try status.activationReceipt(
                expectedProfileID: "profile-b",
                expectedConfigurationDigest: String(repeating: "e", count: 64)
            )
        )
    }

    func testPrivilegedLaunchRejectsDigestMismatchBeforeCoreDiscovery() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("user", isDirectory: true),
            privilegedRuntimeRootDirectory: root.appendingPathComponent("run", isDirectory: true),
            privilegedServiceSupportDirectory: root.appendingPathComponent("service", isDirectory: true)
        )
        let controller = KumoController(
            servicePaths: paths,
            stateFileOwnership: StateFileOwnership(userID: getuid(), groupID: getgid())
        )
        let request = CoreRuntimeLaunchRequest(
            spec: RuntimeSpec(
                profileID: "profile-b",
                profileYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n",
                overrideYAMLs: [],
                endpoint: ControllerEndpoint(),
                proxyPorts: ProxyPortConfiguration(),
                mode: .rule,
                runtimeSettings: CoreRuntimeSettings(),
                configurationDigest: String(repeating: "f", count: 64)
            ),
            expectedGeneration: .stopped
        )

        do {
            _ = try await controller.launchRuntimeAndWait(request, restart: false)
            XCTFail("Expected the Helper launch to reject the mismatched digest")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("digest"))
        }
    }
}
