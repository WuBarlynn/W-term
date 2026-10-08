#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.98.1-aarch64-apple-darwin}"

# Personal Team development signing. Xcode owns the account/certificate/profile.
# Optional overrides: WTERM_APPLE_TEAM_ID and WTERM_MACOS_CONFIGURATION.
configuration="${WTERM_MACOS_CONFIGURATION:-Release}"
case "$configuration" in
  Debug) mode=debug ;;
  Release) mode=release ;;
  *) printf 'WTERM_MACOS_CONFIGURATION must be Debug or Release\n' >&2; exit 1 ;;
esac

# Generate Flutter/plugin configuration once; the signed Xcode build does the work.
flutter build macos "--$mode" --no-pub --config-only
work_dir="$PWD/build/macos-signed"
mkdir -p "$work_dir"
settings_file=$(mktemp "$work_dir/settings.XXXXXX")
trap 'rm -f "$settings_file"' EXIT
host_arch=$(uname -m)
case "$host_arch" in arm64|x86_64) ;; *) printf 'Unsupported Mac architecture: %s\n' "$host_arch" >&2; exit 1 ;; esac
xcode_args=(-workspace macos/Runner.xcworkspace -scheme Runner
  -configuration "$configuration" -derivedDataPath "$work_dir"
  -destination "platform=macOS,arch=$host_arch" "ARCHS=$host_arch"
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development'
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
  WTERM_ENTITLEMENTS_FILE="Runner/Biometric${configuration}.entitlements")
if [[ -n "${WTERM_APPLE_TEAM_ID:-}" ]]; then
  xcode_args+=("DEVELOPMENT_TEAM=$WTERM_APPLE_TEAM_ID")
fi
xcodebuild "${xcode_args[@]}" -showBuildSettings -json > "$settings_file"
team=$(/usr/bin/python3 - "$settings_file" <<'PY'
import json, re, sys
settings = next(row['buildSettings'] for row in json.load(open(sys.argv[1])) if row['target'] == 'Runner')
team = settings.get('DEVELOPMENT_TEAM', '')
if not re.fullmatch(r'[A-Z0-9]{10}', team):
    sys.exit('Please select a Team for Runner in Xcode, or set WTERM_APPLE_TEAM_ID.')
print(team)
PY
)
app=$(/usr/bin/python3 - "$settings_file" <<'PY'
import json, os, sys
settings = next(row['buildSettings'] for row in json.load(open(sys.argv[1])) if row['target'] == 'Runner')
print(os.path.join(settings['TARGET_BUILD_DIR'], settings['FULL_PRODUCT_NAME']))
PY
)
printf 'Development signing: team %s, configuration %s\n' "$team" "$configuration"
# Permit Xcode to maintain this user's selected development provisioning only.
xcodebuild -quiet "${xcode_args[@]}" "DEVELOPMENT_TEAM=$team" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

# A successful compiler exit is not sufficient: reject ad-hoc or incomplete signing.
codesign --verify --deep --strict --verbose=2 "$app"
signature=$(codesign -d --verbose=4 "$app" 2>&1)
if ! printf '%s\n' "$signature" | /usr/bin/grep -Fqx "TeamIdentifier=$team"; then
  printf 'Signed application has an unexpected or missing TeamIdentifier\n' >&2
  exit 1
fi
if ! printf '%s\n' "$signature" | /usr/bin/grep -q '^Authority=Apple Development:'; then
  printf 'Signed application does not contain an Apple Development signature\n' >&2
  exit 1
fi
codesign -d --entitlements :- "$app" 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
p = plistlib.loads(sys.stdin.buffer.read())
identifier = p.get("com.apple.application-identifier", "")
assert identifier.endswith(".dev.wterm.wterm"), "Missing app identifier entitlement"
assert identifier in p.get("keychain-access-groups", []), "Missing app Keychain group"
assert p.get("com.apple.security.app-sandbox") is True, "Missing sandbox entitlement"
assert p.get("com.apple.security.network.client") is True, "Missing outgoing network entitlement"
assert p.get("com.apple.security.network.server") is True, "Missing forwarding listener entitlement"
assert p.get("com.apple.security.files.user-selected.read-write") is True, "Missing selected-file entitlement"
'
printf 'Verified development-signed app: %s\n' "$app"
