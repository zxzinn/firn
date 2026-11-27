#!/bin/bash
set -euo pipefail

REPO="${FIRN_REPO:-zxzinn/firn}"
INSTALL_DIR="${FIRN_INSTALL_DIR:-$HOME/.local/bin}"
FIRN_VERSION="${FIRN_VERSION:-}"
SKIP_IMAGES="${FIRN_SKIP_IMAGES:-0}"

OS="$(uname -s)"
ARCH="$(uname -m)"
if [ "$OS" != "Darwin" ] || [ "$ARCH" != "arm64" ]; then
  echo "[firn-install] Firn requires macOS on Apple Silicon (arm64); detected ${OS}/${ARCH}." >&2
  exit 1
fi

CURL_AUTH=()
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -n "$TOKEN" ]; then
  CURL_AUTH=(-H "Authorization: Bearer $TOKEN")
fi

if [ -n "$FIRN_VERSION" ]; then
  case "$FIRN_VERSION" in
    v*) TAG="$FIRN_VERSION" ;;
    *) TAG="v$FIRN_VERSION" ;;
  esac
  API_URL="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
else
  API_URL="https://api.github.com/repos/${REPO}/releases/latest"
fi

echo "[firn-install] Fetching release metadata from ${API_URL}..."
RELEASE_JSON="$(/usr/bin/curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: FirnInstaller" "${CURL_AUTH[@]}" "$API_URL")"

PARSED="$(/usr/bin/python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
tag = data["tag_name"]
assets = {a["name"]: a["browser_download_url"] for a in data.get("assets", [])}
for req in ("firn-darwin-arm64.tar.gz", "SHA256SUMS.txt"):
    if req not in assets:
        raise SystemExit(f"Release {tag} missing required asset: {req}")
print(tag)
print(assets["firn-darwin-arm64.tar.gz"])
print(assets["SHA256SUMS.txt"])
' <<<"$RELEASE_JSON")"

TAG="$(echo "$PARSED" | sed -n '1p')"
TARBALL_URL="$(echo "$PARSED" | sed -n '2p')"
SUMS_URL="$(echo "$PARSED" | sed -n '3p')"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firn-install.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "[firn-install] Downloading ${TAG} (firn-darwin-arm64.tar.gz + SHA256SUMS.txt)..."
/usr/bin/curl -fsSL -o "$TMP_DIR/SHA256SUMS.txt" "$SUMS_URL"
/usr/bin/curl -fSL -# -o "$TMP_DIR/firn-darwin-arm64.tar.gz" "$TARBALL_URL"

EXPECTED_SHA="$(awk '$2 == "firn-darwin-arm64.tar.gz" || $2 == "./firn-darwin-arm64.tar.gz" { print tolower($1); exit }' "$TMP_DIR/SHA256SUMS.txt")"
if [ -z "$EXPECTED_SHA" ]; then
  echo "[firn-install] SHA256SUMS.txt does not list firn-darwin-arm64.tar.gz." >&2
  exit 1
fi
ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$TMP_DIR/firn-darwin-arm64.tar.gz" | awk '{print tolower($1)}')"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "[firn-install] SHA-256 checksum mismatch: expected=$EXPECTED_SHA actual=$ACTUAL_SHA" >&2
  exit 1
fi
echo "[firn-install] Verified SHA-256 ($ACTUAL_SHA)."

mkdir -p "$TMP_DIR/unpack" "$INSTALL_DIR"
/usr/bin/tar -xzf "$TMP_DIR/firn-darwin-arm64.tar.gz" -C "$TMP_DIR/unpack"

if ! /usr/bin/codesign -d --entitlements :- "$TMP_DIR/unpack/firnd" 2>&1 | grep -q "com.apple.security.virtualization"; then
  if [ -f "$TMP_DIR/unpack/entitlements.plist" ]; then
    /usr/bin/codesign --entitlements "$TMP_DIR/unpack/entitlements.plist" --force -s - "$TMP_DIR/unpack/firnd"
  else
    echo "[firn-install] unpacked firnd missing com.apple.security.virtualization entitlement." >&2
    exit 1
  fi
fi

for bin in firn firnd firn-hostnet; do
  if [ ! -f "$TMP_DIR/unpack/$bin" ]; then
    echo "[firn-install] missing binary $bin in archive" >&2
    exit 1
  fi
  install -m 0755 "$TMP_DIR/unpack/$bin" "$INSTALL_DIR/$bin"
done
if [ -f "$TMP_DIR/unpack/entitlements.plist" ]; then
  install -m 0644 "$TMP_DIR/unpack/entitlements.plist" "$INSTALL_DIR/entitlements.plist"
fi
if [ -d "$TMP_DIR/unpack/Firn.app" ]; then
  rm -rf "$INSTALL_DIR/Firn.app"
  cp -R "$TMP_DIR/unpack/Firn.app" "$INSTALL_DIR/Firn.app"
fi

echo "[firn-install] Installed Firn ${TAG} to ${INSTALL_DIR}."

if [ "$SKIP_IMAGES" != "1" ]; then
  echo "[firn-install] Downloading verified Linux ARM64 VM images (${TAG})..."
  "$INSTALL_DIR/firn" images pull --version "$TAG"
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo ""
    echo "Add Firn to your PATH:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac
echo ""
echo "[firn-install] Next:"
echo "  firn doctor && firn up"
