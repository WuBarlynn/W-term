#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
# Prepare Flutter assets and plugin integration, then build with the selected
# team's development signing. Provisioning is managed in Xcode by the user.
flutter build macos --debug --no-pub
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -derivedDataPath build/macos \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  WTERM_ENTITLEMENTS_FILE=Runner/Biometric.entitlements build
