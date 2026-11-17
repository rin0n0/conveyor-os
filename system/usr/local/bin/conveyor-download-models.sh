#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: Fast AI Model Downloader
# Downloads recommended models into /var/lib/models (Btrfs NoCoW) or /mnt/shared/models

MODELS_DIR="/var/lib/models"
if [[ -d "/mnt/shared/models" ]]; then
    echo "Found shared buffer at /mnt/shared/models."
fi
mkdir -p "$MODELS_DIR"

echo "=========================================================="
echo "Conveyor OS Local Model Downloader"
echo "Target directory: $MODELS_DIR"
echo "=========================================================="
echo "Select model to download:"
echo "1) Gemma 2 2B / E4B (Fast, fits 100% in 4-8 GB VRAM, ~2.5 GB)"
echo "2) Qwen 2.5 Coder 7B Instruct (State of the art code intelligence, ~4.7 GB)"
echo "3) DeepSeek R1 Distill Qwen 7B (Reasoning / Thinking model, ~4.7 GB)"
echo "4) Whisper Small (Voice-to-Prompt speech recognition, ~460 MB)"
echo "5) All recommended developer models"
echo "=========================================================="
read -rp "Enter choice [1-5]: " CHOICE

download_file() {
    local url="$1"
    local dest="$2"
    echo "Downloading: $(basename "$dest") ..."
    curl -C - -L --progress-bar -o "$dest" "$url"
    echo "Saved to $dest"
}

case "$CHOICE" in
    1)
        download_file "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf" "$MODELS_DIR/gemma-4-E4B-it-Q4_K_M.gguf"
        ;;
    2)
        download_file "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf" "$MODELS_DIR/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
        ;;
    3)
        download_file "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf" "$MODELS_DIR/deepseek-r1-distill-qwen-7b-q4_k_m.gguf"
        ;;
    4)
        download_file "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin" "$MODELS_DIR/ggml-small.bin"
        ;;
    5)
        download_file "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf" "$MODELS_DIR/gemma-4-E4B-it-Q4_K_M.gguf"
        download_file "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf" "$MODELS_DIR/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
        download_file "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin" "$MODELS_DIR/ggml-small.bin"
        ;;
    *)
        echo "Invalid selection."
        exit 1
        ;;
esac

echo ""
echo ">>> All requested models successfully downloaded into $MODELS_DIR!"
echo ">>> llama-swap will now automatically discover and serve them on http://localhost:8080/v1"
