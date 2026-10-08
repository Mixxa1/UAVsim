#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/uavsim-workbench-asset-probe"
APP="$BUILD/WorkbenchAssetProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cd "$ROOT"
"$ROOT/Tools/probe-sources.sh" > "$BUILD/sources.txt"
cat >> "$BUILD/sources.txt" <<'EOF'
DroneUAVDemo/Scene/WorkbenchModelBuilder.swift
DroneUAVDemo/Scene/WorkbenchModelAssetLibrary.swift
EOF
tr '\n' '\0' < "$BUILD/sources.txt" | xargs -0 swiftc -O -module-cache-path "$BUILD/module-cache" \
  -o "$APP/Contents/MacOS/probe" Tools/WorkbenchAssets/probe.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.uavsim.workbenchassetprobe</string>
<key>CFBundleExecutable</key><string>probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
EOF
ln -sfn "$ROOT/DroneUAVDemo/Resources/Models/WorkbenchParts" "$APP/Contents/Resources/WorkbenchParts"
"$APP/Contents/MacOS/probe" "$ROOT/DroneUAVDemo/Resources/Models/WorkbenchParts"
