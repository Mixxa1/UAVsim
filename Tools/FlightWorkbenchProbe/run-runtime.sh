#!/bin/bash
set -euo pipefail
flight_tools_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
flight_tools_derived="${1:-/tmp/uavsim-flight-tools-build}"
flight_tools_output="${2:-/tmp/uavsim-flight-tools-preview}"
flight_tools_probe_build="${TMPDIR:-/tmp}/uavsim-flight-tools-probe"
flight_tools_arch="$(uname -m)"
flight_tools_objects_dir="$flight_tools_derived/Build/Intermediates.noindex/DroneUAVDemo.build/Debug/DroneUAVDemo.build/Objects-normal/$flight_tools_arch"
flight_tools_products="$flight_tools_derived/Build/Products/Debug"
mkdir -p "$flight_tools_probe_build" "$flight_tools_output"
flight_tools_objects=()
while IFS= read -r object; do
  case "$object" in */DroneUAVDemoApp.o) ;; *) flight_tools_objects+=("$object");; esac
done < "$flight_tools_objects_dir/DroneUAVDemo.LinkFileList"
swiftc -parse-as-library -module-name DroneUAVDemo -target "$flight_tools_arch-apple-macos14.6" \
  -module-cache-path "$flight_tools_probe_build/module-cache" -c \
  "$flight_tools_repo/Tools/GroundVehicleSceneProbe/AppEntrySupport.swift" -o "$flight_tools_probe_build/AppEntrySupport.o"
# Locating the CLI inside the temporary build bundle lets Bundle.main use the production assets
# and translations. This executable never launches that app or opens a window.
flight_tools_executable="$flight_tools_products/DroneUAVDemo.app/Contents/MacOS/FlightWorkbenchProbe"
swiftc -parse-as-library -Xfrontend -disable-access-control \
  -module-cache-path "$flight_tools_probe_build/module-cache" -target "$flight_tools_arch-apple-macos14.6" \
  -I "$flight_tools_products" -Xlinker -dead_strip -lc++ \
  -o "$flight_tools_executable" "${3:-$flight_tools_repo/Tools/FlightWorkbenchProbe/main.swift}" \
  "${flight_tools_objects[@]}" "$flight_tools_probe_build/AppEntrySupport.o"
"$flight_tools_executable" "$flight_tools_output" "$flight_tools_repo"
