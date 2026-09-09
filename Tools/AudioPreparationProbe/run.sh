#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-audio-preparation-probe"
mkdir -p "$BUILD"
cd "$ROOT"
swiftc -Onone -D DEBUG -parse-as-library -module-cache-path "$BUILD/module-cache" -o "$BUILD/probe" \
  Tools/AudioPreparationProbe/main.swift \
  DroneUAVDemo/Services/SimulationAudioService.swift \
  DroneUAVDemo/Domain/SonicBoomModel.swift \
  DroneUAVDemo/Domain/AtmosphereModel.swift \
  DroneUAVDemo/Domain/WeatherModel.swift \
  DroneUAVDemo/Domain/AudioAssetCatalog.swift \
  DroneUAVDemo/Domain/AppAudioSettings.swift
"$BUILD/probe"
