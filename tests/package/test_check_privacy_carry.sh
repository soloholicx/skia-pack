#!/usr/bin/env bash
# Self-test for scripts/check_privacy_carry.sh: a correct archive passes; each
# way the manifest can be missing, duplicated, misplaced, tampered or malformed
# is rejected for ITS reason; each tool failure is an error (exit 2), never a
# pass (exit code AND message checked).
set -uo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="${PACK_ROOT}/scripts/check_privacy_carry.sh"
# A test-only manifest (fake reason codes): this self-test is independent of
# whatever manifest skia-pack ships, so it can run before one is approved.
MANIFEST="${PACK_ROOT}/tests/package/fixtures/privacy/PrivacyInfo.test.xcprivacy"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_check_privacy_carry.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
failures=0
B=skia-pack_SkiaPackPrivacy.bundle

# expect <name> <want-rc> <want-substring> <archive> [<expected>] [PATH prefix]
expect() {
    local name="$1" want_rc="$2" want_msg="$3" arc="$4" exp="${5:-${MANIFEST}}" pre="${6:-}"
    local out rc
    out="$(PATH="${pre:+${pre}:}${PATH}" "${CHECK}" "${arc}" "${exp}" 2>&1)"; rc=$?
    if [[ "${rc}" == "${want_rc}" ]] && grep -qF -- "${want_msg}" <<< "${out}"; then
        echo "ok   ${name} (rc=${rc})"
    else
        echo "FAIL ${name}: want rc=${want_rc} with '${want_msg}', got rc=${rc}:"; sed 's/^/       /' <<< "${out}"
        failures=$((failures + 1))
    fi
}
# arc <name> [<manifest>]: a minimal archive whose app carries the bundle.
arc() {
    local a="${WORK}/$1.xcarchive" m="${2:-${MANIFEST}}"
    mkdir -p "${a}/Products/Applications/App.app/${B}"
    printf 'binary\n' > "${a}/Products/Applications/App.app/App"
    printf '<plist/>\n' > "${a}/Products/Applications/App.app/Info.plist"
    printf '<plist/>\n' > "${a}/Products/Applications/App.app/${B}/Info.plist"
    cp "${m}" "${a}/Products/Applications/App.app/${B}/PrivacyInfo.xcprivacy"
    echo "${a}"
}
APPDIR=Products/Applications/App.app
[[ -f "${MANIFEST}" ]] || { echo "ENVIRONMENT: no ${MANIFEST}"; exit 2; }

expect "correct archive passes" 0 "check_privacy_carry PASS" "$(arc good)"

# Missing / misplaced / duplicated.
a="$(arc missing)"; rm -rf "${a}/${APPDIR}/${B}"
mkdir -p "${WORK}/missing-dd/Build/Products/Release-iphoneos/${B}"   # what the old Build/Products check saw
cp "${MANIFEST}" "${WORK}/missing-dd/Build/Products/Release-iphoneos/${B}/PrivacyInfo.xcprivacy"
expect "missing in the app (still present in Build/Products) rejected" 1 "found 0" "${a}"
a="$(arc noapp)"; rm -rf "${a}/${APPDIR}"
expect "no .app rejected" 1 "expected one .app in the archive, found 0" "${a}"
a="$(arc twoapps)"; cp -R "${a}/${APPDIR}" "${a}/Products/Applications/Other.app"
expect "two .app rejected" 1 "expected one .app in the archive, found 2" "${a}"
a="$(arc dupbundle)"; mkdir -p "${a}/${APPDIR}/Frameworks/X.framework"; cp -R "${a}/${APPDIR}/${B}" "${a}/${APPDIR}/Frameworks/X.framework/"
expect "a second bundle (in a framework) rejected" 1 "found 2" "${a}"
a="$(arc nested)"; mkdir -p "${a}/${APPDIR}/PlugIns"; mv "${a}/${APPDIR}/${B}" "${a}/${APPDIR}/PlugIns/"
expect "bundle not at the app's top level rejected" 1 "not at the app's top level" "${a}"
a="$(arc dupinbundle)"; mkdir -p "${a}/${APPDIR}/${B}/Sub"; cp "${MANIFEST}" "${a}/${APPDIR}/${B}/Sub/PrivacyInfo.xcprivacy"
expect "a second manifest inside the bundle rejected" 1 "found 2" "${a}"
a="$(arc dupcopy)"; cp "${MANIFEST}" "${a}/${APPDIR}/copy.plist"
expect "a copy of the manifest elsewhere in the app rejected" 1 "appears 2 times" "${a}"
a="$(arc symlink)"; mv "${a}/${APPDIR}/${B}/PrivacyInfo.xcprivacy" "${a}/${APPDIR}/real.xcprivacy"
ln -s ../real.xcprivacy "${a}/${APPDIR}/${B}/PrivacyInfo.xcprivacy"
expect "manifest as a symlink rejected" 1 "not a regular file" "${a}"

# Tampered / malformed.
sed 's/AAAA\.1/AAAA.2/' "${MANIFEST}" > "${WORK}/tampered.xcprivacy"
cmp -s "${MANIFEST}" "${WORK}/tampered.xcprivacy" && { echo "ENVIRONMENT: tamper did not change the manifest"; exit 2; }
expect "tampered manifest (one reason code changed) rejected" 1 "differs from" "$(arc tampered "${WORK}/tampered.xcprivacy")"
mkmani() { # mkmani <name> <python expression transforming p>
    /usr/bin/python3 - "${MANIFEST}" "${WORK}/$1.xcprivacy" "$2" <<'PY' || { echo "ENVIRONMENT: fixture"; exit 2; }
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb")); exec(sys.argv[3]); plistlib.dump(p, open(sys.argv[2], "wb"))
PY
    echo "${WORK}/$1.xcprivacy"
}
printf 'not a plist\n' > "${WORK}/garbage.xcprivacy"
expect "not a property list rejected" 1 "not a valid property list" "$(arc garbage "${WORK}/garbage.xcprivacy")" "${WORK}/garbage.xcprivacy"
m="$(mkmani unknowncat 'p["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPIType"]="NSPrivacyAccessedAPICategoryNope"')"
expect "unknown category rejected" 1 "unknown category" "$(arc unknowncat "${m}")" "${m}"
m="$(mkmani noreasons 'p["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"]=[]')"
expect "empty reasons rejected" 1 "not a non-empty list" "$(arc noreasons "${m}")" "${m}"
m="$(mkmani badcode 'p["NSPrivacyAccessedAPITypes"][1]["NSPrivacyAccessedAPITypeReasons"]=["35F9"]')"
expect "malformed reason code rejected" 1 "well-formed codes" "$(arc badcode "${m}")" "${m}"
m="$(mkmani dupcat 'p["NSPrivacyAccessedAPITypes"].append(dict(p["NSPrivacyAccessedAPITypes"][0]))')"
expect "category listed twice rejected" 1 "listed twice" "$(arc dupcat "${m}")" "${m}"
m="$(mkmani notracking 'del p["NSPrivacyTracking"]')"
expect "missing NSPrivacyTracking rejected" 1 "NSPrivacyTracking missing" "$(arc notracking "${m}")" "${m}"

# Tool failures: a shim runs the real tool, then misbehaves.
GOOD="$(arc tools)"
shim() { # shim <dir> <tool> <script body>
    mkdir -p "${WORK}/$1"; printf '#!/bin/bash\n%s\n' "$3" > "${WORK}/$1/$2"; chmod +x "${WORK}/$1/$2"; echo "${WORK}/$1"
}
PY3="$(command -v python3)" || { echo "ENVIRONMENT: no python3"; exit 2; }
expect "find exits 2 after output -> error" 2 "find failed" "${GOOD}" "" "$(shim s1 find '/usr/bin/find "$@"; exit 2')"
expect "find exits 2, no output -> error" 2 "find failed" "${GOOD}" "" "$(shim s2 find 'exit 2')"
expect "find fails only on the file sweep -> error" 2 "find failed" "${GOOD}" "" \
    "$(shim s3 find 'for a; do [[ "$a" == -type ]] && exit 2; done; exec /usr/bin/find "$@"')"
expect "cmp exits 2 -> error, not 'differ'" 2 "cmp failed" "${GOOD}" "" "$(shim s4 cmp 'exit 2')"
expect "plutil exits 2 after printing OK -> error" 2 "plutil -lint failed" "${GOOD}" "" "$(shim s5 plutil '/usr/bin/plutil "$@"; exit 2')"
expect "plutil exits 0 without OK -> error" 2 "without reporting OK" "${GOOD}" "" "$(shim s6 plutil 'exit 0')"
expect "python3 exits 2 after printing VALID -> error" 2 "shape check failed (rc=2)" "${GOOD}" "" "$(shim s7 python3 "\"${PY3}\" \"\$@\"; exit 2")"
expect "python3 exits 0 without VALID -> error" 2 "without reporting VALID" "${GOOD}" "" "$(shim s8 python3 'cat >/dev/null; exit 0')"
expect "python3 exits 1 without a verdict -> error" 2 "without a verdict" "${GOOD}" "" "$(shim s9 python3 'cat >/dev/null; exit 1')"
expect "the same good archive still passes with real tools" 0 "check_privacy_carry PASS" "${GOOD}"

# Usage.
expect "missing expected manifest -> error" 2 "no such expected manifest" "${GOOD}" "${WORK}/none"
expect "missing archive -> error" 2 "no such archive" "${WORK}/none.xcarchive"

if [[ ${failures} -eq 0 ]]; then echo "test_check_privacy_carry: ALL PASS"; else echo "test_check_privacy_carry: ${failures} FAILED"; exit 1; fi
