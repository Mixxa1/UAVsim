# Структура проекта DroneUAVDemo

Документ описывает актуальную структуру активного Swift/macOS проекта после удаления встроенной Swift/SceneKit CAD v0.

Исторический функционал старой CAD-системы вынесен в архив `../readmeCADv_zero.md`. Новая CAD-архитектура развивается отдельно в `../CADNext`.

## Активное приложение

- `DroneUAVDemoApp.swift` — точка входа macOS-приложения.
- `Presentation/Views` — SwiftUI shell, стартовый экран, runtime viewport, mission UI, replay UI, payload UI, модульная панель и overlays.
- `Presentation/ViewModels` — состояние симуляции, replay-библиотеки, биндов, compass и legal gate.
- `Domain` — модели БЛА, миссий, payload, replay, карты, input authority, telemetry и neutral CAD bridge.
- `Domain/CADBridge` — минимальные `Codable`-модели для будущего импорта внешних CADNext-экспортов в симулятор.
- `Simulation` — flight physics, mission execution, autopilot, safety, mission planning, replay recording/playback и reports.
- `Scene` — SceneKit-сцены симуляции и replay.
- `Input` — keyboard, game controller, autopilot, remote input и bindings.
- `Remote` — transport, packets и decoder для удаленного управления.
- `Services` — replay storage/settings, telemetry export, video export и legal agreement services.
- `Resources` — локализация, ассеты и legal documents.

## CADNext

`../CADNext` — внешний архитектурный каркас будущей CAD-системы:

- `core` — C++ domain core;
- `kernel` — будущий OCCT geometry kernel adapter;
- `viewer` — будущий Coin3D viewport слой;
- `gui` — будущий Qt Widgets / QtGui shell;
- `python` — будущие wrappers, macros и workbenches;
- `bridge` — нейтральный export layer для UAVsim;
- `tests` — первые unit-level контракты.

Симулятор не должен напрямую зависеть от OCCT, Coin3D или Qt. Связь с CADNext должна идти через bridge/export package: visual mesh, collision mesh, mass properties, center of mass, attachment points, material tags, payload mount points и UAV role tags.
