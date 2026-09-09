#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-planner-cadence-probe"
mkdir -p "$BUILD"
export CLANG_MODULE_CACHE_PATH="$BUILD/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD/swift-module-cache"
cd "$ROOT"
bash Tools/probe-sources.sh > "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -D DEBUG -o "$BUILD/probe" Tools/PlannerCadenceProbe/main.swift
"$BUILD/probe"
