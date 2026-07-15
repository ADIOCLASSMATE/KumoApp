#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:?Set VERSION, for example VERSION=0.0.1}"
CHANNEL="${CHANNEL:-stable}"
REPOSITORY="${REPOSITORY:-ProjectKumo/KumoApp}"
APP_PATH="${APP_PATH:-build/Build/Products/Release/Kumo.app}"
OUTPUT_DIR="${OUTPUT_DIR:-build/release}"
ARCH_NAME="${ARCH_NAME:-arm64}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
DMG_BACKGROUND_PATH="${DMG_BACKGROUND_PATH:-Assets/dmg-background.png}"
DMG_WINDOW_WIDTH="${DMG_WINDOW_WIDTH:-660}"
DMG_WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT:-420}"
DMG_ICON_SIZE="${DMG_ICON_SIZE:-96}"
DMG_ICON_Y="${DMG_ICON_Y:-220}"
DMG_APP_ICON_X="${DMG_APP_ICON_X:-176}"
DMG_APPLICATIONS_ICON_X="${DMG_APPLICATIONS_ICON_X:-488}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must use numeric x.y.z format." >&2
  exit 1
fi

if [[ "$ARCH_NAME" != "arm64" ]]; then
  echo "Kumo supports Apple Silicon only; ARCH_NAME must be arm64." >&2
  exit 1
fi

if [[ -z "$DEVELOPMENT_TEAM" || -z "$CODE_SIGN_IDENTITY" ]]; then
  echo "Release DMGs require a Developer ID Application identity and Team ID." >&2
  exit 1
fi

if [[ ! -f "$NOTARY_KEY_PATH" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" ]]; then
  echo "Release DMGs require App Store Connect notarization credentials." >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  echo "Run make app-release first." >&2
  exit 1
fi

APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"
if [[ ! -f "$APP_INFO_PLIST" ]]; then
  echo "App Info.plist not found: $APP_INFO_PLIST" >&2
  exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO_PLIST")"
if [[ "$APP_VERSION" != "$VERSION" ]]; then
  echo "App bundle version ${APP_VERSION} does not match release VERSION ${VERSION}." >&2
  echo "Build with: make release-dmg VERSION=${VERSION}" >&2
  exit 1
fi

APP_EXECUTABLE="${APP_PATH}/Contents/MacOS/Kumo"
HELPER_EXECUTABLE="${APP_PATH}/Contents/MacOS/KumoService"
CLI_EXECUTABLE="${APP_PATH}/Contents/Helpers/kumo"
NODE_EXECUTABLE="${APP_PATH}/Contents/Resources/Kumo_KumoCoreKit.bundle/Contents/Resources/SubStore/node/bin/node"

for binary in "$APP_EXECUTABLE" "$HELPER_EXECUTABLE" "$CLI_EXECUTABLE" "$NODE_EXECUTABLE"; do
  if [[ ! -x "$binary" ]]; then
    echo "Required release executable is missing: $binary" >&2
    exit 1
  fi
  binary_archs="$(/usr/bin/lipo -archs "$binary")"
  if [[ "$binary_archs" != "arm64" ]]; then
    echo "Release executable is not arm64-only: $binary ($binary_archs)" >&2
    exit 1
  fi
done

/usr/bin/codesign --verify --strict --deep --all-architectures "$APP_PATH"
for signed_item in "$APP_PATH" "$HELPER_EXECUTABLE" "$CLI_EXECUTABLE"; do
  signing_info="$(/usr/bin/codesign -dv --verbose=4 "$signed_item" 2>&1)"
  team="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2}' <<<"$signing_info")"
  authority="$(/usr/bin/awk -F= '/^Authority=Developer ID Application:/{print $2; exit}' <<<"$signing_info")"
  runtime="$(/usr/bin/awk '/^CodeDirectory .*flags=.*\(.*runtime.*\)/{print "runtime"; exit}' <<<"$signing_info")"
  if [[ "$team" != "$DEVELOPMENT_TEAM" || -z "$authority" || "$runtime" != "runtime" ]]; then
    echo "$signed_item must use hardened-runtime Developer ID Application signing for Team $DEVELOPMENT_TEAM." >&2
    exit 1
  fi
done

if [[ ! -f "$DMG_BACKGROUND_PATH" ]]; then
  echo "DMG background not found: $DMG_BACKGROUND_PATH" >&2
  echo "Place the installer background at Assets/dmg-background.png." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

ASSET_NAME="Kumo-macos-${VERSION}-${ARCH_NAME}.dmg"
DMG_PATH="${OUTPUT_DIR}/${ASSET_NAME}"
ARCH_MANIFEST_PATH="${OUTPUT_DIR}/latest.yml"
STAGING_DIR="$(mktemp -d "${OUTPUT_DIR%/}/.kumo-release.XXXXXX")"
STAGED_DMG_PATH="${STAGING_DIR}/${ASSET_NAME}"
STAGED_MANIFEST_PATH="${STAGING_DIR}/latest.yml"
RW_DMG_PATH="${STAGING_DIR}/${ASSET_NAME%.dmg}-rw.dmg"
MOUNT_DIR="$(mktemp -d /tmp/kumo-dmg-mount.XXXXXX)"
VOLUME_NAME="Kumo ${VERSION}"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" -force -quiet || true
  fi
  rm -rf "$MOUNT_DIR" "$STAGING_DIR"
}
trap cleanup EXIT

detach_dmg() {
  local _
  for _ in 1 2 3 4 5; do
    if hdiutil detach "$MOUNT_DIR" -quiet; then
      MOUNTED=0
      return 0
    fi
    sleep 1
  done

  hdiutil detach "$MOUNT_DIR" -force -quiet
  MOUNTED=0
}

configure_finder_window() {
  /usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 100 + $DMG_WINDOW_WIDTH, 100 + $DMG_WINDOW_HEIGHT}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $DMG_ICON_SIZE
    set background picture of viewOptions to (POSIX file "$MOUNT_DIR/.background/dmg-background.png" as alias)
    set position of item "Kumo.app" of container window to {$DMG_APP_ICON_X, $DMG_ICON_Y}
    set position of item "Applications" of container window to {$DMG_APPLICATIONS_ICON_X, $DMG_ICON_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
}

APP_SIZE_MB="$(du -sm "$APP_PATH" | awk '{print $1}')"
DMG_SIZE_MB="$((APP_SIZE_MB + 128))"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -size "${DMG_SIZE_MB}m" \
  -fs HFS+ \
  -ov \
  -type UDIF \
  "$RW_DMG_PATH"

hdiutil attach "$RW_DMG_PATH" \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$MOUNT_DIR" \
  -quiet
MOUNTED=1

ditto "$APP_PATH" "$MOUNT_DIR/Kumo.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
cp "$DMG_BACKGROUND_PATH" "$MOUNT_DIR/.background/dmg-background.png"

if ! configure_finder_window; then
  echo "Warning: failed to configure Finder window for ${VOLUME_NAME}; continuing with default DMG layout." >&2
fi
sync
detach_dmg

hdiutil convert "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$STAGED_DMG_PATH" \
  -quiet

/usr/bin/codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$STAGED_DMG_PATH"
/usr/bin/codesign --verify --strict "$STAGED_DMG_PATH"
DMG_SIGNING_INFO="$(/usr/bin/codesign -dv --verbose=4 "$STAGED_DMG_PATH" 2>&1)"
DMG_TEAM="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2}' <<<"$DMG_SIGNING_INFO")"
DMG_AUTHORITY="$(/usr/bin/awk -F= '/^Authority=Developer ID Application:/{print $2; exit}' <<<"$DMG_SIGNING_INFO")"
if [[ "$DMG_TEAM" != "$DEVELOPMENT_TEAM" || -z "$DMG_AUTHORITY" ]]; then
  echo "The DMG must use Developer ID Application signing for Team $DEVELOPMENT_TEAM." >&2
  exit 1
fi

NOTARY_RESULT="$(xcrun notarytool submit "$STAGED_DMG_PATH" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait \
  --output-format json)"
printf '%s\n' "$NOTARY_RESULT"
NOTARY_STATUS="$(printf '%s' "$NOTARY_RESULT" | /usr/bin/plutil -extract status raw -o - -)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  echo "Apple notarization did not accept the DMG (status: $NOTARY_STATUS)." >&2
  exit 1
fi
xcrun stapler staple "$STAGED_DMG_PATH"
xcrun stapler validate "$STAGED_DMG_PATH"
/usr/bin/codesign --verify --strict "$STAGED_DMG_PATH"
hdiutil verify "$STAGED_DMG_PATH"

SHA256="$(shasum -a 256 "$STAGED_DMG_PATH" | awk '{print $1}')"

if [[ -z "${RELEASE_TAG:-}" && "$CHANNEL" == "beta" ]]; then
  RELEASE_TAG="pre-release"
elif [[ -z "${RELEASE_TAG:-}" ]]; then
  RELEASE_TAG="${VERSION}"
fi

DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"

cat > "$STAGED_MANIFEST_PATH" <<EOF
version: ${VERSION}
channel: ${CHANNEL}
downloadURL: ${DOWNLOAD_URL}
assetName: ${ASSET_NAME}
sha256: ${SHA256}
releaseNotes: |
  See https://github.com/${REPOSITORY}/releases/tag/${RELEASE_TAG}
EOF

# STAGING_DIR is inside OUTPUT_DIR, so publication and rollback stay on one
# filesystem. Preserve the previous pair until both replacements succeed.
PREVIOUS_DMG_PATH="${STAGING_DIR}/previous.dmg"
PREVIOUS_MANIFEST_PATH="${STAGING_DIR}/previous-latest.yml"
HAD_PREVIOUS_DMG=0
HAD_PREVIOUS_MANIFEST=0
if [[ -e "$DMG_PATH" ]]; then
  if ! mv "$DMG_PATH" "$PREVIOUS_DMG_PATH"; then
    echo "Could not preserve the previous DMG; release publication was not started." >&2
    exit 1
  fi
  HAD_PREVIOUS_DMG=1
fi
if [[ -e "$ARCH_MANIFEST_PATH" ]]; then
  if ! mv "$ARCH_MANIFEST_PATH" "$PREVIOUS_MANIFEST_PATH"; then
    if [[ "$HAD_PREVIOUS_DMG" == "1" ]]; then
      mv "$PREVIOUS_DMG_PATH" "$DMG_PATH"
    fi
    echo "Could not preserve the previous manifest; release publication was not started." >&2
    exit 1
  fi
  HAD_PREVIOUS_MANIFEST=1
fi

if ! mv "$STAGED_DMG_PATH" "$DMG_PATH" \
  || ! mv "$STAGED_MANIFEST_PATH" "$ARCH_MANIFEST_PATH"; then
  rm -f "$DMG_PATH" "$ARCH_MANIFEST_PATH"
  if [[ "$HAD_PREVIOUS_DMG" == "1" ]]; then
    mv "$PREVIOUS_DMG_PATH" "$DMG_PATH"
  fi
  if [[ "$HAD_PREVIOUS_MANIFEST" == "1" ]]; then
    mv "$PREVIOUS_MANIFEST_PATH" "$ARCH_MANIFEST_PATH"
  fi
  echo "Could not publish the verified release pair; previous artifacts were restored." >&2
  exit 1
fi

echo "Created ${DMG_PATH}"
echo "Created ${ARCH_MANIFEST_PATH}"
echo "SHA-256 ${SHA256}"
