#!/bin/bash
# Emits the Swift source list the headless flight probes compile against.
#
# The app has no test target, so the probes build the Domain/Simulation layers directly with
# swiftc. The excluded files reach into the view-model/scene layers for types that live there;
# the probes need the flight model, not the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXCLUDED=(
  AppGraphicsSettings.swift
  MissionSafetyEvaluator.swift
  VehicleComponentGraphBuilder.swift
)

FIND_ARGS=()
for name in "${EXCLUDED[@]}"; do
  FIND_ARGS+=(! -name "$name")
done

{
  find DroneUAVDemo/Domain DroneUAVDemo/Simulation -name '*.swift' "${FIND_ARGS[@]}"
  find DroneUAVDemo/Input \( -name 'ResolvedControlState.swift' \
    -o -name 'KeyboardInputService.swift' \
    -o -name 'InputSourceKind.swift' \
    -o -name 'ControllerAxisMap.swift' \
    -o -name 'ControllerRateProfile.swift' \)
} | sort -u
