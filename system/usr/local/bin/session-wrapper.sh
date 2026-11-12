#!/usr/bin/env bash
set -euo pipefail

COMPOSITOR="${1:-driftwm}"

# Load dynamic hardware profile generated at early boot
if [[ -f /run/gpu-profile.env ]]; then
    set -a
    # shellcheck source=/dev/null
    source /run/gpu-profile.env
    set +a
fi

export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1
export ELECTRON_OZONE_PLATFORM_HINT=auto
export TERMINAL=footclient
export LAUNCHER="fuzzel"

# Ensure ephemeral Firefox & build caches stay off the SATA-USB drive
mkdir -p "/tmp/conveyor-${USER}/ff-cache"

# If 2014 legacy GPU has broken hardware GL, allow software fallback cleanly
if [[ "${WAYLAND_RENDER_MODE:-hw}" == "sw" ]]; then
    export WLR_RENDERER=pixman
    export LIBGL_ALWAYS_SOFTWARE=1
fi

# Start shared lightweight cockpit daemons in background (0 MB VRAM terminal server)
foot --server &
wl-paste --type text --watch cliphist store &

case "$COMPOSITOR" in
    driftwm)
        exec driftwm
        ;;
    niri-session)
        exec niri-session
        ;;
    sway)
        exec sway
        ;;
    *)
        exec "$COMPOSITOR"
        ;;
esac
