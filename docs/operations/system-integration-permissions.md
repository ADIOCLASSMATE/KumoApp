# System Integration and Permissions

## App Bundle and Entitlements

Kumo ships as a real `.app` bundle generated from `project.yml` via XcodeGen
(`make generate`). The bundle pulls in:

- `Resources/KumoApp/Info.plist` — bundle metadata, `LSApplicationCategoryType`,
  `NSAppTransportSecurity` (allows local-network PAC), `NSServices` (Services
  menu), `CFBundleDocumentTypes` (`.yaml` profiles), `NSUserActivityTypes`
  (Spotlight handoff), and `NSAppleEventsUsageDescription` /
  `NSSystemAdministrationUsageDescription` (consent strings used when running
  `networksetup` and spawning the Mihomo / bundled Node Sub-Store processes).
- `Resources/KumoApp/KumoApp.entitlements` — `com.apple.security.app-sandbox`
  is **disabled** so that `networksetup` invocations and child processes
  (the shutdown/repair proxy fallback, Sub-Store backend listener, and PAC HTTP
  listener) keep working. Direct Mihomo supervision is restricted to the Helper
  and isolated tests. `com.apple.security.network.client` and
  `com.apple.security.network.server` are enabled. Sandboxing remains a
  follow-up once helper-bundle / XPC architecture lands.

Build commands:

```bash
make generate    # xcodegen generate -> Kumo.xcodeproj (gitignored)
make app         # xcodebuild Debug -> build/Build/Products/Debug/Kumo.app
make app-release # xcodebuild Release
make dev         # build + open Kumo.app
make dev-cli     # legacy swift run KumoApp without bundle (no Spotlight / Intents)
```

## System Proxy

`SystemProxyController` runs macOS `networksetup` commands and now branches on
the `SystemProxyMode` carried by `SystemProxyConfiguration`:

- `manual` mode configures web, secure web, SOCKS firewall proxies, plus the
  bypass list, and explicitly turns auto-proxy state off.
- `pac` mode boots a local `PACServer` (loopback `NWListener` HTTP that
  responds with the user's PAC script as
  `application/x-ns-proxy-autoconfig`), then runs `-setautoproxyurl
  http://127.0.0.1:<port>/proxy.pac` and `-setautoproxystate on`, while
  turning manual web/secure/socks off.
- `setEnabled(false)` restores the exact web, secure-web, SOCKS, bypass, and
  auto-proxy/PAC values captured before Kumo enabled the proxy. If the active
  network service changed while Kumo was enabled, it first removes the
  Kumo-managed state from the current service and then restores the original
  service snapshot. The PAC URL is compared without changing its case.

`setSystemProxy(_:dryRun:)` is `async` — dry-run mode skips the listener and
returns the would-be commands for inspection (used by the CLI and tests).

Before enabling system proxy, Kumo now verifies that the target
`host:mixed-port` is accepting local TCP connections. This prevents macOS from
being pointed at a stale or failed listener. After applying `networksetup`
commands, Kumo reads the OS proxy state back and only marks the feature enabled
when manual or PAC settings match the requested mode.

In production, Helper-backed enable requests also carry the exact observed
runtime generation. The Helper validates that generation inside its serialized
mutation gate before and after applying the proxy configuration; a stale request
returns a conflict instead of pointing macOS at a superseded listener. Disable
does not require a runtime generation because restoring safe OS proxy state must
remain possible after a crash or ambiguous runtime transition. If the
post-apply generation check fails, Helper uses the durable disable journal,
verifies System Proxy is off and the recovery action is complete, and only then
returns the original conflict.

## Command Line Tool Symlink

`Kumo.app/Contents/Helpers/kumo` is the source of truth for the bundled CLI;
it is copied into the app bundle by the `Copy Kumo CLI` post-build script in
`project.yml` (and the equivalent `cp` step in `Makefile`). The helper path is
intentional: macOS volumes are case-insensitive by default, so dropping the
CLI as `Contents/MacOS/kumo` would silently overwrite the GUI main binary
`Contents/MacOS/Kumo`. The first-run onboarding sheet and Settings > General >
Command Line Tool both use `CLILinkInstaller` to manage a symlink at
`/usr/local/bin/kumo` that points at the bundled binary.

`CLILinkInstaller` reuses the `osascript ... with administrator privileges`
pattern used by `KumoServiceManager` because `/usr/local/bin` is not writable
for ordinary users. Install runs `/bin/ln -sfn <bundled> /usr/local/bin/kumo`
inside the elevated shell call; uninstall runs `/bin/rm -f` and refuses to
delete a symlink that does not point at the bundled CLI, so unrelated CLI
shims are not affected. macOS will request administrator authorization once
per operation, the same way the Kumo Helper install does, and the prompt is
separate from any VPN configuration prompt.

The target path is reported through `KumoController.cliLinkStatus()` so the
UI and CLI can show whether the symlink is installed, points elsewhere, or is
shadowed by a regular file. There is no automatic update — running the CLI
installer again repoints the symlink at whatever `kumo` ships inside the
current `Kumo.app`.

## LaunchAgent (Open at Login)

`KumoAppDelegate` keeps `SMAppService.mainApp` in sync with
`UserPreferences.launchAtLogin` whenever the app launches. The Settings
"Preferences" tab toggles the same preference and registers/unregisters
through `SMAppService`. Registration only succeeds when `Kumo.app` lives in
`/Applications` (macOS launch services requirement).

## Dock Badge

While the app is running, a 1 s timer in `KumoAppDelegate` writes
`NSApp.dockTile.badgeLabel` from the live `KumoAppStore.connections.count`,
so the user sees connection volume even when the main window is hidden.

## Spotlight

`SpotlightIndexer` indexes profile summaries (name + source) into the default
`CSSearchableIndex` on launch and after profile refreshes. Each entry uses
the profile id as `uniqueIdentifier`, and `NSUserActivityTypes` declares
`io.kumo.KumoApp.openProfile`. Tapping a Spotlight result returns the user
to Kumo and selects the matching profile via `KumoAppContext.handleUserActivity`.

## Services Menu

`Info.plist` registers a single Services entry — "Import Profile to Kumo" —
that targets `importProfileURL(_:userData:error:)` on the AppDelegate. Any
text or URL string sent through Services becomes a profile import attempt
via `KumoAppStore.importRemoteProfile(urlString:useProxy:)`.

## App Intents

`KumoIntents.swift` exposes five intents that surface in Shortcuts, Siri,
and Spotlight:

- `StartKumoIntent` / `StopKumoIntent`
- `RefreshKumoIntent`
- `SetKumoModeIntent` (with `KumoModeChoice` enum mirroring `OutboundMode`)
- `ToggleSystemProxyIntent`

Phrases are wired through `KumoShortcutsProvider`. Each intent resolves the
live `KumoAppStore` via `KumoAppContext.shared.store`, so intent
side-effects stay consistent with the SwiftUI UI.

## Dry Run

`setSystemProxy(_:dryRun:)` (now `async`) still supports dry-run for unit
tests, CLI previews, agent safety, and debugging network service names.
Dry-run returns the exact commands without executing them and without
binding the PAC listener.

## Current Assumptions

Kumo can still store a manual network service name, but new default system
proxy settings prefer the active route interface by resolving
`route -n get default` through `networksetup -listnetworkserviceorder`.
This avoids writing proxy settings to `Wi-Fi` when the active service is
Ethernet, USB tethering, or another macOS network service.

When enabling system proxy outside dry-run, Kumo captures the complete previous
proxy state for the selected service. Disable and synchronous shutdown restore
that snapshot exactly, including any pre-existing proxy endpoints, bypass list,
and PAC URL/state. Each multi-command update also captures the state immediately
before the attempt, so a partial `networksetup` failure can roll back instead of
leaving a mixed configuration.

After enabling, Kumo persists the exact proxy snapshot read back from macOS.
Disable and network-service migration use that applied snapshot as a CAS-style
ownership precondition: if the current web, secure-web, SOCKS, bypass, or PAC
state no longer matches, Kumo refuses to overwrite it and preserves the newer
settings made by the user or another application.

Foreground app quit uses the same disable path before allowing termination.
The SwiftUI app delegate returns `.terminateLater`, asks `KumoAppStore` to
restore the system proxy snapshot and stop Mihomo, then replies to AppKit that
termination may continue. A synchronous restore is attempted if the normal
asynchronous path fails. When the runtime backend is reachable but Kumo cannot
prove that proxy state is safely restored or disabled, shutdown deliberately
leaves the owning Mihomo process running and records a `stop-skipped` diagnostic
rather than strand macOS on a dead loopback proxy. An unreachable installed
Helper follows the separate fail-closed ownership rule below.

## Permissions

Kumo uses signed service requests, service status, TUN status, and a
`KumoService` helper target for production runtime ownership.
This follows the Sparkle and Clash Verge Rev model: macOS asks for administrator
authorization when Kumo installs or repairs the helper, but Kumo does **not**
register a NetworkExtension or VPN profile. The "Allow VPN Configuration"
system prompt is therefore not expected for System Proxy or Mihomo TUN mode.

The normal App and CLI controller require a compatible Helper for every
runtime-changing operation, not only TUN. The direct `CoreSupervisor` authority
is restricted to the Helper process and isolated tests. A missing, partial,
foreign-user, unsafe, incompatible, or unreachable Helper is therefore a
fail-closed state with an Install / Repair action; the front end cannot start a
second local Mihomo beside an unobservable privileged process.

On foreground app quit, Kumo asks the Helper to stop its Mihomo process rather
than uninstalling the Helper. If the Helper cannot be reached, Kumo reports the
failure and does not attempt an unprivileged local stop of a root-owned runtime.
Stopping Mihomo is the cleanup boundary for the active TUN route and
Mihomo-managed DNS interception; the user's persisted TUN preference remains
available for the next explicit start.

The helper requires a valid non-root installing-user UID and resolves its
primary GID without falling back to the daemon's root identity. Its socket is
root-directory-protected and accessible only to that user. Authoritative state,
PID, instance records, configs, work data, and logs remain root-owned under a
private runtime directory; descriptor-based reads/writes reject symlinked,
foreign-owned, hard-linked, or group/world-writable entries. The GUI/CLI keeps a
separate user-owned preference snapshot and receives live runtime state only
through authenticated IPC. This removes the root/user parent-directory race.

The Helper never executes `state.json`'s user-selected core path. Managed core
installation runs inside the Helper and writes a root-owned, non-user-writable
binary below `/Library/Application Support/io.kumo.KumoService/users/<uid>/`;
candidate discovery in service mode returns only that verified binary. Runtime
instance identity, lifecycle locking, and generated configuration live in a
root-only `/private/var/run/io.kumo/<uid>/` directory. Subscription conversion is done
by the App/CLI before IPC, and the Helper accepts only normalized Mihomo YAML.

Helper installation never executes the bundle path directly as root. Kumo
accepts only the fixed nested Helper (or the same build-product directory in
Debug), validates its regular-file shape and code signature, hashes its pinned
file descriptor, and asks a fixed system shell to copy it into a random
root-only `/var/root` stage. The elevated flow verifies that digest and code
signature again before executing the stage. The stage installs itself with
descriptor-relative copy, `O_NOFOLLOW`, `fsync`, and atomic rename; a bad source
or destination symlink cannot overwrite a victim or discard the previous
Helper. LaunchDaemon plist and credentials use the same root-owned atomic
writer. Release builds additionally require the App and Helper to carry the
same non-empty signing Team ID; ad-hoc signatures are accepted only by Debug.

### Installation Manifest and Convergent Repair

The root-owned `installation-manifest.json` records the transaction ID and
phase (`installing`, `installed`, or `repairRequired`), authorized UID, service
label, Helper/protocol versions, capability strings, executable and LaunchDaemon
SHA-256 values, and credential key ID. It intentionally contains no shared
secret. Installation health uses the states `absent`, `legacyComplete`,
`current`, `partial`, `foreignUser`, or `unsafe`; plist identity, ownership,
permissions, link count, and manifest digests are checked through no-follow file
descriptors. The unprivileged App uses an app-visible inspection scope for the
executable, plist, and manifest only: the credential lives below a root-owned
`0700` directory and is intentionally unreadable. A successful authenticated
handshake proves key agreement at that boundary. The privileged installer and
Helper use the full inspection scope, including credential shape, permissions,
and key-ID agreement with the manifest. Authenticated `GET /service/status`
reports that privileged classification on every status refresh. The App merges
it conservatively with its app-visible classification, so neither side can
upgrade a degraded verdict from the other side. A running process alone is not
enough to make a partial installation available.

A coherent previous installation uses snapshot-and-rollback replacement. A
partial installation has no safe predecessor, so repair is convergent instead:
write `installing`, stop the loaded service, make System Proxy safe, replace the
entire executable/credential/plist set, start the daemon, verify its authenticated
handshake, and only then write `installed`. Any failure stops the candidate,
makes System Proxy safe again, and records `repairRequired`. Retrying follows the
same sequence and does not require the user to manually delete privileged files.
`foreignUser` and `unsafe` states are rejected rather than overwritten.

Uninstall and repair always execute a separately validated Helper from the
sealed App bundle (or the explicit Debug build-product location). They never
delegate cleanup to the installed copy, which may be incomplete or tampered.

### Protocol Handshake

`GET /service/handshake` returns an explicit protocol version, Helper version,
and open-string capability list. The current App requires exact runtime
activation receipts, atomic runtime-generation CAS, and privileged installation
health reporting, plus routed live-runtime mutations. Service availability
requires a safe complete disk state and a compatible authenticated handshake;
an older or partially installed daemon
may be running but is still reported as requiring repair. Installation commits
its manifest only after the new daemon reports the exact expected version and
capabilities.

A clean first-time install authorizes, installs, and authenticates the Helper
while a legacy local Mihomo continues serving traffic. It then normalizes the
selected profile and prepares the Helper-owned managed core while the old
runtime is still intact. After those checks succeed, Kumo disables the legacy
proxy, stops the ownership-verified local process, force-activates the exact
selected profile through Helper, and restores System Proxy. If authorization
or preflight fails, the legacy runtime and proxy are untouched; if the local
stop fails while it is still present, Kumo restores the local proxy.
If one of those pre-handoff steps fails after Helper was installed, the App
continues to expose the legacy runtime, blocks ordinary Helper mutations, and a
subsequent Install / Repair resumes the same takeover. Quit may retire that
legacy process only after the reachable Helper proves its own runtime stopped.
A reachable reinstall requires Mihomo to be strictly stopped and System Proxy
to be off. Repair of an installed but unreachable or authenticated-status
incompatible Helper follows a fail-safe takeover instead: it first restores and
verifies the locally recorded macOS proxy state, replaces the Helper while
resetting its root-owned recovery journal to disabled, force-activates the exact
selected profile when a runtime was present or ambiguous, and only then
re-enables System Proxy if it was previously on. A later failure triggers a
Helper-side disable and reports an error if the safe disabled state cannot be
verified; it never falls back to a second local Mihomo.

System proxy requests through Helper mode include the effective network service,
endpoint, mode, PAC script, and bypass settings in the signed request.
The Helper keeps one long-lived controller/PAC-server pair and persists enough
state to reconcile proxy ownership after a daemon restart. Before
`networksetup`, it write-ahead persists enable/reconfigure state and stages
disable with the
`completeDisable` recovery action in the root-owned
`/Library/Application Support/io.kumo.KumoService/users/<uid>/system-proxy-state.json`.
Unlike `/private/var/run`, this journal survives daemon restart and reboot.
Reconciliation completes an interrupted disable, or re-applies requested PAC or
manual configuration only when runtime/listener readiness and the applied
snapshot ownership check succeed. External proxy edits are preserved rather
than overwritten.

## Advanced Features

The following remain hardening work after the first service-backed path:

- Privileged Helper repair diagnostics and automatic repair prompts
- Migration from the contained installer to `SMAppService.daemon`
- Richer proxy-guard diagnostics and user notifications
- Front-end sandboxing and helper-bundle separation

## Future Work

- Adopt `SMAppService.daemon` for lifecycle management after the current
  digest-pinned, root-staged installer.
- Adopt App Sandbox + helper-bundle separation so `networksetup` invocations
  and child processes can run from a sandboxed front-end.
- Expand automatic Helper repair and proxy-reconciliation diagnostics.
