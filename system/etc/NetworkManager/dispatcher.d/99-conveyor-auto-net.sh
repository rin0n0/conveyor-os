#!/usr/bin/env bash
# NetworkManager Dispatcher script: triggers college network auto-detect on cable plug / link up
IFACE="${1:-}"
ACTION="${2:-}"

if [[ "$ACTION" == "up" || "$ACTION" == "carrier" ]]; then
    # Run in background to avoid blocking NetworkManager
    /usr/local/bin/conveyor-net-auto.sh >/dev/null 2>&1 &
fi
