#!/usr/bin/env bash
# Hardware probe for the portable OS. Runs after GPU drivers load and must always
# leave a usable profile behind, so detection problems fall back to CPU mode.
set -uo pipefail

RUN_DIR="${CONVEYOR_RUN_DIR:-/run}"
LLAMA_CONFIG_DIR="${CONVEYOR_LLAMA_CONFIG_DIR:-/etc/llama-swap}"
SYSFS_DRM="${CONVEYOR_SYSFS_DRM:-/sys/class/drm}"
PROFILE_ENV="$RUN_DIR/gpu-profile.env"
LLAMA_ACTIVE_CFG="$RUN_DIR/llama-swap-active.yaml"
MIN_GPU_PROFILE_VRAM_GIB=7

has_drm_card() {
    compgen -G "$SYSFS_DRM/card[0-9]*" >/dev/null
}

wait_for_gpu_drivers() {
    grep -qw nomodeset /proc/cmdline 2>/dev/null && return
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 >/dev/null 2>&1
    for _ in {1..10}; do
        has_drm_card && return
        sleep 0.5
    done
}

# Prints: <best usable device type> <largest discrete device-local heap in bytes>
probe_vulkan() {
    timeout 20 vulkaninfo 2>/dev/null | awk '
        function finish_gpu() {
            if (!seen || api_major < 1 || (api_major == 1 && api_minor < 2)) return
            if (type ~ /DISCRETE_GPU/) {
                best = "discrete"
                if (heap_max > discrete_heap) discrete_heap = heap_max
            } else if (type ~ /INTEGRATED_GPU/ && best == "none") {
                best = "integrated"
            }
        }
        BEGIN { best = "none"; discrete_heap = 0 }
        /^GPU[0-9]+:/ {
            finish_gpu()
            seen = 1; type = ""; api_major = 0; api_minor = 0
            heap_max = 0; heap_size = 0
            next
        }
        /^[[:space:]]*apiVersion[[:space:]]*=/ && api_major == 0 {
            if (match($0, /[0-9]+\.[0-9]+\.[0-9]+/)) {
                split(substr($0, RSTART, RLENGTH), version, ".")
                api_major = version[1] + 0; api_minor = version[2] + 0
            }
        }
        /^[[:space:]]*deviceType[[:space:]]*=/ && type == "" { type = $NF }
        /^[[:space:]]*memoryHeaps\[[0-9]+\]:/ { heap_size = 0 }
        /^[[:space:]]*size[[:space:]]*=/ { heap_size = $3 + 0 }
        /MEMORY_HEAP_DEVICE_LOCAL_BIT/ { if (heap_size > heap_max) heap_max = heap_size }
        END { finish_gpu(); printf "%s %.0f\n", best, discrete_heap }
    '
}

mkdir -p "$RUN_DIR"
wait_for_gpu_drivers

RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
RAM_GIB=$(( ${RAM_KB:-0} / 1024 / 1024 ))

GPU_BACKEND="cpu"
VRAM_GIB=0
WAYLAND_RENDER_MODE="hw"
has_drm_card || WAYLAND_RENDER_MODE="sw"

read -r VULKAN_DEVICE VRAM_BYTES < <(probe_vulkan || true)
case "${VULKAN_DEVICE:-none}" in
    discrete)
        GPU_BACKEND="vulkan"
        VRAM_GIB=$(( ${VRAM_BYTES:-0} / 1024 / 1024 / 1024 ))
        ;;
    integrated)
        GPU_BACKEND="vulkan"
        ;;
esac

# Integrated GPUs report 0 here: they share system RAM, so the CPU profile is the safe choice.
if (( VRAM_GIB >= MIN_GPU_PROFILE_VRAM_GIB )); then
    LLAMA_PROFILE="$LLAMA_CONFIG_DIR/config-8gb-vram-32gb-ram.yaml"
else
    LLAMA_PROFILE="$LLAMA_CONFIG_DIR/config-cpu-only.yaml"
fi

ln -sf "$LLAMA_PROFILE" "$LLAMA_ACTIVE_CFG"

cat >"$PROFILE_ENV" <<EOF
GPU_BACKEND=${GPU_BACKEND}
VRAM_GIB=${VRAM_GIB}
RAM_GIB=${RAM_GIB}
WAYLAND_RENDER_MODE=${WAYLAND_RENDER_MODE}
LLAMA_PROFILE=${LLAMA_PROFILE}
EOF
