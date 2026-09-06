#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-controller-axis-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" | xargs -0 swiftc -O -o "$BUILD/probe" Tools/ControllerAxisProbe/main.swift
"$BUILD/probe"
