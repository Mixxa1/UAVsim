#!/bin/bash
set -euo pipefail
launch_pad_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
launch_pad_probe_build="${TMPDIR:-/tmp}/uavsim-launch-pad-probe"
mkdir -p "$launch_pad_probe_build"
cd "$launch_pad_repo"
CLANG_MODULE_CACHE_PATH="$launch_pad_probe_build/clang-cache" \
    swiftc -module-cache-path "$launch_pad_probe_build/swift-cache" \
    DroneUAVDemo/Scene/UAVLaunchPad.swift Tools/UAVLaunchPadProbe/main.swift \
    -o "$launch_pad_probe_build/probe"
"$launch_pad_probe_build/probe" "${1:-$launch_pad_repo/DroneUAVDemo/Resources/Models/LaunchPads}"
