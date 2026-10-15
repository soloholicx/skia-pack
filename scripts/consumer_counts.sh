# shellcheck shell=bash
# Counting helpers for verify_consumer.sh (sourced; the caller defines fail,
# WORK and PRIVACY_BUNDLE). A count is only ever produced by a step whose exit
# status was checked: a failed search, read or grep fails the gate — never "0".
# These helpers run inside command substitutions, where set -e is not inherited,
# so every failure exits explicitly.

# nul_records <list> count|one: parse a `find -print0` list strictly (Python:
# a read error is an exception, not an early EOF). The list must be empty or a
# run of complete, non-empty, NUL-terminated records; anything else — an
# unreadable list, an incomplete trailing record, an empty record — fails.
#   count  prints the number of records
#   one    requires exactly one record and prints it (any bytes but NUL)
nul_records() {
    local out rc=0
    out="$(python3 - "$1" "$2" 2> "${WORK}/nul-records.err" <<'PY'
import sys
path, mode = sys.argv[1], sys.argv[2]
try:
    with open(path, "rb") as f:
        data = f.read()
except OSError as e:
    sys.exit(f"cannot read {path}: {e}")
if data and not data.endswith(b"\0"):
    sys.exit(f"{path}: incomplete trailing record (no final NUL)")
records = data.split(b"\0")[:-1]
if any(not r for r in records):
    sys.exit(f"{path}: empty record")
if mode == "count":
    print(len(records))
elif mode == "one" and len(records) == 1:
    sys.stdout.buffer.write(records[0] + b"/")   # "/" keeps trailing newlines through $(...)
else:
    sys.exit(f"{path}: mode {mode} with {len(records)} records")
PY
)" || rc=$?
    (( rc == 0 )) || fail "parsing the search results ${1} failed (exit ${rc}): $(head -1 "${WORK}/nul-records.err")"
    case "$2" in
        count) [[ "${out}" =~ ^[0-9]+$ ]] || fail "parsing ${1} printed '${out}', not a count" ;;
        one)   [[ "${out}" == */ ]] || fail "parsing ${1} printed '${out}' without its end marker"
               out="${out%/}" ;;
    esac
    printf '%s\n' "${out}"
}

# count_privacy_bundles <root>: how many privacy bundles lie under <root>. A
# failed find (including a missing <root>, or one that listed hits before
# failing) or a failed read of its list fails the gate.
count_privacy_bundles() {
    local list="${WORK}/find-privacy.lst" n
    find "$1" -name "${PRIVACY_BUNDLE}" -type d -prune -print0 > "${list}" 2> "${WORK}/find-privacy.err" \
        || fail "searching $1 for ${PRIVACY_BUNDLE} failed: $(head -1 "${WORK}/find-privacy.err")"
    n="$(nul_records "${list}" count)" || exit 1
    echo "${n}"
}

# grep_count <basic regex> <file>: how many lines of <file> match. grep -c
# exits 0 with a positive count or 1 with "0"; anything else — exit 2 or more,
# or output that disagrees with the exit status — fails the gate, whatever it
# printed.
grep_count() {
    local out rc=0
    out="$(grep -c -- "$1" "$2")" || rc=$?
    case "${rc}:${out}" in
        0:[1-9]*|1:0) [[ "${out}" =~ ^[0-9]+$ ]] && { echo "${out}"; return 0; } ;;
    esac
    fail "grep -c '$1' $2 failed: exit ${rc}, output '${out}'"
}
