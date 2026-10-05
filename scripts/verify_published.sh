#!/usr/bin/env bash
# READ-ONLY verification of an already published release. Builds nothing from
# source, packages nothing, uploads nothing — it downloads the three release
# assets and checks that they are what the tag says they are.
#
#   verify_published.sh <version>
#
# Run from a checkout OF THE RELEASE TAG (the workflow checks the tag out), so
# VERSION, Package.swift and the verify scripts are the released ones.
#
#   1. consistency   VERSION == <version>; Package.swift's url is this
#                    version's and its checksum equals the downloaded zip's;
#                    the standalone pack.json's sha256s equal the downloaded
#                    tarball's and zip's; pack.json names this version
#   2. verify.sh     every audit and smoke test, on the downloaded bytes
#                    (merge integrity needs the packaging stage and is
#                    reported as a skip here — it ran at release time)
#   3. consumer      scripts/verify_consumer.sh exact <version>: SwiftPM
#                    resolves the tag like any consumer, macOS run + iOS links
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

# Downloaded bytes go where verify.sh reads its inputs. Nothing else may be there.
rm -rf artifacts
mkdir -p artifacts
if [[ -n "${SKIA_PACK_PUBLISHED_ASSETS_DIR:-}" ]]; then
    for name in "${TARBALL}" "${ZIP}" pack.json; do
        cp "${SKIA_PACK_PUBLISHED_ASSETS_DIR}/${name}" "artifacts/${name}" || fail "asset ${name} not in ${SKIA_PACK_PUBLISHED_ASSETS_DIR}"
    done
else
    for name in "${TARBALL}" "${ZIP}" pack.json; do
        gh release download "${VERSION}" --pattern "${name}" --dir artifacts || fail "release ${VERSION} has no asset ${name}"
    done
fi

# ---- 1. the tag, the manifest and the bytes agree -----------------------------
want_url="https://github.com/soloholicx/skia-pack/releases/download/${VERSION}/${ZIP}"
grep -q "url: \"${want_url}\"" Package.swift || fail "Package.swift url is not ${want_url}"
spm="$(swift package compute-checksum "artifacts/${ZIP}")"
grep -q "checksum: \"${spm}\"" Package.swift \
    || fail "Package.swift checksum does not match the published ${ZIP} (${spm})"
python3 - "artifacts/pack.json" "${VERSION}" "${TARBALL}" "${ZIP}" "${spm}" <<'PY' || fail "pack.json does not describe the published assets"
import hashlib, json, pathlib, sys
manifest_path, version, tarball, zip_name, spm = sys.argv[1:6]
m = json.loads(pathlib.Path(manifest_path).read_text())
sha = lambda n: hashlib.sha256((pathlib.Path("artifacts") / n).read_bytes()).hexdigest()
errors = []
if m.get("version") != version: errors.append(f"version {m.get('version')} != {version}")
a = m.get("artifacts") or {}
t, x = a.get("macos-arm64-tarball", {}), a.get("xcframework", {})
if t.get("file") != tarball or t.get("sha256") != sha(tarball): errors.append("tarball name/sha256 mismatch")
if x.get("file") != zip_name or x.get("sha256") != sha(zip_name): errors.append("xcframework name/sha256 mismatch")
if x.get("spm_checksum") != spm: errors.append("xcframework spm_checksum mismatch")
for e in errors: print("pack.json:", e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
echo "consistency PASS: tag ${VERSION} · Package.swift url+checksum · pack.json · downloaded bytes all agree"

# ---- 2 + 3 ----------------------------------------------------------------------
./scripts/verify.sh
./scripts/verify_consumer.sh exact "${VERSION}"

echo
echo "[verify-published] ${VERSION}: published assets verified (read-only)"
