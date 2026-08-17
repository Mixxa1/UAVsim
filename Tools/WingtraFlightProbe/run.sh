#!/bin/bash
# Builds and runs the headless Wingtra hover/transition regression probe.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-wingtra-flight-probe"
mkdir -p "$BUILD"
export CLANG_MODULE_CACHE_PATH="$BUILD/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -o "$BUILD/probe" Tools/WingtraFlightProbe/main.swift
"$BUILD/probe" "$@"
