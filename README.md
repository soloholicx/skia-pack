# skia-pack

Versioned, prebuilt **Skia + HarfBuzz** static-library artifacts for macOS arm64, iOS
arm64 and the iOS Simulator (arm64) —
the single source of Skia for [slate-kit] and [term-kit], so that one process links
exactly **one Skia and one HarfBuzz**.

## What a release contains

Each release tag (`150.2.1` = `SK_MILESTONE.PACK.PATCH`) ships three immutable assets:

| Asset | Consumer | Contents |
|---|---|---|
| `skia-pack-<ver>-macos-arm64.tar.gz` | CMake | `pack.json` + `headers/` + `lib/` (individual `.a` archives + merged `libSkiaPack.a`) |
| `SkiaPack.xcframework.zip` | SwiftPM | three slices — `macos-arm64`, `ios-arm64`, `ios-arm64-simulator` — each `libSkiaPack.a` + `Headers/` (same layout, one shared header tree). From 150.2.1 the zip carries no AppleDouble `._*` entries (`scripts/check_zip.sh`) |
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
| `macos-arm64` | macOS 14.0 | tarball + xcframework | Since 150.2.0 this slice is the 150.1.0 one **reused byte-for-byte** (same Skia/HarfBuzz pins; `pins.json` → `macos_base`). `verify.sh` proves every archive and header identical. |
| `ios-arm64` | iOS 17.0 | xcframework only | Built with `SK_METAL_WAIT_UNTIL_SCHEDULED` (from 150.2.1; see below) |
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

**iOS command-buffer scheduling (from 150.2.1).** Both iOS slices are built with
`-DSK_METAL_WAIT_UNTIL_SCHEDULED`: Ganesh's `GrMtlCommandBuffer::commit` then calls
`waitUntilScheduled` after every commit that does not wait for completion (synchronous
commits still wait for completion). This covers only the Metal command buffers Skia itself
commits, and only commits that succeed; it is not a background-safety guarantee on its own —
an app must still stop submitting GPU work once it is inactive. `verify.sh` (k) checks the
compiled objects of every release. The macOS slice is unaffected.

## Consuming

**SwiftPM** — this repo is itself a package whose only target is a remote binaryTarget:

```swift
.package(url: "https://github.com/soloholicx/skia-pack.git", exact: "150.2.1"),
// …
.target(name: "YourCore",
        dependencies: [.product(name: "SkiaPack", package: "skia-pack")])
```

**CMake** — download the tarball pinned by your repo's `skia-pack.lock`
(see slate-kit's `cmake/SkiaPack.cmake`), or point at a local build:
`-DSLATE_SKIA_PREBUILT_DIR=<skia-pack>/artifacts/skia-pack-150.2.1-macos-arm64`.

## Building locally

```bash
./scripts/build.sh ios-arm64            # fetches pinned sources (pins.json → third_party/ clones),
./scripts/build.sh ios-arm64-simulator  # then HarfBuzz archive + Skia archives (gn args: gn/ios*.gn)
./scripts/build.sh                      # macOS (gn/macos.gn) — only needed when pins.json has no
                                        # "macos_base"; otherwise the base release's slice is reused
./scripts/package.sh                    # artifacts/ tarball + three-slice xcframework + pack.json
./scripts/verify.sh                     # symbol audits, macOS identity, per-slice checks, smoke tests
./scripts/verify_consumer.sh local      # tests/consumer via SwiftPM from the release zip: macOS run, iOS + simulator link
tests/package/test_check_zip.sh         # self-tests of the zip-hygiene and SK_METAL_WAIT_UNTIL_SCHEDULED probes
tests/package/test_check_wait_scheduled.sh
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

Releases are cut locally with `scripts/release.sh`. The bytes are packaged **once**,
verified, frozen under `artifacts/release-<version>/`, and those exact bytes are what the
committed checksum names and what is uploaded:

1. preflight — clean tree, on `main`, level with `origin/main`; the version must have no
   tag, no GitHub release (draft or published) and no frozen artifacts. Re-running an
   existing version is refused.
2. build → package → verify → consumer check → freeze.
3. commit the frozen zip's checksum into `Package.swift`, push `main` (no tag yet).
4. create a **draft** release, upload the frozen assets, read each one back and compare.
5. publish — which is what creates the tag (== version string), so a tag never exists
   without its assets.
6. post-verify against the published product.

An interrupted release is continued with `scripts/release.sh --resume`, which never
rebuilds or repackages: it re-checks the frozen bytes and picks up where it stopped.
Assets are replaced only while the release is still a draft; a published release is
never uploaded to, modified or deleted from — a botched one rolls forward as a PATCH
bump. The script records the release commit and the GitHub release id, requires a
resume to stand on that commit, and re-reads the release immediately before every
upload, delete and publish: it must still be that release, still a draft, still
targeting that commit, and a failed query stops the run rather than counting as "no
release". Right before publishing it also re-checks that no tag of that name has appeared on
origin (an existing tag would win over the draft's target). A per-version lock keeps two
runs on one machine apart; an existing lock is always refused, never taken over — remove
a stale one by hand after confirming no release is running. All of that narrows, but cannot close, a race with someone publishing from another
machine — **enable GitHub's "immutable releases" setting on the repository** for a
server-side guarantee. `scripts/release.sh --check` runs only the preflight;
`tests/release/test_release.sh` exercises all of this against a fake `gh`.

`.github/workflows/release.yml` is **read-only**: when a release is published (or on
manual dispatch for a released version from 150.2.0 on — earlier tags lack the scripts) it downloads the assets on a clean runner and
runs `scripts/verify_published.sh` — tag, `Package.swift`, `pack.json` and bytes must
agree, then the release gate and the SwiftPM consumer check run against those bytes. It
never builds Skia and never uploads.

`.github/workflows/runner-precheck.yml` (manual, or automatically when the file itself changes
in a PR) proves the runner image still satisfies that job's conditions — pinned Xcode, pinned
simulator runtime, a device of the pinned type that boots, a process spawned inside it — with
nothing substituted and no retries. Run it before cutting a release; a green run describes the
image at that moment only.

## Design

The full architecture (versioning, HarfBuzz-unification mechanism and its validation,
consumption mechanics for both build systems, linking topology) lives in slate-kit:
`docs/limitless-integration/01-skia-pack-architecture.md`.

[slate-kit]: https://github.com/soloholicx/slate-kit
[term-kit]: https://github.com/soloholicx/term-kit
