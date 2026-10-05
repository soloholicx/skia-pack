#!/usr/bin/env bash
# Shared platform table — sourced by build/package/verify. One row per slice.
#   pack_platform_init <platform>  sets:
#     PACK_GN_FILE      gn/<file>.gn
#     PACK_SKIA_OUT     build/skia/Release-<platform>
#     PACK_HB_OUT       HarfBuzz build dir
#     PACK_SDK          xcrun SDK name
#     PACK_TRIPLE       clang -target triple for consumer-side smoke links
#     PACK_MINOS        deployment target
#     PACK_MACHO_PLATFORM  LC_BUILD_VERSION platform number (1 macOS, 2 iOS, 7 iOS Simulator)
#     PACK_XC_ID        xcframework LibraryIdentifier
PACK_ALL_PLATFORMS=(macos-arm64 ios-arm64 ios-arm64-simulator)
PACK_IOS_PLATFORMS=(ios-arm64 ios-arm64-simulator)
pack_platform_init() {
    local root="$1" platform="$2"
    PACK_SKIA_OUT="${root}/build/skia/Release-${platform}"
    PACK_XC_ID="${platform}"
    case "${platform}" in
        macos-arm64)
            PACK_GN_FILE="gn/macos.gn"; PACK_HB_OUT="${root}/build/harfbuzz"
            PACK_SDK="macosx"; PACK_TRIPLE="arm64-apple-macos14.0"; PACK_MINOS="14.0"; PACK_MACHO_PLATFORM=1 ;;
        ios-arm64)
            PACK_GN_FILE="gn/ios.gn"; PACK_HB_OUT="${root}/build/harfbuzz-${platform}"
            PACK_SDK="iphoneos"; PACK_TRIPLE="arm64-apple-ios17.0"; PACK_MINOS="17.0"; PACK_MACHO_PLATFORM=2 ;;
        ios-arm64-simulator)
            PACK_GN_FILE="gn/ios-sim.gn"; PACK_HB_OUT="${root}/build/harfbuzz-${platform}"
            PACK_SDK="iphonesimulator"; PACK_TRIPLE="arm64-apple-ios17.0-simulator"; PACK_MINOS="17.0"; PACK_MACHO_PLATFORM=7 ;;
        *) echo "error: unknown platform '${platform}' (expected: ${PACK_ALL_PLATFORMS[*]})" >&2; return 1 ;;
    esac
}
