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
# Exit: 0 clean; 1 a check failed; 2 usage or environment error.
set -euo pipefail

ZIP="${1:-}"
REF="${2:-}"
[[ -n "${ZIP}" && $# -le 2 ]] || { echo "usage: check_zip.sh <zip> [<reference-dir>]" >&2; exit 2; }
[[ -f "${ZIP}" ]] || { echo "check_zip: no such zip: ${ZIP}" >&2; exit 2; }
[[ -z "${REF}" || -d "${REF}" ]] || { echo "check_zip: no such reference dir: ${REF}" >&2; exit 2; }

fail() { echo "check_zip FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check_zip.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# ---- 1. listing --------------------------------------------------------------
listing="$(zipinfo -1 "${ZIP}")" || { echo "check_zip: zipinfo could not read ${ZIP}" >&2; exit 2; }
[[ -n "${listing}" ]] || fail "zip is empty"
appledouble="$(printf '%s\n' "${listing}" | grep -E '(^|/)\._' || true)"
macosx="$(printf '%s\n' "${listing}" | grep -E '(^|/)__MACOSX/' || true)"
if [[ -n "${appledouble}" || -n "${macosx}" ]]; then
    n_ad="$(printf '%s' "${appledouble}" | grep -c . || true)"
    n_mx="$(printf '%s' "${macosx}" | grep -c . || true)"
    fail "zip carries ${n_ad} AppleDouble (._*) and ${n_mx} __MACOSX/ entries, e.g. $(printf '%s\n' "${appledouble}${macosx}" | head -1)"
fi

# ---- 2. what SwiftPM sees == what ditto sees -----------------------------------
mkdir -p "${WORK}/unzip" "${WORK}/ditto"
unzip -q "${ZIP}" -d "${WORK}/unzip" || { echo "check_zip: unzip failed on ${ZIP}" >&2; exit 2; }
ditto -x -k "${ZIP}" "${WORK}/ditto" || { echo "check_zip: ditto -x -k failed on ${ZIP}" >&2; exit 2; }

# tree_manifest <dir>: one line per entry — type, path, and content hash (file)
# or link target (symlink). Never follows symlinks.
tree_manifest() {
    (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
        if [[ -L "${p}" ]]; then printf 'l %s -> %s\n' "${p}" "$(readlink "${p}")"
        elif [[ -d "${p}" ]]; then printf 'd %s\n' "${p}"
        elif [[ -f "${p}" ]]; then printf 'f %s %s\n' "${p}" "$(shasum -a 256 "${p}" | awk '{print $1}')"
        else printf '? %s\n' "${p}"
        fi
    done)
}
tree_manifest "${WORK}/unzip" > "${WORK}/unzip.manifest"
tree_manifest "${WORK}/ditto" > "${WORK}/ditto.manifest"
grep -q '^? ' "${WORK}/unzip.manifest" && fail "unzip tree has entries that are neither file, directory nor symlink"
if ! diff -u "${WORK}/ditto.manifest" "${WORK}/unzip.manifest" > "${WORK}/ud.diff"; then
    head -20 "${WORK}/ud.diff" >&2
    fail "the tree plain unzip produces (what SwiftPM sees) differs from ditto's"
fi

# ---- 3. against the reference --------------------------------------------------
entries="$(grep -c . "${WORK}/unzip.manifest")"
links="$(grep -c '^l ' "${WORK}/unzip.manifest" || true)"
if [[ -n "${REF}" ]]; then
    # The zip may wrap the reference in its parent directory name (--keepParent).
    top="${WORK}/unzip/$(basename "${REF}")"
    [[ -d "${top}" ]] || top="${WORK}/unzip"
    tree_manifest "${REF}" > "${WORK}/ref.manifest"
    tree_manifest "${top}" > "${WORK}/top.manifest"
    if ! diff -u "${WORK}/ref.manifest" "${WORK}/top.manifest" > "${WORK}/ref.diff"; then
        head -20 "${WORK}/ref.diff" >&2
        fail "the unzipped tree differs from the reference ${REF}"
    fi
    echo "check_zip PASS: ${ZIP} — no AppleDouble/__MACOSX entries; unzip tree == ditto tree == reference (${entries} entries, ${links} symlinks)"
else
    echo "check_zip PASS: ${ZIP} — no AppleDouble/__MACOSX entries; unzip tree == ditto tree (${entries} entries, ${links} symlinks)"
fi
