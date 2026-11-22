#!/bin/bash
# Builds MacClean.app and packages .zip, .dmg, and SHA256SUMS.txt under build/release/.
# Usage: ./scripts/package-release.sh [version]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

raw_version="${1:-${VERSION:-0.2.5}}"
version="${raw_version#v}"

echo "==> Building MacClean v${version}..."
if ! UNIVERSAL="${UNIVERSAL:-1}" VERSION="$version" ./scripts/build-app.sh; then
    echo "Universal build unavailable; falling back to host architecture..."
    UNIVERSAL=0 VERSION="$version" ./scripts/build-app.sh
fi

app="$root/build/MacClean.app"
out_dir="$root/build/release"
stage_dir="$root/build/dmg-stage"
rm -rf "$out_dir" "$stage_dir"
mkdir -p "$out_dir" "$stage_dir"

zip_name="MacClean-v${version}-macos.zip"
dmg_name="MacClean-v${version}-macos.dmg"

echo "==> Creating ${zip_name}..."
ditto -c -k --sequesterRsrc --keepParent "$app" "$out_dir/$zip_name"

echo "==> Creating ${dmg_name}..."
cp -R "$app" "$stage_dir/MacClean.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create \
    -volname "MacClean" \
    -srcfolder "$stage_dir" \
    -ov \
    -format UDZO \
    "$out_dir/$dmg_name" >/dev/null
rm -rf "$stage_dir"

echo "==> Generating SHA256SUMS.txt..."
(
    cd "$out_dir"
    shasum -a 256 "$zip_name" "$dmg_name" > SHA256SUMS.txt
)

echo "==> Release artifacts ready in $out_dir:"
ls -lh "$out_dir"
cat "$out_dir/SHA256SUMS.txt"
