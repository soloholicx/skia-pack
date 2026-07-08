#!/usr/bin/env bash
# Full pack build:
#   1. pinned sources (scripts/fetch_sources.sh — pins.json → third_party/
#      clones + Skia DEPS externals; no-op when already at the pins)
#   2. standalone HarfBuzz static archive (scripts/build_harfbuzz.sh)
#   3. gn gen with args from gn/macos.gn (system-HB wired at the pack's own
#      HarfBuzz 14.2 headers) + ninja
#
# Output: build/skia/Release-macos-arm64/*.a  (the Skia archive set; with
# system-HB Skia produces NO libharfbuzz.a of its own — package.sh copies the
# HarfBuzz build's archive in under that name).
#
# Idempotent: gn gen and ninja are incremental; re-runs are cheap.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIA_ROOT="${PACK_ROOT}/third_party/skia"
HB_INCLUDE="${PACK_ROOT}/third_party/harfbuzz/src"
OUT_DIR="${PACK_ROOT}/build/skia/Release-macos-arm64"
GN_ARGS_FILE="${PACK_ROOT}/gn/macos.gn"

# 1. Pinned sources: third_party/ clones at pins.json SHAs + Skia DEPS
#    externals. No-op when everything is already in place.
"${PACK_ROOT}/scripts/fetch_sources.sh"

# 2. HarfBuzz first — Skia compiles against its headers.
"${PACK_ROOT}/scripts/build_harfbuzz.sh"

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
