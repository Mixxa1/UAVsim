#!/bin/bash
set -euo pipefail
instructor_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
instructor_derived="${1:-/tmp/uavsim-instructor-derived-data}"
instructor_output="${2:-/tmp/uavsim-instructor-preview}"
instructor_probe_build="${TMPDIR:-/tmp}/uavsim-instructor-runtime-probe"
instructor_arch="$(uname -m)"
instructor_objects_dir="$instructor_derived/Build/Intermediates.noindex/DroneUAVDemo.build/Debug/DroneUAVDemo.build/Objects-normal/$instructor_arch"
instructor_products="$instructor_derived/Build/Products/Debug"
mkdir -p "$instructor_probe_build" "$instructor_output"
instructor_objects=()
while IFS= read -r object; do
  case "$object" in */DroneUAVDemoApp.o) ;; *) instructor_objects+=("$object");; esac
done < "$instructor_objects_dir/DroneUAVDemo.LinkFileList"
swiftc -parse-as-library -module-name DroneUAVDemo -target "$instructor_arch-apple-macos14.6" \
  -module-cache-path "$instructor_probe_build/module-cache" -c \
  "$instructor_repo/Tools/GroundVehicleSceneProbe/AppEntrySupport.swift" -o "$instructor_probe_build/AppEntrySupport.o"
# Locating the CLI inside the temporary build bundle lets Bundle.main use the production assets
# and translations. This executable never launches that app or opens a window.
instructor_executable="$instructor_products/DroneUAVDemo.app/Contents/MacOS/InstructorRuntimeProbe"
swiftc -parse-as-library -Xfrontend -disable-access-control \
  -module-cache-path "$instructor_probe_build/module-cache" -target "$instructor_arch-apple-macos14.6" \
  -I "$instructor_products" -Xlinker -dead_strip -lc++ \
  -o "$instructor_executable" "$instructor_repo/Tools/InstructorProbe/runtime.swift" \
  "${instructor_objects[@]}" "$instructor_probe_build/AppEntrySupport.o"
"$instructor_executable" "$instructor_output"
