#!/usr/bin/env bash
# Self-test for scripts/consumer_counts.sh (the counts behind verify_consumer.sh's
# privacy assertions): real zero and real hits are counted; every way the search
# or grep can fail — with no output, with plausible output, or with output
# followed by a failure — is an error (exit 1 with the reason), never a count.
#
#   COUNTS_LIB=<file> test_consumer_counts.sh   run against another implementation
#                                               (used to show the old one fails)
set -uo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${COUNTS_LIB:-${PACK_ROOT}/scripts/consumer_counts.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_consumer_counts.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
PRIVACY_BUNDLE=skia-pack_SkiaPackPrivacy.bundle
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=/dev/null
source "${LIB}"
failures=0

# expect <name> <want-rc> <want-stdout|-> <want-stderr-substring|-> <PATH prefix|-> <cmd…>
# Runs <cmd…> the way verify_consumer.sh does: in a command substitution.
expect() {
    local name="$1" want_rc="$2" want_out="$3" want_err="$4" pre="$5"; shift 5
    local out rc
    [[ "${pre}" == - ]] && pre=""
    out="$(PATH="${pre:+${pre}:}${PATH}" "$@" 2> "${WORK}/stderr")"; rc=$?
    if [[ "${rc}" == "${want_rc}" ]] \
        && { [[ "${want_out}" == - ]] || [[ "${out}" == "${want_out}" ]]; } \
        && { [[ "${want_err}" == - ]] || grep -qF -- "${want_err}" "${WORK}/stderr"; }; then
        echo "ok   ${name} (rc=${rc}, out='${out}')"
    else
        echo "FAIL ${name}: want rc=${want_rc} out='${want_out}' err~'${want_err}', got rc=${rc} out='${out}' err='$(head -1 "${WORK}/stderr")'"
        failures=$((failures + 1))
    fi
}

# Shims: each fault is a directory put first on PATH.
shim() { # shim <dir> <tool> <body>
    mkdir -p "${WORK}/$1"
    printf '#!/bin/bash\n%s\n' "$3" > "${WORK}/$1/$2"
    chmod +x "${WORK}/$1/$2"
    echo "${WORK}/$1"
}
B="${PRIVACY_BUNDLE}"
EMPTY="${WORK}/empty"; mkdir -p "${EMPTY}/a/b"
ONE="${WORK}/one"; mkdir -p "${ONE}/x/${B}/Contents"
TWO="${WORK}/two"; mkdir -p "${TWO}/x/${B}" "${TWO}/y z/${B}"
NL="${WORK}/newline"; mkdir -p "${NL}/$(printf 'a\nb')/${B}"

echo "== count_privacy_bundles"
expect "zero bundles counts 0"                    0 0 - - count_privacy_bundles "${EMPTY}"
expect "one bundle counts 1"                      0 1 - - count_privacy_bundles "${ONE}"
expect "two bundles (one in a path with a space) count 2" 0 2 - - count_privacy_bundles "${TWO}"
expect "a bundle under a newline path counts 1"   0 1 - - count_privacy_bundles "${NL}"
expect "missing root rejected"                    1 "" "searching ${WORK}/nope" - count_privacy_bundles "${WORK}/nope"
F="$(shim find-fails find 'echo "find: simulated failure" >&2; exit 1')"
expect "find fails with no output rejected"       1 "" "find: simulated failure" "${F}" count_privacy_bundles "${ONE}"
F="$(shim find-hits-then-fails find '/usr/bin/find "$@"; echo "find: failed after listing" >&2; exit 1')"
expect "find lists the bundle, then fails: rejected" 1 "" "find: failed after listing" "${F}" count_privacy_bundles "${ONE}"
F="$(shim find-nothing-then-fails find 'echo "find: failed with no hits" >&2; exit 1')"
expect "find lists nothing, then fails: rejected (not 0)" 1 "" "find: failed with no hits" "${F}" count_privacy_bundles "${EMPTY}"
# The review's fault: a grep that prints 0 and exits 2 for `grep -c .`.
G="$(shim grep-c-dot-0-rc2 grep 'if [[ "$*" == "-c ." ]]; then /bin/cat >/dev/null; printf "0\n"; exit 2; fi; exec /usr/bin/grep "$@"')"
expect "review fault (grep -c . prints 0, exits 2) cannot hide a bundle" 0 1 - "${G}" count_privacy_bundles "${ONE}"

echo "== grep_count"
P="${WORK}/Package.swift"
printf 'a\n.target(name: "SkiaPackPrivacy", condition: nil)\nb\n' > "${P}"
expect "match counts 1"                           0 1 - - grep_count 'name: "SkiaPackPrivacy", condition: nil' "${P}"
expect "no match counts 0"                        0 0 - - grep_count 'condition: .when(platforms: \[.iOS\])' "${P}"
expect "missing file rejected"                    1 "" "grep -c" - grep_count x "${WORK}/nope.swift"
G="$(shim grep-0-rc2 grep 'printf "0\n"; exit 2')"
expect "grep prints 0, exits 2: rejected"         1 "" "exit 2, output '0'" "${G}" grep_count x "${P}"
G="$(shim grep-1-rc2 grep 'printf "1\n"; exit 2')"
expect "grep prints a normal count, exits 2: rejected" 1 "" "exit 2, output '1'" "${G}" grep_count x "${P}"
G="$(shim grep-none-rc2 grep 'exit 2')"
expect "grep prints nothing, exits 2: rejected"   1 "" "exit 2, output ''" "${G}" grep_count x "${P}"
G="$(shim grep-0-rc0 grep 'printf "0\n"; exit 0')"
expect "grep prints 0 but exits 0: rejected"      1 "" "exit 0, output '0'" "${G}" grep_count x "${P}"
G="$(shim grep-1-rc1 grep 'printf "1\n"; exit 1')"
expect "grep prints 1 but exits 1: rejected"      1 "" "exit 1, output '1'" "${G}" grep_count x "${P}"
G="$(shim grep-junk-rc0 grep 'printf "1x\n"; exit 0')"
expect "grep prints a non-number, exits 0: rejected" 1 "" "output '1x'" "${G}" grep_count x "${P}"

echo
if (( failures )); then echo "test_consumer_counts: ${failures} FAILED"; exit 1; fi
echo "test_consumer_counts: all passed"
