#!/usr/bin/env bash
set -euo pipefail

# Universal 2014-2026 dynamic hardware probe for portable USB boot
PROFILE_ENV="/run/gpu-profile.env"
LLAMA_ACTIVE_CFG="/run/llama-swap-active.yaml"

mkdir -p /run/modprobe.d /run/systemd/system

HAS_NVIDIA=0
NVIDIA_TURING_PLUS=0
HAS_AMD=0
HAS_INTEL=0

for dev in /sys/bus/pci/devices/*; do
    [[ -f "$dev/class" && -f "$dev/vendor" && -f "$dev/device" ]] || continue
    cls=$(cat "$dev/class")
    # Display controller class 0x03xxxx
    [[ "$cls" == 0x03* ]] || continue
    vendor=$(cat "$dev/vendor")
    device=$(cat "$dev/device")
    case "$vendor" in
        0x10de)
            HAS_NVIDIA=1
            # Turing (TU1xx: >= 0x1e00), Ampere (0x2200+), Ada (0x2600+), Blackwell (0x2b00+)
            # Pre-Turing Kepler/Maxwell/Pascal (< 0x1e00) are NOT supported by nvidia-open!
            dev_num=$((device))
            if (( dev_num >= 0x1e00 )); then
                NVIDIA_TURING_PLUS=1
            fi
            ;;
        0x1002) HAS_AMD=1 ;;
        0x8086) HAS_INTEL=1 ;;
    esac
done

# Detect system RAM in GiB
RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
RAM_GIB=$(( RAM_KB / 1024 / 1024 ))

# Safe NVIDIA handling: blacklist nvidia-open on 2014-2017 Kepler/Maxwell/Pascal or blocked SecureBoot
GPU_BACKEND="cpu"
VRAM_GIB=0
WAYLAND_RENDER_MODE="hw"

if (( HAS_NVIDIA == 1 )); then
    if (( NVIDIA_TURING_PLUS == 1 )) && modprobe --dry-run nvidia-drm >/dev/null 2>&1; then
        modprobe nvidia-drm modeset=1 fbdev=1 || true
        GPU_BACKEND="cuda"
        if command -v nvidia-smi >/dev/null 2>&1; then
            VRAM_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 || echo 0)
            VRAM_GIB=$(( VRAM_MIB / 1024 ))
        fi
    else
        # Force nouveau for Wayland display on pre-Turing 2014-2017 NVIDIA cards
        cat > /run/modprobe.d/00-no-nvidia.conf <<'EOF'
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
install nvidia /bin/false
EOF
        systemctl mask --runtime nvidia-persistenced.service nvidia-powerd.service >/dev/null 2>&1 || true
    fi
fi

# Check Vulkan >= 1.2 for AMD / Intel GPUs (skips broken Haswell 2014 ANV / legacy radeon)
if [[ "$GPU_BACKEND" == "cpu" ]] && (( HAS_AMD == 1 || HAS_INTEL == 1 )); then
    if command -v vulkaninfo >/dev/null 2>&1; then
        VK_VER=$(vulkaninfo --summary 2>/dev/null | awk '/apiVersion/ {print $3; exit}' || true)
        if [[ -n "$VK_VER" ]]; then
            # Accept Vulkan 1.2+ (ignore llvmpipe software vulkan for LLM inference)
            if ! vulkaninfo --summary 2>/dev/null | grep -qi "llvmpipe"; then
                GPU_BACKEND="vulkan"
            fi
        fi
    fi
    # Read AMD VRAM from sysfs if present
    for vram_file in /sys/class/drm/card*/device/mem_info_vram_total; do
        if [[ -f "$vram_file" ]]; then
            BYTES=$(cat "$vram_file")
            VRAM_GIB=$(( BYTES / 1024 / 1024 / 1024 ))
            break
        fi
    done
fi

# Select llama-swap hardware tier dynamically
if (( VRAM_GIB >= 7 && RAM_GIB >= 28 )); then
    LLAMA_PROFILE="/etc/llama-swap/config-8gb-vram-32gb-ram.yaml"
else
    LLAMA_PROFILE="/etc/llama-swap/config-cpu-only.yaml"
fi

ln -sf "$LLAMA_PROFILE" "$LLAMA_ACTIVE_CFG"

cat > "$PROFILE_ENV" <<EOF
GPU_BACKEND=${GPU_BACKEND}
VRAM_GIB=${VRAM_GIB}
RAM_GIB=${RAM_GIB}
WAYLAND_RENDER_MODE=${WAYLAND_RENDER_MODE}
LLAMA_PROFILE=${LLAMA_PROFILE}
EOF
