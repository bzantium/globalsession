#!/bin/bash
set -e

APP_NAME="gsession"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build/DerivedData"
APP_PATH="${BUILD_DIR}/Build/Products/Debug/${APP_NAME}.app"
SIGN_ID="gsession Dev"

pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true

xcodebuild -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | tail -3

codesign --force --sign "$SIGN_ID" "$APP_PATH" 2>/dev/null && echo "✓ Signed with ${SIGN_ID}"

open "$APP_PATH"
echo "✓ ${APP_NAME} launched"
