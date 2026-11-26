# skia-pack

Versioned, prebuilt **Skia + HarfBuzz** static-library artifacts for macOS arm64, iOS
arm64, the iOS Simulator (arm64) and Linux x86_64 —
the single source of Skia for [slate-kit] and [term-kit], so that one process links
exactly **one Skia and one HarfBuzz**. That includes processes with Rust code in them:
[rust-skia] 0.157.0 (and so Slint's Skia renderer) can bind to these archives instead of
building its own Skia — see [Rust consumers](#rust-consumers-rust-skia).

Skia is built from the project's own fork, [soloholicx/skia] branch `termkit/m157`:
upstream `chrome/m157` plus the commits rust-skia carries on top of it.

## What a release contains

Each release tag (`157.1.0` = `SK_MILESTONE.PACK.PATCH`) ships five immutable assets:

| Asset | Consumer | Contents |
|---|---|---|
| `skia-pack-<ver>-macos-arm64.tar.gz` | CMake, Cargo | `pack.json` + `skia-defines.txt` + `headers/` + `lib/` (individual `.a` archives + merged `libSkiaPack.a`) |
| `skia-pack-<ver>-linux-x86_64.tar.gz` | CMake, Cargo | `pack.json` + `skia-defines.txt` + `headers/` + `lib/` (individual `.a` archives) |
| `SkiaPack.xcframework.zip` | SwiftPM | three slices — `macos-arm64`, `ios-arm64`, `ios-arm64-simulator` — each `libSkiaPack.a` + `Headers/` (same layout, one shared header tree). The zip carries no AppleDouble `._*` entries (`scripts/check_zip.sh`) |
| `skia-pack-<ver>-skia-headers.tar.gz` | Cargo | Skia's headers, public and private, no sources — what rust-skia needs as `SKIA_SOURCE_DIR`. One tree for all slices. |
| `pack.json` | humans/CI | fully resolved manifest: Skia/HarfBuzz commits, GN args hash, deps externals, toolchain, artifact checksums |

The `headers/` tree is anchored so **one** `-I <pack>/headers` resolves every existing
include spelling: `#include "include/core/SkCanvas.h"`,
`#include "modules/skparagraph/include/Paragraph.h"`, and `#include <hb.h>` (48 flat
HarfBuzz headers at the root).

One HarfBuzz per process: Skia is built with `skia_use_system_harfbuzz=true` wired at
this repo's own HarfBuzz checkout (14.5.1, the commit Skia m157 itself pins), so Skia's
archives carry `hb_*` as *undefined* symbols; the single shipped `lib/libharfbuzz.a`
(CoreText on for Apple; the subset API SkPDF needs is merged in) is the only definer.
`scripts/verify.sh` and `scripts/verify_linux.sh` enforce this as a release gate.

**What is built.** The GN args are the set rust-skia generates for its `gl`, `metal` /
`vulkan`, `pdf` and `textlayout` features, plus the pack's own differences, each listed
with its reason in `gn/*.gn`: the standalone HarfBuzz, WebP kept on, C++20, deployment
targets. Compared with 150.x: SkPDF and the OpenGL backend (macOS, Linux) are now built,
Vulkan on Linux, and raw-photo (DNG) decoding is gone. `skia-defines.txt` lists the
preprocessor defines the build used; a release gate compares it with the file
rust-skia's own build of the same commit writes (`gn/rust-skia/`).

### Platforms

| Slice | Deployment target | Ships as | Notes |
|---|---|---|---|
| `macos-arm64` | macOS 14.0 | tarball + xcframework | |
| `linux-x86_64` | Ubuntu 22.04 (glibc 2.35, libstdc++ up to `GLIBCXX_3.4.30`) | tarball only | Clang 17 + libstdc++. Links the system's **FreeType** and **Fontconfig**; everything else is vendored. Built by the `build-linux` workflow, not on the release machine. No merged `libSkiaPack.a`. |
| `ios-arm64` | iOS 17.0 | xcframework only | Built with `SK_METAL_WAIT_UNTIL_SCHEDULED` and `UCONFIG_NO_FILE_IO=1` (see below) |
| `ios-arm64-simulator` | iOS 17.0 | xcframework only | **arm64 only** — simulators on Apple Silicon hosts. There is no x86_64 simulator slice. Same defines as `ios-arm64`. |

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

**iOS command-buffer scheduling (from 157.1.0).** Both iOS slices are built with
`-DSK_METAL_WAIT_UNTIL_SCHEDULED`: Ganesh's `GrMtlCommandBuffer::commit` then calls
`waitUntilScheduled` after every commit that does not wait for completion (synchronous
commits still wait for completion). This covers only the Metal command buffers Skia itself
commits, and only commits that succeed; it is not a background-safety guarantee on its own —
an app must still stop submitting GPU work once it is inactive. `verify.sh` (k) checks the
compiled objects of every release. The macOS slice is unaffected.

**iOS: `WrapCAMetalLayer` with no drawable.** A surface made with
`SkSurfaces::WrapCAMetalLayer` asks the layer for its drawable only when Skia flushes. If
`nextDrawable` returns nil at that point, the render pass has no render target. Under Metal API
validation that aborts the process ("No rendertargets set in RenderPassDescriptor"); without
validation no abort was seen. This was observed in the iOS Simulator only, and the same way with
150.2.0, the 150.2.1 candidate and 157.1.0, so it is existing Skia behaviour and not caused by the
wait above. Whether the wait happens on this path is not verified. Apps that cannot rule out a
nil drawable should acquire the drawable first, skip the frame when there is none, and wrap
its texture (for example with `SkSurfaces::WrapBackendTexture`).

**iOS: no ICU data-file loading (from 157.1.0).** Both iOS slices are built with
`-DUCONFIG_NO_FILE_IO=1`, so ICU common no longer loads data from files: the `ICU_DATA`
environment variable is not read, a directory set with `u_setDataDirectory` is recorded but
nothing is loaded from it, and `.dat` / `.res` files cannot be loaded by path or package
name. ICU uses the data linked into the archive (`icudt78`) by default; data an app hands
over in memory (`udata_setCommonData`, `udata_setAppData`, the `open` functions that take a
data pointer) is still supported. This covers ICU's own data loading only — Skia's and
HarfBuzz's file APIs are unchanged (see "Privacy manifest" below for what they access).
`verify.sh` (l) checks the compiled objects of every release. The macOS slice is
unaffected. Results compared on the iOS Simulator for one set of multilingual samples do not
show that every ICU use, or behaviour on a device, is unchanged.

## Privacy manifest (iOS)

The `SkiaPack` product carries `PrivacyInfo.xcprivacy` (`Sources/SkiaPackPrivacy/`) for the
required-reason APIs the prebuilt **iOS** libraries call. SwiftPM copies it into an iOS app
as `skia-pack_SkiaPackPrivacy.bundle`; macOS consumers get no bundle, because this manifest
covers the iOS slices only (the macOS slice has not been audited for it).

| API category | Reasons | Why |
|---|---|---|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1`, `3B52.1` | Skia and HarfBuzz call `stat`/`fstat` on files whose paths the app passes in (fonts, images, data). |

System boot time is not declared: it was for the DNG SDK's timer, which m157 slices do not
carry (`skia_use_dng_sdk=false`).

**Path contract.** The file-timestamp reasons hold only for these paths, and keeping to them
is the **calling app's** responsibility — skia-pack does not enforce it at run time:

* files inside the app's own container — `C617.1`;
* files the user explicitly granted access to (e.g. a document picker) — `3B52.1`;
* resources in the app's main bundle are treated as `C617.1`. This is this project's reading
  of the reason definitions, not a statement that Apple has approved this manifest.

Any other path is outside what the manifest declares. Note that Skia's own iOS fallback
stays in place: when a read-only open of a path fails, Skia looks up the same name as a
resource in the app's **main bundle** (`sk_fopen`, `sk_exists`, `sk_isdir` and the directory
iterator in `src/ports/SkOSFile_*.cpp`), so a file there can be accessed even though the app
passed a different path. ICU no longer reads data files on iOS (see above).

## Consuming

**SwiftPM** — this repo is itself a package; the `SkiaPack` product is a remote binaryTarget
plus two resource-wiring targets, `SkiaPackSupport` (all platforms) and `SkiaPackPrivacy`
(iOS only, via a conditional dependency). They have no headers and no API; a consumer does
not import them, and the product name, the headers, the frameworks and the linker flags are
the same as before:

```swift
.package(url: "https://github.com/soloholicx/skia-pack.git", exact: "157.1.0"),
// …
.target(name: "YourCore",
        dependencies: [.product(name: "SkiaPack", package: "skia-pack")])
```

**CMake** — download the tarball pinned by your repo's `skia-pack.lock`
(see slate-kit's `cmake/SkiaPack.cmake`), or point at a local build:
`-DSLATE_SKIA_PREBUILT_DIR=<skia-pack>/artifacts/skia-pack-157.1.0-macos-arm64`.
On Linux also link `-lfontconfig -lfreetype`, and put the archives in a
`-Wl,--start-group … -Wl,--end-group` (they reference each other).

### Rust consumers (rust-skia)

skia-bindings 0.157.0 skips its own download and build when it is told where a Skia is.
Extract the slice tarball for your platform and the `skia-headers` archive, then build with:

```bash
export SKIA_SOURCE_DIR=<skia-pack-<ver>-skia-headers>
export SKIA_LIBRARY_SEARCH_PATH=<skia-pack-<ver>-<platform>>/lib
export SKIA_BUILD_DEFINES="$(tr '\n' ' ' < <skia-pack-<ver>-<platform>>/skia-defines.txt)"
```

and link the pack's HarfBuzz from your own build script
(`cargo:rustc-link-search=native=<…>/lib`, `cargo:rustc-link-lib=static=harfbuzz`):
rust-skia's own build folds HarfBuzz into Skia's archives, the pack keeps it separate.
The build log of `skia-bindings` must say `STARTING BIND AGAINST SYSTEM SKIA`.
skia-safe needs the `textlayout` feature (the pack's archives are built with it). The
`svg` and `skottie` modules are not built; other optional features (`webp`, …) are not
covered by the gate.
C++ code in the same executable compiles against `headers/` with the same defines.

`tests/rust-consumer` is exactly this — Slint 1.19.0 with its Skia renderer plus a C++
library calling Skia, SkShaper, ICU and HarfBuzz, in one executable — and
`scripts/verify_rust_consumer.sh` is the gate on it: bind mode was taken, the program
runs, every object of the pack's Skia archives is in the binary's Skia byte for byte,
and no symbol is defined twice. This mode of skia-bindings is not documented upstream;
the gate is what keeps it honest for the pinned versions.

## Building locally

```bash
# On a Mac — the Apple slices:
./scripts/build.sh                      # macOS: fetches pinned sources (pins.json → third_party/ clones),
./scripts/build.sh ios-arm64            # then HarfBuzz archive + Skia archives (gn args: gn/*.gn)
./scripts/build.sh ios-arm64-simulator
SKIA_PACK_WITHOUT_LINUX=1 ./scripts/package.sh   # tarball + three-slice xcframework + skia-headers + pack.json
./scripts/verify.sh                     # symbol audits, defines, per-slice checks, smoke tests
./scripts/verify_consumer.sh local      # tests/consumer via SwiftPM: macOS run, iOS + simulator link
./scripts/verify_rust_consumer.sh build/verify/skia-pack-<ver>-macos-arm64 artifacts/skia-pack-<ver>-skia-headers
tests/package/test_check_zip.sh         # self-tests of the zip-hygiene and SK_METAL_WAIT_UNTIL_SCHEDULED probes
tests/package/test_check_wait_scheduled.sh
tests/package/test_check_icu_no_file_io.sh # self-test of the UCONFIG_NO_FILE_IO probe (verify.sh (l))
tests/package/test_check_privacy_carry.sh # self-test of the privacy-manifest carry checker (test-only fixture)
tests/package/test_consumer_counts.sh # self-test of verify_consumer.sh's counts (a failed find/grep is never a count)

# On Linux (Ubuntu 22.04; clang-17, cmake, ninja, libfreetype-dev, libfontconfig1-dev) — the Linux slice:
./scripts/build.sh linux-x86_64
./scripts/package_linux.sh              # artifacts/ tarball + linux-x86_64.json
./scripts/verify_linux.sh               # symbol audits, defines, smoke test, system baseline
xvfb-run -a ./scripts/verify_rust_consumer.sh build/verify-linux/skia-pack-<ver>-linux-x86_64 build/package/skia-headers
```

Without `SKIA_PACK_WITHOUT_LINUX=1`, `package.sh` includes the Linux slice: the candidate
of a `build-linux` workflow run, fetched and checked by
`scripts/fetch_linux_candidate.sh <run-id>` (it must have been built by a successful run
on the commit you are standing on, and its bytes must match its manifest). The slice is
built on a GitHub-hosted `ubuntu-22.04` runner because that is the baseline it promises;
`verify_linux.sh` fails on a machine with a newer libstdc++.

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

0. run the `build-linux` workflow on the commit to be released, then
   `scripts/fetch_linux_candidate.sh <run-id>`.
1. preflight — clean tree, on `main`, level with `origin/main`; the version must have no
   tag, no GitHub release (draft or published) and no frozen artifacts; the Linux
   candidate is a slice of this commit from a successful run. Re-running an existing
   version is refused.
2. build → package → verify → consumer check → Rust consumer check → freeze.
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
agree, then the release gate and the SwiftPM consumer check run against those bytes; a
second job runs the Linux slice's gate and the Rust consumer gate on `ubuntu-22.04`
(`scripts/verify_published_linux.sh`). It never builds Skia and never uploads.

`.github/workflows/build-linux.yml` (manual only) is the one place CI compiles: it builds
the Linux slice candidate, runs its gates, and keeps it as a workflow artifact. It has
read-only permissions and publishes nothing.

`.github/workflows/runner-precheck.yml` (manual, or automatically when the file itself changes
in a PR) proves the runner image still satisfies that job's conditions — pinned Xcode, pinned
simulator runtime, a device of the pinned type that boots, a process spawned inside it — with
nothing substituted and no retries. Run it before cutting a release; a green run describes the
image at that moment only.

## Design

The full architecture (versioning, HarfBuzz-unification mechanism and its validation,
consumption mechanics for both build systems, linking topology) lives in slate-kit:
`docs/limitless-integration/01-skia-pack-architecture.md`.

[rust-skia]: https://github.com/rust-skia/rust-skia
[soloholicx/skia]: https://github.com/soloholicx/skia
[slate-kit]: https://github.com/soloholicx/slate-kit
[term-kit]: https://github.com/soloholicx/term-kit
