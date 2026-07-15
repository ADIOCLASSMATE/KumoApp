# Testing and Quality

## Current Tests

The current test suites cover:

- Runtime config generation, including stable HTTP proxy/rule provider cache
  paths isolated by profile ID and provider key/URL in local and Helper modes.
- Immutable `RuntimeSpec` generation, SHA-256 activation receipts, and rejection
  when the Helper regenerates YAML with a different digest.
- Runtime backend parity and generation-CAS behavior for start/restart/stop,
  mode changes, proxy selections, rule toggles, connection closes, provider
  refreshes, and Geo data refreshes. Service-client coverage separately checks
  generation-scoped System Proxy enable. Tests include stale Helper responses
  mapped from HTTP 409 and partial/unsafe installation states blocking the
  service adapter.
- Core state persistence.
- System proxy command construction, exact snapshot restoration, network-service
  migration cleanup, PAC URL case preservation, shutdown safety, and recovery
  by `CoreStateStore` from the root-owned proxy journal after loss of the
  volatile runtime tree. Coverage includes interrupted-disable
  `completeDisable` recovery and applied-snapshot ownership checks that preserve
  externally changed proxy settings, plus post-apply generation loss forcing a
  verified journaled disable.
- Mihomo controller response mapping with mocked URL loading.
- Backup export/import round trips.
- Service request signing.
- Helper protocol/version/capability handshake compatibility, required request
  generation fields, tagged runtime-mutation payloads, and legacy payloads
  failing closed.
- Privileged state writes preserve authorized-user ownership and permissions.
- Privileged state writes reject symlinked state directories and invalid root
  authorization identities.
- Managed Mihomo downloads discover and rank assets from GitHub's dynamic
  expanded-assets listing, reject non-arm64 asset requests, and only fall back
  after HTTP 404 responses.
- Bounded HTTP downloads cancel chunked bodies before they cross the byte cap;
  Mach-O load-command validation rejects malformed executables.
- Real bundled-parser conversion for Base64 VLESS and Hysteria2 subscriptions,
  plus plain URI lists, malformed/scalar documents, and generated group/rule
  completion. Parser-child shutdown tests cover bounded termination without an
  unbounded `waitUntilExit()`.
- Transactional profile validation, commit-after-readiness, rollback, selective
  repository snapshots, queued-operation cancellation, and profile path safety.
  Rollback coverage includes a candidate cleanup that leaves `.failed` with no
  PID, readiness, or generation and requires starting the frozen previous
  runtime with a stopped-generation expectation.
- Profile-scoped override isolation, anti-forgery ownership rules, complete
  repository rollback, and global structural preflight coverage.
- PID/start-time identity, exact orphan classification, dual-listener readiness,
  lifecycle-lock serialization, legacy cleanup boundaries, and symlink-safe
  runtime logging. Direct-start cancellation tests verify cleanup of only the
  matching launch generation.
- Mihomo `-t` rejects a schema-invalid restart before the old PID is stopped.
- Helper candidates reject symlinks, hard links, unsafe permissions, and CWD
  discovery; elevated install executes only a digest-pinned root stage and the
  atomic installer cannot follow a destination symlink. Service-mode tests keep
  repair available for an unreachable/incompatible installed Helper and verify
  proxy restore, privileged-journal reset, selected-runtime activation, and
  proxy re-enable ordering.
- Installation-manifest classification covers absent, legacy-complete, current,
  interrupted/repair-required partial, foreign-user, digest-mismatched, and
  unsafe file sets. Tests distinguish app-visible inspection, which deliberately
  skips the root-only credential file, from privileged full-disk credential
  validation. Status tests verify that a compatible handshake still consumes
  the Helper's privileged classification and that neither view can upgrade the
  other's degraded safety verdict. Convergent-repair tests interrupt every
  transaction stage and verify that a retry reaches one complete installed state.
- The Helper mutation gate serializes overlapping async writes.
- Signed service sockets opt out of `SIGPIPE` so a peer disconnect becomes a
  handled write failure rather than terminating the App, CLI, or Helper.
- Legacy-to-Helper migration tests prove administrator authorization and
  profile/core preflight complete before the old proxy is interrupted, a
  failed local stop restores that proxy, and a failed Helper activation leaves
  macOS proxy state safe. Failure-then-retry coverage proves an already
  installed Helper resumes takeover, while ordinary Helper mutation and quit
  cleanup remain gated by exact local/Helper ownership.
- App tests cover the non-skippable Helper onboarding order, missing-versus-
  repair guidance on Start, generation-safe state updates, and confinement of
  every app-visible and privileged path beneath an isolated smoke-test root.
- App update manifest/checksum handling, mandatory runtime/proxy cleanup,
  expected-version checks, DMG/App/Helper/CLI/Node signature and exact-arm64
  validation, safe staging, and installer rollback behavior.
- CLI argument parsing, JSON envelope stability, color/log rendering rules, and
  npm-style help behavior.

Most behavioral coverage targets `KumoCoreKit`, where the critical shared
policy lives. Separate `KumoCLITests` and `KumoAppTests` targets cover CLI
contracts and generation-safe store behavior.

## Verification Commands

Use:

```bash
swift build --product kumo
make swift-test
.build/debug/kumo --help
.build/debug/kumo status --json
.build/debug/kumo skills install --agent codex --scope global --dry-run --json
```

`make swift-test` prepares the signed arm64 Node sidecar before running the
suite. Direct `swift test` remains useful for pure unit tests; bundled-parser
integration cases skip when generated Sub-Store runtime resources are absent.

An opt-in integration test runs a real Mihomo binary entirely in a temporary
application-support directory with random loopback ports:

```bash
KUMO_REAL_MIHOMO_PATH="$HOME/Library/Application Support/Kumo/cores/mihomo" \
  swift test --filter RealMihomoProfileSwitchIntegrationTests
```

It switches between distinct native YAML profiles, two local-HTTP
proxy/rule-provider profiles, and a normalized Base64 node subscription. After
each switch it verifies live `/proxies` contents, a new generation, the exact
config-file SHA-256, and provider cache isolation. It does not install, stop, or
replace the live App/Helper and does not change macOS System Proxy.

Debug App builds also support an isolated UI smoke mode:

```bash
make app ARCH=arm64
SMOKE_ROOT="$(mktemp -d /tmp/KumoApp-Smoke.XXXXXX)"
KUMO_ISOLATED_APP_TEST_ROOT="$SMOKE_ROOT" \
  build/Build/Products/Debug/Kumo.app/Contents/MacOS/Kumo
```

In this mode user state, sockets, privileged support paths, the Helper binary,
and the LaunchDaemon plist path all resolve below `SMOKE_ROOT`. Notifications,
login-item synchronization, Spotlight indexing, update polling, and quit-time
runtime cleanup are disabled. It is therefore safe to launch beside the live
installed Kumo to inspect the real `.app` composition and onboarding without
touching the live Helper, Mihomo, or macOS System Proxy. The environment hook is
compiled only in Debug builds.

Release plumbing also has fail-closed command checks that do not need a local
release certificate:

```bash
! make prepare-substore-runtime ARCH=amd64
! make prepare-substore-runtime ARCH=unknown
! make app-release ARCH=arm64 \
  DEVELOPMENT_TEAM=INVALID00 \
  CODE_SIGN_IDENTITY='Developer ID Application: Missing (INVALID00)'
```

All three commands must fail before producing a release artifact.

Do not start a development server. This project is a Swift package, not a web app.
For user-facing release checks, prefer the bundled helper at
`Kumo.app/Contents/Helpers/kumo` and the `/usr/local/bin/kumo` symlink over
`swift run kumo`.

## Test Strategy

Prioritize tests that do not mutate real system state:

- Use temporary application support directories.
- Use dry-run for system proxy commands.
- Mock controller responses before testing live Mihomo APIs.
- Avoid tests that require a real network subscription.

## Areas That Need More Coverage

- Profile import and remote refresh errors.
- Missing core path errors.
- Automated App UI navigation beyond the isolated onboarding/main-window smoke
  and store tests.
- Helper restart reconciliation against real macOS network-service changes.
- End-to-end installation from a real signed/notarized DMG, including installed
  Helper compatibility and recovery-artifact inspection.

## Quality Rules

- Keep `KumoCoreKit` independent from SwiftUI.
- Keep command execution isolated.
- Use explicit errors instead of generic failures.
- Keep advanced features behind advanced UI.
- Prefer small files grouped by domain responsibility.

## Manual QA Checklist

- `kumo status --json` returns valid JSON.
- `kumo --help`, `kumo -l`, `kumo help json`, and `kumo completion zsh` return
  npm-style discoverability output.
- `kumo status --color never` contains no ANSI escapes, and `kumo status --json`
  remains plain JSON even when `--color always` is supplied.
- `kumo status --silent` succeeds without successful text output.
- `kumo doctor --timing` writes timing diagnostics without polluting JSON output.
- `kumo logs cli --limit 5` and `kumo logs clean --dry-run --json` operate on
  CLI debug logs without touching runtime logs.
- Missing Mihomo core shows a clear error.
- Empty profile still generates a safe direct config.
- Plain and Base64 node subscriptions import into usable proxy groups; switching
  away from them and back changes both live `/proxies` data and traffic streams.
- A failed profile switch restores the previous selected profile and running or
  stopped state without showing candidate nodes as active.
- Helper mode reports only the protected managed core, and repairing/updating
  the Helper installs it before starting Mihomo.
- First-run onboarding requires the Helper before optional CLI and Agent Skill
  setup; the Helper step has no Skip action, and Start routes a missing or
  damaged Helper back to the appropriate install/repair screen.
- A clean legacy migration keeps the existing runtime and proxy online through
  administrator authorization and selected-profile/core preflight, then
  restores the same selected profile and System Proxy after Helper takeover.
- A partial Helper install can be repaired by retrying Install / Repair without
  manually deleting the LaunchDaemon, privileged executable, credential, or
  manifest. Failure leaves System Proxy safe and reports `repairRequired`.
- Helper uninstall runs the validated bundled Helper and still succeeds when
  the installed copy is incomplete; it never executes that damaged copy.
- An installed unreachable or incompatible Helper fails ordinary status and
  mutations closed; Repair restores proxy state first, performs exact selected
  runtime takeover when needed, and re-enables proxy only after the new Helper
  is ready.
- Managed core installation rejects missing or mismatched published SHA-256
  digests, streaming/download or decompression overflow, malformed load
  commands, and the wrong Mach-O architecture;
  a rejected candidate never replaces the previous executable.
- Cancelling a supervisor start after launch terminates and removes that
  generation without clearing a newer lifecycle generation.
- Removing the volatile Helper runtime directory and restarting the daemon
  preserves enough root-owned proxy journal state to restore or safely
  reconcile the exact pre-Kumo macOS proxy configuration.
- Helper runtime files remain in the root-private tree even when user work or
  log directories are replaced with symlinks, while legacy owned processes are
  still recognized for one-time cleanup.
- A late log-load failure from an older runtime generation cannot erase logs
  already loaded for the new generation.
- First App hydration force-reloads a live selected profile, failed/ambiguous
  runtimes advance the UI generation, and a stale delay task cannot leave its
  spinner active.
- System proxy dry-run prints the expected commands.
- SwiftUI window opens with Overview selected.
- Settings opens with Cmd+,.
- Inspect search fields remain available when a query returns no matches.
- Core runtime and System Proxy settings only commit after the user applies staged edits.
- TUN helper uninstall asks for confirmation before removing the service.
- Menu bar status item exposes start, stop, mode switching, refresh, profiles, proxy groups, and system proxy controls.
- Proxy groups preserve the active runtime configuration's `proxy-groups:` sequence across Overview, Proxies, menu bar, and CLI surfaces.
- App updates check the default GitHub Releases feed when no manifest override is set.
- App update DMG downloads fail closed on SHA-256 mismatch and report a clear error when the current app location is not writable.
- App update installation refuses to launch the detached installer unless the
  owning runtime is strictly stopped and System Proxy restoration is complete.
- A wrong-version, wrong-Team, unsigned, Intel, or universal update candidate is
  rejected before replacement; a simulated post-backup failure restores the
  previous app.
- Release artifacts contain exact arm64 App, Helper, CLI, and Node executables;
  Kumo-owned code and the DMG use the configured Developer ID Application Team,
  and notarization/stapling complete before `latest.yml` records the checksum.
- A published release contains only its arm64 DMG and `latest.yml`.
- `kumo doctor --json` reports status, profile, and core candidate information.
- `kumo backup export <path> --json` creates a manifest-backed backup directory.
- `kumo substore status --json` reports enabled state, backend runtime state,
  resource version, and local URL without launching a dev server.

## Localization QA Checklist

- Settings → General shows the **Appearance** section with a Language dropdown.
- The dropdown contains **System Default** plus every language compiled into the app resource bundles (currently 18 languages including `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `de`, `fr`, `es`, and others).
- Selecting a language triggers the **Restart Required** prompt.
- Clicking **Restart Now** terminates and relaunches the app.
- After restart, the app UI renders in the selected language (Settings labels, sidebar destinations, toolbar actions, mode names, About view, and menu bar status item).
- Selecting **System Default** removes `AppleLanguages` and the app follows macOS system language after restart.
- `preferences.json` contains `appLanguage` as a BCP-47 string (or `null`) after a change.
- String Catalog entries exist for all user-facing labels added in the same change set.
