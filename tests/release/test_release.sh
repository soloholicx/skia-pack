#!/usr/bin/env bash
# Tests for scripts/release.sh's guards and its frozen-artifact rule. No
# network, no real GitHub, no Skia build: a throwaway clone with a local bare
# "origin", a fake `gh` (tests/release/fake_gh.sh) and stub build/package/verify
# scripts. The stub packager mints DIFFERENT bytes on every call, so any
# repackaging of an existing version is caught by a checksum mismatch.
#
#   tests/release/test_release.sh        exit 0 = all cases behaved
set -uo pipefail
PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skia-pack-release-test.XXXXXX")"
trap 'chmod -R u+w "${ROOT}" 2>/dev/null; rm -rf "${ROOT}"' EXIT
failures=0
ok()  { echo "ok    $*"; }
bad() { echo "WRONG $*"; failures=$((failures + 1)); }

new_sandbox() { # fresh origin + clone; sets SB, FAKE_GH, FAKE_ORIGIN
    SB="${ROOT}/sb-$1"; export FAKE_GH="${ROOT}/gh-$1" FAKE_ORIGIN="${ROOT}/origin-$1.git"
    mkdir -p "${SB}/scripts" "${FAKE_GH}/bin"
    cp "${PACK_ROOT}/scripts/release.sh" "${SB}/scripts/"
    cp "${PACK_ROOT}/Package.swift" "${PACK_ROOT}/pins.json" "${PACK_ROOT}/.gitignore" "${SB}/"
    echo "9.9.9" > "${SB}/VERSION"; echo "9.9.9" > "${FAKE_GH}/version"
    cp "${PACK_ROOT}/tests/release/fake_gh.sh" "${FAKE_GH}/bin/gh"; chmod +x "${FAKE_GH}/bin/gh"
    for s in build verify; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_GH/build.log"\n' "$s" > "${SB}/scripts/$s.sh"; done
    printf '#!/usr/bin/env bash\necho "verify_consumer $*" >> "$FAKE_GH/build.log"\n' > "${SB}/scripts/verify_consumer.sh"
    cat > "${SB}/scripts/package.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."; echo "package" >> "$FAKE_GH/build.log"
mkdir -p artifacts; n="$(grep -c '^package$' "$FAKE_GH/build.log")"
echo "tarball bytes, packaging run $n" > artifacts/skia-pack-9.9.9-macos-arm64.tar.gz
echo "zip bytes, packaging run $n" > artifacts/SkiaPack.xcframework.zip
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
printf '{"version":"9.9.9","artifacts":{"macos-arm64-tarball":{"file":"skia-pack-9.9.9-macos-arm64.tar.gz","sha256":"%s"},"xcframework":{"file":"SkiaPack.xcframework.zip","sha256":"%s","spm_checksum":"%s"}}}\n' \
    "$(sha artifacts/skia-pack-9.9.9-macos-arm64.tar.gz)" "$(sha artifacts/SkiaPack.xcframework.zip)" "$(swift package compute-checksum artifacts/SkiaPack.xcframework.zip)" > artifacts/pack.json
STUB
    chmod +x "${SB}/scripts/"*.sh
    git init -q --bare "${FAKE_ORIGIN}"
    ( cd "${SB}" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base \
      && git remote add origin "${FAKE_ORIGIN}" && git push -q origin main ) >/dev/null 2>&1
}
run() { # run <args…> → sets RC, OUT
    OUT="$( cd "${SB}" && PATH="${FAKE_GH}/bin:${PATH}" SKIA_PACK_RELEASE_CONFIRM=1 SKIA_PACK_RELEASE_RETRY_SLEEP=0 \
            GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
            ./scripts/release.sh "$@" 2>&1 )"; RC=$?
}
count()      { local n; n="$(grep -cE "$1" "$2" 2>/dev/null)" || true; echo "${n:-0}"; }
packs()      { count '^package$' "${FAKE_GH}/build.log"; }
violations() { [[ -f "${FAKE_GH}/violations.log" ]] && cat "${FAKE_GH}/violations.log"; }
mutations()  { count '^gh release (create|upload|delete-asset|edit)' "${FAKE_GH}/calls.log"; }
expect_refused() { # expect_refused <label> <message fragment> [args…] — and nothing may be built or mutated
    local label="$1" frag="$2"; shift 2
    local p0 m0; p0="$(packs)"; m0="$(mutations)"
    run "$@"
    if [[ ${RC} -ne 0 && "${OUT}" == *"REFUSED"*"${frag}"* && "$(packs)" == "${p0}" && "$(mutations)" == "${m0}" ]]; then ok "${label}"
    else bad "${label}: rc=${RC} packs ${p0}→$(packs) mutations ${m0}→$(mutations): $(echo "${OUT}" | tail -2)"; fi
}
published_matches_frozen() {
    local f="${SB}/artifacts/release-9.9.9" n
    for n in skia-pack-9.9.9-macos-arm64.tar.gz SkiaPack.xcframework.zip pack.json; do
        cmp -s "${f}/${n}" "${FAKE_GH}/assets/${n}" || return 1
    done
    local spm; spm="$(cd "${SB}" && swift package compute-checksum "${f}/SkiaPack.xcframework.zip")"
    git --git-dir="${FAKE_ORIGIN}" show 9.9.9:Package.swift | grep -q "checksum: \"${spm}\"" || return 1
    [[ "$(cat "${FAKE_GH}/state")" == published ]]
}

# ---- A. a new version, start to finish ------------------------------------------
new_sandbox A
run
if [[ ${RC} -eq 0 ]] && published_matches_frozen && [[ "$(packs)" == 1 ]] && [[ -z "$(violations)" ]] \
   && grep -q '^verify_consumer exact 9.9.9$' "${FAKE_GH}/build.log" \
   && [[ "$(git --git-dir="${FAKE_ORIGIN}" rev-parse 9.9.9^{commit})" == "$(git --git-dir="${FAKE_ORIGIN}" rev-parse main)" ]]; then
    ok "A  new release: packaged once, frozen bytes published, tag created at publish on the release commit"
else bad "A  new release: rc=${RC} packs=$(packs) $(violations) $(echo "${OUT}" | tail -3)"; fi
grep -q 'gh release create 9.9.9 --draft' "${FAKE_GH}/calls.log" && ok "A  release was created as a draft" || bad "A  not created as draft"

# ---- B. the same version again -----------------------------------------------------
expect_refused "B  plain re-run of a published version" "already exists"
expect_refused "B  --check reports the same refusal" "already exists" --check
# H. resume of an already complete release: read-only, changes nothing
m0="$(mutations)"; run --resume
[[ ${RC} -eq 0 && "$(mutations)" == "${m0}" && "$(packs)" == 1 ]] && published_matches_frozen \
    && ok "H  --resume on a complete release only re-verifies (no upload, no repackage)" || bad "H  rc=${RC} $(echo "${OUT}" | tail -2)"
# G. a published asset that is not the frozen bytes is reported, never repaired
echo "foreign bytes" > "${FAKE_GH}/assets/SkiaPack.xcframework.zip"
expect_refused "G  published asset differs from frozen → refused, nothing replaced" "published assets are never replaced" --resume
rm "${FAKE_GH}/assets/pack.json"
echo "zip bytes, packaging run 1" > "${FAKE_GH}/assets/SkiaPack.xcframework.zip"
expect_refused "G  published release missing an asset → refused, nothing uploaded" "nothing is uploaded to a published release" --resume
[[ -z "$(violations)" ]] && ok "G  no upload/delete/clobber ever reached the published release" || bad "G  $(violations)"

# ---- C. preflight guards ---------------------------------------------------------------
new_sandbox C
echo x > "${SB}/stray.txt"
expect_refused "C  dirty working tree" "working tree is not clean"
rm "${SB}/stray.txt"
( cd "${SB}" && git checkout -q -b side )
expect_refused "C  not on the release branch" "releases are cut from 'main'"
( cd "${SB}" && git checkout -q main && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m local-only )
expect_refused "C  HEAD not level with origin/main" "is not origin/main"
( cd "${SB}" && git reset -q --hard origin/main && git tag 9.9.9 )
expect_refused "C  stray local tag" "already exists locally"
( cd "${SB}" && git tag -d 9.9.9 >/dev/null && git push -q origin HEAD:refs/tags/9.9.9 ) 2>/dev/null
expect_refused "C  tag exists on origin" "already exists on origin"
( cd "${SB}" && git push -q origin :refs/tags/9.9.9 ) 2>/dev/null
echo draft > "${FAKE_GH}/state"; echo 7 > "${FAKE_GH}/id"; git --git-dir="${FAKE_ORIGIN}" rev-parse main > "${FAKE_GH}/target"
expect_refused "C  a draft release already exists" "draft GitHub release 9.9.9 already exists"
echo none > "${FAKE_GH}/state"
expect_refused "C  --resume with nothing frozen" "no frozen artifacts" --resume
run --check
[[ ${RC} -eq 0 && "$(packs)" == 0 ]] && ok "C  --check passes on a clean, fresh version and builds nothing" || bad "C  --check: rc=${RC} ${OUT}"
( cd "${SB}" && unset SKIA_PACK_RELEASE_CONFIRM; PATH="${FAKE_GH}/bin:${PATH}" SKIA_PACK_RELEASE_CONFIRM=0 ./scripts/release.sh >/dev/null 2>&1 ) \
    && bad "C  ran without SKIA_PACK_RELEASE_CONFIRM=1" || ok "C  refuses without SKIA_PACK_RELEASE_CONFIRM=1"

# ---- D. interrupted upload, then resume ----------------------------------------------------
new_sandbox D
touch "${FAKE_GH}/tear_next_upload" "${FAKE_GH}/fail_uploads"       # first upload lands torn, the rest fail
run
if [[ ${RC} -ne 0 && "$(cat "${FAKE_GH}/state")" == draft && -d "${SB}/artifacts/release-9.9.9" ]] \
   && ! git --git-dir="${FAKE_ORIGIN}" rev-parse -q --verify refs/tags/9.9.9 >/dev/null; then
    ok "D  failed upload stops before publish: draft only, no tag, artifacts frozen"
else bad "D  interrupted run: rc=${RC} state=$(cat "${FAKE_GH}/state") $(echo "${OUT}" | tail -2)"; fi
frozen_sums="$(cat "${SB}/artifacts/release-9.9.9/SHA256SUMS")"
# E. a plain re-run in this state must not repackage
expect_refused "E  plain re-run while a draft + frozen artifacts exist" "already exists"
rm "${FAKE_GH}/fail_uploads"
run --resume
if [[ ${RC} -eq 0 ]] && published_matches_frozen && [[ "$(packs)" == 1 ]] && [[ -z "$(violations)" ]] \
   && [[ "$(cat "${SB}/artifacts/release-9.9.9/SHA256SUMS")" == "${frozen_sums}" ]] \
   && grep -q 'gh release delete-asset 9.9.9' "${FAKE_GH}/calls.log"; then
    ok "D  --resume: torn DRAFT asset replaced, frozen bytes published, still packaged exactly once"
else bad "D  resume: rc=${RC} packs=$(packs) $(violations) $(echo "${OUT}" | tail -3)"; fi

# ---- F / I. frozen artifacts that are not the released ones ------------------------------------
new_sandbox F
touch "${FAKE_GH}/fail_uploads"; run; rm "${FAKE_GH}/fail_uploads"
chmod -R u+w "${SB}/artifacts/release-9.9.9"; echo tampered >> "${SB}/artifacts/release-9.9.9/SkiaPack.xcframework.zip"
expect_refused "F  --resume with a modified frozen asset" "do not match" --resume
# I. a self-consistent but DIFFERENT frozen set, with the version already public
new_sandbox I
run
chmod -R u+w "${SB}/artifacts/release-9.9.9"
( cd "${SB}/artifacts/release-9.9.9" && echo "zip bytes, some other build" > SkiaPack.xcframework.zip \
  && shasum -a 256 skia-pack-9.9.9-macos-arm64.tar.gz SkiaPack.xcframework.zip pack.json > SHA256SUMS )
expect_refused "I  --resume from artifacts this version was not cut from" "does not name the frozen zip" --resume

interrupted() { # a release stopped at a DRAFT with no assets; sets RELEASE_COMMIT
    new_sandbox "$1"; touch "${FAKE_GH}/fail_uploads"; run; rm "${FAKE_GH}/fail_uploads"
    RELEASE_COMMIT="$(sed -n 's/^release_commit=//p' "${SB}/artifacts/release-9.9.9.state")"
    [[ "$(cat "${FAKE_GH}/state")" == draft && -n "${RELEASE_COMMIT}" ]] || bad "$1 setup: not an interrupted draft"
}
no_tag() { ! git --git-dir="${FAKE_ORIGIN}" rev-parse -q --verify refs/tags/9.9.9 >/dev/null; }

# ---- J. main moved on between the interruption and the resume -----------------------------------
interrupted J
( cd "${SB}" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "unrelated later work" && git push -q origin main ) 2>/dev/null
expect_refused "J  --resume after main advanced: refused BEFORE publish" "is not the release commit" --resume
[[ "$(cat "${FAKE_GH}/state")" == draft ]] && no_tag && ok "J  still a draft, no tag — nothing became public" || bad "J  state=$(cat "${FAKE_GH}/state")"
( cd "${SB}" && git checkout -q --detach "${RELEASE_COMMIT}" )
run --resume
if [[ ${RC} -eq 0 ]] && published_matches_frozen && [[ "$(git --git-dir="${FAKE_ORIGIN}" rev-parse 9.9.9^{commit})" == "${RELEASE_COMMIT}" ]] \
   && [[ "$(git --git-dir="${FAKE_ORIGIN}" rev-parse main)" != "${RELEASE_COMMIT}" ]]; then
    ok "J  resumed from the recorded release commit: tag is on it, not on the newer main"
else bad "J  resume on release commit: rc=${RC} $(echo "${OUT}" | tail -2)"; fi

# ---- K. the draft targets some other commit ---------------------------------------------------------
interrupted K
git --git-dir="${FAKE_ORIGIN}" rev-parse main~1 > "${FAKE_GH}/target"        # an older commit, older Package.swift
expect_refused "K  draft targets a different commit: refused before upload/publish" "not the recorded release commit" --resume
[[ "$(cat "${FAKE_GH}/state")" == draft ]] && no_tag && ok "K  still a draft, no tag" || bad "K  state=$(cat "${FAKE_GH}/state")"

# ---- N. the draft was deleted and recreated by someone else -----------------------------------------
interrupted N
echo 999 > "${FAKE_GH}/id"
expect_refused "N  release id changed under us" "deleted and recreated" --resume

# ---- L. the draft gets published elsewhere while this run is working --------------------------------
interrupted L1
echo "torn" > "${FAKE_GH}/assets/skia-pack-9.9.9-macos-arm64.tar.gz"                                # the draft holds one torn asset
touch "${FAKE_GH}/publish_on_download"            # published by another session during our read-back of it
expect_refused "L  published during a download: the torn asset is NOT deleted, nothing uploaded" "no longer a draft" --resume
[[ -z "$(violations)" ]] && ok "L  no delete/upload reached the now-published release" || bad "L  $(violations)"
interrupted L2
echo 4 > "${FAKE_GH}/publish_after_views"         # published by another session just before our first upload
expect_refused "L  published between two of our checks: nothing uploaded" "no longer a draft" --resume
[[ -z "$(violations)" ]] && ok "L  no upload reached the now-published release" || bad "L  $(violations)"

# ---- M. a failed query is not "no release" -------------------------------------------------------------
interrupted M
touch "${FAKE_GH}/fail_view"
expect_refused "M  HTTP 503 on the release query: --check refuses" "could not determine the state" --check
expect_refused "M  HTTP 503: a plain run refuses" "could not determine the state"
expect_refused "M  HTTP 503: --resume refuses" "could not determine the state" --resume
rm "${FAKE_GH}/fail_view"
new_sandbox M2
git init -q --bare "${ROOT}/elsewhere.git"; ( cd "${SB}" && git remote set-url origin "${ROOT}/missing.git" )
run --check
[[ ${RC} -ne 0 && "$(packs)" == 0 ]] && ok "M  unreachable origin: refuses (a failed fetch/ls-remote is not 'no tag')" || bad "M  unreachable origin: rc=${RC} ${OUT}"

# ---- O. one release run at a time on this machine --------------------------------------------------------
new_sandbox O
L="${SB}/artifacts/release-9.9.9.lock"
mkdir -p "${L}"                                    # the window: another run did mkdir, has not written its pid yet
expect_refused "O  lock with NO pid yet (the other run's init window): refused, not taken over" "release lock for 9.9.9 already exists"
[[ -d "${L}" && ! -e "${L}/pid" ]] && ok "O  the other run's lock was left exactly as it was" || bad "O  lock was disturbed"
echo $$ > "${L}/pid"
expect_refused "O  lock held by a live pid" "release lock for 9.9.9 already exists"
echo 999999 > "${L}/pid"
expect_refused "O  lock naming a dead pid: still refused (no automatic takeover)" "release lock for 9.9.9 already exists"
[[ "$(cat "${L}/pid")" == 999999 ]] && ok "O  a refused run does not remove a lock it does not own" || bad "O  foreign lock removed"
expect_refused "O  --resume honours the lock too" "release lock for 9.9.9 already exists" --resume
run --check
[[ ${RC} -eq 0 ]] && ok "O  --check is read-only and does not need the lock" || bad "O  --check under lock: rc=${RC} ${OUT}"
rm -rf "${L}"                                      # the human-confirmed cleanup
run
[[ ${RC} -eq 0 ]] && published_matches_frozen && [[ ! -e "${L}" ]] \
    && ok "O  after manual cleanup the release runs, and releases its own lock at exit" || bad "O  after cleanup: rc=${RC} $(echo "${OUT}" | tail -2)"
# a refused preflight must release the lock it took
expect_refused "O  (setup) re-run of the published version" "already exists"
[[ ! -e "${L}" ]] && ok "O  a run refused in preflight releases its own lock" || bad "O  lock leaked after a refusal"

# ---- Q. a same-named tag appears AFTER the preflight ----------------------------------------------------
interrupted Q
echo "torn" > "${FAKE_GH}/assets/pack.json"        # forces a read-back download, during which the tag is planted
git --git-dir="${FAKE_ORIGIN}" rev-parse main~1 > "${FAKE_GH}/plant_tag_on_download"
e0="$(count '^gh release edit' "${FAKE_GH}/calls.log")"
run --resume
if [[ ${RC} -ne 0 && "${OUT}" == *"REFUSED"*"appeared on origin"*"NOT published"* && "$(cat "${FAKE_GH}/state")" == draft ]] \
   && [[ "$(count '^gh release edit' "${FAKE_GH}/calls.log")" == "${e0}" ]]; then
    ok "Q  tag planted after preflight (at an older commit): refused BEFORE publish, still a draft"
else bad "Q  late tag: rc=${RC} state=$(cat "${FAKE_GH}/state") $(echo "${OUT}" | tail -2)"; fi
interrupted Q2
# the tag lookup itself failing right before publish must stop too: make ls-remote fail after preflight
cat > "${FAKE_GH}/bin/git" <<'GITWRAP'
#!/usr/bin/env bash
real="$(PATH="${PATH#*:}" command -v git)"
if [[ "$1" == "ls-remote" ]]; then
    n=$(( $(cat "$FAKE_GH/lsremote_calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_GH/lsremote_calls"
    (( n >= 2 )) && { echo "fatal: unable to access origin: Could not resolve host" >&2; exit 128; }
fi
exec "$real" "$@"
GITWRAP
chmod +x "${FAKE_GH}/bin/git"
e0="$(count '^gh release edit' "${FAKE_GH}/calls.log")"
run --resume
if [[ ${RC} -ne 0 && "${OUT}" == *"could not list tags on origin"* && "$(cat "${FAKE_GH}/state")" == draft ]] \
   && [[ "$(count '^gh release edit' "${FAKE_GH}/calls.log")" == "${e0}" ]]; then
    ok "Q  tag lookup fails right before publish: refused, still a draft"
else bad "Q  failed late lookup: rc=${RC} state=$(cat "${FAKE_GH}/state") $(echo "${OUT}" | tail -2)"; fi
rm -f "${FAKE_GH}/bin/git"

# ---- R. two real runs started at the same moment --------------------------------------------------------
new_sandbox R
race() { ( cd "${SB}" && PATH="${FAKE_GH}/bin:${PATH}" SKIA_PACK_RELEASE_CONFIRM=1 SKIA_PACK_RELEASE_RETRY_SLEEP=0 \
           GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
           ./scripts/release.sh > "${ROOT}/race-$1.out" 2>&1; echo $? > "${ROOT}/race-$1.rc" ); }
race 1 & race 2 & wait
rcs="$(cat "${ROOT}/race-1.rc" "${ROOT}/race-2.rc" | sort | tr '\n' ' ')"
locked="$(cat "${ROOT}/race-1.out" "${ROOT}/race-2.out" | grep -c 'release lock for 9.9.9 already exists' || true)"
if [[ "${rcs}" == "0 1 " && "${locked}" == 1 && "$(packs)" == 1 ]] && published_matches_frozen && [[ -z "$(violations)" ]]; then
    ok "R  two simultaneous runs: exactly one releases (packaged once), the other is refused by the lock"
else bad "R  race: rcs='${rcs}' lock refusals=${locked} packs=$(packs)"; fi

# ---- P. verifying the published release must not disturb the frozen set ---------------------------------
# (same sandbox: a finished release with artifacts/ and artifacts/release-9.9.9/ in place)
cp "${PACK_ROOT}/scripts/verify_published.sh" "${SB}/scripts/"
printf '#!/usr/bin/env bash\necho "verify dir=${SKIA_PACK_VERIFY_ARTIFACTS_DIR:-UNSET}" >> "$FAKE_GH/build.log"\n' > "${SB}/scripts/verify.sh"
before="$(cd "${SB}/artifacts" && find . -type f | sort | xargs shasum -a 256)"
OUT="$( cd "${SB}" && PATH="${FAKE_GH}/bin:${PATH}" ./scripts/verify_published.sh 9.9.9 2>&1 )"; RC=$?
after="$(cd "${SB}/artifacts" && find . -type f | sort | xargs shasum -a 256)"
if [[ ${RC} -eq 0 && "${before}" == "${after}" ]] && ( cd "${SB}/artifacts/release-9.9.9" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ) \
   && grep -q "^verify dir=.*/build/verify-published/9.9.9$" "${FAKE_GH}/build.log"; then
    ok "P  verify_published: artifacts/ and the frozen set untouched; the gate read the downloaded copy"
else bad "P  verify_published: rc=${RC} changed=$([[ "${before}" == "${after}" ]] && echo no || echo YES) $(echo "${OUT}" | tail -2)"; fi
echo "foreign" > "${FAKE_GH}/assets/SkiaPack.xcframework.zip"
OUT="$( cd "${SB}" && PATH="${FAKE_GH}/bin:${PATH}" ./scripts/verify_published.sh 9.9.9 2>&1 )"; RC=$?
[[ ${RC} -ne 0 && "${OUT}" == *"Package.swift checksum does not match"* ]] && ok "P  verify_published: a published zip that is not the committed checksum fails" || bad "P  tampered published zip: rc=${RC}"

echo
if [[ ${failures} -eq 0 ]]; then echo "[test_release] ALL CASES PASSED"; else echo "[test_release] ${failures} CASE(S) WRONG"; fi
exit $(( failures > 0 ))
