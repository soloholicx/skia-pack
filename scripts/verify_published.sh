#!/usr/bin/env bash
# READ-ONLY verification of an already published release. Builds nothing from
# source, packages nothing, uploads nothing — it downloads the release
# assets and checks that they are what the tag says they are.
#
#   verify_published.sh <version>
#
# Run from a checkout OF THE RELEASE TAG (the workflow checks the tag out), so
# VERSION, Package.swift and the verify scripts are the released ones. That
# also bounds what can be verified: only tags that CONTAIN this script
# (150.2.0 onward) — 150.1.0 and earlier predate it.
#
#   1. consistency   VERSION == <version>; Package.swift's url is this
#                    version's and its checksum equals the downloaded zip's;
#                    the standalone pack.json's sha256s equal those of all four
#                    downloaded archives; pack.json names this version; the
#                    skia-headers archive unpacks to the tree hash it records
#                    and contains headers only
#   2. verify.sh     every audit and smoke test, on the downloaded bytes
#                    (merge integrity needs the packaging stage and is
#                    reported as a skip here — it ran at release time)
#   3. consumer      scripts/verify_consumer.sh exact <version>: SwiftPM
#                    resolves the tag like any consumer, macOS run + iOS links
#   4. Rust consumer scripts/verify_rust_consumer.sh on the downloaded macOS
#                    slice and skia-headers (opens a window: needs a desktop
#                    session). SKIA_PACK_VERIFY_SKIP_RUST_CONSUMER=1 skips it
#                    explicitly; it is then reported as SKIPPED, never passed.
#
# The Linux slice's bytes are checked against pack.json here; its gates run on
# Linux (scripts/verify_published_linux.sh).
#
# Needs a booted iOS simulator (SKIA_PACK_SIM_UDID=<udid>, else any booted one).
# SKIA_PACK_PUBLISHED_ASSETS_DIR=<dir> uses already-downloaded assets instead
# of `gh release download` (tests only).
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WANT="${1:?usage: verify_published.sh <version>}"
cd "${PACK_ROOT}"
fail() { echo "FAIL: $*" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "${VERSION}" == "${WANT}" ]] || fail "this checkout is VERSION ${VERSION}, asked to verify ${WANT} — check out the release tag"
TARBALL="skia-pack-${VERSION}-macos-arm64.tar.gz"
ZIP="SkiaPack.xcframework.zip"
LINUX="skia-pack-${VERSION}-linux-x86_64.tar.gz"
HEADERS="skia-pack-${VERSION}-skia-headers.tar.gz"
ALL_ASSETS=("${TARBALL}" "${ZIP}" "${LINUX}" "${HEADERS}" pack.json)

# The downloaded bytes get a directory of their own. artifacts/ is never
# touched: on a release machine it holds the frozen set (artifacts/release-*/)
# that an interrupted release resumes from.
DL="${PACK_ROOT}/build/verify-published/${VERSION}"
rm -rf "${DL}"
mkdir -p "${DL}"
if [[ -n "${SKIA_PACK_PUBLISHED_ASSETS_DIR:-}" ]]; then
    for name in "${ALL_ASSETS[@]}"; do
        cp "${SKIA_PACK_PUBLISHED_ASSETS_DIR}/${name}" "${DL}/${name}" || fail "asset ${name} not in ${SKIA_PACK_PUBLISHED_ASSETS_DIR}"
    done
else
    for name in "${ALL_ASSETS[@]}"; do
        gh release download "${VERSION}" --pattern "${name}" --dir "${DL}" || fail "could not download asset ${name} of release ${VERSION}"
    done
fi

# ---- 1. the tag, the manifest and the bytes agree -----------------------------
want_url="https://github.com/soloholicx/skia-pack/releases/download/${VERSION}/${ZIP}"
grep -q "url: \"${want_url}\"" Package.swift || fail "Package.swift url is not ${want_url}"
spm="$(swift package compute-checksum "${DL}/${ZIP}")"
grep -q "checksum: \"${spm}\"" Package.swift \
    || fail "Package.swift checksum does not match the published ${ZIP} (${spm})"
python3 - "${DL}" "${VERSION}" "${TARBALL}" "${ZIP}" "${spm}" "${LINUX}" "${HEADERS}" <<'PY' || fail "pack.json does not describe the published assets"
import hashlib, json, pathlib, sys
dl, version, tarball, zip_name, spm, linux, headers = sys.argv[1:8]
m = json.loads((pathlib.Path(dl) / "pack.json").read_text())
sha = lambda n: hashlib.sha256((pathlib.Path(dl) / n).read_bytes()).hexdigest()
errors = []
if m.get("version") != version: errors.append(f"version {m.get('version')} != {version}")
a = m.get("artifacts") or {}
t, x = a.get("macos-arm64-tarball", {}), a.get("xcframework", {})
if t.get("file") != tarball or t.get("sha256") != sha(tarball): errors.append("tarball name/sha256 mismatch")
if x.get("file") != zip_name or x.get("sha256") != sha(zip_name): errors.append("xcframework name/sha256 mismatch")
if x.get("spm_checksum") != spm: errors.append("xcframework spm_checksum mismatch")
l, h = a.get("linux-x86_64-tarball", {}), a.get("skia-headers", {})
if l.get("file") != linux or l.get("sha256") != sha(linux): errors.append("linux tarball name/sha256 mismatch")
if h.get("file") != headers or h.get("sha256") != sha(headers): errors.append("skia-headers name/sha256 mismatch")
for e in errors: print("pack.json:", e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
HEADERS_DIR="${DL}/skia-headers"
mkdir -p "${HEADERS_DIR}"
tar -xzf "${DL}/${HEADERS}" -C "${HEADERS_DIR}"
HEADERS_TREE="${HEADERS_DIR}/skia-pack-${VERSION}-skia-headers"
[[ -d "${HEADERS_TREE}/include" ]] || fail "skia-headers archive layout unexpected"
# shellcheck source=scripts/headers.sh
source "${PACK_ROOT}/scripts/headers.sh"
want_tree="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['artifacts']['skia-headers']['tree_sha256'])" "${DL}/pack.json")"
[[ "$(headers_tree_sha256 "${HEADERS_TREE}")" == "${want_tree}" ]] || fail "skia-headers tree is not the one pack.json records"
stray="$(find "${HEADERS_TREE}" -type f ! -name '*.h' ! -name '*.inc' ! -name LICENSE | head -3)"
[[ -z "${stray}" ]] || fail "skia-headers contains files that are not headers: ${stray}"
echo "consistency PASS: tag ${VERSION} · Package.swift url+checksum · pack.json · downloaded bytes of all five assets agree"

# ---- 2 + 3 ----------------------------------------------------------------------
SKIA_PACK_VERIFY_ARTIFACTS_DIR="${DL}" ./scripts/verify.sh
./scripts/verify_consumer.sh exact "${VERSION}"

# ---- 4 ---------------------------------------------------------------------------
if [[ "${SKIA_PACK_VERIFY_SKIP_RUST_CONSUMER:-0}" == "1" ]]; then
    echo "rust consumer SKIPPED (SKIA_PACK_VERIFY_SKIP_RUST_CONSUMER=1)"
    rust_note=" — Rust consumer gate SKIPPED"
else
    ./scripts/verify_rust_consumer.sh "build/verify/skia-pack-${VERSION}-macos-arm64" "${HEADERS_TREE}"
    rust_note=""
fi

echo
echo "[verify-published] ${VERSION}: published assets verified (read-only)${rust_note}"
