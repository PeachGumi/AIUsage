#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
DIST="$ROOT/build/dist"

cd "$ROOT"
command -v xcodegen >/dev/null
xcodegen generate >/dev/null

xcodebuild test \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO

rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$DERIVED/Build/Products/Release/AIUsage.app" "$DIST/AIUsage.app"
codesign --force --deep --sign - "$DIST/AIUsage.app"
codesign --verify --deep --strict "$DIST/AIUsage.app"
ditto -c -k --sequesterRsrc --keepParent "$DIST/AIUsage.app" "$DIST/AIUsage-macOS.zip"
shasum -a 256 "$DIST/AIUsage-macOS.zip" > "$DIST/AIUsage-macOS.zip.sha256"

printf 'Release artifacts:\n  %s\n  %s\n' \
  "$DIST/AIUsage-macOS.zip" \
  "$DIST/AIUsage-macOS.zip.sha256"
