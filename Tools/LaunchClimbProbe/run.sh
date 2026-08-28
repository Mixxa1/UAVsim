#!/bin/bash
# Builds and runs the headless launch climb-out probe. See main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-launch-climb-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -o "$BUILD/probe" Tools/LaunchClimbProbe/main.swift
"$BUILD/probe" "$@"
