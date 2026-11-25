#!/usr/bin/env bash
# Hardware probe for the portable OS. Runs after GPU drivers load and must always
# leave a usable profile behind, so detection problems fall back to CPU mode.
#
# Compute backend, best first:
#   cuda   - NVIDIA driver loaded, driver supports CUDA 13, every GPU is Turing or newer
#   vulkan - any GPU with Vulkan 1.2+
#   cpu    - everything else
set -uo pipefail

RUN_DIR="${CONVEYOR_RUN_DIR:-/run}"
LLAMA_CONFIG_DIR="${CONVEYOR_LLAMA_CONFIG_DIR:-/etc/llama-swap}"
LLAMA_BIN_DIR="${CONVEYOR_LLAMA_BIN_DIR:-/usr/local/bin}"
SYSFS_DRM="${CONVEYOR_SYSFS_DRM:-/sys/class/drm}"
SYSFS_MODULE="${CONVEYOR_SYSFS_MODULE:-/sys/module}"
PROFILE_ENV="$RUN_DIR/gpu-profile.env"
LLAMA_ACTIVE_CFG="$RUN_DIR/llama-swap-active.yaml"
LOG_FILE="$RUN_DIR/gpu-detect.log"
# Allow 4+ GB cards (e.g. Quadro P1000, RTX 3050 4GB) to use GPU profile with --fit on
MIN_GPU_PROFILE_VRAM_GIB=3
# The CUDA backend is built with CUDA 13: it needs a CUDA 13 driver and compute capability 7.5+
REQUIRED_CUDA_MAJOR=13
MIN_COMPUTE_CAPABILITY=75

mkdir -p "$RUN_DIR"
log() {
    printf '[boot-gpu-detect] %s\n' "$*" >>"$LOG_FILE"
}
: >"$LOG_FILE"

has_drm_card() {
    compgen -G "$SYSFS_DRM/card[0-9]*" >/dev/null
}

has_nvidia_pci() {
    command -v lspci >/dev/null 2>&1 && lspci -nn 2>/dev/null | grep -Eqi '(VGA|3D|Display).*\[10de:'
}

# Check if any DRM card is actually bound to nvidia or nouveau (not just simpledrm)
drm_driver_bound() {
    local card drv
    for card in "$SYSFS_DRM"/card[0-9]*; do
        [[ -e "$card/device/driver" ]] || continue
        drv=$(basename "$(readlink -f "$card/device/driver")" 2>/dev/null || true)
        if [[ "$drv" != "simple-framebuffer" && "$drv" != "simpledrm" && -n "$drv" ]]; then
            return 0
        fi
    done
    return 1
}

wait_for_gpu_drivers() {
    grep -qw nomodeset /proc/cmdline 2>/dev/null && return
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 >/dev/null 2>&1
    for _ in {1..10}; do
        drm_driver_bound && return
        sleep 0.5
    done
}

# If an NVIDIA GPU is present (e.g. Pascal Quadro P1000) and nvidia-open refused to bind it
# while nouveau was blacklisted by GRUB, explicitly load nouveau as a fallback.
recover_legacy_nvidia() {
    grep -qw nomodeset /proc/cmdline 2>/dev/null && return
    has_nvidia_pci || return
    drm_driver_bound && return
    [[ -d "$SYSFS_MODULE/nouveau" ]] && return

    log "NVIDIA PCI device found, but no hardware DRM driver bound (likely pre-Turing GPU rejected by nvidia-open)."
    log "Attempting explicit fallback to nouveau..."
    modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>>"$LOG_FILE" || true
    if modprobe nouveau 2>>"$LOG_FILE"; then
        command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=5 >/dev/null 2>&1 || true
        for _ in {1..8}; do
            drm_driver_bound && break
            sleep 0.5
        done
        log "nouveau fallback loaded (drm_driver_bound=$(drm_driver_bound && echo yes || echo no))."
    else
        log "Failed to load nouveau fallback."
    fi
}

# Prints: <best usable device type> <largest discrete device-local heap in bytes>
probe_vulkan() {
    local extra_env="${1:-}"
    env $extra_env timeout 20 vulkaninfo 2>/dev/null | awk '
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

# Prints: <cuda device count> <largest GPU memory in MiB>, or fails when CUDA is not usable
probe_cuda() {
    if [[ ! -d "$SYSFS_MODULE/nvidia" ]]; then
        log "probe_cuda: /sys/module/nvidia not present"
        return 1
    fi
    if [[ ! -e "$LLAMA_BIN_DIR/libggml-cuda.so" ]]; then
        log "probe_cuda: libggml-cuda.so missing"
        return 1
    fi
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log "probe_cuda: nvidia-smi not found"
        return 1
    fi

    # Ensure /dev/nvidiactl, /dev/nvidia0, /dev/nvidia-uvm exist before greetd/Wayland starts
    if command -v nvidia-modprobe >/dev/null 2>&1; then
        nvidia-modprobe -c=0 2>>"$LOG_FILE" || true
        nvidia-modprobe -u -c=0 2>>"$LOG_FILE" || true
    fi

    local summary driver_cuda_major gpus
    if ! summary=$(timeout 20 nvidia-smi 2>>"$LOG_FILE"); then
        log "probe_cuda: nvidia-smi failed"
        return 1
    fi
    driver_cuda_major=$(sed -n 's/.*CUDA Version: *\([0-9][0-9]*\)\..*/\1/p' <<<"$summary" | head -n1)
    log "probe_cuda: driver reports CUDA major=${driver_cuda_major:-unknown}"
    if (( ${driver_cuda_major:-0} < REQUIRED_CUDA_MAJOR )); then
        log "probe_cuda: driver CUDA ${driver_cuda_major:-0} < required $REQUIRED_CUDA_MAJOR"
        return 1
    fi

    if ! gpus=$(timeout 20 nvidia-smi --query-gpu=compute_cap,memory.total --format=csv,noheader,nounits 2>>"$LOG_FILE"); then
        log "probe_cuda: nvidia-smi --query-gpu failed"
        return 1
    fi
    log "probe_cuda: GPUs=${gpus//$'\n'/; }"

    awk -F', *' -v min_cc="$MIN_COMPUTE_CAPABILITY" '
        NF < 2 { next }
        {
            split($1, cc, ".")
            if ((cc[1] * 10 + cc[2]) < min_cc) unsupported = 1
            count++
            if ($2 + 0 > max_mib) max_mib = $2 + 0
        }
        END {
            if (count == 0 || unsupported) exit 1
            printf "%d %d\n", count, max_mib
        }
    ' <<<"$gpus"
}

wait_for_gpu_drivers
recover_legacy_nvidia

RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
RAM_GIB=$(( ${RAM_KB:-0} / 1024 / 1024 ))

GPU_BACKEND="cpu"
VRAM_GIB=0
LLAMA_DEVICES=""
EXTRA_GPU_ENV=""
WAYLAND_RENDER_MODE="hw"
has_drm_card || WAYLAND_RENDER_MODE="sw"

if read -r CUDA_COUNT CUDA_MIB < <(probe_cuda); then
    GPU_BACKEND="cuda"
    VRAM_GIB=$(( (CUDA_MIB + 512) / 1024 ))
    # Only CUDA devices: otherwise llama.cpp would also use the same card through Vulkan
    for (( index = 0; index < CUDA_COUNT; index++ )); do
        LLAMA_DEVICES+="${LLAMA_DEVICES:+,}CUDA${index}"
    done
    log "Selected CUDA backend: devices=${LLAMA_DEVICES}, VRAM=${VRAM_GIB}GiB"
else
    read -r VULKAN_DEVICE VRAM_BYTES < <(probe_vulkan || true)
    # For pre-Turing NVIDIA cards on nouveau (e.g. Pascal Quadro P1000), try NVK experimental flag
    if [[ "${VULKAN_DEVICE:-none}" == "none" && -d "$SYSFS_MODULE/nouveau" ]]; then
        log "Standard Vulkan probe found no device on nouveau; testing NVK_I_WANT_A_BROKEN_VULKAN_DRIVER=1"
        read -r VULKAN_DEVICE VRAM_BYTES < <(probe_vulkan "NVK_I_WANT_A_BROKEN_VULKAN_DRIVER=1" || true)
        if [[ "${VULKAN_DEVICE:-none}" != "none" ]]; then
            EXTRA_GPU_ENV="NVK_I_WANT_A_BROKEN_VULKAN_DRIVER=1"
            log "NVK unlocked Vulkan device: type=${VULKAN_DEVICE}, bytes=${VRAM_BYTES}"
        fi
    fi

    case "${VULKAN_DEVICE:-none}" in
        discrete)
            GPU_BACKEND="vulkan"
            VRAM_GIB=$(( (${VRAM_BYTES:-0} + 536870912) / 1073741824 ))
            ;;
        integrated)
            GPU_BACKEND="vulkan"
            ;;
    esac
    log "Selected ${GPU_BACKEND} backend: vulkan_type=${VULKAN_DEVICE:-none}, VRAM=${VRAM_GIB}GiB"
fi

# Integrated GPUs report 0 here: they share system RAM, so the CPU profile is the safe choice.
if (( VRAM_GIB >= MIN_GPU_PROFILE_VRAM_GIB )); then
    LLAMA_PROFILE="$LLAMA_CONFIG_DIR/config-8gb-vram-32gb-ram.yaml"
else
    LLAMA_PROFILE="$LLAMA_CONFIG_DIR/config-cpu-only.yaml"
fi

# The active config is a generated copy: it pins llama-server to the chosen devices
ACTIVE_TMP="$LLAMA_ACTIVE_CFG.tmp"
if [[ -n "$LLAMA_DEVICES" ]]; then
    sed -E "s/^([[:space:]]*)llama-server[[:space:]]*$/\1llama-server --device ${LLAMA_DEVICES}/" "$LLAMA_PROFILE" >"$ACTIVE_TMP"
elif [[ -n "$EXTRA_GPU_ENV" ]]; then
    sed -E "s/^([[:space:]]*)llama-server[[:space:]]*$/\1env ${EXTRA_GPU_ENV} llama-server/" "$LLAMA_PROFILE" >"$ACTIVE_TMP"
else
    cp "$LLAMA_PROFILE" "$ACTIVE_TMP"
fi
mv -f "$ACTIVE_TMP" "$LLAMA_ACTIVE_CFG"

cat >"$PROFILE_ENV" <<EOF
GPU_BACKEND=${GPU_BACKEND}
VRAM_GIB=${VRAM_GIB}
RAM_GIB=${RAM_GIB}
LLAMA_DEVICES=${LLAMA_DEVICES}
WAYLAND_RENDER_MODE=${WAYLAND_RENDER_MODE}
LLAMA_PROFILE=${LLAMA_PROFILE}
EOF
if [[ -n "$EXTRA_GPU_ENV" ]]; then
    echo "$EXTRA_GPU_ENV" >>"$PROFILE_ENV"
fi
