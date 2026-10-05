// swift-tools-version: 5.10
// Scratch SwiftPM consumer of the SkiaPack product — the shape slate-kit and
// term-kit consume it in. scripts/verify_consumer.sh copies this package to a
// temp dir and builds it for macOS (build + run), iOS device and iOS
// Simulator. The dependency is chosen by SKIA_PACK_CONSUMER_DEP:
//   path:<abs path to a skia-pack checkout>   (pre-release; pair with
//                                              SKIA_PACK_LOCAL_XCFRAMEWORK)
//   exact:<version>                           (post-release: the published tag)
import Foundation
import PackageDescription

let spec = ProcessInfo.processInfo.environment["SKIA_PACK_CONSUMER_DEP"] ?? ""
let dependency: Package.Dependency
if spec.hasPrefix("path:") {
    dependency = .package(name: "skia-pack", path: String(spec.dropFirst(5)))
} else if spec.hasPrefix("exact:") {
    dependency = .package(
        url: "https://github.com/soloholicx/skia-pack.git", exact: Version(stringLiteral: String(spec.dropFirst(6))))
} else {
    fatalError("set SKIA_PACK_CONSUMER_DEP=path:<checkout> or exact:<version>")
}

// Frameworks Skia's archives reference, per platform (the lists differ: AppKit /
// CoreServices exist only on macOS, UIKit only on iOS).
let frameworks: [LinkerSetting] =
    ["Metal", "Foundation", "CoreFoundation", "CoreGraphics", "CoreText", "QuartzCore", "IOSurface"]
        .map { .linkedFramework($0) }
    + ["MetalKit", "CoreServices", "AppKit"].map { .linkedFramework($0, .when(platforms: [.macOS])) }
    + [.linkedFramework("UIKit", .when(platforms: [.iOS]))]

let package = Package(
    name: "skia-pack-consumer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Dynamic on purpose: a static library product never runs the linker, and
        // the point is to LINK the binary target for every platform.
        .library(name: "SkiaPackConsumer", type: .dynamic, targets: ["SkiaPackConsumer"])
    ],
    dependencies: [dependency],
    targets: [
        .target(
            name: "SkiaPackConsumer",
            dependencies: [.product(name: "SkiaPack", package: "skia-pack")],
            linkerSettings: frameworks),
        .executableTarget(name: "consumer-cli", dependencies: ["SkiaPackConsumer"]),
    ],
    cxxLanguageStandard: .cxx20
)
