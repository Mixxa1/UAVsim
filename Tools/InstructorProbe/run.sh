#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-instructor-probe"
mkdir -p "$BUILD"
cd "$ROOT"
swiftc -parse-as-library -module-cache-path "$BUILD/module-cache" -o "$BUILD/probe" \
  Tools/InstructorProbe/main.swift \
  DroneUAVDemo/Domain/FlightTrainingSession.swift \
  DroneUAVDemo/Domain/InstructorTour.swift \
  DroneUAVDemo/Services/InstructorProgressStore.swift
"$BUILD/probe"
