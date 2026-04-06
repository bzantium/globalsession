#!/bin/bash
set -e

# Usage: ./scripts/update-cask.sh <version>
# Example: ./scripts/update-cask.sh 1.0.0

VERSION="${1:?Usage: $0 <version>}"
DMG_URL="https://github.com/bzantium/globalsession/releases/download/v${VERSION}/gsession-${VERSION}.dmg"
CASK_FILE="homebrew/Casks/globalsession.rb"

echo "==> Downloading DMG to compute SHA256..."
SHA256=$(curl -sL "${DMG_URL}" | shasum -a 256 | awk '{print $1}')
echo "    SHA256: ${SHA256}"

echo "==> Updating ${CASK_FILE}..."
sed -i '' "s/version \".*\"/version \"${VERSION}\"/" "${CASK_FILE}"
sed -i '' "s/sha256 \".*\"/sha256 \"${SHA256}\"/" "${CASK_FILE}"

echo "==> Done! Updated cask to v${VERSION}"
echo "    Now commit and push the homebrew tap repo."
