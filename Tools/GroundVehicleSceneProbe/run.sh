#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED="${1:-${TMPDIR:-/tmp}/uavsim-ground-build}"
BUILD="${TMPDIR:-/tmp}/uavsim-ground-vehicle-scene-probe"
OBJECT_DIR="$DERIVED/Build/Intermediates.noindex/DroneUAVDemo.build/Debug/DroneUAVDemo.build/Objects-normal/arm64"
PRODUCTS="$DERIVED/Build/Products/Debug"
mkdir -p "$BUILD/Vehicles"
# Build the Debug app first. Link its existing production objects without the app entry point;
# this executable creates no window, starts no app lifecycle, and uses no duplicated scene code.
OBJECTS=()
while IFS= read -r object; do
  case "$object" in */DroneUAVDemoApp.o) ;; *) OBJECTS+=("$object");; esac
done < "$OBJECT_DIR/DroneUAVDemo.LinkFileList"
cp "$ROOT/DroneUAVDemo/Resources/Models/Vehicles/harop-cabover-6x6-transport.usdz" "$BUILD/Vehicles/"
cp "$ROOT/DroneUAVDemo/Resources/Models/Vehicles/harpy-bonnet-6x6-transport.usdz" "$BUILD/Vehicles/"
cp "$ROOT/DroneUAVDemo/Resources/Models/Scenario/Fire_sheet_baseColor.png" "$BUILD/"
cp "$ROOT/DroneUAVDemo/Resources/Models/Scenario/Fire_sheet_emissive.jpg" "$BUILD/"
swiftc -parse-as-library -module-name DroneUAVDemo -target arm64-apple-macos14.6 \
  -module-cache-path "$BUILD/module-cache" -c \
  "$ROOT/Tools/GroundVehicleSceneProbe/AppEntrySupport.swift" -o "$BUILD/AppEntrySupport.o"
swiftc -parse-as-library -Xfrontend -disable-access-control \
  -module-cache-path "$BUILD/module-cache" -target arm64-apple-macos14.6 \
  -I "$PRODUCTS" -Xlinker -dead_strip -lc++ \
  -o "$BUILD/probe" "$ROOT/Tools/GroundVehicleSceneProbe/main.swift" \
  "$ROOT/Tools/GroundVehicleSceneProbe/DetonationPresentationProbe.swift" "${OBJECTS[@]}" "$BUILD/AppEntrySupport.o"
"$BUILD/probe" "${2:-}"
