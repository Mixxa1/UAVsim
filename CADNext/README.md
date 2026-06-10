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
- CADNext 0.5: Sketch Workspace v1 — current.
- CADNext 0.6: Sketch profile → face → extrude.
- CADNext 0.7: Boolean operations.
- CADNext 0.8: Bridge/export into UAVsim.

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
