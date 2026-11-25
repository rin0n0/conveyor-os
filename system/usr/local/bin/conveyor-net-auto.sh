#!/usr/bin/env bash
set -uo pipefail

# Conveyor OS: College Multi-Subnet Auto-Detector & Switcher
# Probes known static gateways via ARP/Ping and auto-activates the correct classroom profile.

LOCK_FILE="/run/conveyor-net-auto.lock"
STAMP_FILE="/run/conveyor-net-auto.stamp"
COOLDOWN_SEC=10

# Prevent concurrent runs or dispatcher recursion loops
if [[ -w /run ]]; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
    if [[ -f "$STAMP_FILE" ]]; then
        last=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)
        now=$(date +%s)
        if (( now - last < COOLDOWN_SEC )); then
            exit 0
        fi
    fi
    date +%s >"$STAMP_FILE"
fi

log() {
    echo "[conveyor-net-auto] $*"
    command -v logger >/dev/null 2>&1 && logger -t conveyor-net-auto "$*" 2>/dev/null || true
}

# Find primary Ethernet interface (with carrier preferred)
IFACE=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
    | awk -F: '$2 == "ethernet" && $3 != "unavailable" {print $1; exit}')
if [[ -z "$IFACE" ]]; then
    IFACE=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "ethernet" {print $1; exit}')
fi
if [[ -z "$IFACE" ]]; then
    log "No Ethernet device found."
    exit 0
fi

# If current connection already reaches the internet, do not disturb it
if ping -c 1 -W 1 -I "$IFACE" 1.1.1.1 >/dev/null 2>&1; then
    log "Interface $IFACE already has internet access; keeping current profile."
    exit 0
fi

log "Probing saved static profiles on $IFACE..."

FOUND_PROFILE=""
while IFS=: read -r name type; do
    [[ "$type" == "802-3-ethernet" || "$type" == "ethernet" ]] || continue
    [[ -n "$name" ]] || continue

    method=$(nmcli -g ipv4.method connection show "$name" 2>/dev/null | head -n1 || true)
    gateway=$(nmcli -g ipv4.gateway connection show "$name" 2>/dev/null | head -n1 || true)
    [[ "$method" == "manual" && -n "$gateway" && "$gateway" != "--" ]] || continue

    log "Testing gateway $gateway for profile '$name'..."
    if arping -c 1 -w 1 -I "$IFACE" "$gateway" >/dev/null 2>&1 || ping -c 1 -W 1 -I "$IFACE" "$gateway" >/dev/null 2>&1; then
        log "Gateway $gateway responded! Matching profile: $name"
        FOUND_PROFILE="$name"
        break
    fi
done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)

if [[ -n "$FOUND_PROFILE" ]]; then
    log "Activating profile '$FOUND_PROFILE'..."
    nmcli connection up "$FOUND_PROFILE" ifname "$IFACE" >/dev/null 2>&1 || nmcli connection up "$FOUND_PROFILE" >/dev/null 2>&1 || true
else
    log "No static gateway responded. Looking for DHCP/Auto Ethernet profile..."
    while IFS=: read -r name type; do
        [[ "$type" == "802-3-ethernet" || "$type" == "ethernet" ]] || continue
        method=$(nmcli -g ipv4.method connection show "$name" 2>/dev/null | head -n1 || true)
        if [[ "$method" == "auto" ]]; then
            log "Activating DHCP profile '$name'..."
            nmcli connection up "$name" ifname "$IFACE" >/dev/null 2>&1 || true
            break
        fi
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
fi
