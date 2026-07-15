import Foundation

/// The exact, controller-confirmed runtime that currently owns proxy traffic.
public struct RuntimeIdentity: Codable, Equatable, Sendable {
    public let profileID: String
    public let generation: UUID
    public let configurationDigest: String

    public init(profileID: String, generation: UUID, configurationDigest: String) {
        self.profileID = profileID
        self.generation = generation
        self.configurationDigest = configurationDigest
    }

    init?(confirmedBy status: CoreStatus) {
        guard status.state == .running,
              status.readiness == .controllerReady,
              let profileID = status.activeProfileID,
              !profileID.isEmpty,
              let generation = status.runtimeGeneration,
              let configurationDigest = status.configurationDigest,
              !configurationDigest.isEmpty else {
            return nil
        }
        self.init(
            profileID: profileID,
            generation: generation,
            configurationDigest: configurationDigest
        )
    }
}

/// One observed backend state. `identity` is deliberately absent until the
/// controller has confirmed the exact profile, generation, and config digest.
public struct RuntimeSnapshot: Equatable, Sendable {
    public let status: CoreStatus
    public let identity: RuntimeIdentity?

    public init(status: CoreStatus) {
        self.status = status
        self.identity = RuntimeIdentity(confirmedBy: status)
    }
}

/// Compare-and-swap precondition for every runtime lifecycle mutation.
public enum RuntimeGenerationExpectation: Codable, Equatable, Sendable {
    case stopped
    case matching(UUID)

    private enum Kind: String, Codable {
        case stopped
        case matching
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case generation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stopped:
            guard !container.contains(.generation) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .generation,
                    in: container,
                    debugDescription: "A stopped runtime expectation cannot include a generation."
                )
            }
            self = .stopped
        case .matching:
            self = .matching(try container.decode(UUID.self, forKey: .generation))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stopped:
            try container.encode(Kind.stopped, forKey: .kind)
        case .matching(let generation):
            try container.encode(Kind.matching, forKey: .kind)
            try container.encode(generation, forKey: .generation)
        }
    }

    func validate(actualGeneration: UUID?) throws {
        let matches: Bool
        switch self {
        case .stopped:
            matches = actualGeneration == nil
        case .matching(let expected):
            matches = actualGeneration == expected
        }
        guard matches else {
            throw KumoError.runtimeGenerationConflict
        }
    }

    func requireStoppedOperation() throws {
        guard self == .stopped else {
            throw KumoError.invalidArguments("Starting a runtime requires a stopped-generation expectation.")
        }
    }

    func requiredMatchingGeneration() throws -> UUID {
        guard case .matching(let generation) = self else {
            throw KumoError.invalidArguments("This runtime operation requires an exact generation expectation.")
        }
        return generation
    }
}

/// Single authority boundary for lifecycle reads and mutations.
///
/// Implementations must enforce `expecting` atomically with the mutation; a
/// caller-side status check is never an acceptable substitute.
protocol RuntimeBackend: Sendable {
    func status() async throws -> RuntimeSnapshot

    func start(
        _ spec: RuntimeSpec,
        systemProxySettings: SystemProxySettings?,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot

    func restart(
        _ spec: RuntimeSpec,
        systemProxySettings: SystemProxySettings?,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot

    func stop(expecting: RuntimeGenerationExpectation) async throws -> RuntimeSnapshot

    func apply(
        _ mutation: RuntimeMutation,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot
}

struct SupervisorRuntimeBackend: RuntimeBackend {
    private let supervisor: CoreSupervisor
    private let corePath: String?

    init(supervisor: CoreSupervisor, corePath: String? = nil) {
        self.supervisor = supervisor
        self.corePath = corePath
    }

    func status() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(status: try supervisor.status())
    }

    func start(
        _ spec: RuntimeSpec,
        systemProxySettings: SystemProxySettings?,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot {
        try expecting.requireStoppedOperation()
        let status = try supervisor.start(
            configuration: launchConfiguration(spec, systemProxySettings: systemProxySettings),
            expecting: expecting
        )
        return RuntimeSnapshot(status: status)
    }

    func restart(
        _ spec: RuntimeSpec,
        systemProxySettings: SystemProxySettings?,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot {
        _ = try expecting.requiredMatchingGeneration()
        let status = try supervisor.restart(
            configuration: launchConfiguration(spec, systemProxySettings: systemProxySettings),
            expecting: expecting
        )
        return RuntimeSnapshot(status: status)
    }

    func stop(expecting: RuntimeGenerationExpectation) async throws -> RuntimeSnapshot {
        _ = try expecting.requiredMatchingGeneration()
        return RuntimeSnapshot(status: try supervisor.stop(expecting: expecting))
    }

    func apply(
        _ mutation: RuntimeMutation,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot {
        _ = try expecting.requiredMatchingGeneration()
        let before = try supervisor.status()
        try expecting.validate(actualGeneration: before.runtimeGeneration)
        guard before.state == .running, before.readiness == .controllerReady else {
            throw KumoError.coreNotRunning
        }
        let controller = MihomoControllerClient(endpoint: before.endpoint)
        try await controller.apply(mutation)
        var after = try supervisor.status()
        try expecting.validate(actualGeneration: after.runtimeGeneration)
        if case .setMode(let mode) = mutation {
            after.mode = mode
        }
        return RuntimeSnapshot(status: after)
    }

    private func launchConfiguration(
        _ spec: RuntimeSpec,
        systemProxySettings: SystemProxySettings?
    ) -> CoreLaunchConfiguration {
        CoreLaunchConfiguration(
            corePath: corePath,
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

struct ServiceRuntimeBackend: RuntimeBackend {
    private let client: KumoServiceClient
    private let serviceStatusProvider: @Sendable () -> ServiceModeStatus

    init(serviceManager: KumoServiceManager) throws {
        let serviceStatus = serviceManager.status()
        try Self.validate(serviceStatus: serviceStatus)
        guard let client = serviceManager.serviceClient() else {
            throw KumoError.serviceUnavailable("Kumo Helper credentials are unavailable.")
        }
        self.client = client
        self.serviceStatusProvider = { serviceManager.status() }
    }

    init(
        client: KumoServiceClient,
        serviceStatusProvider: @escaping @Sendable () -> ServiceModeStatus
    ) throws {
        try Self.validate(serviceStatus: serviceStatusProvider())
        self.client = client
        self.serviceStatusProvider = serviceStatusProvider
    }

    func status() async throws -> RuntimeSnapshot {
        try requireSafeService()
        return RuntimeSnapshot(
            status: try client.sendDecodable(client.statusRequest(), as: CoreStatus.self)
        )
    }

    func start(
        _ spec: RuntimeSpec,
        systemProxySettings: SystemProxySettings?,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot {
        try expecting.requireStoppedOperation()
        try requireAtomicCASCapability()
        let status = try client.sendDecodable(
            client.startCoreRequest(CoreRuntimeLaunchRequest(
                spec: spec,
                systemProxySettings: systemProxySettings,
                expectedGeneration: expecting
            )),
            as: CoreStatus.self
        )
        _ = try status.activationReceipt(
            expectedProfileID: spec.profileID,
            expectedConfigurationDigest: spec.configurationDigest
        )
        return RuntimeSnapshot(status: status)
    }

    func restart(
        _ spec: RuntimeSpec,
        systemProxySettings: SystemProxySettings?,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot {
        _ = try expecting.requiredMatchingGeneration()
        try requireAtomicCASCapability()
        let status = try client.sendDecodable(
            client.restartCoreRequest(CoreRuntimeLaunchRequest(
                spec: spec,
                systemProxySettings: systemProxySettings,
                expectedGeneration: expecting
            )),
            as: CoreStatus.self
        )
        _ = try status.activationReceipt(
            expectedProfileID: spec.profileID,
            expectedConfigurationDigest: spec.configurationDigest
        )
        return RuntimeSnapshot(status: status)
    }

    func stop(expecting: RuntimeGenerationExpectation) async throws -> RuntimeSnapshot {
        _ = try expecting.requiredMatchingGeneration()
        try requireAtomicCASCapability()
        let status = try client.sendDecodable(
            try client.stopCoreRequest(RuntimeStopRequest(expectedGeneration: expecting)),
            as: CoreStatus.self
        )
        guard status.isStrictlyStoppedProcessState else {
            throw KumoError.commandFailed("Kumo Helper did not confirm that the requested runtime stopped.")
        }
        return RuntimeSnapshot(status: status)
    }

    func apply(
        _ mutation: RuntimeMutation,
        expecting: RuntimeGenerationExpectation
    ) async throws -> RuntimeSnapshot {
        _ = try expecting.requiredMatchingGeneration()
        try requireAtomicCASCapability()
        let status = try client.sendDecodable(
            try client.runtimeMutationRequest(RuntimeMutationRequest(
                mutation: mutation,
                expectedGeneration: expecting
            )),
            as: CoreStatus.self
        )
        try expecting.validate(actualGeneration: status.runtimeGeneration)
        return RuntimeSnapshot(status: status)
    }

    private func requireAtomicCASCapability() throws {
        try requireSafeService()
        let handshake = try client.compatibleHandshake()
        guard handshake.capabilities.contains(.atomicRuntimeGenerationCAS) else {
            throw KumoError.serviceUnavailable(
                "The installed Kumo Helper cannot safely compare runtime generations. Repair the Helper before changing the runtime."
            )
        }
    }

    private func requireSafeService() throws {
        try Self.validate(serviceStatus: serviceStatusProvider())
    }

    private static func validate(serviceStatus: ServiceModeStatus) throws {
        guard serviceStatus.isAvailable,
              serviceStatus.isRunning else {
            throw KumoError.serviceUnavailable(
                serviceStatus.message
                    ?? "Kumo Helper is not safe for runtime mutations. Repair the Helper before changing the runtime."
            )
        }
    }
}
