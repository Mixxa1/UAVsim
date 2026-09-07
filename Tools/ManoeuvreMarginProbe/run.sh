#!/bin/bash
# Builds and runs the headless manoeuvre-margin probe. See main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-manoeuvre-margin-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
# The same three files UAVModelProbe needs: the airframe library and the geometry sample
# it feeds, plus the graph builder that probe-sources.sh excludes because it depends on
# them. main.swift supplies the only other Scene type involved (`DroneVisualModel`).
echo "DroneUAVDemo/Scene/UAVModelAssetLibrary.swift" >> "$BUILD/sources.txt"
echo "DroneUAVDemo/Scene/DroneVisualGeometrySample.swift" >> "$BUILD/sources.txt"
echo "DroneUAVDemo/Simulation/VehicleComponentGraphBuilder.swift" >> "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -o "$BUILD/probe" Tools/ManoeuvreMarginProbe/main.swift
"$BUILD/probe" "$@"
