#!/bin/bash
# Builds and runs the headless USDZ airframe library probe. See main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-uavmodel-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
# Two Scene-layer files the probe needs, plus the graph builder that probe-sources.sh
# excludes precisely because it depends on them. main.swift supplies the only other
# Scene type involved (`DroneVisualModel`), so the rest of that layer stays out.
echo "DroneUAVDemo/Scene/UAVModelAssetLibrary.swift" >> "$BUILD/sources.txt"
echo "DroneUAVDemo/Scene/DroneVisualGeometrySample.swift" >> "$BUILD/sources.txt"
echo "DroneUAVDemo/Simulation/VehicleComponentGraphBuilder.swift" >> "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -o "$BUILD/probe" Tools/UAVModelProbe/main.swift
"$BUILD/probe" "$@"
