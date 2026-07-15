#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${SUBSTORE_NODE_VERSION:-24.14.0}"
SUBSTORE_DIR="${SUBSTORE_DIR:-Sources/KumoCoreKit/Resources/SubStore}"
CACHE_DIR="${SUBSTORE_RUNTIME_CACHE_DIR:-build/substore-runtime-cache}"
NODE_TARGET="${SUBSTORE_DIR}/node/bin/node"
NODE_METADATA="${NODE_TARGET}.kumo-runtime"
REQUESTED_ARCH="${SUBSTORE_NODE_ARCH:-${ARCH:-}}"
FORCE_REFRESH="${SUBSTORE_FORCE_REFRESH:-0}"

if [[ -z "${REQUESTED_ARCH}" ]]; then
  REQUESTED_ARCH="$(uname -m)"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Kumo's bundled Sub-Store runtime is available on macOS only." >&2
  exit 1
fi

case "${REQUESTED_ARCH}" in
  arm64|aarch64)
    NODE_PLATFORM="darwin-arm64"
    MACHO_ARCH="arm64"
    ;;
  *)
    echo "Kumo supports Apple Silicon only; unsupported architecture: ${REQUESTED_ARCH}" >&2
    exit 1
    ;;
esac

EXPECTED_METADATA="v${NODE_VERSION} ${NODE_PLATFORM}"
node_architectures() {
  /usr/bin/lipo -archs "$1" 2>/dev/null || true
}

node_is_trusted() {
  local node_path="$1"
  local signing_info

  [[ -x "$node_path" ]] || return 1
  [[ "$(node_architectures "$node_path")" == "$MACHO_ARCH" ]] || return 1
  [[ "$("$node_path" --version 2>/dev/null)" == "v${NODE_VERSION}" ]] || return 1
  /usr/bin/codesign --verify --strict "$node_path" >/dev/null 2>&1 || return 1
  signing_info="$(/usr/bin/codesign -dv --verbose=4 "$node_path" 2>&1)" || return 1
  /usr/bin/grep -q '^TeamIdentifier=HX7739G8FX$' <<<"$signing_info" || return 1
  /usr/bin/grep -q '^Authority=Developer ID Application: Node.js Foundation (HX7739G8FX)$' <<<"$signing_info" || return 1
  /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<<"$signing_info"
}

if [[ "$FORCE_REFRESH" != "1" ]] \
  && [[ -x "$NODE_TARGET" ]] \
  && [[ -f "$NODE_METADATA" ]] \
  && [[ "$(<"$NODE_METADATA")" == "$EXPECTED_METADATA" ]] \
  && node_is_trusted "$NODE_TARGET"; then
  exit 0
fi

ARCHIVE_NAME="node-v${NODE_VERSION}-${NODE_PLATFORM}.tar.xz"
ARCHIVE_PATH="${CACHE_DIR}/${ARCHIVE_NAME}"
EXTRACT_DIR="${CACHE_DIR}/node-v${NODE_VERSION}-${NODE_PLATFORM}"
DEFAULT_DOWNLOAD_URL="https://nodejs.org/dist/v${NODE_VERSION}/${ARCHIVE_NAME}"
DOWNLOAD_URL="${SUBSTORE_NODE_DOWNLOAD_URL:-${DEFAULT_DOWNLOAD_URL}}"
EXPECTED_SHA256="${SUBSTORE_NODE_SHA256:-}"

mkdir -p "$CACHE_DIR"

if [[ -z "$EXPECTED_SHA256" ]]; then
  if [[ "$DOWNLOAD_URL" != "$DEFAULT_DOWNLOAD_URL" ]]; then
    echo "SUBSTORE_NODE_SHA256 is required with a custom Node download URL." >&2
    exit 1
  fi
  SHASUMS_PATH="${CACHE_DIR}/SHASUMS256-v${NODE_VERSION}.txt"
  if [[ "$FORCE_REFRESH" == "1" || ! -f "$SHASUMS_PATH" ]]; then
    curl -fL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "${SHASUMS_PATH}.tmp"
    mv "${SHASUMS_PATH}.tmp" "$SHASUMS_PATH"
  fi
  EXPECTED_SHA256="$(/usr/bin/awk -v archive="$ARCHIVE_NAME" '$2 == archive {print $1}' "$SHASUMS_PATH")"
  if [[ -z "$EXPECTED_SHA256" ]]; then
    echo "Node checksum manifest does not contain ${ARCHIVE_NAME}." >&2
    exit 1
  fi
fi

archive_is_valid() {
  [[ -f "$ARCHIVE_PATH" ]] \
    && [[ "$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{print $1}')" == "$EXPECTED_SHA256" ]]
}

if ! archive_is_valid; then
  rm -f "$ARCHIVE_PATH"
  curl -fL "$DOWNLOAD_URL" -o "${ARCHIVE_PATH}.tmp"
  mv "${ARCHIVE_PATH}.tmp" "$ARCHIVE_PATH"
fi

if ! archive_is_valid; then
  echo "Node archive checksum verification failed for ${ARCHIVE_NAME}." >&2
  rm -f "$ARCHIVE_PATH"
  exit 1
fi

rm -rf "$EXTRACT_DIR"
tar -xJf "$ARCHIVE_PATH" -C "$CACHE_DIR"

EXTRACTED_NODE="${EXTRACT_DIR}/bin/node"
if ! node_is_trusted "$EXTRACTED_NODE"; then
  echo "Downloaded Node runtime failed architecture, version, or signature verification." >&2
  rm -rf "$EXTRACT_DIR"
  exit 1
fi

mkdir -p "$(dirname "$NODE_TARGET")"
cp "$EXTRACTED_NODE" "$NODE_TARGET"
chmod 755 "$NODE_TARGET"
printf '%s\n' "$EXPECTED_METADATA" > "$NODE_METADATA"

rm -rf "$EXTRACT_DIR"
