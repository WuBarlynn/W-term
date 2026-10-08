#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${WTERM_SIGNING_IDENTITY:-W Term Vault Code Signing}"
work=$(mktemp -d "${TMPDIR:-/tmp}/wterm-signing-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
xcrun swiftc macos/Runner/BiometricSigningPolicy.swift tests/native/SigningPolicyCheck.swift -o "$work/check"
printf 'int main(void) { return 0; }\n' > "$work/main.c"
xcrun clang "$work/main.c" -o "$work/unsigned"
codesign --remove-signature "$work/unsigned"
"$work/check" "$work/unsigned" deny
cp "$work/unsigned" "$work/adhoc"
codesign -f -s - --identifier dev.wterm.wterm "$work/adhoc"
"$work/check" "$work/adhoc" deny
cp "$work/unsigned" "$work/stable"
codesign -f -s "$identity" --timestamp=none --identifier dev.wterm.wterm "$work/stable"
"$work/check" "$work/stable" allow
# A new executable signed with the same identity retains the same requirement.
printf 'int main(void) { return 7; }\n' > "$work/main.c"
xcrun clang "$work/main.c" -o "$work/updated"
codesign -f -s "$identity" --timestamp=none --identifier dev.wterm.wterm "$work/updated"
"$work/check" "$work/updated" allow
codesign -d -r- "$work/stable" 2>/dev/null > "$work/stable.dr"
codesign -d -r- "$work/updated" 2>/dev/null > "$work/updated.dr"
cmp "$work/stable.dr" "$work/updated.dr"
printf 'PASS stable identity across rebuilds\n'
cp "$work/stable" "$work/wrong-identifier"
codesign -f -s "$identity" --timestamp=none --identifier dev.wterm.other "$work/wrong-identifier"
"$work/check" "$work/wrong-identifier" deny
cp "$work/stable" "$work/weak-requirement"
codesign -f -s "$identity" --timestamp=none --identifier dev.wterm.wterm \
  -r '=designated => identifier "dev.wterm.wterm"' "$work/weak-requirement"
"$work/check" "$work/weak-requirement" allow
cp "$work/stable" "$work/tampered"
/usr/bin/python3 - "$work/tampered" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    # A byte in the signed Mach-O header; static-code loading remains possible.
    f.seek(28)
    value = f.read(1)
    f.seek(28)
    f.write(bytes([value[0] ^ 1]))
PY
"$work/check" "$work/tampered" deny
cp "$work/check" "$work/signed-check"
codesign -f -s "$identity" --timestamp=none --identifier dev.wterm.wterm "$work/signed-check"
"$work/signed-check" --self allow
if [[ $# -gt 0 ]]; then
  "$work/check" "$1" allow
fi
