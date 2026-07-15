import Foundation
import KumoCoreKit

@MainActor
extension KumoAppStore {
    func loadProxyGroups() async {
        let generation = runtimeDataGeneration.current
        guard status.state == .running else {
            proxyGroups = []
            proxyGeoTask?.cancel()
            proxyGeoTask = nil
            return
        }

        do {
            let groups = try await controller.proxyGroups()
            guard runtimeDataGeneration.accepts(generation) else { return }
            proxyGroups = groups
            errorMessage = nil
        } catch {
            guard runtimeDataGeneration.accepts(generation) else { return }
            proxyGroups = []
            errorMessage = displayMessage(for: error)
        }

        guard runtimeDataGeneration.accepts(generation) else { return }
        applyCachedCountries()
        scheduleCountryDetection(generation: generation)
        refreshProfilePreview()
    }

    /// Re-parses the current profile YAML into a list of read-only proxy
    /// groups (`profilePreviewGroups`). Used by the Overview sidebar to
    /// render the user's configured nodes while mihomo is stopped. Failures
    /// are intentionally swallowed — there's no actionable error to surface
    /// for a missing or malformed `proxy-groups:` section, and the empty
    /// fallback already provides a clear UI state.
    func refreshProfilePreview() {
        guard let profileID = currentProfile?.id else {
            profilePreviewGroups = []
            return
        }
        guard let yaml = try? controller.profileContent(id: profileID) else {
            profilePreviewGroups = []
            return
        }
        guard let groups = try? ProfileNodeParser.parseProxyGroups(yaml: yaml) else {
            profilePreviewGroups = []
            return
        }
        profilePreviewGroups = groups
    }

    /// Reads cached `server → country` codes for every node in the current
    /// `proxyGroups` and writes them onto `detectedCountry` synchronously,
    /// so the UI shows known flags immediately without waiting on the
    /// async lookup task.
    private func applyCachedCountries() {
        guard let serverMap = currentProfileServerMap(), !serverMap.isEmpty else {
            return
        }
        let generation = runtimeDataGeneration.current
        Task { @MainActor [proxyGeoLookup] in
            var updates: [String: String] = [:]
            for server in Set(serverMap.values) {
                if let code = await proxyGeoLookup.cachedCountry(for: server) {
                    updates[server] = code
                }
            }
            guard !updates.isEmpty, self.runtimeDataGeneration.accepts(generation) else { return }
            self.writeBackCountries(serverMap: serverMap, codes: updates, generation: generation)
        }
    }

    /// Spawns a single async task that resolves country codes for every
    /// known node server in the current profile, deduplicating across nodes
    /// that share a server and writing the result back to `proxyGroups`.
    /// Re-entrancy is guarded by `proxyGeoTask` — calling this again while
    /// a previous lookup is still in flight cancels the previous task.
    private func scheduleCountryDetection(generation: UInt64) {
        proxyGeoTask?.cancel()
        guard let serverMap = currentProfileServerMap(), !serverMap.isEmpty else {
            return
        }
        let hosts = Array(Set(serverMap.values))
        let lookup = proxyGeoLookup
        proxyGeoTask = Task { @MainActor [weak self] in
            let codes = await lookup.countries(for: hosts)
            guard !Task.isCancelled,
                  let self,
                  self.runtimeDataGeneration.accepts(generation) else { return }
            self.writeBackCountries(serverMap: serverMap, codes: codes, generation: generation)
        }
    }

    private func writeBackCountries(
        serverMap: [String: String],
        codes: [String: String],
        generation: UInt64
    ) {
        guard !codes.isEmpty, runtimeDataGeneration.accepts(generation) else { return }
        var updated = proxyGroups
        var didChange = false
        for groupIndex in updated.indices {
            for proxyIndex in updated[groupIndex].proxies.indices {
                let proxyName = updated[groupIndex].proxies[proxyIndex].name
                guard let server = serverMap[proxyName] else { continue }
                guard let code = codes[server.lowercased()] ?? codes[server] else { continue }
                if updated[groupIndex].proxies[proxyIndex].detectedCountry != code {
                    updated[groupIndex].proxies[proxyIndex].detectedCountry = code
                    didChange = true
                }
            }
        }
        if didChange {
            proxyGroups = updated
        }
    }

    private func currentProfileServerMap() -> [String: String]? {
        guard let profileID = currentProfile?.id else { return nil }
        guard let yaml = try? controller.profileContent(id: profileID) else { return nil }
        guard let nodes = try? ProfileNodeParser.parseNodes(yaml: yaml) else { return nil }
        return nodes.mapValues(\.server)
    }

    func loadCoreConfiguration() async {
        let generation = runtimeDataGeneration.current
        guard status.state == .running else {
            let settings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
            coreConfiguration = CoreConfigurationSnapshot(
                mode: status.mode,
                mixedPort: settings.mixedPort,
                logLevel: settings.logLevel,
                allowLAN: settings.allowLAN,
                ipv6: settings.ipv6,
                geoData: settings.geoData,
                tunEnabled: settings.tun?.isEnabled ?? false,
                dnsEnabled: settings.dns?.isEnabled ?? false,
                snifferEnabled: settings.sniffer?.isEnabled ?? false,
                dns: settings.dns,
                sniffer: settings.sniffer
            )
            return
        }

        do {
            let configuration = try await controller.coreConfiguration()
            guard runtimeDataGeneration.accepts(generation) else { return }
            coreConfiguration = configuration
            errorMessage = nil
        } catch {
            guard runtimeDataGeneration.accepts(generation) else { return }
            errorMessage = displayMessage(for: error)
        }
    }

    func loadResources() async {
        let generation = runtimeDataGeneration.current
        guard status.state == .running else {
            proxyProviders = []
            ruleProviders = []
            return
        }

        do {
            async let nextProxyProviders = controller.proxyProviders()
            async let nextRuleProviders = controller.ruleProviders()
            let loadedProxyProviders = try await nextProxyProviders
            let loadedRuleProviders = try await nextRuleProviders
            guard runtimeDataGeneration.accepts(generation) else { return }
            proxyProviders = loadedProxyProviders
            ruleProviders = loadedRuleProviders
            errorMessage = nil
        } catch {
            guard runtimeDataGeneration.accepts(generation) else { return }
            errorMessage = displayMessage(for: error)
        }
    }

    func updateRuntimeSettings(_ settings: CoreRuntimeSettings) async {
        await performLoadingTask { [self] in
            let (_, didTransitionRuntime) = try await performRuntimeMutation {
                try await controller.updateRuntimeSettings(settings)
            }
            guard !didTransitionRuntime else { return }
            status.runtimeSettings = settings
            status.proxyPorts.mixedPort = settings.mixedPort
            coreConfiguration.mixedPort = settings.mixedPort
            coreConfiguration.logLevel = settings.logLevel
            coreConfiguration.allowLAN = settings.allowLAN
            coreConfiguration.ipv6 = settings.ipv6
            coreConfiguration.geoData = settings.geoData
            coreConfiguration.tunEnabled = settings.tun?.isEnabled ?? coreConfiguration.tunEnabled
        }
    }

    func setControllerSecret(_ secret: String) {
        Task { @MainActor in
            do {
                try await controller.setControllerSecret(secret)
                status.endpoint.secret = secret
                errorMessage = nil
            } catch {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func setRuleEnabled(_ rule: RuleEntry, isEnabled: Bool) async {
        await performLoadingTask { [self] in
            try await controller.setRuleEnabled(index: rule.index, isEnabled: isEnabled)
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index].isEnabled = isEnabled
            }
        }
    }

    func updateProxyProvider(_ provider: ProxyProviderEntry) async {
        await performLoadingTask { [self] in
            try await controller.updateProxyProvider(name: provider.name)
            await loadResources()
        }
    }

    func updateRuleProvider(_ provider: RuleProviderEntry) async {
        await performLoadingTask { [self] in
            try await controller.updateRuleProvider(name: provider.name)
            await loadResources()
        }
    }

    func updateAllProviders() async {
        await performLoadingTask { [self] in
            for provider in proxyProviders {
                try await controller.updateProxyProvider(name: provider.name)
            }
            for provider in ruleProviders {
                try await controller.updateRuleProvider(name: provider.name)
            }
            await loadResources()
        }
    }

    func upgradeGeoData() async {
        await performLoadingTask { [self] in
            try await controller.upgradeGeoData()
        }
    }

    func selectProxy(group: ProxyGroup, proxy: ProxyNode) async {
        await performLoadingTask { [self] in
            try await self.controller.selectProxy(group: group.name, name: proxy.name)
            await self.loadProxyGroups()
        }
    }

    func testDelay(for group: ProxyGroup) async {
        let generation = runtimeDataGeneration.current
        let originalNodeNames = group.proxies.map(\.name)
        isTestingDelay = true
        defer {
            if runtimeDataGeneration.accepts(generation) {
                isTestingDelay = false
            }
        }

        do {
            let nodes = try await controller.testGroupDelay(group: group)
            guard runtimeDataGeneration.accepts(generation) else { return }
            if let index = proxyGroups.firstIndex(where: {
                $0.id == group.id && $0.proxies.map(\.name) == originalNodeNames
            }) {
                proxyGroups[index].proxies = nodes
            }
            errorMessage = nil
        } catch {
            guard runtimeDataGeneration.accepts(generation) else { return }
            errorMessage = displayMessage(for: error)
        }
    }
}
