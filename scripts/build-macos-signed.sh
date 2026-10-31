#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.98.1-aarch64-apple-darwin}"

# Long-lived local signing with a self-signed Code Signing certificate.
# The certificate + private key must already exist in the user's keychain.
# Optional overrides: WTERM_SIGNING_IDENTITY and WTERM_MACOS_CONFIGURATION.
signing_identity="${WTERM_SIGNING_IDENTITY:-W Term Vault Code Signing}"
configuration="${WTERM_MACOS_CONFIGURATION:-Release}"
case "$configuration" in
  Debug) mode=debug ;;
  Release) mode=release ;;
  *) printf 'WTERM_MACOS_CONFIGURATION must be Debug or Release\n' >&2; exit 1 ;;
esac

# Make sure codesign can actually see a private-key-backed identity.
if ! security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$signing_identity\""; then
  printf 'Code signing identity not found or has no usable private key: %s\n' "$signing_identity" >&2
  printf 'Check with: security find-identity -v -p codesigning\n' >&2
  exit 1
fi

# Generate Flutter/plugin configuration once; Xcode builds without signing,
# then this script applies the stable self-signed identity manually.
flutter build macos "--$mode" --no-pub --config-only
target_arch="${WTERM_MACOS_ARCH:-$(uname -m)}"
case "$target_arch" in
  arm64) work_dir="$PWD/build/macos-signed" ;;
  x86_64) work_dir="$PWD/build/macos-signed-x86_64" ;;
  *) printf 'Unsupported Mac architecture: %s\n' "$target_arch" >&2; exit 1 ;;
esac
mkdir -p "$work_dir"
settings_file=$(mktemp "$work_dir/settings.XXXXXX")
entitlements_file=$(mktemp "$work_dir/selfsigned-entitlements.XXXXXX.plist")
trap 'rm -f "$settings_file" "$entitlements_file"' EXIT

xcode_args=(
  -workspace macos/Runner.xcworkspace
  -scheme Runner
  -configuration "$configuration"
  -derivedDataPath "$work_dir"
  -destination "platform=macOS,arch=$target_arch"
  "ARCHS=$target_arch"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  "WTERM_ENTITLEMENTS_FILE=Runner/Biometric${configuration}.entitlements"
)

xcodebuild "${xcode_args[@]}" -showBuildSettings -json > "$settings_file"
app=$(/usr/bin/python3 - "$settings_file" <<'PY'
import json, os, sys
settings = next(row['buildSettings'] for row in json.load(open(sys.argv[1])) if row['target'] == 'Runner')
print(os.path.join(settings['TARGET_BUILD_DIR'], settings['FULL_PRODUCT_NAME']))
PY
)

source_entitlements="$PWD/macos/Runner/Biometric${configuration}.entitlements"
if [[ ! -f "$source_entitlements" ]]; then
  printf 'Entitlements file not found: %s\n' "$source_entitlements" >&2
  exit 1
fi

# A self-signed identity has no Apple Team ID / provisioning profile.  Remove
# entitlements that require Apple provisioning, while retaining App Sandbox,
# network, file-selection, hardened-runtime-related and other unrestricted keys.
/usr/bin/python3 - "$source_entitlements" "$entitlements_file" <<'PY'
import plistlib, sys
src, dst = sys.argv[1:3]
with open(src, 'rb') as f:
    ent = plistlib.load(f)
for key in (
    'application-identifier',
    'com.apple.application-identifier',
    'com.apple.developer.team-identifier',
    'keychain-access-groups',
):
    ent.pop(key, None)
with open(dst, 'wb') as f:
    plistlib.dump(ent, f, fmt=plistlib.FMT_XML, sort_keys=True)
PY

printf 'Building %s (%s) without Xcode provisioning...\n' "$configuration" "$target_arch"
xcodebuild -quiet "${xcode_args[@]}" build

if [[ ! -d "$app" ]]; then
  printf 'Built application not found: %s\n' "$app" >&2
  exit 1
fi

printf 'Signing with self-signed identity: %s\n' "$signing_identity"

# Sign nested code from the inside out.  Do not pass the app entitlements to
# frameworks/libraries; the final Runner app receives the filtered entitlements.
while IFS= read -r -d '' item; do
  printf '  signing nested code: %s\n' "$item"
  codesign --force --sign "$signing_identity" --timestamp=none "$item"
done < <(
  find "$app/Contents" -depth \
    \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \) \
       -o -type f -name '*.dylib' \) \
    -print0
)

# Sign the outer application last.
codesign --force \
  --sign "$signing_identity" \
  --timestamp=none \
  --entitlements "$entitlements_file" \
  "$app"

# Verify the whole code graph and explicitly reject ad-hoc signing.
codesign --verify --deep --strict --verbose=2 "$app"
signature=$(codesign -d --verbose=4 "$app" 2>&1)
if printf '%s\n' "$signature" | /usr/bin/grep -Fqx 'Signature=adhoc'; then
  printf 'Signed application is still ad-hoc signed\n' >&2
  exit 1
fi
if ! printf '%s\n' "$signature" | /usr/bin/grep -Fqx "Authority=$signing_identity"; then
  printf 'Unexpected signing authority. Expected: %s\n' "$signing_identity" >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi

# Verify the entitlements that this project actually needs and that are valid
# without an Apple provisioning profile.  Keychain access must use the app's
# own/private keychain items and must not specify kSecAttrAccessGroup.
codesign -d --entitlements :- "$app" 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
p = plistlib.loads(sys.stdin.buffer.read())
for forbidden in (
    "application-identifier",
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "keychain-access-groups",
):
    assert forbidden not in p, f"Restricted entitlement still present: {forbidden}"
assert p.get("com.apple.security.app-sandbox") is True, "Missing sandbox entitlement"
assert p.get("com.apple.security.network.client") is True, "Missing outgoing network entitlement"
assert p.get("com.apple.security.network.server") is True, "Missing forwarding listener entitlement"
assert p.get("com.apple.security.files.user-selected.read-write") is True, "Missing selected-file entitlement"
'

printf '\nVerified self-signed app: %s\n' "$app"
printf 'Signing identity: %s\n' "$signing_identity"
printf 'Note: TeamIdentifier is expected to be absent for this self-signed build.\n'
printf 'Note: do not set kSecAttrAccessGroup for the Touch ID Keychain item.\n'
