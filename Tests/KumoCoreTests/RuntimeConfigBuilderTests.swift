import CryptoKit
import XCTest
import Yams
@testable import KumoCoreKit

final class RuntimeConfigBuilderTests: XCTestCase {
    func testBuildReturnsDigestOfExactGeneratedConfiguration() throws {
        let profile = Profile(
            name: "Digest",
            source: .inline,
            rawYAML: "proxies: []\nrules:\n  - MATCH,DIRECT\n"
        )

        let runtime = try RuntimeConfigBuilder().build(profile: profile)
        let expected = SHA256.hash(data: Data(runtime.yaml.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(runtime.configurationDigest, expected)
    }

    func testBuildRejectsScalarProfileInsteadOfSilentlyBuildingEmptyRuntime() throws {
        let profile = Profile(
            name: "Encoded Subscription",
            source: .inline,
            rawYAML: Data("vless://example".utf8).base64EncodedString()
        )

        XCTAssertThrowsError(try RuntimeConfigBuilder().build(profile: profile))
    }

    func testBuildAppendsControlledRuntimeSettings() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            proxies: []
            rules:
              - MATCH,DIRECT
            """
        )
        let builder = RuntimeConfigBuilder(
            endpoint: ControllerEndpoint(port: 19097, secret: "secret"),
            proxyPorts: ProxyPortConfiguration(mixedPort: 17890),
            mode: .global
        )

        let runtime = try builder.build(profile: profile)
        let mapping = try yamlMapping(runtime.yaml)

        XCTAssertEqual(mapping["external-controller"] as? String, "127.0.0.1:19097")
        XCTAssertEqual(mapping["mixed-port"] as? Int, 17890)
        XCTAssertEqual(mapping["mode"] as? String, "global")
        XCTAssertEqual(mapping["secret"] as? String, "secret")
        XCTAssertEqual(mapping["find-process-mode"] as? String, "always")
    }

    func testBuildReplacesProfileRuntimeSettingsWithControlledSettings() throws {
        let profile = Profile(
            name: "Remote",
            source: .inline,
            rawYAML: """
            port: 47890
            socks-port: 47891
            redir-port: 47892
            tproxy-port: 47893
            mixed-port: 7890
            allow-lan: true
            mode: rule
            log-level: debug
            find-process-mode: off
            external-controller: 127.0.0.1:9090
            secret: "remote-secret"
            proxies: []
            proxy-groups:
              - name: Proxy
                type: select
                proxies:
                  - DIRECT
            rules:
              - MATCH,DIRECT
            """
        )
        let builder = RuntimeConfigBuilder(
            endpoint: ControllerEndpoint(port: 19097, secret: "local-secret"),
            proxyPorts: ProxyPortConfiguration(mixedPort: 17890),
            mode: .global
        )

        let runtime = try builder.build(profile: profile)
        let mapping = try yamlMapping(runtime.yaml)

        XCTAssertFalse(runtime.yaml.contains("port: 47890"))
        XCTAssertFalse(runtime.yaml.contains("socks-port: 47891"))
        XCTAssertFalse(runtime.yaml.contains("redir-port: 47892"))
        XCTAssertFalse(runtime.yaml.contains("tproxy-port: 47893"))
        XCTAssertFalse(runtime.yaml.contains("mixed-port: 7890"))
        XCTAssertFalse(runtime.yaml.contains("allow-lan: true"))
        XCTAssertFalse(runtime.yaml.contains("mode: rule"))
        XCTAssertFalse(runtime.yaml.contains("log-level: debug"))
        XCTAssertFalse(runtime.yaml.contains("find-process-mode: off"))
        XCTAssertFalse(runtime.yaml.contains("external-controller: 127.0.0.1:9090"))
        XCTAssertFalse(runtime.yaml.contains("secret: \"remote-secret\""))
        XCTAssertEqual(mapping["mixed-port"] as? Int, 17890)
        XCTAssertEqual(mapping["allow-lan"] as? Bool, false)
        XCTAssertEqual(mapping["mode"] as? String, "global")
        XCTAssertEqual(mapping["log-level"] as? String, "info")
        XCTAssertEqual(mapping["find-process-mode"] as? String, "always")
        XCTAssertEqual(mapping["external-controller"] as? String, "127.0.0.1:19097")
        XCTAssertEqual(mapping["secret"] as? String, "local-secret")
        XCTAssertTrue(runtime.yaml.contains("proxy-groups:"))
    }

    func testBuildIncludesRuntimeSettingsAndOverridesBeforeControlledKeys() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            mixed-port: 7890
            rules:
              - MATCH,DIRECT
            """
        )
        let settings = CoreRuntimeSettings(
            mixedPort: 19090,
            allowLAN: true,
            logLevel: "debug",
            ipv6: true,
            findProcessMode: "strict",
            geoData: GeoDataSettings(
                geoIPURL: "https://example.com/geoip.dat",
                geoSiteURL: "https://example.com/geosite.dat",
                mmdbURL: "https://example.com/mmdb",
                asnURL: "https://example.com/asn",
                autoUpdate: true,
                updateIntervalHours: 12,
                usesDatMode: true
            )
        )
        let builder = RuntimeConfigBuilder(runtimeSettings: settings)

        let runtime = try builder.build(profile: profile, overrideYAMLs: ["proxy-groups: []"])

        XCTAssertTrue(runtime.yaml.contains("proxy-groups: []"))
        XCTAssertTrue(runtime.yaml.contains("mixed-port: 19090"))
        XCTAssertTrue(runtime.yaml.contains("allow-lan: true"))
        XCTAssertTrue(runtime.yaml.contains("log-level: debug"))
        XCTAssertTrue(runtime.yaml.contains("ipv6: true"))
        XCTAssertTrue(runtime.yaml.contains("find-process-mode: strict"))
        XCTAssertTrue(runtime.yaml.contains("geo-auto-update: true"))
        XCTAssertTrue(runtime.yaml.contains("geo-update-interval: 12"))
        XCTAssertFalse(runtime.yaml.contains("mixed-port: 7890"))
    }

    func testOverridesReplaceEarlierTopLevelBlocks() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            proxies:
              - name: old
                type: direct
            rules:
              - MATCH,DIRECT
            """
        )
        let builder = RuntimeConfigBuilder()

        let runtime = try builder.build(
            profile: profile,
            overrideYAMLs: [
                """
                proxies:
                  - name: replacement
                    type: direct
                """
            ]
        )

        XCTAssertFalse(runtime.yaml.contains("name: old"))
        XCTAssertTrue(runtime.yaml.contains("name: replacement"))
        XCTAssertTrue(runtime.yaml.contains("rules:"))
    }

    func testOverridesAppendAndPrependRulesWithSparkleOperators() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            rules:
              - DOMAIN-SUFFIX,base.example,Proxy
            """
        )
        let builder = RuntimeConfigBuilder()

        let runtime = try builder.build(
            profile: profile,
            overrideYAMLs: [
                """
                rules+:
                  - MATCH,DIRECT
                """,
                """
                +rules:
                  - DOMAIN-SUFFIX,first.example,DIRECT
                """
            ]
        )

        XCTAssertLineOrder(
            runtime.yaml,
            [
                "DOMAIN-SUFFIX,first.example,DIRECT",
                "DOMAIN-SUFFIX,base.example,Proxy",
                "MATCH,DIRECT"
            ]
        )
        XCTAssertFalse(runtime.yaml.contains("rules+:"))
        XCTAssertFalse(runtime.yaml.contains("+rules:"))
    }

    func testOverridesApplyVergeStyleRuleSequenceOperators() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            rules:
              - DOMAIN-SUFFIX,remove.example,Proxy
              - DOMAIN-SUFFIX,base.example,Proxy
            """
        )
        let builder = RuntimeConfigBuilder()

        let runtime = try builder.build(
            profile: profile,
            overrideYAMLs: [
                """
                prepend-rules:
                  - DOMAIN-SUFFIX,first.example,DIRECT
                append-rules:
                  - MATCH,DIRECT
                delete-rules:
                  - DOMAIN-SUFFIX,remove.example,Proxy
                """
            ]
        )

        XCTAssertLineOrder(
            runtime.yaml,
            [
                "DOMAIN-SUFFIX,first.example,DIRECT",
                "DOMAIN-SUFFIX,base.example,Proxy",
                "MATCH,DIRECT"
            ]
        )
        XCTAssertFalse(runtime.yaml.contains("remove.example"))
        XCTAssertFalse(runtime.yaml.contains("prepend-rules:"))
        XCTAssertFalse(runtime.yaml.contains("append-rules:"))
        XCTAssertFalse(runtime.yaml.contains("delete-rules:"))
    }

    func testOverridesDeepMergeNestedMappings() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            sniffer:
              enable: true
              sniff:
                HTTP:
                  ports:
                    - 80
            """
        )
        let builder = RuntimeConfigBuilder()

        let runtime = try builder.build(
            profile: profile,
            overrideYAMLs: [
                """
                sniffer:
                  sniff:
                    TLS:
                      ports:
                        - 443
                """
            ]
        )

        XCTAssertTrue(runtime.yaml.contains("enable: true"))
        XCTAssertTrue(runtime.yaml.contains("HTTP:"))
        XCTAssertTrue(runtime.yaml.contains("TLS:"))
        XCTAssertTrue(runtime.yaml.contains("- 80"))
        XCTAssertTrue(runtime.yaml.contains("- 443"))
    }

    func testBangOverrideReplacesNestedMapping() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            sniffer:
              enable: true
              sniff:
                HTTP:
                  ports:
                    - 80
            """
        )
        let builder = RuntimeConfigBuilder()

        let runtime = try builder.build(
            profile: profile,
            overrideYAMLs: [
                """
                sniffer!:
                  enable: false
                """
            ]
        )

        XCTAssertTrue(runtime.yaml.contains("enable: false"))
        XCTAssertFalse(runtime.yaml.contains("HTTP:"))
        XCTAssertFalse(runtime.yaml.contains("- 80"))
    }

    func testBuildInjectsControlledTunAndDNSWhenEnabled() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            tun:
              enable: false
            dns:
              enable: false
            rules:
              - MATCH,DIRECT
            """
        )
        let settings = CoreRuntimeSettings(
            mixedPort: 19090,
            tun: TunSettings(
                isEnabled: true,
                stack: "mixed",
                disableICMPForwarding: true,
                dnsHijack: ["any:53"],
                routeExcludeAddress: ["100.64.0.0/10"],
                device: "utun9"
            ),
            dns: DnsSettings(
                isEnabled: true,
                nameserver: ["https://example.com/dns-query"]
            )
        )
        let builder = RuntimeConfigBuilder(runtimeSettings: settings)

        let runtime = try builder.build(profile: profile)
        let mapping = try yamlMapping(runtime.yaml)
        let tun = try XCTUnwrap(mapping["tun"] as? [String: Any])
        let dns = try XCTUnwrap(mapping["dns"] as? [String: Any])

        XCTAssertEqual(tun["enable"] as? Bool, true)
        XCTAssertEqual(tun["stack"] as? String, "mixed")
        XCTAssertEqual(tun["disable-icmp-forwarding"] as? Bool, true)
        XCTAssertEqual(tun["dns-hijack"] as? [String], ["any:53"])
        XCTAssertEqual(tun["route-exclude-address"] as? [String], ["100.64.0.0/10"])
        XCTAssertEqual(tun["device"] as? String, "utun9")
        XCTAssertEqual(dns["enable"] as? Bool, true)
        XCTAssertEqual(dns["nameserver"] as? [String], ["https://example.com/dns-query"])
        XCTAssertFalse(runtime.yaml.contains("tun:\n  enable: false"))
    }

    func testBuildPreservesProfileTunWhenKumoTunIsDisabled() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            tun:
              enable: true
            rules:
              - MATCH,DIRECT
            """
        )
        let builder = RuntimeConfigBuilder(runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false)))

        let runtime = try builder.build(profile: profile)

        XCTAssertTrue(runtime.yaml.contains("tun:\n  enable: true"))
    }

    func testPrivilegedRuntimeStripsUnmanagedFeatureBlocksWhenDisabled() throws {
        let profile = Profile(
            name: "Remote",
            source: .remote(URL(string: "https://example.com/subscription")!),
            rawYAML: """
            tun:
              enable: true
            dns:
              enable: true
              listen: 0.0.0.0:53
            listeners:
              - name: exposed
                type: mixed
                port: 80
                listen: 0.0.0.0
            sniffer:
              enable: true
            hosts:
              attacker.example: 127.0.0.1
            rules:
              - MATCH,DIRECT
            """
        )
        let builder = RuntimeConfigBuilder(
            runtimeSettings: CoreRuntimeSettings(
                tun: TunSettings(isEnabled: false),
                dns: DnsSettings(isEnabled: false),
                sniffer: SnifferSettings(isEnabled: false)
            ),
            enforceManagedFeatureSettings: true
        )

        let runtime = try builder.build(profile: profile)

        XCTAssertFalse(runtime.yaml.contains("tun:"))
        XCTAssertFalse(runtime.yaml.contains("dns:"))
        XCTAssertFalse(runtime.yaml.contains("listeners:"))
        XCTAssertFalse(runtime.yaml.contains("sniffer:"))
        XCTAssertFalse(runtime.yaml.contains("attacker.example"))
    }

    func testRuntimeOwnsEveryControllerAndExternalUITopLevelKey() throws {
        let profile = Profile(
            name: "Remote",
            source: .inline,
            rawYAML: """
            external-controller: 0.0.0.0:9090
            external-controller-cors: {allow-origins: ['*']}
            external-controller-pipe: malicious
            external-controller-tls: 0.0.0.0:9443
            external-controller-unix: /tmp/malicious.sock
            external-doh-server: /dns-query
            external-ui: /var/root/ui
            external-ui-name: malicious
            external-ui-url: https://attacker.example/ui.zip
            tls: {certificate: /etc/passwd, private-key: /etc/master.passwd}
            secret: attacker
            rules: [MATCH,DIRECT]
            """
        )
        let runtime = try RuntimeConfigBuilder(
            endpoint: ControllerEndpoint(port: 19097, secret: "kumo"),
            enforceManagedFeatureSettings: true
        ).build(
            profile: profile,
            overrideYAMLs: [
                "external-controller-unix: /tmp/override.sock\nexternal-ui: /tmp/override-ui"
            ]
        )
        let mapping = try yamlMapping(runtime.yaml)

        XCTAssertEqual(mapping["external-controller"] as? String, "127.0.0.1:19097")
        XCTAssertEqual(mapping["secret"] as? String, "kumo")
        for key in [
            "external-controller-cors", "external-controller-pipe", "external-controller-tls",
            "external-controller-unix", "external-doh-server", "external-ui", "external-ui-name",
            "external-ui-url", "tls"
        ] {
            XCTAssertNil(mapping[key], "Kumo must remove profile-controlled \(key)")
        }
    }

    func testStructuredControlledSettingsCannotInjectTopLevelYAML() throws {
        let injectedRange = "198.18.0.1/16\nexternal-controller-unix: /tmp/pwn.sock"
        let injectedHostKey = "safe.example\nexternal-ui-url: https://attacker.example/ui.zip"
        let settings = CoreRuntimeSettings(
            dns: DnsSettings(
                isEnabled: true,
                fakeIPRange: injectedRange,
                hosts: [injectedHostKey: .single("127.0.0.1\nlisteners: injected")]
            )
        )
        let runtime = try RuntimeConfigBuilder(
            runtimeSettings: settings,
            enforceManagedFeatureSettings: true
        ).build(profile: Profile(name: "Safe", source: .inline, rawYAML: "rules: [MATCH,DIRECT]"))
        let mapping = try yamlMapping(runtime.yaml)
        let dns = try XCTUnwrap(mapping["dns"] as? [String: Any])
        let hosts = try XCTUnwrap(mapping["hosts"] as? [String: Any])

        XCTAssertEqual(dns["fake-ip-range"] as? String, injectedRange)
        XCTAssertEqual(hosts[injectedHostKey] as? String, "127.0.0.1\nlisteners: injected")
        XCTAssertNil(mapping["external-controller-unix"])
        XCTAssertNil(mapping["external-ui-url"])
        XCTAssertNil(mapping["listeners"])
    }

    func testPrivilegedRuntimeRejectsUnsafeListenerSettings() throws {
        let profile = Profile(name: "Safe", source: .inline, rawYAML: "rules: [MATCH,DIRECT]")

        XCTAssertThrowsError(try RuntimeConfigBuilder(
            endpoint: ControllerEndpoint(host: "0.0.0.0", port: 9097),
            enforceManagedFeatureSettings: true
        ).build(profile: profile))
        XCTAssertThrowsError(try RuntimeConfigBuilder(
            endpoint: ControllerEndpoint(port: 443),
            enforceManagedFeatureSettings: true
        ).build(profile: profile))
        XCTAssertThrowsError(try RuntimeConfigBuilder(
            runtimeSettings: CoreRuntimeSettings(
                dns: DnsSettings(isEnabled: true, listen: "0.0.0.0:53")
            ),
            enforceManagedFeatureSettings: true
        ).build(profile: profile))
    }

    func testPrivilegedRuntimeRewritesRemoteProviderStorageAndRejectsLocalFiles() throws {
        let remote = Profile(
            name: "Remote",
            source: .inline,
            rawYAML: """
            proxy-providers:
              remote:
                type: http
                url: https://example.com/subscription.yaml
                path: ../../outside.yaml
            proxy-groups:
              - {name: Proxy, type: select, use: [remote]}
            rules: [MATCH,Proxy]
            """
        )
        let builder = RuntimeConfigBuilder(enforceManagedFeatureSettings: true)
        let runtime = try builder.build(profile: remote, profileID: "remote-profile")
        let providers = try XCTUnwrap(try yamlMapping(runtime.yaml)["proxy-providers"] as? [String: Any])
        let provider = try XCTUnwrap(providers["remote"] as? [String: Any])

        let path = try XCTUnwrap(provider["path"] as? String)
        XCTAssertTrue(path.hasPrefix("./providers/proxy/"))
        XCTAssertTrue(path.hasSuffix(".yaml"))
        XCTAssertFalse(path.contains("outside"))

        let local = Profile(
            name: "Local",
            source: .inline,
            rawYAML: """
            proxy-providers:
              local: {type: file, path: /etc/passwd}
            rules: [MATCH,DIRECT]
            """
        )
        XCTAssertThrowsError(try builder.build(profile: local))
    }

    func testHTTPProviderStorageIsStableAndIsolatedAcrossProfilesInEveryRuntimeMode() throws {
        let fixedProfileUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let profile = Profile(
            id: fixedProfileUUID,
            name: "Remote",
            source: .inline,
            rawYAML: remoteProviderProfileYAML(
                proxyURL: "https://example.com/proxies.yaml",
                ruleURL: "https://example.com/rules.yaml"
            )
        )
        let otherProfile = Profile(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            name: "Other",
            source: .inline,
            rawYAML: profile.rawYAML
        )

        for privileged in [false, true] {
            let builder = RuntimeConfigBuilder(enforceManagedFeatureSettings: privileged)
            let first = try providerPaths(
                in: builder.build(profile: profile, profileID: "profile-a").yaml
            )
            let repeated = try providerPaths(
                in: builder.build(profile: profile, profileID: "profile-a").yaml
            )
            let other = try providerPaths(
                in: builder.build(profile: otherProfile, profileID: "profile-b").yaml
            )

            XCTAssertEqual(first.proxy, repeated.proxy, "Proxy provider cache paths must be stable.")
            XCTAssertEqual(first.rule, repeated.rule, "Rule provider cache paths must be stable.")
            XCTAssertNotEqual(first.proxy, other.proxy, "Proxy provider caches must be profile-scoped.")
            XCTAssertNotEqual(first.rule, other.rule, "Rule provider caches must be profile-scoped.")
            XCTAssertTrue(first.proxy.hasPrefix("./providers/proxy/"))
            XCTAssertTrue(first.rule.hasPrefix("./providers/rule/"))
            XCTAssertFalse(first.proxy.contains(".."))
            XCTAssertFalse(first.rule.contains(".."))
        }
    }

    func testHTTPProviderStorageChangesWhenProviderKeyOrURLChanges() throws {
        let profileID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let original = Profile(
            id: profileID,
            name: "Original",
            source: .inline,
            rawYAML: remoteProviderProfileYAML(
                proxyKey: "shared",
                proxyURL: "https://example.com/proxies-a.yaml",
                ruleURL: "https://example.com/rules-a.yaml"
            )
        )
        let updatedURL = Profile(
            id: profileID,
            name: "Updated URL",
            source: .inline,
            rawYAML: remoteProviderProfileYAML(
                proxyKey: "shared",
                proxyURL: "https://example.com/proxies-b.yaml",
                ruleURL: "https://example.com/rules-b.yaml"
            )
        )
        let updatedKey = Profile(
            id: profileID,
            name: "Updated Key",
            source: .inline,
            rawYAML: remoteProviderProfileYAML(
                proxyKey: "renamed",
                proxyURL: "https://example.com/proxies-a.yaml",
                ruleURL: "https://example.com/rules-a.yaml"
            )
        )

        for privileged in [false, true] {
            let builder = RuntimeConfigBuilder(enforceManagedFeatureSettings: privileged)
            let originalPaths = try providerPaths(
                in: builder.build(profile: original, profileID: "profile-a").yaml,
                proxyKey: "shared"
            )
            let updatedURLPaths = try providerPaths(
                in: builder.build(profile: updatedURL, profileID: "profile-a").yaml,
                proxyKey: "shared"
            )
            let updatedKeyPaths = try providerPaths(
                in: builder.build(profile: updatedKey, profileID: "profile-a").yaml,
                proxyKey: "renamed"
            )

            XCTAssertNotEqual(originalPaths.proxy, updatedURLPaths.proxy)
            XCTAssertNotEqual(originalPaths.rule, updatedURLPaths.rule)
            XCTAssertNotEqual(originalPaths.proxy, updatedKeyPaths.proxy)
        }
    }

    func testPrivilegedRuntimeRejectsFileBackedProxyCredentials() {
        let profile = Profile(
            name: "SSH",
            source: .inline,
            rawYAML: """
            proxies:
              - name: SSH
                type: ssh
                server: example.com
                port: 22
                username: root
                private-key: /var/root/.ssh/id_ed25519
            rules: [MATCH,SSH]
            """
        )

        XCTAssertThrowsError(
            try RuntimeConfigBuilder(enforceManagedFeatureSettings: true).build(profile: profile)
        )
    }

    func testTunSettingsDecodesMissingNewFieldsWithDefaults() throws {
        let data = Data(
            """
            {
              "isEnabled": true,
              "stack": "mixed",
              "autoRoute": true,
              "autoDetectInterface": true,
              "strictRoute": false,
              "dnsHijack": ["any:53"],
              "routeExcludeAddress": [],
              "mtu": 1500
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(TunSettings.self, from: data)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.autoRedirect)
        XCTAssertFalse(settings.disableICMPForwarding)
        XCTAssertEqual(settings.dnsHijack, ["any:53"])
    }

    func testBuildInjectsFullDnsSettingsWhenEnabled() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            rules:
              - MATCH,DIRECT
            """
        )
        let settings = CoreRuntimeSettings(
            mixedPort: 19090,
            dns: DnsSettings(
                isEnabled: true,
                listen: "0.0.0.0:53",
                ipv6: true,
                ipv6Timeout: 200,
                preferH3: true,
                enhancedMode: "fake-ip",
                fakeIPRange: "198.18.0.1/16",
                fakeIPRange6: "fc00::/18",
                fakeIPFilter: ["+.lan"],
                fakeIPFilterMode: "blacklist",
                useHosts: true,
                useSystemHosts: true,
                respectRules: true,
                defaultNameserver: ["223.5.5.5"],
                nameserver: ["https://doh.pub/dns-query"],
                fallback: ["https://1.1.1.1/dns-query"],
                fallbackFilter: ["geoip": .bool(true), "geoip-code": .single("CN"), "ipcidr": .multiple(["100.100.100.100/32"])],
                proxyServerNameserver: ["https://dns.alidns.com/dns-query"],
                directNameserver: ["https://dns.alidns.com/dns-query"],
                directNameserverFollowPolicy: true,
                nameserverPolicy: ["geosite:cn": .single("223.5.5.5")],
                proxyServerNameserverPolicy: ["geosite:cn": .single("https://dns.alidns.com/dns-query")],
                cacheAlgorithm: "arc",
                hosts: ["localhost": .single("127.0.0.1")]
            ),
            sniffer: SnifferSettings(
                isEnabled: true,
                httpOverrideDestination: true,
                httpPorts: [80, 8080],
                tlsPorts: [443, 8443],
                quicPorts: [443]
            )
        )
        let builder = RuntimeConfigBuilder(runtimeSettings: settings)

        let runtime = try builder.build(profile: profile)
        let mapping = try yamlMapping(runtime.yaml)
        let dns = try XCTUnwrap(mapping["dns"] as? [String: Any])
        let hosts = try XCTUnwrap(mapping["hosts"] as? [String: Any])
        let sniffer = try XCTUnwrap(mapping["sniffer"] as? [String: Any])
        let sniff = try XCTUnwrap(sniffer["sniff"] as? [String: Any])
        let http = try XCTUnwrap(sniff["HTTP"] as? [String: Any])
        let tls = try XCTUnwrap(sniff["TLS"] as? [String: Any])
        let quic = try XCTUnwrap(sniff["QUIC"] as? [String: Any])

        // DNS assertions
        XCTAssertEqual(dns["enable"] as? Bool, true)
        XCTAssertEqual(dns["listen"] as? String, "0.0.0.0:53")
        XCTAssertEqual(dns["ipv6"] as? Bool, true)
        XCTAssertEqual(dns["ipv6-timeout"] as? Int, 200)
        XCTAssertEqual(dns["prefer-h3"] as? Bool, true)
        XCTAssertEqual(dns["fake-ip-filter-mode"] as? String, "blacklist")
        XCTAssertEqual(dns["use-hosts"] as? Bool, true)
        XCTAssertEqual(dns["use-system-hosts"] as? Bool, true)
        XCTAssertEqual(dns["respect-rules"] as? Bool, true)
        XCTAssertEqual(dns["fallback"] as? [String], ["https://1.1.1.1/dns-query"])
        let fallbackFilter = try XCTUnwrap(dns["fallback-filter"] as? [String: Any])
        XCTAssertEqual(fallbackFilter["geoip"] as? Bool, true)
        XCTAssertEqual(fallbackFilter["geoip-code"] as? String, "CN")
        XCTAssertEqual(fallbackFilter["ipcidr"] as? [String], ["100.100.100.100/32"])
        XCTAssertEqual(dns["direct-nameserver-follow-policy"] as? Bool, true)
        XCTAssertEqual((dns["nameserver-policy"] as? [String: Any])?["geosite:cn"] as? String, "223.5.5.5")
        XCTAssertEqual(
            (dns["proxy-server-nameserver-policy"] as? [String: Any])?["geosite:cn"] as? String,
            "https://dns.alidns.com/dns-query"
        )
        XCTAssertEqual(dns["cache-algorithm"] as? String, "arc")
        XCTAssertEqual(hosts["localhost"] as? String, "127.0.0.1")

        // Sniffer assertions
        XCTAssertEqual(sniffer["enable"] as? Bool, true)
        XCTAssertEqual(http["override-destination"] as? Bool, true)
        XCTAssertEqual(http["ports"] as? [Int], [80, 8080])
        XCTAssertEqual(tls["ports"] as? [Int], [443, 8443])
        XCTAssertEqual(quic["ports"] as? [Int], [443])
    }

    func testSnifferHTTPOverrideDestinationWithoutPorts() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            rules:
              - MATCH,DIRECT
            """
        )
        let settings = CoreRuntimeSettings(
            sniffer: SnifferSettings(
                isEnabled: true,
                httpOverrideDestination: true,
                httpPorts: [],
                tlsPorts: [443]
            )
        )
        let builder = RuntimeConfigBuilder(runtimeSettings: settings)

        let runtime = try builder.build(profile: profile)

        XCTAssertTrue(runtime.yaml.contains("sniff:"))
        XCTAssertTrue(runtime.yaml.contains("HTTP:"))
        XCTAssertTrue(runtime.yaml.contains("override-destination: true"))
        XCTAssertFalse(runtime.yaml.contains("HTTP:\n      ports:"))
        XCTAssertTrue(runtime.yaml.contains("TLS:\n      ports:"))
    }

    func testRuntimeSettingsDecodesMissingFindProcessModeWithDefault() throws {
        let data = Data(
            """
            {
              "mixedPort": 7890,
              "allowLAN": false,
              "logLevel": "info",
              "ipv6": false,
              "geoData": {
                "geoIPURL": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-lite.dat",
                "geoSiteURL": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat",
                "mmdbURL": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb",
                "asnURL": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb",
                "autoUpdate": false,
                "updateIntervalHours": 24,
                "usesDatMode": false
              }
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(CoreRuntimeSettings.self, from: data)

        XCTAssertEqual(settings.findProcessMode, "always")
    }

    private func XCTAssertLineOrder(
        _ yaml: String,
        _ fragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = yaml.startIndex
        for fragment in fragments {
            guard let range = yaml.range(of: fragment, range: lowerBound..<yaml.endIndex) else {
                XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
    }

    private func yamlMapping(_ yaml: String) throws -> [String: Any] {
        try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
    }

    private func remoteProviderProfileYAML(
        proxyKey: String = "shared",
        proxyURL: String,
        ruleURL: String
    ) -> String {
        """
        proxy-providers:
          \(proxyKey):
            type: http
            url: \(proxyURL)
            path: ../../shared-proxies.yaml
        rule-providers:
          shared-rules:
            type: http
            behavior: domain
            format: yaml
            url: \(ruleURL)
            path: ../../shared-rules.yaml
        proxy-groups:
          - {name: Proxy, type: select, use: [\(proxyKey)]}
        rules:
          - RULE-SET,shared-rules,Proxy
          - MATCH,DIRECT
        """
    }

    private func providerPaths(
        in yaml: String,
        proxyKey: String = "shared"
    ) throws -> (proxy: String, rule: String) {
        let mapping = try yamlMapping(yaml)
        let proxyProviders = try XCTUnwrap(mapping["proxy-providers"] as? [String: Any])
        let proxyProvider = try XCTUnwrap(proxyProviders[proxyKey] as? [String: Any])
        let ruleProviders = try XCTUnwrap(mapping["rule-providers"] as? [String: Any])
        let ruleProvider = try XCTUnwrap(ruleProviders["shared-rules"] as? [String: Any])
        return (
            proxy: try XCTUnwrap(proxyProvider["path"] as? String),
            rule: try XCTUnwrap(ruleProvider["path"] as? String)
        )
    }
}
