# Persistence and Logging

## Application Support Directory

Kumo stores local state under:

```text
~/Library/Application Support/Kumo/
```

`KumoPaths` centralizes user-owned and privileged path derivation so the GUI,
CLI, tests, and Helper agree on their respective layouts.

## Directory Layout

```text
Kumo/
  profiles/
    default.yaml
    profiles-metadata.json
    current.txt
  overrides/
    overrides.json
    files/
      <id>.yaml
      <id>.js
  work/
    core.pid
    core-instance.json
    core-lifecycle.lock
    instances/
      <launch-id>/config.yaml
  logs/
    core.log
    runtime-events.jsonl
    substore.log
  cores/
    mihomo
  substore/
    status.json
    resources/
    data/
    temp/
  state.json
  preferences.json
```

When Helper mode owns Mihomo, authoritative lifecycle records, the lock, and
per-launch configs are root-private instead:

```text
/private/var/run/io.kumo/<uid>/
  state.json
  core.pid
  core-instance.json
  core-lifecycle.lock
  config.yaml
  work/
  logs/
  instances/<launch-id>/config.yaml
```

State that must survive a Helper restart or reboot is stored separately:

```text
/Library/Application Support/io.kumo.KumoService/
  installation-manifest.json
  users/<uid>/
    mihomo
    service-credentials.json
    system-proxy-state.json
```

`installation-manifest.json` is the root-owned commit record for the privileged
installation. It records transaction phase, authorized UID, Helper/protocol
identity and capabilities, executable/plist SHA-256 values, and the credential
key ID, but never the shared secret. Disk classification combines this record
with descriptor-verified artifacts so a partial or interrupted replacement is
reported as repairable rather than mistaken for a healthy installed service.
The normal App inspects only the executable, plist, and manifest because the
per-user credential directory is deliberately root-owned `0700`; authenticated
handshake success proves the key relationship. Only the privileged installer
and Helper perform full on-disk credential and manifest key-ID validation.

`system-proxy-state.json` is a minimal root-owned recovery journal. Enable and
reconfigure stage the requested state before `networksetup`; disable stages a
`completeDisable` recovery action before its first mutation. The journal keeps
the exact pre-Kumo snapshot and the last read-back snapshot Kumo actually
applied. When `/private/var/run` is recreated after a crash or reboot,
`CoreStateStore` merges the journal into fresh runtime status. Helper startup
completes and verifies an interrupted disable instead of re-enabling Kumo. The
file uses root-only `0600` permissions and no-follow, atomic replacement.

## Backup Format

Kumo can export a directory backup containing:

- `manifest.json`
- `profiles/`
- `overrides/`
- `substore/`
- `state.json`

The first backup format is directory-based rather than zip-based so it remains
transparent, testable, and easy for agents to inspect. A future UI can wrap the
same manifest in a compressed archive or sync it to WebDAV without changing the
CoreKit import/export contract.

## State File

`state.json` stores `CoreStatus`:

- core run state
- process identifier
- outbound mode
- controller endpoint
- mixed proxy port
- system proxy state (including PAC `mode` and `pacScript`)
- the exact pre-Kumo system proxy snapshot used to restore web, secure-web,
  SOCKS, bypass, and auto-proxy/PAC values on disable or shutdown
- the exact Kumo-applied proxy snapshot used as the compare-before-write
  ownership check, plus any pending `completeDisable` recovery action
- controlled runtime settings, including TUN stack, routing, DNS, route
  exclusions, MTU, and ICMP forwarding preferences
- active profile identifier, runtime generation UUID, and exact generated-config
  SHA-256 digest
- last status message

This lets the CLI and GUI share local-mode state without a daemon.
Runtime setting models must decode missing fields with defaults so app updates
can add new TUN controls without invalidating an existing `state.json`.
The desktop App owns the user-visible `state.json`. The privileged Helper keeps
its authoritative live runtime state in the root-owned private tree instead;
it uses descriptor-based secure staging and atomic replacement and never
projects runtime files through a user-replaceable parent directory. The proxy
recovery journal described above is the deliberate persistent exception: it
contains only the state needed to restore or safely reconcile macOS proxy
ownership after loss of the volatile runtime directory.

## User Preferences

`preferences.json` stores `UserPreferences` (UI lifecycle preferences that do
not affect Mihomo runtime):

- `launchAtLogin` — synced with `SMAppService.mainApp` by `KumoAppDelegate`.
- `hideMenuBarIcon` — persisted for the menu bar visibility preference; Kumo now uses
  an AppKit `NSStatusItem`, so runtime visibility can be wired through the status item
  controller when the Settings toggle is re-exposed.
- `quitOnLastWindowClose` — read by
  `applicationShouldTerminateAfterLastWindowClosed`.
- `updateChannel` (`stable` / `beta`) and `updateManifestURL` — feed
  `AppUpdateManager.checkForUpdate(...)`. A blank `updateManifestURL` uses
  Kumo's default GitHub Releases feed; a value overrides it for local testing
  or private distribution.
- `appLanguage` — an optional BCP-47 language tag (e.g. `en`, `zh-Hans`).
  `nil` means follow the system language. On launch `LocalizationManager` reads
  this value and writes it to the standard `AppleLanguages` UserDefaults key so
  macOS resolves the correct `.lproj` at the next launch. The field is decoded
  with `decodeIfPresent` so older `preferences.json` files without it default to
  `nil`.

Decoding falls back to defaults so a missing or corrupted file never blocks
launch.

## App Updates

App update downloads are cached under:

```text
updates/downloads/
```

The detached DMG installer writes its log to:

```text
logs/app-update-installer.log
```

The cache is disposable. Release metadata and artifact rules are documented in
[Release Management](release-management.md).

## Sub-Store

`substore/status.json` (`SubStoreStatus`) stores enable flag, custom backend
URL, host/LAN mode, proxy mode, cron settings, resource version, copied bundle
paths, and configured ports.

Bundled Sub-Store resources are copied from `KumoCoreKit` into:

```text
substore/resources/
  manifest.json
  node/bin/node
  backend/sub-store.bundle.js
```

Sub-Store runtime data is kept under `substore/data/`, matching
`SUB_STORE_DATA_BASE_PATH`. Temporary staging work belongs under
`substore/temp/`. There is no bundled web frontend: Kumo's SwiftUI Sub-Store
surface talks to the local backend over HTTP directly.

`SubStoreSupervisor` launches the bundled Node sidecar with
`sub-store.bundle.js` and Sparkle-compatible environment variables. Stopping
Sub-Store terminates the backend process and closes the log handle.

## Runtime Configuration

The generated Mihomo runtime configuration is unique to a launch:

```text
work/instances/<launch-id>/config.yaml
```

Helper mode uses the root-private
`/private/var/run/io.kumo/<uid>/instances/` equivalent.
Mihomo still receives the normal Kumo work directory through `-d`, while the
exact config is supplied through `-f`. Only a validated instance directory is
removed after stop; legacy cleanup never deletes the whole `work/` tree.
`CoreStatus.configurationDigest` and the per-instance record store SHA-256 over
the bytes of that exact YAML. Controller readiness is not a complete activation
proof until the active profile ID, generation UUID, and stored digest match the
immutable `RuntimeSpec` submitted for the launch.

Mihomo stores HTTP provider downloads below
`work/providers/{proxy,rule}/<profile-hash>/<provider-hash>.yaml`. The same
profile-ID and provider-key/URL hashing is generated for local and Helper
runtimes, so their physical roots differ but their cache-isolation rule does
not.

Profile YAML, metadata, and selection files use user-only permissions. Reads
reject traversal identifiers, symlinks, non-regular files, hard links, foreign
owners in Helper mode, and oversized data. Core logs, runtime events, PID files,
instance records, and instance configs are opened without following symlinks and
are validated through their file descriptors before permissions or ownership
are changed.

## Logs

Core stdout and stderr are appended to:

```text
logs/core.log
```

Sub-Store backend stdout and stderr are appended to:

```text
logs/substore.log
```

Each Sub-Store launch writes a header line (`[ISO timestamp] starting <executable> <args>`) so log readers can split sessions easily.

The main UI intentionally does not expose full logs on the Overview screen. Full log inspection belongs in the `Logs` destination under `Inspect`. The `Sub-Store` settings page surfaces a "View Logs" button that opens `logs/substore.log` in the user's text editor.

Live Mihomo logs should be treated as an event stream with a bounded in-memory cache. The local `core.log` file remains a fallback and diagnostic artifact.

The CLI has a separate debug-log channel under:

```text
logs/cli/
```

Each `kumo` invocation may create a `*-kumo-debug-0.log` file with command-level
diagnostics. `--logs-max <count>` controls retention, and `--logs-max=0`
disables CLI debug log files for sensitive environments. `--logs-dir <path>`
can redirect these files for temporary diagnostics.

`kumo --timing` writes a process-specific `*-kumo-timing.json` file in the same
directory. Timing files are for performance diagnostics and should not be mixed
with runtime event streams.

CLI terminal output follows npm-style log levels:

```text
silent < error < warn < notice < http < info < verbose < silly
```

Normal command results go to stdout. Logs, warnings, progress, timing summaries,
and debug-log paths go to stderr. `--json` keeps stdout as plain JSON only.

Before writing terminal or file logs, CLI diagnostics redact controller secrets,
authorization headers, basic auth passwords, subscription tokens, and token-like
query parameters. Redaction is a safety net, not a reason to paste logs into
public places without review.

## Overrides

Overrides are persisted under:

```text
overrides/
  overrides.json
  files/
    <id>.yaml
    <id>.js
```

`overrides.json` stores ordering, enabled state, global/profile scope, format,
source, and the owning `profileID` for non-global entries. Runtime generation
loads the selected profile's enabled YAML entries first, then enabled global
YAML entries, and finally appends Kumo-controlled settings. Legacy local
metadata without a `profileID` remains readable for migration but is not applied
to any profile. JavaScript content can be stored as `.js`, but execution remains
disabled until a reviewed sandbox exists; there is no per-override `.log` file.

Every override mutation snapshots the complete repository tree, including
metadata and content files. Profile-scoped changes structurally preflight the
selected profile, while global changes structurally preflight every stored
profile because their merge affects every future runtime. If preflight or live
activation fails, Kumo restores the snapshot atomically; a live failure also
restores the previously verified runtime generation.

## Future Work

- Add separate app and service diagnostic log views.
- Add privacy review for logs before sharing diagnostics.
- Add explicit core, runtime-event, and Sub-Store log rotation/retention
  controls.
