#!/usr/bin/env bash
# NetworkManager Dispatcher script: triggers college network auto-detect when Ethernet comes up
IFACE="${1:-}"
ACTION="${2:-}"

if [[ "$ACTION" == "up" || "$ACTION" == "connectivity-change" ]]; then
    # Run in background with lock/cooldown inside conveyor-net-auto.sh to prevent loops
    /usr/local/bin/conveyor-net-auto.sh >/dev/null 2>&1 &
fi
