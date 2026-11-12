# Conveyor OS (Portable Agentic Dev OS)

Переносимая ОС программиста-кодера («конвейер» продуктовой разработки) для **Intel SSD 545s 256GB (`SSDSC2KW256G8`, 238.47 GiB)** через мост **JMicron `JMS578` (`152d:0578`)** с загрузкой по **UEFI** на произвольных ПК (2014–2026 гг.).

## Вариативность при старте (3 уровня адаптации)

1. **Уровень GRUB2 (выбор ядра/транспорта до загрузки ОС):**
   - `Conveyor OS (Auto-Detect)` — штатный старт (`boot-gpu-detect` сам определяет CPU ISA, GPU, RAM/VRAM).
   - `Conveyor OS (Pure Open / Strict SecureBoot)` — Deployment 1 без сторонних модулей ядра (100% подпись Fedora `shimx64.efi`).
   - `Conveyor OS (Safe Hardware: BOT + No-GPU-Accel)` — включает `usb-storage.quirks=152d:0578:u` (отключает UAS на капризных USB 2014 г.) и программный рендер.
2. **Уровень `tuigreet` (выбор GUI-композитора при входе):**
   - **DriftWM** — бесконечный 2D-холст («острова» проектов + миникарта `Driftmap` + `driftwm-settings`).
   - **Niri** — 1D-ленты (1 проект = 1 горизонтальная полоса + `Super+O` Overview).
   - **Sway** — минималистичный fallback (~33 МБ RAM) для слабых ПК 2014 года и `llvmpipe`.
3. **Уровень `boot-gpu-detect` + `llama-swap` (автовыбор AI-профиля):**
   - На целевой связке **8 ГБ VRAM + 32 ГБ RAM** автоматически поднимает `config-8gb-vram-32gb-ram.yaml` (`Gemma 4 E4B` целиком в 8 ГБ VRAM; `Qwen3.6-35B-A3B` через `--n-cpu-moe` — активные/DeltaNet/KV-кэш в 8 ГБ VRAM, эксперты в 32 ГБ RAM).
   - На старых/слабых ПК автоматически переключается на `config-cpu-only.yaml` (без OOM).

## Структура репозитория

- `Containerfile` — сборка `bootc` OCI-образа (Fedora Atomic, `x86-64-v2`, `llama.cpp` с `GGML_CPU_ALL_VARIANTS=ON`, `DriftWM`, `Niri`, `Sway`, `Foot`, `Zellij`, `bwrap`, `jj`, `mise`).
- `system/` — системные конфиги, `udev`-правила (`152d:0578` и изоляция дисков хоста), `greetd`/`tuigreet`, `boot-gpu-detect`, YAML-профили `llama-swap` и скелет пользовательских настроек (`/etc/skel`).
- `scripts/` — скрипт разметки Intel SSD 545s (`LUKS2` + `Btrfs` 238.47 GiB), обёртка `bwrap` для CLI-агентов.

## Быстрый старт

1. Проверить адаптер на Linux-хосте: `lsusb -t` и `lsblk -D /dev/sdX`.
2. Собрать OCI-образ:
   ```bash
   podman build -t localhost/conveyor-os:latest .
   ```
3. Разметить **Intel SSD 545s** через `scripts/partition-intel-545s.sh` (осторожно: полностью очистит целевой диск!).
4. Установить образ через `bootc install to-filesystem` и прописать `grub2` с `--removable` в `\EFI\BOOT\BOOTX64.EFI`.
5. Установить в `@home` **Antigravity Desktop + `agy` CLI** (Google AI Pro) и скачать веса в `/var/lib/models` (`@models`).
