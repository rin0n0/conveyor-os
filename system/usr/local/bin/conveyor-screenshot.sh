#!/usr/bin/env bash
# Select a screen area, save it to ~/Pictures/Screenshots and copy it to the clipboard.
set -euo pipefail

TARGET_DIR="${HOME}/Pictures/Screenshots"
TARGET_FILE="${TARGET_DIR}/$(date +%Y-%m-%d_%H-%M-%S).png"

# slurp exits non-zero when the selection is cancelled
AREA=$(slurp) || exit 0

mkdir -p "$TARGET_DIR"
grim -g "$AREA" "$TARGET_FILE"
wl-copy --type image/png <"$TARGET_FILE"
notify-send -a "Скриншот" "Скриншот сохранён" "$TARGET_FILE" || true
