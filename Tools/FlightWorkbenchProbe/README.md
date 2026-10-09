# Flight workbench integration probe

Build the macOS Debug app, then run the production objects in an isolated probe:

```sh
xcodebuild -project DroneUAVDemo.xcodeproj -scheme DroneUAVDemo -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/uavsim-flight-tools-build CODE_SIGNING_ALLOWED=NO build
bash Tools/FlightWorkbenchProbe/run-runtime.sh /tmp/uavsim-flight-tools-build /tmp/uavsim-flight-tools-preview
```

The probe checks native key down/up, remapping and focus release, hold-to-rewind/cancel/continue,
restoring battery and physics, recording branches and trimmed durations,
calibration pauses, USB HID report edges and disconnects, combined profile validation and round trips,
spatial wind, relief maps, replay environment changes and legacy decoding, scenario setup,
matching terrain rendering/collision/raycasting, placing search targets, fire trees and crop fields on relief,
placing existing vegetation assets on relief,
and independent articulation of the transmitter USDZ. Native views and SceneKit previews render to
the supplied output folder. Windows remain hidden. Test preferences use an isolated defaults suite;
interface scaling is restored after preview capture.

Synthetic HID reports exercise the backend. They do not replace a connection test with a physical
transmitter or joystick. Rewind covers local free flight and training; active scripted missions and
online sessions are excluded. Releasing a payload clears aircraft history.

The original articulated transmitter display asset can be rebuilt using the bundled Python runtime
with Pillow and the system `usdcat`, `usdzip`, and `usdchecker`:

```sh
python3 Tools/TransmitterAssets/build.py
```

Authoring source, pivot manifest, original textures and native USD validation output live in
`Assets/Transmitter`. Exterior dimensions are approximate and the model is for input visualization.

A focused shader probe reads the current modifier source and renders maximum relief through Metal:

```sh
bash Tools/FlightWorkbenchProbe/run-runtime.sh /tmp/uavsim-flight-tools-build /tmp/uavsim-flight-tools-preview "$PWD/Tools/FlightWorkbenchProbe/ShaderProbe.swift"
```
