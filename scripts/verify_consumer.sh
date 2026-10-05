#!/usr/bin/env bash
# Build tests/consumer — a SwiftPM package depending on the SkiaPack product —
# for every platform the xcframework ships, the way a real consumer would.
#
#   verify_consumer.sh local            pre-release: this checkout as a path
#                                       dependency + the xcframework that
#                                       scripts/verify.sh unzipped from the
#                                       release zip (build/verify/xcframework)
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
#                    Asserted so the documented limitation stays true.
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
        export SKIA_PACK_CONSUMER_DEP="path:${PACK_ROOT}"
        # SwiftPM requires a binaryTarget path RELATIVE to the package root.
        export SKIA_PACK_LOCAL_XCFRAMEWORK="build/verify/xcframework/SkiaPack.xcframework" ;;
    exact)
        [[ -n "${2:-}" ]] || { echo "usage: verify_consumer.sh exact <version>" >&2; exit 2; }
        export SKIA_PACK_CONSUMER_DEP="exact:$2"
        unset SKIA_PACK_LOCAL_XCFRAMEWORK ;;
    *) echo "usage: verify_consumer.sh local | exact <version>" >&2; exit 2 ;;
esac

fail() { echo "FAIL: $*" >&2; exit 1; }
WORK="${PACK_ROOT}/build/verify-consumer"
rm -rf "${WORK}"
mkdir -p "${WORK}"
cp -R "${PACK_ROOT}/tests/consumer" "${WORK}/consumer"
cd "${WORK}/consumer"

echo "consumer: macOS (swift build + run)..."
swift build > "${WORK}/macos-build.log" 2>&1 || { tail -30 "${WORK}/macos-build.log" >&2; fail "consumer macOS build"; }
./.build/debug/consumer-cli || fail "consumer macOS run"
echo "consumer macOS PASS"

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

echo "consumer: iOS Simulator (generic, unrestricted archs) — must fail on x86_64..."
rm -rf "${WORK}/dd/Build/Products/Debug-iphonesimulator"
if xcb "${WORK}/ios-sim-generic-universal.log" 'generic/platform=iOS Simulator' ONLY_ACTIVE_ARCH=NO; then
    fail "a universal simulator build linked — the arm64-only limitation documented in README.md is no longer true; update the docs and this check"
fi
grep -q "x86_64" "${WORK}/ios-sim-generic-universal.log" \
    || { grep -E "error:|ld:" "${WORK}/ios-sim-generic-universal.log" | head -20 >&2; fail "universal simulator build failed, but not because of x86_64"; }
echo "consumer iOS Simulator universal: fails on x86_64 as documented"

echo
echo "[verify-consumer] ALL CHECKS PASSED (${MODE})"
