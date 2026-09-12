#!/bin/bash
# Builds and runs the headless crash-and-settle probe. See main.swift.
#
# Scenarios per aircraft: a dive into the ground, a wreck already on its back and turning, an
# unpowered glide to the ground, and — for anything with a wing — losing one wing or the tail
# in cruise. Each is checked for coming to rest, for not turning for ever, and for never
# gaining mechanical energy while unpowered.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-crash-scenario-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
cat >> "$BUILD/sources.txt" <<'SOURCES'
DroneUAVDemo/Scene/UAVModelAssetLibrary.swift
DroneUAVDemo/Scene/DroneVisualGeometrySample.swift
DroneUAVDemo/Simulation/VehicleComponentGraphBuilder.swift
SOURCES
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -o "$BUILD/probe" Tools/CrashScenarioProbe/main.swift
"$BUILD/probe" "$@"
