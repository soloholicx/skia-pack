#!/usr/bin/env bash
# Assemble the two release artifacts + manifest from one build:
#   (a) artifacts/skia-pack-<ver>-macos-arm64.tar.gz   — CMake-side tarball
#       (pack.json + headers/ + lib/ with individual .a archives + merged
#        libSkiaPack.a)
#   (b) artifacts/SkiaPack.xcframework.zip             — SwiftPM binaryTarget
#       (single macos-arm64 slice: libSkiaPack.a + Headers/, same layout)
#   (c) artifacts/pack.json                            — standalone, fully
#       resolved manifest (includes both artifacts' hashes + spm checksum)
#
# The pack.json copies embedded INSIDE the artifacts carry every field except
# the artifacts' own hashes (an artifact cannot contain its own digest); the
# standalone copy (c) is the fully resolved one attached to the release.
#
# Idempotent: staging and artifacts are rebuilt from scratch on every run.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${PACK_ROOT}/VERSION")"
PLATFORM="macos-arm64"
SKIA_ROOT="${PACK_ROOT}/third_party/skia"
HB_ROOT="${PACK_ROOT}/third_party/harfbuzz"
SKIA_OUT="${PACK_ROOT}/build/skia/Release-${PLATFORM}"
HB_OUT="${PACK_ROOT}/build/harfbuzz"
ARTIFACTS="${PACK_ROOT}/artifacts"
STAGE_NAME="skia-pack-${VERSION}-${PLATFORM}"
STAGE="${ARTIFACTS}/${STAGE_NAME}"
TARBALL="${ARTIFACTS}/${STAGE_NAME}.tar.gz"
XCFRAMEWORK="${ARTIFACTS}/SkiaPack.xcframework"
XCZIP="${ARTIFACTS}/SkiaPack.xcframework.zip"

[[ -f "${SKIA_OUT}/libskia.a" ]]  || { echo "error: run scripts/build.sh first (missing ${SKIA_OUT}/libskia.a)" >&2; exit 1; }
[[ -f "${HB_OUT}/libharfbuzz.a" ]] || { echo "error: run scripts/build.sh first (missing ${HB_OUT}/libharfbuzz.a)" >&2; exit 1; }
if [[ -f "${SKIA_OUT}/libharfbuzz.a" ]]; then
    echo "error: Skia build produced its own libharfbuzz.a — system-HB wiring regressed" >&2
    exit 1
fi

rm -rf "${STAGE}" "${TARBALL}" "${XCFRAMEWORK}" "${XCZIP}" "${ARTIFACTS}/pack.json"
mkdir -p "${STAGE}/headers" "${STAGE}/lib"

# ---------------------------------------------------------------- headers ----
# Anchored so one -I <pack>/headers resolves every existing include spelling:
#   "include/core/SkCanvas.h", "modules/skparagraph/include/Paragraph.h", <hb.h>
cp -R "${SKIA_ROOT}/include" "${STAGE}/headers/include"          # public + private
mkdir -p "${STAGE}/headers/modules/skcms/src"
cp "${SKIA_ROOT}/modules/skcms/"*.h "${STAGE}/headers/modules/skcms/"
cp "${SKIA_ROOT}/modules/skcms/src/"*.h "${STAGE}/headers/modules/skcms/src/"  # skcms.h -> "src/skcms_public.h"
for mod in skshaper skparagraph skunicode; do
    mkdir -p "${STAGE}/headers/modules/${mod}"
    cp -R "${SKIA_ROOT}/modules/${mod}/include" "${STAGE}/headers/modules/${mod}/include"
done
cp "${HB_ROOT}/src/"hb*.h "${STAGE}/headers/"                    # 48 flat HarfBuzz headers

# ------------------------------------------------------------------- libs ----
# Every archive the Skia build produced (18 with system-HB — no vendored HB),
# plus the standalone HarfBuzz 14.2 archive shipped AS lib/libharfbuzz.a.
cp "${SKIA_OUT}/"*.a "${STAGE}/lib/"
cp "${HB_OUT}/libharfbuzz.a" "${STAGE}/lib/libharfbuzz.a"

# Merged archive: libtool -static preserves per-object granularity (dead
# stripping still works), unlike ld -r. Duplicate member basenames across
# libjpeg{,12,16}.a are appended, not collapsed (SPIKE S4).
libtool -static -o "${STAGE}/lib/libSkiaPack.a" "${STAGE}/lib/"lib*.a 2> >(grep -v "same member name" >&2 || true)

# -------------------------------------------------------------- pack.json ----
embedded_manifest="${STAGE}/pack.json"
python3 - "$PACK_ROOT" "$VERSION" "$PLATFORM" "$embedded_manifest" <<'PY'
import hashlib, json, pathlib, subprocess, sys
from datetime import datetime, timezone

pack_root, version, platform, out_path = sys.argv[1:5]
root = pathlib.Path(pack_root)
skia = root / "third_party" / "skia"
hb = root / "third_party" / "harfbuzz"
stage = root / "artifacts" / f"skia-pack-{version}-{platform}"

def run(*argv, cwd=None):
    return subprocess.check_output(argv, cwd=cwd, text=True).strip()

def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

milestone = None
for line in (skia / "include" / "core" / "SkMilestone.h").read_text().splitlines():
    if line.startswith("#define SK_MILESTONE"):
        milestone = int(line.split()[-1])
hb_version = None
for line in (hb / "src" / "hb-version.h").read_text().splitlines():
    if line.startswith("#define HB_VERSION_STRING"):
        hb_version = line.split('"')[1]

externals = {}
ext_dir = skia / "third_party" / "externals"
for entry in sorted(ext_dir.iterdir()):
    if (entry / ".git").exists():
        externals[entry.name] = run("git", "rev-parse", "HEAD", cwd=entry)

xcodebuild = run("xcodebuild", "-version").splitlines()
manifest = {
    "name": "skia-pack",
    "version": version,
    "skia": {
        "commit": run("git", "rev-parse", "HEAD", cwd=skia),
        "milestone": milestone,
    },
    "harfbuzz": {
        "version": hb_version,
        "commit": run("git", "rev-parse", "HEAD", cwd=hb),
    },
    "gn_args_file": "gn/macos.gn",
    "gn_args_sha256": sha256(root / "gn" / "macos.gn"),
    "deps_externals": externals,
    "toolchain": {
        "xcode": xcodebuild[0].replace("Xcode ", ""),
        "xcode_build": xcodebuild[1].replace("Build version ", ""),
        "clang": run("clang", "--version").splitlines()[0],
        "macos_sdk": run("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "macos_deployment_target": "14.0",
    },
    "platforms": [platform],
    "libraries": sorted(p.name for p in (stage / "lib").glob("*.a")),
    "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "artifacts": None,  # resolved only in the standalone release copy
}
pathlib.Path(out_path).write_text(json.dumps(manifest, indent=2) + "\n")
PY

# ---------------------------------------------------------------- tarball ----
tar -C "${ARTIFACTS}" -czf "${TARBALL}" "${STAGE_NAME}"

# ------------------------------------------------------------- xcframework ----
xcodebuild -create-xcframework \
    -library "${STAGE}/lib/libSkiaPack.a" \
    -headers "${STAGE}/headers" \
    -output "${XCFRAMEWORK}" > /dev/null
cp "${embedded_manifest}" "${XCFRAMEWORK}/pack.json"
ditto -c -k --keepParent "${XCFRAMEWORK}" "${XCZIP}"

# ------------------------------- standalone, fully resolved pack.json --------
tarball_sha256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
zip_sha256="$(shasum -a 256 "${XCZIP}" | awk '{print $1}')"
spm_checksum="$(cd "${PACK_ROOT}" && swift package compute-checksum "${XCZIP}")"

python3 - "$embedded_manifest" "${ARTIFACTS}/pack.json" \
          "${STAGE_NAME}.tar.gz" "$tarball_sha256" \
          "SkiaPack.xcframework.zip" "$zip_sha256" "$spm_checksum" <<'PY'
import json, pathlib, sys
src, dst, tar_name, tar_sha, zip_name, zip_sha, spm = sys.argv[1:8]
manifest = json.loads(pathlib.Path(src).read_text())
manifest["artifacts"] = {
    "macos-arm64-tarball": {"file": tar_name, "sha256": tar_sha},
    "xcframework": {"file": zip_name, "sha256": zip_sha, "spm_checksum": spm},
}
pathlib.Path(dst).write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "[package] done:"
echo "  tarball:      ${TARBALL}"
echo "    sha256:     ${tarball_sha256}"
echo "  xcframework:  ${XCZIP}"
echo "    sha256:     ${zip_sha256}"
echo "    spm:        ${spm_checksum}"
echo "  manifest:     ${ARTIFACTS}/pack.json"
