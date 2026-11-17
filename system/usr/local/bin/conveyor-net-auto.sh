#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: College Multi-Subnet Auto-Detector & Switcher
# Probes known static gateways via ARP/Ping and auto-activates the correct classroom profile.

# Find primary active Ethernet interface
IFACE=$(nmcli -t -f DEVICE,TYPE device status | grep ':ethernet$' | cut -d: -f1 | head -n1 || true)
if [[ -z "$IFACE" ]]; then
    # Fallback to Wi-Fi if no Ethernet
    IFACE=$(nmcli -t -f DEVICE,TYPE device status | grep ':wifi$' | cut -d: -f1 | head -n1 || true)
fi

if [[ -z "$IFACE" ]]; then
    echo "No Ethernet or Wi-Fi device found."
    exit 0
fi

echo "Probing network environments on $IFACE..."

# Read all configured NetworkManager profiles with static IPv4 gateways
PROFILES=$(nmcli -t -f NAME,TYPE,IPV4.GATEWAY,IPV4.METHOD connection show)

FOUND_PROFILE=""

# Check each static profile's gateway via fast ARP ping (50-200ms Layer-2 probe)
while IFS=: read -r name type gateway method; do
    [[ "$type" == "802-3-ethernet" || "$type" == "ethernet" || "$type" == "wifi" || "$type" == "802-11-wireless" ]] || continue
    [[ "$method" == "manual" ]] || continue
    [[ -n "$gateway" ]] || continue

    echo "Testing gateway $gateway for profile '$name'..."
    if arping -c 1 -w 1 -I "$IFACE" "$gateway" >/dev/null 2>&1 || ping -c 1 -W 1 -I "$IFACE" "$gateway" >/dev/null 2>&1; then
        echo ">>> Gateway $gateway responded! Matching profile: $name"
        FOUND_PROFILE="$name"
        break
    fi
done <<< "$PROFILES"

if [[ -n "$FOUND_PROFILE" ]]; then
    echo "Activating profile '$FOUND_PROFILE'..."
    nmcli connection up "$FOUND_PROFILE" >/dev/null 2>&1 || true
    
    # Check internet reachability
    if curl -s --connect-timeout 2 http://connectivity-check.ubuntu.com >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        STATUS_MSG="Интернет доступен"
    else
        STATUS_MSG="Шлюз доступен, но внешний интернет закрыт"
    fi

    echo "Network connected: $FOUND_PROFILE ($STATUS_MSG)"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Conveyor Network" "Сеть: $FOUND_PROFILE" "$STATUS_MSG" || true
    fi
else
    echo "No static college gateway responded. Falling back to DHCP/Auto profile..."
    DHCP_PROFILE=$(nmcli -t -f NAME,IPV4.METHOD connection show | grep ':auto$' | cut -d: -f1 | head -n1 || true)
    if [[ -n "$DHCP_PROFILE" ]]; then
        nmcli connection up "$DHCP_PROFILE" >/dev/null 2>&1 || true
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -a "Conveyor Network" "Сеть: DHCP / Авто" "Используется динамический IP" || true
        fi
    fi
fi
