#!/usr/bin/env bash
# Build the standalone HarfBuzz static archive — the ONE HarfBuzz the pack ships.
#
# Flags are term-kit's validated production set (moved here from term-kit's
# HarfBuzzExternal.cmake) plus HB_BUILD_SUBSET=ON as cheap insurance (S7: no
# current consumer link demands hb_subset_*, but PDF-adjacent consumers might).
#
# Output: build/harfbuzz/libharfbuzz.a  (CoreText on; FreeType/glib/ICU off).
# The CMake build also emits libharfbuzz-{subset,gpu,raster,vector}.a — the
# pack packages libharfbuzz.a ONLY.
#
# Idempotent: cmake configure + ninja are incremental; a no-op re-run takes
# seconds.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HB_SRC="${PACK_ROOT}/third_party/harfbuzz"
HB_BUILD="${PACK_ROOT}/build/harfbuzz"

if [[ ! -f "${HB_SRC}/CMakeLists.txt" ]]; then
    echo "error: harfbuzz sources missing (${HB_SRC})" >&2
    echo "run: ./scripts/fetch_sources.sh" >&2
    exit 1
fi

cmake -S "${HB_SRC}" -B "${HB_BUILD}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DHB_HAVE_CORETEXT=ON \
    -DHB_HAVE_FREETYPE=OFF \
    -DHB_HAVE_GLIB=OFF \
    -DHB_HAVE_ICU=OFF \
    -DHB_BUILD_UTILS=OFF \
    -DHB_BUILD_TESTS=OFF \
    -DHB_BUILD_SUBSET=ON

cmake --build "${HB_BUILD}"

if [[ ! -f "${HB_BUILD}/libharfbuzz.a" ]]; then
    echo "error: expected ${HB_BUILD}/libharfbuzz.a after build" >&2
    exit 1
fi

echo "[harfbuzz] built: ${HB_BUILD}/libharfbuzz.a"
