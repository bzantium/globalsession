#!/bin/bash
set -e

APP_NAME="gsession"
DMG_NAME="${APP_NAME}-Installer"
BUILD_DIR="$(pwd)/build"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="$(pwd)/dist/${DMG_NAME}.dmg"

echo "==> Cleaning build directories..."
rm -rf "${BUILD_DIR}" "$(pwd)/dist"
mkdir -p "${BUILD_DIR}" "$(pwd)/dist"

echo "==> Building ${APP_NAME}..."
xcodebuild -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    build

# Copy the built app to build dir
cp -R "${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app" "${APP_PATH}"

echo "==> Creating DMG staging area..."
STAGING_DIR="${BUILD_DIR}/dmg-staging"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"

echo "==> Creating DMG installer..."
create-dmg \
    --volname "${APP_NAME} Installer" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 150 185 \
    --app-drop-link 450 185 \
    --no-internet-enable \
    "${DMG_PATH}" \
    "${STAGING_DIR}/"

echo ""
echo "==> Done! DMG created at: ${DMG_PATH}"
echo "    Double-click to open, then drag to Applications."
