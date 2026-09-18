#!/usr/bin/env bash
set -euo pipefail
WTERM_BRIDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WTERM_BRIDGE_ROOT"
cargo build --manifest-path rust/Cargo.toml --locked
flutter test tests/smoke/vault_bridge_test.dart --dart-define="WTERM_NATIVE_LIB=$WTERM_BRIDGE_ROOT/rust/target/debug/libwterm_core.dylib"
