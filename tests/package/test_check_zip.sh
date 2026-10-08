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
# CHECK_ZIP overrides the gate under test (used to show this test rejects an
# older, fail-open version of it).
CHECK="${CHECK_ZIP:-${PACK_ROOT}/scripts/check_zip.sh}"
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

# Layout: the WHOLE unzipped tree must be the reference — wrapped in one
# directory named like it, or unwrapped — with nothing beside it.
ditto -c -k --norsrc --noextattr "${REF}" "${WORK}/unwrapped.zip"
expect "unwrapped zip (root is the reference's tree) passes" 0 "unwrapped" -- "${WORK}/unwrapped.zip" "${REF}"
expect "wrapped zip (--keepParent) passes, reported as wrapped" 0 "wrapped in Fixture.xcframework/" -- "${WORK}/clean.zip" "${REF}"
stage_zip() { # stage_zip <name> <setup-command…>: zip the CONTENTS of a fresh staging dir
    local s="${WORK}/stage-$1"; mkdir -p "${s}"; shift
    (cd "${s}" && "$@") || { echo "ENVIRONMENT: staging failed"; exit 2; }
    ditto -c -k --norsrc --noextattr "${s}" "${WORK}/$(basename "${s}").zip"
}
stage_zip extra-file sh -c "cp -R '${REF}' . && printf 'x\n' > unexpected.txt"
expect "extra top-level FILE beside the wrapper: rejected" 1 "differs from the reference" -- "${WORK}/stage-extra-file.zip" "${REF}"
stage_zip extra-dir sh -c "cp -R '${REF}' . && mkdir extra && printf 'x\n' > extra/f.txt"
expect "extra top-level DIRECTORY beside the wrapper: rejected" 1 "differs from the reference" -- "${WORK}/stage-extra-dir.zip" "${REF}"
stage_zip extra-empty-dir sh -c "cp -R '${REF}' . && mkdir extra"
expect "extra empty top-level directory beside the wrapper: rejected" 1 "differs from the reference" -- "${WORK}/stage-extra-empty-dir.zip" "${REF}"
stage_zip unwrapped-extra sh -c "cp -R '${REF}'/. . && printf 'x\n' > unexpected.txt"
expect "unwrapped tree plus an extra top-level file: rejected" 1 "differs from the reference" -- "${WORK}/stage-unwrapped-extra.zip" "${REF}"
stage_zip double-wrap sh -c "mkdir outer && cp -R '${REF}' outer/"
expect "reference nested one level too deep: rejected" 1 "differs from the reference" -- "${WORK}/stage-double-wrap.zip" "${REF}"

# Tool-failure negative controls. A shim directory first on PATH makes one tool
# exit 2 — after its normal output or with none, on every call or only on
# calls whose arguments contain <match>. Each fault is applied to the clean zip
# against its reference (a fault must not PASS) and against a reference with
# different bytes (a fault must not turn the real difference into "matches");
# faults in the tools the listing check uses (zipinfo, the ._ / __MACOSX
# searches, wc) are also applied to the AppleDouble zip (a fault must not hide
# the pollution — the other tools never run for it, the listing already fails
# it). Every case must exit 2 with "check_zip ERROR".
make_shim() { # make_shim <dir> <tool> <after-output|no-output> [match]
    local dir="$1" tool="$2" how="$3" match="${4:-}" real
    real="$(command -v "${tool}")" || { echo "ENVIRONMENT: no ${tool}"; exit 2; }
    mkdir -p "${dir}"
    {
        echo '#!/bin/bash'
        printf 'case "$*" in *%q*) ;; *) exec "%s" "$@" ;; esac\n' "${match}" "${real}"
        [[ "${how}" == after-output ]] && printf '"%s" "$@"\n' "${real}"
        echo 'exit 2'
    } > "${dir}/${tool}"
    chmod +x "${dir}/${tool}"
}
expect_fault() { # expect_fault <label> <shim-dir> <listing-phase: yes|no>
    local zip ref out rc pairs=("clean.zip:${REF}" "clean.zip:${WORK}/bytes/Fixture.xcframework")
    [[ "$3" == yes ]] && pairs+=("appledouble.zip:${REF}")
    for pair in "${pairs[@]}"; do
        zip="${WORK}/${pair%%:*}"; ref="${pair#*:}"
        out="$(PATH="$2:${PATH}" "${CHECK}" "${zip}" "${ref}" 2>&1)"; rc=$?
        if [[ "${rc}" == 2 ]] && grep -qF "check_zip ERROR" <<< "${out}"; then
            echo "ok   fault: $1 — $(basename "${zip}") vs $(basename "$(dirname "${ref}")") (rc=2)"
        else
            echo "FAIL fault: $1 — $(basename "${zip}") vs ${ref}: want rc=2 check_zip ERROR, got rc=${rc}: ${out}"
            failures=$((failures + 1))
        fi
    done
}
expect "control for the fault cases: clean zip vs different bytes is a FAIL" 1 "differs from the reference" -- "${WORK}/clean.zip" "${WORK}/bytes/Fixture.xcframework"
for how in after-output no-output; do
    for spec in "shasum::no" "readlink::no" "zipinfo::yes" "unzip::no" "ditto::no" "find::no" "sort::no" "diff::no" "wc::yes" \
                'grep:\._:yes' "grep:__MACOSX:yes" "grep:^l :no"; do
        tool="${spec%%:*}"; rest="${spec#*:}"; match="${rest%:*}"; listing="${rest##*:}"; d="${WORK}/shim-${tool}-${how}-$(printf '%s' "${match:-all}" | tr -c 'A-Za-z0-9' '_')"
        make_shim "${d}" "${tool}" "${how}" "${match}"
        if [[ -n "${match}" ]]; then scope="only calls with '${match}'"; else scope="every call"; fi
        expect_fault "${tool} exits 2 (${how}, ${scope})" "${d}" "${listing}"
    done
done

for z in "$@"; do
    expect "given zip $(basename "${z}") rejected as AppleDouble-polluted" 1 "AppleDouble (._*)" -- "${z}"
done

echo
if (( failures )); then echo "[test_check_zip] ${failures} FAILED"; exit 1; fi
echo "[test_check_zip] ALL PASSED"
