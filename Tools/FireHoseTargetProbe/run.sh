#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-fire-hose-target-probe"
mkdir -p "$BUILD"
cd "$ROOT"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(bash Tools/probe-sources.sh)
swiftc -parse-as-library -module-cache-path "$BUILD/module-cache" -o "$BUILD/probe" \
    "${SOURCES[@]}" Tools/FireHoseTargetProbe/main.swift
"$BUILD/probe"
