#!/usr/bin/env python3
"""Preprocessor defines of a Skia build, in the form rust-skia expects.

usage: skia_defines.py write <skia-out-dir>            -> <skia-out-dir>/skia-defines.txt
       skia_defines.py check <platform> <defines-file>

`write` reproduces what skia-bindings 0.157.0 does after its own build
(build_support/skia_bindgen.rs, definitions::from_ninja_features, features
ganesh + textlayout): take the first `defines = ` line of a fixed list of
ninja files, split it, undo ninja's escaping, and keep the first occurrence
of each name. A Rust consumer passes the file's content to skia-bindings as
SKIA_BUILD_DEFINES when it binds to the pack instead of building Skia.

`check` compares such a file with the one rust-skia's own build of the same
Skia commit produced (gn/rust-skia/<platform>.defines.txt). Every difference
must be listed, with its reason, in gn/rust-skia/<platform>.allowed-diff.txt;
an entry there that no longer applies is an error too.
"""
import pathlib
import sys

NINJA_FILES = [
    "obj/skia.ninja",
    "obj/gpu.ninja",
    "obj/modules/skshaper/skshaper.ninja",
    "obj/modules/skparagraph/skparagraph.ninja",
    "obj/modules/skunicode/skunicode_core.ninja",
    "obj/modules/skunicode/skunicode_icu.ninja",
    "obj/third_party/icu/icu.ninja",
]
PREFIX = "defines = "


def unescape(text, escape):
    out, chars = [], iter(text)
    for ch in chars:
        if ch == escape:
            nxt = next(chars, None)
            if nxt is not None:
                out.append(nxt)
        else:
            out.append(ch)
    return "".join(out)


def from_ninja(out_dir):
    seen, result = set(), []
    for rel in NINJA_FILES:
        path = out_dir / rel
        if not path.is_file():
            sys.exit(f"error: missing ninja file {path}")
        line = next((l for l in path.read_text().splitlines() if l.startswith(PREFIX)), None)
        if line is None:
            sys.exit(f"error: no `defines = ` line in {path}")
        for token in line[len(PREFIX):].split():
            if not token.startswith("-D"):
                sys.exit(f"error: {path}: define without -D prefix: {token}")
            name, sep, value = token[2:].partition("=")
            if name in seen:
                continue
            seen.add(name)
            if sep:
                value = unescape(unescape(value, "$"), "\\")
                result.append(f"-D{name}={value}")
            else:
                result.append(f"-D{name}")
    return result


def read_defines(path):
    return [l.strip() for l in pathlib.Path(path).read_text().splitlines() if l.strip()]


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    if len(sys.argv) == 3 and sys.argv[1] == "write":
        out_dir = pathlib.Path(sys.argv[2])
        defines = from_ninja(out_dir)
        # Same file shape as skia-bindings: one per line, then an empty line.
        (out_dir / "skia-defines.txt").write_text("\n".join(defines) + "\n\n")
        print(f"[defines] {len(defines)} defines -> {out_dir / 'skia-defines.txt'}")
        return
    if len(sys.argv) == 4 and sys.argv[1] == "check":
        platform, ours_path = sys.argv[2], sys.argv[3]
        ours = set(read_defines(ours_path))
        theirs = set(read_defines(root / "gn" / "rust-skia" / f"{platform}.defines.txt"))
        allowed = {}
        for raw in (root / "gn" / "rust-skia" / f"{platform}.allowed-diff.txt").read_text().splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            sign, define = line.split(None, 1)
            if sign not in ("+", "-") or "#" not in raw:
                sys.exit(f"error: allowed-diff line needs '+|- -DNAME  # reason': {raw}")
            allowed[(sign, define.strip())] = raw
        actual = {("+", d) for d in ours - theirs} | {("-", d) for d in theirs - ours}
        unexplained = sorted(actual - set(allowed))
        stale = sorted(set(allowed) - actual)
        for sign, define in unexplained:
            print(f"FAIL: unexplained difference from rust-skia's defines: {sign} {define}", file=sys.stderr)
        for sign, define in stale:
            print(f"FAIL: allowed difference no longer exists: {sign} {define}", file=sys.stderr)
        if unexplained or stale:
            sys.exit(1)
        print(f"defines PASS ({platform}): {len(ours)} defines; {len(ours & theirs)} shared with rust-skia's "
              f"{len(theirs)}; {len(actual)} differences, all listed with a reason")
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
