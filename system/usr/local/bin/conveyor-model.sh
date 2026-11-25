#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: Model Installer & Scenario Tagging Registry
# Manages downloaded GGUF/Safetensors weights, maps them to scenario aliases for llama-swap and ComfyUI

MODELS_DIR="/var/lib/models"
SHARED_DIR="/mnt/shared/models"
COMFY_DIR="${HOME}/comfyui/models"
SHARED_COMFY="/mnt/shared/models/comfyui"

mkdir -p "$MODELS_DIR" 2>/dev/null || true
mkdir -p "$SHARED_DIR" 2>/dev/null || true

# Function to list currently active scenario assignments
cmd_list() {
    echo "=========================================================="
    echo "Conveyor OS: Active Model Scenarios (llama-swap & ComfyUI)"
    echo "=========================================================="
    printf "%-18s %-32s %-12s\n" "СЦЕНАРИЙ (ALIAS)" "ТЕКУЩИЙ ФАЙЛ" "РАЗМЕР"
    echo "----------------------------------------------------------"

    for role in "coder" "fast" "think" "embed"; do
        link="$MODELS_DIR/active-${role}.gguf"
        if [[ -L "$link" ]]; then
            target=$(readlink -f "$link")
            size=$(ls -lh "$target" 2>/dev/null | awk '{print $5}' || echo "N/A")
            base=$(basename "$target")
            printf "%-18s %-32s %-12s\n" "[$role]" "$base" "$size"
        else
            printf "%-18s %-32s %-12s\n" "[$role]" "(не назначен)" "-"
        fi
    done

    echo "----------------------------------------------------------"
    echo "ComfyUI Checkpoints ($SHARED_COMFY/checkpoints):"
    if [[ -d "$SHARED_COMFY/checkpoints" ]]; then
        find "$SHARED_COMFY/checkpoints" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.ckpt" \) 2>/dev/null | while read -r ckpt; do
            sz=$(ls -lh "$ckpt" 2>/dev/null | awk '{print $5}' || echo "")
            echo "  * $(basename "$ckpt") ($sz)"
        done
    else
        echo "  (папка пуста или не смонтирована)"
    fi
    echo "=========================================================="
}

# Function to assign a file to a scenario
assign_model() {
    local src_file="$1"
    local role="$2"
    local mode="${3:-link}" # link or copy

    if [[ ! -f "$src_file" ]]; then
        echo "Ошибка: Файл '$src_file' не найден!" >&2
        exit 1
    fi

    local abs_src
    abs_src=$(realpath "$src_file")

    case "$role" in
        coder|fast|think|embed)
            if [[ "$abs_src" != *.gguf ]]; then
                echo "Ошибка: для роли [$role] нужен файл .gguf" >&2
                exit 1
            fi
            if [[ ! -w "$MODELS_DIR" ]]; then
                echo "Ошибка: нет прав на запись в $MODELS_DIR" >&2
                exit 1
            fi
            local target_link="$MODELS_DIR/active-${role}.gguf"
            if [[ "$mode" == "copy" ]]; then
                echo "Копирование файла в $MODELS_DIR (Btrfs NoCoW)..."
                local dest_file="$MODELS_DIR/$(basename "$abs_src")"
                if [[ "$abs_src" != "$dest_file" ]]; then
                    cp -v "$abs_src" "$dest_file"
                fi
                ln -sfn "$dest_file" "$target_link"
            else
                echo "Создание символической ссылки на $abs_src..."
                ln -sfn "$abs_src" "$target_link"
            fi
            # Unload running models so the next request starts the new file
            curl -fsS -m 10 -X POST http://127.0.0.1:8080/api/models/unload >/dev/null 2>&1 || true
            echo ">>> УСПЕХ: Роль [$role] теперь указывает на $(basename "$abs_src")"
            echo ">>> Сервис llama-swap будет использовать эту модель при следующем запросе к '$role'."
            ;;
        comfy-checkpoint|comfy-lora)
            local subdir="checkpoints"
            [[ "$role" == "comfy-lora" ]] && subdir="loras"
            local target_dir="$SHARED_COMFY/$subdir"
            mkdir -p "$target_dir" 2>/dev/null || true

            # exFAT (/mnt/shared) does not support symlinks; only copy into shared or symlink inside Btrfs ~/comfyui
            if [[ "$abs_src" != "$target_dir/"* && "$mode" == "copy" ]]; then
                echo "Копирование файла в $target_dir (exFAT не поддерживает симлинки)..."
                cp -v "$abs_src" "$target_dir/$(basename "$abs_src")"
            elif [[ "$abs_src" != "$target_dir/"* && ! -d "$COMFY_DIR" ]]; then
                echo "Примечание: exFAT (/mnt/shared) не поддерживает симлинки."
                echo "Файл оставлен в $abs_src; для общего хранения скопируйте его с режимом 'copy' или в $target_dir."
            fi

            if [[ -d "$COMFY_DIR" ]]; then
                mkdir -p "$COMFY_DIR/$subdir"
                ln -sfn "$abs_src" "$COMFY_DIR/$subdir/$(basename "$abs_src")"
            fi
            echo ">>> УСПЕХ: $(basename "$abs_src") зарегистрирован как [$role] для ComfyUI!"
            ;;
        *)
            echo "Неизвестный сценарий: $role" >&2
            echo "Допустимые сценарии: coder, fast, think, embed, comfy-checkpoint, comfy-lora" >&2
            exit 1
            ;;
    esac
}

# If arguments provided: conveyor-model install <file> <role> [link|copy]
if [[ "${1:-}" == "install" || "${1:-}" == "set" || "${1:-}" == "register" ]]; then
    if [[ $# -lt 3 ]]; then
        echo "Использование: conveyor-model install <файл> <сценарий> [link|copy]" >&2
        exit 1
    fi
    assign_model "$2" "$3" "${4:-link}"
    exit 0
fi

if [[ "${1:-}" == "list" || "${1:-}" == "status" ]]; then
    cmd_list
    exit 0
fi

# Interactive mode: scan detected files
echo "=========================================================="
echo "Conveyor OS: Менеджер установки и разметки моделей"
echo "=========================================================="
echo "Поиск скачанных весов (.gguf, .safetensors, .ckpt)..."

SEARCH_DIRS=("$SHARED_DIR" "/mnt/shared" "${HOME}/Downloads" "$MODELS_DIR")
CANDIDATES=()

while IFS= read -r f; do
    [[ -f "$f" ]] && CANDIDATES+=("$f")
done < <(find "${SEARCH_DIRS[@]}" -maxdepth 2 -type f \( -name "*.gguf" -o -name "*.safetensors" -o -name "*.ckpt" \) 2>/dev/null | sort -u)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "В стандартных папках (диск E: /mnt/shared, ~/Downloads, /var/lib/models) весов не обнаружено."
    echo ""
    read -rp "Введите полный путь к скачанному файлу вручную: " MANUAL_FILE
    if [[ -f "$MANUAL_FILE" ]]; then
        CANDIDATES+=("$MANUAL_FILE")
    else
        echo "Файл не найден."
        exit 1
    fi
fi

echo "Найдены следующие файлы:"
for i in "${!CANDIDATES[@]}"; do
    f="${CANDIDATES[$i]}"
    sz=$(ls -lh "$f" 2>/dev/null | awk '{print $5}' || echo "N/A")
    printf " [%2d] %-40s (%s) [%s]\n" $((i+1)) "$(basename "$f")" "$sz" "$(dirname "$f")"
done

echo "----------------------------------------------------------"
read -rp "Выберите номер файла для установки [1-${#CANDIDATES[@]}]: " FILE_IDX

if ! [[ "$FILE_IDX" =~ ^[0-9]+$ ]] || (( FILE_IDX < 1 || FILE_IDX > ${#CANDIDATES[@]} )); then
    echo "Некорректный номер."
    exit 1
fi

SELECTED_FILE="${CANDIDATES[$((FILE_IDX-1))]}"
echo "Выбран файл: $(basename "$SELECTED_FILE")"
echo ""
echo "Выберите сценарий авто-использования:"
echo " 1) [coder]            Основная модель кода (для Aider, OpenCode, VS Code)"
echo " 2) [fast]             Быстрая модель (короткие ответы, чат, триаж)"
echo " 3) [think]            Глубокие рассуждения / логика (DeepSeek-R1 / QwQ)"
echo " 4) [embed]            Векторные эмбеддинги для RAG и поиска"
echo " 5) [comfy-checkpoint] Чекпоинт для генерации изображений (SD 1.5, SDXL, Flux)"
echo " 6) [comfy-lora]       LoRA для ComfyUI"
echo "----------------------------------------------------------"
read -rp "Введите номер сценария [1-6]: " ROLE_IDX

case "$ROLE_IDX" in
    1) ROLE="coder" ;;
    2) ROLE="fast" ;;
    3) ROLE="think" ;;
    4) ROLE="embed" ;;
    5) ROLE="comfy-checkpoint" ;;
    6) ROLE="comfy-lora" ;;
    *) echo "Неверный выбор сценария."; exit 1 ;;
esac

echo ""
echo "Способ подключения:"
echo " 1) Символическая ссылка (Рекомендуется: экономит место, файл остается на диске E:)"
echo " 2) Полная копия в зашифрованный сабволюм @models (NoCoW)"
read -rp "Выберите способ [1-2, Enter = 1]: " MODE_OPT

MODE="link"
[[ "$MODE_OPT" == "2" ]] && MODE="copy"

assign_model "$SELECTED_FILE" "$ROLE" "$MODE"
echo ""
cmd_list
