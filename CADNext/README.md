# CADNext

CADNext — новая CAD-система для проекта DroneUAVDemo / UAVsim.

## Статус

Это новая архитектура, заменяющая старую Swift/SceneKit CAD v0.  
Старый функционал зафиксирован в `../readmeCADv_zero.md`.

## Архитектура

CADNext строится как отдельный CAD-компонент:

- C++ core;
- Open CASCADE Technology для геометрического ядра;
- Coin3D для 3D viewport;
- Qt Widgets / QtGui для пользовательского интерфейса;
- Qt Style Sheets для тем;
- Python bindings для всех C++ API;
- Python macros и workbenches;
- будущий bridge к DroneUAVDemo / UAVsim.

## Основные принципы

1. Реальная геометрия хранится как solid/topology, а не как SceneKit mesh.
2. OCCT отвечает за BRep, faces, edges, wires, solids, fillets, chamfers и boolean operations.
3. Mesh используется только для отображения.
4. Все C++ API должны иметь Python wrapper.
5. Быстрые и критические операции остаются в C++.
6. Python используется для макросов, рабочих сред и автоматизации.
7. Qt отвечает за desktop UI.
8. Coin3D отвечает за интерактивный 3D viewport.
9. Связь с симулятором выполняется через отдельный bridge/export layer.
10. Симулятор не должен напрямую зависеть от OCCT.

## Модули

- `core` — документы, объекты, features, материалы, transforms, attachment points и units.
- `kernel` — абстракция геометрического ядра, stub backend для сборки по умолчанию и граница будущего OCCT backend.
- `viewer` — Coin3D scene graph (grid, axes, primitive nodes), selection и SoQt viewport; собирается только при `CADNEXT_WITH_COIN3D=ON`.
- `gui` — Qt Widgets shell: main window, project tree, property panel, toolbar и workbench host; собирается только при `CADNEXT_WITH_QT=ON`.
- `app` — standalone исполняемый файл `cadnext_app`; собирается только при `CADNEXT_BUILD_APP=ON` (требует Qt и Coin3D флаги).
- `python` — SWIG/PyCXX/PySide-compatible зона для wrappers, macros и workbenches; собирается только при `CADNEXT_WITH_PYTHON=ON`.
- `bridge` — нейтральный экспорт в UAVsim: visual mesh, collision mesh, mass properties, center of mass, attachments, material tags и UAV role tags.
- `tests` — первые unit-level контракты новой архитектуры.

## Roadmap

- CADNext 0.2: Touchable Viewer Prototype — done.
- CADNext 0.3: Interaction & Document Editing Layer — done.
- CADNext 0.4: OCCT primitives and BRep-backed shapes — done.
- CADNext 0.5: Sketch Workspace v1.
- CADNext 0.6: Extrude + Custom Profiles v1 — done.
- CADNext 0.7: Stable Custom Profiles and Extrude Cut v1 — done.
- CADNext 0.8: Work Planes on Body Faces / Sketch on Face — current.
- CADNext 0.9: Bridge/export into UAVsim.

## CADNext 0.8 — Work Planes on Body Faces / Sketch on Face

Workflow цели этапа:

```text
Extrude body
→ select planar face
→ Create Sketch on Face
→ camera normal to selected face
→ draw sketch on that face
→ Extrude / Cut from face sketch
```

Implemented:

- face picking поверх body picking: клик по телу выбирает конкретную
  грань (hover — слабая подсветка, selected — заливка + рамка);
- rendered body mesh carries triangle face ownership:
  `MeshTriangle::faceId` maps the picked `SoIndexedFaceSet` face index
  back to the owning body face before falling back to body selection;
- procedural prism/extrude meshes assign face ids (`face-cap-start`,
  `face-cap-end`, `face-side-N`), so non-OCCT extruded bodies can still
  be face-picked and sketched on; procedural viewer primitives without a
  face-owned mesh remain body-only and report that face picking requires
  an OCCT backend;
- Coin3D face overlays are still used for hover/selected highlight and
  as an additional pick proxy, but the primary body-surface path is now
  triangle ownership from the rendered mesh;
- planar face analysis через OCCT (`FaceAnalyzer`):
  - `TopExp_Explorer` по `TopAbs_FACE`;
  - `BRepAdaptor_Surface` + `GeomAbs_Plane` / `gp_Pln`;
  - orthonormal right-handed u/v/normal frame, normal наружу из тела;
  - width/height/origin из face bounds, area из triangulation;
  - классификация Planar/Cylindrical/Conical/Spherical/Other;
  - только planar faces получают `isSketchable = true`;
- stable-ish face id v1: `face-<index>-<normalHash>-<centerHash>-<areaHash>`
  из квантованной геометрии — простые extrude bodies получают те же ids
  после save/load;
- Property Panel для выбранной грани: Body, Face id, Kind, Origin,
  U/V/Normal, Size, Area, Sketchable;
- `Create Work Plane from Face`: WorkPlane объект в Document, в дереве
  (`Work Planes → Plane from Face N`), selectable/sketchable как обычная
  плоскость, удаляемый;
- `Create Sketch on Face`: face-based sketch через единый вход
  `enterSketchOnReference(...)` — тот же путь, что canonical planes;
- `Normal to Face` (toolbar, Part menu и context menu на грани);
- камера автоматически становится normal to face при входе в эскиз;
- sketch grid/cursor/preview лежат строго на плоскости грани, геометрия
  хранится в локальных face u/v;
- Extrude / Cut Extrude от face-based sketch работают через существующий
  OCCT pipeline без отдельной логики (top face cut, side face cut);
- Cut Extrude требует OCCT BRep backend. DroneUAVDemo launcher поэтому
  предпочитает `CADNext/build-gui-occt/app/cadnext_app`; procedural
  `build-gui` остается fallback без boolean cut;
- save/load: `SketchReference` типа `BodyFace` (`sourceBodyId`,
  `sourceFaceId`, resolved plane, `displayName`) и массив `workPlanes`
  в `.cadnext`; при load faceId ре-резолвится по пересобранным телам.

Not implemented yet (осознанно за рамками 0.8):

- full/robust topological naming;
- parametric regeneration зависимых features после изменения ранних;
- sketch on curved faces (цилиндр/конус/сфера — not sketchable);
- offset face / tangent plane;
- face constraints, assembly constraints.

CADNext 0.8 stores resolved face plane geometry as fallback.
Full robust topological naming is planned later.

Face ids стабильны для текущего evaluated body state; если после load
(или после изменения тела) faceId не находится, face-based sketch и
work plane продолжают работать от сохранённой resolved plane reference —
документ обязан загружаться в любом случае. Face workflows доступны
только в OCCT-сборках: без BRep backend список граней пуст и face-действия
просто остаются недоступными.

## CADNext 0.7 — Stable Custom Profiles and Extrude Cut v1

Implemented:

- robust custom polygon profile detection from committed line loops;
- endpoint clustering for line loops with stable tolerance;
- profile rebuild after add/delete/cancel/load/undo/redo;
- stale profile cache prevention;
- self-intersecting closed loops reported as invalid profiles;
- clearer XY/XZ/YZ Sketch2D orientation;
- Sketch2D plane badge:
  - Plane XY: U=X, V=Y;
  - Plane XZ: U=X, V=Z;
  - Plane YZ: U=Y, V=Z;
- local U/V axis labels and colors follow world axes:
  - X red;
  - Y green;
  - Z blue;
- Cut Extrude command;
- Distance cut mode;
- Through All cut mode;
- To Object cut mode v1 using limit object bounding box projection;
- Cut preview as a transient red/orange cutter volume;
- OCCT BRep cut pipeline:
  - Sketch profile → TopoDS_Wire;
  - TopoDS_Wire → TopoDS_Face;
  - BRepPrimAPI_MakePrism cutter solid;
  - BRepAlgoAPI_Cut topological boolean cut;
  - BRepMesh_IncrementalMesh / MeshExtractor viewport mesh.

Not implemented yet:

- Up To Face;
- Up To Nearest Face;
- Thin cut;
- Draft angle;
- offset from face;
- advanced feature regeneration after sketch edits;
- multi-body boolean management;
- pattern/mirror.

Cut Extrude is available only in OCCT-enabled builds. The non-OCCT
procedural fallback keeps Extrude New Body working but intentionally does
not perform mesh subtraction. Cut features are saved as metadata
(`targetBodyId`, `sketchId`, `profileId`, `depthMode`, `direction`,
`distance`, `limitObjectId`) and replayed on load when an OCCT backend is
available; the transient cutter preview and raw OCCT shape internals are
never serialized.

## CADNext 0.6 — Extrude + Custom Profiles v1

Implemented:

- sketch profile detector v1;
- rectangle profile detection;
- circle profile detection;
- closed line-loop polygon profile detection;
- profile selection;
- Extrude command;
- Extrude dialog:
  - New Body operation;
  - Distance depth mode;
  - Positive / Negative / Symmetric direction;
- extrude preview;
- Apply Extrude creates a new body;
- extrusion direction respects sketch plane normal;
- `.cadnext` save/load for extrude metadata.

Not implemented yet:

- boolean cut;
- add material / fuse;
- through all;
- up to object;
- up to face;
- advanced feature regeneration;
- constraints.

Custom closed profiles are built from lines: consecutive line entities
whose endpoints chain together (small tolerance) and whose last endpoint
returns to the first form one Polygon profile. Open chains and
self-intersecting loops are invalid and cannot be extruded. Detected
profiles are shown with a faint fill in sketch mode; clicking inside a
region (or on a rectangle/circle entity) selects the profile, which then
gets a brighter fill and an orange outline.

Extrusion follows the sketch plane normal (`world = origin + u·U + v·V`,
direction = ±normal, Symmetric = ±distance/2): XY extrudes along Z, XZ
along Y, YZ along X. With OCCT enabled the body is built as a BRep prism
(wire → face → prism; circles use an exact circular wire); without OCCT a
procedural prism mesh (ear-clipped caps + side walls) keeps the GUI build
working. In both paths the profile + `ExtrudeParameters` stay the source
of truth — the generated body mesh is derived, never serialized, and is
re-derived from the feature recipe on load.

`.cadnext` files gain optional `extrude`/`createdBodyId` members on
features (format version unchanged; pre-0.6 files keep loading).
Profiles are not saved — the detector finds them again after load.

## CADNext 0.5 — Sketch Workspace v1

Implemented in this stage:

- sketch data model;
- XY/XZ/YZ sketch planes;
- sketch mode;
- sketch plane visualization (translucent plane + U/V axes);
- basic sketch tools:
  - Line (two clicks: start, end);
  - Rectangle (two clicks: opposite corners);
  - Circle (two clicks: center, radius point);
- sketch entity rendering;
- sketch entity selection (project tree and viewport click);
- project tree support for sketches and sketch entities (Bodies/Sketches groups);
- `.cadnext` save/load support for sketches (older files without sketches keep loading);
- profile detection v1 for rectangle and circle profiles (plus a sequential
  closed line loop);
- preparation for Sketch → Face → Extrude workflow (`ExtrudeParameters`
  placeholder, profiles carry outer loops and areas);
- Esc cancels the active sketch tool;
- sketch entity name editing (geometry parameters are read-only in 0.5;
  parameter editing and dimensions arrive in 0.6);
- AddSketchEntityCommand / RenameSketchEntityCommand wired into undo/redo.

CADNext uses Z-up viewport convention.
Default sketch plane is XY.
Sketch coordinates are stored as local 2D u/v coordinates:

```text
XY: u=X, v=Y, normal=Z
XZ: u=X, v=Z, normal=Y
YZ: u=Y, v=Z, normal=X
```

This stage intentionally does not implement boolean operations.
Extrude from sketch is planned as the next stage.

### CADNext 0.5 UX Fix — WorkPlane Rendering and Sketch2D Navigation

Fixed in this stage:

- work planes are helper overlays and no longer visually occlude bodies;
- selected plane uses outline-first highlighting;
- non-active planes are hidden/dimmed in Sketch2D;
- Sketch2D switches to true orthographic normal-to-plane view;
- orbit is disabled in Sketch2D;
- trackpad gestures in Sketch2D map to pan/zoom;
- Properties panel moved to the right inspector dock;
- sketch cursor/live preview/snap remain on the active sketch plane;
- Fit View ignores infinite axes and helper overlays where appropriate.

Work plane helpers live in their own scene layer rendered after the
bodies, are drawn outline-first (the fill quad is an invisible pick proxy
that only gets a faint tint on hover/selection) and never write the depth
buffer, so a helper plane can tint a body but never hide it. The world
grid/axes and all plane frames are hidden in Sketch2D — only the active
sketch plane helper (fill, grid, local U/V axes, origin marker) remains.

The Sketch2D camera is orthographic and locked normal to the plane with
U horizontal and V vertical on screen; for the left-handed canonical XZ
plane the camera sits on the -Y side so +X still points right
(`planeNormalViewSide`). In Sketch2D mode, orbit is disabled. Trackpad
gestures are mapped to pan and zoom so the active sketch plane remains
locked to the screen: two-finger scroll pans along U/V, pinch zooms at
the cursor (a discrete mouse wheel zooms too), and a left drag pans.

The helper visibility / navigation / Fit View rules are encoded in the
headless-testable `cadnext::ViewportPolicy`
(`tests/test_workplane_visibility_policy.cpp`,
`tests/test_sketch2d_view_state.cpp`,
`tests/test_sketch_reference_mapping.cpp`). A selected plane offers a
context menu (secondary click): Create Sketch, Normal to Plane, Fit
Plane, Hide Other Planes. The Properties inspector is a right-side dock
(View menu toggles it), so the viewport keeps its full height; with no
selection it shows a "No selection" empty state.

### Sketch Plane Input Fix

CADNext sketch input now uses a strict active SketchReference:

- New Sketch XY/XZ/YZ automatically enters Sketch2D view.
- The camera becomes normal to the active sketch plane.
- Orthographic sketch view is used for 2D input.
- Mouse coordinates are projected onto the active sketch plane
  (analytic camera-ray/plane intersection — never a depth pick, never
  the world grid).
- Sketch cursor/crosshair shows the exact point that will be used.
- Snap-to-grid is applied in local U/V coordinates.
- Line/Rectangle/Circle tools show live preview before commit.
- Final sketch entities are stored in the local U/V coordinates of their
  sketch plane.
- In Sketch2D the left drag pans (orbit is disabled and can never knock
  the camera off the plane normal); wheel zoom keeps working.

Invariant: cursor, preview and committed geometry must use the same
active SketchReference. The shared `sketchPointToWorld` /
`worldToSketchPoint` core transforms are the single source of truth for
input projection, transient previews and committed entity rendering
(`isWorldPointOnSketchPlane` guards this at commit time).

### Sketch input UX

CADNext sketch mode supports:

- live sketch cursor/crosshair;
- snap-to-grid;
- configurable grid step;
- show/hide sketch grid;
- rubber-band preview for Line;
- live rectangle preview;
- live circle preview;
- anchor marker after the first point;
- Esc cancellation for pending sketch operations.

Esc is two-stage: the first press cancels the pending operation and keeps
the tool armed, the second press returns to Select. The snap/grid controls
live on the sketch toolbar (`Snap Grid`, `Show Grid`, `Grid:` step
spinbox); the status bar shows the current mode
(`Sketch: Snap ON, Grid 0.100`). The grid step drives both the snap math
and the drawn sketch grid (the drawn spacing is capped for very fine
steps; snapping always uses the exact step, minimum 0.001).

Transient preview geometry is not stored in `.cadnext`.
Only committed sketch entities are serialized.

CADNext can be launched from the DroneUAVDemo application menu
(CAD → Open CADNext); the Swift simulator only starts the standalone
`cadnext_app` process and never embeds the Qt/Coin3D UI.

## CADNext 0.4 — OCCT-backed primitives / BRep evaluation

Implemented in this stage:

- optional OCCT backend (`CADNEXT_WITH_OCCT=ON`);
- BRep-backed Box primitive;
- BRep-backed Cylinder primitive;
- BRep-backed Sphere primitive;
- internal ShapeHandle → TopoDS_Shape registry (OCCT types never leave the
  kernel implementation and are never serialized);
- OCCT shape validation (`BRepCheck_Analyzer`);
- BRep → TriangleMesh extraction (`BRepMesh_IncrementalMesh`, deflection
  scaled by the shape bounding box, face-orientation-aware winding);
- Coin3D mesh-backed viewport rendering when OCCT is enabled;
- procedural viewer fallback when OCCT is disabled or evaluation fails;
- status bar shows the active geometry backend;
- save/load remains parameter-based and does not serialize OCCT internals —
  every load re-evaluates shapes from the primitive descriptors.

Evaluation pipeline:

```text
PrimitiveParameters → GeometryEvaluator → Kernel/OcctKernel
  → ShapeHandle (internal TopoDS_Shape) → MeshExtractor → TriangleMesh
  → Coin3D viewport
```

The Coin3D mesh is display data only and is never the geometric source of truth.

Primitive bodies are built centered on the local origin (cylinder axis along
Z); world placement always comes from `Object.transform`, matching the 0.2/0.3
viewer behavior.

Reference Plane remains a viewer/helper object in this stage.
Boolean operations are intentionally not implemented yet.

## CADNext 0.3 — Interaction & Document Editing Layer

Implemented in this stage:

- viewport picking (clean left click ray-picks; click on empty space clears
  the selection; drags keep navigating the camera);
- unified selected object state (`MainWindow::selectObject`/`clearSelection`);
- tree ↔ viewport ↔ property panel synchronization;
- editable object name (empty names are rejected, id never changes);
- editable transform (position/rotation/scale via spin boxes);
- editable primitive dimensions (box W/H/D, cylinder R/H, sphere R, plane W/H);
- per-object viewer node updates (grid/axes and untouched objects are not
  rebuilt; the selection highlight survives dimension edits);
- `.cadnext` JSON save/load (`DocumentSerializer`, format version 1, no
  external JSON dependency);
- document dirty-state (`*` in the window title);
- File New/Open/Save/Save As actions with platform shortcuts and a
  Save/Discard/Cancel prompt when closing a dirty document;
- minimal command stack foundation for undo/redo (`CommandStack`;
  only `RenameObjectCommand` is wired into the GUI Edit menu for now —
  command coverage grows in later stages).

This stage still intentionally avoids boolean operations and sketch/extrude workflows.
The purpose is to make CADNext behave like a real editable document before introducing OCCT-backed BRep operations.

CADNext 0.3 stores transform rotationEuler in degrees. This may be normalized later when OCCT transform integration is introduced.

## CADNext 0.2 — Touchable Viewer Prototype

Implemented in this stage:

- standalone CADNext app entry point (`cadnext_app`);
- Qt MainWindow skeleton;
- Coin3D viewport skeleton (SoQtExaminerViewer: orbit/pan/zoom);
- scene root, camera, light;
- grid and axes (X red, Y green, Z blue; Z-up);
- Add Box action;
- Add Cylinder action;
- Add Sphere and Add Plane (reference plane placeholder) actions;
- project tree;
- property panel (name editable; transform and dimensions read-only);
- tree-based selection;
- selected object highlight;
- Fit View / Reset Camera actions;
- Delete Selected action;
- `PrimitiveKind` / `PrimitiveParameters` construction descriptor in core
  (временный viewer descriptor, не финальный BRep источник истины);
- core test `test_primitive_object`.

CADNext 0.2 supports project-tree based selection.
Viewport picking is planned for CADNext 0.3/0.4.

This stage intentionally does not implement boolean operations yet.
The purpose is to make CADNext visible and interactive before adding heavy geometry kernel logic.

### Сборка без GUI (default)

```bash
# Default, no external geometry/UI dependencies
cmake -S CADNext -B CADNext/build
cmake --build CADNext/build
ctest --test-dir CADNext/build
```

### Сборка с GUI (Qt + Coin3D)

Требуются Qt6, Coin3D и SoQt (например, `brew install coin3d` — установит
Coin, SoQt и qtbase).

```bash
# GUI without OCCT
cmake -S CADNext -B CADNext/build-gui \
  -DCADNEXT_BUILD_APP=ON \
  -DCADNEXT_WITH_QT=ON \
  -DCADNEXT_WITH_COIN3D=ON

cmake --build CADNext/build-gui
```

### Сборка с OCCT

Требуется Open CASCADE Technology (например, `brew install opencascade`).

```bash
# OCCT core tests
cmake -S CADNext -B CADNext/build-occt \
  -DCADNEXT_WITH_OCCT=ON

cmake --build CADNext/build-occt
ctest --test-dir CADNext/build-occt

# GUI with OCCT
cmake -S CADNext -B CADNext/build-gui-occt \
  -DCADNEXT_BUILD_APP=ON \
  -DCADNEXT_WITH_QT=ON \
  -DCADNEXT_WITH_COIN3D=ON \
  -DCADNEXT_WITH_OCCT=ON

cmake --build CADNext/build-gui-occt
```

Запуск приложения:

```bash
CADNext/build-gui/app/cadnext_app        # procedural backend
CADNext/build-gui-occt/app/cadnext_app   # OCCT BRep backend
```

## CADNext generation 1 foundation

Current implemented foundation:

- C++ core document model;
- object model;
- feature history model;
- material / transform / attachment point contracts;
- result / error contract;
- kernel abstraction;
- stub kernel backend;
- optional OCCT backend boundary;
- UAVSim bridge export package;
- Python binding boundary placeholder;
- CMake build skeleton;
- basic architecture tests.

## Не входит в первый каркас

- полноценный OCCT build;
- boolean operations;
- CAD editor;
- перенос старого Swift/SceneKit cut pipeline;
- зависимость DroneUAVDemo от OCCT, Coin3D или Qt.
