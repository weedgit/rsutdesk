#!/bin/sh
# Builds dist/RustDesk-Team-Linux on an Ubuntu build machine: the .deb plus install.sh and
# allowed-ips.txt. Extra arguments go to build.py, e.g. --drm for the unattended Wayland variant.
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
rm -f rustdesk-*.deb rustdesk-unattended-wayland-*.deb
python3 build.py --flutter "$@"
out=dist/RustDesk-Team-Linux
rm -rf "$out"; mkdir -p "$out"
cp rustdesk-*.deb team/linux/install.sh team/allowed-ips.txt "$out/"
chmod +x "$out/install.sh"
echo "Built $out"
