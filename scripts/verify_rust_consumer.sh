#!/usr/bin/env bash
# The "one Skia per process" gate for Rust consumers.
#
# Builds and runs tests/rust-consumer: Slint 1.19.0 with its Skia renderer
# (rust-skia 0.157.0) and a C++ static library that calls Skia, SkShaper, ICU
# and HarfBuzz, in ONE executable. rust-skia is pointed at the pack instead of
# downloading or building its own Skia.
#
# usage: verify_rust_consumer.sh <pack-dir> <skia-headers-dir>
#   <pack-dir>           an extracted slice tarball (headers/, lib/,
#                        skia-defines.txt) for THIS host's platform
#   <skia-headers-dir>   the extracted skia-headers asset (include/, src/,
#                        modules/)
#
# Checks:
#   1. skia-bindings took the "bind against system Skia" path — and neither
#      downloaded nor built Skia
#   2. the executable runs: the C++ side shapes and draws text with the pack's
#      HarfBuzz, the Rust side draws through skia-safe, Slint renders a window
#      (needs a display; on Linux run under xvfb-run)
#   3. every object of the pack's five Skia archives rust-skia links is in the
#      skia-bindings rlib byte for byte — the Skia in the executable IS the
#      pack's
#   4. the executable defines no external symbol twice, and the link map
#      takes hb_* from the pack's libharfbuzz.a only
#
# Needs: cargo (Rust 1.85+), clang with libclang (LIBCLANG_PATH if it is not
# on the default path), network for crates on the first run.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 2 ]] || { echo "usage: verify_rust_consumer.sh <pack-dir> <skia-headers-dir>" >&2; exit 2; }
PACK_DIR="$(cd "$1" && pwd)"
HEADERS_DIR="$(cd "$2" && pwd)"
WORK="${PACK_ROOT}/build/verify-rust-consumer"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "${PACK_DIR}/skia-defines.txt" && -d "${PACK_DIR}/lib" && -d "${PACK_DIR}/headers" ]] || fail "${PACK_DIR} is not an extracted slice"
[[ -f "${HEADERS_DIR}/include/core/SkCanvas.h" && -d "${HEADERS_DIR}/src" ]] || fail "${HEADERS_DIR} is not the skia-headers tree"
if find "${HEADERS_DIR}" -type f \( -name '*.cpp' -o -name '*.cc' -o -name '*.c' -o -name '*.mm' \) | grep -q .; then
    fail "${HEADERS_DIR} contains source files — this gate must prove headers alone are enough"
fi

case "$(uname -s)" in
    Darwin) cc=clang; cxx=clang++; sha() { shasum -a 256 "$@"; } ;;
    Linux)  cc=clang-17; cxx=clang++-17; sha() { sha256sum "$@"; }
            : "${LIBCLANG_PATH:=/usr/lib/llvm-17/lib}"; export LIBCLANG_PATH ;;
    *) fail "unsupported host" ;;
esac

# The target directory is kept between runs (crates compile once); everything
# that depends on the pack is rebuilt because cargo watches these variables.
mkdir -p "${WORK}/out"
export SKIA_PACK_DIR="${PACK_DIR}"
export SKIA_SOURCE_DIR="${HEADERS_DIR}"
export SKIA_LIBRARY_SEARCH_PATH="${PACK_DIR}/lib"
SKIA_BUILD_DEFINES="$(tr '\n' ' ' < "${PACK_DIR}/skia-defines.txt")"; export SKIA_BUILD_DEFINES
export CC="${cc}" CXX="${cxx}"
export CARGO_TARGET_DIR="${WORK}/target"
unset SKIA_BINARIES_URL FORCE_SKIA_BUILD FORCE_SKIA_BINARIES_DOWNLOAD SKIA_USE_SYSTEM_LIBRARIES

# Nothing below depends on where cargo puts things inside the target directory
# (that layout changed between cargo releases): the build script's output is
# read from cargo's own -vv log, artifact paths from its JSON messages.
(cd "${PACK_ROOT}/tests/rust-consumer" \
    && cargo clean --release --locked -p skia-bindings -p skia-pack-rust-consumer) > "${WORK}/clean.log" 2>&1 \
    || { cat "${WORK}/clean.log" >&2; fail "cargo clean of the two packages the gate rebuilds"; }
echo "rust consumer: cargo build..."
(cd "${PACK_ROOT}/tests/rust-consumer" && cargo build --release --locked -vv --message-format=json) \
    > "${WORK}/messages.json" 2> "${WORK}/build.log" \
    || { tail -60 "${WORK}/build.log" >&2; fail "rust consumer build"; }
artifact() { # artifact <target-name> <field: rlib|executable>
    python3 - "${WORK}/messages.json" "$1" "$2" <<'PY'
import json, sys
path, name, field = sys.argv[1:4]
found = set()
for line in open(path):
    line = line.strip()
    if not line.startswith("{"):
        continue
    m = json.loads(line)
    if m.get("reason") != "compiler-artifact" or m["target"]["name"].replace("-", "_") != name.replace("-", "_"):
        continue
    if "custom-build" in m["target"]["kind"]:
        continue
    if field == "executable":
        if m.get("executable"):
            found.add(m["executable"])
    else:
        found.update(f for f in m["filenames"] if f.endswith(".rlib"))
if len(found) != 1:
    sys.exit(f"error: expected exactly one {field} for {name}, got {sorted(found)}")
print(found.pop())
PY
}

# ---- 1. bind mode -------------------------------------------------------------
# cargo -vv prefixes each line a build script prints with "[<package> <version>] ";
# the script's stdout lands in cargo's stdout, its stderr in cargo's stderr.
sed -n 's/^\[skia-bindings [^]]*\] //p' "${WORK}/messages.json" "${WORK}/build.log" > "${WORK}/skia-bindings.output"
[[ -s "${WORK}/skia-bindings.output" ]] || { tail -40 "${WORK}/build.log" >&2; fail "the skia-bindings build script did not run (no output in cargo's log)"; }
grep -q '^STARTING BIND AGAINST SYSTEM SKIA$' "${WORK}/skia-bindings.output" || fail "skia-bindings did not bind against the pack"
if grep -qE 'STARTING OFFLINE BUILD|DOWNLOAD|TRYING TO DOWNLOAD|ninja' "${WORK}/skia-bindings.output"; then
    fail "skia-bindings downloaded or built Skia"
fi
echo "bind(1) PASS: skia-bindings bound against the pack; no download, no Skia build"

# ---- 2. run -------------------------------------------------------------------
BIN="$(artifact skia-pack-rust-consumer executable)" || fail "locating the consumer executable"
RUST_CONSUMER_OUT="${WORK}/out" "${BIN}" > "${WORK}/run.log" 2>&1 || { cat "${WORK}/run.log" >&2; fail "rust consumer run"; }
hb_version="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['harfbuzz']['version'])" "${PACK_DIR}/pack.json")"
grep -q "^core stub: status 0, skia m157, harfbuzz ${hb_version}," "${WORK}/run.log" || { cat "${WORK}/run.log" >&2; fail "C++ side did not report Skia m157 with HarfBuzz ${hb_version}"; }
grep -q '^skia-safe: raster surface 32x32$' "${WORK}/run.log" || fail "Rust side did not draw"
lit="$(sed -n 's/^slint: snapshot .* pixels differing from the corner: \([0-9]*\)$/\1/p' "${WORK}/run.log")"
[[ -n "${lit}" ]] && (( lit > 1000 )) || { cat "${WORK}/run.log" >&2; fail "Slint window snapshot is missing or blank"; }
echo "run(2) PASS: $(grep '^core stub' "${WORK}/run.log"); Slint snapshot has ${lit} drawn pixels"

# ---- 3. the Skia in the executable is the pack's ------------------------------
rlib="$(artifact skia-bindings rlib)" || fail "locating the skia-bindings rlib"
rm -rf "${WORK}/objects"; mkdir -p "${WORK}/objects/rlib"
# Hashes of an archive's object members. Fails closed if two members share a
# name (ar x would silently keep only one of them).
extract_hashes() { # extract_hashes <archive> <scratch-dir>  -> sha256 list on stdout
    python3 - "$1" "$2" <<'PY'
import hashlib, pathlib, subprocess, sys
archive, scratch = sys.argv[1:3]
scratch = pathlib.Path(scratch); scratch.mkdir(parents=True, exist_ok=True)
names = [n for n in subprocess.check_output(["ar", "t", archive], text=True).splitlines() if n.endswith(".o")]
if len(set(names)) != len(names):
    sys.exit(f"error: {archive} has members with the same name; cannot compare objects")
subprocess.check_call(["ar", "x", archive], cwd=scratch)
for name in names:
    print(hashlib.sha256((scratch / name).read_bytes()).hexdigest())
PY
}
extract_hashes "${rlib}" "${WORK}/objects/rlib" | sort -u > "${WORK}/objects/rlib.sha"
total=0
for lib in libskia.a libskshaper.a libskparagraph.a libskunicode_core.a libskunicode_icu.a; do
    extract_hashes "${PACK_DIR}/lib/${lib}" "${WORK}/objects/${lib}" | sort -u > "${WORK}/objects/${lib}.sha"
    n="$(wc -l < "${WORK}/objects/${lib}.sha" | tr -d ' ')"
    absent="$(comm -23 "${WORK}/objects/${lib}.sha" "${WORK}/objects/rlib.sha" | wc -l | tr -d ' ')"
    [[ "${absent}" == "0" ]] || fail "identity(3): ${absent} of ${n} objects of the pack's ${lib} are not in the skia-bindings rlib byte for byte"
    (( n > 0 )) || fail "identity(3): ${lib} has no objects"
    total=$(( total + n ))
done
echo "identity(3) PASS: all ${total} distinct objects of the pack's five Skia archives are in the skia-bindings rlib byte for byte"

# ---- 4. one definition of everything ------------------------------------------
map="$(sed -n 's/^link map: //p' "${WORK}/run.log")"
[[ -f "${map}" ]] || fail "link map missing"
if [[ "$(uname -s)" == "Darwin" ]]; then
    dupes="$(nm -U "${BIN}" | awk '$2=="T"{print $3}' | sort | uniq -d | wc -l | tr -d ' ')"
    hb_defs="$(nm -U "${BIN}" | grep -cE ' [Tt] _hb_shape$' || true)"
    hb_sources="$(LC_ALL=C grep -oE '[^ /]+\.(a|rlib)(\[[0-9]+\])?\((hb-|harfbuzz)[^)]*\)' "${map}" | sed -E 's/(\[[0-9]+\])?\(.*//; s/-[0-9a-f]{16}\.rlib/.rlib/' | sort -u | tr '\n' ' ')"
else
    dupes="$(nm --defined-only "${BIN}" | awk '$2=="T"{print $3}' | sort | uniq -d | wc -l)"
    hb_defs="$(nm --defined-only "${BIN}" | grep -cE ' [Tt] hb_shape$' || true)"
    hb_sources="$(grep -oE '[^ /(]+\.(a|rlib)\((hb-|harfbuzz)[^)]*\)' "${map}" | sed -E 's/\(.*//; s/-[0-9a-f]{16}\.rlib/.rlib/' | sort -u | tr '\n' ' ')"
fi
[[ "${dupes}" == "0" ]] || fail "symbols(4): ${dupes} external text symbols are defined more than once"
[[ "${hb_defs}" == "1" ]] || fail "symbols(4): hb_shape is defined ${hb_defs} times (want 1)"
[[ "${hb_sources}" == "libharfbuzz.a " ]] || fail "symbols(4): HarfBuzz objects came from: ${hb_sources}(want only libharfbuzz.a)"
grep -qF "${PACK_DIR}/lib/libharfbuzz.a" "${map}" || fail "symbols(4): the link map does not name the pack's libharfbuzz.a"
echo "symbols(4) PASS: no external symbol defined twice; hb_shape defined once; HarfBuzz objects only from the pack's libharfbuzz.a"

echo
echo "[verify-rust-consumer] ALL CHECKS PASSED"
