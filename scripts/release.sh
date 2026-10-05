#!/usr/bin/env bash
# Release flow (architecture doc §8) — solves the URL/checksum chicken-and-egg
# without ever letting a published version change underneath its consumers.
#
# NOT part of the local build/verify loop. This script publishes a release to
# GitHub; it must only be run deliberately, by a human. It refuses to run
# unless SKIA_PACK_RELEASE_CONFIRM=1 is set.
#
#   release.sh             a NEW version, start to finish
#   release.sh --resume    continue an interrupted release from its FROZEN
#                          artifacts — never rebuilds, never repackages
#   release.sh --check     run the preflight guards for a new release and stop
#   release.sh --check --resume   …for a resume
#
# The invariant: the bytes are packaged ONCE, verified, frozen, and those
# exact bytes are what the committed checksum names and what gets uploaded.
#
#   0. preflight      clean tree, on main, level with origin/main; the version
#                     has no tag (local or remote), no GitHub release (draft
#                     or published) and no frozen artifacts. An existing
#                     version is REFUSED — a plain re-run can only ever be a
#                     mistake (it would mint new bytes for an old checksum).
#   1. build + package + verify + consumer check     (once)
#   2. freeze         copy the three assets + SHA256SUMS to
#                     artifacts/release-<version>/ (read-only). Everything
#                     after this point reads ONLY from there.
#   3. commit         release URL + spm checksum of the frozen zip into
#                     Package.swift; push main. No tag yet.
#   4. draft release  targeting that commit; upload the frozen assets;
#                     download every asset back and compare sha256.
#   5. publish        only when all three assets match. Publishing is what
#                     creates the tag (== version string), so consumers can
#                     never resolve a tag whose asset is not there yet, and an
#                     aborted release leaves no tag behind.
#   6. post-verify    scripts/verify_consumer.sh exact <version> against the
#                     published product (.github/workflows/release.yml repeats
#                     the read-only verification on a clean runner).
#
# If anything fails after step 2: fix the cause and run `release.sh --resume`.
# Resume re-checks the frozen bytes against SHA256SUMS and against the
# checksum committed in Package.swift, then picks up at the first unfinished
# step. Assets are replaced only while the release is still a DRAFT (nobody
# can have consumed a draft); once published, nothing is ever uploaded,
# replaced or deleted — a mismatch there is reported and left alone.
# A published release is immutable: a botched one is rolled forward as a PATCH.
#
# What the script holds on to between steps (artifacts/release-<version>.state):
# the release COMMIT and the GitHub release ID. A resume must be standing on
# that commit, and the draft it continues must be that release, still a draft,
# still targeting that commit — all checked BEFORE anything is uploaded or
# published, and re-checked immediately before every single mutation. A failed
# query is never read as "no release": anything but a definite answer stops.
#
# Limits, stated plainly. artifacts/release-<version>.lock keeps two runs on
# THIS machine apart (an existing lock is always refused, never taken over). Against another machine or a click in the web UI, the
# re-check narrows the window to one API call but cannot close it — only
# GitHub's server-side "immutable releases" repository setting makes a
# published release unmodifiable. Enable it for this repo.
#
# Needs a booted iOS simulator (SKIA_PACK_SIM_UDID=<udid>, else any booted
# device): verify.sh runs the simulator slice's smoke test inside it.
set -euo pipefail

MODE="new"; CHECK_ONLY=0
for arg in "$@"; do
    case "${arg}" in
        --resume) MODE="resume" ;;
        --check)  CHECK_ONLY=1 ;;
        *) echo "usage: release.sh [--resume] [--check]" >&2; exit 2 ;;
    esac
done

if [[ "${CHECK_ONLY}" == "0" && "${SKIA_PACK_RELEASE_CONFIRM:-0}" != "1" ]]; then
    echo "release.sh publishes a GitHub release (push + upload + tag)." >&2
    echo "Set SKIA_PACK_RELEASE_CONFIRM=1 to confirm you intend to release." >&2
    exit 1
fi

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${PACK_ROOT}/VERSION")"
ARTIFACTS="${PACK_ROOT}/artifacts"
FROZEN="${ARTIFACTS}/release-${VERSION}"
ASSETS=("skia-pack-${VERSION}-macos-arm64.tar.gz" "SkiaPack.xcframework.zip" "pack.json")
REPO_URL="https://github.com/soloholicx/skia-pack"
RELEASE_URL="${REPO_URL}/releases/download/${VERSION}/SkiaPack.xcframework.zip"
RELEASE_BRANCH="main"

cd "${PACK_ROOT}"
refuse() { echo "release: REFUSED — $*" >&2; exit 1; }
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# query_release — one authoritative read of the release. Sets:
#   REL_STATE none|draft|published · REL_ID · REL_TARGET · REL_ASSETS (comma list)
# "none" ONLY when GitHub positively answered "release not found". A network,
# auth, permission or server error is not an answer and stops the script.
query_release() {
    local out err rc=0
    err="$(mktemp "${TMPDIR:-/tmp}/skia-pack-gh.XXXXXX")"
    out="$(gh release view "${VERSION}" --json databaseId,isDraft,targetCommitish,assets \
              --jq '[.databaseId, .isDraft, .targetCommitish, ([.assets[].name] | join(","))] | map(tostring) | join("|")' 2>"${err}")" || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        if grep -qi '^release not found' "${err}"; then
            rm -f "${err}"
            REL_STATE=none; REL_ID=""; REL_TARGET=""; REL_ASSETS=""
            return 0
        fi
        local why; why="$(tr '\n' ' ' < "${err}")"; rm -f "${err}"
        refuse "could not determine the state of release ${VERSION} (gh exit ${rc}: ${why:-no message}) — not assuming it does not exist"
    fi
    rm -f "${err}"
    local draft
    # '|' (not a tab): tab is IFS whitespace, so an empty field would silently shift the rest.
    IFS='|' read -r REL_ID draft REL_TARGET REL_ASSETS <<< "${out}"
    [[ "${REL_ID}" =~ ^[0-9]+$ && -n "${REL_TARGET}" && ( "${draft}" == "true" || "${draft}" == "false" ) ]] \
        || refuse "unintelligible answer for release ${VERSION}: '${out}'"
    [[ "${draft}" == "true" ]] && REL_STATE=draft || REL_STATE=published
}
has_asset() { [[ ",${REL_ASSETS}," == *",$1,"* ]]; }
STATE_FILE="${ARTIFACTS}/release-${VERSION}.state"
state_get() { [[ -f "${STATE_FILE}" ]] && sed -n "s/^$1=//p" "${STATE_FILE}" | tail -1 || true; }
state_set() { mkdir -p "${ARTIFACTS}"; echo "$1=$2" >> "${STATE_FILE}"; }
remote_tag_commit() { # peeled commit of the remote tag, empty if the tag does not exist
    local out
    out="$(git ls-remote --tags origin "refs/tags/${VERSION}" "refs/tags/${VERSION}^{}")" \
        || refuse "could not list tags on origin — not assuming tag ${VERSION} does not exist"
    awk 'END{print $1}' <<< "${out}"
}
manifest_field() { # url | checksum as committed in Package.swift
    sed -n "s/.*$1: \"\\([^\"]*\\)\".*/\\1/p" Package.swift | head -1
}
verify_frozen() {
    [[ -f "${FROZEN}/SHA256SUMS" ]] || refuse "no frozen artifacts at ${FROZEN}"
    local name
    for name in "${ASSETS[@]}"; do
        [[ -f "${FROZEN}/${name}" ]] || refuse "frozen asset missing: ${name}"
    done
    (cd "${FROZEN}" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) \
        || refuse "frozen artifacts do not match ${FROZEN}/SHA256SUMS — they were modified after the freeze; this version cannot be released from them"
}

# ------------------------------------------------------------------ lock ----
# One release run per machine at a time, taken BEFORE the authoritative
# preflight so two runs can never both pass it. An existing lock is refused
# whatever it contains — including a lock whose pid file is still empty
# (another run is between its mkdir and its write) or names a dead process.
# Nothing is taken over automatically: a stale lock is removed by a human who
# has confirmed no release is running. Only the run that created the lock
# removes it.
LOCK="${ARTIFACTS}/release-${VERSION}.lock"
LOCK_OWNED=0
scratch=""
cleanup() {
    [[ -n "${scratch}" ]] && rm -rf "${scratch}"
    if [[ "${LOCK_OWNED}" == "1" && "$(cat "${LOCK}/pid" 2>/dev/null)" == "$$" ]]; then rm -rf "${LOCK}"; fi
}
trap cleanup EXIT
if [[ "${CHECK_ONLY}" == "0" ]]; then
    mkdir -p "${ARTIFACTS}"
    mkdir "${LOCK}" 2>/dev/null \
        || refuse "a release lock for ${VERSION} already exists (${LOCK}, pid '$(cat "${LOCK}/pid" 2>/dev/null || true)') — another release.sh is running or died; remove the lock by hand only after confirming none is running"
    LOCK_OWNED=1
    echo $$ > "${LOCK}/pid"
fi

# ------------------------------------------------------------ 0. preflight ----
[[ -z "$(git status --porcelain)" ]] || refuse "working tree is not clean (commit or stash first)"
branch="$(git rev-parse --abbrev-ref HEAD)"
git fetch --quiet origin "${RELEASE_BRANCH}" || refuse "could not fetch origin/${RELEASE_BRANCH}"
head_commit="$(git rev-parse HEAD)"
origin_commit="$(git rev-parse "origin/${RELEASE_BRANCH}")"
query_release
state="${REL_STATE}"
tag_commit="$(remote_tag_commit)"
recorded_commit="$(state_get release_commit)"
recorded_id="$(state_get release_id)"

if [[ "${MODE}" == "new" ]]; then
    [[ "${branch}" == "${RELEASE_BRANCH}" ]] || refuse "on branch '${branch}', releases are cut from '${RELEASE_BRANCH}'"
    [[ "${head_commit}" == "${origin_commit}" ]] \
        || refuse "HEAD ${head_commit:0:7} is not origin/${RELEASE_BRANCH} ${origin_commit:0:7} (pull/push first)"
    [[ -z "${tag_commit}" ]] || refuse "tag ${VERSION} already exists on origin — a published version is immutable; bump VERSION"
    git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null \
        && refuse "tag ${VERSION} already exists locally — bump VERSION, or delete the stray local tag if it was never pushed"
    [[ "${state}" == "none" ]] \
        || refuse "a ${state} GitHub release ${VERSION} already exists — to continue an interrupted release use --resume; otherwise bump VERSION"
    [[ ! -e "${FROZEN}" && ! -e "${STATE_FILE}" ]] \
        || refuse "frozen artifacts for ${VERSION} already exist at ${FROZEN} — use --resume to continue that release; delete them only if you are certain nothing was ever uploaded"
else
    verify_frozen
    frozen_spm="$(swift package compute-checksum "${FROZEN}/SkiaPack.xcframework.zip")"
    committed_spm="$(manifest_field checksum)"
    if [[ -n "${recorded_commit}" ]]; then
        # The release commit exists. A resume must stand exactly on it: if main
        # moved on, HEAD is some other commit and must not become the release.
        [[ "${head_commit}" == "${recorded_commit}" ]] \
            || refuse "HEAD ${head_commit:0:7} is not the release commit ${recorded_commit:0:7} recorded for ${VERSION} — check that commit out (git checkout --detach ${recorded_commit:0:7}) and resume from there"
        [[ "${committed_spm}" == "${frozen_spm}" && "$(manifest_field url)" == "${RELEASE_URL}" ]] \
            || refuse "the recorded release commit's Package.swift does not name the frozen zip (${frozen_spm:0:12}…)"
        if [[ "${branch}" != "${RELEASE_BRANCH}" ]]; then
            # Detached on the release commit is fine once that commit is on origin/main.
            git merge-base --is-ancestor "${recorded_commit}" "${origin_commit}" \
                || refuse "on '${branch}', and the release commit ${recorded_commit:0:7} is not on origin/${RELEASE_BRANCH}"
        fi
        manifest_resolved=1
    else
        # Interrupted between freeze and commit: nothing of this version may be public yet.
        [[ "${branch}" == "${RELEASE_BRANCH}" ]] || refuse "on branch '${branch}', releases are cut from '${RELEASE_BRANCH}'"
        [[ "${head_commit}" == "${origin_commit}" ]] \
            || refuse "no release commit is recorded for ${VERSION}, and HEAD ${head_commit:0:7} is not origin/${RELEASE_BRANCH} ${origin_commit:0:7}"
        [[ -z "${tag_commit}" && "${state}" == "none" ]] \
            || refuse "a tag or release for ${VERSION} exists but no release commit is recorded here (${STATE_FILE}) — these frozen artifacts are not the ones this version was cut from"
        [[ "${committed_spm}" != "${frozen_spm}" ]] \
            || refuse "Package.swift already names the frozen zip but no release commit is recorded (a run died between commit and record). If HEAD ${head_commit:0:7} IS that release commit, record it: echo release_commit=${head_commit} >> ${STATE_FILE}"
        manifest_resolved=0
    fi
    if [[ "${state}" != "none" ]]; then
        # The release this resume would continue must be THE one this version was cut as.
        [[ "${REL_TARGET}" == "${recorded_commit}" ]] \
            || refuse "the ${state} release ${VERSION} targets ${REL_TARGET:0:12}, not the recorded release commit ${recorded_commit:0:7} — nothing uploaded, nothing published"
        [[ -z "${recorded_id}" || "${REL_ID}" == "${recorded_id}" ]] \
            || refuse "release ${VERSION} is now id ${REL_ID}, this release was created as id ${recorded_id} — it was deleted and recreated by someone else"
    fi
    if [[ -n "${tag_commit}" ]]; then
        [[ "${state}" == "published" ]] || refuse "tag ${VERSION} exists on origin but the release is '${state}' — inconsistent, resolve by hand"
        [[ "${tag_commit}" == "${recorded_commit}" ]] || refuse "tag ${VERSION} points at ${tag_commit:0:7}, not the release commit ${recorded_commit:0:7}"
    fi
fi
echo "[release] preflight OK (${MODE}): version ${VERSION}, HEAD ${head_commit:0:7}, release state ${state}"
if [[ "${CHECK_ONLY}" == "1" ]]; then exit 0; fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/skia-pack-release.XXXXXX")"

# ------------------------------------- 1. build, package (once), verify -------
if [[ "${MODE}" == "new" ]]; then
    # The macOS slice is rebuilt only when pins.json does not reuse a base
    # release (see pins.json "macos_base").
    if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('pins.json')).get('macos_base') else 1)"; then
        ./scripts/build.sh macos-arm64
    fi
    ./scripts/build.sh ios-arm64
    ./scripts/build.sh ios-arm64-simulator
    ./scripts/package.sh
    ./scripts/verify.sh
    ./scripts/verify_consumer.sh local

    # ----------------------------------------------------------- 2. freeze ----
    [[ -z "$(git status --porcelain)" ]] || refuse "the build dirtied the working tree"
    mkdir -p "${FROZEN}"
    for name in "${ASSETS[@]}"; do
        cp "${ARTIFACTS}/${name}" "${FROZEN}/${name}"
        cmp -s "${ARTIFACTS}/${name}" "${FROZEN}/${name}" || refuse "freeze copy of ${name} differs"
    done
    (cd "${FROZEN}" && shasum -a 256 "${ASSETS[@]}" > SHA256SUMS)
    chmod -R a-w "${FROZEN}"
    echo "[release] frozen: ${FROZEN}"
    sed 's/^/[release]   /' "${FROZEN}/SHA256SUMS"
    manifest_resolved=0
fi
verify_frozen

# ---------------------------------------------- 3. commit the frozen checksum ----
spm_checksum="$(swift package compute-checksum "${FROZEN}/SkiaPack.xcframework.zip")"
recorded_spm="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['artifacts']['xcframework']['spm_checksum'])" "${FROZEN}/pack.json")"
[[ "${spm_checksum}" == "${recorded_spm}" ]] || refuse "frozen pack.json records spm checksum ${recorded_spm:0:12}… but the frozen zip is ${spm_checksum:0:12}…"
if [[ "${manifest_resolved}" == "0" ]]; then
    python3 - "${PACK_ROOT}/Package.swift" "${RELEASE_URL}" "${spm_checksum}" <<'PY'
import pathlib, re, sys
path, url, checksum = sys.argv[1:4]
manifest = pathlib.Path(path)
text = manifest.read_text()
text, n_url = re.subn(r'url: "[^"]*"', f'url: "{url}"', text, count=1)
text, n_sum = re.subn(r'checksum: "[^"]*"', f'checksum: "{checksum}"', text, count=1)
assert n_url == 1 and n_sum == 1, "Package.swift url/checksum lines not found"
manifest.write_text(text)
PY
    git add Package.swift
    git commit -m "release: v${VERSION} — resolve binaryTarget url + checksum"
    state_set release_commit "$(git rev-parse HEAD)"
    echo "[release] Package.swift → url=${RELEASE_URL} checksum=${spm_checksum}"
fi
release_commit="$(state_get release_commit)"
[[ "$(git rev-parse HEAD)" == "${release_commit}" ]] || refuse "HEAD is not the recorded release commit ${release_commit:0:7}"
if ! git merge-base --is-ancestor "${release_commit}" "$(git rev-parse "origin/${RELEASE_BRANCH}")"; then
    git push origin "${release_commit}:refs/heads/${RELEASE_BRANCH}"
fi

# ------------------------------------------- 4. draft release + frozen assets ----
query_release
if [[ "${REL_STATE}" == "none" ]]; then
    # --target pins the commit the tag will be created at when the draft is
    # published; no tag exists until then.
    gh release create "${VERSION}" --draft --target "${release_commit}" \
        --title "skia-pack ${VERSION}" \
        --notes "Prebuilt Skia m150 (@$(sed -n 's/.*"commit": "\([0-9a-f]\{7\}\).*/\1/p' pins.json | head -1)) + HarfBuzz 14.2.0 static artifacts: macOS arm64 (tarball + xcframework slice), iOS arm64 and iOS Simulator arm64 (xcframework slices; simulator on Apple Silicon hosts only). See pack.json for the full manifest."
    query_release
    [[ "${REL_STATE}" == "draft" ]] || refuse "the release just created is '${REL_STATE}', expected a draft"
    state_set release_id "${REL_ID}"
fi
BOUND_ID="$(state_get release_id)"
if [[ -z "${BOUND_ID}" ]]; then        # a draft made by a run that died before recording its id
    BOUND_ID="${REL_ID}"; state_set release_id "${BOUND_ID}"
fi
ENTRY_STATE="${REL_STATE}"

# The release must be the bound one and target the release commit — in either state.
check_bound() {
    [[ "${REL_STATE}" != "none" ]] || refuse "release ${VERSION} disappeared (it was id ${BOUND_ID})"
    [[ "${REL_ID}" == "${BOUND_ID}" ]] || refuse "release ${VERSION} is now id ${REL_ID}, not the bound id ${BOUND_ID} — it was replaced by someone else"
    [[ "${REL_TARGET}" == "${release_commit}" ]] \
        || refuse "release ${VERSION} targets ${REL_TARGET:0:12}, not the release commit ${release_commit:0:7}"
}
# Called immediately before EVERY mutation: a fresh read, and it must still be our draft.
require_draft() {
    query_release
    check_bound
    [[ "${REL_STATE}" == "draft" ]] \
        || refuse "release ${VERSION} is no longer a draft (published elsewhere while this run was working) — not touching it: $1"
}
remote_sha() { # sha256 of a LISTED asset as GitHub serves it; a failed download is an error, not "absent"
    local name="$1" dir="${scratch}/dl-$RANDOM"
    mkdir -p "${dir}"
    gh release download "${VERSION}" --pattern "${name}" --dir "${dir}" >/dev/null 2>&1 && [[ -f "${dir}/${name}" ]] \
        || refuse "asset ${name} is listed on release ${VERSION} but could not be downloaded — not assuming anything about it"
    sha_of "${dir}/${name}"
    rm -rf "${dir}"
}
query_release; check_bound

if [[ "${ENTRY_STATE}" == "published" ]]; then
    # Already public: read-only from here on. Report, never repair.
    for name in "${ASSETS[@]}"; do
        has_asset "${name}" || refuse "PUBLISHED release ${VERSION} is missing asset ${name} — nothing is uploaded to a published release; roll forward with a PATCH"
        got="$(remote_sha "${name}")"; want="$(sha_of "${FROZEN}/${name}")"
        [[ "${got}" == "${want}" ]] \
            || refuse "PUBLISHED asset ${name} is ${got:0:12}…, frozen is ${want:0:12}… — published assets are never replaced; this version is burnt, roll forward with a PATCH"
    done
else
    upload_asset() {
        local name="$1" want got attempt
        want="$(sha_of "${FROZEN}/${name}")"
        for attempt in 1 2 3; do
            require_draft "checking ${name}"
            if has_asset "${name}"; then
                got="$(remote_sha "${name}")"
                if [[ "${got}" == "${want}" ]]; then
                    echo "[release] asset ok: ${name}"
                    return 0
                fi
                # A torn upload (or a foreign file) on OUR DRAFT. The download above took
                # time: confirm it is still our draft right before deleting.
                echo "[release] draft asset ${name} has wrong bytes (${got:0:12}…) — deleting it from the draft" >&2
                require_draft "deleting ${name}"
                gh release delete-asset "${VERSION}" "${name}" --yes
            fi
            require_draft "uploading ${name}"
            # No --clobber anywhere: the only deletion is the explicit draft-only one above.
            if (( attempt < 3 )); then
                gh release upload "${VERSION}" "${FROZEN}/${name}" \
                    || { echo "[release] upload failed (attempt ${attempt}): ${name}" >&2; sleep "${SKIA_PACK_RELEASE_RETRY_SLEEP:-5}"; }
            else
                # Last resort: raw upload with explicit octet-stream, addressed to the BOUND
                # release id. Observed in the wild: a proxy EOF-kills sniffed-content-type
                # uploads of small .json assets while binary zips sail through.
                echo "[release] falling back to raw octet-stream upload: ${name}" >&2
                gh api --method POST -H "Content-Type: application/octet-stream" \
                    "https://uploads.github.com/repos/${REPO_URL#https://github.com/}/releases/${BOUND_ID}/assets?name=${name}" \
                    --input "${FROZEN}/${name}" >/dev/null || echo "[release] raw upload failed: ${name}" >&2
            fi
        done
        require_draft "final check of ${name}"
        has_asset "${name}" && [[ "$(remote_sha "${name}")" == "${want}" ]] && { echo "[release] asset ok: ${name}"; return 0; }
        refuse "could not get ${name} onto the draft with the frozen bytes — fix the cause and run release.sh --resume"
    }
    for name in "${ASSETS[@]}"; do upload_asset "${name}"; done
    # Final read-back of all three before anything becomes public.
    require_draft "final read-back"
    for name in "${ASSETS[@]}"; do
        has_asset "${name}" && [[ "$(remote_sha "${name}")" == "$(sha_of "${FROZEN}/${name}")" ]] \
            || refuse "read-back of ${name} does not match the frozen bytes"
    done
fi
echo "[release] all ${#ASSETS[@]} assets on the release match the frozen bytes"

# --------------------------------------------------------------- 5. publish ----
if [[ "${ENTRY_STATE}" != "published" ]]; then
    # Publishing creates the tag at the draft's target ONLY if no such tag exists;
    # an existing tag wins and target_commitish is ignored. So the tag must still
    # be absent right now (the preflight answer may be stale), and a failed lookup
    # is not "absent". What remains is the single API call between this check and
    # the publish — not closable from here; the post-publish check below reports it.
    late_tag="$(remote_tag_commit)"
    [[ -z "${late_tag}" ]] \
        || refuse "tag ${VERSION} appeared on origin (→ ${late_tag:0:7}) after the preflight — publishing would adopt it instead of tagging the release commit ${release_commit:0:7}; NOT published"
    require_draft "publishing"          # still ours, still a draft, still targeting the release commit
    gh release edit "${VERSION}" --draft=false
    echo "[release] published ${VERSION}"
fi
git fetch --quiet origin "refs/tags/${VERSION}:refs/tags/${VERSION}"
tagged="$(git rev-parse "${VERSION}^{commit}")"
[[ "${tagged}" == "${release_commit}" ]] \
    || refuse "published tag ${VERSION} points at ${tagged:0:7}, expected the release commit ${release_commit:0:7}"

# ----------------------------------------------------------- 6. post-verify ----
./scripts/verify_consumer.sh exact "${VERSION}"

echo "[release] ${VERSION} released and post-verified (tag ${VERSION} → ${release_commit:0:7})"
