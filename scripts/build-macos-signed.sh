#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
: "${WTERM_APPLE_TEAM_ID:?请设置 Xcode 中实际的 Apple 开发团队 ID（WTERM_APPLE_TEAM_ID）}"
# Prepare Flutter assets and plugin integration, then build with the selected
# team's development signing. Provisioning is managed in Xcode by the user.
flutter build macos --debug --no-pub
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -derivedDataPath build/macos \
  DEVELOPMENT_TEAM="$WTERM_APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' \
  WTERM_ENTITLEMENTS_FILE=Runner/Biometric.entitlements build
