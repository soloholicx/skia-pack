// swift-tools-version: 5.10
// skia-pack SwiftPM facade: the package's only target is a remote binaryTarget
// pointing at the versioned, immutable release artifact. Both slate-kit and
// term-kit depend on this package with `exact:` pins; SwiftPM's package-identity
// machinery then guarantees exactly one Skia + one HarfBuzz per process (or
// fails resolution loudly on a mismatch).
//
// Dev-mode escape hatch: when iterating against an unreleased pack, set
//   SKIA_PACK_LOCAL_XCFRAMEWORK=/abs/path/to/SkiaPack.xcframework
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
        url: "https://github.com/soloholicx/skia-pack/releases/download/150.1.0/SkiaPack.xcframework.zip",
        checksum: "e078ad43aa997dd27ba3583de00441d40202c3f488a403f449a01625a4351b28")
}

let package = Package(
    name: "skia-pack",
    products: [
        .library(name: "SkiaPack", targets: ["SkiaPackBinary"])
    ],
    targets: [binaryTarget]
)
