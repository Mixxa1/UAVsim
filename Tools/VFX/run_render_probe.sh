#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-vfx-render-probe"
mkdir -p "$BUILD/VFX"
cp "$ROOT/DroneUAVDemo/Resources/VFX/"*.png "$BUILD/VFX/"
swiftc -parse-as-library -target arm64-apple-macos14.6 \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Tools/VFX/render_probe.swift" "$ROOT/DroneUAVDemo/Scene/FireVisualAssetLoader.swift" \
  -o "$BUILD/probe"
"$BUILD/probe"
