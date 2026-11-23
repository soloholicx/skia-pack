#!/usr/bin/env bash
# READ-ONLY verification of a published release, Linux side. Downloads the
# Linux slice, the skia-headers archive and pack.json, and runs the slice's
# gates on those bytes. Builds no Skia, packages nothing, uploads nothing.
#
#   verify_published_linux.sh <version>
#
# Run on Linux from a checkout OF THE RELEASE TAG (157.1.0 onward).
#   1. consistency   pack.json names this version and records the sha256 of
#                    both downloaded archives; the skia-headers tree hash
#   2. verify_linux.sh        every audit and the smoke test, on those bytes
#   3. verify_rust_consumer.sh  one Skia per process (needs a display: run
#                    under xvfb-run)
#
# SKIA_PACK_PUBLISHED_ASSETS_DIR=<dir> uses already-downloaded assets instead
# of `gh release download` (tests only).
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WANT="${1:?usage: verify_published_linux.sh <version>}"
cd "${PACK_ROOT}"
fail() { echo "FAIL: $*" >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "${VERSION}" == "${WANT}" ]] || fail "this checkout is VERSION ${VERSION}, asked to verify ${WANT} — check out the release tag"
LINUX="skia-pack-${VERSION}-linux-x86_64.tar.gz"
HEADERS="skia-pack-${VERSION}-skia-headers.tar.gz"
DL="${PACK_ROOT}/build/verify-published/${VERSION}"
rm -rf "${DL}"; mkdir -p "${DL}/skia-headers"
for name in "${LINUX}" "${HEADERS}" pack.json; do
    if [[ -n "${SKIA_PACK_PUBLISHED_ASSETS_DIR:-}" ]]; then
        cp "${SKIA_PACK_PUBLISHED_ASSETS_DIR}/${name}" "${DL}/${name}" || fail "asset ${name} not in ${SKIA_PACK_PUBLISHED_ASSETS_DIR}"
    else
        gh release download "${VERSION}" --pattern "${name}" --dir "${DL}" || fail "could not download asset ${name} of release ${VERSION}"
    fi
done
tar -xzf "${DL}/${HEADERS}" -C "${DL}/skia-headers"
HEADERS_TREE="${DL}/skia-headers/skia-pack-${VERSION}-skia-headers"
# shellcheck source=scripts/headers.sh
source "${PACK_ROOT}/scripts/headers.sh"
python3 - "${DL}" "${VERSION}" "${LINUX}" "${HEADERS}" "$(headers_tree_sha256 "${HEADERS_TREE}")" <<'PY' || fail "pack.json does not describe the published Linux assets"
import hashlib, json, pathlib, sys
dl, version, linux, headers, tree = sys.argv[1:6]
m = json.loads((pathlib.Path(dl) / "pack.json").read_text())
sha = lambda n: hashlib.sha256((pathlib.Path(dl) / n).read_bytes()).hexdigest()
a = m.get("artifacts") or {}
l, h = a.get("linux-x86_64-tarball", {}), a.get("skia-headers", {})
errors = []
if m.get("version") != version: errors.append(f"version {m.get('version')} != {version}")
if l.get("file") != linux or l.get("sha256") != sha(linux): errors.append("linux tarball name/sha256 mismatch")
if h.get("file") != headers or h.get("sha256") != sha(headers): errors.append("skia-headers name/sha256 mismatch")
if h.get("tree_sha256") != tree: errors.append("skia-headers tree hash mismatch")
if "linux-x86_64" not in (m.get("slices") or {}): errors.append("no linux-x86_64 slice in the manifest")
for e in errors: print("pack.json:", e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
echo "consistency PASS: tag ${VERSION} · pack.json · downloaded Linux slice and skia-headers agree"

SKIA_PACK_VERIFY_ARTIFACTS_DIR="${DL}" ./scripts/verify_linux.sh
./scripts/verify_rust_consumer.sh "build/verify-linux/skia-pack-${VERSION}-linux-x86_64" "${HEADERS_TREE}"

echo
echo "[verify-published-linux] ${VERSION}: published Linux assets verified (read-only)"
