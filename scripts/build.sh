#!/usr/bin/env bash
# Full pack build:
#   1. standalone HarfBuzz static archive (scripts/build_harfbuzz.sh)
#   2. Skia externals sync (tools/git-sync-deps — network; skipped when
#      externals are already present unless SKIA_PACK_SYNC_DEPS=1)
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

if [[ ! -f "${SKIA_ROOT}/tools/git-sync-deps" ]]; then
    echo "error: skia submodule not initialized (${SKIA_ROOT})" >&2
    echo "run: git submodule update --init third_party/skia" >&2
    exit 1
fi

# 1. HarfBuzz first — Skia compiles against its headers.
"${PACK_ROOT}/scripts/build_harfbuzz.sh"

# 2. Skia DEPS externals (vendored ICU, libjpeg-turbo, …). Needs network.
#    Skip when already synced unless forced — keeps offline re-runs working.
cd "${SKIA_ROOT}"
if [[ ! -d "${SKIA_ROOT}/third_party/externals/icu" || "${SKIA_PACK_SYNC_DEPS:-0}" == "1" ]]; then
    python3 tools/git-sync-deps
else
    echo "[skia] externals present — skipping git-sync-deps (SKIA_PACK_SYNC_DEPS=1 to force)"
fi
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
