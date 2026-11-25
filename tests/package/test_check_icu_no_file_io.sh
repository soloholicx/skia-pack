#!/usr/bin/env bash
# Self-test for scripts/check_icu_no_file_io.sh on synthetic archives (no Skia
# build needed). Tiny stand-ins for the five members the checker reads are
# compiled for iOS — ICU's umapfile with and without the stat/open/mmap calls,
# putil with and without the "ICU_DATA" string, and Skia's / HarfBuzz's file
# API users — and archived under the member names the real archives use. The
# checker must classify each archive correctly, and must report a PROBE ERROR
# (rc 3, never "on" or "off") when a member or positive control is missing,
# copies of a member differ, or a tool fails.
set -uo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# CHECK_ICU_NO_FILE_IO overrides the probe under test (used to show this test
# rejects a fail-open version of it).
CHECK="${CHECK_ICU_NO_FILE_IO:-${PACK_ROOT}/scripts/check_icu_no_file_io.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_check_icu_no_file_io.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
failures=0 cases=0

src() { printf '%s\n' "${@:2}" > "${WORK}/$1.c"; }
# Like ICU's umapfile.cpp, every variant clears its output with UDataMemory_init
# (also the MAP_NONE one the macro selects), so 'on' still has an import.
src umapfile_off '#include <fcntl.h>' '#include <sys/mman.h>' '#include <sys/stat.h>' 'void UDataMemory_init(void **);' \
    'int uprv_mapFile(void **out, const char *path) {' \
    '    UDataMemory_init(out); struct stat s; if (stat(path, &s)) return 0;' \
    '    int fd = open(path, O_RDONLY); if (fd < 0) return 0;' \
    '    *out = mmap(0, (size_t)s.st_size, PROT_READ, MAP_SHARED, fd, 0); return *out != MAP_FAILED; }'
src umapfile_on 'void UDataMemory_init(void **);' 'int uprv_mapFile(void **out, const char *path) { (void)path; UDataMemory_init(out); return 0; }'
src umapfile_noinit 'int uprv_mapFile(void **out, const char *path) { (void)path; *out = 0; return 0; }'
src umapfile_mmap_only '#include <sys/mman.h>' 'void UDataMemory_init(void **);' \
    'int uprv_mapFile(void **out, const char *path) { (void)path; UDataMemory_init(out); *out = mmap(0, 4096, PROT_READ, MAP_SHARED, 3, 0); return *out != MAP_FAILED; }'
src umapfile_nodef 'int uprv_unrelated(void) { return 0; }'
src putil_off '#include <stdlib.h>' 'const char *icu_data_env(void) { return getenv("ICU_DATA"); }'
src putil_on 'const char *icu_data_dir(void) { return ""; }'
src sk_posix '#include <sys/stat.h>' 'long sk_fsize(int fd) { struct stat s; return fstat(fd, &s) ? -1 : (long)s.st_size; }'
src sk_stdio '#include <sys/stat.h>' 'int sk_exists(const char *p) { struct stat s; return stat(p, &s) == 0; }'
src hb '#include <sys/stat.h>' 'long hb_blob_size(int fd) { struct stat s; return fstat(fd, &s) ? -1 : (long)s.st_size; }'
src nofile 'int no_file_api(void) { return 1; }'

cc_ios() { xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -O1 -c "$@"; }
for f in umapfile_off umapfile_on umapfile_noinit umapfile_mmap_only umapfile_nodef putil_off putil_on sk_posix sk_stdio hb nofile; do
    cc_ios "${WORK}/${f}.c" -o "${WORK}/${f}.o" || { echo "ENVIRONMENT: cannot compile fixture ${f}"; exit 2; }
done
# The fixtures must reference the symbols the real archives do, or the test proves nothing.
for pair in umapfile_off:_stat umapfile_off:_open umapfile_off:_mmap umapfile_on:_UDataMemory_init sk_posix:_fstat sk_stdio:_stat hb:_fstat; do
    nm -u "${WORK}/${pair%%:*}.o" | grep -qx "${pair#*:}" \
        || { echo "ENVIRONMENT: fixture ${pair%%:*} does not reference ${pair#*:}"; exit 2; }
done
grep -qaF ICU_DATA "${WORK}/putil_off.o" || { echo "ENVIRONMENT: fixture putil_off has no ICU_DATA string"; exit 2; }

# make_lib <name> <member=object>…: an archive libSkiaPack.a with those members, in order.
make_lib() {
    local dir="${WORK}/lib-$1"; shift
    mkdir -p "${dir}/out"
    local i=0 spec
    for spec in "$@"; do
        i=$((i + 1)); mkdir -p "${dir}/m${i}"; cp "${WORK}/${spec#*=}.o" "${dir}/m${i}/${spec%%=*}"
        (cd "${dir}/m${i}" && ar -q "${dir}/out/libSkiaPack.a" "${spec%%=*}" 2>/dev/null) || { echo "ENVIRONMENT: ar -q failed"; exit 2; }
    done
    echo "${dir}/out/libSkiaPack.a"
}
CONTROLS=(libskia.SkOSFile_posix.o=sk_posix libskia.SkOSFile_stdio.o=sk_stdio harfbuzz.cc.o=hb)
# Like the real archives: umapfile and putil occur twice (identical copies), among unrelated members.
ON="$(make_lib on other.o=nofile libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on "${CONTROLS[@]}" libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on)"
OFF="$(make_lib off other.o=nofile libicu.umapfile.o=umapfile_off libicu.putil.o=putil_off "${CONTROLS[@]}" libicu.umapfile.o=umapfile_off libicu.putil.o=putil_off)"
ON_SINGLE="$(make_lib on-single libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on "${CONTROLS[@]}")"
ONLY_ICU_DATA="$(make_lib only-icu-data libicu.umapfile.o=umapfile_on libicu.putil.o=putil_off "${CONTROLS[@]}")"
ONLY_MMAP="$(make_lib only-mmap libicu.umapfile.o=umapfile_mmap_only libicu.putil.o=putil_on "${CONTROLS[@]}")"
NO_DATAMEM_INIT="$(make_lib no-datamem-init libicu.umapfile.o=umapfile_noinit libicu.putil.o=putil_on "${CONTROLS[@]}")"
NO_MAPFILE_DEF="$(make_lib no-mapfile-def libicu.umapfile.o=umapfile_nodef libicu.putil.o=putil_on "${CONTROLS[@]}")"
COPIES_DIFFER="$(make_lib copies-differ libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on "${CONTROLS[@]}" libicu.umapfile.o=umapfile_off)"
NO_UMAPFILE="$(make_lib no-umapfile libicu.putil.o=putil_on "${CONTROLS[@]}")"
NO_PUTIL="$(make_lib no-putil libicu.umapfile.o=umapfile_on "${CONTROLS[@]}")"
NO_SK_POSIX="$(make_lib no-sk-posix libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on libskia.SkOSFile_stdio.o=sk_stdio harfbuzz.cc.o=hb)"
SK_POSIX_NOFSTAT="$(make_lib sk-posix-nofstat libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on libskia.SkOSFile_posix.o=nofile libskia.SkOSFile_stdio.o=sk_stdio harfbuzz.cc.o=hb)"
SK_STDIO_NOSTAT="$(make_lib sk-stdio-nostat libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on libskia.SkOSFile_posix.o=sk_posix libskia.SkOSFile_stdio.o=nofile harfbuzz.cc.o=hb)"
HB_NOFSTAT="$(make_lib hb-nofstat libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on libskia.SkOSFile_posix.o=sk_posix libskia.SkOSFile_stdio.o=sk_stdio harfbuzz.cc.o=nofile)"
NO_HB="$(make_lib no-hb libicu.umapfile.o=umapfile_on libicu.putil.o=putil_on libskia.SkOSFile_posix.o=sk_posix libskia.SkOSFile_stdio.o=sk_stdio)"
TRUNCATED="${WORK}/truncated.a"; head -c 2000 "${ON}" > "${TRUNCATED}"

expect() { # expect <name> <want-rc> <check args…>
    local name="$1" want="$2" out rc; shift 2
    cases=$((cases + 1))
    out="$("${CHECK}" "$@" 2>&1)"; rc=$?
    if [[ "${rc}" == "${want}" ]] && { [[ "${want}" != 3 ]] || grep -qF "PROBE ERROR" <<< "${out}" || grep -qF "usage:" <<< "${out}"; }; then
        echo "ok   ${name} (rc=${rc})"
    else
        echo "FAIL ${name}: want rc=${want}, got rc=${rc}: ${out}"; failures=$((failures + 1))
    fi
}
# verdicts
expect "compiled out, mode on"                              0 "${ON}" on
expect "compiled out (single copies), mode on"              0 "${ON_SINGLE}" on
expect "compiled out, mode off is rejected"                 1 "${ON}" off
expect "file loading present, mode off"                     0 "${OFF}" off
expect "file loading present, mode on is rejected"          1 "${OFF}" on
expect "only ICU_DATA left in putil, mode on is rejected"   1 "${ONLY_ICU_DATA}" on
expect "only ICU_DATA left in putil, mode off is rejected"  1 "${ONLY_ICU_DATA}" off
expect "only _mmap left in umapfile, mode on is rejected"   1 "${ONLY_MMAP}" on
expect "only _mmap left in umapfile, mode off is rejected"  1 "${ONLY_MMAP}" off
# probe errors: a missing member, control or consistent copy is never a verdict
for mode in on off; do
    expect "umapfile does not define uprv_mapFile (${mode})" 3 "${NO_MAPFILE_DEF}" "${mode}"
    expect "umapfile without UDataMemory_init (${mode})"   3 "${NO_DATAMEM_INIT}" "${mode}"
    expect "copies of umapfile differ (${mode})"             3 "${COPIES_DIFFER}" "${mode}"
    expect "no umapfile member (${mode})"                    3 "${NO_UMAPFILE}" "${mode}"
    expect "no putil member (${mode})"                       3 "${NO_PUTIL}" "${mode}"
    expect "no SkOSFile_posix member (${mode})"              3 "${NO_SK_POSIX}" "${mode}"
    expect "SkOSFile_posix without fstat (${mode})"          3 "${SK_POSIX_NOFSTAT}" "${mode}"
    expect "SkOSFile_stdio without stat (${mode})"           3 "${SK_STDIO_NOSTAT}" "${mode}"
    expect "harfbuzz without fstat (${mode})"                3 "${HB_NOFSTAT}" "${mode}"
    expect "no harfbuzz member (${mode})"                    3 "${NO_HB}" "${mode}"
    expect "truncated archive (${mode})"                     3 "${TRUNCATED}" "${mode}"
    expect "not an archive (${mode})"                        3 /etc/hosts "${mode}"
    expect "no such file (${mode})"                          3 "${WORK}/missing.a" "${mode}"
done
expect "usage: no arguments"                                3
expect "usage: one argument"                                3 "${ON}"
expect "usage: bad mode"                                    3 "${ON}" maybe
expect "usage: extra argument"                              3 "${ON}" on extra

# Tool-failure negative controls. A shim directory placed first on PATH makes
# one tool fail — exit 2 after producing its normal output ("after-output"),
# exit 2 with no output ("no-output"), or exit 0 with no output ("empty-ok") —
# either on every call or only on calls whose arguments contain <match> (so a
# single search or subcommand fails while the rest of the probe works). Every
# case must be a probe error (rc 3), in BOTH modes and on BOTH archives: a tool
# error must never pass 'on' or 'off', and never stand in for a rejection.
make_shim() { # make_shim <dir> <tool> <after-output|no-output|empty-ok> [match]
    local dir="$1" tool="$2" how="$3" match="${4:-}" real
    real="$(command -v "$2")"
    mkdir -p "${dir}"
    {
        echo '#!/bin/bash'
        printf 'case "$*" in *%q*) ;; *) exec "%s" "$@" ;; esac\n' "${match}" "${real}"
        case "${how}" in
            after-output) printf '"%s" "$@"\nexit 2\n' "${real}" ;;
            no-output) echo 'exit 2' ;;
            empty-ok) echo 'cat > /dev/null 2>&1 < /dev/null; exit 0' ;;
        esac
    } > "${dir}/${tool}"
    chmod +x "${dir}/${tool}"
}
expect_fault() { # expect_fault <label> <shim-dir>
    local lib mode out rc
    for lib in "${ON}" "${OFF}"; do
        for mode in on off; do
            cases=$((cases + 1))
            out="$(PATH="$2:${PATH}" "${CHECK}" "${lib}" "${mode}" 2>&1)"; rc=$?
            if [[ "${rc}" == 3 ]] && grep -qF "PROBE ERROR" <<< "${out}"; then
                echo "ok   fault: $1 — $(basename "$(dirname "$(dirname "${lib}")")"), mode ${mode} (rc=3)"
            else
                echo "FAIL fault: $1 — ${lib} mode ${mode}: want rc=3 PROBE ERROR, got rc=${rc}: ${out}"
                failures=$((failures + 1))
            fi
        done
    done
}
for how in after-output no-output empty-ok; do
    for spec in "nm:" "nm:-u" "nm:-g" "python3:" "grep:" "grep:_stat" "grep:_open" "grep:_mmap" "grep:ICU_DATA" \
                "grep:uprv_mapFile" "grep:_UDataMemory_init" "grep:_fstat" "grep:members"; do
        tool="${spec%%:*}"; match="${spec#*:}"; d="${WORK}/shim-${tool}-${how}-${match:-all}"
        # a grep that exits 0 with no output would read as "found": that is a
        # wrong answer from a working tool, not a tool failure — not modelled
        [[ "${tool}" == grep && "${how}" == empty-ok ]] && continue
        make_shim "${d}" "${tool}" "${how}" "${match}"
        if [[ -n "${match}" ]]; then scope="only calls with '${match}'"; else scope="every call"; fi
        expect_fault "${tool} ${how} (${scope})" "${d}"
    done
done
mkdir -p "${WORK}/shim-mktemp"; printf '#!/bin/bash\nexit 1\n' > "${WORK}/shim-mktemp/mktemp"; chmod +x "${WORK}/shim-mktemp/mktemp"
expect_fault "mktemp fails" "${WORK}/shim-mktemp"

echo
if (( failures )); then echo "[test_check_icu_no_file_io] ${failures} of ${cases} FAILED"; exit 1; fi
echo "[test_check_icu_no_file_io] ALL ${cases} PASSED"
