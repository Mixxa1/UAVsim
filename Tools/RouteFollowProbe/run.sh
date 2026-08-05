#!/bin/bash
# Builds and runs the headless fixed-wing route-following probe.
#
# The app has no test target, so this compiles the Domain/Simulation sources directly with
# swiftc. Files that reach into the SceneKit/SwiftUI layers are excluded — the probe needs the
# flight model, not the app.
#
#   Tools/RouteFollowProbe/run.sh                          # expect PASS
#   Tools/RouteFollowProbe/run.sh --no-replan-handshake    # expect FAIL, see main.swift
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-route-probe"
mkdir -p "$BUILD"
cd "$ROOT"

"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"

tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -o "$BUILD/probe" Tools/RouteFollowProbe/main.swift

"$BUILD/probe" "$@"
