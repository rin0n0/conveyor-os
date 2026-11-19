#!/usr/bin/env bash
# Super+M in DriftWM: start the minimap, or show/hide it when it is already running.
set -euo pipefail

if pgrep -f '/usr/local/lib/conveyor/driftmap.py' >/dev/null 2>&1; then
    exec driftmap --show
fi

if [[ "${XDG_CURRENT_DESKTOP:-}" != *driftwm* && -z "${DRIFTWM_SOCKET:-}" ]] && ! pgrep -x driftwm >/dev/null 2>&1; then
    notify-send -a "Мини-карта" "Мини-карта работает только в DriftWM" || true
    exit 0
fi

driftmap >/dev/null 2>&1 &
