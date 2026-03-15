# Architecture

## Upgrade Strategy

Incremental rescue-first evolution of the existing macOS SwiftUI + SceneKit project.
No full rewrite. Existing app shell, persistence, scene controller, and services were preserved.

## Layered Design (Current)

1. UI layer
- `ContentView`
  - start menu + project list,
  - simulation workspace with top toolstrip (primary actions),
  - optional detailed side panel (`ControlPanelView`),
  - fullscreen trigger and save/open dialogs.
- `SceneViewportView`
  - 3D scene + compact telemetry HUD, resilient in collapsed-panel mode and fullscreen.

2. Input/control layer
- `KeyboardInputService`
  - action abstraction (`KeyboardCommand` -> `KeyboardAction`),
  - continuous key-hold state from keyDown/keyUp,
  - profile persistence + conflict detection,
  - high-priority `Tab` interception at input layer for deterministic panel toggle.

3. Simulation orchestration layer
- `DroneSimulationViewModel`
  - owns command pipeline and mode transitions,
  - performs spawn sanitization and launch diagnostics,
  - routes UI/buttons/keyboard into control state,
  - runs fixed-rate simulation tick + telemetry sampling.

4. Dynamics layer
- `SimpleDronePhysicsEngine`
  - semi-fixed timestep integration,
  - multirotor dynamics with rotor spool model,
  - fixed-wing simplified aerodynamics path,
  - startup force/torque diagnostics and ground-idle lock to prevent launch drift.

5. Rendering layer
- `DroneSceneController`
  - updates drone transforms, camera rigs, environment, overlays.
  - camera switching decoupled from physics (no force coupling from camera helpers).

6. Persistence/export layer
- `ProjectStorageService`: project snapshots + autosaves + index.
- `TelemetryExportService`: internal telemetry session persistence and explicit export.

## Runtime Data Flow

1. UI/keyboard emits actions.
2. ViewModel mutates `DroneControlValues` and `mode`.
3. ViewModel builds `DroneControlInput`.
4. Physics engine integrates `DroneState`.
5. Collision/battery/thermal services compute derived state.
6. Scene controller renders updated frame.
7. Telemetry snapshot is recorded/exported.

## Internal Storage

`Application Support/DroneUAVDemo/InternalStore`
- `Projects/<projectID>/project.json`
- `Autosaves/<projectID>.json`
- `Telemetry/<projectID>/session_<timestamp>.txt`
- `Index/projects_index.json`
