# Core Control Layer

## Purpose

`KumoCoreKit` is the shared domain layer for the GUI, CLI, tests, and privileged
Helper backend. It prevents the app from developing separate, inconsistent
implementations for lifecycle control, profile generation, controller calls,
and system proxy changes.

## Public Entry Point

`KumoController` is the high-level facade. It currently exposes:

- `status()`
- `currentProfile()`
- `profiles()`
- `coreCandidates()`
- `setCorePath(_:)`
- `installManagedCore()`
- `startAndWait(corePath:)` / `restartAndWait(corePath:)` / `stopSafely()`
- `activateProfile(id:policy:forceReload:)`
- transactional profile update, refresh, delete, and scheduled refresh helpers
- `setMode(_:)`
- `proxyGroups()`
- `selectProxy(group:name:)`
- `testProxyDelay(proxy:testURL:)`
- `testGroupDelay(group:)`
- `refreshProfile(from:)`
- `importProfile(from:)`
- `profileContent(id:)`
- transactional `addLocalOverride(...)`, `addRemoteOverride(...)`,
  `updateOverride(...)`, `deleteOverride(id:)`, and `reorderOverrides(ids:)`
- `refreshDueProfiles()`
- `coreConfiguration()`
- `rules()`
- `connections()`
- `recentLogs(limit:)`
- `setSystemProxy(_:dryRun:)`
- `dnsSettings()` / `applyDnsSettings(_:)` / `setDnsEnabled(_:)`
- `snifferSettings()` / `applySnifferSettings(_:)` / `setSnifferEnabled(_:)`
- `tunStatus()` / `applyTunSettings(_:)` / `setTunEnabled(_:)`
- `subStoreStatus()` / `updateSubStoreStatus(_:)` / `prepareSubStoreResources()`
- `exportBackup(to:)` / `importBackup(from:)`
- `checkAppUpdate(...)` / `downloadAppUpdate(...)` / `installAppUpdate(...)`
- `userPreferences()` / `updateUserPreferences(_:)`
- `installCLILink()` / `uninstallCLILink()`

Low-level synchronous lifecycle, direct profile selection, and raw profile
mutation methods are module-internal. Callers cannot bypass normalization, the
operation gate, readiness verification, or transactional profile activation.
The public API is intentionally close to the CLI command vocabulary and the
service API.

## Internal Responsibilities

`KumoCoreKit` is split by responsibility:

- Models: `Profile`, `ProxyGroup`, `ProxyNode`, `CoreStatus`, `OutboundMode`, `CoreRuntimeSettings`, `TunSettings`, `DnsSettings`, `SnifferSettings`, `PolicyValue`, `FallbackFilterValue`.
- Configuration: profile loading, override management, and runtime config generation.
- Runtime: Mihomo process supervision, Sub-Store lifecycle, and core installation.
- Networking: Mihomo external-controller client and Sub-Store HTTP client.
- System: macOS system proxy command construction and execution, PAC server.
- Service: signed Unix socket transport for privileged helper IPC.
- Support: paths, state storage, shared errors, app updates, backups, and CLI link management.

## Runtime Ownership and Backend Contract

Runtime authority is explicit rather than inferred from whether a socket happens
to answer. A normally constructed App or CLI controller uses
`RuntimeAuthority.serviceRequired`; all production lifecycle and live-runtime
mutations must go through the authenticated Helper. `RuntimeAuthority.supervisor`
is restricted to the Helper process and isolated tests. A missing, damaged,
incompatible, or unreachable Helper therefore blocks production mutations
instead of silently creating a second locally supervised Mihomo process.

`RuntimeBackend` is the single lifecycle boundary used by the controller. Its
`ServiceRuntimeBackend` and `SupervisorRuntimeBackend` adapters expose the same
`status`, `start`, `restart`, `stop`, and live `apply` operations. Each mutation
carries a `RuntimeGenerationExpectation`: a start requires `stopped`, while a
restart, stop, mode change, proxy selection, rule toggle, connection close,
provider refresh, or Geo data refresh requires the exact current generation.
A stale precondition fails as a generation conflict; it is not
reinterpreted as permission to mutate whatever generation is now running.

The desired launch input is frozen in an immutable `RuntimeSpec` before process
mutation. It contains the profile YAML, the selected profile's ordered override
YAML, controlled endpoint/ports/mode/settings, and the SHA-256 digest of the
fully generated Mihomo YAML. A controller-ready `RuntimeSnapshot` exposes a
`RuntimeIdentity` only when profile ID, runtime generation, and configuration
digest are all present. Successful activation returns the same three values as
a `RuntimeActivationReceipt`; a profile label or successful IPC response alone
is not proof that traffic moved to the requested configuration.

## Design Rules

- Keep UI concerns out of `KumoCoreKit`.
- Keep `Process` and shell execution behind small wrappers.
- Keep dry-run paths available for tests and agent workflows.
- Keep error messages specific enough for UI and CLI display.
- Keep advanced GUI behavior behind `KumoController` so the CLI and Helper
  backend can reuse the same policy.

Runtime-changing calls share a FIFO `ProfileOperationGate`. Profile activation,
start/restart/stop, every live controller write, and applied
Core/TUN/DNS/Sniffer settings therefore cannot interleave. A task cancelled while waiting checks cancellation
before it is allowed to mutate the runtime. If a supervisor start is cancelled
after its process launches, cleanup carries that start's runtime-generation UUID
through `failStartup`; it cannot clear or terminate a generation installed by a
later lifecycle operation.

Override mutations use that same in-process gate and cross-process profile
transaction lock. They snapshot all override metadata and content before the
candidate is written. Profile-scoped changes structurally preflight the selected
profile with only its scoped plus global YAML; global changes structurally
preflight every stored profile because they affect every generated config.
This repository-wide check uses `RuntimeConfigBuilder`, not a Mihomo `-t` run
for every dormant profile. A live selected runtime still receives semantic
validation, restart, and generation/readiness verification. Rollback runs
outside a cancelled caller task so the prior override tree and runtime are
still restored.

Profile activation commits a selected profile only after the validation that is
available for its requested run policy. Running, ambiguous, and start-required
transitions freeze both candidate and rollback `RuntimeSpec` values, then
receive bounded Mihomo `-t`, process/listener/controller readiness, exact
profile/generation/configuration-digest receipt, and `/proxies` verification.
If a failed candidate launch has already cleared its generation, rollback
re-observes the authoritative backend and starts the frozen previous spec from
the stopped-generation path, including a fully cleaned `.failed` state;
otherwise it restarts using the exact currently observed generation. A
strictly stopped
`.preserveRunState` transition performs normalization and structural config
validation, commits the selection, and deliberately remains stopped; semantic
and live verification occur on its next start. The App/CLI normalizes and builds
the candidate, then sends the immutable spec in a signed
`POST /core/start` or `POST /core/restart` payload. The Helper never opens a
profile below the user's Application Support directory. Protected core
discovery and installation use `GET /core/candidates` and
`POST /core/install`, so a root Helper never executes a user-writable core path.

## Remaining Growth Areas

The shared facade already owns runtime settings, provider refresh, live logs,
ordered YAML overrides, and Sub-Store lifecycle. Remaining extensions include:

- Providers: initialization progress and safe content preview.
- Rules: richer rule metadata and rule enable/disable operations.
- Logs: more resilient stream reconnect and diagnostic retention controls.
- Overrides: reviewed JavaScript transform sandboxing and audit behavior.
- Service: automatic Helper repair and eventual `SMAppService.daemon`
  lifecycle migration.

## Future Compatibility

`KumoController` keeps GUI and CLI command semantics independent of the concrete
backend, but production authority is intentionally not selected dynamically.
The App and CLI require the service backend; only the Helper and isolated tests
construct the supervisor backend. New runtime mutations must preserve that
ownership rule, carry a generation precondition, and join the shared operation
gate.
