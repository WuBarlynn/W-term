#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/wterm-quick-unlock-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
xcrun swiftc macos/Runner/MacQuickUnlock.swift tests/native/QuickUnlockCheck.swift -o "$work/check"
if [[ "${1:-}" == --hardware ]]; then
  bundle="$work/Quick Unlock Fixture.app"
  mkdir -p "$bundle/Contents/MacOS"
  mv "$work/check" "$bundle/Contents/MacOS/check"
  cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.wterm.quick-unlock-fixture</string>
<key>CFBundleExecutable</key><string>check</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  cat > "$work/sandbox.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
  codesign -f -s "${WTERM_SIGNING_IDENTITY:-W Term Vault Code Signing}" --timestamp=none \
    --entitlements "$work/sandbox.plist" "$bundle"
  "$bundle/Contents/MacOS/check" "$@"
else
  "$work/check" "$@"
fi
