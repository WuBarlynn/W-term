#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
export RUSTUP_TOOLCHAIN=1.98.1-aarch64-apple-darwin
flutter build ios --release --no-codesign --no-pub
WTERM_IOS_APP="$PWD/build/ios/iphoneos/Runner.app"
WTERM_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WTERM_IOS_APP/Info.plist")
WTERM_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WTERM_IOS_APP/Info.plist")
WTERM_IPA="$PWD/build/ios/wterm-ios-$WTERM_VERSION-$WTERM_BUILD-unsigned.ipa"
WTERM_IPA_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/wterm-ipa.XXXXXX")
trap 'rm -rf "$WTERM_IPA_STAGE"' EXIT
mkdir -p "$WTERM_IPA_STAGE/Payload"
ditto "$WTERM_IOS_APP" "$WTERM_IPA_STAGE/Payload/Runner.app"
ditto -c -k --keepParent "$WTERM_IPA_STAGE/Payload" "$WTERM_IPA"
printf 'Unsigned device IPA: %s\n' "$WTERM_IPA"
