// swift-tools-version: 5.10
// skia-pack SwiftPM facade: the package's only target is a remote binaryTarget
// pointing at the versioned, immutable release artifact. Both slate-kit and
// term-kit depend on this package with `exact:` pins; SwiftPM's package-identity
// machinery then guarantees exactly one Skia + one HarfBuzz per process (or
// fails resolution loudly on a mismatch).
//
// Dev-mode escape hatch: when iterating against an unreleased pack, set
//   SKIA_PACK_LOCAL_XCFRAMEWORK=build/verify/xcframework/SkiaPack.xcframework
// (SwiftPM requires the path to be RELATIVE to this package's root)
// (honored when this manifest is (re-)evaluated — intended for use with
// `swift package edit skia-pack --path …` from a consumer, or when skia-pack
// itself is the root package). Caveat: SwiftPM caches manifests — after
// toggling, run `swift package purge-cache` or delete .build.
import Foundation
import PackageDescription

let binaryTarget: Target
if let localPath = ProcessInfo.processInfo.environment["SKIA_PACK_LOCAL_XCFRAMEWORK"] {
    binaryTarget = .binaryTarget(name: "SkiaPackBinary", path: localPath)
} else {
    binaryTarget = .binaryTarget(
        name: "SkiaPackBinary",
        url: "https://github.com/soloholicx/skia-pack/releases/download/150.2.0/SkiaPack.xcframework.zip",
        checksum: "26b4cb5327b2d2d64820431c0b2e68241fbd57c37ab1abe69d9c6c25acf40291")
}

let package = Package(
    name: "skia-pack",
    products: [
        .library(name: "SkiaPack", targets: ["SkiaPackBinary"])
    ],
    targets: [binaryTarget]
)
