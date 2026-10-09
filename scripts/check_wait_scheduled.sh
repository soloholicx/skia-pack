#!/usr/bin/env bash
# Is SK_METAL_WAIT_UNTIL_SCHEDULED compiled into a slice's Ganesh Metal
# command buffer? Reads the object, never the GN args.
#
#   check_wait_scheduled.sh <libSkiaPack.a> <on|off>
#
# From the archive's gpu.GrMtlCommandBuffer.o (exactly one such member):
#   1. nm -u: _objc_msgSend$waitUntilScheduled is referenced iff <on>
#   2. disassembly of GrMtlCommandBuffer::commit(bool): it calls the
#      waitUntilScheduled selector stub iff <on>
# Positive controls (a probe that cannot see these is broken, not "off"):
# nm -u must list $commit and $waitUntilCompleted; commit(bool) must call
# the commit stub.
#
# Fail closed: every tool's exit status is checked separately from its output,
# and every search is three-state — found (0), absent (1), error (anything
# else). A tool or search error is a PROBE ERROR (exit 3); it never counts as
# "absent", so it can neither pass 'off' nor stand in for an expected
# rejection of 'on'.
#
# Exit: 0 the slice matches <on|off>; 1 it does not; 3 probe/environment error.
set -uo pipefail

LIB="${1:-}"; MODE="${2:-}"
[[ -n "${LIB}" && ( "${MODE}" == on || "${MODE}" == off ) && $# -eq 2 ]] \
    || { echo "usage: check_wait_scheduled.sh <libSkiaPack.a> <on|off>" >&2; exit 3; }
SLICE="$(basename "$(dirname "${LIB}")")"
probe() { echo "check_wait_scheduled: PROBE ERROR (${SLICE}): $*" >&2; exit 3; }
[[ -f "${LIB}" ]] || probe "no such archive: ${LIB}"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null)" && [[ -x "${OBJDUMP}" ]] || probe "llvm-objdump not found"

MEMBER="gpu.GrMtlCommandBuffer.o"
SYM='__ZN18GrMtlCommandBuffer6commitEb'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check_wait_scheduled.XXXXXX")" || probe "mktemp failed"
trap 'rm -rf "${WORK}"' EXIT

# search <file> <grep args…>: prints found|absent; any other grep status is a probe error.
search() {
    local file="$1"; shift
    grep -q "$@" -- "${file}"
    case $? in
        0) echo found ;;
        1) echo absent ;;
        *) return 1 ;;
    esac
}

ar -t "${LIB}" > "${WORK}/members" 2> "${WORK}/ar-t.err" || probe "ar -t failed: $(head -1 "${WORK}/ar-t.err")"
grep -cx -- "${MEMBER}" "${WORK}/members" > "${WORK}/count"; rc=$?
[[ "${rc}" == 0 || "${rc}" == 1 ]] || probe "grep failed counting ${MEMBER} (rc=${rc})"
n="$(< "${WORK}/count")"
[[ "${n}" == "1" ]] || probe "expected exactly one ${MEMBER} in ${LIB}, found ${n:-?}"
(cd "${WORK}" && ar -x "${LIB}" "${MEMBER}") 2> "${WORK}/ar-x.err" || probe "ar -x failed: $(head -1 "${WORK}/ar-x.err")"
[[ -s "${WORK}/${MEMBER}" ]] || probe "ar -x produced no ${MEMBER}"

nm -u "${WORK}/${MEMBER}" > "${WORK}/undef" 2> "${WORK}/nm.err" || probe "nm failed: $(head -1 "${WORK}/nm.err")"
"${OBJDUMP}" -d -r --no-show-raw-insn --disassemble-symbols="${SYM}" "${WORK}/${MEMBER}" > "${WORK}/commit.s" 2> "${WORK}/objdump.err" \
    || probe "llvm-objdump failed: $(head -1 "${WORK}/objdump.err")"

for control in commit waitUntilCompleted; do
    r="$(search "${WORK}/undef" -x "_objc_msgSend\$${control}")" || probe "grep failed (positive control \$${control})"
    [[ "${r}" == found ]] || probe "positive control _objc_msgSend\$${control} not referenced"
done
r="$(search "${WORK}/commit.s" -F "<${SYM}>:")" || probe "grep failed (commit symbol)"
[[ "${r}" == found ]] || probe "symbol ${SYM} not found"
r="$(search "${WORK}/commit.s" -F 'objc_msgSend$commit')" || probe "grep failed (commit stub call)"
[[ "${r}" == found ]] || probe "positive control: commit(bool) does not call the commit stub"

referenced="$(search "${WORK}/undef" -x '_objc_msgSend$waitUntilScheduled')" || probe "grep failed (waitUntilScheduled reference)"
called="$(search "${WORK}/commit.s" -F 'objc_msgSend$waitUntilScheduled')" || probe "grep failed (waitUntilScheduled call)"

want=absent; [[ "${MODE}" == on ]] && want=found
if [[ "${referenced}" == "${want}" && "${called}" == "${want}" ]]; then
    echo "check_wait_scheduled: ${SLICE} is '${MODE}' (waitUntilScheduled referenced: ${referenced}, called from commit(bool): ${called}; positive controls present)"
    exit 0
fi
echo "check_wait_scheduled: ${SLICE} is NOT '${MODE}' (waitUntilScheduled referenced: ${referenced}, called from commit(bool): ${called})" >&2
exit 1
