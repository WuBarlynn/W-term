#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .toolchains/cargo/bin/cargo ]]; then source scripts/env.sh; fi
PYTHON="${WTERM_TEST_PYTHON:-.toolchains/test-venv/bin/python}"
export WTERM_FIXTURE_ROOT
WTERM_FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wterm-fixture.XXXXXX")"
export WTERM_TEST_PORT="${WTERM_TEST_PORT:-22222}"
export WTERM_CRYPTO_PYTHON
WTERM_CRYPTO_PYTHON="$("$PYTHON" -c 'import sys; print(sys.executable)')"
"$PYTHON" tests/fixtures/ssh_server.py --root "$WTERM_FIXTURE_ROOT" --port "$WTERM_TEST_PORT" > "$WTERM_FIXTURE_ROOT/server.log" 2>&1 &
fixture_pid=$!
cleanup() {
  kill "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" 2>/dev/null || true
  "$PYTHON" -c 'import os, shutil; shutil.rmtree(os.environ["WTERM_FIXTURE_ROOT"])'
}
trap cleanup EXIT
for _ in $(seq 1 100); do
  if ! kill -0 "$fixture_pid" 2>/dev/null; then cat "$WTERM_FIXTURE_ROOT/server.log"; exit 1; fi
  if grep -q '^READY' "$WTERM_FIXTURE_ROOT/server.log"; then break; fi
  sleep 0.1
done
if ! grep -q '^READY' "$WTERM_FIXTURE_ROOT/server.log"; then cat "$WTERM_FIXTURE_ROOT/server.log"; exit 1; fi
cargo test --manifest-path rust/Cargo.toml --locked
cargo test --manifest-path rust/Cargo.toml --locked fixture_ -- --ignored --test-threads=1
if [[ "${WTERM_TEST_FORWARD_BRIDGE:-0}" == "1" ]]; then
  cargo build --manifest-path rust/Cargo.toml --locked
  flutter test --no-pub tests/smoke/forward_bridge_test.dart tests/smoke/interactive_auth_bridge_test.dart tests/smoke/proxy_bridge_test.dart tests/smoke/route_bridge_test.dart \
    --dart-define="WTERM_NATIVE_LIB=$PWD/rust/target/debug/libwterm_core.dylib" \
    --dart-define="WTERM_TEST_PORT=$WTERM_TEST_PORT" \
    --dart-define="WTERM_JUMP_PORT=$(cat "$WTERM_FIXTURE_ROOT/jump_port")" \
    --dart-define="WTERM_JUMP2_PORT=$(cat "$WTERM_FIXTURE_ROOT/jump2_port")" \
    --dart-define="WTERM_STALL_PORT=$(cat "$WTERM_FIXTURE_ROOT/stall_port")" \
    --dart-define="WTERM_HTTP_PROXY_PORT=$(cat "$WTERM_FIXTURE_ROOT/http_proxy_port")" \
    --dart-define="WTERM_SOCKS_PROXY_PORT=$(cat "$WTERM_FIXTURE_ROOT/socks5_proxy_port")"
fi
