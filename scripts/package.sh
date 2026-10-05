#!/usr/bin/env bash
# Assemble the release artifacts + manifest:
#   (a) artifacts/skia-pack-<ver>-macos-arm64.tar.gz   — CMake-side tarball
#       (pack.json + headers/ + lib/ with individual .a archives + merged
#        libSkiaPack.a). macOS only: no CMake consumer builds for iOS.
#   (b) artifacts/SkiaPack.xcframework.zip             — SwiftPM binaryTarget,
#       three slices, each libSkiaPack.a + Headers/ (one shared header tree):
#         macos-arm64 · ios-arm64 · ios-arm64-simulator (Apple Silicon only)
#   (c) artifacts/pack.json                            — standalone, fully
#       resolved manifest (includes both artifacts' hashes + spm checksum)
#
# Where the macOS slice comes from:
#   * pins.json has "macos_base"  → the base release's archives and headers
#     are REUSED byte-for-byte (scripts/fetch_macos_base.sh); only the stage
#     directory name and pack.json carry the new version. Nothing is rebuilt.
#   * no "macos_base"             → built from source (scripts/build.sh).
# The iOS slices are always built from source (scripts/build.sh <platform>).
# Skia's iOS archives are fat (arm64 + arm64e); every archive is thinned to
# arm64 before the merge.
#
# The pack.json copies embedded INSIDE the artifacts carry every field except
# the artifacts' own hashes (an artifact cannot contain its own digest); the
# standalone copy (c) is the fully resolved one attached to the release.
#
# Idempotent: staging and artifacts are rebuilt from scratch on every run.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/platform.sh
source "${PACK_ROOT}/scripts/platform.sh"
VERSION="$(tr -d '[:space:]' < "${PACK_ROOT}/VERSION")"
PLATFORM="macos-arm64"
SKIA_ROOT="${PACK_ROOT}/third_party/skia"
HB_ROOT="${PACK_ROOT}/third_party/harfbuzz"
ARTIFACTS="${PACK_ROOT}/artifacts"
STAGE_NAME="skia-pack-${VERSION}-${PLATFORM}"
STAGE="${ARTIFACTS}/${STAGE_NAME}"
IOS_STAGE_ROOT="${PACK_ROOT}/build/package"       # per-slice staging, not shipped as-is
TARBALL="${ARTIFACTS}/${STAGE_NAME}.tar.gz"
XCFRAMEWORK="${ARTIFACTS}/SkiaPack.xcframework"
XCZIP="${ARTIFACTS}/SkiaPack.xcframework.zip"

# Fail early, before anything is wiped: every slice's inputs must exist.
for platform in "${PACK_IOS_PLATFORMS[@]}"; do
    pack_platform_init "${PACK_ROOT}" "${platform}"
    [[ -f "${PACK_SKIA_OUT}/libskia.a" ]]  || { echo "error: run scripts/build.sh ${platform} first (missing ${PACK_SKIA_OUT}/libskia.a)" >&2; exit 1; }
    [[ -f "${PACK_HB_OUT}/libharfbuzz.a" ]] || { echo "error: run scripts/build.sh ${platform} first (missing ${PACK_HB_OUT}/libharfbuzz.a)" >&2; exit 1; }
    if [[ -f "${PACK_SKIA_OUT}/libharfbuzz.a" ]]; then
        echo "error: Skia ${platform} build produced its own libharfbuzz.a — system-HB wiring regressed" >&2
        exit 1
    fi
done

macos_base_rc=0
"${PACK_ROOT}/scripts/fetch_macos_base.sh" || macos_base_rc=$?
case "${macos_base_rc}" in
    0) MACOS_ORIGIN="reused" ;;
    3) MACOS_ORIGIN="built" ;;
    *) exit "${macos_base_rc}" ;;
esac
if [[ "${MACOS_ORIGIN}" == "built" ]]; then
    pack_platform_init "${PACK_ROOT}" macos-arm64
    [[ -f "${PACK_SKIA_OUT}/libskia.a" ]]  || { echo "error: run scripts/build.sh first (missing ${PACK_SKIA_OUT}/libskia.a)" >&2; exit 1; }
    [[ -f "${PACK_HB_OUT}/libharfbuzz.a" ]] || { echo "error: run scripts/build.sh first (missing ${PACK_HB_OUT}/libharfbuzz.a)" >&2; exit 1; }
    if [[ -f "${PACK_SKIA_OUT}/libharfbuzz.a" ]]; then
        echo "error: Skia build produced its own libharfbuzz.a — system-HB wiring regressed" >&2
        exit 1
    fi
fi

rm -rf "${STAGE}" "${TARBALL}" "${XCFRAMEWORK}" "${XCZIP}" "${ARTIFACTS}/pack.json" "${IOS_STAGE_ROOT}"
mkdir -p "${ARTIFACTS}" "${IOS_STAGE_ROOT}"

# ---------------------------------------------------------------- headers ----
# Anchored so one -I <pack>/headers resolves every existing include spelling:
#   "include/core/SkCanvas.h", "modules/skparagraph/include/Paragraph.h", <hb.h>
stage_headers() { # stage_headers <dest>
    local dest="$1"
    mkdir -p "${dest}"
    cp -R "${SKIA_ROOT}/include" "${dest}/include"          # public + private
    mkdir -p "${dest}/modules/skcms/src"
    cp "${SKIA_ROOT}/modules/skcms/"*.h "${dest}/modules/skcms/"
    cp "${SKIA_ROOT}/modules/skcms/src/"*.h "${dest}/modules/skcms/src/"  # skcms.h -> "src/skcms_public.h"
    local mod
    for mod in skshaper skparagraph skunicode; do
        mkdir -p "${dest}/modules/${mod}"
        cp -R "${SKIA_ROOT}/modules/${mod}/include" "${dest}/modules/${mod}/include"
    done
    cp "${HB_ROOT}/src/"hb*.h "${dest}/"                    # 48 flat HarfBuzz headers
    # The one src/ header the public surface transitively needs:
    # modules/skunicode/include/SkUnicode.h -> "src/base/SkUTF.h" (self-contained,
    # pulls only include/private/base/SkAPI.h). Verified as the ONLY "src/..."
    # spelling reachable from the packaged tree (grep sweep in verify evidence).
    mkdir -p "${dest}/src/base"
    cp "${SKIA_ROOT}/src/base/SkUTF.h" "${dest}/src/base/"
}

# ------------------------------------------------------------ macOS stage ----
if [[ "${MACOS_ORIGIN}" == "reused" ]]; then
    base_version="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['macos_base']['version'])" "${PACK_ROOT}/pins.json")"
    BASE_STAGE="${PACK_ROOT}/build/macos-base/tarball/skia-pack-${base_version}-${PLATFORM}"
    mkdir -p "${STAGE}"
    cp -R "${BASE_STAGE}/headers" "${STAGE}/headers"
    cp -R "${BASE_STAGE}/lib" "${STAGE}/lib"
    # The header tree is shared by all three slices, so it must also be exactly
    # what the pinned sources the iOS slices were just built from would stage.
    stage_headers "${IOS_STAGE_ROOT}/headers-from-source"
    if ! diff -rq "${STAGE}/headers" "${IOS_STAGE_ROOT}/headers-from-source" > "${IOS_STAGE_ROOT}/headers.diff"; then
        echo "error: reused ${base_version} headers differ from the pinned sources (see ${IOS_STAGE_ROOT}/headers.diff)" >&2
        exit 1
    fi
    rm -rf "${IOS_STAGE_ROOT}/headers-from-source" "${IOS_STAGE_ROOT}/headers.diff"
else
    pack_platform_init "${PACK_ROOT}" macos-arm64
    mkdir -p "${STAGE}/lib"
    stage_headers "${STAGE}/headers"
    # Every archive the Skia build produced (18 with system-HB — no vendored HB),
    # plus the standalone HarfBuzz 14.2 archive shipped AS lib/libharfbuzz.a.
    cp "${PACK_SKIA_OUT}/"*.a "${STAGE}/lib/"
    cp "${PACK_HB_OUT}/libharfbuzz.a" "${STAGE}/lib/libharfbuzz.a"
    # Merged archive: libtool -static preserves per-object granularity (dead
    # stripping still works), unlike ld -r. Duplicate member basenames across
    # libjpeg{,12,16}.a are appended, not collapsed (SPIKE S4).
    libtool -static -o "${STAGE}/lib/libSkiaPack.a" "${STAGE}/lib/"lib*.a 2> >(grep -v "same member name" >&2 || true)
fi

# -------------------------------------------------------------- iOS stages ----
# build/package/<platform>/lib/*.a (thinned individual archives, kept for
# verify's merge-integrity audit) + build/package/<platform>/libSkiaPack.a.
for platform in "${PACK_IOS_PLATFORMS[@]}"; do
    pack_platform_init "${PACK_ROOT}" "${platform}"
    slice="${IOS_STAGE_ROOT}/${platform}"
    mkdir -p "${slice}/lib"
    for archive in "${PACK_SKIA_OUT}"/lib*.a "${PACK_HB_OUT}/libharfbuzz.a"; do
        name="$(basename "${archive}")"
        archs="$(lipo -archs "${archive}")"
        case " ${archs} " in
            " arm64 ")   cp "${archive}" "${slice}/lib/${name}" ;;
            *" arm64 "*) lipo -thin arm64 "${archive}" -output "${slice}/lib/${name}" ;;
            *) echo "error: ${archive} has no arm64 slice (archs: ${archs})" >&2; exit 1 ;;
        esac
    done
    libtool -static -o "${slice}/libSkiaPack.a" "${slice}/lib/"lib*.a 2> >(grep -v -e "same member name" -e "has no symbols" >&2 || true)
done

# -------------------------------------------------------------- pack.json ----
embedded_manifest="${STAGE}/pack.json"
python3 - "$PACK_ROOT" "$VERSION" "$embedded_manifest" "$MACOS_ORIGIN" <<'PY'
import hashlib, json, pathlib, subprocess, sys
from datetime import datetime, timezone

pack_root, version, out_path, macos_origin = sys.argv[1:5]
root = pathlib.Path(pack_root)
skia = root / "third_party" / "skia"
hb = root / "third_party" / "harfbuzz"
stage = root / "artifacts" / f"skia-pack-{version}-macos-arm64"
ios_stage = root / "build" / "package"

def run(*argv, cwd=None):
    return subprocess.check_output(argv, cwd=cwd, text=True).strip()

# The manifest records the ACTUAL source state — which must be the pinned one.
# pins.json is the contract (the repo carries no submodules); a mismatch means
# the build used sources nobody pinned. Refuse to mint a manifest for that.
pins = json.loads((root / "pins.json").read_text())
for name, checkout in (("skia", skia), ("harfbuzz", hb)):
    pinned = pins[name]["commit"]
    actual = run("git", "rev-parse", "HEAD", cwd=checkout)
    if actual != pinned:
        sys.exit(
            f"error: third_party/{name} is at {actual} but pins.json pins "
            f"{pinned} — run ./scripts/fetch_sources.sh (refusing to package "
            f"unpinned sources)"
        )

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
this_toolchain = {
    "xcode": xcodebuild[0].replace("Xcode ", ""),
    "xcode_build": xcodebuild[1].replace("Build version ", ""),
    "clang": run("clang", "--version").splitlines()[0],
}
now = datetime.now(timezone.utc).isoformat(timespec="seconds")

# Per-slice provenance. A reused slice keeps the toolchain/built_at of the
# release it was built for; a built slice records this run's.
slices = {}
if macos_origin == "reused":
    base = pins["macos_base"]
    base_manifest = json.loads(
        (root / "build" / "macos-base" / "tarball" / f"skia-pack-{base['version']}-macos-arm64" / "pack.json").read_text())
    slices["macos-arm64"] = {
        "origin": "reused",
        "reused_from": {
            "version": base["version"],
            "tarball_sha256": base["tarball"]["sha256"],
            "xcframework_sha256": base["xcframework"]["sha256"],
        },
        "gn_args_file": base_manifest["gn_args_file"],
        "gn_args_sha256": base_manifest["gn_args_sha256"],
        "deployment_target": base_manifest["toolchain"]["macos_deployment_target"],
        "toolchain": base_manifest["toolchain"],
        "built_at": base_manifest["built_at"],
    }
    macos_toolchain = base_manifest["toolchain"]
else:
    macos_toolchain = dict(this_toolchain,
                           macos_sdk=run("xcrun", "--sdk", "macosx", "--show-sdk-version"),
                           macos_deployment_target="14.0")
    slices["macos-arm64"] = {
        "origin": "built",
        "gn_args_file": "gn/macos.gn",
        "gn_args_sha256": sha256(root / "gn" / "macos.gn"),
        "deployment_target": "14.0",
        "toolchain": macos_toolchain,
        "built_at": now,
    }
slices["macos-arm64"]["archs"] = ["arm64"]
slices["macos-arm64"]["libSkiaPack_sha256"] = sha256(stage / "lib" / "libSkiaPack.a")

for platform, gn_file, sdk in (("ios-arm64", "gn/ios.gn", "iphoneos"),
                               ("ios-arm64-simulator", "gn/ios-sim.gn", "iphonesimulator")):
    slices[platform] = {
        "origin": "built",
        "gn_args_file": gn_file,
        "gn_args_sha256": sha256(root / gn_file),
        "deployment_target": "17.0",
        "toolchain": dict(this_toolchain, sdk=sdk, sdk_version=run("xcrun", "--sdk", sdk, "--show-sdk-version")),
        "built_at": now,
        "archs": ["arm64"],
        "thinned_from": "arm64 + arm64e (Skia's iOS toolchain emits both; arm64e is not shipped)",
        "libSkiaPack_sha256": sha256(ios_stage / platform / "libSkiaPack.a"),
    }

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
    # Top-level gn_args_* / toolchain describe the macOS slice (the shape every
    # earlier release had); per-slice detail for all platforms is in "slices".
    "gn_args_file": slices["macos-arm64"]["gn_args_file"],
    "gn_args_sha256": slices["macos-arm64"]["gn_args_sha256"],
    "deps_externals": externals,
    "toolchain": macos_toolchain,
    "platforms": list(slices),
    "slices": slices,
    "libraries": sorted(p.name for p in (stage / "lib").glob("*.a")),
    "built_at": now,
    "artifacts": None,  # resolved only in the standalone release copy
}
pathlib.Path(out_path).write_text(json.dumps(manifest, indent=2) + "\n")
PY

# ---------------------------------------------------------------- tarball ----
tar -C "${ARTIFACTS}" -czf "${TARBALL}" "${STAGE_NAME}"

# ------------------------------------------------------------- xcframework ----
xcodebuild -create-xcframework \
    -library "${STAGE}/lib/libSkiaPack.a" -headers "${STAGE}/headers" \
    -library "${IOS_STAGE_ROOT}/ios-arm64/libSkiaPack.a" -headers "${STAGE}/headers" \
    -library "${IOS_STAGE_ROOT}/ios-arm64-simulator/libSkiaPack.a" -headers "${STAGE}/headers" \
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

echo "[package] done (macOS slice: ${MACOS_ORIGIN}):"
echo "  tarball:      ${TARBALL}"
echo "    sha256:     ${tarball_sha256}"
echo "  xcframework:  ${XCZIP}"
echo "    sha256:     ${zip_sha256}"
echo "    spm:        ${spm_checksum}"
echo "  manifest:     ${ARTIFACTS}/pack.json"
