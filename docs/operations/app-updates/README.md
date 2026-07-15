# App Updates

Kumo updates itself from a GitHub Releases manifest while the app is running.
The update system has two separate concerns:

- **Discovery** — periodically check whether a newer manifest version exists.
- **Installation** — download the DMG, verify its SHA-256 checksum, and hand
  replacement work to an external installer helper.

## Release Feeds

Kumo reads one manifest URL for the selected update channel:

- Stable: `https://github.com/ProjectKumo/KumoApp/releases/latest/download/latest.yml`
- Beta: `https://github.com/ProjectKumo/KumoApp/releases/download/pre-release/latest.yml`
- Custom: Settings may override the manifest URL for development or private feeds.

The selected channel is stored in `UserPreferences.updateChannel`. A blank
custom URL means Kumo uses the default feed for that channel.

Official feeds publish Apple Silicon arm64 builds only. There is no Intel or
universal feed and the updater does not choose between architecture variants.
A custom feed is therefore expected to preserve the same arm64 manifest
contract.

## Manifest Contract

`latest.yml` is uploaded as a release asset beside the DMG:

```yaml
version: 0.0.1
channel: stable
downloadURL: https://github.com/ProjectKumo/KumoApp/releases/download/0.0.1/Kumo-macos-0.0.1-arm64.dmg
assetName: Kumo-macos-0.0.1-arm64.dmg
sha256: <64-character-sha256>
releaseNotes: |
  See https://github.com/ProjectKumo/KumoApp/releases/tag/0.0.1
```

The same fields are accepted as JSON for local testing. `AppUpdateManager`
ignores a manifest when its `channel` does not match the selected channel or
when `version` is not greater than `CFBundleShortVersionString`.

Automatic installation requires:

- `downloadURL` points to a `.dmg`;
- `sha256` is present and non-empty.

If either condition is missing, the UI opens the download URL instead of trying
to install automatically.

## Asynchronous Polling

`KumoAppStore.startUpdatePolling()` owns the runtime polling task. It is called
after `KumoRootView` attaches the live store to `KumoAppContext`, and
`KumoAppDelegate.applicationWillTerminate(_:)` cancels the task through
`stopUpdatePolling()`.

The task is intentionally app-local. Kumo does not require APNs or a push token
for update discovery.

Polling behavior:

1. Wait five minutes.
2. Read the selected release manifest.
3. Compare the manifest version with the app bundle version.
4. If a newer version exists, update `lastUpdateCheckResult` and post the
   update-available notification when allowed by notification throttling.
5. Loop until the task is cancelled.

Manual checks in About and Settings call the same update-checking path, but
they keep the user-facing status behavior:

- manual success with no update sets `Kumo is up to date.`;
- manual failure writes `errorMessage`;
- background polling avoids both, so transient network failures do not disturb
  the main UI.

## Notification Behavior

`AppNotificationCoordinator` registers three update categories:

- `UPDATE_AVAILABLE` with `Install Now` and `Remind Me Later`;
- `UPDATE_PROGRESS` with replacement-style stage text;
- `RESTART_READY` with `Restart Now`.

The five-minute poll can repeatedly discover the same release, so update
notifications are gated per version:

- a version is notified once by default;
- `Remind Me Later` removes the visible update notification and suppresses that
  version for six hours;
- once the snooze expires, the same version may notify again;
- a newer version is treated as a new notification candidate.

Notification actions route back through
`KumoAppStore.handleNotificationAction(actionIdentifier:manifest:version:)`.
`Install Now` uses the current checked update when available, or the manifest
embedded in the notification payload.

## Installation Flow

When the user installs an update:

1. Kumo downloads the DMG into
   `~/Library/Application Support/Kumo/updates/downloads/`.
2. Kumo computes SHA-256 and deletes the file if it does not match the
   manifest.
3. Kumo posts coarse download/install notification updates.
4. `KumoController.installAppUpdate(...)` enters the shared operation gate,
   restores or safely disables System Proxy, stops the owning Mihomo runtime,
   and then re-reads status. Installation is refused unless the runtime is
   strictly stopped, System Proxy is off, and no restoration snapshot remains.
   An installed but unreachable Helper therefore blocks the update instead of
   permitting an unsafe local fallback.
5. Kumo verifies DMG integrity, Developer ID signature, matching Kumo Team,
   stapled notarization ticket, and Gatekeeper assessment. It mounts the DMG
   read-only and copies `Kumo.app` to a unique staging path on the destination
   volume.
6. The staged app must have the expected bundle identifier and manifest
   version. The App, embedded Helper, and CLI must be hardened-runtime
   Developer ID code from the installed Kumo Team; those executables and the
   bundled Node runtime must each contain exactly one arm64 slice. Node must
   retain the expected Node.js Foundation signing Team. Any mismatch removes
   the stage and aborts before replacement.
7. Kumo launches the detached installer helper (`nohup` + background shell).
8. Only after `installAppUpdate(...)` returns with the detached helper scheduled
   does Kumo set `isUpdateInstallerReadyForTermination`. At that point
   `applicationShouldTerminate` returns `.terminateNow`—step 4 has already
   proved cleanup and the helper is blocked on the current PID. The earlier UI
   progress flag alone cannot bypass normal termination cleanup.
9. After the current process exits, the helper revalidates the installed and
   staged app identities, moves the old app to a same-volume backup, atomically
   moves the staged app into place, and reopens Kumo. A failure after backup
   restores and reopens the previous app; if automatic rollback itself fails,
   recovery artifacts are preserved instead of being deleted.

The helper is external because an app cannot safely overwrite its own bundle
while it is running. Do not call `Process.run()` on the installer script
directly: it waits for the script to finish, which deadlocks against step 7.

Replacing `Kumo.app` does not replace an already installed LaunchDaemon copy of
Kumo Helper. If an update changes Helper protocols, endpoints, or trust rules,
repair or reinstall Kumo Helper before the next runtime start. The fail-closed
backend rule prevents the new App from silently launching a local core beside
an incompatible or unreachable old daemon.

## Logs and Cache

- Downloads: `~/Library/Application Support/Kumo/updates/downloads/`
- Installer log: `~/Library/Application Support/Kumo/logs/app-update-installer.log`

macOS notifications do not provide a continuously updating native progress bar
for this update flow. Kumo uses in-app `ProgressView` for precise progress and
coarse notification stage text for background awareness.
