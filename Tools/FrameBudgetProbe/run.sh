#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-frame-budget-probe"
mkdir -p "$BUILD"
cd "$ROOT"
swiftc -O -module-cache-path "$BUILD/module-cache" -o "$BUILD/probe" \
  Tools/FrameBudgetProbe/main.swift DroneUAVDemo/Domain/RuntimePerformancePolicy.swift
"$BUILD/probe"
