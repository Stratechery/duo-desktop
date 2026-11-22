#!/bin/sh
# Xcode pre-build phase: the Glass Act pin check, then Glass Act's own Rust AV1 build for this platform.
set -eu
# Xcode's script PATH has no Homebrew; rustup from Homebrew is keg-only.
PATH="/opt/homebrew/opt/rustup/bin:$PATH:${CARGO_HOME:-$HOME/.cargo}/bin"
export PATH
"$SRCROOT/scripts/check-glassact.sh"
exec "$SRCROOT/../vendor/glassact/scripts/build-rust" --xcode
