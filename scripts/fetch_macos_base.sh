#!/usr/bin/env bash
# Materialize the reused macOS slice (pins.json "macos_base") under
# build/macos-base/: the two release assets of the base version, downloaded
# and sha256-verified, then extracted.
#
#   build/macos-base/<tarball>.tar.gz, SkiaPack.xcframework.zip   (verified bytes)
#   build/macos-base/tarball/skia-pack-<base>-macos-arm64/        (extracted)
#   build/macos-base/xcframework/SkiaPack.xcframework/            (extracted)
#
# The base is only valid while this checkout still builds the SAME inputs: the
# script refuses if pins.json's skia/harfbuzz commits or gn/macos.gn differ
# from what the base was built from.
#
# Exit 3 = pins.json has no "macos_base" (macOS is built from source instead).
# Idempotent: verified downloads are kept; extraction is redone every run.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${PACK_ROOT}/build/macos-base"

fields="$(python3 - "${PACK_ROOT}" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
pins = json.loads((root / "pins.json").read_text())
base = pins.get("macos_base")
if not base:
    sys.exit(3)
for name in ("skia", "harfbuzz"):
    if pins[name]["commit"] != base[f"{name}_commit"]:
        sys.exit(f"error: pins.json {name} commit {pins[name]['commit']} != macos_base.{name}_commit "
                 f"{base[name + '_commit']} — the reused macOS slice was built from different sources; "
                 f"remove macos_base and build macOS from source")
gn = hashlib.sha256((root / "gn" / "macos.gn").read_bytes()).hexdigest()
if gn != base["gn_args_sha256"]:
    sys.exit(f"error: gn/macos.gn sha256 {gn} != macos_base.gn_args_sha256 {base['gn_args_sha256']} — "
             f"remove macos_base and build macOS from source")
print(base["version"], base["tarball"]["url"], base["tarball"]["sha256"],
      base["xcframework"]["url"], base["xcframework"]["sha256"])
PY
)" || exit $?
read -r base_version tar_url tar_sha zip_url zip_sha <<< "${fields}"

fetch() { # fetch <url> <sha256> <dest>
    local url="$1" want="$2" dest="$3" got
    if [[ -f "${dest}" ]]; then
        got="$(shasum -a 256 "${dest}" | awk '{print $1}')"
        [[ "${got}" == "${want}" ]] && { echo "[macos-base] $(basename "${dest}") present, sha256 ok"; return 0; }
        echo "[macos-base] $(basename "${dest}") present but sha256 ${got} != ${want} — re-downloading" >&2
        rm -f "${dest}"
    fi
    echo "[macos-base] downloading ${url}"
    curl -fL --retry 3 -o "${dest}.part" "${url}"
    got="$(shasum -a 256 "${dest}.part" | awk '{print $1}')"
    if [[ "${got}" != "${want}" ]]; then
        rm -f "${dest}.part"
        echo "error: ${url} sha256 ${got} != pinned ${want}" >&2
        exit 1
    fi
    mv "${dest}.part" "${dest}"
}

mkdir -p "${BASE_DIR}"
TARBALL="${BASE_DIR}/skia-pack-${base_version}-macos-arm64.tar.gz"
XCZIP="${BASE_DIR}/SkiaPack.xcframework.zip"
fetch "${tar_url}" "${tar_sha}" "${TARBALL}"
fetch "${zip_url}" "${zip_sha}" "${XCZIP}"

rm -rf "${BASE_DIR}/tarball" "${BASE_DIR}/xcframework"
mkdir -p "${BASE_DIR}/tarball"
tar -xzf "${TARBALL}" -C "${BASE_DIR}/tarball"
ditto -x -k "${XCZIP}" "${BASE_DIR}/xcframework"
[[ -d "${BASE_DIR}/tarball/skia-pack-${base_version}-macos-arm64/lib" ]] || { echo "error: base tarball layout unexpected" >&2; exit 1; }
[[ -f "${BASE_DIR}/xcframework/SkiaPack.xcframework/macos-arm64/libSkiaPack.a" ]] || { echo "error: base xcframework layout unexpected" >&2; exit 1; }
echo "[macos-base] ready: ${base_version} at ${BASE_DIR}"
