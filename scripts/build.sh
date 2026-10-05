#!/usr/bin/env bash
# Full pack build:
#   1. pinned sources (scripts/fetch_sources.sh — pins.json → third_party/
#      clones + Skia DEPS externals; no-op when already at the pins)
#   2. standalone HarfBuzz static archive (scripts/build_harfbuzz.sh)
#   3. gn gen with args from the platform's gn file (system-HB wired at the
#      pack's own HarfBuzz 14.2 headers) + ninja
#
# usage: build.sh [platform]   platform = macos-arm64 (default) | ios-arm64 |
#                              ios-arm64-simulator   (scripts/platform.sh)
#
# Output: build/skia/Release-<platform>/*.a  (the Skia archive set; with
# system-HB Skia produces NO libharfbuzz.a of its own — package.sh copies the
# HarfBuzz build's archive in under that name).
#
# Idempotent: gn gen and ninja are incremental; re-runs are cheap.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIA_ROOT="${PACK_ROOT}/third_party/skia"
HB_INCLUDE="${PACK_ROOT}/third_party/harfbuzz/src"
PLATFORM="${1:-macos-arm64}"
# shellcheck source=scripts/platform.sh
source "${PACK_ROOT}/scripts/platform.sh"
pack_platform_init "${PACK_ROOT}" "${PLATFORM}"
OUT_DIR="${PACK_SKIA_OUT}"
GN_ARGS_FILE="${PACK_ROOT}/${PACK_GN_FILE}"

# 1. Pinned sources: third_party/ clones at pins.json SHAs + Skia DEPS
#    externals. No-op when everything is already in place.
"${PACK_ROOT}/scripts/fetch_sources.sh"

# 2. HarfBuzz first — Skia compiles against its headers.
"${PACK_ROOT}/scripts/build_harfbuzz.sh" "${PLATFORM}"

cd "${SKIA_ROOT}"
if [[ ! -x "${SKIA_ROOT}/bin/gn" ]]; then
    python3 bin/fetch-gn
fi

# 3. Compose the GN args string from the canonical file: strip comments/blank
#    lines, substitute the HarfBuzz include path, join with spaces.
gn_args="$(grep -v '^[[:space:]]*#' "${GN_ARGS_FILE}" | grep -v '^[[:space:]]*$' \
    | sed "s|@HB_INCLUDE@|${HB_INCLUDE}|" | tr '\n' ' ')"

./bin/gn gen "${OUT_DIR}" --args="${gn_args}"
ninja -C "${OUT_DIR}" skia skshaper skparagraph

echo "[skia] built: ${OUT_DIR}"
ls "${OUT_DIR}"/*.a
