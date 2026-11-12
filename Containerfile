# Stage 1: Build universal llama.cpp + whisper.cpp (Dynamic backends: Vulkan + CPU ISA variants)
FROM registry.fedoraproject.org/fedora:43 AS llama-builder

RUN dnf install -y --setopt=install_weak_deps=False \
    git cmake ninja-build gcc-c++ vulkan-headers vulkan-loader-devel \
    glslc spirv-tools libcurl-devel && \
    dnf clean all

WORKDIR /build

# Build llama.cpp with dynamic CPU dispatch (SSE4.2, AVX, AVX2, AVX-512) and Vulkan
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git && \
    cmake -S llama.cpp -B build-llama -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DGGML_BACKEND_DL=ON \
      -DGGML_CPU_ALL_VARIANTS=ON \
      -DGGML_VULKAN=ON \
      -DGGML_NATIVE=OFF && \
    cmake --build build-llama --target llama-server llama-cli -j"$(nproc)" && \
    cmake --install build-llama --prefix /opt/ai-out

# Build whisper.cpp for fast push-to-talk voice prompt transcription (0 MB VRAM)
RUN git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git && \
    cmake -S whisper.cpp -B build-whisper -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DWHISPER_BUILD_TESTS=OFF \
      -DWHISPER_BUILD_EXAMPLES=ON && \
    cmake --build build-whisper --target whisper-cli -j"$(nproc)" && \
    install -Dm755 build-whisper/bin/whisper-cli /opt/ai-out/bin/whisper-cli

# Stage 2: Build Rust tools (DriftWM + driftwm-settings under safe x86-64-v2 ISA)
FROM registry.fedoraproject.org/fedora:43 AS rust-builder

RUN dnf install -y --setopt=install_weak_deps=False \
    git cargo rust clang pkgconf-pkg-config \
    wayland-devel libxkbcommon-devel libinput-devel mesa-libgbm-devel \
    seatd-devel libdisplay-info-devel systemd-devel && \
    dnf clean all

ENV RUSTFLAGS="-C target-cpu=x86-64-v2"
WORKDIR /build

RUN git clone --depth 1 https://github.com/malbiruk/driftwm.git && \
    cargo build --release --manifest-path driftwm/Cargo.toml && \
    install -Dm755 driftwm/target/release/driftwm /opt/rust-out/usr/local/bin/driftwm

RUN git clone --depth 1 https://github.com/wwmaxik/driftwm-settings.git && \
    cargo build --release --manifest-path driftwm-settings/Cargo.toml && \
    install -Dm755 driftwm-settings/target/release/driftwm-settings /opt/rust-out/usr/local/bin/driftwm-settings || true

# Stage 3: Download non-packaged developer CLI binaries (llama-swap, jj, mise, ast-grep, pueue, opencode)
FROM registry.fedoraproject.org/fedora:43 AS tools-downloader

RUN dnf install -y --setopt=install_weak_deps=False curl tar gzip jq && dnf clean all
WORKDIR /opt/tools

# Download latest stable release binaries
RUN set -eux; \
    mkdir -p /opt/tools/bin; \
    # llama-swap (unified OpenAI + Anthropic API reverse proxy)
    curl -fsSL https://github.com/mostlygeek/llama-swap/releases/download/v0.7.3/llama-swap_linux_x86_64.tar.gz | tar -xz -C /opt/tools/bin llama-swap || \
    curl -fsSL https://github.com/mostlygeek/llama-swap/releases/latest/download/llama-swap_linux_x86_64.tar.gz | tar -xz -C /opt/tools/bin llama-swap || true; \
    # Jujutsu (jj VCS - fearless snapshots, no branch locking)
    JJ_URL=$(curl -fsSL https://api.github.com/repos/jj-vcs/jj/releases/latest | jq -r '.assets[] | select(.name | test("x86_64-unknown-linux-musl.tar.gz$")) | .browser_download_url' | head -n1); \
    curl -fsSL "$JJ_URL" | tar -xz -C /opt/tools/bin --strip-components=1 ./jj || true; \
    # mise (polyglot runtime & env manager)
    curl -fsSL https://mise.jdx.dev/mise-latest-linux-x64 -o /opt/tools/bin/mise; \
    # ast-grep (AST-based code intelligence & structural search)
    SG_URL=$(curl -fsSL https://api.github.com/repos/ast-grep/ast-grep/releases/latest | jq -r '.assets[] | select(.name | test("x86_64-unknown-linux-gnu.tar.gz$")) | .browser_download_url' | head -n1); \
    curl -fsSL "$SG_URL" | tar -xz -C /opt/tools/bin ast-grep || true; \
    # pueue (lightweight daemon for background batch tasks & MoE queues)
    curl -fsSL https://github.com/Nukesor/pueue/releases/latest/download/pueue-linux-x86_64 -o /opt/tools/bin/pueue; \
    curl -fsSL https://github.com/Nukesor/pueue/releases/latest/download/pueued-linux-x86_64 -o /opt/tools/bin/pueued; \
    # opencode (model-agnostic open-source terminal coding agent)
    OC_URL=$(curl -fsSL https://api.github.com/repos/opencode-ai/opencode/releases/latest | jq -r '.assets[] | select(.name | test("linux-x64.tar.gz$")) | .browser_download_url' | head -n1); \
    if [ -n "$OC_URL" ]; then curl -fsSL "$OC_URL" | tar -xz -C /opt/tools/bin opencode || true; fi; \
    chmod +x /opt/tools/bin/*

# Stage 4: Bootable Immutable Fedora Atomic (bootc) OS Image
FROM quay.io/fedora/fedora-bootc:43

# Base firmware, Wayland sessions (DriftWM + Niri + Sway), Cockpit & Dev isolation
RUN dnf install -y --setopt=install_weak_deps=False \
    linux-firmware \
    greetd tuigreet \
    niri sway waybar fuzzel swaync kanshi \
    foot zellij tmux neovim git lazygit git-delta difftastic \
    ripgrep fd-find yazi btop nvtop \
    firefox pipewire wireplumber wl-clipboard cliphist wtype \
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome \
    bubblewrap podman zram-generator systemd-oomd nftables \
    NetworkManager-wifi usb_modeswitch usbutils pciutils vulkan-tools \
    mesa-dri-drivers mesa-vulkan-drivers \
    python3 python3-pip uv nodejs pnpm clang lld sccache ccache && \
    dnf clean all

# Install aider-chat CLI agent via uv globally into /usr/local
RUN uv pip install --system --break-system-packages aider-chat || true

# Copy prebuilt universal binaries and tools
COPY --from=llama-builder /opt/ai-out/ /usr/local/
COPY --from=rust-builder /opt/rust-out/ /
COPY --from=tools-downloader /opt/tools/bin/ /usr/local/bin/
RUN ldconfig

# System configuration, udev rules (152d:0578 + host isolation), GPU detect & AI profiles
COPY system/etc/ /etc/
COPY system/usr/ /usr/

RUN chmod +x /usr/local/libexec/boot-gpu-detect.sh \
             /usr/local/bin/session-wrapper.sh \
             /usr/local/bin/*.sh || true

# Auto-enable required system services
RUN systemctl enable greetd.service \
                     boot-gpu-detect.service \
                     llama-swap.service \
                     nftables.service \
                     fstrim.timer \
                     NetworkManager.service

RUN bootc container lint
