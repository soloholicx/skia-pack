#!/usr/bin/env bash
# Build tests/consumer — a SwiftPM package depending on the SkiaPack product —
# for every platform the xcframework ships, the way a real consumer would.
#
#   verify_consumer.sh local            pre-release: this checkout as a path
#                                       dependency + the release ZIP itself
#                                       (artifacts/SkiaPack.xcframework.zip),
#                                       which SwiftPM extracts the way it will
#                                       for a published release
#   verify_consumer.sh exact <version>  post-release: the published tag
#
# Checks:
#   macOS            swift build, then RUN the executable
#   iOS device       xcodebuild, generic/platform=iOS                 (link)
#   iOS Simulator    xcodebuild, a concrete simulator destination     (link) —
#                    no arch flags: Xcode builds only the active arch
#   iOS Simulator    xcodebuild, generic/platform=iOS Simulator with
#                    ARCHS=arm64                                      (link)
#   iOS Simulator    the same generic destination WITHOUT an arch restriction
#                    must FAIL: the simulator slice is arm64-only, so a
#                    universal (arm64 + x86_64) simulator build cannot link.
#                    Asserted so the documented limitation stays true. The
#                    failure must be THAT failure — the linker ignoring
#                    libSkiaPack.a for x86_64 and then missing its symbols,
#                    with the arm64 half and all compilation clean — not just
#                    any red build whose log mentions x86_64.
#   negative control the same universal build with a deliberate compile error
#                    must NOT be accepted as "the documented failure".
#
#   privacy, iOS     tests/consumer-app (an iOS app linking SkiaPack statically
#                    through tests/consumer) archived Release, unsigned; the
#                    archive's .app — not Build/Products — must carry exactly
#                    one valid skia-pack_SkiaPackPrivacy.bundle/PrivacyInfo.xcprivacy
#                    identical to Sources/SkiaPackPrivacy/PrivacyInfo.xcprivacy
#                    (scripts/check_privacy_carry.sh). Negative controls on
#                    copies of that archive: bundle removed from the app while
#                    Build/Products still has it, a duplicate bundle, and a
#                    tampered manifest must each be rejected.
#   privacy, macOS   the manifest covers the iOS slices only: the macOS swift
#                    build and the macOS xcodebuild build must hold NO
#                    skia-pack_SkiaPackPrivacy.bundle (a failed search fails).
#                    local only — control: the same two builds against a copy
#                    of this package whose SkiaPackPrivacy dependency is made
#                    unconditional must each show the bundle, so the search is
#                    seen finding it on macOS.
#   local only       the xcframework SwiftPM extracted from the zip (for the
#                    macOS build and for xcodebuild) has no AppleDouble ._*
#                    file and is byte-identical, tree for tree, to the one
#                    scripts/verify.sh extracted with ditto
#
# The concrete-destination check needs an available simulator device:
# SKIA_PACK_SIM_UDID=<udid>, else any booted device.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
case "${MODE}" in
    local)
        XCF="${PACK_ROOT}/build/verify/xcframework/SkiaPack.xcframework"
        [[ -d "${XCF}" ]] || { echo "error: run scripts/verify.sh first (missing ${XCF})" >&2; exit 1; }
        [[ -f "${PACK_ROOT}/artifacts/SkiaPack.xcframework.zip" ]] \
            || { echo "error: run scripts/package.sh first (missing artifacts/SkiaPack.xcframework.zip)" >&2; exit 1; }
        export SKIA_PACK_CONSUMER_DEP="path:${PACK_ROOT}"
        # SwiftPM requires a binaryTarget path RELATIVE to the package root.
        # The zip, not an extracted directory: consumers get the zip.
        export SKIA_PACK_LOCAL_XCFRAMEWORK="artifacts/SkiaPack.xcframework.zip" ;;
    exact)
        [[ -n "${2:-}" ]] || { echo "usage: verify_consumer.sh exact <version>" >&2; exit 2; }
        export SKIA_PACK_CONSUMER_DEP="exact:$2"
        unset SKIA_PACK_LOCAL_XCFRAMEWORK ;;
    *) echo "usage: verify_consumer.sh local | exact <version>" >&2; exit 2 ;;
esac

fail() { echo "FAIL: $*" >&2; exit 1; }

# check_spm_extracted <label> <search root>: local mode only. Exactly one
# SkiaPack.xcframework that SwiftPM extracted from the zip; no ._* file in it;
# same files and bytes as the ditto-extracted reference.
check_spm_extracted() {
    [[ "${MODE}" == "local" ]] || return 0
    local label="$1" root="$2" list="${WORK}/$1-xcframework.lst" found n
    # The count and the path come from the same checked NUL list (nul_records).
    find "${root}" -type d -name SkiaPack.xcframework -prune -print0 > "${list}" 2> "${WORK}/${label}-xcframework.err" \
        || fail "${label}: searching ${root} for SkiaPack.xcframework failed: $(head -1 "${WORK}/${label}-xcframework.err")"
    n="$(nul_records "${list}" count)" || exit 1
    [[ "${n}" == "1" ]] || fail "${label}: expected one SwiftPM-extracted SkiaPack.xcframework under ${root}, found ${n}"
    found="$(nul_records "${list}" one)" || exit 1
    # The search goes to a file first: `find | head` under pipefail would die of
    # SIGPIPE when there are many hits, exiting without this message.
    find "${found}" -name '._*' > "${WORK}/${label}-appledouble.txt" 2> "${WORK}/${label}-appledouble.err" \
        || fail "${label}: searching the SwiftPM-extracted xcframework for ._* failed: $(head -1 "${WORK}/${label}-appledouble.err")"
    [[ ! -s "${WORK}/${label}-appledouble.txt" ]] \
        || fail "${label}: SwiftPM-extracted xcframework contains $(wc -l < "${WORK}/${label}-appledouble.txt" | tr -d ' ') AppleDouble files, e.g. $(head -3 "${WORK}/${label}-appledouble.txt" | tr '\n' ' ')"
    diff -r "${XCF}" "${found}" > "${WORK}/${label}-extracted.diff" 2>&1 \
        || fail "${label}: SwiftPM-extracted xcframework differs from build/verify's (see ${WORK}/${label}-extracted.diff)"
    echo "consumer ${label}: SwiftPM extracted the zip — no ._* files, identical to the verified tree"
}
WORK="${PACK_ROOT}/build/verify-consumer"
rm -rf "${WORK}"
mkdir -p "${WORK}"
PRIVACY_BUNDLE="skia-pack_SkiaPackPrivacy.bundle"
# nul_records, count_privacy_bundles, grep_count: a failed search, read or grep fails the gate — never "0".
source "${PACK_ROOT}/scripts/consumer_counts.sh"
# macos_xcodebuild <log> <derived data>: the consumer package built for macOS by xcodebuild.
macos_xcodebuild() {
    xcodebuild -scheme SkiaPackConsumer -destination 'platform=macOS' -derivedDataPath "$2" \
        -skipPackagePluginValidation build > "$1" 2>&1
}
cp -R "${PACK_ROOT}/tests/consumer" "${WORK}/consumer"
cd "${WORK}/consumer"

echo "consumer: macOS (swift build + run)..."
swift build > "${WORK}/macos-build.log" 2>&1 || { tail -30 "${WORK}/macos-build.log" >&2; fail "consumer macOS build"; }
./.build/debug/consumer-cli || fail "consumer macOS run"
echo "consumer macOS PASS"
check_spm_extracted swiftpm "${WORK}/consumer/.build/artifacts"
n="$(count_privacy_bundles "${WORK}/consumer/.build")"
[[ "${n}" == 0 ]] || fail "privacy: the macOS swift build holds ${n} ${PRIVACY_BUNDLE} — the manifest covers iOS only"
echo "consumer macOS (swift build): no ${PRIVACY_BUNDLE}, as intended (the manifest covers iOS only)"

echo "consumer: macOS (xcodebuild) — no privacy bundle..."
macos_xcodebuild "${WORK}/macos-xcodebuild.log" "${WORK}/dd-macos" \
    || { grep -E "error:|ld:" "${WORK}/macos-xcodebuild.log" | head -20 >&2; fail "consumer macOS xcodebuild build"; }
n="$(count_privacy_bundles "${WORK}/dd-macos/Build")"
[[ "${n}" == 0 ]] || fail "privacy: the macOS xcodebuild build holds ${n} ${PRIVACY_BUNDLE} — the manifest covers iOS only"
echo "consumer macOS (xcodebuild): no ${PRIVACY_BUNDLE}, as intended"

if [[ "${MODE}" == local ]]; then
    echo "consumer: privacy control — with the dependency made unconditional, macOS must show the bundle..."
    CTRL="${WORK}/pack-unconditional"
    mkdir -p "${CTRL}/artifacts"
    cp -R "${PACK_ROOT}/Package.swift" "${PACK_ROOT}/Sources" "${CTRL}/"
    cp "${PACK_ROOT}/artifacts/SkiaPack.xcframework.zip" "${CTRL}/artifacts/"
    sed -i '' 's/\.target(name: "SkiaPackPrivacy", condition: \.when(platforms: \[\.iOS\]))/.target(name: "SkiaPackPrivacy", condition: nil)/' "${CTRL}/Package.swift"
    uncond="$(grep_count 'name: "SkiaPackPrivacy", condition: nil' "${CTRL}/Package.swift")"
    ios_only="$(grep_count 'condition: .when(platforms: \[.iOS\])' "${CTRL}/Package.swift")"
    [[ "${uncond}" == 1 && "${ios_only}" == 0 ]] \
        || fail "privacy control: could not make the SkiaPackPrivacy dependency unconditional in the copy"
    cp -R "${PACK_ROOT}/tests/consumer" "${WORK}/consumer-ctrl"
    (cd "${WORK}/consumer-ctrl" && SKIA_PACK_CONSUMER_DEP="path:${CTRL}" swift build > "${WORK}/ctrl-macos-build.log" 2>&1) \
        || { tail -30 "${WORK}/ctrl-macos-build.log" >&2; fail "privacy control: macOS swift build"; }
    n="$(count_privacy_bundles "${WORK}/consumer-ctrl/.build")"
    [[ "${n}" -ge 1 ]] || fail "privacy control: the unconditional macOS swift build shows no ${PRIVACY_BUNDLE} — the search cannot see it"
    (cd "${WORK}/consumer-ctrl" && SKIA_PACK_CONSUMER_DEP="path:${CTRL}" macos_xcodebuild "${WORK}/ctrl-macos-xcodebuild.log" "${WORK}/dd-ctrl-macos") \
        || { grep -E "error:|ld:" "${WORK}/ctrl-macos-xcodebuild.log" | head -20 >&2; fail "privacy control: macOS xcodebuild build"; }
    m="$(count_privacy_bundles "${WORK}/dd-ctrl-macos/Build")"
    [[ "${m}" -ge 1 ]] || fail "privacy control: the unconditional macOS xcodebuild build shows no ${PRIVACY_BUNDLE} — the search cannot see it"
    echo "consumer privacy control: unconditional dependency shows the bundle on macOS (swift build ${n}, xcodebuild ${m})"
fi

xcb() { # xcb <log> <destination> [extra xcodebuild settings…]
    local log="$1" dest="$2"; shift 2
    xcodebuild -scheme SkiaPackConsumer -destination "${dest}" -derivedDataPath "${WORK}/dd" \
        -skipPackagePluginValidation "$@" build > "${log}" 2>&1
}
built_platform() { # built_platform <products subdir>
    local bin
    bin="$(find "${WORK}/dd/Build/Products/$1" -name 'SkiaPackConsumer' -type f -perm +111 2>/dev/null | head -1)"
    [[ -n "${bin}" ]] || { echo "no binary"; return; }
    echo "$(lipo -archs "${bin}") / $(vtool -show-build "${bin}" | awk '/platform/{p=$2} /minos/{m=$2} END{print p, m}')"
}

echo "consumer: iOS device (generic/platform=iOS)..."
xcb "${WORK}/ios-device.log" 'generic/platform=iOS' \
    || { grep -E "error:|ld:" "${WORK}/ios-device.log" | head -20 >&2; fail "consumer iOS device build"; }
echo "consumer iOS device PASS ($(built_platform Debug-iphoneos))"
check_spm_extracted xcodebuild "${WORK}/dd/SourcePackages/artifacts"

echo "consumer: iOS app archive (Release, unsigned) — privacy manifest carry..."
cp -R "${PACK_ROOT}/tests/consumer-app" "${WORK}/consumer-app"
ARCHIVE="${WORK}/ConsumerApp.xcarchive"
MANIFEST="${PACK_ROOT}/Sources/SkiaPackPrivacy/PrivacyInfo.xcprivacy"
CARRY="${PACK_ROOT}/scripts/check_privacy_carry.sh"
xcodebuild -project "${WORK}/consumer-app/ConsumerApp.xcodeproj" -scheme ConsumerApp -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "${WORK}/dd-app" -archivePath "${ARCHIVE}" \
    -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO archive > "${WORK}/app-archive.log" 2>&1 \
    || { grep -E "error:|ld:" "${WORK}/app-archive.log" | head -20 >&2; fail "consumer app archive"; }
"${CARRY}" "${ARCHIVE}" "${MANIFEST}" || fail "privacy: the archived app does not carry the manifest correctly (rc=$?)"
# carry_negative <name> <message the gate must give> <mutation (run in the copy's .app)>
carry_negative() {
    local name="$1" want="$2" mutation="$3" copy="${WORK}/carry-neg-$1.xcarchive" out rc
    cp -R "${ARCHIVE}" "${copy}" || fail "privacy negative ${name}: copy failed"
    (cd "${copy}/Products/Applications/ConsumerApp.app" && eval "${mutation}") || fail "privacy negative ${name}: mutation failed"
    out="$("${CARRY}" "${copy}" "${MANIFEST}" 2>&1)" && rc=0 || rc=$?   # set -e: capture, do not exit
    [[ ${rc} -eq 1 ]] && grep -qF -- "${want}" <<< "${out}" \
        || fail "privacy negative ${name}: want rc=1 with '${want}', got rc=${rc}: ${out}"
    echo "consumer privacy negative ${name}: rejected (${out##*FAIL: })"
}
n="$(count_privacy_bundles "${WORK}/dd-app/Build")"
[[ "${n}" -ge 1 ]] || fail "privacy negative setup: Build/ has no ${PRIVACY_BUNDLE}, so 'missing in the app' would not be exercised"
carry_negative missing-in-app "found 0" "rm -rf ${PRIVACY_BUNDLE}"
carry_negative duplicate "found 2" "mkdir -p Frameworks/Dup.framework && cp -R ${PRIVACY_BUNDLE} Frameworks/Dup.framework/"
carry_negative tampered "differs from" "sed -i '' 's/<false\/>/<true\/>/' ${PRIVACY_BUNDLE}/PrivacyInfo.xcprivacy"
echo "consumer privacy iOS: the archived app carries exactly one valid, intact PrivacyInfo.xcprivacy"

udid="${SKIA_PACK_SIM_UDID:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
[[ -n "${udid}" ]] || fail "no simulator device for the concrete-destination build — set SKIA_PACK_SIM_UDID or boot one"
echo "consumer: iOS Simulator (concrete destination ${udid}, no arch flags)..."
rm -rf "${WORK}/dd/Build/Products/Debug-iphonesimulator"
xcb "${WORK}/ios-sim-concrete.log" "platform=iOS Simulator,id=${udid}" \
    || { grep -E "error:|ld:" "${WORK}/ios-sim-concrete.log" | head -20 >&2; fail "consumer iOS Simulator (concrete) build"; }
echo "consumer iOS Simulator concrete PASS ($(built_platform Debug-iphonesimulator))"

echo "consumer: iOS Simulator (generic, ARCHS=arm64)..."
rm -rf "${WORK}/dd/Build/Products/Debug-iphonesimulator"
xcb "${WORK}/ios-sim-generic-arm64.log" 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    || { grep -E "error:|ld:" "${WORK}/ios-sim-generic-arm64.log" | head -20 >&2; fail "consumer iOS Simulator (generic, ARCHS=arm64) build"; }
echo "consumer iOS Simulator generic+arm64 PASS ($(built_platform Debug-iphonesimulator))"

# Is <log> the documented failure and nothing else? Prints the reason when not.
#   required: ld ignored libSkiaPack.a members as arm64-where-x86_64-was-needed,
#             and the x86_64 link then reported undefined symbols
#   excluded: any compile error, or undefined symbols for arm64 (the half that
#             must still link)
is_arm64_only_link_failure() {
    local log="$1"
    grep -q "ignoring file '[^']*libSkiaPack\.a([^']*)': found architecture 'arm64', required architecture 'x86_64'" "${log}" \
        || { echo "ld never reported libSkiaPack.a as arm64-vs-x86_64"; return 1; }
    grep -q "^Undefined symbols for architecture x86_64:" "${log}" \
        || { echo "no 'Undefined symbols for architecture x86_64'"; return 1; }
    if grep -q "^Undefined symbols for architecture arm64" "${log}"; then
        echo "the arm64 link failed too"; return 1
    fi
    # Every 'error:' line must be the linker's own summary; anything else (a
    # compiler diagnostic, a missing module, a packaging error) is unrelated.
    local other
    other="$(grep -E "(^|[^a-z])error:" "${log}" | grep -v "linker command failed with exit code" | head -3 || true)"
    [[ -z "${other}" ]] || { echo "unrelated error(s): ${other}"; return 1; }
}

echo "consumer: iOS Simulator (generic, unrestricted archs) — must fail on x86_64..."
rm -rf "${WORK}/dd/Build/Products/Debug-iphonesimulator"
if xcb "${WORK}/ios-sim-generic-universal.log" 'generic/platform=iOS Simulator' ONLY_ACTIVE_ARCH=NO; then
    fail "a universal simulator build linked — the arm64-only limitation documented in README.md is no longer true; update the docs and this check"
fi
why="$(is_arm64_only_link_failure "${WORK}/ios-sim-generic-universal.log")" \
    || fail "universal simulator build failed, but not as the documented arm64-only link failure: ${why}"
echo "consumer iOS Simulator universal: x86_64 link fails on the arm64-only libSkiaPack.a, as documented"

echo "consumer: negative control — an unrelated failure must not be accepted..."
printf '\n#error deliberate unrelated failure (verify_consumer negative control)\n' >> Sources/SkiaPackConsumer/SkiaPackConsumer.cpp
rm -rf "${WORK}/dd/Build/Products/Debug-iphonesimulator"
if xcb "${WORK}/ios-sim-negative-control.log" 'generic/platform=iOS Simulator' ONLY_ACTIVE_ARCH=NO; then
    fail "negative control: the deliberately broken build succeeded"
fi
grep -q "x86_64" "${WORK}/ios-sim-negative-control.log" || fail "negative control: log does not even mention x86_64 (control is not exercising the old weak check)"
if why="$(is_arm64_only_link_failure "${WORK}/ios-sim-negative-control.log")"; then
    fail "negative control: an unrelated compile failure was accepted as the documented x86_64 link failure"
fi
echo "consumer negative control: unrelated failure rejected (${why%%$'\n'*})"

echo
echo "[verify-consumer] ALL CHECKS PASSED (${MODE})"
