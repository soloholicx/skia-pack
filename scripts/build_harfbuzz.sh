#!/usr/bin/env bash
# Build the standalone HarfBuzz static archive — the ONE HarfBuzz the pack ships.
#
# Flags are term-kit's validated production set (moved here from term-kit's
# HarfBuzzExternal.cmake) plus HB_BUILD_SUBSET=ON: since 157.1.0 Skia is built
# with SkPDF (rust-skia needs it), and SkPDF calls hb_subset_*.
#
# usage: build_harfbuzz.sh [platform]   (default macos-arm64; see scripts/platform.sh)
#
# Output: <build tree>/pack/libharfbuzz.a, where the build tree is
# build/harfbuzz for macOS and build/harfbuzz-<platform>/ for the iOS slices —
# each platform has its own build tree and SDK (CoreText on;
# FreeType/glib/ICU off).
# pack/libharfbuzz.a is CMake's libharfbuzz.a and libharfbuzz-subset.a merged
# member for member: the pack ships ONE HarfBuzz archive, and it is the only
# definer of hb_* (including hb_subset_*). The CMake build may also emit
# libharfbuzz-{gpu,raster,vector}.a — those are not packaged.
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
if [[ "${PACK_HOST_CAN_BUILD}" != "1" ]]; then
    echo "error: ${PLATFORM} cannot be built on $(uname -s)" >&2
    exit 1
fi
platform_flags=(-DCMAKE_OSX_DEPLOYMENT_TARGET="${PACK_MINOS}" -DHB_HAVE_CORETEXT=ON)
build_target=()
if [[ "${PLATFORM}" == "linux-x86_64" ]]; then
    # Same compiler as Skia's (gn/linux.gn). No CoreText; FreeType stays off:
    # Skia does not use hb-ft, and it would add a system dependency.
    platform_flags=(-DCMAKE_C_COMPILER=clang-17 -DCMAKE_CXX_COMPILER=clang++-17 -DHB_HAVE_CORETEXT=OFF)
    build_target=(--target harfbuzz --target harfbuzz-subset)
elif [[ "${PLATFORM}" != "macos-arm64" ]]; then
    platform_flags+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="${PACK_SDK}" -DCMAKE_OSX_ARCHITECTURES=arm64)
    build_target=(--target harfbuzz --target harfbuzz-subset)
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
    -DHB_HAVE_FREETYPE=OFF \
    -DHB_HAVE_GLIB=OFF \
    -DHB_HAVE_ICU=OFF \
    -DHB_BUILD_UTILS=OFF \
    -DHB_BUILD_TESTS=OFF \
    -DHB_BUILD_SUBSET=ON

cmake --build "${HB_BUILD}" ${build_target[@]+"${build_target[@]}"}

for archive in libharfbuzz.a libharfbuzz-subset.a; do
    if [[ ! -f "${HB_BUILD}/${archive}" ]]; then
        echo "error: expected ${HB_BUILD}/${archive} after build" >&2
        exit 1
    fi
done

# One shipped archive; every member is kept as it is.
mkdir -p "${HB_BUILD}/pack"
rm -f "${HB_BUILD}/pack/libharfbuzz.a"
if [[ "${PLATFORM}" == "linux-x86_64" ]]; then
    printf 'create %s\naddlib %s\naddlib %s\nsave\nend\n' \
        "${HB_BUILD}/pack/libharfbuzz.a" "${HB_BUILD}/libharfbuzz.a" "${HB_BUILD}/libharfbuzz-subset.a" | ar -M
else
    libtool -static -o "${HB_BUILD}/pack/libharfbuzz.a" "${HB_BUILD}/libharfbuzz.a" "${HB_BUILD}/libharfbuzz-subset.a"
fi

echo "[harfbuzz] built: ${HB_BUILD}/pack/libharfbuzz.a (libharfbuzz.a + libharfbuzz-subset.a)"
