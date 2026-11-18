#!/usr/bin/env bash
# Runs in the background after login and installs per-user software that cannot
# live in the read-only image. Safe to repeat: a failed step retries next login.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/conveyor"
AGY_BIN="$HOME/.local/bin/agy"
AGY_INSTALLER_URL="https://antigravity.google/cli/install.sh"
FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"

mkdir -p "$STATE_DIR"
exec >>"$STATE_DIR/user-setup.log" 2>&1
exec 9>"$STATE_DIR/user-setup.lock"
flock -n 9 || exit 0

echo "=== $(date --iso-8601=seconds)"

notify() {
    notify-send -a "Conveyor OS" "$@" || true
}

agy_ready() {
    [[ -x "$AGY_BIN" ]]
}

flathub_ready() {
    flatpak remotes --user --columns=name 2>/dev/null | grep -qx flathub
}

agy_ready && flathub_ready && exit 0

# Let the desktop and its notification daemon start first
sleep 15

for _ in $(seq 1 24); do
    curl -fsSI -m 5 https://antigravity.google >/dev/null 2>&1 && break
    sleep 5
done

if ! flathub_ready; then
    flatpak remote-add --user --if-not-exists flathub "$FLATHUB_URL" || echo "Flathub setup failed"
fi

if ! agy_ready; then
    notify "Установка Antigravity CLI" "Скачиваю agy, это займёт пару минут."
    installer=$(mktemp)
    if curl -fsSL "$AGY_INSTALLER_URL" -o "$installer" && bash "$installer" && agy_ready; then
        notify "Antigravity CLI установлен" "Откройте терминал и введите agy."
    else
        echo "Antigravity CLI installation failed"
        notify -u critical "Antigravity CLI не установлен" "Повторю при следующем входе. Журнал: $STATE_DIR/user-setup.log"
    fi
    rm -f "$installer"
fi
