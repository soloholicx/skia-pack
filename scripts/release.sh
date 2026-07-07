#!/usr/bin/env bash
# Release flow (architecture doc §8) — solves the URL/checksum chicken-and-egg.
#
# NOT part of the local build/verify loop. This script publishes a release to
# GitHub; it must only be run deliberately, by a human, from a clean tree.
# It refuses to run unless SKIA_PACK_RELEASE_CONFIRM=1 is set.
#
#   1. build + package + verify                → artifacts + resolved pack.json
#   2. write release URL + spm_checksum into Package.swift
#   3. commit + tag <version>                  (tag == version string, matching
#                                               the facade's download URL)
#   4. create the GitHub release with the three assets
#   5. post-verify: a scratch consumer resolves exact:<version> and builds a
#      minimal hb_version_string() + SkSurface program against the product
#
# Consumers only ever resolve the tag AFTER step 4, so the asset referenced by
# the manifest always exists by the time the manifest is visible. Artifacts
# are immutable: a botched release is abandoned (delete the tag before anyone
# consumed it) or rolled forward with a PATCH bump.
set -euo pipefail

if [[ "${SKIA_PACK_RELEASE_CONFIRM:-0}" != "1" ]]; then
    echo "release.sh publishes a GitHub release (tag + upload)." >&2
    echo "Set SKIA_PACK_RELEASE_CONFIRM=1 to confirm you intend to release." >&2
    exit 1
fi

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${PACK_ROOT}/VERSION")"
PLATFORM="macos-arm64"
ARTIFACTS="${PACK_ROOT}/artifacts"
TARBALL="${ARTIFACTS}/skia-pack-${VERSION}-${PLATFORM}.tar.gz"
XCZIP="${ARTIFACTS}/SkiaPack.xcframework.zip"
REPO_URL="https://github.com/soloholicx/skia-pack"

cd "${PACK_ROOT}"

# 1. Build, package, verify.
./scripts/build.sh
./scripts/package.sh
./scripts/verify.sh

# 2. Resolve URL + checksum into the SwiftPM facade.
spm_checksum="$(python3 -c "import json; print(json.load(open('${ARTIFACTS}/pack.json'))['artifacts']['xcframework']['spm_checksum'])")"
release_url="${REPO_URL}/releases/download/${VERSION}/SkiaPack.xcframework.zip"
python3 - "${PACK_ROOT}/Package.swift" "${release_url}" "${spm_checksum}" <<'PY'
import pathlib, re, sys
path, url, checksum = sys.argv[1:4]
manifest = pathlib.Path(path)
text = manifest.read_text()
text, n_url = re.subn(r'url: "[^"]*"', f'url: "{url}"', text, count=1)
text, n_sum = re.subn(r'checksum: "[^"]*"', f'checksum: "{checksum}"', text, count=1)
assert n_url == 1 and n_sum == 1, "Package.swift url/checksum lines not found"
manifest.write_text(text)
PY
echo "[release] Package.swift → url=${release_url} checksum=${spm_checksum}"

# 3. Commit + tag. Tag name equals the version string ("150.1.0") — it must
#    match the download URL path baked into Package.swift.
if ! git diff --quiet -- Package.swift; then
    git add Package.swift
    git commit -m "release: v${VERSION} — resolve binaryTarget url + checksum"
fi
git tag -a "${VERSION}" -m "skia-pack ${VERSION}"

# 4. Create the GitHub release with all three assets.
gh release create "${VERSION}" \
    --title "skia-pack ${VERSION}" \
    --notes "Prebuilt Skia m150 (@$(git -C third_party/skia rev-parse --short HEAD)) + HarfBuzz 14.2.0 static artifacts for macOS arm64. See pack.json for the full manifest." \
    "${TARBALL}" "${XCZIP}" "${ARTIFACTS}/pack.json"

# 5. Post-verify: scratch consumer resolves the tag and builds against the
#    released binary artifact.
scratch="$(mktemp -d /tmp/skia-pack-postverify.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT
mkdir -p "${scratch}/Sources/postverify"
cat > "${scratch}/Package.swift" <<EOF
// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "postverify",
    dependencies: [
        .package(url: "${REPO_URL}.git", exact: "${VERSION}")
    ],
    targets: [
        .executableTarget(
            name: "postverify",
            dependencies: [.product(name: "SkiaPack", package: "skia-pack")],
            linkerSettings: [
                .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"), .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"), .linkedFramework("CoreText"),
                .linkedFramework("CoreServices"), .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"), .linkedFramework("IOSurface"),
            ])
    ],
    cxxLanguageStandard: .cxx20
)
EOF
cat > "${scratch}/Sources/postverify/main.cpp" <<'EOF'
#include <cstdio>
#include <cstring>
#include <hb.h>
#include "include/core/SkCanvas.h"
#include "include/core/SkSurface.h"
int main() {
    if (std::strncmp(hb_version_string(), "14.2", 4) != 0) return 1;
    auto surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(64, 64));
    if (!surface) return 1;
    surface->getCanvas()->clear(SK_ColorGREEN);
    std::printf("post-verify OK: hb %s\n", hb_version_string());
    return 0;
}
EOF
(cd "${scratch}" && swift build && ./.build/debug/postverify)

echo "[release] ${VERSION} released and post-verified"
