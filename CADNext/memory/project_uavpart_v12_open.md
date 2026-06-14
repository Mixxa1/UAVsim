---
name: uavpart-v12-open
description: UAVPart v1.2 — открытие .uavpart, UAVPartPreviewPanel, CADPartLibraryService, раздельные меню
metadata:
  type: project
---

Патч добавляет самостоятельный маршрут открытия .uavpart без смешения с .cadnext loader.

**Why:** .cadnext — рабочий CAD-документ с историей операций; .uavpart — готовая деталь/payload asset.

**How to apply:** При работе с функциональностью открытия/импорта деталей использовать новый роутинг.

## Новые файлы

- `gui/include/cadnext/gui/CADPartLibraryService.hpp` — синглтон, хранит список путей .uavpart в `~/.cadnext/parts_library.json` (Qt JSON)
- `gui/src/CADPartLibraryService.cpp`
- `gui/include/cadnext/gui/UAVPartPreviewPanel.hpp` — QDialog для просмотра открытой детали
- `gui/src/UAVPartPreviewPanel.cpp` — показывает имя, материал, массу (кг), габариты (мм), CoM, точки крепления, статус; кнопки "Добавить в библиотеку" и "Открыть только сейчас"

## Изменённые файлы

- `gui/CMakeLists.txt` — добавлены 4 новых файла в target cadnext_gui
- `gui/include/cadnext/gui/MainWindow.hpp` — добавлен `void openUAVPart()`
- `gui/src/MainWindow.cpp`:
  - добавлены includes: `UAVPartReader.hpp`, `UAVPartPreviewPanel.hpp`
  - реализован `MainWindow::openUAVPart()`: диалог→reader.readFullPart()→UAVPartPreviewPanel
  - меню "Файл": "Открыть…" → "Открыть CAD-документ…" + "Открыть деталь…"
  - меню "Файл": "Сохранить" → "Сохранить CAD-документ"

## Статус готовности (UAVPartPreviewPanel)

- `simulationReady==true` → зелёный "Готова к тестированию на БЛА"
- `attachmentPoints.empty()` → оранжевый "Добавьте точку крепления"
- `!mass.valid` → красный "Масса детали не рассчитана"
- иначе → readinessIssues[0] через `uavpartReadinessIssueText()`

## Ограничения v1.2

- ExactGeometry не записывается → "Открыть для редактирования" не реализовано
- VisualMesh не записывается → показывается только предупреждение (без 3D-превью)
- Деградированный режим: файл открывается при любом состоянии, ошибки — в UI

## Следующий шаг

Полноценный каталог Part Library с UI (фильтры, иконки, drag-and-drop), привязка к выбору БЛА.
