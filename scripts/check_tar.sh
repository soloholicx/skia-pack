#!/usr/bin/env bash
# Tar hygiene gate: reads the FINAL .tar.gz member by member — what any
# consumer's tar sees — not the directory it was made from.
#
#   check_tar.sh <tar.gz> <root> [--reference <dir>] [--tree-sha256 <hex>] [--extract-to <dir>]
#
#   (t1) no AppleDouble member (basename "._*") and no "__MACOSX" component.
#        macOS bsdtar writes one per file that carries an extended attribute
#        and folds it back in when it extracts, so on a Mac they are invisible;
#        GNU tar extracts them as ordinary files.
#   (t2) no member carries host metadata in its pax header (xattr / ACL /
#        file flags: LIBARCHIVE.* / SCHILY.* keys), and no global pax header does
#   (t3) every member is <root> or under <root>/; only directories and regular
#        files (no links, devices, FIFOs, sparse files); no absolute path, no
#        "." / ".." / empty component, no backslash; no path twice; no path
#        that is a file and also a directory or a parent; no two paths that one
#        case-insensitive, normalization-insensitive file system (APFS) would
#        fold into one
#   (t4) only after (t1)–(t3) pass: the archive is extracted by THIS script —
#        directories and regular files only, written one at a time with
#        exclusive create, no macOS metadata merging, nothing else honoured —
#        into an empty directory, and the extracted <root> is hashed with
#        scripts/headers.sh headers_tree_sha256. --reference <dir>: must equal
#        that directory's hash. --tree-sha256 <hex>: must equal that value.
#        This is a local extraction that does NOT merge AppleDouble; it is not
#        GNU tar, and the Linux job of the release workflow stays a separate gate.
#
# A rejected archive is never extracted. Exit 0 PASS, 1 FAIL, 2 usage/tool error.
# Only reads <tar.gz>; writes only into --extract-to (must not exist, or be
# empty) or a temporary directory it removes.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo "usage: check_tar.sh <tar.gz> <root> [--reference <dir>] [--tree-sha256 <hex>] [--extract-to <dir>]" >&2; exit 2; }
die()  { echo "check_tar ERROR: $*" >&2; exit 2; }
fail() { echo "check_tar FAIL: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || usage
TARBALL="$1"; ROOT="$2"; shift 2
REFERENCE=""; WANT_TREE=""; EXTRACT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reference)   [[ $# -ge 2 ]] || usage; REFERENCE="$2"; shift 2 ;;
        --tree-sha256) [[ $# -ge 2 ]] || usage; WANT_TREE="$2"; shift 2 ;;
        --extract-to)  [[ $# -ge 2 ]] || usage; EXTRACT="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -f "${TARBALL}" ]] || die "no such archive: ${TARBALL}"
[[ -n "${ROOT}" && "${ROOT}" != */* && "${ROOT}" != "." && "${ROOT}" != ".." ]] || die "root must be one path component: '${ROOT}'"
[[ -z "${REFERENCE}" || -d "${REFERENCE}" ]] || die "reference is not a directory: ${REFERENCE}"
[[ -z "${WANT_TREE}" || "${WANT_TREE}" =~ ^[0-9a-f]{64}$ ]] || die "--tree-sha256 must be 64 lowercase hex digits"

CLEANUP=""
if [[ -z "${EXTRACT}" ]]; then
    EXTRACT="$(mktemp -d "${TMPDIR:-/tmp}/check_tar.XXXXXX")" || die "mktemp failed"
    CLEANUP="${EXTRACT}"
elif [[ -e "${EXTRACT}" ]]; then
    [[ -d "${EXTRACT}" && -z "$(ls -A "${EXTRACT}")" ]] || die "--extract-to must not exist or be empty: ${EXTRACT}"
else
    mkdir -p "${EXTRACT}" || die "cannot create ${EXTRACT}"
fi
trap '[[ -n "${CLEANUP}" ]] && rm -rf "${CLEANUP}"' EXIT

# (t1)–(t3), then (t4)'s extraction. Python 3.9 compatible (the Mac's
# /usr/bin/python3); tarfile's extraction filters are NOT used, and
# extractall()/extract() are never called.
set +e
stats="$(python3 - "${TARBALL}" "${ROOT}" "${EXTRACT}" <<'PY'
import os, sys, tarfile, unicodedata
tar_path, root, dest = sys.argv[1:4]
problems = {}
def note(kind, name):
    problems.setdefault(kind, []).append(name)
META = ("xattr", "acl", "fflags")
def is_meta(key):
    k = key.lower()
    return k.startswith("libarchive.") or k.startswith("schily.") or any(m in k for m in META)
try:
    tf = tarfile.open(tar_path, mode="r:gz")
    members = tf.getmembers()
except Exception as e:  # unreadable archive is a tool/input error, not a verdict
    print(f"check_tar ERROR: cannot read {tar_path}: {e}", file=sys.stderr)
    sys.exit(2)
for key in (tf.pax_headers or {}):
    if is_meta(key):
        note("global pax header with host metadata", key)
seen, folded, files, dirs = set(), {}, set(), set()
for m in members:
    n = m.name
    parts = n.split("/")
    if n.startswith("/") or "\\" in n or any(p in ("", ".", "..") for p in parts):
        note("unsafe path", n); continue
    base = parts[-1]
    if base.startswith("._"):
        note("AppleDouble ._* member", n)
    if "__MACOSX" in parts:
        note("__MACOSX member", n)
    if any(is_meta(k) for k in m.pax_headers):
        note("pax header with host metadata (xattr/ACL/flags)", n)
    if not (n == root or n.startswith(root + "/")):
        note(f"member outside {root}/", n)
    if m.isdir():
        dirs.add(n)
    elif m.isreg() and m.type != tarfile.CONTTYPE and not m.issparse():
        files.add(n)
    else:
        note("member that is not a directory or regular file", f"{n} (type {m.type!r})")
    if n in seen:
        note("path appears twice", n)
    seen.add(n)
    key = unicodedata.normalize("NFD", n).casefold()
    if key in folded and folded[key] != n:
        note("paths that fold together on a case-insensitive file system", f"{folded[key]} / {n}")
    folded.setdefault(key, n)
if root in files:
    note("root is a file", root)
for n in seen:
    parts = n.split("/")
    for i in range(1, len(parts)):
        if "/".join(parts[:i]) in files:
            note("file used as a directory", n); break
    if n in files and n in dirs:
        note("path is both a file and a directory", n)
if not files:
    note("archive has no regular file", tar_path)
if problems:
    for kind, names in problems.items():
        eg = ", ".join(names[:3]) + (", …" if len(names) > 3 else "")
        print(f"check_tar FAIL: {tar_path}: {len(names)} {kind} (e.g. {eg})", file=sys.stderr)
    sys.exit(1)
# (t4) extraction: directories first (sorted, so parents precede children),
# then regular files, each with exclusive create.
try:
    for n in sorted(dirs, key=lambda s: s.count("/")):
        os.makedirs(os.path.join(dest, n), exist_ok=True)
    for m in members:
        if m.name not in files:
            continue
        path = os.path.join(dest, m.name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        src = tf.extractfile(m)
        with open(path, "xb") as out:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                out.write(chunk)
        os.chmod(path, 0o755 if (m.mode & 0o111) else 0o644)
except (OSError, tarfile.TarError) as e:
    print(f"check_tar FAIL: {tar_path}: extraction failed: {e}", file=sys.stderr)
    sys.exit(1)
on_disk = sum(len(fs) for _, _, fs in os.walk(os.path.join(dest, root)))
if on_disk != len(files):
    print(f"check_tar FAIL: {tar_path}: {len(files)} regular members but {on_disk} files on disk after extraction", file=sys.stderr)
    sys.exit(1)
print(f"{len(members)} {len(files)} {len(dirs)}")
PY
)"
rc=$?
set -e
[[ ${rc} -eq 0 ]] || exit "${rc}"
read -r n_members n_files n_dirs <<< "${stats}"

# shellcheck source=scripts/headers.sh
source "${PACK_ROOT}/scripts/headers.sh"
tree="$(headers_tree_sha256 "${EXTRACT}/${ROOT}")" || die "hashing the extracted tree failed"
[[ "${tree}" =~ ^[0-9a-f]{64}$ ]] || die "hashing the extracted tree failed"
note=""
if [[ -n "${REFERENCE}" ]]; then
    ref="$(headers_tree_sha256 "${REFERENCE}")" || die "hashing the reference tree failed"
    [[ "${tree}" == "${ref}" ]] || fail "${TARBALL}: extracted tree ${tree} != reference ${REFERENCE} ${ref}"
    note="${note} == reference"
fi
if [[ -n "${WANT_TREE}" ]]; then
    [[ "${tree}" == "${WANT_TREE}" ]] || fail "${TARBALL}: extracted tree ${tree} != expected ${WANT_TREE}"
    note="${note} == expected"
fi
echo "check_tar PASS: ${TARBALL} — root ${ROOT}/, ${n_members} members (${n_files} files, ${n_dirs} dirs); 0 AppleDouble, 0 host-metadata headers; extracted tree ${tree}${note}"
