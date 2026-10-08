#!/usr/bin/env bash
# Self-test for scripts/check_zip.sh: a clean zip passes; each kind of
# polluted or mismatched zip is rejected for ITS reason (exit code AND message
# checked, so an unrelated failure cannot count as a rejection).
#
#   tests/package/test_check_zip.sh [<extra-zip-that-must-be-rejected>…]
#
# Extra arguments are real zips known to carry AppleDouble entries (e.g. the
# 150.2.0 release zip); each must be rejected as such.
set -uo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="${PACK_ROOT}/scripts/check_zip.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_check_zip.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
failures=0

# expect <name> <want-rc> <want-substring> -- <check_zip args…>
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

# A fixture shaped like an xcframework: nested dirs, a symlink, and files that
# carry an extended attribute (what makes ditto emit ._ entries by default).
make_fixture() { # make_fixture <dir>
    mkdir -p "$1/Fixture.xcframework/ios-arm64/Headers/include"
    printf 'lib\n' > "$1/Fixture.xcframework/ios-arm64/libFixture.a"
    printf '#pragma once\n' > "$1/Fixture.xcframework/ios-arm64/Headers/include/a.h"
    printf '<plist/>\n' > "$1/Fixture.xcframework/Info.plist"
    ln -s include/a.h "$1/Fixture.xcframework/ios-arm64/Headers/alias.h"
    xattr -w com.skia-pack.test 1 "$1/Fixture.xcframework/ios-arm64/libFixture.a"
    xattr -w com.skia-pack.test 1 "$1/Fixture.xcframework/Info.plist"
}

make_fixture "${WORK}/src"
REF="${WORK}/src/Fixture.xcframework"
[[ -n "$(xattr "${REF}/Info.plist")" ]] || { echo "ENVIRONMENT: could not set an xattr on the fixture"; exit 2; }

# The packaging command scripts/package.sh uses.
ditto -c -k --norsrc --noextattr --keepParent "${REF}" "${WORK}/clean.zip"
expect "clean zip (package.sh flags) passes against its reference" 0 "check_zip PASS" -- "${WORK}/clean.zip" "${REF}"
expect "clean zip passes without a reference" 0 "check_zip PASS" -- "${WORK}/clean.zip"

# Negative controls.
ditto -c -k --keepParent "${REF}" "${WORK}/appledouble.zip"
[[ -n "$(zipinfo -1 "${WORK}/appledouble.zip" | grep -E '(^|/)\._')" ]] \
    || { echo "ENVIRONMENT: ditto's default flags did not emit ._ entries for the fixture — control is not exercising the check"; exit 2; }
expect "default ditto flags (AppleDouble ._ entries) rejected" 1 "AppleDouble (._*)" -- "${WORK}/appledouble.zip" "${REF}"

ditto -c -k --sequesterRsrc --keepParent "${REF}" "${WORK}/macosx.zip"
expect "--sequesterRsrc (__MACOSX/ entries) rejected" 1 "__MACOSX/ entries" -- "${WORK}/macosx.zip" "${REF}"

cp -R "${WORK}/src" "${WORK}/extra"
printf 'late\n' > "${WORK}/extra/Fixture.xcframework/ios-arm64/late.h"
expect "reference has a file the zip lacks: rejected" 1 "differs from the reference" -- "${WORK}/clean.zip" "${WORK}/extra/Fixture.xcframework"

cp -R "${WORK}/src" "${WORK}/relink"
ln -sfn Headers/include/a.h "${WORK}/relink/Fixture.xcframework/ios-arm64/Headers/alias.h"
expect "symlink target differs from the reference: rejected" 1 "differs from the reference" -- "${WORK}/clean.zip" "${WORK}/relink/Fixture.xcframework"

cp -R "${WORK}/src" "${WORK}/bytes"
printf 'LIB\n' > "${WORK}/bytes/Fixture.xcframework/ios-arm64/libFixture.a"
expect "file bytes differ from the reference: rejected" 1 "differs from the reference" -- "${WORK}/clean.zip" "${WORK}/bytes/Fixture.xcframework"

expect "missing zip is a usage error, not a pass" 2 "no such zip" -- "${WORK}/nope.zip"

for z in "$@"; do
    expect "given zip $(basename "${z}") rejected as AppleDouble-polluted" 1 "AppleDouble (._*)" -- "${z}"
done

echo
if (( failures )); then echo "[test_check_zip] ${failures} FAILED"; exit 1; fi
echo "[test_check_zip] ALL PASSED"
