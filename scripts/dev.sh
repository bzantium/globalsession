#!/bin/bash
set -e

APP_NAME="gsession"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build/DerivedData"
APP_PATH="${BUILD_DIR}/Build/Products/Debug/${APP_NAME}.app"
# Stable self-signed identity. MUST be a real identity (not ad-hoc): an ad-hoc
# signature's cdhash changes on every build, which silently invalidates the TCC
# Accessibility grant and breaks osascript VPN control (error -25211 on connect).
# This cert predates the GlobalSession→gsession rename; the label is cosmetic.
SIGN_ID="GlobalSession Dev"

pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true

xcodebuild -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | tail -3
# `| tail` hides xcodebuild's exit code from `set -e`; check it explicitly.
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "✗ Build failed." >&2; exit 1; }

# Fail loudly if the identity is missing — otherwise codesign leaves the app
# ad-hoc signed and the Accessibility permission breaks on every rebuild.
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "✗ Signing identity '$SIGN_ID' not found in keychain." >&2
    echo "  Create a self-signed code-signing cert with that name in Keychain Access," >&2
    echo "  or update SIGN_ID in this script." >&2
    exit 1
fi

codesign --force --preserve-metadata=entitlements --sign "$SIGN_ID" "$APP_PATH"
echo "✓ Signed with ${SIGN_ID}"

# Sanity check: confirm we did NOT end up ad-hoc.
if codesign -dv "$APP_PATH" 2>&1 | grep -q "adhoc"; then
    echo "✗ App is still ad-hoc signed — Accessibility grant will not persist." >&2
    exit 1
fi

open "$APP_PATH"
echo "✓ ${APP_NAME} launched"
