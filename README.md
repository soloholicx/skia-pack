# skia-pack

Versioned, prebuilt **Skia + HarfBuzz** static-library artifacts for macOS arm64, iOS
arm64 and the iOS Simulator (arm64) —
the single source of Skia for [slate-kit] and [term-kit], so that one process links
exactly **one Skia and one HarfBuzz**.

## What a release contains

Each release tag (`150.2.0` = `SK_MILESTONE.PACK.PATCH`) ships three immutable assets:

| Asset | Consumer | Contents |
|---|---|---|
| `skia-pack-<ver>-macos-arm64.tar.gz` | CMake | `pack.json` + `headers/` + `lib/` (individual `.a` archives + merged `libSkiaPack.a`) |
| `SkiaPack.xcframework.zip` | SwiftPM | three slices — `macos-arm64`, `ios-arm64`, `ios-arm64-simulator` — each `libSkiaPack.a` + `Headers/` (same layout, one shared header tree) |
| `pack.json` | humans/CI | fully resolved manifest: Skia/HarfBuzz commits, GN args hash, deps externals, toolchain, artifact checksums |

The `headers/` tree is anchored so **one** `-I <pack>/headers` resolves every existing
include spelling: `#include "include/core/SkCanvas.h"`,
`#include "modules/skparagraph/include/Paragraph.h"`, and `#include <hb.h>` (48 flat
HarfBuzz headers at the root).

One HarfBuzz per process: Skia is built with `skia_use_system_harfbuzz=true` wired at
this repo's own HarfBuzz 14.2 checkout, so Skia's archives carry `hb_*` as *undefined*
symbols; the single shipped `lib/libharfbuzz.a` (CoreText on, subset on) is the only
definer. `scripts/verify.sh` enforces this as a release gate.

### Platforms

| Slice | Deployment target | Ships as | Notes |
|---|---|---|---|
| `macos-arm64` | macOS 14.0 | tarball + xcframework | In 150.2.0 this slice is the 150.1.0 one **reused byte-for-byte** (same Skia/HarfBuzz pins; `pins.json` → `macos_base`). `verify.sh` proves every archive and header identical. |
| `ios-arm64` | iOS 17.0 | xcframework only | |
| `ios-arm64-simulator` | iOS 17.0 | xcframework only | **arm64 only** — simulators on Apple Silicon hosts. There is no x86_64 simulator slice. |

There is no iOS tarball: the tarball exists for CMake consumers, and none build for iOS.

**Simulator builds and x86_64.** Building for a concrete simulator (Xcode's Run, or
`-destination 'platform=iOS Simulator,id=…'`) builds only the active architecture and
needs nothing special. A *generic* simulator build
(`-destination 'generic/platform=iOS Simulator'`) is universal by default and fails to
link for x86_64; pass `ARCHS=arm64` for that invocation (or set `EXCLUDED_ARCHS[sdk=iphonesimulator*]=x86_64`
on the consuming target). `scripts/verify_consumer.sh` checks all three statements.

On iOS, link `Metal`, `Foundation`, `CoreFoundation`, `CoreGraphics`, `CoreText`,
`QuartzCore`, `IOSurface` and `UIKit` (the macOS list's `AppKit`, `CoreServices`,
`MetalKit` and `OpenGL` do not apply).

Skia's iOS toolchain emits fat `arm64 + arm64e` archives; the pack ships `arm64` only.

## Consuming

**SwiftPM** — this repo is itself a package whose only target is a remote binaryTarget:

```swift
.package(url: "https://github.com/soloholicx/skia-pack.git", exact: "150.2.0"),
// …
.target(name: "YourCore",
        dependencies: [.product(name: "SkiaPack", package: "skia-pack")])
```

**CMake** — download the tarball pinned by your repo's `skia-pack.lock`
(see slate-kit's `cmake/SkiaPack.cmake`), or point at a local build:
`-DSLATE_SKIA_PREBUILT_DIR=<skia-pack>/artifacts/skia-pack-150.2.0-macos-arm64`.

## Building locally

```bash
./scripts/build.sh ios-arm64            # fetches pinned sources (pins.json → third_party/ clones),
./scripts/build.sh ios-arm64-simulator  # then HarfBuzz archive + Skia archives (gn args: gn/ios*.gn)
./scripts/build.sh                      # macOS (gn/macos.gn) — only needed when pins.json has no
                                        # "macos_base"; otherwise the base release's slice is reused
./scripts/package.sh                    # artifacts/ tarball + three-slice xcframework + pack.json
./scripts/verify.sh                     # symbol audits, macOS identity, per-slice checks, smoke tests
./scripts/verify_consumer.sh local      # tests/consumer via SwiftPM: macOS run, iOS + simulator link
```

`verify.sh` runs the simulator slice's smoke test inside a **booted simulator**
(`SKIA_PACK_SIM_UDID=<udid>`, else any booted device) and fails without one;
`SKIA_PACK_VERIFY_SKIP_SIM_RUN=1` skips that step explicitly and is reported as a skip.

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
