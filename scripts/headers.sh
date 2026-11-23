#!/usr/bin/env bash
# Header staging, shared by scripts/package.sh (Apple slices, run on a Mac)
# and scripts/package_linux.sh (run on Linux). Sourced; expects SKIA_ROOT and
# HB_ROOT (the pinned checkouts).
#
#   stage_headers <dest>        the public tree every slice ships as headers/
#   stage_bind_headers <dest>   the tree rust-skia needs as SKIA_SOURCE_DIR
#   headers_tree_sha256 <dir>   one hash over a tree's relative paths + contents
#
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
    # modules/skunicode/include/SkUnicode.h -> "src/core/SkUTF.h" (src/base/ up
    # to m150). Self-contained: it pulls only include/private/base/SkAPI.h.
    # scripts/verify.sh checks it is the ONLY "src/..." spelling reachable
    # from the packaged tree.
    mkdir -p "${dest}/src/core"
    cp "${SKIA_ROOT}/src/core/SkUTF.h" "${dest}/src/core/"
}

# What skia-bindings compiles its C++ shims and runs bindgen against: it adds
# the Skia source root as the one include path, and its shims include private
# headers ("src/...", "modules/.../src/..."). Headers only — no .cpp, no
# third-party sources; the tests/rust-consumer build proves this is enough.
# Platform-independent: the same tree serves every slice.
stage_bind_headers() { # stage_bind_headers <dest>
    local dest="$1" dir
    mkdir -p "${dest}"
    for dir in include src modules; do
        (cd "${SKIA_ROOT}" && find "${dir}" -type f \( -name '*.h' -o -name '*.inc' \) -print0) \
            | (cd "${SKIA_ROOT}" && cpio -0 -pdm --quiet "${dest}")
    done
    cp "${SKIA_ROOT}/LICENSE" "${dest}/LICENSE"
}

# Order-independent of the file system: paths are sorted bytewise.
headers_tree_sha256() { # headers_tree_sha256 <dir>
    python3 - "$1" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    h.update(path.relative_to(root).as_posix().encode() + b"\0")
    h.update(hashlib.sha256(path.read_bytes()).digest())
print(h.hexdigest())
PY
}
