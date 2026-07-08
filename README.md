# skia-pack

Versioned, prebuilt **Skia + HarfBuzz** static-library artifacts for macOS arm64 —
the single source of Skia for [slate-kit] and [term-kit], so that one process links
exactly **one Skia and one HarfBuzz**.

## What a release contains

Each release tag (`150.1.0` = `SK_MILESTONE.PACK.PATCH`) ships three immutable assets:

| Asset | Consumer | Contents |
|---|---|---|
| `skia-pack-<ver>-macos-arm64.tar.gz` | CMake | `pack.json` + `headers/` + `lib/` (individual `.a` archives + merged `libSkiaPack.a`) |
| `SkiaPack.xcframework.zip` | SwiftPM | single `macos-arm64` slice: `libSkiaPack.a` + `Headers/` (same layout) |
| `pack.json` | humans/CI | fully resolved manifest: Skia/HarfBuzz commits, GN args hash, deps externals, toolchain, artifact checksums |

The `headers/` tree is anchored so **one** `-I <pack>/headers` resolves every existing
include spelling: `#include "include/core/SkCanvas.h"`,
`#include "modules/skparagraph/include/Paragraph.h"`, and `#include <hb.h>` (48 flat
HarfBuzz headers at the root).

One HarfBuzz per process: Skia is built with `skia_use_system_harfbuzz=true` wired at
this repo's own HarfBuzz 14.2 checkout, so Skia's archives carry `hb_*` as *undefined*
symbols; the single shipped `lib/libharfbuzz.a` (CoreText on, subset on) is the only
definer. `scripts/verify.sh` enforces this as a release gate.

## Consuming

**SwiftPM** — this repo is itself a package whose only target is a remote binaryTarget:

```swift
.package(url: "https://github.com/soloholicx/skia-pack.git", exact: "150.1.0"),
// …
.target(name: "YourCore",
        dependencies: [.product(name: "SkiaPack", package: "skia-pack")])
```

**CMake** — download the tarball pinned by your repo's `skia-pack.lock`
(see slate-kit's `cmake/SkiaPack.cmake`), or point at a local build:
`-DSLATE_SKIA_PREBUILT_DIR=<skia-pack>/artifacts/skia-pack-150.1.0-macos-arm64`.

## Building locally

```bash
./scripts/build.sh                   # fetches pinned sources (pins.json → third_party/ clones),
                                     # then HarfBuzz archive + Skia archives (gn args: gn/macos.gn)
./scripts/package.sh                 # artifacts/ tarball + xcframework + pack.json
./scripts/verify.sh                  # symbol audits + smoke test on the release bytes
```

Sources are **not** submodules — SwiftPM recursively initializes submodules of git
dependencies, so submodules would make every consumer clone ~1.1 GB of Skia + HarfBuzz
history just to resolve a ~23 MB binary product. Instead `pins.json` records the upstream
URL + commit for each input, and `scripts/fetch_sources.sh` (run automatically by
`build.sh`) materializes them under the gitignored `third_party/` as plain clones.
`SKIA_PACK_REFERENCE_SKIA`/`SKIA_PACK_REFERENCE_HARFBUZZ` can point at local repos to
speed up a fresh clone.

Releases are cut with `scripts/release.sh` (tag == version string; assets uploaded via
`gh release create`; post-verified by a scratch consumer). Artifacts are immutable —
a botched release rolls forward as a PATCH bump, never a replacement.

## Design

The full architecture (versioning, HarfBuzz-unification mechanism and its validation,
consumption mechanics for both build systems, linking topology) lives in slate-kit:
`docs/limitless-integration/01-skia-pack-architecture.md`.

[slate-kit]: https://github.com/soloholicx/slate-kit
[term-kit]: https://github.com/soloholicx/term-kit
