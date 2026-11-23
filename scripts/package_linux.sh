#!/usr/bin/env bash
# Assemble the linux-x86_64 slice. Runs on Linux, after
# scripts/build.sh linux-x86_64:
#   artifacts/skia-pack-<ver>-linux-x86_64.tar.gz
#       skia-pack-<ver>-linux-x86_64/
#           pack.json           this slice's manifest (no hash of the tarball
#                               itself — an artifact cannot contain its own)
#           skia-defines.txt    the defines the Skia build used
#           headers/            the same public tree the Apple slices ship
#           lib/                the individual static archives, libharfbuzz.a
#                               among them (the one definer of hb_*)
#   artifacts/linux-x86_64.json
#       the same manifest plus the tarball's name and sha256, and the hash of
#       the headers-only tree rust-skia binds against. scripts/release.sh (on
#       the Mac) takes the slice from a CI run, checks it against this file,
#       and merges it into the release's pack.json.
#
# There is no merged libSkiaPack.a here: that archive exists for the
# xcframework (SwiftPM), which has no Linux form.
#
# Idempotent: staging and artifacts are rebuilt from scratch on every run.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/platform.sh
source "${PACK_ROOT}/scripts/platform.sh"
VERSION="$(tr -d '[:space:]' < "${PACK_ROOT}/VERSION")"
PLATFORM="linux-x86_64"
pack_platform_init "${PACK_ROOT}" "${PLATFORM}"
[[ "${PACK_HOST_CAN_BUILD}" == "1" ]] || { echo "error: ${PLATFORM} is packaged on Linux" >&2; exit 1; }
SKIA_ROOT="${PACK_ROOT}/third_party/skia"
HB_ROOT="${PACK_ROOT}/third_party/harfbuzz"
ARTIFACTS="${PACK_ROOT}/artifacts"
STAGE_NAME="skia-pack-${VERSION}-${PLATFORM}"
STAGE="${ARTIFACTS}/${STAGE_NAME}"
TARBALL="${ARTIFACTS}/${STAGE_NAME}.tar.gz"
SLICE_JSON="${ARTIFACTS}/${PLATFORM}.json"
BIND_HEADERS="${PACK_ROOT}/build/package/skia-headers"
# shellcheck source=scripts/headers.sh
source "${PACK_ROOT}/scripts/headers.sh"

[[ -f "${PACK_SKIA_OUT}/libskia.a" ]] || { echo "error: run scripts/build.sh ${PLATFORM} first (missing ${PACK_SKIA_OUT}/libskia.a)" >&2; exit 1; }
[[ -f "${PACK_SKIA_OUT}/skia-defines.txt" ]] || { echo "error: run scripts/build.sh ${PLATFORM} first (missing skia-defines.txt)" >&2; exit 1; }
[[ -f "${PACK_HB_OUT}/pack/libharfbuzz.a" ]] || { echo "error: run scripts/build.sh ${PLATFORM} first (missing ${PACK_HB_OUT}/pack/libharfbuzz.a)" >&2; exit 1; }
if [[ -f "${PACK_SKIA_OUT}/libharfbuzz.a" ]]; then
    echo "error: Skia ${PLATFORM} build produced its own libharfbuzz.a — system-HB wiring regressed" >&2
    exit 1
fi

rm -rf "${STAGE}" "${TARBALL}" "${SLICE_JSON}" "${BIND_HEADERS}"
mkdir -p "${STAGE}/lib" "$(dirname "${BIND_HEADERS}")"
stage_headers "${STAGE}/headers"
stage_bind_headers "${BIND_HEADERS}"
cp "${PACK_SKIA_OUT}/"*.a "${STAGE}/lib/"
cp "${PACK_HB_OUT}/pack/libharfbuzz.a" "${STAGE}/lib/libharfbuzz.a"
cp "${PACK_SKIA_OUT}/skia-defines.txt" "${STAGE}/skia-defines.txt"

python3 - "$PACK_ROOT" "$VERSION" "${STAGE}" "$(headers_tree_sha256 "${STAGE}/headers")" "$(headers_tree_sha256 "${BIND_HEADERS}")" <<'PY'
import hashlib, json, pathlib, subprocess, sys
from datetime import datetime, timezone

pack_root, version, stage, public_headers, bind_headers = sys.argv[1:6]
root, stage = pathlib.Path(pack_root), pathlib.Path(stage)
skia, hb = root / "third_party" / "skia", root / "third_party" / "harfbuzz"

def run(*argv, cwd=None):
    return subprocess.check_output(argv, cwd=cwd, text=True).strip()

pins = json.loads((root / "pins.json").read_text())
for name, checkout in (("skia", skia), ("harfbuzz", hb)):
    actual = run("git", "rev-parse", "HEAD", cwd=checkout)
    if actual != pins[name]["commit"]:
        sys.exit(f"error: third_party/{name} is at {actual} but pins.json pins {pins[name]['commit']} — "
                 f"run ./scripts/fetch_sources.sh (refusing to package unpinned sources)")

def define(path, name):
    for line in path.read_text().splitlines():
        if line.startswith(f"#define {name}"):
            return line.split()[-1].strip('"')

os_release = dict(l.split("=", 1) for l in pathlib.Path("/etc/os-release").read_text().splitlines() if "=" in l)
manifest = {
    "name": "skia-pack",
    "version": version,
    "platform": "linux-x86_64",
    "skia": {"commit": pins["skia"]["commit"], "milestone": int(define(skia / "include/core/SkMilestone.h", "SK_MILESTONE"))},
    "harfbuzz": {"version": define(hb / "src/hb-version.h", "HB_VERSION_STRING"), "commit": pins["harfbuzz"]["commit"]},
    "origin": "built",
    "gn_args_file": "gn/linux.gn",
    "gn_args_sha256": hashlib.sha256((root / "gn/linux.gn").read_bytes()).hexdigest(),
    "toolchain": {
        "clang": run("clang-17", "--version").splitlines()[0],
        "libstdcxx": run("clang++-17", "-print-file-name=libstdc++.so"),
        "glibc": run("ldd", "--version").splitlines()[0],
        "os": os_release.get("PRETTY_NAME", "").strip('"'),
    },
    "system_libraries": ["freetype", "fontconfig"],
    "archs": ["x86_64"],
    "libraries": sorted(p.name for p in (stage / "lib").glob("*.a")),
    "library_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((stage / "lib").glob("*.a"))},
    "headers_tree_sha256": public_headers,
    "skia_headers_tree_sha256": bind_headers,
    "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
}
(stage / "pack.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

tar -C "${ARTIFACTS}" -czf "${TARBALL}" "${STAGE_NAME}"
tarball_sha256="$(sha256sum "${TARBALL}" | awk '{print $1}')"
python3 - "${STAGE}/pack.json" "${SLICE_JSON}" "${STAGE_NAME}.tar.gz" "${tarball_sha256}" <<'PY'
import json, pathlib, sys
src, dst, name, sha = sys.argv[1:5]
manifest = json.loads(pathlib.Path(src).read_text())
manifest["artifact"] = {"file": name, "sha256": sha}
pathlib.Path(dst).write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "[package] done (${PLATFORM}):"
echo "  tarball:   ${TARBALL}"
echo "    sha256:  ${tarball_sha256}"
echo "  manifest:  ${SLICE_JSON}"
echo "  rust-skia headers tree (not an artifact of this job): ${BIND_HEADERS}"
