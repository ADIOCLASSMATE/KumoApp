import Foundation

public enum KumoServiceProtocol {
    public static let currentVersion = 1
}

public struct KumoServiceCapability: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let runtimeActivationReceipt = KumoServiceCapability(
        rawValue: "runtime-activation-receipt-v1"
    )
    public static let atomicRuntimeGenerationCAS = KumoServiceCapability(
        rawValue: "atomic-runtime-generation-cas-v1"
    )
    public static let privilegedInstallationHealth = KumoServiceCapability(
        rawValue: "privileged-installation-health-v1"
    )
    public static let routedRuntimeMutations = KumoServiceCapability(
        rawValue: "routed-runtime-mutations-v1"
    )
}

public struct KumoServiceHandshake: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let helperVersion: String
    public let capabilities: [KumoServiceCapability]

    public init(
        protocolVersion: Int,
        helperVersion: String,
        capabilities: [KumoServiceCapability]
    ) {
        self.protocolVersion = protocolVersion
        self.helperVersion = helperVersion
        self.capabilities = capabilities
    }

    public static func current(helperVersion: String) -> KumoServiceHandshake {
        KumoServiceHandshake(
            protocolVersion: KumoServiceProtocol.currentVersion,
            helperVersion: helperVersion,
            capabilities: [
                .runtimeActivationReceipt,
                .atomicRuntimeGenerationCAS,
                .privilegedInstallationHealth,
                .routedRuntimeMutations
            ]
        )
    }

    public var isCompatible: Bool {
        protocolVersion == KumoServiceProtocol.currentVersion
            && capabilities.contains(.runtimeActivationReceipt)
            && capabilities.contains(.atomicRuntimeGenerationCAS)
            && capabilities.contains(.privilegedInstallationHealth)
            && capabilities.contains(.routedRuntimeMutations)
    }
}
