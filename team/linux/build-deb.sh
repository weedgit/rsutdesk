#!/bin/sh
# Builds dist/rustdesk-team-<version>.deb on an Ubuntu build machine: one package that installs
# RustDesk Team. team/allowed-ips.txt is built into the app (a fresh install starts with that
# list), so edit it before building. Extra arguments go to build.py, e.g. --drm for the
# unattended Wayland variant (dist/rustdesk-team-unattended-wayland-<version>.deb).
set -e
cd "$(dirname "$0")/../.."
# Ubuntu 26.04's GCC no longer pulls in <cstdint> implicitly; webm-sys (libwebm) relies on it.
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-include cstdint"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
# The Rust/Dart bridge is generated, not committed.
if [ ! -f src/bridge_generated.rs ]; then
    flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs \
        --dart-output ./flutter/lib/generated_bridge.dart \
        --c-output ./flutter/macos/Runner/bridge_generated.h
fi
rm -f rustdesk-*.deb
python3 build.py --flutter "$@"
mkdir -p dist
for deb in rustdesk-*.deb; do
    out="dist/$(echo "$deb" | sed 's/^rustdesk-/rustdesk-team-/')"
    cp "$deb" "$out"
    echo "Built $out"
done
