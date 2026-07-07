#!/usr/bin/env bash
# Release-gate verification. Runs against the EXACT release bytes: the tarball
# is re-extracted and the xcframework zip re-unzipped into build/verify/.
#
# Checks:
#   (a) every Skia-produced archive defines zero _hb_* symbols
#   (b) across all packaged archives, ONLY libharfbuzz.a defines _hb_*
#       (and the merged libSkiaPack.a defines exactly the same set, no dupes)
#   (c) libharfbuzz.a embeds the 14.2.0 version string
#   (d) libtool-merge integrity: member count and defined-symbol count of
#       libSkiaPack.a equal the sums over the input archives
#   (e) smoke test builds AND runs against BOTH artifact forms:
#         form 1 — tarball: -I headers/ + individual .a archives
#         form 2 — xcframework: Headers/ + merged libSkiaPack.a
#
# Idempotent: build/verify is rebuilt from scratch on every run.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${PACK_ROOT}/VERSION")"
PLATFORM="macos-arm64"
STAGE_NAME="skia-pack-${VERSION}-${PLATFORM}"
TARBALL="${PACK_ROOT}/artifacts/${STAGE_NAME}.tar.gz"
XCZIP="${PACK_ROOT}/artifacts/SkiaPack.xcframework.zip"
VERIFY="${PACK_ROOT}/build/verify"

[[ -f "${TARBALL}" ]] || { echo "error: run scripts/package.sh first (missing ${TARBALL})" >&2; exit 1; }
[[ -f "${XCZIP}" ]]   || { echo "error: run scripts/package.sh first (missing ${XCZIP})" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

rm -rf "${VERIFY}"
mkdir -p "${VERIFY}"
tar -xzf "${TARBALL}" -C "${VERIFY}"
ditto -x -k "${XCZIP}" "${VERIFY}/xcframework"

PACKDIR="${VERIFY}/${STAGE_NAME}"
LIB="${PACKDIR}/lib"
SLICE="${VERIFY}/xcframework/SkiaPack.xcframework/macos-arm64"
[[ -d "${PACKDIR}/headers" && -d "${LIB}" ]] || fail "tarball layout unexpected"
[[ -f "${SLICE}/libSkiaPack.a" && -d "${SLICE}/Headers" ]] || fail "xcframework layout unexpected"

hb_defined_count() { nm -jgU "$1" | grep -c '^_hb_' || true; }

# ---- audits (a) + (b): _hb_* definer sweep over every packaged archive -----
hb_count=0
for archive in "${LIB}"/lib*.a; do
    base="$(basename "${archive}")"
    [[ "${base}" == "libSkiaPack.a" ]] && continue
    count="$(hb_defined_count "${archive}")"
    if [[ "${base}" == "libharfbuzz.a" ]]; then
        (( count > 0 )) || fail "audit(b): libharfbuzz.a defines no _hb_* symbols"
        hb_count="${count}"
    else
        (( count == 0 )) || fail "audit(a/b): ${base} defines ${count} _hb_* symbols (must be 0)"
    fi
done
echo "audit(a) PASS: all Skia-produced archives define 0 _hb_* symbols"
echo "audit(b) PASS: only libharfbuzz.a defines _hb_* (${hb_count} symbols)"

merged_hb="$(hb_defined_count "${LIB}/libSkiaPack.a")"
[[ "${merged_hb}" == "${hb_count}" ]] \
    || fail "merged libSkiaPack.a _hb_* count ${merged_hb} != libharfbuzz.a ${hb_count}"
dupes="$(nm -jgU "${LIB}/libSkiaPack.a" | grep '^_hb_' | sort | uniq -d | wc -l | tr -d ' ')"
[[ "${dupes}" == "0" ]] || fail "merged archive has ${dupes} duplicate _hb_* definitions"
echo "audit(b+) PASS: merged archive defines the same ${merged_hb} _hb_* symbols, no duplicates"

# ---- audit (c): HB version string ------------------------------------------
strings "${LIB}/libharfbuzz.a" | grep -q '14\.2\.0' \
    || fail "audit(c): 14.2.0 version string not found in libharfbuzz.a"
echo "audit(c) PASS: libharfbuzz.a embeds 14.2.0"

# ---- audit (d): libtool-merge integrity -------------------------------------
members_of()  { ar -t "$1" | grep -cv '^__\.SYMDEF' || true; }
symbols_of()  { nm -jgU "$1" | grep -cv -e ':$' -e '^$' || true; }

sum_members=0
sum_symbols=0
for archive in "${LIB}"/lib*.a; do
    [[ "$(basename "${archive}")" == "libSkiaPack.a" ]] && continue
    sum_members=$(( sum_members + $(members_of "${archive}") ))
    sum_symbols=$(( sum_symbols + $(symbols_of "${archive}") ))
done
merged_members="$(members_of "${LIB}/libSkiaPack.a")"
merged_symbols="$(symbols_of "${LIB}/libSkiaPack.a")"
[[ "${merged_members}" == "${sum_members}" ]] \
    || fail "audit(d): member count ${merged_members} != input sum ${sum_members}"
[[ "${merged_symbols}" == "${sum_symbols}" ]] \
    || fail "audit(d): defined-symbol count ${merged_symbols} != input sum ${sum_symbols}"
echo "audit(d) PASS: libSkiaPack.a = ${merged_members} members, ${merged_symbols} defined symbols (equals input sums)"

# ---- (e) smoke test, both artifact forms ------------------------------------
FRAMEWORKS=(
    -framework Metal -framework MetalKit -framework Foundation
    -framework CoreFoundation -framework CoreGraphics -framework CoreText
    -framework CoreServices -framework AppKit -framework QuartzCore
    -framework IOSurface -framework OpenGL
)
CXXFLAGS=(-std=c++20 -mmacosx-version-min=14.0 -O1)
SMOKE_SRC="${PACK_ROOT}/tests/smoke/smoke.cpp"

# Canonical consumer link order (slate-kit's _SKIA_BUNDLED_LIBS).
BUNDLED_LIBS=(
    libskia.a libskshaper.a libskparagraph.a libskunicode_core.a
    libskunicode_icu.a libharfbuzz.a libicu.a libpng.a libwebp.a
    libwebp_sse41.a libjpeg.a libjpeg12.a libjpeg16.a libskcms.a
    libdng_sdk.a libpiex.a libexpat.a libwuffs.a libzlib.a
)
link_libs=()
for lib in "${BUNDLED_LIBS[@]}"; do
    [[ -f "${LIB}/${lib}" ]] || fail "tarball missing expected archive ${lib}"
    link_libs+=("${LIB}/${lib}")
done

echo "smoke form 1 (tarball: headers/ + individual archives)..."
clang++ "${CXXFLAGS[@]}" -I "${PACKDIR}/headers" "${SMOKE_SRC}" \
    "${link_libs[@]}" "${FRAMEWORKS[@]}" -o "${VERIFY}/smoke_tarball"
"${VERIFY}/smoke_tarball" "${VERIFY}/smoke_tarball.png"
echo "smoke form 1 PASS"

echo "smoke form 2 (xcframework: Headers/ + merged libSkiaPack.a)..."
clang++ "${CXXFLAGS[@]}" -I "${SLICE}/Headers" "${SMOKE_SRC}" \
    "${SLICE}/libSkiaPack.a" "${FRAMEWORKS[@]}" -o "${VERIFY}/smoke_merged"
"${VERIFY}/smoke_merged" "${VERIFY}/smoke_merged.png"
echo "smoke form 2 PASS"

echo
echo "[verify] ALL CHECKS PASSED"
