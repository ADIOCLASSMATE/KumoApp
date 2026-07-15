import Foundation
import KumoCoreKit

@MainActor
extension KumoAppStore {
    func setSystemProxyEnabled(_ isEnabled: Bool) {
        guard status.state == .running || !isEnabled else {
            errorMessage = "Start Kumo before enabling System Proxy."
            return
        }

        Task { @MainActor in
            do {
                _ = try await controller.setSystemProxy(isEnabled)
                status.systemProxyEnabled = isEnabled
                errorMessage = nil
            } catch {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func updateSystemProxySettings(_ settings: SystemProxySettings) {
        Task { @MainActor in
            do {
                try await controller.updateSystemProxySettings(settings)
                status.systemProxySettings = settings
                errorMessage = nil
            } catch {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func refreshServiceModeStatus() {
        serviceModeStatus = controller.serviceModeStatus()
    }

    func refreshTunStatus() {
        do {
            tunStatus = try controller.tunStatus()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func installServiceMode() async {
        await performLoadingTask { [self] in
            serviceModeStatus = try await controller.installServiceMode()
            refreshStatus()
            refreshTunStatus()
        }
        // Installation can legitimately stop after authorization while a
        // legacy runtime remains online. Reflect the observed Helper/migration
        // state even when the transaction reported an error so Retry resumes
        // the correct path instead of presenting a stale Install state.
        refreshServiceModeStatus()
    }

    func uninstallServiceMode() async {
        await performLoadingTask { [self] in
            serviceModeStatus = try await controller.uninstallServiceMode()
            refreshStatus()
            refreshTunStatus()
        }
    }

    func applyTunSettings(_ settings: TunSettings) async {
        await performLoadingTask { [self] in
            let (appliedStatus, didTransitionRuntime) = try await performRuntimeMutation {
                try await controller.applyTunSettings(settings)
            }
            tunStatus = appliedStatus
            refreshServiceModeStatus()
            if !didTransitionRuntime {
                var runtimeSettings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
                runtimeSettings.tun = settings
                status.runtimeSettings = runtimeSettings
                coreConfiguration.tunEnabled = tunStatus.isEnabled
            }
        }
    }

    func setTunEnabled(_ isEnabled: Bool) async {
        await performLoadingTask { [self] in
            let (appliedStatus, didTransitionRuntime) = try await performRuntimeMutation {
                try await controller.setTunEnabled(isEnabled)
            }
            tunStatus = appliedStatus
            refreshServiceModeStatus()
            if !didTransitionRuntime {
                coreConfiguration.tunEnabled = tunStatus.isEnabled
            }
        }
    }

    // MARK: - DNS

    func applyDnsSettings(_ settings: DnsSettings) async {
        await performLoadingTask { [self] in
            let (applied, didTransitionRuntime) = try await performRuntimeMutation {
                try await controller.applyDnsSettings(settings)
            }
            if !didTransitionRuntime {
                var runtimeSettings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
                runtimeSettings.dns = applied
                status.runtimeSettings = runtimeSettings
                coreConfiguration.dnsEnabled = applied.isEnabled
                coreConfiguration.dns = applied
            }
        }
    }

    func setDnsEnabled(_ isEnabled: Bool) async {
        await performLoadingTask { [self] in
            let (settings, didTransitionRuntime) = try await performRuntimeMutation {
                try await controller.setDnsEnabled(isEnabled)
            }
            if !didTransitionRuntime {
                coreConfiguration.dnsEnabled = settings.isEnabled
                coreConfiguration.dns = settings
            }
        }
    }

    // MARK: - Sniffer

    func applySnifferSettings(_ settings: SnifferSettings) async {
        await performLoadingTask { [self] in
            let (applied, didTransitionRuntime) = try await performRuntimeMutation {
                try await controller.applySnifferSettings(settings)
            }
            if !didTransitionRuntime {
                var runtimeSettings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
                runtimeSettings.sniffer = applied
                status.runtimeSettings = runtimeSettings
                coreConfiguration.snifferEnabled = applied.isEnabled
                coreConfiguration.sniffer = applied
            }
        }
    }

    func setSnifferEnabled(_ isEnabled: Bool) async {
        await performLoadingTask { [self] in
            let (settings, didTransitionRuntime) = try await performRuntimeMutation {
                try await controller.setSnifferEnabled(isEnabled)
            }
            if !didTransitionRuntime {
                coreConfiguration.snifferEnabled = settings.isEnabled
                coreConfiguration.sniffer = settings
            }
        }
    }
}
