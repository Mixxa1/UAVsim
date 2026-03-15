# Decisions and Assumptions

Last updated: 2026-03-13

## Decisions

1. Rescue-first over feature creep
- Stability regressions are addressed before further aerodynamics/features.
- If advanced path destabilizes baseline control, baseline-safe behavior wins.

2. Deterministic spawn reset is mandatory
- On init/reset: zero velocities, zero rotor state, neutral controls, manual mode baseline.
- Weather reset to normal/no wind for hard reset contexts.

3. Launch diagnostics stay enabled
- Keep startup logs for first-frame force/torque and controller/motor state.
- Explicit warning if net lateral force is nonzero at startup.

4. Ground-idle lock is allowed as a safety guard
- While near-ground with low collective, lock dynamic drift terms and suppress idle side-slip.
- This is a stability safeguard for baseline usability.

5. Tab is treated as a primary control action
- `Tab` is intercepted at keyboard input service level, independent of SwiftUI focus chain.
- This preserves reliable panel collapse/expand in windowed and fullscreen modes.

6. Fullscreen is a first-class app behavior
- Window is configured with automatic resizability and explicit fullscreen command.
- Scene viewport/layout must adapt without fixed-size assumptions.

7. Top-oriented primary workflow
- Main flight operations live in top toolstrip groups.
- Side panel remains optional/detailed, not the primary control surface.

## Assumptions

1. This pass targets a stable baseline, not final high-fidelity physics.
2. SceneKit + SwiftUI local event monitoring remains acceptable for this app architecture.
3. Localization via `.strings` remains acceptable for this phase; String Catalog migration can follow.
