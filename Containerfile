# Pinned upstream versions. Bump them deliberately: a new version is a new build input.
# Stage 1: Build universal llama.cpp + whisper.cpp (Dynamic backends: Vulkan + CPU ISA variants)
FROM registry.fedoraproject.org/fedora:43 AS llama-builder

ARG LLAMA_CPP_VERSION=v1.0.0
ARG WHISPER_CPP_VERSION=v1.9.5

RUN dnf install -y --setopt=install_weak_deps=False \
    git cmake ninja-build gcc-c++ \
    vulkan-headers vulkan-loader-devel \
    spirv-headers-devel spirv-tools-devel glslang-devel \
    glslc libshaderc-devel spirv-tools libcurl-devel && \
    dnf clean all

WORKDIR /build

# CUDA 13 toolkit from NVIDIA's Fedora repository, for the optional CUDA backend.
# CUDA 13 supports Turing (RTX 20xx / GTX 16xx) and newer: the same cards the NVIDIA
# open kernel modules in this image support.
ARG CUDA_VERSION=13.2
RUN cuda_suffix="${CUDA_VERSION/./-}" && \
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/fedora43/x86_64/cuda-fedora43.repo \
      -o /etc/yum.repos.d/cuda.repo && \
    dnf install -y --setopt=install_weak_deps=False \
      "cuda-compiler-${cuda_suffix}" "cuda-cudart-devel-${cuda_suffix}" "libcublas-devel-${cuda_suffix}" \
      "cuda-cccl-${cuda_suffix}" "cuda-driver-devel-${cuda_suffix}" "cuda-profiler-api-${cuda_suffix}" && \
    dnf clean all

# Build llama.cpp with dynamic CPU dispatch (SSE4.2, AVX, AVX2, AVX-512), Vulkan and CUDA.
# Every backend is a separate library loaded at runtime; boot-gpu-detect picks the device.
# CUDA targets: Turing 75, Ampere 86, Ada 89, Blackwell 120, plus PTX for newer GPUs.
RUN git clone --depth 1 --branch "${LLAMA_CPP_VERSION}" https://github.com/ggml-org/llama.cpp.git && \
    cmake -S llama.cpp -B build-llama -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DGGML_BACKEND_DL=ON \
      -DGGML_CPU_ALL_VARIANTS=ON \
      -DGGML_VULKAN=ON \
      -DGGML_CUDA=ON \
      -DCUDAToolkit_ROOT="/usr/local/cuda-${CUDA_VERSION}" \
      -DCMAKE_CUDA_COMPILER="/usr/local/cuda-${CUDA_VERSION}/bin/nvcc" \
      "-DCMAKE_CUDA_ARCHITECTURES=75-real;86-real;89-real;120a-real;89-virtual" \
      -DGGML_NATIVE=OFF \
      -DLLAMA_BUILD_TESTS=OFF \
      -DGGML_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=ON \
      -DLLAMA_USE_PREBUILT_UI=OFF && \
    cmake --build build-llama --target llama-server -j"$(nproc)" && \
    mkdir -p /opt/ai-out/bin /opt/ai-out/lib64 && \
    install -m755 build-llama/bin/llama-server /opt/ai-out/bin/ && \
    find build-llama -name "*.so*" -exec cp -P {} /opt/ai-out/lib64/ \; && \
    find build-llama \( -name "libggml-cpu-*.so" -o -name "libggml-vulkan.so" -o -name "libggml-cuda.so" \) \
      -exec cp -P {} /opt/ai-out/bin/ \; && \
    for cuda_lib in libcudart libcublas libcublasLt; do \
      cp -P "/usr/local/cuda-${CUDA_VERSION}/targets/x86_64-linux/lib/${cuda_lib}".so.13* /opt/ai-out/lib64/; \
    done

# Build whisper.cpp for fast push-to-talk voice prompt transcription (0 MB VRAM)
RUN git clone --depth 1 --branch "${WHISPER_CPP_VERSION}" https://github.com/ggml-org/whisper.cpp.git && \
    cmake -S whisper.cpp -B build-whisper -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DGGML_NATIVE=OFF \
      -DWHISPER_BUILD_TESTS=OFF \
      -DWHISPER_BUILD_EXAMPLES=ON && \
    cmake --build build-whisper --target whisper-cli -j"$(nproc)" && \
    install -Dm755 build-whisper/bin/whisper-cli /opt/ai-out/bin/whisper-cli

# Stage 2: Build Rust tools (DriftWM under safe x86-64-v2 ISA)
FROM registry.fedoraproject.org/fedora:43 AS rust-builder

ARG DRIFTWM_VERSION=v0.21.0

RUN dnf install -y --setopt=install_weak_deps=False \
    git cargo rust clang pkgconf-pkg-config \
    wayland-devel libxkbcommon-devel libinput-devel mesa-libgbm-devel \
    libseat-devel libdisplay-info-devel systemd-devel && \
    dnf clean all

ENV RUSTFLAGS="-C target-cpu=x86-64-v2"
WORKDIR /build

RUN git clone --depth 1 --branch "${DRIFTWM_VERSION}" https://github.com/malbiruk/driftwm.git && \
    cargo build --release --locked --manifest-path driftwm/Cargo.toml && \
    install -Dm755 driftwm/target/release/driftwm /opt/rust-out/usr/local/bin/driftwm

# Stage 3: Download non-packaged developer CLI binaries
FROM registry.fedoraproject.org/fedora:43 AS tools-downloader

ARG LLAMA_SWAP_VERSION=273
ARG JJ_VERSION=v0.47.1
ARG MISE_VERSION=v2026.11.9
ARG AST_GREP_VERSION=0.51.3
ARG PUEUE_VERSION=v4.0.4
ARG ZELLIJ_VERSION=v0.46.0
ARG YAZI_VERSION=v26.9.1
ARG CLIPHIST_VERSION=v0.7.0
ARG OPENCODE_VERSION=v1.19.6
ARG DRIFTMAP_VERSION=v1.0.0
# diffview.nvim has no releases; this is the newest commit
ARG DIFFVIEW_COMMIT=4516612fe98ff56ae0415a259ff6361a89419b0a

RUN dnf install -y --setopt=install_weak_deps=False curl tar gzip unzip && dnf clean all
WORKDIR /opt/tools

RUN set -euxo pipefail; \
    mkdir -p /opt/tools/bin; \
    gh="https://github.com"; \
    # llama-swap (OpenAI-compatible model router with a web UI on /ui)
    curl -fsSL "$gh/mostlygeek/llama-swap/releases/download/v${LLAMA_SWAP_VERSION}/llama-swap_${LLAMA_SWAP_VERSION}_linux_amd64.tar.gz" | tar -xz -C /opt/tools/bin llama-swap; \
    # Jujutsu (jj VCS)
    curl -fsSL "$gh/jj-vcs/jj/releases/download/${JJ_VERSION}/jj-${JJ_VERSION}-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C /opt/tools/bin --strip-components=1 ./jj; \
    # mise (polyglot runtime & env manager)
    curl -fsSL "$gh/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-x64" -o /opt/tools/bin/mise; \
    # ast-grep (structural code search)
    curl -fsSL "$gh/ast-grep/ast-grep/releases/download/${AST_GREP_VERSION}/app-x86_64-unknown-linux-gnu.zip" -o /tmp/ast-grep.zip; \
    unzip -q -o /tmp/ast-grep.zip -d /opt/tools/bin; \
    # pueue & pueued (background task queue)
    curl -fsSL "$gh/Nukesor/pueue/releases/download/${PUEUE_VERSION}/pueue-x86_64-unknown-linux-musl" -o /opt/tools/bin/pueue; \
    curl -fsSL "$gh/Nukesor/pueue/releases/download/${PUEUE_VERSION}/pueued-x86_64-unknown-linux-musl" -o /opt/tools/bin/pueued; \
    # zellij (terminal multiplexer)
    curl -fsSL "$gh/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C /opt/tools/bin; \
    # yazi (terminal file manager)
    curl -fsSL "$gh/sxyazi/yazi/releases/download/${YAZI_VERSION}/yazi-x86_64-unknown-linux-musl.zip" -o /tmp/yazi.zip; \
    unzip -q -j /tmp/yazi.zip "*/yazi" "*/ya" -d /opt/tools/bin; \
    # cliphist (clipboard history, not packaged in Fedora)
    curl -fsSL "$gh/sentriz/cliphist/releases/download/${CLIPHIST_VERSION}/${CLIPHIST_VERSION}-linux-amd64" -o /opt/tools/bin/cliphist; \
    # opencode (baseline build also runs on older CPUs without AVX2)
    curl -fsSL "$gh/anomalyco/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-x64-baseline.tar.gz" | tar -xz -C /opt/tools/bin opencode; \
    rm -f /tmp/ast-grep.zip /tmp/yazi.zip; \
    chmod +x /opt/tools/bin/*; \
    # Driftmap: minimap overlay for DriftWM (single Python file, GTK 4 + layer shell)
    mkdir -p /opt/tools/lib; \
    curl -fsSL "https://raw.githubusercontent.com/rywby-dot/driftwm-minimap/${DRIFTMAP_VERSION}/driftmap.py" \
      -o /opt/tools/lib/driftmap.py; \
    # diffview.nvim, installed as a Neovim package for every user
    mkdir -p /opt/tools/nvim/diffview.nvim; \
    curl -fsSL "https://codeload.github.com/sindrets/diffview.nvim/tar.gz/${DIFFVIEW_COMMIT}" \
      | tar -xz -C /opt/tools/nvim/diffview.nvim --strip-components=1

# Stage 4: Build NVIDIA open kernel modules for the exact kernel of the base image
FROM quay.io/fedora/fedora-bootc:43 AS nvidia-builder

# The repository only keeps current drivers, so this follows the nightly refresh.
ARG REFRESH_DATE=manual

RUN set -euxo pipefail; \
    echo "NVIDIA driver refresh: ${REFRESH_DATE}"; \
    curl -fsSL https://negativo17.org/repos/fedora-nvidia.repo -o /etc/yum.repos.d/fedora-nvidia.repo; \
    mkdir -p /var/roothome /var/lib/alternatives /var/cache/akmods /var/log/akmods /run/akmods /out; \
    chmod 1777 /var/tmp; \
    kernel_version=$(rpm -q --qf '%{VERSION}' kernel-core); \
    kernel_release=$(rpm -q --qf '%{RELEASE}' kernel-core); \
    kernel="${kernel_version}-${kernel_release}.x86_64"; \
    # Fedora mirrors drop older kernels, Koji keeps every build
    dnf install -y --setopt=install_weak_deps=False "kernel-devel-${kernel}" || \
      dnf install -y --setopt=install_weak_deps=False \
        "https://kojipkgs.fedoraproject.org/packages/kernel/${kernel_version}/${kernel_release}/x86_64/kernel-devel-${kernel}.rpm"; \
    dnf install -y --setopt=install_weak_deps=False akmod-nvidia; \
    akmods --force --kernels "${kernel}" --kmod nvidia; \
    modinfo -k "${kernel}" nvidia nvidia_drm nvidia_modeset nvidia_uvm >/dev/null; \
    cp /var/cache/akmods/nvidia/kmod-nvidia-*.rpm /out/; \
    echo "${kernel}" >/out/kernel; \
    rpm -q --qf '%{VERSION}' akmod-nvidia >/out/version

# Stage 5: Bootable Immutable Fedora Atomic (bootc) OS Image
FROM quay.io/fedora/fedora-bootc:43

ARG AIDER_VERSION=0.86.2
# CI passes the current date, so the nightly build picks up Fedora package updates.
ARG REFRESH_DATE=manual

# A package that cannot be installed must fail the build.
RUN echo "Fedora package refresh: ${REFRESH_DATE}" && \
    dnf install -y --setopt=install_weak_deps=False \
    linux-firmware \
    greetd tuigreet \
    niri sway waybar fuzzel SwayNotificationCenter kanshi \
    foot tmux neovim micro nano git lazygit git-delta difftastic \
    ripgrep fd-find btop nvtop jq curl unzip \
    firefox Thunar pavucontrol xdg-utils libnotify \
    pipewire pipewire-pulseaudio pipewire-utils wireplumber \
    wl-clipboard wtype grim slurp \
    jetbrains-mono-fonts google-noto-sans-fonts google-noto-color-emoji-fonts fontawesome-6-free-fonts \
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome \
    flatpak distrobox bubblewrap podman zram-generator systemd-oomd-defaults nftables \
    NetworkManager-wifi NetworkManager-tui nm-connection-editor iputils usb_modeswitch usbutils pciutils vulkan-tools \
    bluez bluez-obexd blueman \
    python3-gobject python3-cairo gtk4 gtk4-layer-shell \
    gdisk exfatprogs \
    mesa-dri-drivers mesa-vulkan-drivers \
    python3 python3-pip python3.12 uv nodejs nodejs-npm pnpm \
    gcc gcc-c++ make cmake gdb clang lld sccache ccache && \
    dnf clean all

# NVIDIA driver. nouveau stays available: the boot menu picks the driver through
# kernel arguments, so older NVIDIA cards on other PCs still have an option.
RUN --mount=type=bind,from=nvidia-builder,source=/out,target=/tmp/nvidia \
    set -euxo pipefail; \
    kernel=$(cat /tmp/nvidia/kernel); \
    driver=$(cat /tmp/nvidia/version); \
    test -d "/usr/lib/modules/${kernel}"; \
    mkdir -p /var/roothome /var/lib/alternatives; \
    curl -fsSL https://negativo17.org/repos/fedora-nvidia.repo -o /etc/yum.repos.d/fedora-nvidia.repo; \
    dnf install -y --setopt=install_weak_deps=False \
      /tmp/nvidia/kmod-nvidia-*.rpm "nvidia-driver-${driver}" "nvidia-driver-cuda-${driver}" nvidia-modprobe; \
    mkdir -p /usr/lib/modprobe.d /etc/modprobe.d; \
    find /usr/lib/modprobe.d /etc/modprobe.d -type f \
      -exec sed -i -E '/^[[:space:]]*(blacklist|install)[[:space:]]+nouveau/d' {} +; \
    depmod -a "${kernel}"; \
    rm -f /etc/yum.repos.d/fedora-nvidia.repo; \
    dnf clean all

# aider requires Python < 3.13, Fedora 43 defaults to a newer one.
RUN UV_TOOL_DIR=/usr/lib/conveyor/uv-tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_CACHE_DIR=/tmp/uv-cache \
    UV_PYTHON_DOWNLOADS=never \
    uv tool install --python /usr/bin/python3.12 "aider-chat==${AIDER_VERSION}" && \
    rm -rf /tmp/uv-cache

# Copy prebuilt universal binaries and tools
COPY --from=llama-builder /opt/ai-out/ /usr/local/
COPY --from=rust-builder /opt/rust-out/ /
COPY --from=tools-downloader /opt/tools/bin/ /usr/local/bin/
COPY --from=tools-downloader /opt/tools/lib/driftmap.py /usr/local/lib/conveyor/driftmap.py
COPY --from=tools-downloader /opt/tools/nvim/ /usr/share/nvim/site/pack/conveyor/start/
RUN echo "/usr/local/lib64" > /etc/ld.so.conf.d/local-ai.conf && \
    echo "/usr/local/lib" >> /etc/ld.so.conf.d/local-ai.conf && \
    ldconfig

# System configuration, udev rules (152d:0578 + host isolation), GPU detect & AI profiles
COPY system/etc/ /etc/
COPY system/usr/ /usr/
COPY scripts/bwrap-agent-run.sh scripts/verify-gates.sh /usr/local/bin/

RUN chmod 0755 /usr/local/libexec/*.sh \
               /usr/local/libexec/*.py \
               /usr/local/bin/*.sh \
               /etc/NetworkManager/dispatcher.d/* && \
    chmod 0440 /etc/sudoers.d/* && \
    ln -sf conveyor-model.sh /usr/local/bin/conveyor-model && \
    ln -sf conveyor-driftmap.sh /usr/local/bin/driftmap && \
    ln -sf conveyor-help.sh /usr/local/bin/conveyor-help && \
    ln -sf conveyor-help.sh /usr/local/bin/conveyor-docs && \
    systemd-sysusers

# Boot into the login screen and auto-enable required services
RUN systemctl set-default graphical.target && \
    systemctl enable greetd.service \
                     boot-gpu-detect.service \
                     llama-swap.service \
                     nftables.service \
                     fstrim.timer \
                     NetworkManager.service \
                     bluetooth.service && \
    systemctl --global enable pueued.service

# Rebuild the initramfs so USB, keyboard and LUKS support are present on any PC
RUN set -eux; \
    kernel=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n'); \
    DRACUT_NO_XATTR=1 dracut --force --no-hostonly --reproducible --zstd \
      --kver "${kernel}" "/usr/lib/modules/${kernel}/initramfs.img"

# Fail the build if a promised program or config does not actually work
RUN /usr/local/libexec/conveyor-check-image.sh

RUN bootc container lint
