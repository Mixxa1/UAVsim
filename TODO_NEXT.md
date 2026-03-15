# TODO Next (Prioritized)

## P0 (Stability Gate)

1. Verify left-drift fix in runtime matrix
- Validate neutral spawn for each drone model + each camera mode + weather normal/wind.
- Keep startup diagnostics enabled until no lateral-force warnings appear in smoke runs.

2. Baseline control acceptance tests
- Manual check suite: spawn neutral, throttle response, takeoff/hover/land/reset/emergency.
- Confirm no dead button paths and no one-shot command regressions.

3. Tab + fullscreen interaction checks
- Validate repeated `Tab` collapse/expand in:
  - windowed mode,
  - fullscreen mode,
  - while text fields were recently focused.

## P1

1. Physics debug completeness
- Add physics-shape and contact-point visual toggles via SceneKit debug flags.
- HUD line for last collision source/category/mask.

2. Input/rebind UX hardening
- Add clearer conflict UX during rebinding.
- Add profile import/export.

3. Camera stabilization tuning
- Fine-tune chase defaults per airframe class.
- Validate FPV obstruction hide/restore sets per model.

## P2

1. Telemetry browser UI in project details.
2. Environment performance pass (LOD/instancing and particle throttling).
3. Localization migration from `.strings` to String Catalog.
