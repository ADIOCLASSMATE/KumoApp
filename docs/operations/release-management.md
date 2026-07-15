# Release Management

Kumo publishes one macOS build: Apple Silicon arm64. Intel and universal
binaries are intentionally unsupported. Every public release contains a signed,
notarized DMG and the `latest.yml` manifest consumed by the in-app updater.

Runtime discovery, checksum verification, and installer behavior are documented
in [App Updates](app-updates/README.md).

## Release Trust Requirements

A release must satisfy all of these conditions before a final-named artifact or
manifest is published:

- `Kumo`, `KumoService`, the bundled `kumo` CLI, and the Sub-Store Node runtime
  are executable arm64 Mach-O files with no additional architecture slices.
- `Kumo.app`, `KumoService`, and `kumo` use hardened-runtime Developer ID
  Application signatures from the configured Kumo Team.
- The DMG is signed with the same Developer ID Application identity.
- Apple notarization returns `Accepted`; the ticket is stapled and validated.
- The SHA-256 in `latest.yml` is calculated after signing and stapling.

The build fails closed when an architecture, signing identity, Team ID,
notarization credential, notarization result, or bundled executable is invalid.
Passing `ARCH=amd64`, `ARCH=x86_64`, or an unknown architecture is an error.
DMG creation, notarization, stapling, and validation happen in a temporary
release stage; only the verified DMG is moved into `build/release/`, and
`latest.yml` is generated afterward. A validation failure cleans the temporary
stage without replacing the final names; previously verified outputs, if any,
remain unchanged.

## Required Credentials

Local releases require:

- `DEVELOPMENT_TEAM` — the ten-character Apple Team ID;
- `CODE_SIGN_IDENTITY` — an installed Developer ID Application identity;
- `NOTARY_KEY_PATH` — an App Store Connect API `.p8` private key;
- `NOTARY_KEY_ID` — the API key ID;
- `NOTARY_ISSUER_ID` — the API issuer UUID.

GitHub Actions uses the corresponding secrets:

- `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64`
- `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_CODE_SIGN_IDENTITY`
- `APPLE_DEVELOPMENT_TEAM`
- `APPLE_NOTARY_KEY_P8_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

The workflow imports the certificate into an ephemeral keychain and rejects an
identity that is not `Developer ID Application` for the configured Team.

## Local Release SOP

The example below releases `0.0.10`. Release versions must use numeric `x.y.z`
format.

### 1. Pre-flight

```bash
git status
git branch --show-current
git fetch origin
git pull origin main
git tag -l | grep '^0\.0\.10$'
# The final command must print nothing. Abort if the tag already exists.
```

Run the normal verification suite before signing:

```bash
make swift-test
make app
```

### 2. Build, sign, and notarize

```bash
make clean
make release-dmg VERSION=0.0.10 ARCH=arm64 \
  DEVELOPMENT_TEAM="$APPLE_DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="$APPLE_CODE_SIGN_IDENTITY" \
  NOTARY_KEY_PATH="$APPLE_NOTARY_KEY_PATH" \
  NOTARY_KEY_ID="$APPLE_NOTARY_KEY_ID" \
  NOTARY_ISSUER_ID="$APPLE_NOTARY_ISSUER_ID"
```

Outputs in `build/release/`:

- `Kumo-macos-0.0.10-arm64.dmg`
- `latest.yml`

`make app-release` refreshes the official arm64 Node runtime from a
checksum-verified Node archive. It verifies the Node version, exact Mach-O
architecture, and Node.js Foundation signature before bundling it.

### 3. Verify the finished artifacts

```bash
APP=build/Build/Products/Release/Kumo.app

test "$(lipo -archs "$APP/Contents/MacOS/Kumo")" = arm64
test "$(lipo -archs "$APP/Contents/MacOS/KumoService")" = arm64
test "$(lipo -archs "$APP/Contents/Helpers/kumo")" = arm64
test "$(lipo -archs "$APP/Contents/Resources/Kumo_KumoCoreKit.bundle/Contents/Resources/SubStore/node/bin/node")" = arm64

codesign --verify --strict --deep --all-architectures "$APP"
codesign -dv --verbose=4 "$APP"
codesign -dv --verbose=4 "$APP/Contents/MacOS/KumoService"
codesign -dv --verbose=4 "$APP/Contents/Helpers/kumo"

DMG=build/release/Kumo-macos-0.0.10-arm64.dmg
codesign --verify --strict "$DMG"
xcrun stapler validate "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG"
grep '^sha256:' build/release/latest.yml
```

The three Kumo signing reports must show the configured Team ID, a Developer ID
Application authority, and the `runtime` code-signing flag. The checksum must
match `latest.yml`.

### 4. Tag and publish through GitHub Actions

Release notes must be in English and should be passed with `--notes-file` to
avoid shell-escaping damage when a release is edited manually.

```bash
git tag -a '0.0.10' -m 'Kumo 0.0.10'
git push origin '0.0.10'
gh run list --workflow build-release.yml --limit 1
```

The tag push starts `.github/workflows/build-release.yml`, which repeats the
arm64-only signed/notarized build and publishes the DMG and manifest. Do not run
`gh release create` in parallel with that job. `workflow_dispatch` uses its
required `version` input instead of the selected branch name; beta dispatches
update the rolling `pre-release` tag used by the beta feed. Updating an existing
release first moves it back to draft and verifies that hidden state. New and
existing releases replace the arm64 DMG and `latest.yml`, remove every other
attachment, and verify those are the only two asset names while still draft.
Publishing is the final mutation; a failed upload, cleanup, or verification
leaves the release draft so incomplete assets are not visible to update feeds.

### 5. Verify update discovery

```bash
gh release view 0.0.10 --json assets
curl -sI 'https://github.com/ProjectKumo/KumoApp/releases/latest/download/latest.yml'
```

The release must contain exactly the arm64 DMG and `latest.yml`. Open the DMG on
an Apple Silicon test Mac, install Kumo, and use **About Kumo → Check for
Updates**. A missing manifest produces HTTP 404 and must be corrected before the
release is announced.

## Release Channels

- Stable reads
  `https://github.com/ProjectKumo/KumoApp/releases/latest/download/latest.yml`.
- Beta reads
  `https://github.com/ProjectKumo/KumoApp/releases/download/pre-release/latest.yml`.
- Settings may override the manifest URL for development or private feeds.

There is no architecture-specific Intel feed. `AppUpdateManager` always uses
the Apple Silicon `latest.yml` contract.

## Manifest Contract

```yaml
version: 0.0.10
channel: stable
downloadURL: https://github.com/ProjectKumo/KumoApp/releases/download/0.0.10/Kumo-macos-0.0.10-arm64.dmg
assetName: Kumo-macos-0.0.10-arm64.dmg
sha256: <64-character-sha256-of-the-stapled-dmg>
releaseNotes: |
  See https://github.com/ProjectKumo/KumoApp/releases/tag/0.0.10
```

The updater also accepts these fields as JSON for local testing. Keep the
single-asset shape unless the app-side parser changes in the same release.

## Bundled Runtime and Helper Checks

Release builds include the Sub-Store backend, manifest, and arm64 Node sidecar
inside `KumoCoreKit` resources. Node is generated during the build and is not
tracked in Git. Base64 and URI subscription conversion happens in the App or
CLI before a signed Helper request, so the standalone Helper does not need the
Sub-Store resource bundle.

Releases that change Helper endpoints or runtime trust rules must repair or
reinstall Kumo Helper during smoke testing. Verify that the release-signed
Helper passes the same-Team check, installs through the digest-pinned root
stage, and atomically replaces an existing Helper. Copying a new `Kumo.app`
does not itself replace an already installed LaunchDaemon executable, so update
QA must complete this repair before starting the new runtime when compatibility
changed.

The DMG uses `Assets/dmg-background.png` for its Finder layout. Finder layout
automation may fall back to a default window, but signing, notarization,
stapling, architecture validation, and manifest generation never fall back.
