import Foundation

/// Immutable desired runtime input prepared before any process mutation.
public struct RuntimeSpec: Codable, Equatable, Sendable {
    public let profileID: String
    public let profileYAML: String
    public let overrideYAMLs: [String]
    public let endpoint: ControllerEndpoint
    public let proxyPorts: ProxyPortConfiguration
    public let mode: OutboundMode
    public let runtimeSettings: CoreRuntimeSettings
    public let configurationDigest: String

    public init(
        profileID: String,
        profileYAML: String,
        overrideYAMLs: [String],
        endpoint: ControllerEndpoint,
        proxyPorts: ProxyPortConfiguration,
        mode: OutboundMode,
        runtimeSettings: CoreRuntimeSettings,
        configurationDigest: String
    ) {
        self.profileID = profileID
        self.profileYAML = profileYAML
        self.overrideYAMLs = overrideYAMLs
        self.endpoint = endpoint
        self.proxyPorts = proxyPorts
        self.mode = mode
        self.runtimeSettings = runtimeSettings
        self.configurationDigest = configurationDigest
    }

    func validatedRuntimeConfig(enforceManagedFeatureSettings: Bool) throws -> RuntimeConfig {
        let runtime = try RuntimeConfigBuilder(
            endpoint: endpoint,
            proxyPorts: proxyPorts,
            mode: mode,
            runtimeSettings: runtimeSettings,
            enforceManagedFeatureSettings: enforceManagedFeatureSettings
        ).build(
            profile: Profile(name: profileID, source: .inline, rawYAML: profileYAML),
            profileID: profileID,
            overrideYAMLs: overrideYAMLs
        )
        guard runtime.configurationDigest == configurationDigest else {
            throw KumoError.commandFailed(
                "The generated runtime configuration did not match the requested configuration digest."
            )
        }
        return runtime
    }
}

/// Transport envelope for a runtime spec plus system-proxy recovery input.
public struct CoreRuntimeLaunchRequest: Codable, Equatable, Sendable {
    public let spec: RuntimeSpec
    public let systemProxySettings: SystemProxySettings?
    public let expectedGeneration: RuntimeGenerationExpectation

    public init(
        spec: RuntimeSpec,
        systemProxySettings: SystemProxySettings? = nil,
        expectedGeneration: RuntimeGenerationExpectation
    ) {
        self.spec = spec
        self.systemProxySettings = systemProxySettings
        self.expectedGeneration = expectedGeneration
    }

    var launchConfiguration: CoreLaunchConfiguration {
        CoreLaunchConfiguration(
            profileID: spec.profileID,
            profile: Profile(name: spec.profileID, source: .inline, rawYAML: spec.profileYAML),
            overrideYAMLs: spec.overrideYAMLs,
            endpoint: spec.endpoint,
            proxyPorts: spec.proxyPorts,
            mode: spec.mode,
            runtimeSettings: spec.runtimeSettings,
            systemProxySettings: systemProxySettings,
            expectedConfigurationDigest: spec.configurationDigest
        )
    }
}

public struct RuntimeStopRequest: Codable, Equatable, Sendable {
    public let expectedGeneration: RuntimeGenerationExpectation

    public init(expectedGeneration: RuntimeGenerationExpectation) {
        self.expectedGeneration = expectedGeneration
    }
}

public enum RuntimeMutation: Codable, Equatable, Sendable {
    case setMode(OutboundMode)
    case selectProxy(group: String, name: String)
    case setRuleEnabled(index: Int, isEnabled: Bool)
    case closeConnection(id: String)
    case closeConnections(matchingProxy: String?)
    case updateProxyProvider(name: String)
    case updateRuleProvider(name: String)
    case upgradeGeoData

    private enum Kind: String, Codable {
        case setMode
        case selectProxy
        case setRuleEnabled
        case closeConnection
        case closeConnections
        case updateProxyProvider
        case updateRuleProvider
        case upgradeGeoData
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case mode
        case group
        case name
        case index
        case isEnabled
        case id
        case matchingProxy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .setMode:
            self = .setMode(try container.decode(OutboundMode.self, forKey: .mode))
        case .selectProxy:
            self = .selectProxy(
                group: try container.decode(String.self, forKey: .group),
                name: try container.decode(String.self, forKey: .name)
            )
        case .setRuleEnabled:
            self = .setRuleEnabled(
                index: try container.decode(Int.self, forKey: .index),
                isEnabled: try container.decode(Bool.self, forKey: .isEnabled)
            )
        case .closeConnection:
            self = .closeConnection(id: try container.decode(String.self, forKey: .id))
        case .closeConnections:
            self = .closeConnections(
                matchingProxy: try container.decodeIfPresent(String.self, forKey: .matchingProxy)
            )
        case .updateProxyProvider:
            self = .updateProxyProvider(name: try container.decode(String.self, forKey: .name))
        case .updateRuleProvider:
            self = .updateRuleProvider(name: try container.decode(String.self, forKey: .name))
        case .upgradeGeoData:
            self = .upgradeGeoData
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setMode(let mode):
            try container.encode(Kind.setMode, forKey: .kind)
            try container.encode(mode, forKey: .mode)
        case let .selectProxy(group, name):
            try container.encode(Kind.selectProxy, forKey: .kind)
            try container.encode(group, forKey: .group)
            try container.encode(name, forKey: .name)
        case let .setRuleEnabled(index, isEnabled):
            try container.encode(Kind.setRuleEnabled, forKey: .kind)
            try container.encode(index, forKey: .index)
            try container.encode(isEnabled, forKey: .isEnabled)
        case .closeConnection(let id):
            try container.encode(Kind.closeConnection, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .closeConnections(let matchingProxy):
            try container.encode(Kind.closeConnections, forKey: .kind)
            try container.encodeIfPresent(matchingProxy, forKey: .matchingProxy)
        case .updateProxyProvider(let name):
            try container.encode(Kind.updateProxyProvider, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .updateRuleProvider(let name):
            try container.encode(Kind.updateRuleProvider, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .upgradeGeoData:
            try container.encode(Kind.upgradeGeoData, forKey: .kind)
        }
    }
}

public struct RuntimeMutationRequest: Codable, Equatable, Sendable {
    public let mutation: RuntimeMutation
    public let expectedGeneration: RuntimeGenerationExpectation

    public init(
        mutation: RuntimeMutation,
        expectedGeneration: RuntimeGenerationExpectation
    ) {
        self.mutation = mutation
        self.expectedGeneration = expectedGeneration
    }
}

public struct RuntimeSystemProxyEnableRequest: Codable, Equatable, Sendable {
    public let settings: SystemProxySettings
    public let expectedGeneration: RuntimeGenerationExpectation

    public init(
        settings: SystemProxySettings,
        expectedGeneration: RuntimeGenerationExpectation
    ) {
        self.settings = settings
        self.expectedGeneration = expectedGeneration
    }
}

/// Proof that one exact configuration is the active, controller-ready runtime.
/// Profile selection must not be committed from a profile label alone.
public struct RuntimeActivationReceipt: Codable, Equatable, Sendable {
    public let profileID: String
    public let runtimeGeneration: UUID
    public let configurationDigest: String

    public init(
        profileID: String,
        runtimeGeneration: UUID,
        configurationDigest: String
    ) {
        self.profileID = profileID
        self.runtimeGeneration = runtimeGeneration
        self.configurationDigest = configurationDigest
    }
}

public extension CoreStatus {
    func activationReceipt(
        expectedProfileID: String,
        expectedConfigurationDigest: String
    ) throws -> RuntimeActivationReceipt {
        guard state == .running,
              readiness == .controllerReady,
              activeProfileID == expectedProfileID,
              let runtimeGeneration,
              configurationDigest == expectedConfigurationDigest else {
            throw KumoError.commandFailed(
                "Mihomo did not confirm the requested profile, generation, and configuration digest."
            )
        }
        return RuntimeActivationReceipt(
            profileID: expectedProfileID,
            runtimeGeneration: runtimeGeneration,
            configurationDigest: expectedConfigurationDigest
        )
    }
}
