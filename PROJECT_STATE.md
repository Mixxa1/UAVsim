# Project State

Last updated: 2026-03-13  
Workspace: `/Users/misha/Documents/New project`  
Project: `DroneUAVDemo` (macOS, SwiftUI + SceneKit)

## Current Status

Rescue stabilization patch is applied. Build status is green:
- `xcodebuild -project DroneUAVDemo.xcodeproj -scheme DroneUAVDemo -configuration Debug -destination 'platform=macOS' -derivedDataPath ./.DerivedData build` => **BUILD SUCCEEDED**.

Baseline stability work now in place:
- deterministic spawn sanitization (zero linear/angular velocity, zero rotor state, manual mode baseline),
- startup diagnostics for launch state and early-frame force/torque checks,
- multirotor ground-idle lock preventing unintended lateral slide at idle,
- button command path verified (`Takeoff`, `Hover`, `Land`, `Reset`, `Emergency`) through the ViewModel command pipeline,
- robust `Tab` action interception in input layer for repeated panel collapse/expand,
- top-oriented toolstrip workflow in workspace (Simulation/Flight/Camera/Environment/Debug/Projects),
- macOS fullscreen support via menu command + toolstrip button, with adaptive scene layout.

## Latest Rescue Changes

1. Physics stabilization
- Added startup net-force diagnostics and warning when lateral force is nonzero in initial frames.
- Set rotor target to `0` on ground-idle (instead of maintaining idle spin).
- Strengthened ground lock to clamp `x/z` position and zero dynamic terms when collective is effectively idle.
- Reduced damage-induced asymmetry while on/near ground to avoid startup bias.

2. Spawn/state reset hardening
- `sanitizeDynamicStateForSpawn` now enforces hard reset for init/reset contexts:
  - position/orientation reset to origin-level neutral,
  - manual mode enforced,
  - weather reset to normal/no wind/no gusts,
  - rotor/motor/velocities zeroed.

3. Fullscreen and layout
- Window scene is now fullscreen-capable (`windowResizability(.automatic)`).
- Added explicit fullscreen command (`Ctrl+Cmd+F`) and toolstrip trigger.
- Scene viewport frame constraints updated for fullscreen-safe resizing.

## Remaining Risks

1. Left-drift root cause is now instrumented and mitigated, but needs runtime validation against multiple model/weather presets.
2. `Tab` now routes through keyboard service; behavior in all text-edit edge cases should still be validated manually.
3. Physics debug UX is functional but not yet a complete in-scene contact inspector.
