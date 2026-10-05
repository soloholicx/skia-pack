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

# none | draft | published
release_state() {
    local draft
    if ! draft="$(gh release view "${VERSION}" --json isDraft --jq .isDraft 2>/dev/null)"; then
        echo none; return
    fi
    [[ "${draft}" == "true" ]] && echo draft || echo published
}
remote_tag_commit() { # peeled commit of the remote tag, empty if the tag does not exist
    git ls-remote --tags origin "refs/tags/${VERSION}" "refs/tags/${VERSION}^{}" | awk 'END{print $1}'
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

# ------------------------------------------------------------ 0. preflight ----
[[ -z "$(git status --porcelain)" ]] || refuse "working tree is not clean (commit or stash first)"
branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "${branch}" == "${RELEASE_BRANCH}" ]] || refuse "on branch '${branch}', releases are cut from '${RELEASE_BRANCH}'"
git fetch --quiet origin "${RELEASE_BRANCH}"
head_commit="$(git rev-parse HEAD)"
origin_commit="$(git rev-parse "origin/${RELEASE_BRANCH}")"
state="$(release_state)"
tag_commit="$(remote_tag_commit)"

if [[ "${MODE}" == "new" ]]; then
    [[ "${head_commit}" == "${origin_commit}" ]] \
        || refuse "HEAD ${head_commit:0:7} is not origin/${RELEASE_BRANCH} ${origin_commit:0:7} (pull/push first)"
    [[ -z "${tag_commit}" ]] || refuse "tag ${VERSION} already exists on origin — a published version is immutable; bump VERSION"
    git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null \
        && refuse "tag ${VERSION} already exists locally — bump VERSION, or delete the stray local tag if it was never pushed"
    [[ "${state}" == "none" ]] \
        || refuse "a ${state} GitHub release ${VERSION} already exists — to continue an interrupted release use --resume; otherwise bump VERSION"
    [[ ! -e "${FROZEN}" ]] \
        || refuse "frozen artifacts for ${VERSION} already exist at ${FROZEN} — use --resume to continue that release; delete the directory only if you are certain it was never uploaded"
else
    verify_frozen
    git merge-base --is-ancestor "${origin_commit}" "${head_commit}" \
        || refuse "origin/${RELEASE_BRANCH} ${origin_commit:0:7} is not an ancestor of HEAD ${head_commit:0:7}"
    frozen_spm="$(swift package compute-checksum "${FROZEN}/SkiaPack.xcframework.zip")"
    committed_spm="$(manifest_field checksum)"
    if [[ "${committed_spm}" == "${frozen_spm}" ]]; then
        [[ "$(manifest_field url)" == "${RELEASE_URL}" ]] || refuse "Package.swift checksum is the frozen one but its url is not ${RELEASE_URL}"
        manifest_resolved=1
    else
        # Interrupted between freeze and commit: only acceptable if nothing of
        # this version is public yet.
        [[ -z "${tag_commit}" && "${state}" == "none" ]] \
            || refuse "Package.swift checksum ${committed_spm:0:12}… is not the frozen zip's ${frozen_spm:0:12}…, yet a tag or release for ${VERSION} exists — the frozen artifacts are not the ones this version was cut from"
        manifest_resolved=0
    fi
    if [[ -n "${tag_commit}" ]]; then
        [[ "${state}" == "published" ]] || refuse "tag ${VERSION} exists on origin but the release is '${state}' — inconsistent, resolve by hand"
        [[ "${tag_commit}" == "${head_commit}" ]] || refuse "tag ${VERSION} points at ${tag_commit:0:7}, not HEAD ${head_commit:0:7}"
    fi
fi
echo "[release] preflight OK (${MODE}): version ${VERSION}, HEAD ${head_commit:0:7}, release state ${state}"
if [[ "${CHECK_ONLY}" == "1" ]]; then exit 0; fi

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
    echo "[release] Package.swift → url=${RELEASE_URL} checksum=${spm_checksum}"
fi
release_commit="$(git rev-parse HEAD)"
if [[ "$(git rev-parse "origin/${RELEASE_BRANCH}")" != "${release_commit}" ]]; then
    git push origin "HEAD:refs/heads/${RELEASE_BRANCH}"
fi

# ------------------------------------------- 4. draft release + frozen assets ----
state="$(release_state)"
if [[ "${state}" == "none" ]]; then
    # --target pins the commit the tag will be created at when the draft is
    # published; no tag exists until then.
    gh release create "${VERSION}" --draft --target "${release_commit}" \
        --title "skia-pack ${VERSION}" \
        --notes "Prebuilt Skia m150 (@$(sed -n 's/.*"commit": "\([0-9a-f]\{7\}\).*/\1/p' pins.json | head -1)) + HarfBuzz 14.2.0 static artifacts: macOS arm64 (tarball + xcframework slice), iOS arm64 and iOS Simulator arm64 (xcframework slices; simulator on Apple Silicon hosts only). See pack.json for the full manifest."
    state="draft"
fi

REPO_PATH="${REPO_URL#https://github.com/}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/skia-pack-release.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
remote_sha() { # sha256 of the asset as GitHub serves it; "absent" if not there
    local name="$1" dir="${scratch}/dl-$RANDOM"
    mkdir -p "${dir}"
    if gh release download "${VERSION}" --pattern "${name}" --dir "${dir}" >/dev/null 2>&1 && [[ -f "${dir}/${name}" ]]; then
        sha_of "${dir}/${name}"
    else
        echo absent
    fi
    rm -rf "${dir}"
}
upload_asset() {
    local name="$1" want got attempt rid
    want="$(sha_of "${FROZEN}/${name}")"
    for attempt in 1 2 3 4; do
        got="$(remote_sha "${name}")"
        if [[ "${got}" == "${want}" ]]; then
            echo "[release] asset ok: ${name}"
            return 0
        fi
        if [[ "${got}" != "absent" ]]; then
            # Present with other bytes (a torn upload, or a foreign file).
            [[ "${state}" == "draft" ]] \
                || refuse "PUBLISHED asset ${name} is ${got:0:12}…, frozen is ${want:0:12}… — published assets are never replaced; this version is burnt, roll forward with a PATCH"
            echo "[release] draft asset ${name} has wrong bytes (${got:0:12}…) — deleting it from the draft" >&2
            gh release delete-asset "${VERSION}" "${name}" --yes
        elif [[ "${state}" != "draft" ]]; then
            refuse "PUBLISHED release ${VERSION} is missing asset ${name} — nothing is uploaded to a published release; roll forward with a PATCH"
        fi
        (( attempt <= 3 )) || break
        # No --clobber anywhere: the only deletion is the explicit draft-only one above.
        if (( attempt < 3 )); then
            gh release upload "${VERSION}" "${FROZEN}/${name}" || { echo "[release] upload failed (attempt ${attempt}): ${name}" >&2; sleep 5; }
        else
            # Last resort: raw upload with explicit octet-stream. Observed in
            # the wild: a proxy EOF-kills sniffed-content-type uploads of small
            # .json assets while binary zips sail through.
            echo "[release] falling back to raw octet-stream upload: ${name}" >&2
            rid="$(gh api "repos/${REPO_PATH}/releases/tags/${VERSION}" --jq .id 2>/dev/null \
                   || gh release view "${VERSION}" --json databaseId --jq .databaseId)"
            gh api --method POST -H "Content-Type: application/octet-stream" \
                "https://uploads.github.com/repos/${REPO_PATH}/releases/${rid}/assets?name=${name}" \
                --input "${FROZEN}/${name}" >/dev/null || true
        fi
    done
    refuse "could not get ${name} onto the release with the frozen bytes — fix the cause and run release.sh --resume"
}
for name in "${ASSETS[@]}"; do upload_asset "${name}"; done
# Final read-back of all three before anything becomes public.
for name in "${ASSETS[@]}"; do
    [[ "$(remote_sha "${name}")" == "$(sha_of "${FROZEN}/${name}")" ]] || refuse "read-back of ${name} does not match the frozen bytes"
done
echo "[release] all ${#ASSETS[@]} assets on the release match the frozen bytes"

# --------------------------------------------------------------- 5. publish ----
if [[ "${state}" == "draft" ]]; then
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
