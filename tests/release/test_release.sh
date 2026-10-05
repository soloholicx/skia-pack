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
printf '{"artifacts":{"xcframework":{"spm_checksum":"%s"}}}\n' "$(swift package compute-checksum artifacts/SkiaPack.xcframework.zip)" > artifacts/pack.json
STUB
    chmod +x "${SB}/scripts/"*.sh
    git init -q --bare "${FAKE_ORIGIN}"
    ( cd "${SB}" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base \
      && git remote add origin "${FAKE_ORIGIN}" && git push -q origin main ) >/dev/null 2>&1
}
run() { # run <args…> → sets RC, OUT
    OUT="$( cd "${SB}" && PATH="${FAKE_GH}/bin:${PATH}" SKIA_PACK_RELEASE_CONFIRM=1 \
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
echo draft > "${FAKE_GH}/state"
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
expect_refused "I  --resume from artifacts this version was not cut from" "not the ones this version was cut from" --resume

echo
if [[ ${failures} -eq 0 ]]; then echo "[test_release] ALL CASES PASSED"; else echo "[test_release] ${failures} CASE(S) WRONG"; fi
exit $(( failures > 0 ))
