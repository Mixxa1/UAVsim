#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-replay-world-probe"
mkdir -p "$BUILD"
cp -R "$ROOT/DroneUAVDemo/Resources/VFX" "$BUILD/"
cd "$ROOT"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(bash Tools/probe-sources.sh)
swiftc -parse-as-library -module-cache-path "$BUILD/module-cache" -o "$BUILD/probe" \
  "${SOURCES[@]}" Tools/ReplayWorldProbe/main.swift \
  DroneUAVDemo/Scene/MissionReplayWorldVisuals.swift \
  DroneUAVDemo/Scene/GroundVehicleVisual.swift \
  DroneUAVDemo/Scene/WorldDamageEffectVisual.swift \
  DroneUAVDemo/Scene/FireVisualAssetLoader.swift \
  DroneUAVDemo/Services/MissionReplayStorageService.swift \
  DroneUAVDemo/Scene/Thermal/ThermalDomainModels.swift \
  DroneUAVDemo/Scene/Thermal/ThermalMaterialModel.swift \
  DroneUAVDemo/Scene/Thermal/ThermalPaletteMapper.swift \
  DroneUAVDemo/Scene/Thermal/ThermalNormalizationModel.swift \
  DroneUAVDemo/Scene/Thermal/ThermalSurfaceClassifier.swift \
  DroneUAVDemo/Scene/Thermal/ThermalVariationTexture.swift \
  DroneUAVDemo/Scene/Thermal/ThermalRealTexture.swift \
  DroneUAVDemo/Scene/Thermal/ThermalImportedSurfaceMaterial.swift \
  DroneUAVDemo/Scene/World/UAVWorldFacadeMaterialFactory.swift \
  DroneUAVDemo/Scene/World/UAVWorldBuildingGeometryFactory.swift \
  DroneUAVDemo/Scene/Thermal/ThermalProxyRenderer.swift
"$BUILD/probe"
