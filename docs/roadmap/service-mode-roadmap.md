# Service Mode Roadmap

## Why Service Mode Exists

The production App and CLI treat Kumo Helper as the sole authority for Mihomo
lifecycle and live mutations. They may manage profiles and other user-owned
state before installation, but starting or changing the runtime requires an
explicitly authorized, compatible Helper. Direct `CoreSupervisor` authority is
reserved for the Helper process and isolated tests.

## Reference Model

The Sparkle reference project uses a separate service process with:

- Unix socket communication
- Request signing
- Core start and stop endpoints
- Core event streams
- System proxy endpoints
- Fallback to non-service mode when service is unavailable

Kumo follows the same separation of concerns in Swift-native form. The helper
path uses administrator authorization and LaunchDaemon registration; it does
not use NetworkExtension or install a VPN configuration profile. Kumo differs
from the reference fallback rule: production runtime mutations never fall back
to a local supervisor. A missing, partial, incompatible, or unreachable Helper
fails closed, preventing a second local Mihomo from being launched beside an
unobservable root-owned process.

## Current Signed Runtime Endpoints

The authenticated Unix-socket route currently exposes:

- `GET /service/handshake`
- `GET /service/status`
- `GET /status`
- `GET /sysproxy/status`
- `GET /core/candidates`
- `POST /core/install`
- `POST /core/start`
- `POST /core/stop`
- `POST /core/restart`
- `POST /runtime/mutate`
- `POST /sysproxy/enable`
- `POST /sysproxy/disable`
- `GET /tun/status`
- `GET /logs/recent/<limit>`
- `GET /runtime/events/<limit>`

Helper installation, repair, and uninstall are performed by the authorized
`KumoServiceManager` flow, not by socket endpoints. `/runtime/mutate` carries
generation-scoped mode changes, proxy-group selections, rule toggles,
connection closes, provider refreshes, and Geo data refreshes; production
callers do not write directly to the Mihomo controller.

TUN, DNS, Sniffer, and listener changes do not have independent privileged
mutation endpoints. The App/CLI sends a complete normalized runtime payload
through `POST /core/start` or `POST /core/restart`, so the Helper never needs to
load a user-owned profile while applying settings.

Start requires a stopped-generation precondition. Restart, stop, every live
controller write, and System Proxy enable carry the exact observed runtime
generation. A stale mutation returns HTTP 409. System Proxy disable remains
available without a generation because it is a safety operation.

The GUI and CLI should keep their public command semantics unchanged.

## Authentication

The service does not trust arbitrary local clients. `KumoServiceRequestSigner`
defines the Swift-side canonical request and HMAC header shape used by the
Unix socket transport:

- A generated shared secret persisted for the App and copied into a root-only
  Helper credential directory during authorized installation.
- Request timestamps and nonces.
- Request body hashing.
- A canonical signing string.

Both the App/CLI client socket and every accepted Helper socket enable
`SO_NOSIGPIPE` before writing. If the peer disconnects, the write is reported as
a normal service error instead of terminating either process with `SIGPIPE`.
The Helper accepts connections concurrently so handshake/status reads do not
wait behind long lifecycle work, while one async mutation gate serializes every
state-changing route and its generation comparison.

The handshake publishes protocol version, Helper version, and extensible string
capabilities. The current compatibility contract requires exact activation
receipts, atomic runtime-generation CAS, privileged installation health, and
routed live-runtime mutations. Disk presence alone is never treated as
protocol compatibility.

## Current Ownership Strategy

1. Keep user-owned profile/configuration management available before Helper
   installation, but require the Helper for production runtime mutations.
2. Install or repair the Helper only after explicit administrator authorization.
   A clean first install authenticates the new Helper while the legacy local
   runtime still serves traffic. Kumo also normalizes the selected profile and
   prepares the Helper-owned core before the handoff. Only after those checks
   succeed does it disable the legacy proxy, stop that exact process
   generation, activate the selected profile through Helper, and restore
   System Proxy. Failed authorization or preflight leaves the legacy runtime
   untouched; a failed local stop restores its proxy. If Helper was already
   installed, ordinary mutations remain blocked and Install / Repair resumes
   takeover while the legacy runtime remains visible. Reachable reinstall still requires a strictly stopped
   runtime and System Proxy off. Repair of an unreachable, incompatible, or
   partial Helper restores safe proxy state, replaces the complete privileged
   artifact set, activates the exact selected runtime when needed, and
   re-enables any previously active proxy only after that activation succeeds.
3. Once installed, route App and CLI lifecycle, status, runtime setting, and
   system-proxy mutations through authenticated IPC without changing CLI output
   schemas.
4. Classify installation state from the root-owned manifest and the artifacts
   visible at the caller's privilege scope; privileged repair validates the
   complete set and converges interrupted partial installs instead of requiring
   manual file deletion.
5. Fail closed when the Helper is unavailable or incompatible; never use local
   lifecycle as an availability fallback.
6. Guard every runtime mutation with an atomic generation precondition, and
   roll rejected persisted settings back before another restart.

## Remaining Helper Work

- Migrate the digest-pinned root-stage installer to `SMAppService.daemon`.
- Improve automatic service repair and diagnostics.
- Expand proxy guard events and UI notifications.
- Extend the required onboarding Helper step with richer update-time
  compatibility diagnostics.

The current implementation includes the signed endpoint surface, explicit
runtime backend adapters, generation CAS, protocol/capability handshake,
manifest-classified installation health, convergent repair of partial installs,
service-backed core/system proxy/TUN control, and controlled runtime
configuration generation. It intentionally does not silently install a
privileged daemon; installation remains an explicit, authorized user action.

## Related Subsystem Ownership

Not every local subsystem belongs in the privileged daemon. Current ownership
is explicit so future migrations do not accidentally weaken lifecycle safety.

- **PAC mode is implemented in both backend paths.** The restricted supervisor
  path uses the App-side `PACServer`; production Helper mode keeps one
  long-lived controller/PAC-server pair,
  journals enable/reconfigure before mutation and stages disable as
  `completeDisable` in root-private `system-proxy-state.json`. Restart/reboot
  reconciliation finishes interrupted disable before considering re-enable,
  while applied-snapshot ownership checks preserve external proxy changes.
- **Sub-Store local lifecycle is implemented in the app process** via
  `SubStoreSupervisor` (Node `Process` lifecycle + `logs/substore.log`).
  Sub-Store conversion remains unprivileged by design: the App/CLI normalizes
  subscriptions before IPC, and the Helper accepts only normalized Mihomo YAML.
- **Open at Login** uses `SMAppService.mainApp`. Once a helper bundle
  lifecycle migration is ready, the current root-staged LaunchDaemon installer
  can move to `SMAppService.daemon` without changing the control API.
- **Spotlight indexing** uses `CSSearchableIndex.default()` from the app
  process. This works without a service; only the data source has to move
  if profile state is later owned by the service.
- **App Intents** call back into the live `KumoAppStore`, which reaches the same
  controller ownership rules as the GUI while the App is running. Closed-GUI
  intent execution is not promised by the current architecture.
- **TUN mode** now has first-class settings in `CoreRuntimeSettings`. When
  enabled behind service availability, runtime config generation owns the
  `tun:` and required `dns:` blocks and the helper restarts Mihomo from the
  privileged backend. When service mode is unavailable, Kumo disables the
  requested TUN state and surfaces the helper requirement.
