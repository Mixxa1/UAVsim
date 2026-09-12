#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-damage-model-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
cat >> "$BUILD/sources.txt" <<'SOURCES'
DroneUAVDemo/Scene/UAVModelAssetLibrary.swift
DroneUAVDemo/Scene/DroneVisualGeometrySample.swift
DroneUAVDemo/Simulation/VehicleComponentGraphBuilder.swift
SOURCES
tr '\n' '\0' < "$BUILD/sources.txt" | xargs -0 swiftc -Onone -o "$BUILD/probe" Tools/DamageModelProbe/main.swift
"$BUILD/probe" "$@"
