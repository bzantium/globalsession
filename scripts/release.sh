#!/bin/bash
set -e

# Build a Release version of gsession and install it to /Applications.
#
# This is the project's distribution method (Homebrew was retired). It builds
# locally and signs with a STABLE self-signed identity — important because an
# ad-hoc signature's cdhash changes on every build, which silently revokes the
# macOS Accessibility grant the VPN controls depend on (error -25211). A stable
# identity keeps the same designated requirement, so the permission persists
# across releases and you only grant it once.

APP_NAME="gsession"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# `.noindex` suffix keeps Spotlight from indexing the intermediate build copy.
BUILD_DIR="${PROJECT_DIR}/build/ReleaseDD.noindex"
APP_SRC="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_NAME}.app"
SIGN_ID="GlobalSession Dev"   # stable self-signed identity; label is historical

# Fail early if the identity is missing — otherwise codesign falls back to
# ad-hoc and the Accessibility permission breaks on the next release.
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "✗ Signing identity '$SIGN_ID' not found in keychain." >&2
    echo "  Create a self-signed code-signing certificate with that name in" >&2
    echo "  Keychain Access (Certificate Assistant → Create a Certificate," >&2
    echo "  type: Code Signing), or update SIGN_ID in this script." >&2
    exit 1
fi

echo "==> Building Release..."
xcodebuild -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
# `| tail` masks xcodebuild's exit code from `set -e`; check it explicitly so a
# failed build doesn't silently ship the previous (stale) build product.
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "✗ Build failed." >&2; exit 1; }

[ -d "$APP_SRC" ] || { echo "✗ Build product not found at $APP_SRC" >&2; exit 1; }

echo "==> Quitting running instance..."
pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true

echo "==> Installing to ${INSTALL_PATH}..."
rm -rf "$INSTALL_PATH"
cp -R "$APP_SRC" "$INSTALL_PATH"

echo "==> Signing with '${SIGN_ID}' (entitlements preserved)..."
codesign --force --preserve-metadata=entitlements --sign "$SIGN_ID" "$INSTALL_PATH"

# Guard against silently ending up ad-hoc.
if codesign -dv "$INSTALL_PATH" 2>&1 | grep -q "adhoc"; then
    echo "✗ App is ad-hoc signed — the Accessibility grant will not persist." >&2
    exit 1
fi
codesign --verify --strict "$INSTALL_PATH"
AUTHORITY=$(codesign -dvv "$INSTALL_PATH" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')

# The app is now installed in /Applications, so the intermediate build copy is
# disposable. Delete it outright — leaving it on disk is what caused the
# confusing duplicate in launchers/Spotlight (lsregister -u alone didn't help,
# since Spotlight re-indexes any .app still present on disk). The compiled
# objects under the derived-data dir stay, so incremental rebuilds remain fast.
rm -rf "$APP_SRC"

echo "==> Launching..."
open "$INSTALL_PATH"

echo "✓ ${APP_NAME} installed to ${INSTALL_PATH} (signed: ${AUTHORITY:-unknown}) and launched"
echo
echo "First install with this signature? Grant Accessibility once:"
echo "  System Settings → Privacy & Security → Accessibility → enable ${APP_NAME}"
