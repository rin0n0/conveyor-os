#!/usr/bin/env bash
# Runs before the desktop starts. /etc/skel only reaches new users, so config
# fixes for an existing home are applied here once per CONFIG_VERSION.
# Changed files are backed up to ~/.config/conveyor/backup-v<old>-<timestamp>.
set -euo pipefail

# 1: terminal, keyboard layouts, clipboard, screenshots.
# 2: Bluetooth, minimap keys.
# 3: Super+F1 user manual.
# 4: Super+E Thunar, Waybar cleanup & style, fuzzel foot -e, Zellij layout fix.
CONFIG_VERSION=4
SKEL_DIR=/etc/skel/.config
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_DIR="$CONFIG_DIR/conveyor"
VERSION_FILE="$STATE_DIR/config-version"
MANAGED_FILES=(
    driftwm/config.toml
    niri/config.kdl
    sway/config
    waybar/config.jsonc
    waybar/style.css
    fuzzel/fuzzel.ini
    zellij/layouts/conveyor.kdl
)

current_version=0
if [[ -f "$VERSION_FILE" ]]; then
    current_version=$(<"$VERSION_FILE")
fi
[[ "$current_version" =~ ^[0-9]+$ ]] || current_version=0
(( current_version >= CONFIG_VERSION )) && exit 0

backup_dir="$STATE_DIR/backup-v${current_version}-$(date +%Y%m%d-%H%M%S)"

for relative in "${MANAGED_FILES[@]}"; do
    source_file="$SKEL_DIR/$relative"
    target_file="$CONFIG_DIR/$relative"
    [[ -f "$source_file" ]] || continue
    cmp -s "$source_file" "$target_file" && continue
    if [[ -e "$target_file" ]]; then
        mkdir -p "$backup_dir/$(dirname "$relative")"
        cp -a "$target_file" "$backup_dir/$relative"
    fi
    mkdir -p "$(dirname "$target_file")"
    cp "$source_file" "$target_file"
done

mkdir -p "$STATE_DIR"
echo "$CONFIG_VERSION" >"$VERSION_FILE"
