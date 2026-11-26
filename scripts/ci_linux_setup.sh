#!/usr/bin/env bash
# Toolchain and libraries for the Linux jobs (GitHub-hosted ubuntu-22.04):
# Clang 17 from apt.llvm.org, the two system libraries the slice links
# (FreeType, Fontconfig), and what the Rust consumer gate needs to open a
# Slint window under Xvfb. Uses sudo: for CI runners, not for a workstation.
set -euo pipefail
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | sudo tee /etc/apt/keyrings/apt.llvm.org.asc > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/apt.llvm.org.asc] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-17 main" \
    | sudo tee /etc/apt/sources.list.d/llvm-17.list
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    clang-17 libclang-17-dev llvm-17 ninja-build cmake python3 \
    libfreetype-dev libfontconfig1-dev fonts-dejavu-core \
    xvfb libxkbcommon0 libxkbcommon-x11-0 libx11-xcb1 libxcursor1 libxi6 libxrandr2 \
    libgl1-mesa-dri libgl1 libegl1 libvulkan1 mesa-vulkan-drivers
clang-17 --version
cmake --version
ninja --version
cargo --version
ldd --version | head -1
# The libstdc++ Clang will use — part of the slice's baseline.
clang++-17 -print-file-name=libstdc++.so
nproc; free -g | sed -n 2p; df -h . | tail -1
