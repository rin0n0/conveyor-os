#!/usr/bin/env bash
# Build-time check: every program and config the OS promises must really work.
set -euo pipefail

failures=0
fail() {
    echo "CHECK FAILED: $*" >&2
    failures=$((failures + 1))
}

REQUIRED_COMMANDS=(
    greetd tuigreet driftwm niri sway waybar fuzzel swaync kanshi
    foot tmux zellij nvim micro nano yazi Thunar firefox
    git jj lazygit delta difft rg fd btop nvtop jq curl
    wl-copy cliphist wtype grim slurp pavucontrol notify-send xdg-open
    pipewire pipewire-pulse wireplumber wpctl pw-record
    nmcli nmtui nm-connection-editor vulkaninfo
    flatpak distrobox podman bwrap
    python3 python3.12 uv node npm pnpm mise pueue pueued ast-grep
    gcc g++ make cmake gdb clang
    llama-server llama-swap whisper-cli aider opencode nvidia-smi
    bluetoothctl blueman-manager blueman-applet driftmap
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || fail "command not found: $cmd"
done

export HOME=/tmp/conveyor-check-home
mkdir -p "$HOME"

# These must start, which also proves their shared libraries resolve.
for check in "llama-server --version" "whisper-cli --help" "aider --version" "opencode --version" "llama-swap -version"; do
    # shellcheck disable=SC2086
    timeout 60 $check >/dev/null 2>&1 || fail "does not run: $check"
done

# llama.cpp looks for its CPU and GPU backends next to the executable
compgen -G '/usr/local/bin/libggml-cpu-*.so' >/dev/null || fail "llama.cpp CPU backends missing"
[[ -e /usr/local/bin/libggml-vulkan.so ]] || fail "llama.cpp Vulkan backend missing"
if [[ -e /usr/local/bin/libggml-cuda.so ]]; then
    # libcuda.so.1 comes from the NVIDIA driver package, CUDA runtime libraries from the build
    missing_cuda_libs=$(ldd /usr/local/bin/libggml-cuda.so 2>&1 | grep 'not found' || true)
    [[ -z "$missing_cuda_libs" ]] || fail "llama.cpp CUDA backend cannot load: $missing_cuda_libs"
else
    fail "llama.cpp CUDA backend missing"
fi

# Neovim must load diffview.nvim; the minimap needs GTK 4 with layer shell
nvim --headless -c 'lua if not pcall(require, "diffview") then vim.cmd("cquit 1") end' -c 'qall' >/dev/null 2>&1 \
    || fail "diffview.nvim does not load in Neovim"
python3 -c 'import gi, cairo; gi.require_version("Gtk", "4.0"); gi.require_version("Gtk4LayerShell", "1.0")' \
    || fail "minimap dependencies (GTK 4, layer shell, cairo) are missing"
[[ -s /usr/local/lib/conveyor/driftmap.py ]] || fail "minimap script missing"

kernel=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)
for module in nvidia nvidia_drm nvidia_modeset nvidia_uvm nouveau; do
    modinfo -k "$kernel" "$module" >/dev/null 2>&1 || fail "kernel module missing: $module"
done
if grep -rqE '^[[:space:]]*blacklist[[:space:]]+nouveau' /usr/lib/modprobe.d /etc/modprobe.d; then
    fail "nouveau must be selected at boot, not blacklisted in the image"
fi
compgen -G '/usr/share/vulkan/icd.d/nvidia*.json' >/dev/null \
    || compgen -G '/etc/vulkan/icd.d/nvidia*.json' >/dev/null \
    || fail "NVIDIA Vulkan driver not found"

# Everything the installer needs to make the disk bootable on any UEFI PC
for efi_file in shimx64.efi grubx64.efi mmx64.efi; do
    [[ -s "/usr/lib/bootupd/updates/EFI/fedora/$efi_file" ]] || fail "EFI file missing: $efi_file"
done
[[ -s "/usr/lib/modules/$kernel/vmlinuz" ]] || fail "kernel missing"
initramfs_files=$(lsinitrd "/usr/lib/modules/$kernel/initramfs.img" 2>/dev/null || true)
builtin_modules=$(cat "/usr/lib/modules/$kernel/modules.builtin")
for needed in usb-storage uas dm-crypt btrfs; do
    # A driver compiled into the kernel does not need a file in the initramfs
    grep -q "/$needed\.ko" <<<"$initramfs_files" \
        || grep -q "/$needed\.ko" <<<"$builtin_modules" \
        || fail "initramfs is missing: $needed"
done
grep -q systemd-cryptsetup <<<"$initramfs_files" || fail "initramfs is missing: systemd-cryptsetup"
if grep -Eq '/(nvidia|nouveau)[^/]*\.ko' <<<"$initramfs_files"; then
    fail "GPU drivers must not be in the initramfs"
fi
for windows_file in Boot-Conveyor-OS.cmd Conveyor-Boot.ps1; do
    [[ -s "/usr/share/conveyor/windows/$windows_file" ]] || fail "Windows helper missing: $windows_file"
done

check_llama_swap_profile() {
    local config="$1" port="$2" log models pid role
    log=$(mktemp)
    llama-swap --config "$config" --listen "127.0.0.1:$port" >"$log" 2>&1 &
    pid=$!
    models=""
    for _ in $(seq 1 20); do
        models=$(curl -fsS -m 2 "http://127.0.0.1:$port/v1/models" 2>/dev/null || true)
        [[ -n "$models" ]] && break
        sleep 0.5
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    for role in coder fast think embed; do
        if ! jq -e --arg role "$role" '.data | map(.id) | index($role)' <<<"$models" >/dev/null 2>&1; then
            fail "$config does not expose model role: $role"
            cat "$log" >&2
        fi
    done
    rm -f "$log"
}

port=18080
for config in /etc/llama-swap/*.yaml; do
    check_llama_swap_profile "$config" "$port"
    port=$((port + 1))
done

niri validate -c /etc/skel/.config/niri/config.kdl >/dev/null 2>&1 || fail "invalid niri config"
python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
    /etc/skel/.config/waybar/config.jsonc || fail "invalid waybar config"
python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1], "rb"))' \
    /etc/skel/.config/driftwm/config.toml || fail "invalid driftwm config"

for script in /usr/local/bin/*.sh /usr/local/libexec/*.sh; do
    bash -n "$script" || fail "syntax error: $script"
done

rm -rf "$HOME"

if (( failures > 0 )); then
    echo "$failures image check(s) failed" >&2
    exit 1
fi
echo "All image checks passed"
