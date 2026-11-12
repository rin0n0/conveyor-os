# Stage 1: Build universal llama.cpp + whisper.cpp (Dynamic backends: Vulkan + CPU ISA variants)
FROM registry.fedoraproject.org/fedora:43 AS llama-builder

RUN dnf install -y --setopt=install_weak_deps=False --skip-unavailable \
    git cmake ninja-build gcc-c++ \
    vulkan-headers vulkan-loader-devel \
    spirv-headers-devel spirv-tools-devel glslang-devel \
    glslc libshaderc-devel spirv-tools libcurl-devel && \
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
      -DGGML_NATIVE=OFF \
      -DLLAMA_BUILD_TESTS=OFF \
      -DGGML_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=ON && \
    cmake --build build-llama --target llama-server llama-cli -j"$(nproc)" && \
    (cmake --install build-llama --prefix /opt/ai-out || ( \
      mkdir -p /opt/ai-out/bin /opt/ai-out/lib64 && \
      install -Dm755 build-llama/bin/llama* /opt/ai-out/bin/ && \
      find build-llama -name "*.so*" -exec cp -d {} /opt/ai-out/lib64/ \; \
    ))

# Build whisper.cpp for fast push-to-talk voice prompt transcription (0 MB VRAM)
RUN git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git && \
    cmake -S whisper.cpp -B build-whisper -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DWHISPER_BUILD_TESTS=OFF \
      -DWHISPER_BUILD_EXAMPLES=ON && \
    cmake --build build-whisper --target whisper-cli -j"$(nproc)" && \
    install -Dm755 build-whisper/bin/whisper-cli /opt/ai-out/bin/whisper-cli

# Stage 2: Build Rust tools (DriftWM under safe x86-64-v2 ISA)
FROM registry.fedoraproject.org/fedora:43 AS rust-builder

RUN dnf install -y --setopt=install_weak_deps=False --skip-unavailable \
    git cargo rust clang pkgconf-pkg-config \
    wayland-devel libxkbcommon-devel libinput-devel mesa-libgbm-devel \
    libseat-devel libdisplay-info-devel systemd-devel && \
    dnf clean all

ENV RUSTFLAGS="-C target-cpu=x86-64-v2"
WORKDIR /build

RUN git clone --depth 1 https://github.com/malbiruk/driftwm.git && \
    cargo build --release --manifest-path driftwm/Cargo.toml && \
    install -Dm755 driftwm/target/release/driftwm /opt/rust-out/usr/local/bin/driftwm

# Stage 3: Download non-packaged developer CLI binaries (llama-swap, jj, mise, ast-grep, pueue, zellij, yazi)
FROM registry.fedoraproject.org/fedora:43 AS tools-downloader

RUN dnf install -y --setopt=install_weak_deps=False curl tar gzip jq unzip && dnf clean all
WORKDIR /opt/tools

RUN set -eux; \
    mkdir -p /opt/tools/bin; \
    # llama-swap (unified OpenAI + Anthropic API reverse proxy)
    SWAP_URL=$(curl -fsSL https://api.github.com/repos/mostlygeek/llama-swap/releases/latest | jq -r '.assets[] | select(.name | test("linux.*(amd64|x86_64).*tar.gz$")) | .browser_download_url' | head -n1); \
    if [ -n "$SWAP_URL" ]; then curl -fsSL "$SWAP_URL" | tar -xz -C /opt/tools/bin llama-swap; fi; \
    # Jujutsu (jj VCS - fearless snapshots, no branch locking)
    JJ_URL=$(curl -fsSL https://api.github.com/repos/jj-vcs/jj/releases/latest | jq -r '.assets[] | select(.name | test("x86_64-unknown-linux-musl.tar.gz$")) | .browser_download_url' | head -n1); \
    if [ -n "$JJ_URL" ]; then curl -fsSL "$JJ_URL" | tar -xz -C /opt/tools/bin --strip-components=1 ./jj; fi; \
    # mise (polyglot runtime & env manager)
    curl -fsSL https://mise.jdx.dev/mise-latest-linux-x64 -o /opt/tools/bin/mise; \
    # ast-grep (AST-based code intelligence & structural search)
    curl -fsSL https://github.com/ast-grep/ast-grep/releases/latest/download/app-x86_64-unknown-linux-gnu.zip -o /tmp/ast-grep.zip && \
    unzip -q -o /tmp/ast-grep.zip -d /opt/tools/bin && rm -f /tmp/ast-grep.zip; \
    # pueue & pueued (lightweight daemon for background batch tasks & MoE queues)
    curl -fsSL https://github.com/Nukesor/pueue/releases/latest/download/pueue-x86_64-unknown-linux-musl -o /opt/tools/bin/pueue; \
    curl -fsSL https://github.com/Nukesor/pueue/releases/latest/download/pueued-x86_64-unknown-linux-musl -o /opt/tools/bin/pueued; \
    # zellij (terminal multiplexer with Attention Inbox)
    curl -fsSL https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz | tar -xz -C /opt/tools/bin; \
    # yazi (terminal file manager with Sixel support)
    curl -fsSL https://github.com/sxyazi/yazi/releases/latest/download/yazi-x86_64-unknown-linux-musl.zip -o /tmp/yazi.zip && \
    unzip -q -j /tmp/yazi.zip "*/yazi" "*/ya" -d /opt/tools/bin && rm -f /tmp/yazi.zip; \
    chmod +x /opt/tools/bin/*

# Stage 4: Bootable Immutable Fedora Atomic (bootc) OS Image
FROM quay.io/fedora/fedora-bootc:43

# Base firmware, Wayland sessions (DriftWM + Niri + Sway), Cockpit & Dev isolation
RUN dnf install -y --setopt=install_weak_deps=False --skip-unavailable \
    linux-firmware \
    greetd tuigreet \
    niri sway waybar fuzzel SwayNotificationCenter kanshi \
    foot tmux neovim git lazygit git-delta difftastic \
    ripgrep fd-find btop nvtop \
    firefox pipewire wireplumber wl-clipboard cliphist wtype \
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome \
    bubblewrap podman zram-generator systemd-oomd nftables \
    NetworkManager-wifi usb_modeswitch usbutils pciutils vulkan-tools \
    mesa-dri-drivers mesa-vulkan-drivers \
    python3 python3-pip uv nodejs npm pnpm clang lld sccache ccache && \
    dnf clean all

# Install CLI coding agents: aider-chat & opencode
RUN uv pip install --system --break-system-packages aider-chat || true
RUN npm install -g @opencode/cli || curl -fsSL https://opencode.ai/v2/install | bash || true

# Copy prebuilt universal binaries and tools
COPY --from=llama-builder /opt/ai-out/ /usr/local/
COPY --from=rust-builder /opt/rust-out/ /
COPY --from=tools-downloader /opt/tools/bin/ /usr/local/bin/
RUN echo "/usr/local/lib64" > /etc/ld.so.conf.d/local-ai.conf && \
    echo "/usr/local/lib" >> /etc/ld.so.conf.d/local-ai.conf && \
    ldconfig

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
