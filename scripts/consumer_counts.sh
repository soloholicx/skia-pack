# shellcheck shell=bash
# Counting helpers for verify_consumer.sh (sourced; the caller defines fail,
# WORK and PRIVACY_BUNDLE). A count is only ever produced by a step whose exit
# status was checked: a failed search or grep fails the gate — never "0".

# count_privacy_bundles <root>: how many privacy bundles lie under <root>. The
# NUL-separated list goes to a file and is counted by bash itself, so no second
# tool can fail between the search and the number. A failed find (including a
# missing <root>, or one that printed hits before failing) fails the gate.
count_privacy_bundles() {
    local list="${WORK}/find-privacy.lst" n=0 _
    find "$1" -name "${PRIVACY_BUNDLE}" -type d -prune -print0 > "${list}" 2> "${WORK}/find-privacy.err" \
        || fail "searching $1 for ${PRIVACY_BUNDLE} failed: $(head -1 "${WORK}/find-privacy.err")"
    { while IFS= read -r -d '' _; do n=$((n + 1)); done < "${list}"; } \
        || fail "reading the search results ${list} failed"
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
