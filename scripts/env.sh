#!/usr/bin/env bash
# Source this file before Flutter/Rust commands. A checked-in toolchain tree is
# preferred locally; CI runners use the tools installed by GitHub Actions.
WTERM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$WTERM_ROOT/.toolchains/flutter/bin/flutter" ]]; then
  export CARGO_HOME="$WTERM_ROOT/.toolchains/cargo"
  export RUSTUP_HOME="$WTERM_ROOT/.toolchains/rustup"
  export PUB_CACHE="$WTERM_ROOT/.toolchains/pub-cache"
  export PATH="$WTERM_ROOT/.toolchains/flutter/bin:$CARGO_HOME/bin:$PATH"
fi
# Flutter tooling uses local HTTP/WebSocket services; never send them to a proxy.
export NO_PROXY="localhost,127.0.0.1,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
