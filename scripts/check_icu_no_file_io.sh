#!/usr/bin/env bash
# Is ICU's data-file loading compiled out of a slice (UCONFIG_NO_FILE_IO=1)?
# Reads the objects, never the GN args.
#
#   check_icu_no_file_io.sh <libSkiaPack.a> <on|off>
#
# 'on' = compiled out, 'off' = ICU loads data files as usual:
#   1. libicu.umapfile.o, nm -u: _stat, _open and _mmap are all absent (on) /
#      all referenced (off) — uprv_mapFile is MAP_NONE when the macro is set
#   2. libicu.putil.o: the string "ICU_DATA" is absent (on) / present (off) —
#      putil stops reading the environment override
# A slice in neither state (some but not all of these) matches neither mode.
# Positive controls, in both modes (a probe that cannot see these is broken,
# not "on"): libicu.umapfile.o defines _uprv_mapFile and references
# _UDataMemory_init (the MAP_NONE uprv_mapFile still clears its output with
# it); Skia's and HarfBuzz's own file APIs are untouched — libskia.SkOSFile_posix.o references _fstat,
# libskia.SkOSFile_stdio.o references _stat, harfbuzz.cc.o references _fstat.
#
# Every member above must be present; a name may occur more than once in the
# archive (it does for umapfile/putil), and then every copy must be
# byte-identical — each copy is extracted and compared (ar -x would keep only
# the last one).
#
# Fail closed, as scripts/check_wait_scheduled.sh: every tool's exit status is
# checked separately from its output, and every search is three-state — found
# (0), absent (1), error (anything else). A tool or search error is a PROBE
# ERROR (exit 3); it never counts as "absent", so it can neither pass 'on'
# nor stand in for an expected rejection.
#
# Exit: 0 the slice matches <on|off>; 1 it does not; 3 probe/environment error.
set -uo pipefail

LIB="${1:-}"; MODE="${2:-}"
[[ -n "${LIB}" && ( "${MODE}" == on || "${MODE}" == off ) && $# -eq 2 ]] \
    || { echo "usage: check_icu_no_file_io.sh <libSkiaPack.a> <on|off>" >&2; exit 3; }
SLICE="$(basename "$(dirname "${LIB}")")"
probe() { echo "check_icu_no_file_io: PROBE ERROR (${SLICE}): $*" >&2; exit 3; }
[[ -f "${LIB}" ]] || probe "no such archive: ${LIB}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check_icu_no_file_io.XXXXXX")" || probe "mktemp failed"
trap 'rm -rf "${WORK}"' EXIT

UMAPFILE=libicu.umapfile.o PUTIL=libicu.putil.o
SK_POSIX=libskia.SkOSFile_posix.o SK_STDIO=libskia.SkOSFile_stdio.o HB=harfbuzz.cc.o

# search <file> <grep args…>: prints found|absent; any other grep status is a probe error.
search() {
    local file="$1"; shift
    grep -q "$@" -- "${file}"
    case $? in
        0) echo found ;;
        1) echo absent ;;
        *) return 1 ;;
    esac
}

# Extract every copy of each wanted member as <WORK>/<name> after checking the
# copies are identical. Prints "<name> <copies>" per member.
python3 - "${LIB}" "${WORK}" "${UMAPFILE}" "${PUTIL}" "${SK_POSIX}" "${SK_STDIO}" "${HB}" > "${WORK}/members" 2> "${WORK}/split.err" <<'PY'
import hashlib, os, sys
lib, out, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
d = open(lib, "rb").read()
if d[:8] != b"!<arch>\n":
    sys.exit("not a plain ar archive (fat or not an archive)")
copies, off = {}, 8
while off < len(d):
    h = d[off:off + 60]
    if len(h) != 60 or h[58:60] != b"`\n":
        sys.exit(f"malformed member header at offset {off}")
    name = h[:16].decode("ascii").rstrip()
    size = int(h[48:58].decode("ascii").strip())
    off += 60
    body = d[off:off + size]
    if len(body) != size:
        sys.exit(f"member {name} truncated")
    if name.startswith("#1/"):
        k = int(name[3:]); name = body[:k].rstrip(b"\0").decode(); body = body[k:]
    if name in wanted:
        copies.setdefault(name, []).append(body)
    off += size + (size & 1)
for name in wanted:
    bodies = copies.get(name, [])
    if not bodies:
        sys.exit(f"member {name} not found")
    if len({hashlib.sha256(b).hexdigest() for b in bodies}) != 1:
        sys.exit(f"{len(bodies)} copies of {name} differ")
    open(os.path.join(out, name), "wb").write(bodies[0])
    print(name, len(bodies))
PY
rc=$?
[[ "${rc}" == 0 ]] || probe "splitting the archive failed (rc=${rc}): $(tail -1 "${WORK}/split.err")"
for m in "${UMAPFILE}" "${PUTIL}" "${SK_POSIX}" "${SK_STDIO}" "${HB}"; do
    r="$(search "${WORK}/members" -E "^${m//./\\.} [1-9][0-9]*$")" || probe "grep failed (member list)"
    [[ "${r}" == found && -s "${WORK}/${m}" ]] || probe "member ${m} was not extracted"
done

# undefined <member>: nm -u into <WORK>/<member>.u; an nm failure or empty output is a probe error.
undefined() {
    nm -u "${WORK}/$1" > "${WORK}/$1.u" 2> "${WORK}/$1.nm.err" || probe "nm -u failed on $1: $(head -1 "${WORK}/$1.nm.err")"
    [[ -s "${WORK}/$1.u" ]] || probe "nm -u printed nothing for $1"
}
for m in "${UMAPFILE}" "${SK_POSIX}" "${SK_STDIO}" "${HB}"; do undefined "${m}"; done
nm -g "${WORK}/${UMAPFILE}" > "${WORK}/umapfile.g" 2> "${WORK}/umapfile.g.err" || probe "nm -g failed on ${UMAPFILE}: $(head -1 "${WORK}/umapfile.g.err")"

r="$(search "${WORK}/umapfile.g" -E '^[0-9a-f]+ T _uprv_mapFile$')" || probe "grep failed (positive control _uprv_mapFile)"
[[ "${r}" == found ]] || probe "positive control: ${UMAPFILE} does not define _uprv_mapFile"
for pair in "${UMAPFILE}:_UDataMemory_init" "${SK_POSIX}:_fstat" "${SK_STDIO}:_stat" "${HB}:_fstat"; do
    m="${pair%%:*}" sym="${pair#*:}"
    r="$(search "${WORK}/${m}.u" -x "${sym}")" || probe "grep failed (positive control ${m} ${sym})"
    [[ "${r}" == found ]] || probe "positive control: ${m} does not reference ${sym}"
done

state=""
for sym in _stat _open _mmap; do
    r="$(search "${WORK}/${UMAPFILE}.u" -x "${sym}")" || probe "grep failed (${UMAPFILE} ${sym})"
    state+="umapfile${sym}=${r} "
done
r="$(search "${WORK}/${PUTIL}" -a -F 'ICU_DATA')" || probe "grep failed (${PUTIL} ICU_DATA)"
state+="putil:ICU_DATA=${r}"

want=found; [[ "${MODE}" == on ]] && want=absent
if [[ "${state}" == "umapfile_stat=${want} umapfile_open=${want} umapfile_mmap=${want} putil:ICU_DATA=${want}" ]]; then
    echo "check_icu_no_file_io: ${SLICE} is '${MODE}' (${state}; positive controls present)"
    exit 0
fi
echo "check_icu_no_file_io: ${SLICE} is NOT '${MODE}' (${state})" >&2
exit 1
