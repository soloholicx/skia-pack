#!/usr/bin/env bash
# Build the standalone HarfBuzz static archive — the ONE HarfBuzz the pack ships.
#
# Flags are term-kit's validated production set (moved here from term-kit's
# HarfBuzzExternal.cmake) plus HB_BUILD_SUBSET=ON as cheap insurance (S7: no
# current consumer link demands hb_subset_*, but PDF-adjacent consumers might).
#
# usage: build_harfbuzz.sh [platform]   (default macos-arm64; see scripts/platform.sh)
#
# Output: build/harfbuzz/libharfbuzz.a for macOS, build/harfbuzz-<platform>/
# for the iOS slices — each platform has its own build tree and SDK
# (CoreText on; FreeType/glib/ICU off).
# The CMake build also emits libharfbuzz-{subset,gpu,raster,vector}.a — the
# pack packages libharfbuzz.a ONLY.
#
# Idempotent: cmake configure + ninja are incremental; a no-op re-run takes
# seconds.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HB_SRC="${PACK_ROOT}/third_party/harfbuzz"
PLATFORM="${1:-macos-arm64}"
# shellcheck source=scripts/platform.sh
source "${PACK_ROOT}/scripts/platform.sh"
pack_platform_init "${PACK_ROOT}" "${PLATFORM}"
HB_BUILD="${PACK_HB_OUT}"

# macOS keeps its exact historical configure line. iOS cross-compiles against
# the matching SDK, arm64 only, and builds just the one archive the pack ships.
platform_flags=(-DCMAKE_OSX_DEPLOYMENT_TARGET="${PACK_MINOS}")
build_target=()
if [[ "${PLATFORM}" != "macos-arm64" ]]; then
    platform_flags+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="${PACK_SDK}" -DCMAKE_OSX_ARCHITECTURES=arm64)
    build_target=(--target harfbuzz)
fi

if [[ ! -f "${HB_SRC}/CMakeLists.txt" ]]; then
    echo "error: harfbuzz sources missing (${HB_SRC})" >&2
    echo "run: ./scripts/fetch_sources.sh" >&2
    exit 1
fi

cmake -S "${HB_SRC}" -B "${HB_BUILD}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    "${platform_flags[@]}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DHB_HAVE_CORETEXT=ON \
    -DHB_HAVE_FREETYPE=OFF \
    -DHB_HAVE_GLIB=OFF \
    -DHB_HAVE_ICU=OFF \
    -DHB_BUILD_UTILS=OFF \
    -DHB_BUILD_TESTS=OFF \
    -DHB_BUILD_SUBSET=ON

cmake --build "${HB_BUILD}" ${build_target[@]+"${build_target[@]}"}

if [[ ! -f "${HB_BUILD}/libharfbuzz.a" ]]; then
    echo "error: expected ${HB_BUILD}/libharfbuzz.a after build" >&2
    exit 1
fi

echo "[harfbuzz] built: ${HB_BUILD}/libharfbuzz.a"
