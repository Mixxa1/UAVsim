![Swift](https://img.shields.io/badge/swift-F54A2A?style=for-the-badge&logo=swift&logoColor=white)
![C++](https://img.shields.io/badge/c++-%2300599C.svg?style=for-the-badge&logo=c%2B%2B&logoColor=white)
![CMake](https://img.shields.io/badge/CMake-%23064F8C.svg?style=for-the-badge&logo=cmake&logoColor=white)
![Qt](https://img.shields.io/badge/Qt-41CD52?style=for-the-badge&logo=qt&logoColor=white)
![macOS](https://img.shields.io/badge/mac%20os-000000?style=for-the-badge&logo=macos&logoColor=F0F0F0)
![Xcode](https://img.shields.io/badge/Xcode-007ACC?style=for-the-badge&logo=Xcode&logoColor=white)

# DroneUAVDemo / UAVsim

**UAVsim (Второе название DroneUAVDemo) ** — это macOS-программа для симуляции БЛА, состоящая из двух частей одного продукта: симулятора **DroneUAVDemo** (SwiftUI/SceneKit) и CAD-модуля **CADNext** (C++/OCCT/Qt/Coin3D), в котором проектируются детали полезной нагрузки и точки их крепления к БЛА. CADNext запускается изнутри DroneUAVDemo через меню *CAD*; геометрия и параметры массы передаются обратно в симулятор через нейтральный файловый мост.

DroneUAVDemo сам по себе покрывает физику полёта мультикоптеров и самолётных аппаратов, планирование миссий и автопилот, LAN-мультиплеер, replay миссий с экспортом видео, симуляцию полезной нагрузки и двуязычный (RU/EN) интерфейс.

## Структура репозитория

- `DroneUAVDemo/` — активная часть macOS-программы (Xcode-проект, Swift/SwiftUI/SceneKit).
- `CADNext/` — CAD-модуль UAVsim на C++/OCCT/Qt/Coin3D; собирается отдельным CMake-проектом и запускается изнутри DroneUAVDemo как отдельный процесс (меню *CAD → Open CADNext*).
- `README.md` — этот файл.

---

## DroneUAVDemo — Симулятор

### Аэродинамика и физика полёта

- **Мультикоптер**: 6-DOF динамика с режимами angle (стабилизация), acro (по угловой скорости) и hover-assist (`DronePhysicsEngine.swift`, `DroneFlightMode.swift`).
- **Самолётные БЛА **: модель аэродинамических коэффициентов на таблицах breakpoint по углу атаки/скольжения/отклонению рулей, поведение на сваливании, тензоры инерции по крену/тангажу/рысканию, катапультный старт с настраиваемым углом и курсом направляющей (`FixedWingAerodynamics.swift`, `AirframeArchitecture.swift`).
- **Батарея и термика**: расход батареи в зависимости от throttle, воздушной скорости и агрессивности маневров; тепловая нагрузка по компонентам (моторы, ESC, батарея, гимбал, полётный контроллер, лучи рамы, винты) (`BatteryThermalSimulationService.swift`).
- **Модель повреждений**: накопленные повреждения снижают показатель батареи, увеличивают тепловую нагрузку и ухудшают лётные характеристики (`DamageThermalModel.swift`).
- **Влияние погоды на полёт**: 7 пресетов — Normal, Wind, Rain, Snow, Fog, Smog, Thunderstorm (Обычная (ясная), ветер, дождь, снег, туман, смог, гроза) — каждый со своими множителями видимости, турбулентности, сопротивления, расхода батареи, шума датчиков и риска столкновения (`WeatherModel.swift`).
- **Каталог БЛА**: около 30 референсных платформ, основанные на открытой информации, а также кастомные/абстрактные профили, с фильтрацией по типу (мультикоптер / самолётный / VTOL / вертолёт) и весовому классу (nano/micro/light/medium/heavy) (`UAVReferenceCatalog.swift`, `UAVCatalog.swift`, `UAVFilterState.swift`).

### Автопилот и планирование миссий

- **Автопилот мультикоптера**: удержание позиции с ограничением скорости рысканья, удержание высоты, дедбэнд по радиусу удержания, санитизация NaN во входных данных (`MulticopterAutopilotController.swift`).
- **Автопилот самолётного БЛА**: guidance по принципу «carrot pursuit» вдоль полилинии маршрута, удержание курса с минимизацией бокового отклонения, явный конечный автомат фаз (idle → набор высоты после старта → полёт по участку → подход к точке маршрута → завершение миссии / ошибка), плюс отдельный автомат фаз катапультного старта (`FixedWingAutopilotController.swift`).
- **Валидация миссии**: минимальное расстояние между точками маршрута, пересечение с бесполётными зонами, потолок высоты и просвет по рельефу, проверка режима старта (`MissionPlanValidator.swift`, `MissionConstraints.swift`).
- **Построение маршрута**: навигационная сетка на основе A*, проверка прямой видимости пути, перепланирование при изменении рельефа/цели (`AutoPathPlannerService.swift`); список открытых узлов реализован через бинарную min-heap для больших сеток.
- **Облёт препятствий**: посимвольный (per-tick) облёт препятствий в реальном времени для самолётных аппаратов (боковой отворот, набор высоты «через препятствие», ожидание с предупреждением), оценка риска столкновения с действиями — снизить скорость, зависание, уклонение, аварийная остановка (`CollisionAnalysisService.swift`, `CollisionAnalysis.swift`).
- **Жизненный цикл миссии**: черновики, валидация, таймлайн, разрешение целевой точки guidance, мониторинг выполнения, маппинг событий (`MissionDraft.swift`, `MissionRuntimeMonitor.swift`, `MissionGuidanceTargetResolver.swift`, `MissionEventMapper.swift`).

### LAN Online Trials (мультиплеер)

- **Модель authority**: распределённая модель владения объектами по участникам (session host / participant-owned / vehicle-attached / shared-world / spectator-none) с явными состояниями local/remote/host-managed/unowned (`OnlineObjectAuthority.swift`, `OnlineTrialModels.swift`).
- **Настройка сессии**: режим подключения LAN или server, роли пилот/наблюдатель, режимы запуска (одиночная симуляция, LAN host-pilot, LAN client-pilot, LAN spectator), общие параметры сессии — рельеф, погода, масштаб карты (`OnlineTrialRuntimeContext.swift`, `LANSessionModels.swift`, `LANRuntimeRolePolicy.swift`).
- **Репликация**: снапшоты состояния аппаратов с интерполяцией для плавного отображения удалённых БЛА, репликация состояния повреждений, события столкновений с подтверждением владельца, ретрансляцией хоста, дедупликацией и упорядочиванием (`OnlineVehicleStateSnapshot.swift`, `OnlineVehicleSnapshotInterpolator.swift`, `OnlineCollisionArbiter.swift`).
- **Диагностика**: частота снапшотов (Гц), FPS отрисовки, визуальная задержка реплик, число «зависших» реплик, потерянные/переупорядоченные пакеты, RTT по ping/pong (`OnlineRuntimeNetworkDiagnostics.swift`).
- **Интерфейс**: список доступных сессий/лобби и оверлей authority/диагностики прямо во время полёта (`LANOnlineTrialsView.swift`, `OnlineTrialRuntimeOverlay.swift`).

### Replay, дебрифинг и экспорт

- **Запись и воспроизведение**: replay миссии с интерполяцией кадров, переменная скорость (0.25×–8×), play/pause/stop/перемотка (`MissionReplayPlayer.swift`).
- **Replay Center**: библиотека записей, окно полноэкранного просмотра, редактор обрезки таймлайна, сравнение двух записей side-by-side (`ReplayCenterView.swift`, `FullscreenReplayViewerView.swift`, `ReplayTimelineEditorView.swift`, `ReplayTrimmer.swift`).
- **Экспорт видео**: кодирование через AVFoundation/`AVAssetWriter` — режим Fast использует H.264 (профиль High), режим Quality использует HEVC, оба варианта с явной цветовой меткой Rec.709 — с настраиваемыми битрейт-пресетами (Automatic/Low/Medium/High/Custom, 0.5–120 Мбит/с), разрешениями (360p–1440p), частотой кадров (24/30/60/120 fps), опциональным «впечатыванием» телеметрии в кадр и экспортом обрезанного диапазона (`ReplayVideoExportService.swift`, `ReplayVideoExportMode.swift`, `ReplayExportBitratePreset.swift`).
- **Экспорт телеметрии**: сервис экспорта телеметрии миссии для офлайн-анализа (`TelemetryExportService.swift`).
- **Дебрифинг миссии**: итоговый вердикт, метрики выполнения (дистанция/время/высота/скорость), сводка по энергии (батарея на старте/финише/расход, срабатывания unsafe-battery), сводка по полезной нагрузке, журнал предупреждений/критических событий (`MissionDebriefService.swift`, `MissionDebriefView.swift`, `MissionFailureView.swift`).
- **Хранение**: файловый архив записей с настраиваемой политикой хранения (`MissionReplayStorageService.swift`, `MissionReplaySettingsStore.swift`).

### Полезная нагрузка и интеграция с CAD

- **Типы полезной нагрузки**: грузовой контейнер, камера на гимбале, тепловизор, LiDAR, спасательный набор, датчик, радиорелей и кастомный тип (`PayloadType.swift`).
- **Проверка массы**: масса полезной нагрузки проверяется против лимитов конкретного БЛА и общей взлётной массы перед креплением (`PayloadController.swift`, `PayloadCapabilityCheck.swift`, `VehicleMassModel.swift`).
- **Мост импорта CAD-моделей**: нейтральный, `Codable`-дескриптор импорта принимает BRep/STEP/STL/OBJ/glTF или пакет CADNext и переносит в симулятор параметры массы, точки крепления и теги материала/роли БЛА — без зависимости от OCCT/Coin3D/Qt (`Domain/CADBridge/CADModelImportDescriptor.swift`, `CADExternalModelReference.swift`).
- **Установленная CAD-нагрузка**: деталь несёт массу/центр масс/bounding box, штраф за сопротивление, рейтинг прочности, визуальную сетку, коллизионный проксаймити (sphere/box) и сопоставление точки монтажа БЛА с точкой крепления детали, с пользовательскими смещениями позиции/поворота и результатами валидации (`MountedCADPayload.swift`, `Domain/CADBridge/CADMassPropertiesImport.swift`, `Domain/CADBridge/CADAttachmentImport.swift`).
- **Передача в CADNext**: меню *CAD* в приложении запускает собранный отдельно бинарник `cadnext_app` и обменивается с ним данными о полезной нагрузке (`CADNextLauncherService.swift`, `CADPayloadHandoffService.swift`).

### Управление и ввод

- **Источники**: клавиатура (WASD/стрелки/Q-E/space/shift), геймпады класса MFi/Xbox (настраиваемый режим правого стика: рысканье или панорама камеры), автопилот (следование по маршруту миссии), пакеты сетевого/удалённого управления (`InputManager.swift`, `InputSourceKind.swift`).
- **Пакеты удалённого управления**: JSON, разделение по newline, нумерация последовательности, 6-осевые аналоговые команды плюс булевы флаги действий (arm/disarm, переключение FPV/вида сверху/карты/панели нагрузки, сброс груза, возврат домой, пауза/продолжение миссии, режимы precision/boost) (`RemoteControlPacket.swift`, `RemotePacketDecoder.swift`).
- **Сглаживание**: экспоненциальное сглаживание по каждой оси со своим временем отклика на источник, пороги мёртвой зоны, приоритет «доминирующего» источника ввода для предотвращения дрожания при переключении устройств.

### Мир, окружение и погода

- **Локации**: Grid (базовая), Field, Forest, Cargo Yard и Abandoned City. (Сетка (тестовая локация), поле, лес, порт с контейнерами, заброшенный город)
- **Процедурное размещение**: посеянное (`SplitMix64`) распределение Пуассона для деревьев/объектов, сезонные варианты деревьев (`EnvironmentProceduralVisualFactory.swift`, `EnvironmentProceduralMaterials.swift`, `SeasonalTreeAssetLoader.swift`).
- **Городской слой**: дороги, тротуары и заброшенные здания в стиле brownstone с раскладкой улиц/зданий, учитывающей маршрут, и коллизионными проксями зданий из JSON (стены/полы/двери/окна с порогами скорости при ударе) (`AbandonedCitySceneComposer.swift`, `AbandonedCityLayout.swift`, `AbandonedCityBuildingLoader.swift`, `Resources/Physics/AbandonedCity/abandoned_building_colliders.json`).
- **Погодные эффекты**: слой облаков в небе, окружающая дрон оболочка тумана/смога, случайные удары молнии во время грозы и проход глубины SceneKit `SCNTechnique` для depth-of-field (`WeatherCloudAssetLoader.swift`, `WeatherDepthOfFieldTechnique.swift` + `WeatherDepthOfField.metal`).
- **Визуализация сброса груза**: падающий груз с физикой твёрдого тела и отдельная камера, следующая за грузом при сбросе (`PayloadVisualFactory.swift`, `PayloadDropCameraController.swift`).

### Модули интерфейса

Боковые/модульные панели над SceneKit-вьюпортом (`Presentation/Views`, `Presentation/ViewModels`):

- Тактическая карта (точки маршрута, зоны сброса, бесполётные зоны, объекты старта) и упрощённая «легаси»-карта миссии.
- Экраны статуса миссии, таймлайна, дебрифинга и провала миссии.
- Replay Center, окно полноэкранного просмотра, редактор таймлайна/обрезки записи.
- Панель настройки полезной нагрузки и кнопка на тулбаре.
- Модуль камеры: режимы Free, Chase, Orbit, FPV, Top и Payload Drop; компас-оверлей, компактный и развёрнутый HUD телеметрии.
- Модуль сценария: выбор погоды и типа местности.
- Модуль диагностики: оверлей термики, визуализация повреждений, координация группы аппаратов, шина предупреждений, стойка телеметрии.
- Каталог БЛА с фильтрацией по типу и весовому классу.
- Панель управления полётом (взлёт/посадка/зависание/авто-маршрут/возврат домой/аварийная остановка).
- Оверлеи хаба/курсора геймпада.
- Браузер LAN Online Trials и оверлей в рантайме.
- Настройки: переназначение клавиш, экран принятия юридических документов, окно благодарностей (credits).

### Локализация и юридические документы

- Полная локализация на английский и русский, ~2300 ключей на каждый язык: команды полёта, режимы камеры, термины погоды/БЛА/нагрузки/миссий, диагностика, интерфейс тактической карты (`Resources/en.lproj`, `Resources/ru.lproj`).
- Версионированные двуязычные EULA/ToS с экраном принятия при запуске (`LegalAgreementService.swift`, `LegalGateRootView.swift`, `Resources/Legal/LegalDocuments.json`).
- Благодарности за сторонние ассеты с указанием источников, доступны из меню Help (`CreditsView.swift`, `Resources/Credits/ThirdPartyAssets.json`).

---

## CADNext — CAD-подсистема

CADNext — это CAD-модуль продукта UAVsim для проектирования деталей полезной нагрузки БЛА и их экспорта в симулятор; запускается изнутри DroneUAVDemo через меню *CAD → Open CADNext*, то есть для пользователя это часть одной программы. Технически DroneUAVDemo находит уже собранный бинарник `cadnext_app` (Qt/Coin3D/OCCT) и запускает его как отдельный процесс — код CADNext не линкуется в Swift-таргет, поэтому симулятор не тянет за собой прямую зависимость от OCCT/Coin3D/Qt.

### Как это устроено внутри

- **Документ**: `Document` хранит объекты (`objects`), эскизы (`sketches`), рабочие плоскости (`workPlanes`) и историю фич (`features`) — эскизы и рабочие плоскости не вложены в объекты, а живут отдельно (`core/include/cadnext/Document.hpp`).
- **Геометрическое ядро (kernel)**: абстрактный интерфейс `Kernel` с двумя backend'ами — точный BRep через Open CASCADE (`CADNEXT_WITH_OCCT=ON`) или процедурный `StubKernel`, который используется по умолчанию и собирается без внешних зависимостей (`kernel/include/cadnext/kernel/`).
- **Пайплайн вычисления геометрии**:
  ```text
  PrimitiveParameters → GeometryEvaluator → Kernel/OcctKernel
    → ShapeHandle (внутренний TopoDS_Shape) → MeshExtractor → TriangleMesh
    → Coin3D-вьюпорт
  ```
  OCCT-типы никогда не покидают реализацию ядра и никогда не сериализуются; сетка для Coin3D — это только отображение, а не источник истины о геометрии.
- **История фич**: `FeatureType` перечисляет `Sketch`, `Extrude`, `ExtrudeCut`, `Chamfer`, `Fillet`, `Cut`, а также зарезервированные `BooleanFuse`/`BooleanCut`/`BooleanCommon` — последние существуют в модели данных ядра, но пока не имеют диалогов/команд в GUI (`core/include/cadnext/Feature.hpp`).
- **Файл `.cadnext`**: JSON, версия формата 1; сохраняются только параметрические данные построения (дескрипторы примитивов/эскизов/фич и трансформы) — вычисленная геометрия (OCCT shape, mesh) никогда не сериализуется и пересчитывается заново при каждой загрузке (`core/include/cadnext/DocumentSerializer.hpp`). Undo/redo — линейный `CommandStack`.
- **Условно-стабильные идентификаторы**: ребро — `edge-<index>-s<startHash>-e<endHash>-l<lengthHash>`, грань — `face-<index>-<normalHash>-<centerHash>-<areaHash>` (хэши квантованной геометрии). Они стабильны для текущего состояния тела, но это не полноценный topological naming — при сильном изменении топологии привязка ребра/грани к более ранней фиче может не разрешиться, и такая фича просто пропускается при воспроизведении истории, а не ломает документ.

### Типичный рабочий процесс в редакторе

1. **Создание тела** — либо примитив (Box/Cylinder/Sphere) через тулбар, либо эскиз на одной из канонических плоскостей (XY/XZ/YZ).
2. **Эскиз (режим Sketch2D)** — при входе в эскиз камера становится строго нормальной к плоскости (ортографическая проекция, орбита отключена), показывается сетка с привязкой (snap-to-grid) и курсор-перекрестие. Инструменты Line / Rectangle / Circle рисуют сущности в локальных координатах u/v этой плоскости с живым предпросмотром; Esc отменяет текущую операцию в два этапа (сначала операцию, затем инструмент).
3. **Распознавание профиля** — детектор профилей находит прямоугольники, окружности и произвольные замкнутые контуры из цепочек отрезков (самопересекающиеся и незамкнутые контуры считаются невалидными); клик внутри контура выбирает профиль для дальнейшей операции.
4. **Extrude / Extrude Cut** — выдавливание профиля в новое тело (направление Positive/Negative/Symmetric) или вырез в существующем теле (режимы Distance / Through All / To Object). При включённом OCCT это точный BRep-пайплайн (`TopoDS_Wire` → `TopoDS_Face` → `BRepPrimAPI_MakePrism` / `BRepAlgoAPI_Cut`); без OCCT — процедурная сетка-призма (с ear-clip крышками), которая держит GUI рабочим, но не выполняет настоящего булева вычитания.
5. **Работа с ребрами и гранями готового тела** — выбор ребра подсвечивает его отдельно от тела и открывает Chamfer (`BRepFilletAPI_MakeChamfer`, равноудалённый) или Fillet (`BRepFilletAPI_MakeFillet`, постоянный радиус); выбор плоской грани позволяет создать рабочую плоскость или новый эскиз прямо на этой грани («Create Work Plane from Face», «Create Sketch on Face», «Normal to Face») и продолжить Extrude/Cut уже от него — например, чтобы вырезать что-то с боковой стороны детали. Оба workflow требуют OCCT-сборки.
6. **Точки крепления (Attachment Points)** — отдельный инструмент на тулбаре расставляет на детали точки крепления с ролью (frame/wing/payload/camera/sensor/landingGear/motor/battery/antenna/generic), локальной позицией и поворотом; редактируются через `AttachmentPointDialog`.
7. **Сохранение детали** — кнопка «Save Part» считает массу, центр масс и bounding box (через `BRepGProp` при OCCT-сборке) и записывает деталь в бинарный файл `.uavpart` (см. ниже), включая материал, точки крепления и коллизионный проксаймити.
8. **Mount Editor** — отдельный диалог, в котором деталь из `.uavpart` сопоставляется с конкретной моделью БЛА из каталога: точки крепления детали связываются с точками монтажа БЛА, в 3D-предпросмотре деталь показывается полупрозрачным «призраком» на корпусе БЛА, доступны элементы управления смещением и поворотом, а валидатор сверяет совместимость по типу БЛА и роли точки монтажа. Результат (с финальной трансляцией/поворотом и временной меткой) передаётся в DroneUAVDemo.
9. **Экспорт в симулятор** — `UAVSimBridge` собирает из документа нейтральный пакет экспорта (ссылки на визуальную/коллизионную сетку, параметры массы, список точек крепления, теги материала), не привязанный к конкретному формату файла; именно эти данные (через `.uavpart` или напрямую) принимает на стороне симулятора `Domain/CADBridge`.

### Графический интерфейс

Qt6 Widgets desktop-приложение: дерево проекта (Bodies/Sketches) слева, панель свойств справа, Coin3D-вьюпорт в центре. Два режима навигации — Free3D (изометрия, орбита, выбор тел/граней/рёбер/точек крепления, контекстное меню по правому клику) и Sketch2D (см. рабочий процесс выше, плюс жесты трекпада: два пальца — панорама, pinch — зум по курсору). Диалоги: Extrude, Cut Extrude, единый диалог Chamfer/Fillet, Attachment Point, UAV Mount Editor, выбор БЛА. Coin3D-сцена рисует рабочие плоскости «контуром вперёд», чтобы они подсвечивали, но никогда не перекрывали тела (`gui/`, `viewer/`).

### Формат `.uavpart`

Бинарный контейнер: заголовок (64 байта, magic `UAVPART\0`, версия формата, версия писателя, таблица секций) + секции + CRC32 по всему файлу. Секции:

- **Manifest** (обязательна) — id, имена, версия формата, источник `"CADNext"`, единицы измерения, тип детали, временные метки, флаг `simulationReady` и коды незавершённости (`no_attachment_points`, `mass_not_computed`, `invalid_bounds`, `no_simulation_proxy`).
- **Material** (обязательна) — id материала, плотность, цвет предпросмотра.
- **MassProperties** (обязательна) — объём, масса, центр масс, bounding box, габариты, штраф сопротивления, рейтинг прочности, метод расчёта.
- **AttachmentPoints** — массив точек крепления (id, имя, роль, локальные позиция/поворот, системная/включена).
- **SimulationProxy** — коллизионный проксаймити для симулятора (пока только box, источник — границы массы).
- **Compatibility** — допустимые типы БЛА, предпочтительные роли монтажа, рекомендованная максимальная скорость, предупреждения.
- **VisualMesh** / **ExactGeometry** (зарезервированы, с версии 1.3) — вершины/индексы сетки и BRep-геометрия (`geometryKernel = "opencascade"`) для будущего использования.

Запись идёт через `UAVPartWriter`: валидация (есть блокирующие ошибки и отдельно — предупреждения) → запись во временный файл → проверочное перечитывание → атомарное переименование в целевой файл. Чтение (`UAVPartReader`) поддерживает ленивую загрузку секций (`bridge/include/cadnext/bridge/UAVPartFormat.hpp`, `UAVPartReader.hpp`, `UAVPartWriter.hpp`, `UAVPartValidator.hpp`).

### Статус разработки

Текущая стадия — **CADNext 0.9 (выбор рёбер + Chamfer/Fillet v1)**. Покрытие тестами: 59 файлов тестов на эскизы, extrude/cut, chamfer/fillet, сериализацию, fallback-ядро, извлечение сетки, ссылки на грани/рёбра, точки крепления, формат UAVPart и валидацию монтажа (`tests/`). Локализация интерфейса — файлы перевода Qt для русского и английского (`translations/cadnext_ru.ts`, `cadnext_en.ts`).

---

## Сборка

### DroneUAVDemo

Активное macOS-приложение — Xcode-проект `DroneUAVDemo` (Swift 5, минимальная версия macOS 14.6). Открыть `DroneUAVDemo.xcodeproj` и запустить схему `DroneUAVDemo`.

### CADNext

CADNext — отдельный CMake-проект на C++20, не участвующий в сборке Swift-приложения.

Без GUI и внешних зависимостей (только core/kernel/bridge + тесты):

```bash
cmake -S CADNext -B CADNext/build
cmake --build CADNext/build
ctest --test-dir CADNext/build
```

С графическим интерфейсом (нужны Qt6, Coin3D и SoQt, например `brew install coin3d`):

```bash
cmake -S CADNext -B CADNext/build-gui \
  -DCADNEXT_BUILD_APP=ON \
  -DCADNEXT_WITH_QT=ON \
  -DCADNEXT_WITH_COIN3D=ON
cmake --build CADNext/build-gui
```

С точной геометрией через Open CASCADE (например, `brew install opencascade`):

```bash
cmake -S CADNext -B CADNext/build-gui-occt \
  -DCADNEXT_BUILD_APP=ON \
  -DCADNEXT_WITH_QT=ON \
  -DCADNEXT_WITH_COIN3D=ON \
  -DCADNEXT_WITH_OCCT=ON
cmake --build CADNext/build-gui-occt
```

Флаги сборки: `CADNEXT_WITH_OCCT` — точное BRep-ядро вместо процедурного stub; `CADNEXT_WITH_COIN3D` / `CADNEXT_WITH_QT` — 3D-вьюпорт / Qt6-интерфейс (Qt требует Coin3D); `CADNEXT_BUILD_APP` — собрать исполняемый `cadnext_app` (требует оба флага выше); `CADNEXT_WITH_PYTHON` — Python-обвязка (заглушка); `CADNEXT_BUILD_TESTS` — юнит-тесты (включены по умолчанию).

Пункт меню *CAD → Open CADNext* — точка входа в CAD-модуль UAVsim прямо из DroneUAVDemo: приложение ищет уже собранный бинарник по пути `CADNext/build-gui-occt/app/cadnext_app` (предпочтительно, с OCCT) или `CADNext/build-gui/app/cadnext_app` (процедурный fallback, без булева вычитания) и запускает его как отдельный процесс — код CADNext при этом никогда не линкуется в Swift-таргет.
