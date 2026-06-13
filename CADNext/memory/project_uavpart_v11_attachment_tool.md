---
name: project-uavpart-v11-attachment-tool
description: "UAVPart v1.1 — инструмент точек крепления: маркеры в viewport, диалог, local coordinates, part status display"
metadata:
  type: project
  originSessionId: current
---

# UAVPart v1.1 — Attachment Point Tool (2026-06-13)

**Новые файлы:**
- `gui/include/cadnext/gui/AttachmentPointDialog.hpp` + `gui/src/AttachmentPointDialog.cpp` — QDialog: имя, роль (payload/camera/sensor/generic), isEnabled; режимы create/edit/edit-system.

**SceneGraph изменения** (`viewer/include/cadnext/viewer/SceneGraph.hpp` + `viewer/src/SceneGraph.cpp`):
- `ViewportPickTarget.attachmentPointId` + `isAttachmentPoint()` — новое поле для результата пика по маркеру точки.
- `addOrUpdateAttachmentPointMarkers(bodyId, vector<AttachmentPoint>)` — добавляет группу сфер как дочерний узел body node (локальные координаты наследуют transform тела автоматически). Цвет зависит от роли: payload=amber, camera=cyan, sensor=green, generic=gray, selected=yellow, disabled=dark.
- `removeAttachmentPointMarkers/clearAttachmentPointMarkers` — очищают nodeToAttachmentPoint_ и удаляют группу из body node.
- `setSelectedAttachmentPoint/clearSelectedAttachmentPoint` — управление выделением.
- `showAttachmentPointPreview(worldPos)` / `hideAttachmentPointPreview()` — cyan сфера в world space (unpickable) следующая за курсором в режиме инструмента.
- `attachmentPreviewRoot_` — добавлен перед `sketchTransientRoot_` в root_.
- `pickTargetForPath`: attachment point проверяется первым (до nodeToObjectId_) → маркер побеждает pick по телу.
- `removeObjectNode` + `clearObjectNodes` очищают `attachmentMarkerGroups_` + `nodeToAttachmentPoint_`.

**ToolBar:** `addAttachmentPointAction_` — checkable кнопка "Добавить точку крепления".

**MainWindow:**
- `SelectionKind::AttachmentPoint` (private enum).
- `AttachmentPointSelection { bodyId, pointId }` + `selectedAttachmentPoint_`.
- `attachmentPointToolActive_` — активен/нет режим инструмента.
- `partStatusLabel_` — permanent QLabel в статус-баре (цвет #90c0e8).
- Pick callback: в режиме инструмента → `openCreateAttachmentDialog`; маркер → `selectAttachmentPoint`.
- Hover callback: если инструмент активен и курсор на теле → `showAttachmentPointPreview`.
- Escape → `exitAttachmentPointTool()` (первое).
- `selectBody/selectBodyFace/clearSelection` вызывают `updatePartStatusDisplay`.
- `refreshAttachmentPointMarkers` вызывается из всех путей buildObjectVisual, buildExtrudedBodyVisual, replayExtrudeCutFeature, applyEdgeOperation.
- `partBodyIdForSave()` понимает `SelectionKind::AttachmentPoint`.
- `deleteSelected` понимает `SelectionKind::AttachmentPoint`.

**worldToLocal(worldPoint, Transform)**: helper в anonymous namespace MainWindow.cpp — инвертированное преобразование для хранения localPosition в локальных координатах тела.

**generatePointId()**: простой UUID через mt19937_64 + random_device.

**updatePartStatusDisplay(bodyId)**: показывает "Масса: X кг | Габариты: A×B×C мм | Точки крепления: N | Статус: ...".

**simulationReady проверка**: attachmentPointsDefined=true если есть хотя бы один enabled attachment point + масса валидна через BRepGProp (density 1050 кг/м³ ABS по умолчанию).

**Сборка**: все 4 конфигурации собираются. 59/59 OCCT тестов, 43/43 stub тестов — все зелёные.

**Дальше**: экран выбора БЛА, Mount Editor, кнопка «Тестировать на БЛА», ExactGeometry/VisualMesh секции.
