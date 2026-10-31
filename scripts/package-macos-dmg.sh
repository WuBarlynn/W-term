#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

target_arch="${WTERM_MACOS_ARCH:-arm64}"
case "$target_arch" in
  arm64) app="$PWD/build/macos-signed/Build/Products/Release/W Term.app" ;;
  x86_64) app="$PWD/build/macos-signed-x86_64/Build/Products/Release/W Term.app" ;;
  *) printf 'Unsupported Mac architecture: %s\n' "$target_arch" >&2; exit 1 ;;
esac
if [[ ! -d "$app" ]]; then
  printf 'Build the signed app first: bash scripts/build-macos-signed.sh\n' >&2
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
out_dir="$PWD/build/macos"
mkdir -p "$out_dir"
if [[ "$target_arch" == "x86_64" ]]; then
  dmg="$out_dir/wterm-macos-$version-$build-intel.dmg"
else
  dmg="$out_dir/wterm-macos-$version-$build.dmg"
fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/wterm-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT

ditto "$app" "$stage/W Term.app"
ln -s /Applications "$stage/Applications"
cp "$PWD/LICENSE" "$stage/License.txt"
hdiutil create -volname "W Term" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null

identity="${WTERM_SIGNING_IDENTITY:-W Term Vault Code Signing}"
if security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$identity\""; then
  codesign --force --sign "$identity" "$dmg"
fi

printf 'macOS DMG: %s\n' "$dmg"
