#!/bin/bash
# Builds and runs the headless Wingtra ground/body-origin regression probe. See main.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-wingtra-ground-probe"
mkdir -p "$BUILD"

# Xcode/Swift defaults can point module caches into sandboxed user-library locations. Keep every
# compiler cache in the writable probe build directory so this script also runs under CI/Codex.
export CLANG_MODULE_CACHE_PATH="$BUILD/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"

cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O \
      -framework AppKit \
      -framework SceneKit \
      -o "$BUILD/probe" \
      DroneUAVDemo/Simulation/VehicleComponentGraphBuilder.swift \
      DroneUAVDemo/Scene/DroneModelBuilder.swift \
      DroneUAVDemo/Scene/DroneVisualGeometrySample.swift \
      DroneUAVDemo/Scene/UAVVisualFactory.swift \
      Tools/WingtraGroundProbe/main.swift

"$BUILD/probe" "$@"
