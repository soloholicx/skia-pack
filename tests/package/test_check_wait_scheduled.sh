#!/usr/bin/env bash
# Self-test for scripts/check_wait_scheduled.sh on synthetic archives (no Skia
# build needed). A tiny GrMtlCommandBuffer::commit(bool) is compiled for iOS
# with and without the waitUntilScheduled call and archived under the member
# name the real archives use; the checker must classify each correctly, and
# must report a PROBE ERROR (not "off") when its positive controls are missing
# or the member is ambiguous.
set -uo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# CHECK_WAIT_SCHEDULED overrides the probe under test (used to show this test
# rejects an older, fail-open version of it).
CHECK="${CHECK_WAIT_SCHEDULED:-${PACK_ROOT}/scripts/check_wait_scheduled.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_check_wait_scheduled.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
failures=0

cat > "${WORK}/cb.mm" <<'SRC'
#import <Metal/Metal.h>
struct GrMtlCommandBuffer {
    id<MTLCommandBuffer> fCmdBuffer;
    bool commit(bool waitUntilCompleted);
};
bool GrMtlCommandBuffer::commit(bool waitUntilCompleted) {
    [fCmdBuffer commit];
    if (waitUntilCompleted) {
        [fCmdBuffer waitUntilCompleted];
#if defined(WITH_WAIT)
    } else {
        [fCmdBuffer waitUntilScheduled];
#endif
    }
    return [fCmdBuffer status] != MTLCommandBufferStatusError;
}
SRC
printf 'int unrelated(void) { return 1; }\n' > "${WORK}/empty.c"

cc_ios() { xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -O1 -fobjc-arc -c "$@"; }
# make_lib <name> <object>…: a libSkiaPack.a whose members are named gpu.GrMtlCommandBuffer.o
make_lib() {
    local dir="${WORK}/$1"; shift
    mkdir -p "${dir}/libdir"
    local i=0
    for obj in "$@"; do
        i=$((i + 1)); mkdir -p "${dir}/m${i}"; cp "${obj}" "${dir}/m${i}/gpu.GrMtlCommandBuffer.o"
        (cd "${dir}/m${i}" && ar -q "${dir}/libdir/libSkiaPack.a" gpu.GrMtlCommandBuffer.o 2>/dev/null)
    done
    echo "${dir}/libdir/libSkiaPack.a"
}

cc_ios -x objective-c++ -DWITH_WAIT "${WORK}/cb.mm" -o "${WORK}/on.o" || { echo "ENVIRONMENT: cannot compile the fixture"; exit 2; }
cc_ios -x objective-c++ "${WORK}/cb.mm" -o "${WORK}/off.o" || { echo "ENVIRONMENT: cannot compile the fixture"; exit 2; }
cc_ios "${WORK}/empty.c" -o "${WORK}/empty.o" || { echo "ENVIRONMENT: cannot compile the fixture"; exit 2; }
# The fixture must use selector stubs like the real archives, or the test proves nothing.
nm -u "${WORK}/on.o" | grep -qx '_objc_msgSend$waitUntilScheduled' \
    || { echo "ENVIRONMENT: the fixture compiler did not emit objc_msgSend selector stubs"; exit 2; }

ON="$(make_lib on "${WORK}/on.o")"
OFF="$(make_lib off "${WORK}/off.o")"
EMPTY="$(make_lib empty "${WORK}/empty.o")"
DUP="$(make_lib dup "${WORK}/on.o" "${WORK}/on.o")"

expect() { # expect <name> <want-rc> <lib> <mode>
    local out rc
    out="$("${CHECK}" "$3" "$4" 2>&1)"; rc=$?
    if [[ "${rc}" == "$2" ]]; then echo "ok   $1 (rc=${rc})"
    else echo "FAIL $1: want rc=$2, got rc=${rc}: ${out}"; failures=$((failures + 1)); fi
}
expect "with the call, mode on"                 0 "${ON}" on
expect "with the call, mode off is rejected"    1 "${ON}" off
expect "without the call, mode off"             0 "${OFF}" off
expect "without the call, mode on is rejected"  1 "${OFF}" on
expect "no positive controls: probe error, not off" 3 "${EMPTY}" off
expect "two such members: probe error"          3 "${DUP}" on
expect "not an archive: probe error"            3 /etc/hosts on

# Tool-failure negative controls. A shim directory placed first on PATH makes
# one tool exit 2 — after producing its normal output ("after-output") or with
# no output ("no-output") — either on every call or only on calls whose
# arguments contain <match> (so a single search or subcommand fails while the
# rest of the probe works). Every case must be a probe error (rc 3), in BOTH
# modes and on BOTH archives: a tool error must never pass 'off', and must
# never stand in for the expected rejection of 'on'.
make_shim() { # make_shim <dir> <tool> <after-output|no-output> [match] [real-path]
    local dir="$1" tool="$2" how="$3" match="${4:-}" real="${5:-$(command -v "$2")}"
    mkdir -p "${dir}"
    {
        echo '#!/bin/bash'
        printf 'case "$*" in *%q*) ;; *) exec "%s" "$@" ;; esac\n' "${match}" "${real}"
        [[ "${how}" == after-output ]] && printf '"%s" "$@"\n' "${real}"
        echo 'exit 2'
    } > "${dir}/${tool}"
    chmod +x "${dir}/${tool}"
}
expect_fault() { # expect_fault <label> <shim-dir>
    local lib mode out rc
    for lib in "${ON}" "${OFF}"; do
        for mode in on off; do
            out="$(PATH="$2:${PATH}" "${CHECK}" "${lib}" "${mode}" 2>&1)"; rc=$?
            if [[ "${rc}" == 3 ]] && grep -qF "PROBE ERROR" <<< "${out}"; then
                echo "ok   fault: $1 — $(basename "$(dirname "$(dirname "${lib}")")") lib, mode ${mode} (rc=3)"
            else
                echo "FAIL fault: $1 — ${lib} mode ${mode}: want rc=3 PROBE ERROR, got rc=${rc}: ${out}"
                failures=$((failures + 1))
            fi
        done
    done
}
REAL_OBJDUMP="$(xcrun --find llvm-objdump)"
for how in after-output no-output; do
    for spec in "grep:" "grep:waitUntilScheduled" "grep:commit" "ar:" "ar:-t" "ar:-x" "nm:"; do
        tool="${spec%%:*}"; match="${spec#*:}"; d="${WORK}/shim-${tool}-${how}-${match:-all}"
        make_shim "${d}" "${tool}" "${how}" "${match}"
        if [[ -n "${match}" ]]; then scope="only calls with '${match}'"; else scope="every call"; fi
        expect_fault "${tool} exits 2 (${how}, ${scope})" "${d}"
    done
done
# llvm-objdump is located through xcrun: shim xcrun to hand back a failing objdump.
for how in after-output no-output; do
    make_shim "${WORK}/fake-objdump-${how}" llvm-objdump "${how}" "" "${REAL_OBJDUMP}"
    mkdir -p "${WORK}/shim-xcrun-${how}"
    printf '#!/bin/bash\n[[ "$*" == "--find llvm-objdump" ]] && { echo "%s/llvm-objdump"; exit 0; }\nexec /usr/bin/xcrun "$@"\n' \
        "${WORK}/fake-objdump-${how}" > "${WORK}/shim-xcrun-${how}/xcrun"
    chmod +x "${WORK}/shim-xcrun-${how}/xcrun"
    expect_fault "llvm-objdump exits 2 (${how})" "${WORK}/shim-xcrun-${how}"
done

echo
if (( failures )); then echo "[test_check_wait_scheduled] ${failures} FAILED"; exit 1; fi
echo "[test_check_wait_scheduled] ALL PASSED"
