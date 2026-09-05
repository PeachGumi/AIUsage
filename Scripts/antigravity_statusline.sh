#!/bin/sh
set -eu

CACHE_DIR="$HOME/Library/Application Support/AIUsage"
CACHE_FILE="$CACHE_DIR/antigravity-status.json"
INPUT_FILE="$CACHE_FILE.input.$$"
TMP_FILE="$CACHE_FILE.tmp.$$"

cleanup() {
    rm -f "$INPUT_FILE" "$TMP_FILE"
}
trap cleanup EXIT HUP INT TERM

umask 077
mkdir -p "$CACHE_DIR"
cat > "$INPUT_FILE"

PRODUCT=$(/usr/bin/plutil -extract product raw -o - "$INPUT_FILE" 2>/dev/null || true)
if [ "$PRODUCT" = "antigravity" ]; then
    QUOTA=$(/usr/bin/plutil -extract quota json -o - "$INPUT_FILE" 2>/dev/null || true)
    if [ -n "$QUOTA" ]; then
        printf '{"product":"antigravity","quota":%s}\n' "$QUOTA" > "$TMP_FILE"
        mv -f "$TMP_FILE" "$CACHE_FILE"
    fi
fi

# Keep the custom line visually empty. With stack_with_default=true,
# Antigravity's built-in status line remains visible.
printf '\n'
