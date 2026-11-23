#!/usr/bin/env bash
# Release-gate verification of the linux-x86_64 slice. Runs on Linux against
# the EXACT tarball bytes, re-extracted into build/verify-linux/.
#
# Checks (letters follow scripts/verify.sh where the check is the same):
#   (a) every Skia-produced archive defines zero hb_* symbols
#   (b) only libharfbuzz.a defines hb_*, each exactly once
#   (c) libharfbuzz.a embeds the HarfBuzz version pack.json declares
#   (e) the smoke test builds and RUNS: -I headers/ + the individual archives
#       + the two system libraries (FreeType, Fontconfig)
#   (j) skia-defines.txt differs from the one rust-skia's own build writes
#       only as gn/rust-skia/linux-x86_64.allowed-diff.txt lists; the packaged
#       headers include no non-public path that is not shipped
#   (m) manifest: every archive's sha256 is the one pack.json records; with
#       SKIA_PACK_LINUX_SLICE_JSON=<file> the tarball's own sha256 too
#   (n) system baseline: the smoke executable needs no glibc symbol newer than
#       2.35 and no libstdc++ symbol newer than GLIBCXX_3.4.30 / CXXABI_1.3.13
#       (Ubuntu 22.04), and loads only the expected system libraries. This
#       fails on a build machine whose libstdc++ is newer than the baseline's
#       — the slice must be built where the baseline holds.
#
# SKIA_PACK_VERIFY_ARTIFACTS_DIR points the gate at tarballs that live
# elsewhere; it is only read. Idempotent: build/verify-linux is rebuilt.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${PACK_ROOT}/VERSION")"
PLATFORM="linux-x86_64"
STAGE_NAME="skia-pack-${VERSION}-${PLATFORM}"
ARTIFACTS_DIR="${SKIA_PACK_VERIFY_ARTIFACTS_DIR:-${PACK_ROOT}/artifacts}"
TARBALL="${ARTIFACTS_DIR}/${STAGE_NAME}.tar.gz"
VERIFY="${PACK_ROOT}/build/verify-linux"

[[ "$(uname -s)" == "Linux" ]] || { echo "error: verify_linux.sh runs on Linux" >&2; exit 1; }
[[ -f "${TARBALL}" ]] || { echo "error: missing ${TARBALL} (run scripts/package_linux.sh)" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; exit 1; }

rm -rf "${VERIFY}"
mkdir -p "${VERIFY}"
tar -xzf "${TARBALL}" -C "${VERIFY}"
PACKDIR="${VERIFY}/${STAGE_NAME}"
LIB="${PACKDIR}/lib"
[[ -d "${PACKDIR}/headers" && -d "${LIB}" && -f "${PACKDIR}/pack.json" ]] || fail "tarball layout unexpected"

# ---- (m) manifest ------------------------------------------------------------
python3 - "${PACKDIR}" "${VERSION}" "${TARBALL}" "${SKIA_PACK_LINUX_SLICE_JSON:-}" <<'PY' || fail "manifest(m)"
import hashlib, json, pathlib, sys
packdir, version, tarball, slice_json = sys.argv[1:5]
packdir = pathlib.Path(packdir)
manifest = json.loads((packdir / "pack.json").read_text())
def sha(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
assert manifest["version"] == version, f"pack.json version {manifest['version']} != {version}"
assert manifest["platform"] == "linux-x86_64"
on_disk = sorted(p.name for p in (packdir / "lib").iterdir())
assert on_disk == manifest["libraries"], f"lib/ holds {on_disk}, pack.json lists {manifest['libraries']}"
for name, want in manifest["library_sha256"].items():
    assert sha(packdir / "lib" / name) == want, f"lib/{name} is not the archive pack.json records"
if slice_json:
    outer = json.loads(pathlib.Path(slice_json).read_text())
    assert outer["artifact"]["sha256"] == sha(tarball), "tarball sha256 is not the one the slice manifest records"
    inner = dict(outer); inner.pop("artifact")
    assert inner == manifest, "slice manifest and the tarball's pack.json differ"
    print("manifest(m) PASS: archives and tarball match the slice manifest")
else:
    print("manifest(m) PASS: archives match pack.json (no slice manifest given: tarball hash not checked)")
PY

# ---- (a) + (b): hb_* definer sweep -------------------------------------------
defined() { nm -g --defined-only "$1" 2>/dev/null | awk 'NF==3{print $3}'; }
hb_count=0
for archive in "${LIB}"/lib*.a; do
    base="$(basename "${archive}")"
    count="$(defined "${archive}" | grep -c '^hb_' || true)"
    if [[ "${base}" == "libharfbuzz.a" ]]; then
        (( count > 0 )) || fail "audit(b): libharfbuzz.a defines no hb_* symbols"
        hb_count="${count}"
    else
        (( count == 0 )) || fail "audit(a/b): ${base} defines ${count} hb_* symbols (must be 0)"
    fi
done
dupes="$(defined "${LIB}/libharfbuzz.a" | grep '^hb_' | sort | uniq -d | wc -l)"
[[ "${dupes}" == "0" ]] || fail "audit(b): libharfbuzz.a defines ${dupes} hb_* symbols more than once"
echo "audit(a) PASS: all Skia-produced archives define 0 hb_* symbols"
echo "audit(b) PASS: only libharfbuzz.a defines hb_* (${hb_count} symbols, no duplicates)"
needed="$(for a in "${LIB}"/lib*.a; do nm -g --undefined-only "$a" 2>/dev/null | awk '{print $NF}'; done | grep '^hb_' | sort -u)"
missing="$(comm -23 <(printf '%s\n' "${needed}") <(defined "${LIB}/libharfbuzz.a" | grep '^hb_' | sort -u))"
[[ -z "${missing}" ]] || fail "audit(b): hb_* symbols the Skia archives need but libharfbuzz.a does not define: ${missing}"
echo "audit(b+) PASS: libharfbuzz.a defines every hb_* symbol the Skia archives reference ($(printf '%s\n' "${needed}" | wc -l))"

# ---- (c) HarfBuzz version ----------------------------------------------------
HB_VERSION="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['harfbuzz']['version'])" "${PACKDIR}/pack.json")"
[[ "${HB_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "audit(c): pack.json harfbuzz.version '${HB_VERSION}' is not x.y.z"
(( $(strings "${LIB}/libharfbuzz.a" | grep -cF "${HB_VERSION}" || true) >= 1 )) \
    || fail "audit(c): ${HB_VERSION} version string not found in libharfbuzz.a"
echo "audit(c) PASS: libharfbuzz.a embeds ${HB_VERSION}"

# ---- (j) defines and header closure ------------------------------------------
python3 "${PACK_ROOT}/scripts/skia_defines.py" check "${PLATFORM}" "${PACKDIR}/skia-defines.txt" \
    || fail "defines(j): skia-defines.txt differs from rust-skia's in a way gn/rust-skia/${PLATFORM}.allowed-diff.txt does not list"
src_spellings="$(grep -rhoE '#[[:space:]]*include[[:space:]]+"(src|third_party|tools)/[^"]+"' "${PACKDIR}/headers" | sed -E 's/.*"(.*)"/\1/' | sort -u | tr '\n' ' ')"
[[ "${src_spellings}" == "src/core/SkUTF.h src/skcms_public.h " ]] \
    || fail "headers(j): packaged headers include non-public paths other than the two shipped ones: ${src_spellings}"
[[ -f "${PACKDIR}/headers/src/core/SkUTF.h" && -f "${PACKDIR}/headers/modules/skcms/src/skcms_public.h" ]] \
    || fail "headers(j): a non-public header the packaged tree includes is not shipped"
echo "defines(j) PASS: skia-defines.txt matches rust-skia's except for the listed differences; header tree is closed"

# ---- (e) smoke test ----------------------------------------------------------
# Order matters for static archives: users first. The group lets the linker
# resolve the archives' mutual references whatever their order.
LINK_LIBS=(
    libskparagraph.a libskshaper.a libskunicode_icu.a libskunicode_core.a
    libskia.a libharfbuzz.a libicu.a libpng.a libwebp.a libwebp_sse41.a
    libwebp_avx2.a libjpeg.a libjpeg12.a libjpeg16.a libskcms.a libexpat.a
    libwuffs.a libzlib.a
)
link_libs=()
for lib in "${LINK_LIBS[@]}"; do
    [[ -f "${LIB}/${lib}" ]] || fail "tarball missing expected archive ${lib}"
    link_libs+=("${LIB}/${lib}")
done
[[ "$(cd "${LIB}" && ls | sort | tr '\n' ' ')" == "$(printf '%s\n' "${LINK_LIBS[@]}" | sort | tr '\n' ' ')" ]] \
    || fail "smoke(e): lib/ holds archives the smoke link does not name (or the reverse): $(cd "${LIB}" && ls | tr '\n' ' ')"
read -r -a defines <<< "$(tr '\n' ' ' < "${PACKDIR}/skia-defines.txt")"
echo "smoke (headers/ + individual archives)..."
clang++-17 -std=c++20 -O1 "${defines[@]}" -I "${PACKDIR}/headers" "${PACK_ROOT}/tests/smoke/smoke.cpp" \
    -Wl,--start-group "${link_libs[@]}" -Wl,--end-group \
    -lfontconfig -lfreetype -lpthread -ldl -lm -o "${VERIFY}/smoke"
"${VERIFY}/smoke" "${VERIFY}/smoke.png"
echo "smoke(e) PASS"

# ---- (n) system baseline -----------------------------------------------------
# Static archives do not record symbol versions; the linked executable does.
python3 - "${VERIFY}/smoke" <<'PY' || fail "baseline(n)"
import re, subprocess, sys
limits = {"GLIBC": (2, 35), "GLIBCXX": (3, 4, 30), "CXXABI": (1, 3, 13)}
out = subprocess.run(["objdump", "-T", sys.argv[1]], capture_output=True, text=True, check=True).stdout
worst = {}
for family, version in re.findall(r"\b(GLIBCXX|CXXABI|GLIBC)_([0-9.]+)", out):
    v = tuple(int(x) for x in version.split("."))
    worst[family] = max(worst.get(family, (0,)), v)
    if v > limits[family]:
        sys.exit(f"the smoke executable needs {family}_{version}, newer than the Ubuntu 22.04 baseline")
needed = sorted(set(re.findall(r"NEEDED\s+(\S+)", subprocess.run(["objdump", "-p", sys.argv[1]], capture_output=True, text=True, check=True).stdout)))
# ld-linux-x86-64.so.2 is glibc's own loader; the linker lists it as NEEDED when
# an object references a loader symbol directly (seen with Ubuntu 22.04's
# libstdc++, not with newer ones).
allowed = {"libfontconfig.so.1", "libfreetype.so.6", "libstdc++.so.6", "libm.so.6", "libgcc_s.so.1", "libc.so.6", "libpthread.so.0", "libdl.so.2",
           "ld-linux-x86-64.so.2"}
extra = [n for n in needed if n not in allowed]
if extra:
    sys.exit(f"the smoke executable loads unexpected shared libraries: {extra}")
print("baseline(n) PASS: smoke executable needs at most",
      ", ".join(f"{k}_{'.'.join(map(str, v))}" for k, v in sorted(worst.items())), "and loads", " ".join(needed))
PY

echo
echo "[verify-linux] ALL CHECKS PASSED"
