#!/usr/bin/env bash
#
# Builds the release binary with SwiftPM and assembles a runnable macOS .app bundle.
# Full Xcode is NOT required — Command Line Tools is enough.
#
set -euo pipefail
cd "$(dirname "$0")"

EXE_NAME="ClaudeUsageApp"
BUNDLE_DIR="ClaudeUsage.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Assembling ${BUNDLE_DIR}"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"
cp "${BIN_PATH}/${EXE_NAME}" "${BUNDLE_DIR}/Contents/MacOS/${EXE_NAME}"
cp "Resources/Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"

echo "==> Ad-hoc code signing"
# Ad-hoc signing keeps a stable code identity for the Keychain ACL and avoids the
# "app is damaged" Gatekeeper warning on first open.
codesign --force --deep --sign - "${BUNDLE_DIR}" || echo "    (codesign failed — app may still run locally)"

echo ""
echo "Built ${BUNDLE_DIR}"
echo "  Launch:        open \"${BUNDLE_DIR}\""
echo "  Run w/ logs:   ./${BUNDLE_DIR}/Contents/MacOS/${EXE_NAME}"
