// swift-tools-version: 5.10
// skia-pack SwiftPM facade: the binary is a remote binaryTarget pointing at
// the versioned, immutable release artifact. The SkiaPack product also holds
// SkiaPackSupport, which on iOS (only) depends on SkiaPackPrivacy, the target
// carrying the privacy manifest for the APIs the prebuilt libraries call (a
// binary target cannot carry resources; SwiftPM copies a regular target's
// resource bundle into the app). Both are resource-wiring details: no headers,
// no API, nothing for a consumer to import. Both slate-kit and
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
        url: "https://github.com/soloholicx/skia-pack/releases/download/157.1.1/SkiaPack.xcframework.zip",
        checksum: "dd3e3de3961a2f68e7aa2bcc3d82e6bfe45d047ecffd7aeb83eb308b56f92c7a")
}

let package = Package(
    name: "skia-pack",
    products: [
        .library(name: "SkiaPack", targets: ["SkiaPackBinary", "SkiaPackSupport"])
    ],
    targets: [
        binaryTarget,
        // The manifest covers the iOS slices only, so the bundle reaches iOS apps
        // only: macOS consumers get SkiaPackSupport (empty) and no bundle.
        .target(
            name: "SkiaPackSupport",
            dependencies: [.target(name: "SkiaPackPrivacy", condition: .when(platforms: [.iOS]))],
            publicHeadersPath: "."),
        .target(name: "SkiaPackPrivacy", resources: [.copy("PrivacyInfo.xcprivacy")], publicHeadersPath: "."),
    ]
)
