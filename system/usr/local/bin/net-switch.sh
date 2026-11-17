#!/usr/bin/env bash
set -euo pipefail

# Fast Fuzzel-based network profile selector
# Lists available connections and activates the chosen one

ACTIVE=$(nmcli -t -f NAME connection show --active | head -n1 || true)
PROFILES=$(nmcli -t -f NAME,TYPE,IPV4.METHOD connection show | grep -E ':(802-3-ethernet|ethernet|802-11-wireless|wifi):' | cut -d: -f1 || true)

if [[ -z "$PROFILES" ]]; then
    notify-send -a "Conveyor Network" "Сетевые профили" "Профили подключений не найдены. Создайте их через Super+N"
    exit 0
fi

MENU_ITEMS=""
while IFS= read -r p; do
    if [[ "$p" == "$ACTIVE" ]]; then
        MENU_ITEMS+="${p}  [активно]\n"
    else
        MENU_ITEMS+="${p}\n"
    fi
done <<< "$PROFILES"

CHOICE=$(echo -e "$MENU_ITEMS" | fuzzel --dmenu --prompt="Сеть: " --lines=8 || true)

if [[ -n "$CHOICE" ]]; then
    CLEAN_NAME=$(echo "$CHOICE" | sed 's/  \[активно\]//g' | xargs)
    if [[ -n "$CLEAN_NAME" ]]; then
        nmcli connection up "$CLEAN_NAME"
        notify-send -a "Conveyor Network" "Сеть переключена" "Активен профиль: $CLEAN_NAME"
    fi
fi
