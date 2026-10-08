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
# Exit: 0 the slice matches <on|off>; 1 it does not; 3 probe/environment error.
set -uo pipefail

LIB="${1:-}"; MODE="${2:-}"
[[ -n "${LIB}" && ( "${MODE}" == on || "${MODE}" == off ) && $# -eq 2 ]] \
    || { echo "usage: check_wait_scheduled.sh <libSkiaPack.a> <on|off>" >&2; exit 3; }
[[ -f "${LIB}" ]] || { echo "check_wait_scheduled: no such archive: ${LIB}" >&2; exit 3; }
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null)" || { echo "check_wait_scheduled: llvm-objdump not found" >&2; exit 3; }

MEMBER="gpu.GrMtlCommandBuffer.o"
SYM='__ZN18GrMtlCommandBuffer6commitEb'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check_wait_scheduled.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
probe() { echo "check_wait_scheduled: PROBE ERROR ($(basename "$(dirname "${LIB}")")): $*" >&2; exit 3; }

n="$(ar -t "${LIB}" 2>/dev/null | grep -cx "${MEMBER}")" || true
[[ "${n}" == "1" ]] || probe "expected exactly one ${MEMBER} in ${LIB}, found ${n:-0}"
(cd "${WORK}" && ar -x "${LIB}" "${MEMBER}") || probe "ar could not extract ${MEMBER}"

undef="$(nm -u "${WORK}/${MEMBER}")" || probe "nm failed"
for control in commit waitUntilCompleted; do
    grep -qx "_objc_msgSend\$${control}" <<< "${undef}" || probe "positive control _objc_msgSend\$${control} not referenced"
done
"${OBJDUMP}" -d -r --no-show-raw-insn --disassemble-symbols="${SYM}" "${WORK}/${MEMBER}" > "${WORK}/commit.s" 2>&1 \
    || probe "llvm-objdump failed"
grep -q "<${SYM}>:" "${WORK}/commit.s" || probe "symbol ${SYM} not found"
grep -q 'objc_msgSend\$commit' "${WORK}/commit.s" || probe "positive control: commit(bool) does not call the commit stub"

grep -qx '_objc_msgSend$waitUntilScheduled' <<< "${undef}" && referenced=1 || referenced=0
grep -q 'objc_msgSend\$waitUntilScheduled' "${WORK}/commit.s" && called=1 || called=0

want=0; [[ "${MODE}" == on ]] && want=1
if [[ "${referenced}" == "${want}" && "${called}" == "${want}" ]]; then
    echo "check_wait_scheduled: $(basename "$(dirname "${LIB}")") is '${MODE}' (waitUntilScheduled referenced=${referenced}, called from commit(bool)=${called}; positive controls present)"
    exit 0
fi
echo "check_wait_scheduled: $(basename "$(dirname "${LIB}")") is NOT '${MODE}' (waitUntilScheduled referenced=${referenced}, called from commit(bool)=${called})" >&2
exit 1
