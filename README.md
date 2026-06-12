# DroneUAVDemo / UAVsim

DroneUAVDemo is a macOS SwiftUI / SceneKit UAV simulation workspace. The active app focuses on simulation runtime, mission planning, payload workflows, replay review, input handling, telemetry, and project persistence.

## Current Runtime Scope

- UAV simulation workspace with SceneKit viewport and SwiftUI control surfaces.
- Mission planning, mission drafts, validation, timeline, map, and safety state.
- Payload configuration, mount state, camera controls, and payload overlays.
- Replay center, replay player, timeline editing, comparison, trimming, and video export services.
- Keyboard, controller, autopilot, and remote input providers.
- UAV catalog, profile filtering, drone physics, terrain, weather, damage, battery, and telemetry models.
- CADNext integration placeholder:
  новая CAD-система вынесена из активного Swift/SceneKit слоя и будет развиваться как отдельный C++/OCCT/Qt/Coin3D/Python компонент. Исторический функционал старой CAD-мастерской зафиксирован в `readmeCADv_zero.md`.

## Repository Layout

- `DroneUAVDemo/Presentation` — SwiftUI shell, simulation workspace, module sidebars, replay UI, payload UI, mission UI, and overlays.
- `DroneUAVDemo/Presentation/ViewModels` — runtime orchestration for simulation, replay library, controller bindings, legal gate, and compass state.
- `DroneUAVDemo/Domain` — Codable domain models for UAVs, missions, payload, replay, input authority, map state, telemetry, and neutral external CAD bridge records.
- `DroneUAVDemo/Domain/CADBridge` — lightweight bridge models for future CADNext exports into the simulator. These models do not import CAD v0, OCCT, Coin3D, Qt, or SceneKit.
- `DroneUAVDemo/Simulation` — flight physics, mission execution, autopilot, replay recording/playback, mission reports, safety, collision, and planning services.
- `DroneUAVDemo/Scene` — SceneKit scene construction for simulation and replay only.
- `DroneUAVDemo/Input` — keyboard, controller, remote, autopilot, bindings, and resolved control state.
- `DroneUAVDemo/Remote` — remote packet transport and decoding.
- `DroneUAVDemo/Services` — replay storage/settings, telemetry export, video export, and legal agreement services.
- `DroneUAVDemo/Resources` — localization, assets, and legal documents.
- `CADNext` — external CAD architecture skeleton for the future C++ / OCCT / Coin3D / Qt / Python CAD component.
- `readmeCADv_zero.md` — archive of the removed Swift/SceneKit CAD v0 functionality.

## CADNext Direction

CADNext is intentionally separate from the Swift/macOS simulator app. Its core direction is:

- C++ core for documents, objects, feature history, materials, transforms, attachment points, and mass properties.
- Generation 1 foundation now includes `Result`/`Error`, kernel abstraction, `StubKernel`, OCCT backend boundary, CMake tests, Python binding placeholder, and a UAVSim export package.
- OCCT for BRep topology, wires, faces, solids, shape validation, fillets, chamfers, and boolean operations.
- Coin3D for interactive viewport and selection.
- Qt Widgets / QtGui for the desktop CAD UI.
- Python wrappers, macros, workbenches, and automation.
- A neutral export bridge so UAVsim can consume visual meshes, collision meshes, mass properties, center of mass, attachment points, material tags, payload mount points, and UAV role tags without depending on OCCT directly.

## Build Notes

The active macOS app is the `DroneUAVDemo` Xcode project. CADNext is a separate CMake project and does not participate in the Swift app target.

CADNext can be launched from the main application menu (CAD → Open CADNext) as an external standalone CAD module. The Swift simulator does not embed the Qt/Coin3D CAD UI; it only locates and starts the separately built `cadnext_app` binary (`CADNext/build-gui/app/cadnext_app` or `CADNext/build-gui-occt/app/cadnext_app`).

The previous embedded CAD v0 system has been removed from the active build target and should not be reintroduced as a runtime dependency.
