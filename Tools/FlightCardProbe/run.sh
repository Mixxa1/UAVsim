#!/bin/bash
# Builds and runs the headless flight-card probe. See main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-flight-card-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -o "$BUILD/probe" Tools/FlightCardProbe/main.swift
# The multirotor stepper logs its first frames for every solver it is given; one solver per
# airframe makes that several hundred lines of somebody else's diagnostics.
"$BUILD/probe" "$@" | grep -v '^\[PhysicsStartup\]'
