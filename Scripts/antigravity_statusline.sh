#!/bin/sh
set -eu

CACHE_DIR="$HOME/Library/Application Support/AIUsage"
CACHE_FILE="$CACHE_DIR/antigravity-status.json"
TMP_FILE="$CACHE_FILE.tmp.$$"

umask 077
mkdir -p "$CACHE_DIR"
cat > "$TMP_FILE"
mv -f "$TMP_FILE" "$CACHE_FILE"

# Keep the custom line visually empty. With stack_with_default=true,
# Antigravity's built-in status line remains visible.
printf '\n'
