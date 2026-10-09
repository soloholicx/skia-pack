#!/usr/bin/env bash
# Privacy-manifest carry gate: does an app ARCHIVE built against the SkiaPack
# product carry skia-pack's PrivacyInfo.xcprivacy, once and intact?
#
#   check_privacy_carry.sh <app.xcarchive> <expected PrivacyInfo.xcprivacy>
#
# Looks only inside the archive's .app (never at Build/Products, which can hold
# a manifest that never reached the app). Checks:
#   1. Products/Applications holds exactly one .app
#   2. the .app holds exactly one skia-pack_SkiaPackPrivacy.bundle, at its top
#      level, and that bundle holds exactly one PrivacyInfo.xcprivacy, a
#      regular file at the bundle's top level
#   3. it is byte-identical to <expected>, and no OTHER file in the .app is
#      (a second copy anywhere is a duplicate)
#   4. it is a valid property list (plutil -lint) with the manifest shape:
#      NSPrivacyTracking boolean; NSPrivacyTrackingDomains and
#      NSPrivacyCollectedDataTypes arrays; NSPrivacyAccessedAPITypes a
#      non-empty array of {NSPrivacyAccessedAPIType: a known category,
#      NSPrivacyAccessedAPITypeReasons: non-empty, well-formed codes}, each
#      category once. Whether a code is the RIGHT code is a review decision,
#      not this gate's.
#
# Standalone: nothing in this repository runs it yet. It is meant to run on an
# unsigned Release archive of an app consuming the SkiaPack product, once the
# package carries a manifest (that wiring is a separate, later change).
#
# Fail closed: every tool's exit status is checked; searches are three-state.
# Exit: 0 pass; 1 a check failed; 2 usage, environment or tool error.
set -uo pipefail

ARCHIVE="${1:-}" EXPECTED="${2:-}"
die()  { echo "check_privacy_carry ERROR: $*" >&2; exit 2; }
fail() { echo "check_privacy_carry FAIL: $*" >&2; exit 1; }
[[ $# -eq 2 ]] || { echo "usage: check_privacy_carry.sh <app.xcarchive> <expected PrivacyInfo.xcprivacy>" >&2; exit 2; }
[[ -d "${ARCHIVE}" ]] || die "no such archive: ${ARCHIVE}"
[[ -f "${EXPECTED}" ]] || die "no such expected manifest: ${EXPECTED}"
BUNDLE_NAME="skia-pack_SkiaPackPrivacy.bundle"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check_privacy_carry.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "${WORK}"' EXIT

# list <out-array-name> <find args…>: NUL-separated find results into an array;
# a find error dies (results printed before the error are not trusted).
list() {
    local __name="$1"; shift
    find "$@" -print0 > "${WORK}/find.out" 2> "${WORK}/find.err" || die "find failed ($*): $(head -1 "${WORK}/find.err")"
    local p; local -a acc=()
    while IFS= read -r -d '' p; do acc+=("${p}"); done < "${WORK}/find.out"
    eval "${__name}=(\"\${acc[@]+\"\${acc[@]}\"}\")"
}

# ---- 1. one app -----------------------------------------------------------------
[[ -d "${ARCHIVE}/Products/Applications" ]] || fail "archive has no Products/Applications"
list apps "${ARCHIVE}/Products/Applications" -mindepth 1 -maxdepth 1 -name '*.app'
[[ ${#apps[@]} -eq 1 ]] || fail "expected one .app in the archive, found ${#apps[@]}"
APP="${apps[0]}"

# ---- 2. one bundle, one manifest, where SwiftPM puts it ----------------------------
list bundles "${APP}" -name "${BUNDLE_NAME}"
[[ ${#bundles[@]} -eq 1 ]] || fail "expected one ${BUNDLE_NAME} in ${APP##*/}, found ${#bundles[@]}: ${bundles[*]+${bundles[*]#"${APP}/"}}"
[[ "${bundles[0]}" == "${APP}/${BUNDLE_NAME}" ]] || fail "${BUNDLE_NAME} is not at the app's top level: ${bundles[0]#"${APP}/"}"
list inbundle "${bundles[0]}" -name PrivacyInfo.xcprivacy
[[ ${#inbundle[@]} -eq 1 ]] || fail "expected one PrivacyInfo.xcprivacy in ${BUNDLE_NAME}, found ${#inbundle[@]}"
M="${bundles[0]}/PrivacyInfo.xcprivacy"
[[ "${inbundle[0]}" == "${M}" ]] || fail "the manifest is not at the bundle's top level: ${inbundle[0]#"${APP}/"}"
[[ -f "${M}" && ! -L "${M}" ]] || fail "the manifest is not a regular file"

# ---- 3. intact, and the only copy ------------------------------------------------------
# same <a> <b>: prints same|differ; a cmp error dies.
same() {
    cmp -s -- "$1" "$2"
    case $? in 0) echo same ;; 1) echo differ ;; *) return 1 ;; esac
}
r="$(same "${M}" "${EXPECTED}")" || die "cmp failed on the manifest"
[[ "${r}" == same ]] || fail "the archived manifest differs from ${EXPECTED}"
list files "${APP}" -type f
copies=0
for f in "${files[@]}"; do
    r="$(same "${f}" "${EXPECTED}")" || die "cmp failed on ${f}"
    [[ "${r}" == same ]] && copies=$((copies + 1))
done
[[ ${copies} -eq 1 ]] || fail "the manifest's content appears ${copies} times in ${APP##*/} (want exactly 1)"

# ---- 4. a valid manifest ---------------------------------------------------------------
plutil -lint -- "${M}" > "${WORK}/lint" 2>&1; rc=$?
case ${rc} in
    0) grep -q ': OK$' "${WORK}/lint"; case $? in 0) ;; 1) die "plutil -lint exited 0 without reporting OK" ;; *) die "grep failed" ;; esac ;;
    1) fail "the manifest is not a valid property list: $(head -1 "${WORK}/lint")" ;;
    *) die "plutil -lint failed (rc=${rc}): $(head -1 "${WORK}/lint")" ;;
esac
python3 - "${M}" > "${WORK}/shape" 2>&1 <<'PY'
import plistlib, re, sys
CATS = {"NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPICategorySystemBootTime",
        "NSPrivacyAccessedAPICategoryDiskSpace", "NSPrivacyAccessedAPICategoryActiveKeyboards",
        "NSPrivacyAccessedAPICategoryUserDefaults"}
def bad(msg): print(f"INVALID {msg}"); sys.exit(1)
try:
    p = plistlib.load(open(sys.argv[1], "rb"))
except Exception as e:
    bad(f"not loadable: {e}")
if not isinstance(p, dict): bad("top level is not a dict")
if not isinstance(p.get("NSPrivacyTracking"), bool): bad("NSPrivacyTracking missing or not a boolean")
for k in ("NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes"):
    if not isinstance(p.get(k), list): bad(f"{k} missing or not an array")
apis = p.get("NSPrivacyAccessedAPITypes")
if not isinstance(apis, list) or not apis: bad("NSPrivacyAccessedAPITypes missing, not an array, or empty")
seen = set()
for i, a in enumerate(apis):
    if not isinstance(a, dict) or set(a) != {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}:
        bad(f"entry {i} is not exactly {{NSPrivacyAccessedAPIType, NSPrivacyAccessedAPITypeReasons}}")
    c, rs = a["NSPrivacyAccessedAPIType"], a["NSPrivacyAccessedAPITypeReasons"]
    if c not in CATS: bad(f"entry {i}: unknown category {c!r}")
    if c in seen: bad(f"category {c} listed twice")
    seen.add(c)
    if not isinstance(rs, list) or not rs or not all(isinstance(r, str) and re.fullmatch(r"[0-9A-F]{4}\.[0-9]", r) for r in rs):
        bad(f"entry {i} ({c}): reasons {rs!r} are not a non-empty list of well-formed codes")
    if len(set(rs)) != len(rs): bad(f"entry {i} ({c}): a reason is listed twice")
print("VALID " + "; ".join(f"{a['NSPrivacyAccessedAPIType']}={','.join(a['NSPrivacyAccessedAPITypeReasons'])}" for a in apis))
PY
rc=$?
case ${rc} in
    0) grep -q '^VALID ' "${WORK}/shape"; case $? in 0) ;; 1) die "shape check exited 0 without reporting VALID" ;; *) die "grep failed" ;; esac ;;
    1) grep -q '^INVALID ' "${WORK}/shape"; case $? in
           0) fail "manifest shape: $(grep -m1 '^INVALID ' "${WORK}/shape")" ;;
           *) die "shape check exited 1 without a verdict: $(head -1 "${WORK}/shape")" ;; esac ;;
    *) die "shape check failed (rc=${rc}): $(head -1 "${WORK}/shape")" ;;
esac
echo "check_privacy_carry PASS: ${APP##*/}/${BUNDLE_NAME}/PrivacyInfo.xcprivacy — one copy, identical to ${EXPECTED##*/}, $(grep -m1 '^VALID ' "${WORK}/shape")"
