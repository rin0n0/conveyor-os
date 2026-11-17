#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: Turnkey ComfyUI Launcher & Fast Installer
# Uses 'uv' for instant dependency provisioning and links models with Windows Shared Buffer

COMFY_DIR="${HOME}/comfyui"
SHARED_MODELS="/mnt/shared/models/comfyui"

# Ensure shared model directories exist on the 50GB exchange partition
mkdir -p "$SHARED_MODELS/checkpoints" \
         "$SHARED_MODELS/loras" \
         "$SHARED_MODELS/vae" \
         "$SHARED_MODELS/controlnet" 2>/dev/null || true

if [[ ! -d "$COMFY_DIR" ]]; then
    echo "=========================================================="
    echo "Deploying ComfyUI on Conveyor OS..."
    echo "=========================================================="
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
    cd "$COMFY_DIR"

    echo "Provisioning Python virtual environment via uv..."
    uv venv
    # shellcheck source=/dev/null
    source .venv/bin/activate

    # Detect GPU hardware
    if lspci 2>/dev/null | grep -qi 'nvidia'; then
        echo "NVIDIA GPU detected. Installing PyTorch with CUDA 12.4..."
        uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
    elif lspci 2>/dev/null | grep -qi 'amd\|radeon'; then
        echo "AMD GPU detected. Installing PyTorch with ROCm..."
        uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.1 || \
        uv pip install torch torchvision torchaudio
    else
        echo "CPU / Intel Vulkan environment. Installing standard PyTorch..."
        uv pip install torch torchvision torchaudio
    fi

    echo "Installing ComfyUI requirements..."
    uv pip install -r requirements.txt
    echo "ComfyUI setup complete!"
fi

cd "$COMFY_DIR"
# shellcheck source=/dev/null
source .venv/bin/activate

# Symlink models from shared buffer into ComfyUI models folder
if [[ -d "$SHARED_MODELS/checkpoints" ]]; then
    mkdir -p "$COMFY_DIR/models/checkpoints"
    ln -sf "$SHARED_MODELS/checkpoints"/* "$COMFY_DIR/models/checkpoints/" 2>/dev/null || true
fi
if [[ -d "$SHARED_MODELS/loras" ]]; then
    mkdir -p "$COMFY_DIR/models/loras"
    ln -sf "$SHARED_MODELS/loras"/* "$COMFY_DIR/models/loras/" 2>/dev/null || true
fi

echo "=========================================================="
echo "Starting ComfyUI on http://127.0.0.1:8188"
echo "Shared models directory: $SHARED_MODELS"
echo "=========================================================="

(sleep 3 && firefox http://127.0.0.1:8188 >/dev/null 2>&1) &
python main.py --listen 127.0.0.1 --port 8188
