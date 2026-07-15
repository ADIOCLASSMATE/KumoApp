# Mihomo Runtime and Controller

## Runtime Model

Kumo manages a Mihomo core executable. The core can come from:

- A path passed to the CLI with `--core`.
- The `KUMO_MIHOMO_PATH` environment variable.
- A bundled `mihomo` resource.
- Common Homebrew or system paths.
- A managed download from MetaCubeX/mihomo GitHub Releases.

The supported application and managed-download architecture is Apple Silicon
arm64 only. Managed candidates must be exact arm64 Mach-O executables, and Kumo
does not publish or test an Intel or universal product variant. Source-tree
custom paths are a development escape hatch, not a supported distribution
architecture.

Managed downloads use the public GitHub releases Atom feed to discover the
latest stable `v*` tag, then read GitHub's public expanded-assets page and
select matching macOS `.gz` assets from the names GitHub actually lists.
Kumo prefers the plain architecture build and ranks listed variants as
fallbacks without maintaining a fixed Go-version or CPU-variant filename
table. Every candidate requires the SHA-256 digest published with that GitHub
asset. Kumo streams metadata and archives into bounded temporary files,
cancels a response as soon as its byte cap is crossed, and limits decompressed
size. It verifies the digest, expected Mach-O architecture, and every declared
load command, then stages the executable beside the
destination, and atomically swaps it only after all checks pass; the previous
known-good binary remains in place on validation failure. Only an HTTP 404
advances to another listed asset; cancellation, network, server, integrity, and
filesystem errors fail immediately. This avoids depending
on the GitHub REST API release endpoint, whose unauthenticated quota can return
HTTP 403 even when the browser-accessible release asset is available.

The current implementation starts Mihomo with a generated work directory and a
unique configuration for each launch generation. The restricted supervisor
path used by tests writes that file under
`work/instances/<launch-id>/config.yaml`; the production Helper writes it under
the root-only `/private/var/run/io.kumo/<uid>/instances/` tree. The generated config contains
Kumo-controlled controller and proxy settings, and the supervisor also passes
the controller endpoint with Mihomo's `-ext-ctl` flag plus `-secret` when a
secret is configured. This keeps the UI and CLI controller surface reachable
even when a profile or Mihomo build treats controller YAML differently from
listener settings.

When Kumo Helper owns the runtime, it ignores user-selected executable paths.
It executes only the managed Mihomo binary installed under
`/Library/Application Support/io.kumo.KumoService/users/<uid>/mihomo` after
verifying that the file and every trusted parent are root-owned and not writable
by group or other users.

## Process Supervision

`CoreSupervisor` handles:

- Preparing application support directories.
- Writing the runtime configuration.
- Starting Mihomo with `Process`.
- Recording the process identifier in state and `work/core.pid` locally, or in
  the root-private runtime tree in Helper mode.
- Stopping recorded processes with a graceful signal escalation path.
- Detecting stale process identifiers.
- Recording runtime lifecycle events.

Every lifecycle and destructive status-reconciliation operation uses the same
inter-process file lock. Each tracked process is identified by PID plus its
kernel start time, so PID reuse cannot redirect a stop signal. Kumo inventories
only processes whose executable, owner, `-d` work directory, and instance
configuration/controller arguments exactly match a Kumo launch; matching orphan
generations are reconciled before a new core starts or while it stops. If a
cross-permission process cannot be inspected, Kumo fails closed instead of
clearing the record or launching a second core.

Stop uses both the persisted status PID and the `work/core.pid` fallback, then
escalates through `SIGINT`, `SIGTERM`, and `SIGKILL`. For child processes
started by the current process, `CoreSupervisor` uses `waitpid(..., WNOHANG)`
while waiting so exited children are reaped instead of being mistaken for
still-running zombie processes. When a stop succeeds, the PID file and stored
PID are cleared together. Status checks also consult `work/core.pid`, so Kumo
can recover a running state when the JSON state lost its PID but the managed
core is still alive.

Process probes treat `EPERM` from `kill(pid, 0)` as proof that the process
exists. This is required when the unprivileged GUI checks a Mihomo process
owned by the privileged Helper; permission denial must not be reported as a
stopped core during profile switching or readiness checks.

After `Process.run()` succeeds, startup is transactional: failures while
writing the PID file, persisted state, or lifecycle event terminate the newly
launched process and clear its PID file. Controller readiness also requires the
same PID/start-time identity to own both the external-controller port and the
mixed proxy port before and after uncached `/version` and `/configs` requests.
The reported mixed port must match the generated configuration. This prevents an
older process on either fixed port from masking a failed new launch. Cached
`controllerReady` state is revalidated against both listeners during status
reconciliation.

Before restart, Kumo resolves and pins the executable identity, builds the
candidate launch config, and runs Mihomo's bounded `-t` semantic validation
without stopping the current generation. A missing core or schema-invalid
config therefore cannot take a working runtime down. Production App and CLI
controllers have `serviceRequired` runtime authority and route lifecycle and
live mutations through the signed Unix socket backend. `CoreSupervisor` is the
execution backend inside the Helper and in isolated tests, not a production
availability fallback. A missing, damaged, incompatible, or unreachable Helper
therefore fails closed instead of launching a second Mihomo. Helper-routed start
and restart requests wait for both listener ownership and controller readiness
before returning.

Every lifecycle request is compare-and-swap scoped. Start requires the observed
runtime to remain stopped; restart and stop require the exact generation UUID
the caller observed. Mode changes, proxy-group selections, rule toggles,
connection closes, provider refreshes, and Geo data refreshes use the same
generation-tagged `/runtime/mutate` route. The Helper serializes all mutating
routes, validates the generation inside that serialization boundary, and
returns HTTP 409 without proxy cleanup or another side effect when the
precondition is stale.

System Proxy enable is also tied to the exact controller-ready runtime
generation, so macOS cannot be pointed at a listener that was replaced between
readiness checking and mutation. Disable deliberately remains generation-free:
making macOS proxy state safe must still be possible when runtime identity is
missing or uncertain. If the generation disappears after `networksetup` has
already applied the proxy, the Helper immediately runs the journaled disable
path, verifies the proxy is off and the recovery action is cleared, then
returns the original generation conflict.

Cancellation of a supervisor start after `Process.run()` is also
generation-scoped. The readiness task retains that launch UUID and asks
`CoreSupervisor` to fail only the matching instance record and runtime
generation. Cleanup verifies the recorded PID plus kernel start time before
termination, then removes that launch's PID file, instance record, and instance
configuration, clears its PID/profile/generation fields, and records the failed
startup. If another lifecycle operation has superseded it, cancellation leaves
the newer generation untouched; if cleanup cannot be proved safe, the record is
retained for later reconciliation.

`CoreStatus.activeProfileID`, `runtimeGeneration`, and `configurationDigest`
identify the verified profile/process/configuration tuple used by transactional
profile activation and UI data guards. The digest is SHA-256 over the exact
generated YAML passed to Mihomo. A successful activation must return all three
values in a `RuntimeActivationReceipt`; a matching profile name without the
matching generation and digest is rejected.
At App startup, the first reconciliation force-reloads any non-stopped
generation from the selected profile and active overrides before nodes,
traffic, or inspect data are hydrated. This repairs a crash that happened
after profile content was written but before its runtime restart.

`KumoAppDelegate.applicationShouldTerminate(_:)` delays app termination while
`KumoAppStore.prepareForTermination()` runs
`KumoController.shutdownActiveRuntime()`. Shutdown first restores the exact
pre-Kumo system proxy snapshot, with a synchronous `networksetup` restore as a
fallback for the normal asynchronous/helper path. It stops Mihomo only after
proxy state is confirmed safe. If proxy restore cannot be verified, Kumo keeps
the owning runtime alive and records `stop-skipped`; this is safer than leaving
macOS configured for a loopback listener that no longer exists.

Core stop follows the same ownership boundary as normal mutations. The App and
CLI never use a direct `CoreSupervisor` stop fallback. If the Helper cannot be
reached, Kumo records the IPC failure because the unprivileged process cannot
safely identify or terminate an opaque root-owned generation. Diagnostics from
every failed step are collected into `ShutdownResult` and surfaced via
`errorMessage`; post-shutdown UI state reset still runs.

The AppDelegate races `prepareForTermination` against a 5 s timeout so a
hung helper-IPC stop or stuck `networksetup` invocation cannot keep AppKit
in `.terminateLater` forever; this is the Swift analogue of Sparkle's
SIGINT → SIGTERM → SIGKILL ladder (capped at +6 s in `process-control.ts`).

The helper daemon may remain installed and reachable after app quit. Under a
healthy shutdown it stops its Mihomo process, which is also the cleanup boundary
for the active TUN route and Mihomo-managed DNS interception. On a fail-closed
shutdown, diagnostics explicitly report that the runtime may remain active
until Helper connectivity or safe proxy restoration is repaired.

## TUN Runtime Settings

`CoreRuntimeSettings` carries `TunSettings`. Helper mode always removes
profile/override-provided `tun` and custom `listeners` blocks, even when the UI
toggle is off, so an untrusted subscription cannot make root-owned Mihomo alter
routes or bind privileged listeners. When TUN is enabled,
`RuntimeConfigBuilder` appends Kumo-controlled settings:

- `tun.enable`
- `tun.stack`
- `tun.auto-route`
- `tun.auto-redirect`
- `tun.auto-detect-interface`
- `tun.strict-route`
- `tun.disable-icmp-forwarding`
- `tun.dns-hijack`
- `tun.route-exclude-address`
- `tun.mtu`
- `tun.device` (macOS only, when prefixed with `utun`)

On macOS, Kumo only writes a configured TUN device name when it already starts
with `utun`, matching the platform's virtual interface naming rules. If no
privileged helper or privileged process is available, TUN enable requests are
rejected and the stored state is rolled back before Mihomo is restarted.

When Kumo Helper is running, the App updates its persisted runtime settings and
sends the complete normalized configuration through the same signed restart
payload used by profile activation. The Helper has no separate TUN mutation
endpoint that could rebuild from an untrusted or missing profile path. It
restarts helper-owned Mihomo, waits for controller and proxy listener ownership,
and reports the resulting `TunStatus`. The macOS authorization involved is
helper installation/repair, not a NetworkExtension VPN configuration prompt.

## DNS Runtime Settings

`CoreRuntimeSettings` carries `DnsSettings` independently of TUN. Helper mode
always removes profile-provided `dns` and `hosts` blocks, preventing a remote
profile from binding a privileged DNS listener. When DNS is enabled,
`RuntimeConfigBuilder` appends Kumo-controlled settings:

- `dns.enable`
- `dns.listen`
- `dns.ipv6`
- `dns.ipv6-timeout`
- `dns.prefer-h3`
- `dns.enhanced-mode`
- `dns.fake-ip-range`
- `dns.fake-ip-range6`
- `dns.fake-ip-filter`
- `dns.fake-ip-filter-mode`
- `dns.use-hosts`
- `dns.use-system-hosts`
- `dns.respect-rules`
- `dns.default-nameserver`
- `dns.nameserver`
- `dns.fallback`
- `dns.fallback-filter`
- `dns.proxy-server-nameserver`
- `dns.direct-nameserver`
- `dns.direct-nameserver-follow-policy`
- `dns.nameserver-policy`
- `dns.proxy-server-nameserver-policy`
- `dns.cache-algorithm`

DNS settings are also surfaced through the Mihomo controller (`GET /configs`)
and can be patched at runtime (`PATCH /configs`). However, because DNS
configuration is structurally significant, applying DNS changes through the UI
restarts the core rather than patching piecemeal, matching Mihomo's expectation
that DNS structure changes are loaded from the generated runtime YAML.

### Hosts

Mihomo's `hosts` key is a top-level configuration block, not nested under `dns`.
Kumo stores `hosts` inside `DnsSettings` for UI convenience (users edit hosts
alongside DNS settings in the Configure view), but `RuntimeConfigBuilder` emits
`hosts` as a separate top-level block. Local unprivileged mode preserves a
profile block unless Kumo settings replace it; Helper mode always strips it and
uses only typed signed runtime settings.

## Sniffer Runtime Settings

`CoreRuntimeSettings` carries `SnifferSettings` independently of TUN and DNS.
Helper mode always removes profile-provided `sniffer` blocks. When Sniffer is
enabled, `RuntimeConfigBuilder` appends Kumo-controlled settings:

- `sniffer.enable`
- `sniffer.parse-pure-ip`
- `sniffer.force-dns-mapping`
- `sniffer.override-destination`
- `sniffer.sniff.HTTP` (with `ports` and `override-destination`)
- `sniffer.sniff.TLS` (with `ports`)
- `sniffer.sniff.QUIC` (with `ports`)
- `sniffer.skip-domain`
- `sniffer.force-domain`
- `sniffer.skip-dst-address`
- `sniffer.skip-src-address`

Sniffer changes are applied through core restart, matching the TUN and DNS
application pattern.

## Controller Client

`MihomoControllerClient` wraps the Mihomo external-controller API:

- `GET /version`
- `GET /configs`
- `PATCH /configs`
- `GET /proxies`
- `PUT /proxies/{group}`
- `GET /proxies/{proxy}/delay`
- `GET /rules`
- `GET /connections`
- `DELETE /connections`
- `DELETE /connections/{id}`
- `GET /traffic` over WebSocket
- `GET /memory` over WebSocket

It maps proxy groups into `ProxyGroup`, proxy names into `ProxyNode`, rules into
`RuleEntry`, and connections into `ConnectionEntry`. `KumoController` reorders
the dictionary-shaped `/proxies` group response to match the active runtime
configuration's `proxy-groups:` sequence, appending runtime-only groups after
the configured groups.

## Extended Controller Surface

Configure and Inspect also use:

- `PATCH /rules/disable`
- `GET /providers/proxies`
- `PUT /providers/proxies/{name}`
- `GET /providers/rules`
- `PUT /providers/rules/{name}`
- `POST /upgrade/geo`
- `GET /logs` over WebSocket or an equivalent streaming transport

## Current Transport

Read-only controller data continues to use Mihomo's loopback HTTP/WebSocket
surface through `URLSession`. Production lifecycle operations, mode changes,
proxy selections, and guarded System Proxy enable use Kumo's authenticated Unix
socket transport. Inside the Helper, `CoreSupervisor` and
`MihomoControllerClient` execute those requests against the Helper-owned Mihomo
process. The socket server accepts clients concurrently so handshake/status
reads remain responsive, while a single async mutation gate serializes all
state-changing routes.

## Error Handling

Controller failures are surfaced as `KumoError.controllerResponse(status, body)` when the response is not successful. UI and CLI callers should display the resulting message without hiding the HTTP status.

## Future Work

- Add resilient reconnect policies for event streams.
- Add restart policies.
- Add provider initialization progress.
- Add safe provider-content preview APIs.
