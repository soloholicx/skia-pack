#!/usr/bin/env bash
# Zip hygiene gate for the SwiftPM artifact (SkiaPack.xcframework.zip).
#
#   check_zip.sh <zip> [<reference-dir>]
#
# SwiftPM extracts a binaryTarget zip with plain unzip, so every entry in the
# zip lands in the consumer's tree as-is. Checks:
#   1. no AppleDouble entry (a path component starting with "._") and no
#      __MACOSX/ directory in the zip listing
#   2. the tree that plain `unzip` produces (what SwiftPM sees) is identical to
#      the tree `ditto -x -k` produces (which folds AppleDouble data back into
#      metadata): same files, directories and symlinks, same bytes, same link
#      targets
#   3. with <reference-dir> (the directory that was zipped, e.g. the staged
#      SkiaPack.xcframework): the unzip tree has exactly the reference's
#      files, directories and symlinks, with the same bytes and link targets
#
# Fail closed: every tool's exit status is checked; a hash is validated before
# it is written; searches are three-state (found / absent / error). A tool
# error is exit 2 — never a pass, never a "content matches".
#
# Exit: 0 clean; 1 a check failed; 2 usage, environment or tool error.
set -uo pipefail

ZIP="${1:-}"
REF="${2:-}"
die()  { echo "check_zip ERROR: $*" >&2; exit 2; }
fail() { echo "check_zip FAIL: $*" >&2; exit 1; }
[[ -n "${ZIP}" && $# -le 2 ]] || { echo "usage: check_zip.sh <zip> [<reference-dir>]" >&2; exit 2; }
[[ -f "${ZIP}" ]] || die "no such zip: ${ZIP}"
[[ -z "${REF}" || -d "${REF}" ]] || die "no such reference dir: ${REF}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check_zip.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "${WORK}"' EXIT

# search <out-file> <grep args…> <file>: prints found|absent; a grep error dies.
search() {
    local out="$1"; shift
    grep "$@" > "${out}"
    case $? in
        0) echo found ;;
        1) echo absent ;;
        *) return 1 ;;
    esac
}
lines() { local n; n="$(wc -l < "$1")" || die "wc failed on $1"; echo $(( n )); }

# ---- 1. listing --------------------------------------------------------------
zipinfo -1 "${ZIP}" > "${WORK}/listing" 2> "${WORK}/zipinfo.err" || die "zipinfo failed: $(head -1 "${WORK}/zipinfo.err")"
[[ -s "${WORK}/listing" ]] || fail "zip is empty"
ad="$(search "${WORK}/appledouble" -E '(^|/)\._' -- "${WORK}/listing")" || die "grep failed searching for AppleDouble entries"
mx="$(search "${WORK}/macosx" -E '(^|/)__MACOSX/' -- "${WORK}/listing")" || die "grep failed searching for __MACOSX entries"
if [[ "${ad}" == found || "${mx}" == found ]]; then
    n_ad=0; n_mx=0
    [[ "${ad}" == found ]] && { n_ad="$(lines "${WORK}/appledouble")" || die "count failed"; }
    [[ "${mx}" == found ]] && { n_mx="$(lines "${WORK}/macosx")" || die "count failed"; }
    fail "zip carries ${n_ad} AppleDouble (._*) and ${n_mx} __MACOSX/ entries, e.g. $(cat "${WORK}/appledouble" "${WORK}/macosx" | head -1)"
fi

# ---- 2. what SwiftPM sees == what ditto sees -----------------------------------
mkdir -p "${WORK}/unzip" "${WORK}/ditto" || die "mkdir failed"
unzip -q "${ZIP}" -d "${WORK}/unzip" 2> "${WORK}/unzip.err" || die "unzip failed: $(head -1 "${WORK}/unzip.err")"
ditto -x -k "${ZIP}" "${WORK}/ditto" 2> "${WORK}/ditto.err" || die "ditto -x -k failed: $(head -1 "${WORK}/ditto.err")"

# tree_manifest <dir> <out>: one line per entry — type, path relative to <dir>,
# and content hash (file) or link target (symlink). Never follows symlinks.
# Runs in the current shell (not a pipeline or subshell), so die exits.
tree_manifest() {
    local dir="$1" out="$2" p rel h t entries=0 written
    find "${dir}" -mindepth 1 -print0 > "${out}.find" 2> "${out}.find.err" || die "find failed in ${dir}: $(head -1 "${out}.find.err")"
    LC_ALL=C sort -z "${out}.find" > "${out}.sorted" || die "sort failed"
    : > "${out}" || die "cannot write ${out}"
    while IFS= read -r -d '' p; do
        rel="${p#"${dir}"/}"
        if [[ -L "${p}" ]]; then
            t="$(readlink "${p}")" || die "readlink failed on ${rel}"
            [[ -n "${t}" ]] || die "readlink returned nothing for ${rel}"
            printf 'l %s -> %s\n' "${rel}" "${t}" >> "${out}" || die "write failed"
        elif [[ -d "${p}" ]]; then
            printf 'd %s\n' "${rel}" >> "${out}" || die "write failed"
        elif [[ -f "${p}" ]]; then
            h="$(shasum -a 256 "${p}")" || die "shasum failed on ${rel}"
            h="${h%% *}"
            [[ "${h}" =~ ^[0-9a-f]{64}$ ]] || die "shasum gave a malformed digest for ${rel}: '${h}'"
            printf 'f %s %s\n' "${rel}" "${h}" >> "${out}" || die "write failed"
        else
            die "entry is neither file, directory nor symlink: ${rel}"
        fi
        entries=$(( entries + 1 ))
    done < "${out}.sorted"
    written="$(lines "${out}")" || die "count failed"
    [[ "${written}" == "${entries}" ]] || die "manifest of ${dir} is incomplete"
}
compare() { # compare <a> <b> <what>: 0 same; fail on difference; die on diff error
    diff -u "$1" "$2" > "${WORK}/compare.diff"
    case $? in
        0) ;;
        1) head -20 "${WORK}/compare.diff" >&2; fail "$3" ;;
        *) die "diff failed comparing manifests" ;;
    esac
}

tree_manifest "${WORK}/unzip" "${WORK}/unzip.manifest"
tree_manifest "${WORK}/ditto" "${WORK}/ditto.manifest"
compare "${WORK}/ditto.manifest" "${WORK}/unzip.manifest" "the tree plain unzip produces (what SwiftPM sees) differs from ditto's"

# ---- 3. against the reference --------------------------------------------------
entries="$(lines "${WORK}/unzip.manifest")" || die "count failed"
(( entries > 0 )) || fail "zip extracted to nothing"
links_state="$(search "${WORK}/links" '^l ' -- "${WORK}/unzip.manifest")" || die "grep failed counting symlinks"
links=0; [[ "${links_state}" == found ]] && { links="$(lines "${WORK}/links")" || die "count failed"; }
if [[ -n "${REF}" ]]; then
    # The zip may wrap the reference in its parent directory name (--keepParent).
    top="${WORK}/unzip/$(basename "${REF}")"
    [[ -d "${top}" ]] || top="${WORK}/unzip"
    tree_manifest "${REF}" "${WORK}/ref.manifest"
    tree_manifest "${top}" "${WORK}/top.manifest"
    compare "${WORK}/ref.manifest" "${WORK}/top.manifest" "the unzipped tree differs from the reference ${REF}"
    echo "check_zip PASS: ${ZIP} — no AppleDouble/__MACOSX entries; unzip tree == ditto tree == reference (${entries} entries, ${links} symlinks)"
else
    echo "check_zip PASS: ${ZIP} — no AppleDouble/__MACOSX entries; unzip tree == ditto tree (${entries} entries, ${links} symlinks)"
fi
