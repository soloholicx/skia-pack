#!/usr/bin/env bash
# Self-test for scripts/consumer_counts.sh and verify_consumer.sh's
# check_spm_extracted (the counts behind its privacy and extraction assertions):
# real zero and real hits are counted; every way the search, the read of its
# list, the list parser or grep can fail — with no output, with plausible
# output, or with output followed by a failure — is an error (exit 1 with the
# reason), never a count.
#
#   COUNTS_LIB=<file> VERIFY_CONSUMER=<file> test_consumer_counts.sh
#       run against another implementation (used to show the old one fails);
#       check_spm_extracted is taken from VERIFY_CONSUMER by its text
set -uo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${COUNTS_LIB:-${PACK_ROOT}/scripts/consumer_counts.sh}"
VC="${VERIFY_CONSUMER:-${PACK_ROOT}/scripts/verify_consumer.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_consumer_counts.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
PRIVACY_BUNDLE=skia-pack_SkiaPackPrivacy.bundle
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=/dev/null
source "${LIB}"
eval "$(sed -n '/^check_spm_extracted()/,/^}/p' "${VC}")"
declare -F check_spm_extracted > /dev/null || { echo "ENVIRONMENT: no check_spm_extracted in ${VC}"; exit 2; }
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
# Read errors of the list find wrote. The list is swapped only after a real,
# successful find, so the failure is the read's alone.
with_list_swapped() { # with_list_swapped <list> <how: dir|unreadable> <cmd…>
    local lst="$1" how="$2"; shift 2
    find() {
        command find "$@" || return
        [[ -f "${lst}" ]] || return 0
        case "${how}" in
            dir) mv "${lst}" "${lst}.saved" && mkdir "${lst}" ;;
            unreadable) chmod 000 "${lst}" ;;
        esac
    }
    "$@"
}
# restore_list <list>: undo a swap, so the next case starts from no list at all.
restore_list() { chmod 644 "$1" 2> /dev/null; rm -rf "$1" "$1.saved"; }
expect "list is a directory (real read error): rejected" 1 "" "Is a directory" - \
    with_list_swapped "${WORK}/find-privacy.lst" dir count_privacy_bundles "${ONE}"
restore_list "${WORK}/find-privacy.lst"
expect "list is unreadable (real read error): rejected" 1 "" "Permission denied" - \
    with_list_swapped "${WORK}/find-privacy.lst" unreadable count_privacy_bundles "${ONE}"
restore_list "${WORK}/find-privacy.lst"
with_read_failing() { read() { echo "read: injected I/O error (status 2)" >&2; return 2; }; "$@"; }
expect "review fault (read builtin returns 2) cannot hide a bundle" 0 1 - - with_read_failing count_privacy_bundles "${ONE}"
F="$(shim find-incomplete find 'printf "%s\0%s" "$1/x/'"${B}"'" "$1/y/partial"')"
expect "list ends in an incomplete record: rejected" 1 "" "incomplete trailing record" "${F}" count_privacy_bundles "${ONE}"
F="$(shim find-empty-record find 'printf "\0"')"
expect "list holds an empty record: rejected" 1 "" "empty record" "${F}" count_privacy_bundles "${ONE}"
P="$(shim parser-fails-first python3 '/bin/cat > /dev/null; echo "python3: failed before any output" >&2; exit 2')"
expect "parser fails before the first record: rejected" 1 "" "failed before any output" "${P}" count_privacy_bundles "${ONE}"
P="$(shim parser-0-then-fails python3 '/bin/cat > /dev/null; echo 0; echo "python3: failed part-way" >&2; exit 2')"
expect "parser prints 0, then fails: rejected" 1 "" "failed part-way" "${P}" count_privacy_bundles "${ONE}"
P="$(shim parser-1-then-fails python3 '/bin/cat > /dev/null; echo 1; echo "python3: failed part-way" >&2; exit 2')"
expect "parser prints 1, then fails: rejected" 1 "" "failed part-way" "${P}" count_privacy_bundles "${ONE}"
P="$(shim parser-junk python3 '/bin/cat > /dev/null; echo "1 2"; exit 0')"
expect "parser prints a non-count, exits 0: rejected" 1 "" "not a count" "${P}" count_privacy_bundles "${ONE}"

echo "== check_spm_extracted"
MODE=local   # read by check_spm_extracted
export MODE
XCF="${WORK}/ref/SkiaPack.xcframework"; mkdir -p "${XCF}/ios-arm64"; printf 'lib\n' > "${XCF}/ios-arm64/libSkiaPack.a"
xroot() { # xroot <name> <relative dir of each xcframework…>: a search root with copies of XCF
    local r="${WORK}/x-$1" d; shift
    mkdir -p "${r}"
    for d in "$@"; do mkdir -p "${r}/${d}"; cp -R "${XCF}" "${r}/${d}/"; done
    echo "${r}"
}
X1="$(xroot one a)"; X0="$(xroot zero)"; X2="$(xroot two a b)"; XNL="$(xroot newline "$(printf 'n\nl')")"
L="${WORK}/t-xcframework.lst"
OKMSG="consumer t: SwiftPM extracted the zip — no ._* files, identical to the verified tree"
expect "one identical xcframework passes"          0 "${OKMSG}" - - check_spm_extracted t "${X1}"
expect "one under a newline path passes"           0 "${OKMSG}" - - check_spm_extracted t "${XNL}"
expect "none rejected"                             1 "" "found 0" - check_spm_extracted t "${X0}"
expect "two rejected"                              1 "" "found 2" - check_spm_extracted t "${X2}"
F="$(shim xfind-fails find 'echo "find: simulated failure" >&2; exit 1')"
expect "find fails: rejected with its reason"      1 "" "find: simulated failure" "${F}" check_spm_extracted t "${X1}"
F="$(shim xfind-hits-then-fails find '/usr/bin/find "$@"; echo "find: failed after listing" >&2; exit 1')"
expect "find lists it, then fails: rejected with its reason" 1 "" "find: failed after listing" "${F}" check_spm_extracted t "${X1}"
expect "list is a directory (real read error): rejected" 1 "" "Is a directory" - \
    with_list_swapped "${L}" dir check_spm_extracted t "${X1}"
restore_list "${L}"
P="$(shim xparser-1-then-fails python3 '/bin/cat > /dev/null; echo 1; echo "python3: failed part-way" >&2; exit 2')"
expect "parser prints 1, then fails: rejected"     1 "" "failed part-way" "${P}" check_spm_extracted t "${X1}"
F="$(shim xfind-incomplete find 'case "$*" in *SkiaPack.xcframework*) printf "%s\0%s" "$1/a/SkiaPack.xcframework" "$1/b/Skia";; *) exec /usr/bin/find "$@";; esac')"
expect "list ends in an incomplete record: rejected" 1 "" "incomplete trailing record" "${F}" check_spm_extracted t "${X1}"
# The review's fault: grep prints 1 and exits 2. Passing is right only if no
# failed grep was consulted; the shim records each failure it reports.
G="$(shim xgrep-1-rc2 grep 'if [[ "$*" == "-c ." ]]; then /bin/cat > /dev/null; echo used >> "'"${WORK}"'/xgrep-failed"; printf "1\n"; exit 2; fi; exec /usr/bin/grep "$@"')"
xgrep_case() {
    local rc=0
    rm -f "${WORK}/xgrep-failed"
    check_spm_extracted t "${X1}" || rc=$?
    if [[ -e "${WORK}/xgrep-failed" ]]; then echo "a failed grep (exit 2) was consulted and the check returned ${rc}" >&2; return 3; fi
    return "${rc}"
}
expect "review fault (grep -c . prints 1, exits 2) is not consulted" 0 "${OKMSG}" - "${G}" xgrep_case

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
