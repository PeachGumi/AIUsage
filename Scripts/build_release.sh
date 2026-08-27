#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
DIST="$ROOT/build/dist"
PROJECT="$ROOT/AIUsage.xcodeproj"

cd "$ROOT"

rm -rf "$DERIVED" "$DIST"
mkdir -p "$DIST"

xcodebuild test \
  -project "$PROJECT" \
  -scheme AIUsage \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

xcodebuild build \
  -project "$PROJECT" \
  -scheme AIUsage \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

APP="$DERIVED/Build/Products/Release/AIUsage.app"
[[ -d "$APP" ]] || { echo "Release app not found: $APP" >&2; exit 1; }

cp -R "$APP" "$DIST/AIUsage.app"

# Ad-hoc signing makes the locally built bundle internally consistent. It is
# not Developer ID signing or Apple notarization, so macOS Gatekeeper may still
# warn users who download this ZIP from the internet.
codesign --force --deep --sign - "$DIST/AIUsage.app"
codesign --verify --deep --strict "$DIST/AIUsage.app"

ditto -c -k --sequesterRsrc --keepParent \
  "$DIST/AIUsage.app" "$DIST/AIUsage-macOS.zip"
(
  cd "$DIST"
  shasum -a 256 AIUsage-macOS.zip > AIUsage-macOS.zip.sha256
)

printf 'Release artifacts (ad-hoc signed, not notarized):\n  %s\n  %s\n' \
  "$DIST/AIUsage-macOS.zip" \
  "$DIST/AIUsage-macOS.zip.sha256"
