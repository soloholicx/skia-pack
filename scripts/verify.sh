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
#   (f) macOS identity (only when pins.json reuses a base release): every
#       archive and header of the macOS tarball, and the xcframework's macOS
#       slice, are byte-identical to the base release's
#   (g) xcframework structure: exactly the three expected slices, each with
#       the same header tree
#   (h) per iOS slice, on the release bytes: arm64 only; every object's
#       LC_BUILD_VERSION is the slice's platform at minos 17.0; _hb_* defined
#       once, same set as macOS; HarfBuzz 14.2.0; merge integrity against the
#       packaging stage; the smoke test LINKS as a consumer would, and the
#       simulator build RUNS inside a booted simulator
#   (i) gn/ios*.gn share every non-platform arg with gn/macos.gn verbatim
#   (j) zip hygiene (scripts/check_zip.sh): the xcframework zip has no
#       AppleDouble ._* / __MACOSX entries, and the tree plain unzip produces
#       (what SwiftPM extracts) equals the tree ditto produces
#   (k) SK_METAL_WAIT_UNTIL_SCHEDULED (scripts/check_wait_scheduled.sh, read
#       from the objects): both iOS slices' GrMtlCommandBuffer::commit calls
#       waitUntilScheduled, the macOS slice's does not; reverse check — the
#       probe must REJECT 'on' for the macOS slice, so it is seen detecting
#       absence on the very bytes under test
#
# The simulator run needs a booted simulator: SKIA_PACK_SIM_UDID=<udid>, or
# any booted device. With none, verify FAILS — set
# SKIA_PACK_VERIFY_SKIP_SIM_RUN=1 to skip that one step explicitly (it is
# then reported as SKIPPED, never as passed).
#
# Idempotent: build/verify is rebuilt from scratch on every run.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${PACK_ROOT}/VERSION")"
PLATFORM="macos-arm64"
STAGE_NAME="skia-pack-${VERSION}-${PLATFORM}"
# SKIA_PACK_VERIFY_ARTIFACTS_DIR points the gate at release bytes that live
# elsewhere (scripts/verify_published.sh: the downloaded assets). verify.sh
# only ever READS that directory.
ARTIFACTS_DIR="${SKIA_PACK_VERIFY_ARTIFACTS_DIR:-${PACK_ROOT}/artifacts}"
TARBALL="${ARTIFACTS_DIR}/${STAGE_NAME}.tar.gz"
XCZIP="${ARTIFACTS_DIR}/SkiaPack.xcframework.zip"
VERIFY="${PACK_ROOT}/build/verify"
# shellcheck source=scripts/platform.sh
source "${PACK_ROOT}/scripts/platform.sh"
SKIPPED=()

[[ -f "${TARBALL}" ]] || { echo "error: run scripts/package.sh first (missing ${TARBALL})" >&2; exit 1; }
[[ -f "${XCZIP}" ]]   || { echo "error: run scripts/package.sh first (missing ${XCZIP})" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

rm -rf "${VERIFY}"
mkdir -p "${VERIFY}"

# ---- (j) zip hygiene, before anything is extracted from it --------------------
"${PACK_ROOT}/scripts/check_zip.sh" "${XCZIP}" || fail "zip(j): ${XCZIP} failed the zip hygiene check"
echo "zip(j) PASS: no AppleDouble/__MACOSX entries; plain unzip tree == ditto tree"

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

# ---- (f) macOS identity against the reused base release ---------------------
XCROOT="${VERIFY}/xcframework/SkiaPack.xcframework"
base_rc=0
"${PACK_ROOT}/scripts/fetch_macos_base.sh" > "${VERIFY}/fetch_macos_base.log" 2>&1 || base_rc=$?
if [[ "${base_rc}" == "0" ]]; then
    base_version="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['macos_base']['version'])" "${PACK_ROOT}/pins.json")"
    BASE_PACK="${PACK_ROOT}/build/macos-base/tarball/skia-pack-${base_version}-${PLATFORM}"
    BASE_SLICE="${PACK_ROOT}/build/macos-base/xcframework/SkiaPack.xcframework/macos-arm64"
    base_libs="$(cd "${BASE_PACK}/lib" && ls)"
    new_libs="$(cd "${LIB}" && ls)"
    [[ "${base_libs}" == "${new_libs}" ]] || fail "identity(f): lib/ file set differs from ${base_version}"
    n=0
    for archive in "${BASE_PACK}/lib/"*; do
        cmp -s "${archive}" "${LIB}/$(basename "${archive}")" \
            || fail "identity(f): lib/$(basename "${archive}") differs from ${base_version}"
        n=$(( n + 1 ))
    done
    diff -rq "${BASE_PACK}/headers" "${PACKDIR}/headers" > /dev/null \
        || fail "identity(f): tarball headers/ differ from ${base_version}"
    cmp -s "${BASE_SLICE}/libSkiaPack.a" "${SLICE}/libSkiaPack.a" \
        || fail "identity(f): xcframework macos-arm64/libSkiaPack.a differs from ${base_version}"
    diff -rq "${BASE_SLICE}/Headers" "${SLICE}/Headers" > /dev/null \
        || fail "identity(f): xcframework macos-arm64/Headers differ from ${base_version}"
    echo "identity(f) PASS: macOS tarball (${n} archives + headers) and xcframework macOS slice are byte-identical to ${base_version}"
elif [[ "${base_rc}" == "3" ]]; then
    echo "identity(f) N/A: pins.json has no macos_base — the macOS slice was built from source"
else
    cat "${VERIFY}/fetch_macos_base.log" >&2
    fail "identity(f): could not materialize the macOS base release"
fi

# ---- (g) xcframework structure ----------------------------------------------
python3 - "${XCROOT}/Info.plist" <<'PY' || fail "structure(g): xcframework Info.plist is not the expected three slices"
import plistlib, sys
libs = plistlib.load(open(sys.argv[1], "rb"))["AvailableLibraries"]
got = sorted((l["LibraryIdentifier"], l["SupportedPlatform"], l.get("SupportedPlatformVariant", ""),
              tuple(l["SupportedArchitectures"])) for l in libs)
want = sorted([("macos-arm64", "macos", "", ("arm64",)),
               ("ios-arm64", "ios", "", ("arm64",)),
               ("ios-arm64-simulator", "ios", "simulator", ("arm64",))])
if got != want:
    print("got ", got, file=sys.stderr); print("want", want, file=sys.stderr); sys.exit(1)
PY
for platform in "${PACK_IOS_PLATFORMS[@]}"; do
    [[ -f "${XCROOT}/${platform}/libSkiaPack.a" ]] || fail "structure(g): ${platform}/libSkiaPack.a missing"
    diff -rq "${SLICE}/Headers" "${XCROOT}/${platform}/Headers" > /dev/null \
        || fail "structure(g): ${platform}/Headers differ from the macOS slice's"
done
echo "structure(g) PASS: macos-arm64 + ios-arm64 + ios-arm64-simulator, arm64 only, one shared header tree"

# ---- (h) iOS slices ----------------------------------------------------------
IOS_FRAMEWORKS=(
    -framework Metal -framework Foundation -framework CoreFoundation
    -framework CoreGraphics -framework CoreText -framework QuartzCore
    -framework IOSurface -framework UIKit
)
macos_hb_set="$(nm -jgU "${LIB}/libharfbuzz.a" | grep '^_hb_' | sort -u)"
for platform in "${PACK_IOS_PLATFORMS[@]}"; do
    pack_platform_init "${PACK_ROOT}" "${platform}"
    lib="${XCROOT}/${platform}/libSkiaPack.a"

    archs="$(lipo -archs "${lib}")"
    [[ "${archs}" == "arm64" ]] || fail "ios(h) ${platform}: archs '${archs}' (must be exactly arm64)"

    # Every member must carry LC_BUILD_VERSION for <platform> at minos 17.0
    # (no other tuple, no LC_VERSION_MIN_* stragglers, no unstamped member).
    tuples="$(otool -l "${lib}" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{p=$2} f&&/minos/{print p, $2; f=0}' | sort -u | tr '\n' ';')"
    [[ "${tuples}" == "${PACK_MACHO_PLATFORM} ${PACK_MINOS};" ]] \
        || fail "ios(h) ${platform}: LC_BUILD_VERSION (platform minos) tuples are '${tuples}', want only '${PACK_MACHO_PLATFORM} ${PACK_MINOS};'"
    stamped="$(otool -l "${lib}" 2>/dev/null | grep -c LC_BUILD_VERSION || true)"
    members="$(members_of "${lib}")"
    [[ "${stamped}" == "${members}" ]] || fail "ios(h) ${platform}: ${stamped} of ${members} members carry LC_BUILD_VERSION"
    old_style="$(otool -l "${lib}" 2>/dev/null | grep -c 'LC_VERSION_MIN' || true)"
    [[ "${old_style}" == "0" ]] || fail "ios(h) ${platform}: ${old_style} members carry LC_VERSION_MIN_*"

    ios_hb_set="$(nm -jgU "${lib}" 2>/dev/null | grep '^_hb_' | sort)"
    dupes="$(printf '%s\n' "${ios_hb_set}" | uniq -d | wc -l | tr -d ' ')"
    [[ "${dupes}" == "0" ]] || fail "ios(h) ${platform}: ${dupes} duplicate _hb_* definitions"
    [[ "${ios_hb_set}" == "${macos_hb_set}" ]] || fail "ios(h) ${platform}: defined _hb_* set differs from macOS libharfbuzz.a"
    # grep -c (not -q): -q exits at the first match and SIGPIPEs `strings` on a
    # 48 MB archive, which pipefail then reports as a failure.
    (( $(strings "${lib}" | grep -c '14\.2\.0' || true) >= 1 )) || fail "ios(h) ${platform}: 14.2.0 version string not found"

    stage="${PACK_ROOT}/build/package/${platform}"
    if [[ -d "${stage}/lib" ]]; then
        cmp -s "${stage}/libSkiaPack.a" "${lib}" || fail "ios(h) ${platform}: release slice differs from the packaging stage"
        sum_members=0; sum_symbols=0
        for archive in "${stage}/lib"/lib*.a; do
            base="$(basename "${archive}")"
            [[ "$(lipo -archs "${archive}")" == "arm64" ]] || fail "ios(h) ${platform}: staged ${base} is not arm64-only"
            if [[ "${base}" != "libharfbuzz.a" ]]; then
                count="$(hb_defined_count "${archive}" 2>/dev/null)"
                (( count == 0 )) || fail "ios(h) ${platform}: ${base} defines ${count} _hb_* symbols (must be 0)"
            fi
            sum_members=$(( sum_members + $(members_of "${archive}") ))
            sum_symbols=$(( sum_symbols + $(symbols_of "${archive}" 2>/dev/null) ))
        done
        [[ "${members}" == "${sum_members}" ]] || fail "ios(h) ${platform}: member count ${members} != input sum ${sum_members}"
        merged_symbols="$(symbols_of "${lib}" 2>/dev/null)"
        [[ "${merged_symbols}" == "${sum_symbols}" ]] || fail "ios(h) ${platform}: defined-symbol count ${merged_symbols} != input sum ${sum_symbols}"
        merge_note="merge = ${members} members / ${merged_symbols} symbols (equals input sums)"
    else
        merge_note="merge integrity SKIPPED (no build/package stage)"
        SKIPPED+=("${platform} merge integrity (no build/package stage on this machine)")
    fi

    xcrun --sdk "${PACK_SDK}" clang++ -std=c++20 -O1 -target "${PACK_TRIPLE}" \
        -I "${XCROOT}/${platform}/Headers" "${SMOKE_SRC}" "${lib}" "${IOS_FRAMEWORKS[@]}" \
        -o "${VERIFY}/smoke_${platform}"
    built="$(vtool -show-build "${VERIFY}/smoke_${platform}" | awk '/platform/{p=$2} /minos/{m=$2} END{print p, m}')"
    echo "ios(h) PASS ${platform}: arm64 only; ${members} objects all platform ${PACK_MACHO_PLATFORM} minos ${PACK_MINOS}; _hb_* set == macOS, no dupes; HB 14.2.0; ${merge_note}; smoke links (${built})"
done

# The simulator smoke binary is a plain Mach-O for iOS Simulator: run it inside
# a booted simulator (the device binary cannot run here — link-only above).
if [[ "${SKIA_PACK_VERIFY_SKIP_SIM_RUN:-0}" == "1" ]]; then
    echo "ios(h) SKIPPED: simulator smoke run (SKIA_PACK_VERIFY_SKIP_SIM_RUN=1)"
    SKIPPED+=("simulator smoke run (SKIA_PACK_VERIFY_SKIP_SIM_RUN=1)")
else
    udid="${SKIA_PACK_SIM_UDID:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
    [[ -n "${udid}" ]] || fail "ios(h): no booted simulator for the smoke run — boot one (xcrun simctl boot <udid>), set SKIA_PACK_SIM_UDID, or set SKIA_PACK_VERIFY_SKIP_SIM_RUN=1 to skip explicitly"
    xcrun simctl spawn "${udid}" "${VERIFY}/smoke_ios-arm64-simulator" > "${VERIFY}/smoke_ios-arm64-simulator.log" 2>&1 \
        || { cat "${VERIFY}/smoke_ios-arm64-simulator.log" >&2; fail "ios(h): simulator smoke run failed"; }
    grep -q '^SMOKE OK$' "${VERIFY}/smoke_ios-arm64-simulator.log" || fail "ios(h): simulator smoke run did not print SMOKE OK"
    echo "ios(h) PASS: smoke test ran in simulator ${udid} ($(grep '^hb_version_string' "${VERIFY}/smoke_ios-arm64-simulator.log"); $(grep '^non-background' "${VERIFY}/smoke_ios-arm64-simulator.log"))"
fi

# ---- (i) gn arg drift ---------------------------------------------------------
gn_shared() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' -e '^extra_cflags=' "$1"; }
for gn in ios ios-sim; do
    shared="$(gn_shared "${PACK_ROOT}/gn/${gn}.gn" | grep -v -e '^target_os=' -e '^ios_use_simulator=' -e '^ios_min_target=' -e '^skia_ios_use_signing=')"
    [[ "${shared}" == "$(gn_shared "${PACK_ROOT}/gn/macos.gn")" ]] || fail "gn(i): gn/${gn}.gn shared args drifted from gn/macos.gn"
done
echo "gn(i) PASS: gn/ios.gn and gn/ios-sim.gn share every non-platform arg with gn/macos.gn"

# ---- (k) SK_METAL_WAIT_UNTIL_SCHEDULED in the iOS slices, not in macOS ----------
for gn in ios ios-sim; do
    grep -qx 'extra_cflags=\[.*"-DSK_METAL_WAIT_UNTIL_SCHEDULED".*\]' "${PACK_ROOT}/gn/${gn}.gn" \
        || fail "wait(k): gn/${gn}.gn does not define SK_METAL_WAIT_UNTIL_SCHEDULED"
done
grep -q 'SK_METAL_WAIT_UNTIL_SCHEDULED' "${PACK_ROOT}/gn/macos.gn" && fail "wait(k): gn/macos.gn defines SK_METAL_WAIT_UNTIL_SCHEDULED"
for platform in "${PACK_IOS_PLATFORMS[@]}"; do
    "${PACK_ROOT}/scripts/check_wait_scheduled.sh" "${XCROOT}/${platform}/libSkiaPack.a" on \
        || fail "wait(k) ${platform}: GrMtlCommandBuffer::commit does not call waitUntilScheduled"
done
"${PACK_ROOT}/scripts/check_wait_scheduled.sh" "${XCROOT}/macos-arm64/libSkiaPack.a" off \
    || fail "wait(k) macos-arm64: the macOS slice is expected without the macro"
reverse_rc=0
"${PACK_ROOT}/scripts/check_wait_scheduled.sh" "${XCROOT}/macos-arm64/libSkiaPack.a" on > "${VERIFY}/wait-reverse.log" 2>&1 || reverse_rc=$?
[[ "${reverse_rc}" == "1" ]] \
    || { cat "${VERIFY}/wait-reverse.log" >&2; fail "wait(k) reverse check: probing the macOS slice for 'on' returned rc=${reverse_rc}, want 1 (rejected)"; }
echo "wait(k) PASS: both iOS slices call waitUntilScheduled from GrMtlCommandBuffer::commit; macOS does not; reverse check rejected 'on' for macOS"

echo
if (( ${#SKIPPED[@]} > 0 )); then
    echo "[verify] PASSED WITH SKIPS — not a full release gate:"
    printf '  skipped: %s\n' "${SKIPPED[@]}"
else
    echo "[verify] ALL CHECKS PASSED"
fi
