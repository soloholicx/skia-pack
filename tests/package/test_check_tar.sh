#!/usr/bin/env bash
# Self-test for scripts/check_tar.sh: a clean archive passes; each kind of bad
# archive is rejected for ITS reason (exit code AND message checked, so an
# unrelated failure cannot count as a rejection), and a rejected archive is
# never extracted.
#
#   tests/package/test_check_tar.sh [<tar.gz>:<root>:<n-appledouble>…]
#
# Extra arguments are real archives known to carry AppleDouble members (the
# 157.1.0 macOS and skia-headers tarballs); each must be rejected with exactly
# that many "._*" members reported.
set -uo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="${CHECK_TAR:-${PACK_ROOT}/scripts/check_tar.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_check_tar.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
failures=0

# expect <name> <want-rc> <want-substring> -- <check_tar args…>
expect() {
    local name="$1" want_rc="$2" want_msg="$3"; shift 4
    local out rc
    out="$("${CHECK}" "$@" 2>&1)"; rc=$?
    if [[ "${rc}" == "${want_rc}" ]] && grep -qF -- "${want_msg}" <<< "${out}"; then
        echo "ok   ${name} (rc=${rc})"
    else
        echo "FAIL ${name}: want rc=${want_rc} with '${want_msg}', got rc=${rc}:"; sed 's/^/       /' <<< "${out}"
        failures=$((failures + 1))
    fi
}
# expect_empty <name> <dir>: a rejected archive left nothing behind
expect_empty() {
    if [[ -d "$2" && -z "$(ls -A "$2")" ]]; then echo "ok   $1"; else echo "FAIL $1: $2 is not an empty directory"; failures=$((failures + 1)); fi
}

# Source tree whose files carry extended attributes, as staged files on a Mac do.
mkdir -p "${WORK}/src/r/include/core" "${WORK}/src/r/lib"
printf '#pragma once\n' > "${WORK}/src/r/include/core/A.h"
printf 'lib\n' > "${WORK}/src/r/lib/libx.a"
printf 'license\n' > "${WORK}/src/r/LICENSE"
xattr -w com.apple.provenance x "${WORK}/src/r/include/core/A.h"
xattr -w com.skia-pack.test 1 "${WORK}/src/r/lib/libx.a"
xattr -w com.skia-pack.test 1 "${WORK}/src/r"

# --- the archive package.sh's pack_tar makes: passes -------------------------
tar --no-mac-metadata --no-xattrs --no-acls --no-fflags -C "${WORK}/src" -czf "${WORK}/clean.tgz" r
expect "clean archive == its source tree" 0 "== reference" -- "${WORK}/clean.tgz" r --reference "${WORK}/src/r"
want="$(source "${PACK_ROOT}/scripts/headers.sh"; headers_tree_sha256 "${WORK}/src/r")"
expect "clean archive == expected tree hash" 0 "== expected" -- "${WORK}/clean.tgz" r --tree-sha256 "${want}"
mkdir -p "${WORK}/x-clean"
expect "clean archive extracted into --extract-to" 0 "3 files" -- "${WORK}/clean.tgz" r --extract-to "${WORK}/x-clean/out"
if cmp -s "${WORK}/x-clean/out/r/include/core/A.h" "${WORK}/src/r/include/core/A.h"; then echo "ok   extracted bytes equal source"; else echo "FAIL extracted bytes differ"; failures=$((failures + 1)); fi

# --- macOS tar without the flags (what 157.1.0 shipped) ------------------------
tar -C "${WORK}/src" -czf "${WORK}/plain.tgz" r
mkdir -p "${WORK}/x-plain"
expect "plain bsdtar archive: AppleDouble" 1 "AppleDouble ._* member" -- "${WORK}/plain.tgz" r --extract-to "${WORK}/x-plain"
expect "plain bsdtar archive: xattr pax headers" 1 "pax header with host metadata" -- "${WORK}/plain.tgz" r
expect_empty "rejected archive was not extracted" "${WORK}/x-plain"
# COPYFILE_DISABLE=1 alone: no ._* members, but the xattrs ride in pax headers.
COPYFILE_DISABLE=1 tar -C "${WORK}/src" -czf "${WORK}/copyfile.tgz" r
expect "COPYFILE_DISABLE=1 only: xattr pax headers" 1 "pax header with host metadata" -- "${WORK}/copyfile.tgz" r

# --- hand-made archives, one defect each (Python tarfile, no bsdtar) ----------
mk() { # mk <out> <spec…>: spec = d:<path> | f:<path> | l:<path>:<target> | h:<path>:<target> | x:<path> (file + xattr pax) | g (global xattr pax header)
    python3 - "$@" <<'PY'
import io, sys, tarfile
out, specs = sys.argv[1], sys.argv[2:]
glob = {"LIBARCHIVE.xattr.com.apple.provenance": "eA=="} if "g" in specs else {}
with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT, pax_headers=glob) as t:
    for s in specs:
        if s == "g": continue
        kind, rest = s.split(":", 1)
        if kind == "d":
            i = tarfile.TarInfo(rest); i.type = tarfile.DIRTYPE; i.mode = 0o755; t.addfile(i)
        elif kind in ("f", "x"):
            data = b"x\n"; i = tarfile.TarInfo(rest); i.size = len(data); i.mode = 0o644
            if kind == "x": i.pax_headers = {"SCHILY.xattr.com.apple.provenance": "x"}
            t.addfile(i, io.BytesIO(data))
        elif kind in ("l", "h"):
            path, target = rest.split(":", 1)
            i = tarfile.TarInfo(path); i.type = tarfile.SYMTYPE if kind == "l" else tarfile.LNKTYPE; i.linkname = target; t.addfile(i)
PY
}
mk "${WORK}/ok.tgz" d:r f:r/a.h
expect "hand-made clean archive" 0 "check_tar PASS" -- "${WORK}/ok.tgz" r
mk "${WORK}/ad.tgz" d:r f:r/a.h f:r/._a.h
expect "AppleDouble member (GNU-tar view)" 1 "1 AppleDouble ._* member" -- "${WORK}/ad.tgz" r
mk "${WORK}/macosx.tgz" d:r f:r/a.h f:r/__MACOSX/a.h
expect "__MACOSX member" 1 "__MACOSX member" -- "${WORK}/macosx.tgz" r
mk "${WORK}/xattr.tgz" d:r x:r/a.h
expect "xattr pax header" 1 "pax header with host metadata" -- "${WORK}/xattr.tgz" r
mk "${WORK}/global.tgz" g d:r f:r/a.h
expect "global xattr pax header" 1 "global pax header with host metadata" -- "${WORK}/global.tgz" r
mk "${WORK}/outside.tgz" d:r f:r/a.h f:other/a.h
expect "member outside the root" 1 "member outside r/" -- "${WORK}/outside.tgz" r
mk "${WORK}/dotdot.tgz" d:r f:r/a.h f:r/../a.h
expect "'..' component" 1 "unsafe path" -- "${WORK}/dotdot.tgz" r
mk "${WORK}/abs.tgz" d:r f:r/a.h f:/r/b.h
expect "absolute path" 1 "unsafe path" -- "${WORK}/abs.tgz" r
mk "${WORK}/sym.tgz" d:r f:r/a.h l:r/b.h:a.h
expect "symlink" 1 "not a directory or regular file" -- "${WORK}/sym.tgz" r
mk "${WORK}/hard.tgz" d:r f:r/a.h h:r/b.h:r/a.h
expect "hard link" 1 "not a directory or regular file" -- "${WORK}/hard.tgz" r
mk "${WORK}/dup.tgz" d:r f:r/a.h f:r/a.h
expect "same path twice" 1 "path appears twice" -- "${WORK}/dup.tgz" r
mk "${WORK}/case.tgz" d:r f:r/A.h f:r/a.h
expect "paths differing only in case" 1 "fold together" -- "${WORK}/case.tgz" r
mk "${WORK}/nfd.tgz" d:r "f:r/$(printf '\xc3\xa9').h" "f:r/e$(printf '\xcc\x81').h"
expect "paths differing only in Unicode normalization" 1 "fold together" -- "${WORK}/nfd.tgz" r
mk "${WORK}/filedir.tgz" d:r f:r/a f:r/a/b.h
expect "file used as a directory" 1 "file used as a directory" -- "${WORK}/filedir.tgz" r
mk "${WORK}/both.tgz" d:r f:r/a d:r/a
expect "path that is both file and directory" 1 "both a file and a directory" -- "${WORK}/both.tgz" r
mk "${WORK}/empty.tgz" d:r
expect "no regular file" 1 "has no regular file" -- "${WORK}/empty.tgz" r

# --- tree mismatches and usage --------------------------------------------------
mkdir -p "${WORK}/other/r" && printf 'different\n' > "${WORK}/other/r/a.h"
expect "tree != reference" 1 "!= reference" -- "${WORK}/clean.tgz" r --reference "${WORK}/other/r"
expect "tree != expected hash" 1 "!= expected" -- "${WORK}/clean.tgz" r --tree-sha256 "$(printf '0%.0s' {1..64})"
mkdir -p "${WORK}/busy" && touch "${WORK}/busy/f"
expect "non-empty --extract-to refused" 2 "must not exist or be empty" -- "${WORK}/clean.tgz" r --extract-to "${WORK}/busy"
expect "root with a slash refused" 2 "one path component" -- "${WORK}/clean.tgz" r/include
printf 'not a tar' > "${WORK}/junk.tgz"
expect "unreadable archive is a tool error" 2 "cannot read" -- "${WORK}/junk.tgz" r

# --- real archives known to be polluted ----------------------------------------
for spec in "$@"; do
    IFS=: read -r path root count <<< "${spec}"
    expect "real archive $(basename "${path}"): ${count} AppleDouble members" 1 "${count} AppleDouble ._* member" -- "${path}" "${root}"
done

echo
if (( failures )); then echo "[test_check_tar] ${failures} FAILED"; exit 1; fi
echo "[test_check_tar] ALL PASSED ($(( $# )) real archive(s) checked)"
