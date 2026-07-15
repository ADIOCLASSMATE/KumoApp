import CryptoKit
import Foundation
import Yams

public struct RuntimeConfig: Equatable, Sendable {
    public var yaml: String
    public var endpoint: ControllerEndpoint
    public var proxyPorts: ProxyPortConfiguration
    public var configurationDigest: String
}

public struct RuntimeConfigBuilder: Sendable {
    private static let controlledTopLevelKeys: Set<String> = [
        "external-controller",
        "external-controller-cors",
        "external-controller-pipe",
        "external-controller-tls",
        "external-controller-unix",
        "external-doh-server",
        "external-ui",
        "external-ui-name",
        "external-ui-url",
        "secret",
        "tls",
        "port",
        "socks-port",
        "redir-port",
        "tproxy-port",
        "mixed-port",
        "mode",
        "allow-lan",
        "log-level",
        "ipv6",
        "find-process-mode",
        "geodata-mode",
        "geo-auto-update",
        "geo-update-interval",
        "geox-url"
    ]

    public var endpoint: ControllerEndpoint
    public var proxyPorts: ProxyPortConfiguration
    public var mode: OutboundMode
    public var runtimeSettings: CoreRuntimeSettings
    public var enforceManagedFeatureSettings: Bool

    public init(
        endpoint: ControllerEndpoint = ControllerEndpoint(),
        proxyPorts: ProxyPortConfiguration = ProxyPortConfiguration(),
        mode: OutboundMode = .rule,
        runtimeSettings: CoreRuntimeSettings = CoreRuntimeSettings(),
        enforceManagedFeatureSettings: Bool = false
    ) {
        var effectiveRuntimeSettings = runtimeSettings
        if effectiveRuntimeSettings.mixedPort == CoreRuntimeSettings().mixedPort {
            effectiveRuntimeSettings.mixedPort = proxyPorts.mixedPort
        }
        self.endpoint = endpoint
        self.proxyPorts = ProxyPortConfiguration(mixedPort: effectiveRuntimeSettings.mixedPort)
        self.mode = mode
        self.runtimeSettings = effectiveRuntimeSettings
        self.enforceManagedFeatureSettings = enforceManagedFeatureSettings
    }

    public func build(
        profile: Profile,
        profileID: String? = nil,
        overrideYAMLs: [String] = []
    ) throws -> RuntimeConfig {
        let yaml = try mergedRuntimeYAML(
            profileYAML: profile.rawYAML,
            profileID: profileID ?? profile.id.uuidString.lowercased(),
            overrideYAMLs: overrideYAMLs
        )

        return RuntimeConfig(
            yaml: yaml,
            endpoint: endpoint,
            proxyPorts: proxyPorts,
            configurationDigest: SHA256.hash(data: Data(yaml.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    public func write(
        profile: Profile,
        profileID: String? = nil,
        overrideYAMLs: [String] = [],
        to url: URL
    ) throws -> RuntimeConfig {
        let config = try build(
            profile: profile,
            profileID: profileID,
            overrideYAMLs: overrideYAMLs
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try config.yaml.data(using: .utf8)?.write(to: url, options: .atomic)
        return config
    }

    private func mergedRuntimeYAML(
        profileYAML: String,
        profileID: String,
        overrideYAMLs: [String]
    ) throws -> String {
        var document = try StructuredYAMLDocument(rawYAML: profileYAML)

        for overrideYAML in overrideYAMLs {
            try document.merge(StructuredYAMLDocument(rawYAML: overrideYAML))
        }

        if enforceManagedFeatureSettings {
            try document.restrictForPrivilegedRuntime(profileID: profileID)
        } else {
            try document.namespaceRemoteProviderStorage(profileID: profileID)
        }

        document.removeTopLevelKeys(controlledTopLevelKeys())
        document.replaceTopLevelValues(try controlledConfigMapping())
        return try document.renderedYAML()
    }

    private func controlledConfigMapping() throws -> [String: Any] {
        let controllerAddress = try validatedControllerAddress()
        let minimumPort = enforceManagedFeatureSettings ? 1_024 : 1
        guard (minimumPort...65_535).contains(runtimeSettings.mixedPort) else {
            throw KumoError.invalidArguments("The mixed proxy port is outside Kumo's allowed range.")
        }
        guard endpoint.secret.utf8.count <= 4_096,
              !endpoint.secret.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw KumoError.invalidArguments("The controller secret is invalid.")
        }
        let logLevel = try validatedEnum(
            runtimeSettings.logLevel,
            allowed: ["silent", "error", "warning", "info", "debug"],
            name: "log level"
        )
        let findProcessMode = try validatedEnum(
            runtimeSettings.findProcessMode,
            allowed: ["always", "strict", "off"],
            name: "process lookup mode"
        )
        guard (1...8_760).contains(runtimeSettings.geoData.updateIntervalHours) else {
            throw KumoError.invalidArguments("The geodata update interval is outside Kumo's allowed range.")
        }

        var mapping: [String: Any] = [
            "external-controller": controllerAddress,
            "secret": endpoint.secret,
            "mixed-port": runtimeSettings.mixedPort,
            "mode": mode.rawValue,
            "allow-lan": runtimeSettings.allowLAN,
            "log-level": logLevel,
            "ipv6": runtimeSettings.ipv6,
            "find-process-mode": findProcessMode,
            "geodata-mode": runtimeSettings.geoData.usesDatMode,
            "geo-auto-update": runtimeSettings.geoData.autoUpdate,
            "geo-update-interval": runtimeSettings.geoData.updateIntervalHours,
            "geox-url": [
                "geoip": try validatedRemoteURL(runtimeSettings.geoData.geoIPURL, name: "GeoIP URL"),
                "geosite": try validatedRemoteURL(runtimeSettings.geoData.geoSiteURL, name: "GeoSite URL"),
                "mmdb": try validatedRemoteURL(runtimeSettings.geoData.mmdbURL, name: "MMDB URL"),
                "asn": try validatedRemoteURL(runtimeSettings.geoData.asnURL, name: "ASN URL")
            ]
        ]

        if let tun = runtimeSettings.tun, tun.isEnabled {
            mapping["tun"] = try controlledTunMapping(tun)
        }

        if let dns = runtimeSettings.dns, dns.isEnabled {
            mapping["dns"] = try controlledDnsMapping(dns)
        }

        if let sniffer = runtimeSettings.sniffer, sniffer.isEnabled {
            mapping["sniffer"] = controlledSnifferMapping(sniffer)
        }

        if let dns = runtimeSettings.dns, !dns.hosts.isEmpty {
            mapping["hosts"] = policyMapping(dns.hosts)
        }

        return mapping
    }

    private func validatedControllerAddress() throws -> String {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let renderedHost: String
        switch host {
        case "127.0.0.1", "localhost":
            renderedHost = host
        case "::1", "[::1]":
            renderedHost = "[::1]"
        default:
            throw KumoError.invalidArguments("The Mihomo controller must listen on the local machine.")
        }
        let minimumPort = enforceManagedFeatureSettings ? 1_024 : 1
        guard (minimumPort...65_535).contains(endpoint.port) else {
            throw KumoError.invalidArguments("The Mihomo controller port is outside Kumo's allowed range.")
        }
        return "\(renderedHost):\(endpoint.port)"
    }

    private func validatedEnum(_ value: String, allowed: Set<String>, name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowed.contains(value) else {
            throw KumoError.invalidArguments("The \(name) is not supported by Kumo.")
        }
        return value
    }

    private func validatedRemoteURL(_ value: String, name: String) throws -> String {
        guard value.utf8.count <= 4_096,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw KumoError.invalidArguments("The \(name) must be an HTTP or HTTPS URL.")
        }
        return value
    }

    private func controlledTopLevelKeys() -> Set<String> {
        var keys = Self.controlledTopLevelKeys
        if enforceManagedFeatureSettings {
            keys.formUnion(["tun", "dns", "listeners", "sniffer", "hosts"])
            return keys
        }
        if runtimeSettings.tun?.isEnabled == true {
            keys.insert("tun")
        }
        if runtimeSettings.dns?.isEnabled == true {
            keys.insert("dns")
        }
        if runtimeSettings.sniffer?.isEnabled == true {
            keys.insert("sniffer")
        }
        if let dns = runtimeSettings.dns, !dns.hosts.isEmpty {
            keys.insert("hosts")
        }
        return keys
    }

    private func controlledTunMapping(_ tun: TunSettings) throws -> [String: Any] {
        let stack = try validatedEnum(
            tun.stack,
            allowed: ["mixed", "gvisor", "system"],
            name: "TUN stack"
        )
        guard (576...9_000).contains(tun.mtu) else {
            throw KumoError.invalidArguments("The TUN MTU is outside Kumo's allowed range.")
        }
        var mapping: [String: Any] = [
            "enable": true,
            "stack": stack,
            "auto-route": tun.autoRoute,
            "auto-redirect": tun.autoRedirect,
            "auto-detect-interface": tun.autoDetectInterface,
            "strict-route": tun.strictRoute,
            "disable-icmp-forwarding": tun.disableICMPForwarding,
            "dns-hijack": tun.dnsHijack,
            "mtu": tun.mtu
        ]
        if !tun.routeExcludeAddress.isEmpty {
            mapping["route-exclude-address"] = tun.routeExcludeAddress
        }
        if let device = normalizedTunDevice(tun.device) {
            mapping["device"] = device
        }
        return mapping
    }

    private func controlledDnsMapping(_ dns: DnsSettings) throws -> [String: Any] {
        let enhancedMode = try validatedEnum(
            dns.enhancedMode,
            allowed: ["fake-ip", "redir-host", "normal"],
            name: "DNS enhanced mode"
        )
        var mapping: [String: Any] = [
            "enable": dns.isEnabled,
            "ipv6": dns.ipv6,
            "enhanced-mode": enhancedMode,
            "fake-ip-range": dns.fakeIPRange,
            "ipv6-timeout": max(0, dns.ipv6Timeout),
            "prefer-h3": dns.preferH3,
            "use-hosts": dns.useHosts,
            "use-system-hosts": dns.useSystemHosts,
            "respect-rules": dns.respectRules,
            "direct-nameserver-follow-policy": dns.directNameserverFollowPolicy
        ]
        if !dns.listen.isEmpty {
            mapping["listen"] = try validatedDNSListenAddress(dns.listen)
        }
        if !dns.fakeIPRange6.isEmpty {
            mapping["fake-ip-range6"] = dns.fakeIPRange6
        }
        if !dns.fakeIPFilter.isEmpty {
            mapping["fake-ip-filter"] = dns.fakeIPFilter
        }
        if !dns.fakeIPFilterMode.isEmpty {
            mapping["fake-ip-filter-mode"] = try validatedEnum(
                dns.fakeIPFilterMode,
                allowed: ["blacklist", "whitelist"],
                name: "fake IP filter mode"
            )
        }
        if !dns.defaultNameserver.isEmpty {
            mapping["default-nameserver"] = dns.defaultNameserver
        }
        if !dns.nameserver.isEmpty {
            mapping["nameserver"] = dns.nameserver
        }
        if !dns.fallback.isEmpty {
            mapping["fallback"] = dns.fallback
        }
        if !dns.fallbackFilter.isEmpty {
            mapping["fallback-filter"] = fallbackFilterMapping(dns.fallbackFilter)
        }
        if !dns.proxyServerNameserver.isEmpty {
            mapping["proxy-server-nameserver"] = dns.proxyServerNameserver
        }
        if !dns.directNameserver.isEmpty {
            mapping["direct-nameserver"] = dns.directNameserver
        }
        if !dns.nameserverPolicy.isEmpty {
            mapping["nameserver-policy"] = policyMapping(dns.nameserverPolicy)
        }
        if !dns.proxyServerNameserverPolicy.isEmpty {
            mapping["proxy-server-nameserver-policy"] = policyMapping(dns.proxyServerNameserverPolicy)
        }
        if !dns.cacheAlgorithm.isEmpty {
            mapping["cache-algorithm"] = try validatedEnum(
                dns.cacheAlgorithm,
                allowed: ["lru", "arc"],
                name: "DNS cache algorithm"
            )
        }
        return mapping
    }

    private func validatedDNSListenAddress(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enforceManagedFeatureSettings else { return value }
        let host: String
        let portText: Substring
        if value.hasPrefix("[::1]:") {
            host = "[::1]"
            portText = value.dropFirst("[::1]:".count)
        } else if let separator = value.lastIndex(of: ":") {
            host = String(value[..<separator]).lowercased()
            portText = value[value.index(after: separator)...]
        } else {
            throw KumoError.invalidArguments("The privileged DNS listener must be loopback-only.")
        }
        guard ["127.0.0.1", "localhost", "[::1]"].contains(host),
              let port = Int(portText),
              (1_024...65_535).contains(port) else {
            throw KumoError.invalidArguments("The privileged DNS listener must use a loopback high port.")
        }
        return value
    }

    private func controlledSnifferMapping(_ sniffer: SnifferSettings) -> [String: Any] {
        var mapping: [String: Any] = [
            "enable": sniffer.isEnabled,
            "parse-pure-ip": sniffer.parsePureIP,
            "force-dns-mapping": sniffer.forceDNSMapping,
            "override-destination": sniffer.overrideDestination
        ]
        if !sniffer.httpPorts.isEmpty || !sniffer.tlsPorts.isEmpty || !sniffer.quicPorts.isEmpty || sniffer.httpOverrideDestination {
            var sniff: [String: Any] = [:]
            if !sniffer.httpPorts.isEmpty || sniffer.httpOverrideDestination {
                var http: [String: Any] = [:]
                if !sniffer.httpPorts.isEmpty {
                    http["ports"] = sniffer.httpPorts.filter { (1...65_535).contains($0) }
                }
                if sniffer.httpOverrideDestination {
                    http["override-destination"] = true
                }
                sniff["HTTP"] = http
            }
            if !sniffer.tlsPorts.isEmpty {
                sniff["TLS"] = ["ports": sniffer.tlsPorts.filter { (1...65_535).contains($0) }]
            }
            if !sniffer.quicPorts.isEmpty {
                sniff["QUIC"] = ["ports": sniffer.quicPorts.filter { (1...65_535).contains($0) }]
            }
            mapping["sniff"] = sniff
        }
        if !sniffer.skipDomain.isEmpty {
            mapping["skip-domain"] = sniffer.skipDomain
        }
        if !sniffer.forceDomain.isEmpty {
            mapping["force-domain"] = sniffer.forceDomain
        }
        if !sniffer.skipDstAddress.isEmpty {
            mapping["skip-dst-address"] = sniffer.skipDstAddress
        }
        if !sniffer.skipSrcAddress.isEmpty {
            mapping["skip-src-address"] = sniffer.skipSrcAddress
        }
        return mapping
    }

    private func policyMapping(_ values: [String: PolicyValue]) -> [String: Any] {
        values.mapValues { value in
            switch value {
            case .single(let value): value
            case .multiple(let values): values
            }
        }
    }

    private func fallbackFilterMapping(_ values: [String: FallbackFilterValue]) -> [String: Any] {
        values.mapValues { value in
            switch value {
            case .bool(let value): value
            case .single(let value): value
            case .multiple(let values): values
            }
        }
    }

    private func normalizedTunDevice(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        #if os(macOS)
        return value.hasPrefix("utun") ? value : nil
        #else
        return value
        #endif
    }
}

private struct StructuredYAMLDocument {
    private static let privilegedAllowedTopLevelKeys: Set<String> = [
        "proxies",
        "proxy-groups",
        "proxy-providers",
        "rules",
        "rule-providers",
        "sub-rules"
    ]

    private var mapping: [String: Any]

    init(rawYAML: String) throws {
        let trimmed = rawYAML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.mapping = [:]
            return
        }

        guard let loaded = try Yams.load(yaml: rawYAML) else {
            self.mapping = [:]
            return
        }

        guard let mapping = loaded as? [String: Any] else {
            throw KumoError.invalidArguments("The profile YAML root must be a mapping.")
        }
        self.mapping = mapping
    }

    mutating func merge(_ override: StructuredYAMLDocument) {
        mapping.mergeRuntimeOverride(override.mapping)
    }

    mutating func removeTopLevelKeys(_ keys: Set<String>) {
        for key in keys {
            mapping.removeValue(forKey: key)
        }
    }

    mutating func replaceTopLevelValues(_ values: [String: Any]) {
        for (key, value) in values {
            mapping[key] = value
        }
    }

    mutating func namespaceRemoteProviderStorage(profileID: String) throws {
        try rewriteHTTPProviderStorage(
            key: "proxy-providers",
            storageDirectory: "proxy",
            profileID: profileID
        )
        try rewriteHTTPProviderStorage(
            key: "rule-providers",
            storageDirectory: "rule",
            profileID: profileID
        )
    }

    mutating func restrictForPrivilegedRuntime(profileID: String) throws {
        mapping = mapping.filter { Self.privilegedAllowedTopLevelKeys.contains($0.key) }
        try sanitizeProviders(
            key: "proxy-providers",
            storageDirectory: "proxy",
            profileID: profileID
        )
        try sanitizeProviders(
            key: "rule-providers",
            storageDirectory: "rule",
            profileID: profileID
        )
        try rejectFileBackedProxyCredentials()
    }

    private mutating func rewriteHTTPProviderStorage(
        key: String,
        storageDirectory: String,
        profileID: String
    ) throws {
        guard let rawProviders = mapping[key] else { return }
        guard let providers = rawProviders as? [String: Any] else {
            throw KumoError.invalidArguments("The runtime requires a valid \(key) mapping.")
        }

        var rewritten = providers
        for entry in providers {
            guard var provider = entry.value as? [String: Any],
                  let rawType = provider["type"] as? String,
                  rawType.lowercased() == "http" else {
                continue
            }
            let rawURL = try validatedRemoteProviderURL(provider["url"], key: key)
            provider["path"] = try Self.providerStoragePath(
                profileID: profileID,
                providerKey: entry.key,
                providerURL: rawURL,
                storageDirectory: storageDirectory
            )
            rewritten[entry.key] = provider
        }
        mapping[key] = rewritten
    }

    private mutating func sanitizeProviders(
        key: String,
        storageDirectory: String,
        profileID: String
    ) throws {
        guard let rawProviders = mapping[key] else { return }
        guard let providers = rawProviders as? [String: Any] else {
            throw KumoError.invalidArguments("The privileged runtime requires a valid \(key) mapping.")
        }

        var sanitized: [String: Any] = [:]
        for entry in providers {
            guard var provider = entry.value as? [String: Any],
                  let rawType = provider["type"] as? String else {
                throw KumoError.invalidArguments("The privileged runtime requires typed \(key) entries.")
            }
            let type = rawType.lowercased()
            switch type {
            case "http":
                let rawURL = try validatedRemoteProviderURL(provider["url"], key: key)
                provider["path"] = try Self.providerStoragePath(
                    profileID: profileID,
                    providerKey: entry.key,
                    providerURL: rawURL,
                    storageDirectory: storageDirectory
                )
            case "inline":
                provider.removeValue(forKey: "path")
            case "file":
                throw KumoError.invalidArguments("Local file providers are not available in privileged mode.")
            default:
                throw KumoError.invalidArguments("The privileged runtime does not support this provider type.")
            }
            provider.removeValue(forKey: "path-in-bundle")
            provider.removeValue(forKey: "age-secret-key")
            sanitized[entry.key] = provider
        }
        mapping[key] = sanitized
    }

    private func validatedRemoteProviderURL(_ value: Any?, key: String) throws -> String {
        guard let rawURL = value as? String,
              rawURL.utf8.count <= 4_096,
              !rawURL.unicodeScalars.contains(where: { $0.value == 0 }),
              let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw KumoError.invalidArguments("The runtime requires remote \(key) URLs.")
        }
        return rawURL
    }

    private static func providerStoragePath(
        profileID: String,
        providerKey: String,
        providerURL: String,
        storageDirectory: String
    ) throws -> String {
        let profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileID.isEmpty,
              profileID.utf8.count <= 4_096,
              !profileID.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw KumoError.invalidArguments("The profile identifier cannot namespace provider storage.")
        }
        let profileNamespace = stableDigest(fields: ["profile", profileID])
        let providerIdentity = stableDigest(fields: ["provider", providerKey, providerURL])
        return "./providers/\(storageDirectory)/\(profileNamespace)/\(providerIdentity).yaml"
    }

    private static func stableDigest(fields: [String]) -> String {
        var hasher = SHA256()
        for field in fields {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { bytes in
                hasher.update(data: Data(bytes))
            }
            hasher.update(data: Data(field.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func rejectFileBackedProxyCredentials() throws {
        guard let rawProxies = mapping["proxies"] else { return }
        guard let proxies = rawProxies as? [Any] else {
            throw KumoError.invalidArguments("The privileged runtime requires a valid proxies sequence.")
        }
        let fileBackedKeys: Set<String> = [
            "certificate",
            "private-key",
            "private_key",
            "client-certificate",
            "client-key"
        ]
        for proxy in proxies {
            guard let proxy = proxy as? [String: Any] else {
                throw KumoError.invalidArguments("The privileged runtime requires valid proxy entries.")
            }
            if !fileBackedKeys.isDisjoint(with: proxy.keys) {
                throw KumoError.invalidArguments(
                    "File-backed proxy credentials are not available in privileged mode."
                )
            }
        }
    }

    func renderedYAML() throws -> String {
        guard !mapping.isEmpty else {
            return ""
        }

        return try Yams.dump(object: mapping)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Dictionary where Key == String, Value == Any {
    mutating func mergeRuntimeOverride(_ override: [String: Any]) {
        for (rawKey, overrideValue) in override {
            if applySequenceOperator(rawKey: rawKey, overrideValue: overrideValue) {
                continue
            }

            let key = Self.unwrappedKey(rawKey)
            if rawKey.hasSuffix("!") {
                self[key] = overrideValue
                continue
            }

            if var current = self[key] as? [String: Any],
               let nestedOverride = overrideValue as? [String: Any] {
                current.mergeRuntimeOverride(nestedOverride)
                self[key] = current
            } else {
                self[key] = overrideValue
            }
        }
    }

    private mutating func applySequenceOperator(rawKey: String, overrideValue: Any) -> Bool {
        if rawKey.hasPrefix("+"), let values = overrideValue as? [Any] {
            prepend(values, to: Self.unwrappedKey(String(rawKey.dropFirst())))
            return true
        }

        if rawKey.hasSuffix("+"), let values = overrideValue as? [Any] {
            append(values, to: Self.unwrappedKey(String(rawKey.dropLast())))
            return true
        }

        if rawKey.hasPrefix("prepend-"), let values = overrideValue as? [Any] {
            prepend(values, to: String(rawKey.dropFirst("prepend-".count)))
            return true
        }

        if rawKey.hasPrefix("append-"), let values = overrideValue as? [Any] {
            append(values, to: String(rawKey.dropFirst("append-".count)))
            return true
        }

        if rawKey.hasPrefix("delete-"), let values = overrideValue as? [Any] {
            delete(values, from: String(rawKey.dropFirst("delete-".count)))
            return true
        }

        return false
    }

    private mutating func prepend(_ values: [Any], to key: String) {
        let existing = self[key] as? [Any] ?? []
        self[key] = values + existing
    }

    private mutating func append(_ values: [Any], to key: String) {
        let existing = self[key] as? [Any] ?? []
        self[key] = existing + values
    }

    private mutating func delete(_ values: [Any], from key: String) {
        let namesToDelete = Set(values.compactMap(Self.sequenceItemName))
        guard !namesToDelete.isEmpty else {
            return
        }

        let existing = self[key] as? [Any] ?? []
        self[key] = existing.filter { item in
            guard let name = Self.sequenceItemName(item) else {
                return true
            }
            return !namesToDelete.contains(name)
        }
    }

    private static func sequenceItemName(_ value: Any) -> String? {
        if let value = value as? String {
            return value
        }
        if let mapping = value as? [String: Any],
           let name = mapping["name"] as? String {
            return name
        }
        return nil
    }

    private static func unwrappedKey(_ key: String) -> String {
        let key = key.hasSuffix("!") ? String(key.dropLast()) : key
        guard key.hasPrefix("<"), key.hasSuffix(">") else {
            return key
        }
        return String(key.dropFirst().dropLast())
    }
}
