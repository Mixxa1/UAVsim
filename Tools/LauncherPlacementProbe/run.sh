#!/bin/bash
# Builds and runs the headless launcher-placement probe. See main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-launcher-placement-probe"
mkdir -p "$BUILD"
cd "$ROOT"
# Both loaders are self-contained: SceneKit, a manifest and the models beside it. Nothing
# from Domain or Simulation is involved, so the probe compiles in a couple of seconds.
swiftc -O -o "$BUILD/probe" \
  Tools/LauncherPlacementProbe/main.swift \
  DroneUAVDemo/Scene/CatapultAssetLoader.swift \
  DroneUAVDemo/Scene/CanisterAssetLoader.swift
"$BUILD/probe" "$@"
