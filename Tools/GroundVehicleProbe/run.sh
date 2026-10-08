#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-ground-vehicle-probe"
mkdir -p "$BUILD"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/original-sources.txt"
# Compile a snapshot so continuing work cannot mutate the compiler's input halfway through.
python3 - "$BUILD" "$ROOT" <<'PY'
import pathlib, shutil, sys
build, root = map(pathlib.Path, sys.argv[1:])
paths = (build / 'original-sources.txt').read_text().splitlines()
paths.append('DroneUAVDemo/Scene/GroundVehicleVisual.swift')
paths.append('DroneUAVDemo/Scene/MissionReplayWorldVisuals.swift')
paths.append('DroneUAVDemo/Scene/WorldDamageEffectVisual.swift')
paths.append('DroneUAVDemo/Scene/FireVisualAssetLoader.swift')
with (build / 'sources.txt').open('w') as out:
    for path in paths:
        target = build / 'snapshot' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / path, target)
        out.write(str(target) + '\n')
shutil.copy2(root / 'Tools/GroundVehicleProbe/main.swift', build / 'main.swift')
PY
export SWIFT_MODULECACHE_PATH="$BUILD/swift-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD/clang-cache"
tr '\n' '\0' < "$BUILD/sources.txt" | xargs -0 swiftc -O -o "$BUILD/probe" "$BUILD/main.swift"
cp -R "$ROOT/DroneUAVDemo/Resources/VFX" "$BUILD/"
cp "$ROOT/DroneUAVDemo/Resources/Models/Scenario/Fire_sheet_baseColor.png" "$BUILD/"
cp "$ROOT/DroneUAVDemo/Resources/Models/Scenario/Fire_sheet_emissive.jpg" "$BUILD/"
"$BUILD/probe" "$ROOT/DroneUAVDemo/Resources/Models/Vehicles" "$BUILD"
