#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD="${TMPDIR:-/tmp}/uavsim-keybindings-probe"
mkdir -p "$BUILD"
swiftc -module-cache-path "$BUILD/cache" DroneUAVDemo/Domain/AppLanguage.swift DroneUAVDemo/Domain/L10n.swift DroneUAVDemo/Input/KeyboardInputService.swift Tools/KeyBindingsProbe/main.swift -o "$BUILD/probe"
"$BUILD/probe"
