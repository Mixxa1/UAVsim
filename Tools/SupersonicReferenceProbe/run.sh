#!/bin/bash
# Builds and runs the acceptance probe for the six supersonic reference aircraft.
# See main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-supersonic-reference-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
tr '\n' '\0' < "$BUILD/sources.txt" \
  | xargs -0 swiftc -O -o "$BUILD/probe" Tools/SupersonicReferenceProbe/main.swift
"$BUILD/probe" "$@"
