#!/usr/bin/env bash
set -euo pipefail

# Fast Fuzzel-based network profile selector
# Lists all saved Ethernet/Wi-Fi/VPN connections and activates the chosen one

ACTIVE_LIST=$(nmcli -t -f NAME connection show --active 2>/dev/null || true)
mapfile -t PROFILES < <(
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
    | awk -F: '$2 ~ /^(802-3-ethernet|ethernet|802-11-wireless|wifi|vpn|wireguard)$/ {print $1}'
)

GUI_ITEM="⚙ Открыть настройки сети (GUI)"
AUTO_ITEM="🔄 Автоподбор профиля (колледж / дом)"

MENU_ITEMS=""
for p in "${PROFILES[@]}"; do
    [[ -n "$p" ]] || continue
    if grep -Fxq -- "$p" <<<"$ACTIVE_LIST"; then
        MENU_ITEMS+="${p}  [активно]\n"
    else
        MENU_ITEMS+="${p}\n"
    fi
done
MENU_ITEMS+="${AUTO_ITEM}\n${GUI_ITEM}\n"

CHOICE=$(printf '%b' "$MENU_ITEMS" | fuzzel --dmenu --prompt="Сеть: " --lines=10 || true)
[[ -n "$CHOICE" ]] || exit 0

if [[ "$CHOICE" == "$GUI_ITEM" ]]; then
    exec nm-connection-editor
elif [[ "$CHOICE" == "$AUTO_ITEM" ]]; then
    /usr/local/bin/conveyor-net-auto.sh || true
    ACTIVE_NOW=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -n1 || echo "нет")
    notify-send -a "Conveyor Network" "Автоподбор завершён" "Активный профиль: ${ACTIVE_NOW}" || true
    exit 0
fi

CLEAN_NAME="${CHOICE%  \[активно\]}"
[[ -n "$CLEAN_NAME" ]] || exit 0

if ERR=$(nmcli connection up "$CLEAN_NAME" 2>&1); then
    notify-send -a "Conveyor Network" "Сеть переключена" "Активен профиль: $CLEAN_NAME" || true
else
    notify-send -u critical -a "Conveyor Network" "Ошибка подключения: $CLEAN_NAME" "$ERR" || true
fi
