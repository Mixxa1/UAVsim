#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-ui-presentation-probe"
mkdir -p "$BUILD"
cd "$ROOT"
swiftc -parse-as-library -module-cache-path "$BUILD/module-cache" -o "$BUILD/probe" \
  Tools/UIPresentationProbe/main.swift DroneUAVDemo/Presentation/Views/SimulationObservedObject.swift \
  DroneUAVDemo/Domain/BatteryState.swift DroneUAVDemo/Domain/RF/ELRSLinkCatalog.swift \
  DroneUAVDemo/Domain/L10n.swift DroneUAVDemo/Domain/AppLanguage.swift
"$BUILD/probe" "$ROOT/DroneUAVDemo/Resources"
