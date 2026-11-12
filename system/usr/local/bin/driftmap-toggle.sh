#!/usr/bin/env bash
# Toggles interactive DriftWM 2D minimap overlay
set -euo pipefail

# If driftwm-settings or custom minimap overlay is running, toggle it
if pgrep -x "driftwm-minimap" >/dev/null 2>&1; then
    pkill -x "driftwm-minimap"
elif command -v driftwm-minimap >/dev/null 2>&1; then
    driftwm-minimap &
elif command -v driftwm-settings >/dev/null 2>&1; then
    driftwm-settings &
else
    # Fallback notification if overlay helper isn't running
    notify-send "DriftWM" "2D Canvas: Use Trackpad pinch-to-zoom or Super+Minus / Super+Equal"
fi
