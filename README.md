![Swift](https://img.shields.io/badge/swift-F54A2A?style=for-the-badge&logo=swift&logoColor=white)
![C++](https://img.shields.io/badge/c++-%2300599C.svg?style=for-the-badge&logo=c%2B%2B&logoColor=white)
![CMake](https://img.shields.io/badge/CMake-%23064F8C.svg?style=for-the-badge&logo=cmake&logoColor=white)
![Qt](https://img.shields.io/badge/Qt-41CD52?style=for-the-badge&logo=qt&logoColor=white)
![macOS](https://img.shields.io/badge/mac%20os-000000?style=for-the-badge&logo=macos&logoColor=F0F0F0)
![Xcode](https://img.shields.io/badge/Xcode-007ACC?style=for-the-badge&logo=Xcode&logoColor=white)

# DroneUAVDemo / UAVsim

**UAVsim (второе название — DroneUAVDemo)** — macOS-программа для симуляции БЛА из двух частей одного
продукта: симулятора **DroneUAVDemo** (SwiftUI/SceneKit) и инженерного модуля **CADNext**
(C++/OCCT/Qt/Coin3D), в котором аппарат и его полезная нагрузка проектируются, а затем считаются —
прочность, вибрации, аэродинамика и физические испытания. CADNext запускается изнутри DroneUAVDemo
через меню *CAD*; геометрия, массы и результаты расчётов возвращаются в симулятор через нейтральный
файловый мост.

Симулятор сам по себе покрывает физику полёта мультикоптеров, самолётных аппаратов, VTOL и
вертолётов — от дозвука до сверхзвука, на электричестве и на топливе, — планирование миссий и
автопилот, пять сценарных миссий, реальный рельеф и данные OSM, физическую радиосвязь, звук,
камеры как нагрузку, модель повреждений, LAN-мультиплеер, replay с экспортом видео и двуязычный
(RU/EN) интерфейс.

> **Этот файл — единственный README репозитория.** Все отдельные README и технические заметки
> (`CADNext/README.md`, `CADNext/cfd/README.md`, `CADNext/CFD_QUICKSTART_RU.md`, `Docs/DamageModel.md`,
> `DroneUAVDemo/Domain/RF/README.md`, `DroneUAVDemo/PROJECT_STRUCTURE_RU.md`, README в
> `CADNext/python/*` и `Resources/MapCards`) сведены сюда целиком. Документы в `CADNext/third_party/`
> принадлежат сторонним проектам (SU2, Netgen, Eigen и другие) и не трогались.

## Оглавление

- [I. Что это и как устроено](#i-что-это-и-как-устроено)
- [II. Симулятор DroneUAVDemo](#ii-симулятор-droneuavdemo)
- [III. CADNext — CAD-подсистема](#iii-cadnext--cad-подсистема)
- [IV. Инженерная валидация: CFD, прочность и физические испытания](#iv-инженерная-валидация-cfd-прочность-и-физические-испытания)
- [V. Модель повреждений](#v-модель-повреждений)
- [VI. Python-слой CADNext (задел)](#vi-python-слой-cadnext-задел)
- [VII. Сборка, тесты и пробы](#vii-сборка-тесты-и-пробы)

---

## I. Что это и как устроено

### Две части одного продукта

- `DroneUAVDemo/` — macOS-приложение (Xcode-проект, Swift/SwiftUI/SceneKit). Минимальная версия
  macOS 14.6.
- `CADNext/` — инженерный модуль на C++20 (CMake, OCCT, Qt6, Coin3D, Netgen, SU2). Собирается
  отдельно и запускается как самостоятельный процесс: код CADNext никогда не линкуется в Swift-таргет,
  поэтому симулятор не тянет за собой зависимость от OCCT/Coin3D/Qt.
- `Docs/` — технические документы (их содержимое теперь здесь же).
- `Tools/` — 50 безголовых проб: они гоняют настоящий автопилот, физику, звук и повреждения без
  SceneKit и печатают измеренные числа. Это основной способ проверять лётную модель.

Связь между частями — только через нейтральный пакет экспорта: визуальная и коллизионная сетка,
масса, центр масс, точки крепления, теги материала и роли БЛА.

### Карта каталогов DroneUAVDemo

- `DroneUAVDemoApp.swift` — точка входа macOS-приложения.
- `Presentation/Views` — SwiftUI shell, стартовый экран, рантайм-вьюпорт, интерфейс миссий, replay,
  нагрузки, модульная панель и оверлеи.
- `Presentation/ViewModels` — состояние симуляции, библиотека replay, привязки клавиш, компас,
  экран принятия юридических документов.
- `Domain` — модели БЛА, миссий, нагрузки, replay, карты, авторитет ввода, телеметрия, мир, RF,
  инженерная валидация и нейтральный мост в CAD.
- `Domain/CADBridge` — `Codable`-модели импорта экспортов CADNext в симулятор.
- `Domain/EngineeringValidation` — каталог испытаний, движок валидации, снимок сборки для
  Мастерской и запуск решателей CADNext.
- `Domain/RF` — физическая радиосистема (см. [раздел про RF](#физическая-rf-система)).
- `Domain/World` — единый мир: чанки, реальный рельеф, геопривязка, выбор карты.
- `Simulation` — физика полёта, исполнение миссии, автопилот, безопасность, планирование,
  запись/воспроизведение replay и отчёты.
- `Scene` — SceneKit-сцены симуляции и replay.
- `Input` — клавиатура, геймпад, автопилот, удалённый ввод и привязки.
- `Remote` — транспорт, пакеты и декодер удалённого управления.
- `Services` — хранение и настройки replay, экспорт телеметрии, экспорт видео, юридические документы.
- `Resources` — локализация, ассеты, модели аппаратов, звук и юридические документы.

---

## II. Симулятор DroneUAVDemo

### Аэродинамика и физика полёта

- **Мультикоптер**: 6-DOF динамика с режимами angle (стабилизация), acro (по угловой скорости) и
  hover-assist (`DronePhysicsEngine.swift`, `DroneFlightMode.swift`). Интегрирование ведётся в осях
  тела; лимиты берутся из каталога, а не из зашитых клэмпов, газ висения выводится из тяговооружённости.
- **Самолётные БЛА**: аэродинамические коэффициенты на таблицах breakpoint по углу атаки, скольжению
  и отклонению рулей, поведение на сваливании, тензоры инерции, координация разворота рулём
  направления (`FixedWingAerodynamics.swift`, `AirframeArchitecture.swift`).
- **Моменты относительно ЦТ**: момент тангажа считается коэффициентно — `Cm_cg = Cm_ac + CL·Δx/c̄`,
  без добавления r×F поверх (это было бы двойным учётом).
- **Инерция**: тензоры снимаются с физических габаритов аппарата, а не с масштабированного визуала.
- **Батарея и термика**: расход батареи от газа, воздушной скорости и агрессивности манёвров;
  тепловая нагрузка по компонентам — моторы, ESC, батарея, гимбал, полётный контроллер, лучи рамы,
  винты (`BatteryThermalSimulationService.swift`).
- **Погода**: 7 пресетов — ясно, ветер, дождь, снег, туман, смог, гроза, — каждый со своими
  множителями видимости, турбулентности, сопротивления, расхода батареи, шума датчиков и риска
  столкновения (`WeatherModel.swift`).
- **Каталог БЛА**: более полусотни референсных платформ по открытым данным плюс кастомные профили,
  с фильтрацией по типу (мультикоптер / самолётный / VTOL / вертолёт) и весовому классу
  (nano/micro/light/medium/heavy) (`UAVReferenceCatalog.swift`, `UAVCatalog.swift`).
- **Модели аппаратов**: авторские USDZ-модели вместо процедурных сборок. Визуал кормит граф
  компонентов, поэтому правка модели — это правка лётной модели, а не только картинки.

### Дозвук, трансзвук и сверхзвук

Атмосфера ISA вместо константной плотности; карты сжимаемости по числу Маха; тяга и тепловой режим
на сверхзвуке; конверт по скоростному напору; звуковой удар. Число Маха и скоростной напор — два
независимых входа, их нельзя выводить одно из другого. Измерено пробами `Tools/TopSpeedProbe`,
`Tools/TransonicProbe`, `Tools/SonicBoomProbe`, `Tools/SupersonicReferenceProbe`.

Точность float на больших картах проверена отдельно (`Tools/WorldPrecisionProbe`): крейсер и
сверхзвук корректны до 410 км от начала координат.

### Силовая установка: электричество и топливо

- Дескрипторы силовой установки и топлива как данные: девять топливных аппаратов описаны без правки
  физики.
- ISA-атмосфера и удельный расход (BSFC) меняют массу в полёте.
- Запуск двигателя смоделирован как физика; винт задан картами CT/CP, привязанными к расчётной точке.
- Турбовинтовой винт изменяемого шага и гироскопические моменты ω×(Iω) относительно ЦТ.

### VTOL: переход и движители

Наклоняемые винты (tilt-rotor) и tailsitter: переход между режимами, визуальный риг, индикация
режима в HUD. Боковое перемещение коптерного режима ограничено по скорости (раньше закон был
безграничным P-регулятором — это было корнем повторных ударов о здания).

### Способы старта

Катапульта (четыре установки по массе аппарата, реальный ложемент и рельс), пневматический
контейнер, ручной запуск, разбег по полосе с весом на колёсах. Положение аппарата на установке
замеряется по геометрии, а не берётся константой. Коридор взлёта с площадки проверяется отдельно.

### Автопилот и планирование миссий

- **Мультикоптер**: удержание позиции с ограничением скорости рысканья, удержание высоты, дедбэнд
  по радиусу удержания, санитизация NaN (`MulticopterAutopilotController.swift`).
- **Самолётный БЛА**: guidance «carrot pursuit» вдоль полилинии, удержание курса, явный конечный
  автомат фаз (idle → набор высоты → участок → подход к точке → завершение/ошибка) плюс отдельный
  автомат фаз катапультного старта (`FixedWingAutopilotController.swift`).
- **Валидация миссии**: минимальное расстояние между точками, потолок, просвет по рельефу, проверка
  режима старта (`MissionPlanValidator.swift`, `MissionConstraints.swift`).
- **Построение маршрута**: A* по навигационной сетке, проверка прямой видимости, перепланирование
  при изменении рельефа или цели (`AutoPathPlannerService.swift`).
- **Облёт препятствий**: потиковое уклонение для самолётных аппаратов (боковой отворот, перелёт,
  удержание с предупреждением), оценка риска столкновения с действиями — снизить скорость, зависнуть,
  уклониться, аварийно остановиться (`CollisionAnalysisService.swift`). Здания представлены
  призмами по реальному следу, а не осевыми боксами.
- **Жизненный цикл миссии**: черновики, валидация, таймлайн, разрешение целевой точки, мониторинг
  выполнения, маппинг событий.

Важное правило всей этой части: любой ассист гасится на земле и при явной встречной команде пилота —
защита не должна бороться со стиком.

### Сценарные миссии

Пять готовых сценариев (`MissionScenarioKind`):

| Сценарий | Что делает |
| --- | --- |
| Поиск и спасение | цели на местности, день и ночь, оптический и тепловой канал |
| Тушение пожара | рантайм распространения огня, брандспойт с реакцией на массу рукава, сброс капсул, камера бомбардира |
| Агро-полив | поле пшеницы, сетка покрытия, доза по площади, логистика воды |
| Гонки дронов | ворота отрезком, конструктор трасс прямо в сцене, генератор трасс, класс FPV |
| Перехват с закреплённой нагрузкой | цель, наведение, подмена камеры на FPV/нагрузку |

### Мир, окружение и погода

- **Пресеты местности**: сетка (тестовая), поле, лес, порт с контейнерами, заброшенный город
  (`TerrainPreset`).
- **Реальный мир**: WGS84/ENU-геопривязка, импортёр OSM, высоты рельефа и вода, дороги, мосты и
  растительность по открытым данным; единый контракт `FlyableWorld` покрывает и фотограмметрию, и
  открытые данные.
- **Чанки**: мир стримится кусками; навигация и контакт разведены по разным реестрам.
- **Процедурное размещение**: посеянное (`SplitMix64`) распределение Пуассона для деревьев и
  объектов, сезонные варианты деревьев.
- **Городской слой**: дороги, тротуары и здания с раскладкой, учитывающей маршрут, и коллизионными
  проксями из JSON (стены, полы, двери, окна с порогами скорости при ударе).
- **Погодные эффекты**: слой облаков, оболочка тумана и смога вокруг аппарата, молнии в грозу,
  проход глубины `SCNTechnique` для depth-of-field.
- **Часы мира**: сутки за 24 минуты, ускорение 1×–64×. Лётные таймеры сняты со стенных часов, а не
  с игровых.
- **LiDAR**: накопительное геопривязанное облако точек с экспортом PLY и CSV.

### Камеры как полезная нагрузка

Каналы EO и ИК, проход сенсора и ISP, автоэкспозиция, цвет. Тепловизор работает по среде, а не по
подмене материалов. Общий слой кадра имеет явного владельца (иначе кадры мигают), попиксельная
обработка идёт через Accelerate. Гибридные подвесы (H20T, H30T) моделируются как несколько каналов
одного устройства.

### Звук

Движок пространственного звука, звуковой пакет, звук своего аппарата, материалы ударов, звук
повреждений. Ведомые аппараты и участники LAN звучат и слышны с доплером; у собственного аппарата
доплера нет по построению (слушатель летит вместе с источником).

### Полезная нагрузка и интеграция с CAD

- **Типы**: грузовой контейнер, камера на гимбале, тепловизор, LiDAR, спасательный набор, датчик,
  радиорелей, брандспойт, пусковая капсул, агрораспылитель и кастомный тип (`PayloadType.swift`).
- **Проверка массы**: масса нагрузки сверяется с лимитами конкретного БЛА и общей взлётной массой
  до крепления.
- **Мост импорта CAD**: нейтральный `Codable`-дескриптор принимает BRep/STEP/STL/OBJ/glTF или пакет
  CADNext и переносит массу, точки крепления и теги материала — без зависимости от OCCT.
- **Установленная CAD-нагрузка**: деталь несёт массу, центр масс, габариты, штраф за сопротивление,
  рейтинг прочности, визуальную сетку, коллизионный прокси и сопоставление точки монтажа с точкой
  крепления, с пользовательскими смещениями и результатами валидации.
- **Баллистика сброшенного груза**: снос от скорости носителя намного больше влияния сопротивления.

### Управление и ввод

- **Источники**: клавиатура, геймпады MFi/Xbox, автопилот, пакеты сетевого управления.
- **Раскладка осей геймпада настраивается** — зашитая раскладка не совпадала ни с одной реальной
  аппаратурой. Газ задаётся положением стика, а не приращением; курсор интерфейса не ездит от
  лётного стика.
- **Пакеты удалённого управления**: JSON по строкам, нумерация последовательности, шесть аналоговых
  осей плюс флаги действий (arm/disarm, переключение видов, сброс груза, возврат домой, пауза
  миссии, режимы precision/boost).
- **Сглаживание**: экспоненциальное по каждой оси со своим временем отклика, мёртвые зоны, приоритет
  доминирующего источника.
- **Радиоканал управления**: ELRS-подобные режимы прошивки, бюджет линии, множитель авторитета при
  плохой связи. Задержку команд намеренно не применяем — она ломает управляемость.

### Физическая RF-система

Источник требований: `UAVsim_RF_System_Technical_Specification_RU.pdf`, версия 1.0 от 31 августа 2026 года.

#### Архитектура

Обычная радиосвязь теперь всегда авторитетно рассчитывается физическим RF core:

1. `RFPropagationEngine` вычисляет FSPL, усиление и ориентацию антенн, потери, RSSI, noise floor, SNR, SINR и link margin.
2. `DigitalLinkQualityModel` переводит бюджет в PER, latency, jitter и effective bitrate; `AnalogVideoQualityModel` отдельно моделирует плавный аналоговый шум без цифрового frame freeze.
3. `RFPacketDeliveryEngine` и `RFSharedChannelScheduler` моделируют пакеты, retry, TTL, очереди, MCS, общий bitrate budget, резервы, borrowing и динамический CONTROL boost.
4. CONTROL, VIDEO, TELEMETRY и PAYLOAD DATA имеют независимые конфигурации, состояния и потребителей.

Расстояние является только входом FSPL. Скрытого порога дальности в runtime нет. `nominalLinkRangeM` читается исключительно миграционным конвертером, который один раз создаёт физический compatibility preset для старого профиля. Оптоволоконный канал остаётся отдельной подсистемой.

#### Реализовано

- Versioned `rfSystem` хранится в `.uavbuild`; старые проекты автоматически получают `origin = compatibilityPreset`, а authored-конфигурации запускаются без подмены preset-ом.
- Устройства, антенны, кабели, соединения, фазовые центры, физические transform антенн, поляризация, направленность, повреждение и размещение ground/relay endpoint относительно home/dock участвуют в геометрии и бюджете линии.
- LOS/NLOS и материал препятствия поступают из общего аналитического collision/mesh raycast мира; учитываются diffraction, vegetation, material, macro-clutter, body shadow, atmosphere, weather и воспроизводимый slow fading.
- CONTROL, VIDEO и TELEMETRY оцениваются независимо с частотой runtime 20 Гц. CONTROL authority и failsafe зависят от доставки команд и возраста последнего пакета, а не от радиуса.
- VIDEO имеет два разных пути деградации: analog даёт непрерывный snow/sync noise и не замораживает кадр; digital даёт macroblock artifacts и frame freeze по PER/возрасту доставки.
- Workbench содержит отдельную RF-категорию: frequency, bandwidth, TX power, bitrate/SINR, video mode, gain/polarization, mount XYZ, yaw/pitch/roll, damage, ground placement и QoS. Любая правка переводит конфигурацию в `authored`, попадает в undo и блокирует испытание при preflight error.
- Preflight проверяет schema, уникальность ID, обязательный CONTROL, ссылки и фактические подключения, направление TX/RX, enabled antennas, диапазоны частот и полос, modulation, TX power, sensitivity, физические значения, endpoint placement и переподписанный QoS reserve.
- QoS хранит versioned policy per logical link: priority, minimum reserve, maximum share, traffic overrides, borrowing и dynamic CONTROL boost. Workbench показывает `Σ reserve / channel` до запуска.
- Диагностика показывает полный budget breakdown, packet delivery/age, MCS, queue/TTL/retry/throughput, shared-channel allocation и отдельное состояние VIDEO.
- Replay сохраняет RF snapshot и versioned RF artifacts: calibration baseline, acceptance results, QoS и performance gates; trim/export/report сохраняют совместимость со старыми optional-полями.
- Acceptance-suite включает детерминированные сценарии RF-04/05/06 и scale gates на 10/50/100 активных БПЛА. Результаты отображаются в Diagnostics и mission report.

#### Критерии готовности

| Область | Статус |
|---|---|
| Физический RF без hidden range | Готово |
| Независимые CONTROL / VIDEO / TELEMETRY | Готово |
| Workbench RF editor + preflight | Готово |
| Физические transform антенн и ground station placement | Готово |
| Различная analog / digital деградация | Готово |
| QoS, shared channel, retry, TTL, replay/report | Готово |
| Миграция старых проектов | Готово |
| Scale checks 10 / 50 / 100 | Готово |
| Fiber как отдельный канал | Сохранено |

Команды сборки и тестов из этого документа перенесены в [часть VII](#vii-сборка-тесты-и-пробы).

### LAN Online Trials (мультиплеер)

- **Авторитет**: распределённая модель владения объектами (хост сессии, участник, привязка к
  аппарату, общий мир, наблюдатель) с явными состояниями local/remote/host-managed/unowned.
- **Сессия**: LAN или сервер, роли пилот и наблюдатель, общие параметры — рельеф, погода, масштаб.
- **Репликация**: снапшоты состояния с интерполяцией, репликация повреждений, события столкновений
  с подтверждением владельца, ретрансляцией хоста, дедупликацией и упорядочиванием.
- **Диагностика**: частота снапшотов, FPS, задержка реплик, «зависшие» реплики, потерянные пакеты,
  RTT.

### Replay, дебрифинг и экспорт

- **Запись и воспроизведение** с интерполяцией кадров, скорость 0.25×–8×.
- **Replay Center**: библиотека записей, полноэкранный просмотр, редактор обрезки, сравнение двух
  записей рядом.
- **Экспорт видео**: AVFoundation — Fast использует H.264 High, Quality использует HEVC, оба с
  меткой Rec.709; битрейт 0.5–120 Мбит/с, разрешения 360p–1440p, 24/30/60/120 fps, опциональное
  впечатывание телеметрии, экспорт обрезанного диапазона.
- **Экспорт телеметрии** для офлайн-анализа.
- **Дебрифинг**: вердикт, метрики, сводка по энергии и нагрузке, журнал предупреждений.
- **Паритет среды**: replay воспроизводит ту же погоду, тот же аппарат и ту же локализацию, что были
  в полёте.

### Модули интерфейса

Боковые панели над SceneKit-вьюпортом (`Presentation/Views`, `Presentation/ViewModels`): тактическая
карта, статус и таймлайн миссии, дебрифинг, Replay Center, панель нагрузки, модуль камеры (Free,
Chase, Orbit, FPV, Top, Payload Drop) с компасом и HUD телеметрии, модуль сценария, диагностика
(термика, повреждения, координация группы, шина предупреждений, стойка телеметрии), каталог БЛА,
панель управления полётом, оверлеи геймпада, браузер LAN и оверлей рантайма, настройки.

Новые оверлеи делаются в тёмной панели `GroundControlPalette` — это приборный стиль симулятора, а не
цветные бейджи. Исключение сделано намеренно только для белого OSD-видоискателя режима FPV.

### Analog FPV OSD

FPV-сборки с аналоговой камерой используют живую character-grid OSD, а не набор картинок состояний.
`MCMFontLoader` декодирует все 256 символов MAX7456 из `betaflight.mcm` или `clarity.mcm` в атлас
16×16 глифов; `FPVOSDRenderer` строит сетку 30×16 как `SCNView.overlaySKScene` с nearest-фильтрацией.
Искусственный горизонт повторяет алгоритм Betaflight: девять MCM bar-глифов реагируют на крен и
тангаж, а трёхсимвольный значок аппарата закреплён в центре. RSSI/LQ/SNR приходят из физического
канала CONTROL, проходят через `FPVOSDState` (`live` / `stale` / `unavailable`) и только затем
попадают в HUD. Шум аналогового видеоканала накладывается после SceneKit+SpriteKit, поэтому помеха
одновременно разрушает и картинку камеры, и OSD. FPV-камера включается клавишей `4`, пресет шрифта
выбирается в расширенных настройках камеры.

### Локализация и юридические документы

- Полная локализация на русский и английский, по 3431 ключу в каждом языке (`Resources/ru.lproj`,
  `Resources/en.lproj`): команды полёта, режимы камеры, погода, аппараты, нагрузка, миссии,
  диагностика, тактическая карта.
- Экраны, живущие в своём окне AppKit (благодарности, Replay Center) или в листе поверх симуляции
  (настройки), получают выбранный язык явно через `.environment(\.locale, L10n.currentLanguage().locale)`:
  окружение SwiftUI туда не доходит, и без этого экран открывается на системном языке.
- Код без окружения SwiftUI (окна AppKit, слои сцены и экспорта replay) берёт строки через
  `L10n.s(...)` / `L10n.f(...)`, а не через `NSLocalizedString` — последний всегда резолвит по
  системной локали, а не по выбору в настройках.
- Версионированные двуязычные EULA/ToS с экраном принятия при запуске.
- Благодарности за сторонние ассеты с указанием источников, из меню Help.

### Карточки карт

Скриншоты пресетов, показываемые на карточках в выборе карты (`MapSelectionView`), лежат в
`DroneUAVDemo/Resources/MapCards` и грузятся из бандла по имени файла — замена картинки не требует
правки кода или каталога ассетов.

| Файл | Пресет |
| --- | --- |
| `map-card-gridDemo.*` | тестовая сетка |
| `map-card-field.*` | открытое поле с редкими деревьями |
| `map-card-forest.*` | густой лес |
| `map-card-cargoYard.*` | контейнерный терминал |
| `map-card-city.*` | заброшенный город |

Подходят `.jpg`, `.jpeg` и `.png`. Карточка шириной 240–340 pt обрезается до полосы 150 pt, поэтому
лучше читается горизонтальный кадр примерно 3:2 и шире. Отсутствие файла не ошибка — карточка
показывает цветную заглушку и остаётся рабочей.

---

## III. CADNext — CAD-подсистема

CADNext начинался как редактор деталей полезной нагрузки, а сегодня это инженерный модуль UAVsim:
в нём деталь или аппарат проектируются, а затем считаются — прочность, собственные частоты,
вибрации, удар, климат, пожар, молния, ЭМС, обледенение, флаттер, удар птицы и внешняя
аэродинамика. Запускается из DroneUAVDemo через меню *CAD → Open CADNext*; для пользователя это
часть одной программы, технически — отдельный процесс `cadnext_app`.

### Модули

| Модуль | Что в нём |
| --- | --- |
| `core` | документ, объекты, история фич, материалы, трансформы, точки крепления, единицы |
| `kernel` | абстракция геометрического ядра: точный BRep через OCCT или процедурный `StubKernel` |
| `assembly` | сборки: дерево компонентов, сопряжения, инженерный снимок сборки |
| `fea` | прочность, модальный анализ и все физические испытания (CLI `cadnext_structural`) |
| `em` | собственный FDTD для ЭМС и молнии (без GPL-зависимостей) |
| `cfd` | внешний поток на точной геометрии: Netgen + SU2 (CLI `cadnext_cfd`) |
| `viewer` | сцена Coin3D, выбор, вьюпорт SoQt (`CADNEXT_WITH_COIN3D=ON`) |
| `gui` | оболочка Qt Widgets: главное окно, дерево проекта, панель свойств, окна результатов (`CADNEXT_WITH_QT=ON`) |
| `app` | исполняемый `cadnext_app` (`CADNEXT_BUILD_APP=ON`, требует Qt и Coin3D) |
| `bridge` | нейтральный экспорт в UAVsim и формат `.uavpart` |
| `python` | зона будущих обвязок (см. [часть VI](#vi-python-слой-cadnext-задел)) |
| `tests` | 120 файлов тестов |

### Как это устроено внутри

- **Документ**: `Document` хранит объекты, эскизы, рабочие плоскости и историю фич — эскизы и
  плоскости живут отдельно, а не внутри объектов.
- **Пайплайн геометрии**:

  ```text
  PrimitiveParameters → GeometryEvaluator → Kernel/OcctKernel
    → ShapeHandle (внутренний TopoDS_Shape) → MeshExtractor → TriangleMesh
    → Coin3D-вьюпорт
  ```

  Типы OCCT никогда не покидают реализацию ядра и никогда не сериализуются; сетка для Coin3D — это
  только отображение, а не источник истины о геометрии.
- **Файл `.cadnext`**: JSON, версия формата 1; сохраняются только параметрические данные построения.
  Вычисленная геометрия пересчитывается при каждой загрузке. Undo/redo — линейный `CommandStack`.
- **Условно-стабильные идентификаторы**: ребро — `edge-<index>-s<startHash>-e<endHash>-l<lengthHash>`,
  грань — `face-<index>-<normalHash>-<centerHash>-<areaHash>`. Они стабильны для текущего состояния
  тела, но это не полноценный topological naming: при сильном изменении топологии привязка может не
  разрешиться, и такая фича пропускается при воспроизведении истории, а не ломает документ.

### Рабочий процесс в редакторе

1. **Создание тела** — примитив (Box/Cylinder/Sphere) или эскиз на канонической плоскости (XY/XZ/YZ).
2. **Эскиз (Sketch2D)** — камера строго нормальна к плоскости (ортографическая проекция, орбита
   отключена), сетка с привязкой и курсор-перекрестие. Line / Rectangle / Circle рисуют в локальных
   координатах u/v с живым предпросмотром; Esc отменяет в два этапа — сначала операцию, потом инструмент.
3. **Распознавание профиля** — прямоугольники, окружности и замкнутые контуры из цепочек отрезков
   (самопересекающиеся и незамкнутые невалидны); клик внутри контура выбирает профиль.
4. **Extrude / Extrude Cut** — выдавливание (Positive/Negative/Symmetric) или вырез (Distance /
   Through All / To Object). С OCCT это точный BRep-пайплайн; без OCCT — процедурная призма, которая
   держит интерфейс рабочим, но не делает настоящего булева вычитания.
5. **Рёбра и грани** — выбор ребра открывает Chamfer (равноудалённый) или Fillet (постоянный радиус);
   выбор плоской грани позволяет создать рабочую плоскость или эскиз прямо на грани и продолжить
   Extrude/Cut от неё. Оба пути требуют OCCT-сборки.
6. **Точки крепления** — роль (frame/wing/payload/camera/sensor/landingGear/motor/battery/antenna/generic),
   локальная позиция и поворот.
7. **Сохранение детали** — масса, центр масс и габариты считаются через `BRepGProp`, деталь пишется
   в `.uavpart`.
8. **Mount Editor** — деталь сопоставляется с конкретной моделью БЛА: точки крепления связываются с
   точками монтажа, деталь показывается полупрозрачным «призраком» на корпусе, валидатор сверяет
   совместимость по типу аппарата и роли точки.
9. **Экспорт в симулятор** — `UAVSimBridge` собирает нейтральный пакет: сетки, массы, точки
   крепления, теги материала.

### Обмен с другими CAD (SOLIDWORKS, КОМПАС-3D, FreeCAD, AutoCAD)

Точная геометрия (BRep), без платных SDK; подробности, проверки и ограничения — в
[`CADNext/CAD_INTERCHANGE_RU.md`](CADNext/CAD_INTERCHANGE_RU.md).

- **STEP со структурой изделия, в обе стороны** (AP214 / AP242): сборка `.cadasm` уходит одним файлом —
  деталь хранится один раз, вхождения со своими положениями; сборка из другой системы приходит набором
  `.cadnext` и `.cadasm`. Проверено против настоящего FreeCAD 1.1.3 (`cadnext_test_freecad_interchange`, 11/11).
- **Parasolid `.x_t` / `.x_b`, в обе стороны** — родной формат ядра SOLIDWORKS, Solid Edge, NX, Onshape;
  AutoCAD и КОМПАС-3D его импортируют. Чтение проверено на открытых файлах SOLIDWORKS 2009/2016 и Onshape;
  запись — обратным чтением (вершины побитно, объёмы до 10⁻⁹) на моделях ядра и деталях NIST.
  Приём записанных файлов самими SOLIDWORKS/КОМПАС/AutoCAD здесь проверить нечем.
- Меню: «Импорт CAD-модели…», «Экспорт CAD-модели…», в окне сборки — «Импорт/Экспорт сборки (STEP, Parasolid)…».

### Формат `.uavpart`

Бинарный контейнер: заголовок (64 байта, magic `UAVPART\0`, версия формата, версия писателя, таблица
секций) + секции + CRC32 по всему файлу.

- **Manifest** (обязательна) — id, имена, версия формата, источник `"CADNext"`, единицы, тип детали,
  временные метки, флаг `simulationReady` и коды незавершённости (`no_attachment_points`,
  `mass_not_computed`, `invalid_bounds`, `no_simulation_proxy`).
- **Material** (обязательна) — id материала, плотность, цвет предпросмотра.
- **MassProperties** (обязательна) — объём, масса, центр масс, габариты, штраф сопротивления,
  рейтинг прочности, метод расчёта.
- **AttachmentPoints** — точки крепления (id, имя, роль, локальные позиция и поворот, системная/включена).
- **SimulationProxy** — коллизионный прокси (пока только box, источник — границы массы).
- **Compatibility** — допустимые типы БЛА, предпочтительные роли монтажа, рекомендованная
  максимальная скорость, предупреждения.
- **VisualMesh** / **ExactGeometry** — вершины и индексы сетки, BRep-геометрия
  (`geometryKernel = "opencascade"`).

Запись идёт через `UAVPartWriter`: валидация → временный файл → проверочное перечитывание →
атомарное переименование. Чтение (`UAVPartReader`) поддерживает ленивую загрузку секций.

### История этапов 0.2–0.9

Ниже — исходный журнал этапов CAD-редактора, как он писался по ходу работы. Это история, а не
описание текущего состояния: сегодняшний CADNext включает всё перечисленное плюс сборки, прочность,
физические испытания и CFD.

Сборочные команды из старого файла перенесены в [часть VII](#vii-сборка-тесты-и-пробы), а два его последних раздела («CADNext generation 1 foundation» и «Не входит в первый каркас») сняты: перечисленное в них как будущее давно сделано.

#### CADNext 0.9 — Edge Selection + Chamfer / Fillet v1

Workflow цели этапа:

```text
Create body / Extrude body
→ select body edge
→ edge highlights independently from the body
→ Chamfer or Fillet
→ preview
→ Apply updates the OCCT body
```

Implemented:

- body edge analysis через OCCT (`EdgeAnalyzer`):
  - `TopExp_Explorer` по `TopAbs_EDGE`;
  - `BRepAdaptor_Curve` classification:
    Line / Circle / Ellipse / BSpline / Other;
  - finite start/end/center/length fields;
  - sampled curve polyline for viewport picking and highlight;
  - `isChamferable` / `isFilletable` for finite non-degenerate edges;
- stable-ish edge id v1:
  `edge-<index>-s<startHash>-e<endHash>-l<lengthHash>`;
- edge picking layered over body/face picking:
  the body hit point resolves to the nearest edge inside a body-scale
  tolerance; if no edge is close enough, the existing face/body fallback
  remains unchanged;
- selected edge highlight is a bright thick line only on the edge;
- Property Panel for selected edge: Body, Edge ID, Kind, Length,
  Chamferable, Filletable, Start, End, Center;
- toolbar/menu/context actions:
  - `Chamfer`;
  - `Fillet`;
  - `Chamfer Edge`;
  - `Fillet Edge`;
- Chamfer v1:
  - equal-distance only;
  - `BRepFilletAPI_MakeChamfer`;
  - one selected edge in the GUI v1, API stores `edgeIds` vector;
- Fillet v1:
  - constant radius only;
  - `BRepFilletAPI_MakeFillet`;
  - one selected edge in the GUI v1, API stores `edgeIds` vector;
- preview uses a transient result mesh and never commits the target body
  before Apply;
- Apply validates parameters, re-resolves edge ids against the current
  `ShapeHandle`, runs OCCT, validates the resulting shape, updates the
  display mesh, clears edge selection and records a Feature;
- save/load stores Chamfer/Fillet feature metadata:
  - Chamfer: `targetBodyId`, `edgeIds`, `mode`, `distance`;
  - Fillet: `targetBodyId`, `edgeIds`, `radius`;
  - features replay after load when OCCT is available.

Not implemented yet (осознанно за рамками 0.9):

- variable radius fillet;
- multi-radius fillet;
- face fillet;
- full edge chain propagation / tangent chain selection;
- setback chamfer;
- draft angle;
- mesh-based chamfer/fillet;
- robust topological naming.

CADNext 0.9 uses stable-ish edge ids for the current evaluated body state.
Full robust topological naming is planned later.

Full robust regeneration of chamfer/fillet after earlier topology changes is TODO.
If edge ids no longer resolve during replay, the feature is skipped and the
document keeps the last successfully rebuilt body state from earlier features.
Raw OCCT shape internals, preview meshes and edge highlight state are never
serialized. Chamfer/Fillet require an OCCT-enabled build; procedural builds
do not fake the operation.

#### CADNext 0.8 — Work Planes on Body Faces / Sketch on Face

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

#### CADNext 0.7 — Stable Custom Profiles and Extrude Cut v1

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

#### CADNext 0.6 — Extrude + Custom Profiles v1

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

#### CADNext 0.5 — Sketch Workspace v1

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

##### CADNext 0.5 UX Fix — WorkPlane Rendering and Sketch2D Navigation

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

##### Sketch Plane Input Fix

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

##### Sketch input UX

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

#### CADNext 0.4 — OCCT-backed primitives / BRep evaluation

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

#### CADNext 0.3 — Interaction & Document Editing Layer

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

#### CADNext 0.2 — Touchable Viewer Prototype

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

---

## IV. Инженерная валидация: CFD, прочность и физические испытания

Это то, ради чего CADNext перестал быть только редактором. Аппарат или деталь проверяются расчётом,
и каждый расчёт — настоящая симуляция с проверкой, а не оценка по формуле из справочника.

### Двенадцать расчётов `cadnext_structural`

Один CLI, один контракт «задание → результат → поле», двенадцать видов анализа. Задание — JSON
`cadnext-structural-job/1`, результат — своя схема на каждый вид, поле — поверхностные значения для
показа. Примеры лежат в `CADNext/fea/schema/`, и обе стороны (C++ и Swift) тестируются против этих
файлов: ключ, переименованный на одной стороне, роняет тест на другой.

| `analysis` | Что считает | Норматив |
| --- | --- | --- |
| `static` | статическая прочность под нагрузками и ускорением | CS-23.303/305, STANAG 4671 |
| `modal` | собственные частоты и отстройка от полос возбуждения | — |
| `harmonic` | вибрация по синусу: вибростенд, сила на грани, дисбаланс винта | — |
| `random` | случайная вибрация по спектру PSD | — |
| `shock` | удар: катапульта, посадка, падение; спектр ударного отклика | — |
| `climate` | жара, солнце, холод, тепловые напряжения | MIL-STD-810H |
| `fire` | огнестойкость: целостность, прочность в горячем виде, работа оборудования | ISO 2685, AC 20-135 |
| `lightning` | прямое воздействие молнии: растекание тока, нагрев дуги, прожог | SAE ARP5412 |
| `emc` | экранирование корпуса от внешнего поля | MIL-STD-461G RS103 |
| `icing` | намерзание льда и мощность обогрева | 14 CFR 25 прил. C |
| `flutter` | флаттер и дивергенция против запаса по скорости | 14 CFR 25.629 |
| `bird` | удар птицы: импульс птицы по выбранной грани | 14 CFR 25.571(e), 25.631 |

Общие правила для всех: три сетки и оценка погрешности дискретизации по GCI (Celik), вердикт
PASS/WARNING/FAIL по нормативным критериям (предел текучести на эксплуатационной нагрузке, предел
прочности на расчётной с коэффициентом 1.5), а не по придуманным порогам. WARNING означает, что
результат нельзя честно назвать PASS: полоса погрешности достаёт до нуля запаса, погрешность не
оценена, решение не сошлось или материал подменён изотропным.

### Восемь физических испытаний

Восемь видов испытаний доведены от ядра до окна результата, каждый проверен против замкнутого
решения или точно выводимого эталона:

1. **Механический удар** — отклик по модам, спектр ударного отклика входа, вердикт по одному событию.
2. **Климат** — стандартные условия MIL-STD-810H с солнцем, собственным тепловыделением и
   тепловыми напряжениями.
3. **Пожар** — пламя ISO 2685 / AC 20-135 на выбранные грани, потеря целостности, прочность при
   температуре; пиролиз проверен против данных MaCFP/NIST (для PMMA расхождение по пику +1.7 %).
4. **Молния** — компоненты тока A/B/C/D по ARP5412, растекание, нагрев дуги, прожог.
5. **ЭМС** — собственный решатель FDTD (сетка Yee, CPML, схема total-field/scattered-field). Уровни
   RS103 20/50/200 В/м, экранирование корпуса, поле в точках расположения оборудования.
6. **Обледенение** — метод панелей (Хесс — Смит), траектории капель и коэффициент захвата,
   баланс Мессингера, мощность противообледенительной системы.
7. **Флаттер** — функция Теодорсена, методы p-k и k (V-g), дивергенция из статического определителя,
   запас 1.15·V_D.
8. **Удар птицы** — трёхфазная нагрузка (скачок Гюгонио, спад, торможение), длительность
   установившейся фазы решается из импульса, так что полный импульс точно равен m·u·sin θ.

Что эти расчёты о себе говорят, важнее того, что они считают. Например, удар птицы сообщает
отношение площади грани к миделю птицы: давление распределяется по всей названной грани, поэтому
грань вдвое больше птицы означает, что местное напряжение занижено более чем вдвое — и вердикт в
этом случае не может остаться PASS. Там, где данных нет (полные наборы пиролиза для наших полимеров,
теплофизика всех сплавов), в отчёте так и написано «нет данных», а не подставлено правдоподобное число.

### Проверка расчётов

Расчёты проверяются не на правдоподобие, а против эталонов: балка Эйлера — Бернулли рядом по модам,
пластина Кирхгофа, замкнутые решения теплопроводности, корреляции пограничного слоя Коулса —
Фернхольца, эксперимент ERCOFTAC T3A для перехода, сфера и пластина для SU2. Две пробы на удар
птицы, например, сверяют пик напряжения с рядом, которому даны ровно те же моды и та же статическая
поправка, что у решателя, — иначе сравнивалась бы усечённость ряда, а не решатель.

---

### Как запустить обдув

1. Откройте документ CADNext с объёмными телами.
2. Выберите **Испытания → CFD — обдув и аэродинамика…** или кнопку **CFD — запустить обдув…** на нижней панели.
3. Укажите состав геометрии и оси аппарата. Расчёт использует снимок точной BRep-геометрии в метрах.
4. В окне CFD проверьте скорость, опорную площадь, размах и хорду. Начальная площадь рассчитана по габаритам — замените её принятой для аппарата площадью крыла.
5. Введите углы через точку с запятой, например `-5; 0; 5`. При нескольких α и β рассчитываются все сочетания.
6. Для расчёта сопротивления оставьте начальный режим **RANS — k–ω SST** либо выберите ламинарную модель. В разделе **Сетка и точность** задаются шаг у поверхности и в дальнем поле, удаление границы, первый слой, число слоёв, рост толщины и предел итераций. Начальные слои не гарантируют достаточное разрешение пограничного слоя. **Эйлер** служит для быстрого просмотра обтекания без вязкого сопротивления.
7. Нажмите **Запустить обдув**. После завершения выберите точку α/β и **Давление на поверхности — Cp** либо **Скорость — цветная карта и линии тока, м/с** справа.

Цветной фон строится по пересечениям объёмных ячеек SU2 с продольной плоскостью через центр модели. Интерполяция выполняется внутри треугольников сечения; экстраполяции в тело, дополнительного размытия и принудительного разворота обратного течения нет. Цвет соответствует полному модулю скорости; линии — проекции скорости на плоскость. Отображается увеличенный участок у тела, а не вся расчётная область. Число узлов в подписи относится ко всему файлу поля.

В режимах скорости и Cp сплошное тело берётся из граничных граней сохранённой сетки. Это стационарный расчёт. Колесо меняет масштаб, перетаскивание сдвигает сечение. **Вписать сечение** восстанавливает масштаб.

**Анимация обдува** включена по умолчанию: частицы движутся по рассчитанным линиям тока с локальной скоростью. Она начинается после первой полной записи поля SU2 и продолжается после расчёта. Во время построения сетки потока ещё нет. Скорость воспроизведения задаётся множителем физического времени (начальное значение 0,05×). Это анимация текущего стационарного поля, а не расчёт изменения течения во времени. Тумблеры отдельно управляют цветным полем, линиями, телом и частицами.

Вкладка **Отчёт и графики** в этом же окне содержит графики CL/CD/Cm/CY/Croll/Cyaw по α или β, таблицу расчётных точек, предупреждения и условия расчёта. HTML-файлы не требуются. В нативном окне прочности доступны использование допуска, напряжения Мизеса, перемещения, масштаб деформации, сетка, критическая точка, нагрузки и материал.

Во время расчёта SU2 периодически записывает промежуточные поля. После стабилизации файлов они обновляются в окне с сохранением масштаба. Под индикатором хода расчёта показаны текущая невязка и предварительные CL/CD. Процент означает долю выполненных итераций, а не степень физической достоверности. Результат без сходимости остаётся предварительным.

**Папка расчёта** содержит `job.json`, `result.json`, BRep и `flow/point-N/`: историю сходимости, журнал SU2, поверхностный CSV, объёмные CSV/VTU. Результат можно снова открыть кнопкой **Загрузить результат…**. В Мастерской UAVsim откройте вкладку **Испытания**, выберите запуск в истории CFD и нажмите **Графики и поля** — отчёт откроется отдельным нативным окном.

Для работы нужны собранные `CADNext/build-netgen/cfd/occt/cadnext_cfd` и `CADNext/third_party/su2/install/bin/SU2_CFD`. Пути можно изменить в окне. На macOS SU2 также требует установленную библиотеку `libomp`.

#### Модели и настройки

Окно крепления детали в CADNext использует USDZ из манифеста библиотеки симулятора. При запуске из UAVsim передаётся каталог моделей приложения; самостоятельный запуск использует библиотеку проекта. Встроенные анимации отключаются, шарниры принимают нейтральную позу, как в симуляторе. USDZ служит для отображения; CFD требует точной геометрии документа.

В главном меню и в полёте открывается общий экран настроек: **Инструкция**, **Клавиши**, **Контроллер**, видео, звук, язык и сведения. В инструкции показаны текущие назначения; раздел клавиш позволяет переназначать их. Конфликтующие назначения меняются местами. Клавиши `[`, `]`, `I`, `K` зарезервированы интерфейсом; `⌥1/⌥2/⌥3` переключают камеры оборудования.

#### Границы результата

Расчёт стационарный, несжимаемый, без обдува винтов. Одна сетка не даёт оценки пространственной погрешности; результат сохраняет предупреждение. Для инженерного вывода нужна проверка сгущением сетки, дальнего поля и применимости модели течения.

### CFD: CADNext → Workbench → UAVsim

Модуль реализует полный цикл первой версии из §8, §16 и приложения B
`UAVsim_Engineering_Validation_Technical_Spec.pdf`: точные тела → внешняя область →
сетка → SU2 → проверка сходимости → история и поля → переносимая аэротаблица → физика.

#### Поддерживаемые расчёты

- Одиночная точка, серии α и β, прямоугольная сетка α × β (до 256 точек).
- Несжимаемое течение: Euler, laminar, RANS SST и нестационарный URANS SST; скорость до 100 м/с.
- Стенка в турбулентных моделях: разрешённый пограничный слой (y⁺ ≈ 1) или пристеночные
  функции SU2 (y⁺ 30…300). Режим выбирается явно, потому что определяет и цену, и то,
  чем является трение — расчётом или оценкой по логарифмическому закону.
- Ламинарно-турбулентный переход: `transition: "lm"` — модель Лэнгтри—Ментера γ-Reθ
  (SU2 `KIND_TRANS_MODEL= LM`, корреляции MENTER_LANGTRY) поверх SST, только с
  разрешённым слоем. Слой начинается ламинарным и переходит там, где модель
  предсказывает по интенсивности турбулентности набегающего потока
  `turbulenceIntensity` (доля, по умолчанию 0.01). Вместе с переходом включаются
  поддерживающие члены SST (`SST_OPTIONS= (V2003m, SUSTAINING)`): модель берёт Tu из
  локального k, а без них k затухает по дороге от входа — при границе в шести
  габаритах заданный 1 % приходит к кромке крыла примерно 0.2 %, и переход считался
  бы по чужому Tu.
- Шесть коэффициентов: CL, CD, Cm, CY, Croll, Cyaw; явные S, b, c и точка момента.
- Возможная зона срыва: при β = 0 положительный максимум CL и последующее падение
  не менее `max(0.001, 0.02 × |CLmax|)`. Границы — рассчитанные углы, без
  интерполяции «точного угла срыва». Если максимум не охвачен, зона не определена.
- Давление и скорость: сплошная карта Cp, цветной продольный срез скорости и линии тока в нативном окне CADNext,
  полное объёмное поле в VTU, исходные CSV и журнал SU2.
- Импорт/экспорт JSON-таблицы, асинхронный запуск, прогресс, отмена, локальная история.

`cadnext_cfd --capabilities` возвращает машиночитаемые ограничения.
Обдув винтов, вращающиеся сетки, серии отклонений рулей, динамические производные,
сжимаемость и нестационарный срыв этой версией не рассчитываются. Рулевые и
демпфирующие слагаемые в полёте продолжают использовать исходный профиль.
Euler не допускается в полётную модель: он не рассчитывает вязкое сопротивление.

#### Сборка

Из корня UAVsim, при установленных OCCT, Netgen и SU2:

```sh
cmake -S CADNext -B CADNext/build-netgen \
  -DCADNEXT_WITH_OCCT=ON -DCADNEXT_WITH_NETGEN=ON \
  -DNetgen_DIR="$PWD/CADNext/third_party/netgen/install/Contents/Resources/CMake"
cmake --build CADNext/build-netgen -j6
CADNext/build-netgen/cfd/occt/cadnext_cfd --capabilities
```

Цель CMake называется `cadnext_cfd_cli`, исполняемый файл — `cadnext_cfd`.
Приложение находит инструменты в локальной сборке, в своих Resources или через
`CADNEXT_CFD_TOOL` / `CADNEXT_SU2_CFD`. Эти пути можно выбрать кнопками в Мастерской.
SU2 и Netgen не встраиваются автоматически в distributable приложения.
Проверено с SU2 8.5.0 и Netgen 6.2.2607 на macOS arm64.

#### Режимы точности в диалоге CADNext

«Быстрая оценка» — шаг по поверхности хорда/30, граница в 6 габаритах, 600 итераций RANS;
«Точный расчёт» — хорда/60, 10 габаритов, 2000 итераций. Оба сохраняют первый слой
под y⁺ ≈ 1. Диалог показывает оценку числа ячеек и времени до запуска по замерам на
4 производительных ядрах (Netgen ≈ 0.03 мс на ячейку, SU2 ≈ 1.3 мкс на ячейку-итерацию).
Крыло 1.2 × 0.4 м: быстрая оценка — 406 тыс. ячеек, сетка 13 с, 0.5 с на итерацию,
около 6 минут на угол на свободной машине.

#### Использование в приложении

1. Мастерская → испытания → **Аэродинамика / CFD**.
2. Для расчёта импортировать `.uavframe v2` с BRep-телами и осями CAD.
3. Проверить S, b, c, точку момента, углы, режим, размеры сетки и высоты слоёв.
   Автоматические значения — начальное приближение, а не оценка точности.
4. Запустить расчёт. Отмена завершает отдельный рабочий процесс и его SU2.
5. В истории открыть графики/поля, журнал, повторить настройки, сравнить коэффициенты двух запусков или экспортировать таблицу.
6. Сохранить `.uavbuild`: настройки, TestRecord и коэффициенты переносятся вместе
   со сборкой. Тяжёлые локальные артефакты для полёта не нужны.

Для библиотечной рамы без точной геометрии доступен импорт готовой таблицы.
Диалог явно связывает импорт с текущей конфигурацией; её происхождение остаётся
`imported`, статус — WARNING. Повреждение геометрии переводит физику к повреждённому
исходному профилю. Панель аэродинамики показывает источник текущего режима.

#### Контракт CLI

```sh
cadnext_cfd /absolute/path/to/new-run/job.json
```

Пример: [`CADNext/cfd/schema/aerodynamics-job.example.json`](CADNext/cfd/schema/aerodynamics-job.example.json).
Скопировать его и `sphere.brep` в новый каталог, указать абсолютный `solverPath`.
Относительные пути разрешаются относительно файла задания. Существующие каталоги
расчёта и файлы результата не переиспользуются. `sphere.uavframe` — тот же точный
тестовый solid для запуска через Workbench.

Этот пример — сфера диаметром 1 м, Re = 20, искусственно повышенная вязкость
0.6125 Па·с. Это воспроизводимый тест, **не параметры воздуха для БПЛА**.
`aerodynamics-result.example.json` получен реальным ламинарным SU2 на этой сфере;
он проверяет межъязыковой контракт, не служит эталонной полётной полярой.

Вход содержит SHA-256 каждого BRep, подписанные CAD forward/up, метры,
условия среды, опорные размеры, численные допуски и параметры сетки.
Внешнее оборудование передаётся явными габаритными телами `proxies`;
приближение их обводов отражается в предупреждении. Внутреннее оборудование
не попадает во внешнюю поверхность.

Выход `cadnext-aerodynamics-result/1` содержит TestRecord-envelope, подтверждение
настроек/геометрии, версию решателя и сеточника, метрики, точки и `aeroTable`.
Swift сравнивает подтверждение с отправленным заданием перед принятием результата.
Частичная серия, NaN/Inf, ошибка запуска или отмена дают ERROR без таблицы для runtime.
Нарушение сходимости или пристеночного разрешения оставляет WARNING с полями и
причинами, но без таблицы. Уже завершённые точки и журнал остаются для диагностики.
stdout: `progress <pointNumber> <domain|mesh|solve|collected> <iteration> <iterationTotal>`;
номер точки начинается с 1. Во время решения поля перезаписываются примерно 20 раз,
чтобы нативное окно могло показывать текущий срез до завершения расчёта.

#### Сетка и достоверность

Пристеночные призмы строятся **до** тетраэдрального заполнения оставшегося объёма.
Добавление слоёв после полного заполнения, использованное в Commit117, создавало
перекрывающиеся объёмы. Регрессионный тест проверяет призмы, связность граней,
баланс объёма и направление роста слоёв.

Недостаточно успешного выхода SU2 или малого residual давления. Требуются файлы полей
и полное окно истории. Уравнения судятся по-разному, потому что измеряют разное:

| Уравнение | Критерий | Почему |
| --- | --- | --- |
| давление, скорости | абсолютная невязка ≤ `residualTarget` | масштаб задан течением |
| k, ω | не служат критерием, только выводятся | RMS в SU2 — сырой баланс потоков ячейки, без деления на объём, поэтому его задают крупнейшие ячейки у дальней границы. Замер на «крыле»: 91 % квадрата невязки ω — двенадцать узлов на рёбрах дальней границы в 3 м от тела, где ω равна значению потока; невязка стояла на 10^1.38 сотни итераций. Абсолютный порог ω к тому же меряет сетку (ω_wall ≈ 6ν/(β₁y²)) |
| силы и моменты | разброс в окне ≤ `absTolerance + relTolerance × |last|`; для URANS — дрейф среднего по окну | сходимость сил, а не невязок, решает вопрос о коэффициентах; через неё же проверяется установление турбулентной модели у тела |

Пристеночное разрешение проверяется **по рассчитанному полю**, а не по настройкам:
из поверхностного файла берётся y⁺ и сравнивается с выбранным режимом.

| Режим | Годен, когда | Причина границ |
| --- | --- | --- |
| разрешённый слой | не более 5 % узлов выше y⁺ = 2 | в вязком подслое u⁺ = y⁺ держится до y⁺ ≈ 2; несколько процентов узлов всегда приходится на кромки и точки торможения |
| пристеночные функции | не более 10 % узлов в буферном слое 5 < y⁺ < 30 и выше y⁺ = 300 | логарифмический закон начинается с y⁺ ≈ 30; узлы ниже y⁺ = 5 SU2 считает вязким напряжением (WALLMODEL_MINYPLUS), это не ошибка |

Пристеночные функции требуют SU2 с патчем `tools/su2-patches/incns-wall-function-omp.patch`.
В штатной сборке 8.5 несжимаемый решатель вызывает пристеночную модель из области
«только мастер-поток», хотя внутри неё есть распараллеленный цикл: на нескольких
потоках libomp падает с assertion на двумерной задаче и зависает на трёхмерной
(замерено: четыре потока, ни одной итерации за сорок минут на 708 тыс. элементов).
Патч повторяет вызов сжимаемого решателя; проверено, что результат на 1 и 4 потоках
совпадает, а тест пластины гоняет этот режим многопоточно как регрессию.
`tools/build_su2.sh` накладывает патч автоматически.

Отдельно измерено: на реальной раме (острые кромки, отрывные углы) пристеночная
модель SU2 не сходится в сотнях узлов («wall coefficients (y+) did not converge»)
и расчёт расходится за две итерации, тогда как на пластине тот же режим работает.
Вывод: для аппаратов пользоваться разрешённым слоем; пристеночные функции — для
гладких обтекаемых форм. Сообщение решателя распознаётся и попадает в причины.

Кроме того проверяется соответствие модели числу Рейнольдса: ламинарная модель выше
Re = 5·10⁵ по хорде отклоняется до запуска, между 10⁵ и 5·10⁵ — предупреждение.
Первый слой и их число для выбранного режима считаются по корреляциям плоской
пластины (cf = 0.026·Re^(−1/7), δ₉₉ = 0.37·L·Re^(−1/5)); это оценка с точностью
до раза, поэтому вердикт выносит измеренный y⁺, а не она.

Точка, не прошедшая эти проверки, **не теряется**: её поля записаны и открываются,
но `aeroTable` не выдаётся, `coefficientsUsable` = false, а причины перечислены
по точкам. Для пользовательского расчёта на одной сетке погрешность дискретизации
и влияние границы всё равно неизвестны: завершённый результат всегда WARNING.
Автоматического GCI и исследования дальнего поля в рабочем CLI пока нет.

#### Окно результата

Три режима, переключаются кнопками над видом:

- **Обтекание 3D** — тело, траектории потока от «грабель» перед телом (цвет — скорость
  по шкале Turbo) и стрелки, бегущие по траекториям с расчётной скоростью, замедленной
  ползунком. Стрелки разнесены по времени, а не по длине: где они сгущаются, воздух
  тормозится. Вращение мышью, колесо — масштаб, кнопки «Изометрия / Сбоку / Сверху /
  Спереди». Поле берётся из объёмной сетки SU2 (`FlowVolume`: ячейки → тетраэдры,
  линейная интерполяция внутри ячейки, поиск через сетку корзин); траектории — правило
  средней точки (`traceTrajectories`). Проверено тестом: линейное поле воспроизводится
  точно, траектории в равномерном потоке прямые и приходят за время L/U, в тело не
  заходят. На сетке крыла (4.4 млн тетраэдров в области) чтение 0.7 с, 300 траекторий 0.1 с.
  Затравки там, где поток что-то делает: решётка вплотную к телу по всей ширине,
  сдвинутая вдоль набегающего потока (при угле атаки линии встречают тело, а не
  проходят над ним), малые решётки у боковых кромок, и кольца линий через ядра
  вихрей за телом (`findVortexCores` — максимумы продольной завихренности ω_x;
  `traceThrough` — трассировка в обе стороны). Вихревые линии нарисованы толще.
  Тест: ядро находится с точностью до ячейки и с верным знаком, ошибка закрутки
  падает со вторым порядком при удвоении сетки (0.20 → 0.054 рад).
- **Давление на теле** — Cp на поверхности по той же шкале.
- **Сечение** — описано ниже; здесь же проигрываются кадры URANS.

Легенда вертикальная, всегда для того, что окрашено в текущем режиме.

##### Сечение

Окно показывает сечение посередине размаха: цвет — скорость относительно набегающего
потока по расходящейся шкале (синий медленнее, серый — V∞, красный быстрее; предел —
99-й перцентиль отклонения, чтобы один всплеск у кромки не обесцветил картину),
линии тока и частицы с затухающими хвостами. Всё строится из одного сечения расчётной
сетки (`FlowSection`), поэтому картина не может противоречить себе.

Частицы (`ParticleTracer`) — интегрирование поля, а не рисунок: засев случайный вдоль
входной кромки области, шаг — правило средней точки с подшагами не длиннее 0.2 %
ширины области, частица гибнет в стенке, за границей или через 2.5 прохода области
и появляется заново. Проверено тестом: в равномерном потоке смещение ровно U·t, при
твёрдом вращении дрейф радиуса 3·10⁻⁶ за оборот, в тело не попадает ни одна точка,
смена поля не сбрасывает частицы.

URANS: решатель сохраняет около ста кадров, и каждый сразу после записи сжимается до
узлов этого сечения (`section_<шаг>.csv`, `SectionFrames.hpp`), а полный кадр удаляется —
иначе на сетке аппарата это сотни мегабайт на кадр. Окно играет кадры по одним
физическим часам с частицами: между кадрами поле интерполируется, частицы идут сквозь
смену кадра. Плоскость записана в `flow/section.json`; допуск разреза сечения зависит
только от сетки, поэтому решатель и окно режут одни и те же узлы (есть тест).

#### Оси, единицы, интерполяция

| Величина | Конвенция |
| --- | --- |
| Мастерская | X влево, Y вверх, Z вперёд; метры |
| Геометрия SU2 | X назад, Y вправо, Z вверх; ортонормальная правая система |
| CL / CD / CY | подъём / по потоку / вправо, ортонормальные скоростные оси |
| Cm | момент вокруг оси вправо, нормировка qSc |
| Croll / Cyaw | вокруг осей назад / вверх, нормировка qSb |
| Моменты | положительные по правилу правой руки, относительно указанной точки |
| Поля SU2 | V/V∞ и p/(ρ∞V∞²); масштабы записаны в `fieldNormalization` |
| Нативное поле | Cp безразмерный, скорость переведена в м/с |

`uavsim-aerodynamics/1`, `frame: flight-body-rhu`: возрастающие массивы α/β,
точки в порядке alpha-major / beta-minor; полная прямоугольная сетка обязательна.
Физика fixed-wing и крылатого режима VTOL использует билинейную интерполяцию, пересчитывает моменты к текущему CG
по `M_CG = M_ref + (ref − CG) × F`. Для таблицы только по α боковые производные
остаются из профиля. Одиночная точка или β-серия без α-поляры — диагностика.
Вне диапазона таблицы и при Mach > 0.3 применяется исходная модель.
Таблица рассчитана при одном Re: его изменение с текущей скоростью не моделируется.

Актуальность определяется отпечатком внешней геометрии, включая CAD-оси и положение
внешних компонентов. Перемещение внутренней массы сохраняет поляру и меняет перенос
момента к CG. Переименование сборки не инвалидирует CFD. Изменение коэффициентов
меняет output fingerprint для зависимых проверок. Новый ERROR не маскируется старым
успешным результатом. FAIL/OUTDATED/повреждённые таблицы не допускаются в runtime.

#### Проверки

```sh
# Контракты, оси, сходимость, запуск/отмена процесса и пристеночная сетка
ctest --test-dir CADNext/build-netgen -L cfd-contract --output-on-failure
# Турбулентная модель на пластине: оба пристеночных режима против Коулса—Фернхольца
ctest --test-dir CADNext/build-netgen -R '^cadnext_test_cfd_turbulent_plate$' --output-on-failure
# Модель перехода на пластине: Блазиус до перехода, начало по корреляции модели, Tu 1 % и 3 %
ctest --test-dir CADNext/build-netgen -R '^cadnext_test_cfd_transition_plate$' --output-on-failure
# Сквозные настоящие Euler, laminar α-sweep и SST β-sweep
ctest --test-dir CADNext/build-netgen -R '^cadnext_test_cfd_cli' --output-on-failure
# Аналитические задачи предыдущего коммита (сфера — тяжёлый тест ~3 млн элементов)
ctest --test-dir CADNext/build-netgen -R '^cadnext_test_cfd_(joukowski_euler|blasius|sphere_euler)$' --output-on-failure
# Существующие проверки инженерной подсистемы и новая связка Swift → SU2 → история
Tools/EngineeringValidationProbe/run.sh
```

Тестовые результаты и отчёты CLI находятся под `build-netgen/tests/cfd-cli*`.
Swift probe проверяет интерполяцию, момент относительно CG, инвалидирование,
переносимость `.uavbuild`, реальные поля/прогресс и отмену до/во время выполнения.

##### Верификация турбулентной модели (пластина, оба режима стенки)

Сравнение трения при одинаковом Re_x с корреляциями White и степенной даёт −7…−12 %,
и это не ошибка решателя: корреляции описывают слой, турбулентный от самой кромки,
а у расчётного слоя своя предыстория (модель перехода в SST отсутствует). Поэтому
сравнение ведётся по собственной толщине потери импульса слоя, где начало координат
не участвует, между двумя принятыми зависимостями (они сами расходятся на ~4 %):

| Режим | y⁺ | Re_θ | cf | положение относительно полосы |
| --- | --- | --- | --- | --- |
| разрешённый слой, 3 сетки | 0.22 → 0.10 | ≈ 4440 | 0.00294 → 0.00298 | −0.42 % → внутри полосы Coles–Fernholz…Kármán–Schoenherr → PASS |
| пристеночные функции, 2 сетки | 54 → 36 | ≈ 4350 | 0.00282 → 0.00281 | на 4.7…5.4 % ниже полосы при допуске 3.65 % → **FAIL** |

⚠️ Исправлено 2026-09-19. Первая версия теста интегрировала θ = ∫u(1 − u)dy с U = 1 до верха
области. Внешний поток там течёт со скоростью 0.998–0.9995 (вытеснение слоя, граница дальнего
поля), и этот дефицит на 0.2 м давал вклад порядка самого θ: Re_θ выходил 5300 вместо 4400, полоса
законов уезжала вниз, и пристеночные функции «проходили» на −2.7 %. Теперь θ считается по локальной
внешней скорости до u = 0.999 U_e, а тест перехода сверяет сам инструмент с Блазиусом (±3 %).
Итог: пристеночные функции SU2 занижают трение на ~5 % против канонического слоя. Около 2.5–3 %
объясняют константы закона стенки SU2 (κ = 0.41, B = 5.0) против κ = 0.384 у Коулса—Фернхольца,
остаток не объяснён. Разрешённый слой не затронут.

Измерено также, что на высоту домена (0.2 L против 1 L при том же первом слое),
интенсивность турбулентности на входе (0.1 % против 5 %) и продольное сгущение
(96 против 192 ячеек) результат не реагирует; всё определяет пристеночный шаг.

##### Проверка модели перехода γ-Reθ (пластина, 2026-09-19)

`cadnext_test_cfd_transition_plate`: SST + LM + поддерживающие члены, две сетки на уровень.

| | Tu = 1 %, Re_L 2.5·10⁶ | Tu = 3 %, Re_L 2.5·10⁵ |
| --- | --- | --- |
| Tu у кромки | 1.002 % ✓ | 3.018 % ✓ |
| Re_θ ламинарного слоя / Блазиус (проверка инструмента) | 1.019 ✓ | 1.003 ✓ |
| cf√Re_x / Блазиус до перехода (допуск 5 %) | 1.002 ✓ | 1.059 ✗ |
| переход на пластине | да ✓ | да ✓ |
| Re_θ в минимуме трения (допуск Re_θc…1.15 Re_θt + сетка) | 731 = 1.25 Re_θt ✗ | 237 = 1.31 Re_θt ✗ |
| турбулентный хвост x = 0.9 в полосе законов (±5 %) | −1.9 % ✓ | −14.6 % (Re_θ ≈ 420, не судится) |

Модель переходит устойчиво (одинаково на двух сетках) на 25–30 % позже по Re_θ, чем минимум трения
по заявленному порогу 1.15 Re_θt; отход трения от Блазиуса при Tu = 1 % начинается около
Re_θ ≈ 540 (0.92 Re_θt), между Re_θc и Re_θt. При Tu = 3 % ламинарный слой несёт +6 % трения ещё до
перехода. Пороги заявлены до прогона и не сдвигались; решение — по итогам обсуждения (сверка с
экспериментом T3A/T3A− или обоснованное определение начала перехода).

##### Валидация перехода против эксперимента: ERCOFTAC T3A и T3A− (2026-09-19)

`cadnext_test_cfd_t3a`. Данные: ERCOFTAC Classic Collection, case 020 (Rolls-Royce ASL, Coupland; SIG
Savill), таблицы t3ay.dat/t3amy.dat — Cf, Re_θ и Tu на каждой станции. Затухание Tu в трубе
воспроизведено (без поддерживающих членов; k и ω на входе подобраны по закону затухания SST под
измеренное Tu(x)) — отклонение ≤ 3 %. Две сетки (48 и 108 тыс. ячеек), сходимость по CD.

| | T3A (Tu 3.0→1.3 %) | T3A− (Tu 0.9→0.5 %) |
| --- | --- | --- |
| минимум Cf (начало перехода) | 277–285 мм против 395 (коридор 295–495) — раньше, ~−28 % по Re_x | 971–990 мм против 1095 (коридор 995–1195) — ~−9 % |
| Cf до перехода | +10…+15 % к опыту | +2…+10 % до 600 мм, затем +20…+32 % |
| Cf после перехода | −3…−6 % | — |

Итог: γ-Reθ SU2 (MENTER_LANGTRY, SST V2003m) в нашей постановке ставит переход раньше опыта и
завышает трение ламинарного/предпереходного слоя; турбулентная часть совпадает. Критерии теста
(коридор станций, ±10 %) не пройдены — тест остаётся красным как запись. Предупреждение результата
исследования при `transition: "lm"` называет эти числа.

##### Цена расчёта (замерено на 4 производительных ядрах)

| Задача | Сетка | Время |
| --- | --- | --- |
| Рама 1.2 м, разрешённый слой (первый слой 16.5 мкм, 27 слоёв, шаг по поверхности хорда/60) | 1.66 млн элементов | сетка 16 мин, решатель ≈ 2.3 с/итерация → ~1 ч на стационарную точку |
| Та же рама, пристеночные функции (первый слой 0.82 мм, 7 слоёв) | 0.71 млн элементов | ≈ 1 с/итерация, но модель стенки на этой геометрии расходится |

URANS с этими же сетками дороже кратно (240 физических × 30 внутренних ≈ 7200 итераций).
Потоки по умолчанию — по числу производительных ядер: на гибридном процессоре
экономичные ядра только задерживают барьеры OpenMP.

##### Итог проверки реализации

- Контракты CFD, пристеночная сетка, три CLI-режима, Joukowski, Blasius и сфера прошли.
- Турбулентная модель на пластине: разрешённый слой — PASS; пристеночные функции занижают трение
  на ~5 % и допуск 3 % не проходят (см. выше).
- Swift EngineeringValidationProbe: 188/188, включая настоящий SU2, перенос таблицы,
  пересчёт момента к CG, инвалидирование, отмену и согласованность пристеночной
  оценки с решателем.
- Остальной набор ctest: 83/83 без метки cfd.
- macOS Debug и Qt-GUI собираются; результаты открываются в нативных окнах.
- Не проверено живьём пользователем: новые элементы диалога CFD (режим стенки,
  подбор пристеночной сетки) и панель Мастерской.

---

## V. Модель повреждений

Источник состояния — `VehicleComponentGraph`. У детали независимо хранятся целостность, остаточная прочность, жёсткость, пластическая деформация, работоспособность и состояние крепления. Потеря целостности сама по себе не означает отделения. Обломок появляется, когда разрушено соединение, и уходит вместе со своими зависимыми деталями. После отделения пересчитываются масса, центр масс, инерция и контактная геометрия.

### Конструкция: станции и сечения

Крыло — это цепочка из 12 станций на полуразмах. Их нарезают по реальной планформе меша. Хвостовое оперение, киль, хвостовая балка и лучи мультикоптера нарезаются на 4 станции. У каждого соединения есть сечение `VehicleJointSection` с набором параметров:

- анкер;
- оси размаха, нормали и хорды;
- предельные изгибающие моменты: положительный и отрицательный по flap, lag, кручение;
- срез и растяжение;
- жёсткости;
- материал.

Прочность сечения — итог расчёта (`VehicleSectionDesign`), а не табличное значение. Расчёт идёт в таком порядке.

**Расчётная перегрузка.** Эксплуатационная перегрузка — большая из двух:
- манёвр по CS-23.337: `2.1 + 24000/(W_lb + 10000)`, в пределах 2.5…3.8;
- порыв 50 фут/с на крейсерской скорости по CS-23.341, с коэффициентом ослабления K_g.

Разрушающая перегрузка равна эксплуатационной, умноженной на `max(1.5, 1/yieldRatio)`. Так в пределах эксплуатационной нагрузки не остаётся остаточной деформации.

**Распределение нагрузки.** Подъёмная сила по размаху распределяется по Шренку. Действуют нижняя граница минимальной толщины и фитинг-фактор 1.15. Отрицательный изгиб принят равным 0.4 положительного.

**Пол по огибающей.** Каждое соединение дополнительно поднимается до нагрузок, которые тот же решатель нагрузок даёт в расчётных случаях:
- выход из пике и работа на отрицательной перегрузке;
- боковой случай;
- висение на полной тяге;
- посадочный удар;
- инерция при аварийной посадке.

Проверка комбинированная: квадратичное взаимодействие изгиба, кручения, среза и растяжения. Если расчётный случай не проходит при полном изгибе и кручении одновременно, всё сечение увеличивается пропорционально.

**Лонжерон.** Ось жёсткости крыла — прямая линия, построенная робастной оценкой Тейла–Сена по 35 % хорды полос. Хвостовые балки и гондолы, вписанные в планформу, её не искривляют.

**Крепления оборудования.** Аккумулятор, авионика, подвес, нагрузка, моторы и винты рассчитаны на удар 40 g по всем шести направлениям. Это аварийный удар из MIL-STD-810, метод 516: функциональный удар 20 g без повреждений и аварийный 40 g с удержанием.

**Шасси.** Шасси рассчитывается на тот удар, который ему передаст контактный решатель. Это касание с расчётной вертикальной скоростью CS-23.473(d), `4.4·(W/S)^¼` фут/с в пределах 7–10 фут/с, в каждой контактной точке, с тем же импульсом, длительностью и плечом.

### Мгновенный отклик соединения

Нагрузка на соединение сначала проходит через `StructuralJointResponse.evaluate`, и исход наступает сразу:
- выше предела текучести остаётся пластическая деформация;
- при использовании ≥ 1 соединение ломается или складывается на обшивке;
- ниже текучести ничего не происходит.

Разрушения, накопленного со временем, нет, как и «отпадания через секунду после посадки». Усталость моделируется только одна: крепление повреждённого винта, по правилу Майнера (`N = 10^((1−S)/b)`, поправка Гудмана).

Полётные нагрузки берутся из удельной силы и углового ускорения, которые публикует сам физический движок. Скорость не дифференцируется: иначе клэмпы и регуляторы читались бы как манёвр.

### Удар

**Удар по тонкому элементу** (крыло, балка, луч) решается переходным процессом `StructuralMemberImpactSolver`:
- цепочка жёстких станций на шестикомпонентных пружинах;
- неявная схема Ньюмарка на блочно-трёхдиагональном разложении Холецкого.

Контакт работает как автомат с тремя состояниями: открыт, упругий, смятие, с возможностью повторного касания. Деталь сминается при силе смятия своего сечения, а при сквозном смятии режется. Шарниры упругопластические; секции складываются или отделяются прямо внутри импульса. Скорость обломков определяется по импульсу.

**Подвижное препятствие** — ветка или ствол — входит в решатель отдельной степенью свободы. У него есть эффективная масса и упругопластическая пружина к земле с пределом и изломом. Эта степень свободы конденсируется в контактную строку ударенной станции. Лёгкая ветка отбрасывается собственной инерцией. Массивный ствол работает как стена. Если ветка ломается или соскальзывает, контакт прекращается, и аппарат продолжает движение сквозь то место, где она была.

**Удар по тупой детали** (фюзеляж, гондола, подвес) идёт по жёсткому пути. Деталь сминается при силе смятия своей «тени» вдоль удара и продолжает смятие, пока хватает её глубины. Импульс переходит в плато силы плюс жёсткий остаток. Раньше любой такой удар был трёхмиллисекундным, и фюзеляж, ударившийся о дерево на 30 м/с, передавал тысячу g на все крепления.

**Отлетевшая деталь** получает от препятствия не больше, чем нужно, чтобы остановить её саму, плюс то, что успело передать её крепление до разрушения.

**Остальной планер** ощущает удар через спектр ударного отклика:
- элемент — на своём первом периоде изгиба;
- навесная деталь — на периоде собственного крепления, `2π√(m/k)`.

### Деревья

Крона — это не объём вязкого торможения. `TreeCrownStructure` строит древесину сосны детерминированно по боксу кроны. Константы — свойства настоящей сосны (обоснование в комментарии к типу):
- ствол со стройностью H/DBH = 50;
- мутовки через 0.6 м, по 5 ветвей;
- основание ветви — ¼ диаметра ствола;
- длина ветви равна радиусу кроны на её высоте;
- по 4 боковых отростка на ветвь;
- зелёная древесина: MOR 35 МПа, E 7 ГПа, плотность 800 кг/м³.

Каждая ветвь — сужающаяся консоль. Сила излома берётся по наиболее напряжённому сечению, жёсткость — интегрированием податливости. Эффективная масса вычисляется методом Рэлея. Ветвь, изгиб которой превысил ~22°, соскальзывает с детали; ветвь, которая раньше доходит до излома, ломается. Сломанная ветвь остаётся сломанной до сброса полёта (`TreeBranchRegistry`).

Ствол моделируется целиком, от земли до вершины, поэтому отдельный бокс ствола сцены остаётся только для навигации. Кроной считается любое древесное препятствие: и `tree.canopy` сцены, и `world.tree` мира открытых данных. Выталкивание из препятствия при проникновении (`resolveObstaclePenetration`) деревья пропускает. Раньше оно возвращало аппарат на поверхность кроны, до её полуширины вбок за шаг, и аппарат не доходил ни до ствола, ни до ветвей.

Проход через крону обрабатывается каждый шаг, пока в кроне есть любая наружная деталь (`resolveCrownPassage`). Проверка непрерывная по времени: движущийся отрезок ветви сравнивается с боксом детали отсечением единичного квадрата (s, t). Первая пересечённая ветвь разрешается как удар через тот же решатель.

Хвоя и мелкие побеги сметаются: сопротивление по модели снегоочистителя `ρ·A·|v|·v` на тени каждой детали. Плотность ρ = 0.9 кг/м³ — это хвоя и побеги внутри самой кроны: около 30 кг сырой хвои и 15 кг побегов у сосны 15–18 м на примерно 50 м³ кроны. Древостойная «canopy bulk density» пожарной науки (0.05–0.3) для этого не подходит: она усреднена вместе с просветами между кронами. Сила зависит от размера и скорости, а не от массы, и крыло, зашедшее в крону, разворачивает аппарат к ней. Побеги толщиной 4 мм (треть мелкого горючего материала) задирают переднюю кромку каждой детали в кроне. Вращающийся винт встречает их на трёх четвертях окружной скорости.

В Debug-сборке консоль Xcode показывает строки `[Tree]`: вход в крону и каждый значимый удар — деталь, ствол или ветвь, диаметр, сила излома, масса, скорость, импульс, исход.

### Аэродинамика повреждений

Крыло интегрируется по полосам в осях тела. Местный угол атаки меняется от крена: `2·p̂·y`, с коэффициентом индуцированной поправки, откалиброванным так, чтобы демпфирование полос в безотрывном обтекании равнялось `clp` самолёта. Скорость полосы меняется от рыскания. Подъёмная сила и сопротивление разлагаются на нормальную и осевую силу; момент крена даёт именно нормальная сила.

Повреждение входит как разность: одни и те же полосы считаются повреждёнными и целыми при текущем обтекании, и разница прибавляется к коэффициентам исправного самолёта. Первая вмятина меняет самолёт ровно на вклад самой вмятины, а не на разницу между двумя моделями.

Ниже угла сваливания демпфирование крена полностью совпадает с исходным `clp`. В зоне сваливания полосы берут управление на себя, и демпфирование может перейти через ноль в авторотацию: штопор возникает сам. Руль высоты, руль направления и элероны теряют эффективность в следе крыла вместе со своими производными устойчивости. Раньше полная ручка на себя держала весь парк на α = 80° в плоском штопоре.

### Разбитый аппарат: конец движения

Обломок обязан остановиться. Раньше он не останавливался: eBee крутился на 9 рад/с через двадцать секунд после удара о полосу, а MQ-9B подпрыгивал на месте. Причин было четыре, и все физические.

**Сопротивление вращению.** Коэффициентная модель гасит вращение через `clp`, `cmq` и `cnr`, а они пропорциональны скорости: `q·S·b·C·(p·b/2V)` — это `V·p`. В полёте так и есть, но при падении воздушной скорости демпфирование исчезает вместе с ней. Теперь каждая наружная деталь, разрезанная на четыре части по длинной стороне, встречает сопротивление собственной скорости вращения `ω×r`: `−½ρ·C·A·|v|·v`, где C = 1.2 — нормальная сила плоской пластины (Hoerner). Член квадратичный по угловой скорости, поэтому там, где работают коэффициенты, он пренебрежимо мал.

**Контакт с землёй.** Наземный клэмп поднимал аппарат на его нижнюю точку и обнулял скорость снижения — и всё. В точке касания не возникало ни силы, ни трения, а решатель ударов включается только при скорости подхода больше 0.35 м/с. Теперь, когда аппарат стоит не на своих опорах, каждая касающаяся точка получает импульс, останавливающий её проваливание, через плечо к центру масс, и кулоново трение против скольжения (последовательные импульсы, несколько проходов). Плюс сопротивление качению и повороту: обломок не колесо, его обшивка сминается, а края зарываются. Сопротивление качению 0.1 от нагрузки на плечо качения — цифра для неровного деформируемого тела на грунте.

**Отскок на больших скоростях.** Коэффициент восстановления материала — это отскок на нескольких метрах в секунду. Дальше удар всё больше пластический: `e` падает как `(v_y/v)^¼` (Johnson, *Contact Mechanics*, §11.4). eBee, падавший на 55 м/с, подпрыгивал на семь метров; теперь возвращается 0.12 скорости вместо 0.24, а после сквозного смятия не возвращается ничего.

**Отодвигание от поверхности.** Решатель удара отодвигал аппарат от препятствия на 4 % радиуса сферы, чтобы не было повторного касания в том же шаге. Для земли, которую уже держит клэмп, это подъём: у MQ-9B — 2 см, то есть 900 Дж за касание. Обломок подпрыгивал на собственном подъёме бесконечно. Для опорной поверхности зазор убран.

**Обломок без деталей.** Когда от аппарата остаётся один контактный шар, он ведёт себя как шар: точка касания под центром масс, вращение останавливать нечем. Если в профиле осталось меньше трёх точек, землю держат нижние углы коробок уцелевших деталей.

**Управление без моторов.** Регулятор висения конвертоплана выдавал управляющий момент и обесточенным: лежащий обломок пытался встать в положение висения. Момент делают роторы; при выключенных роторах его нет.

### Геометрия и обломки

Видимые меши привязаны к физическим компонентам независимо от старых групп диагностики. Цельные меши крыла режутся по станциям: граница проходит по стабильному хешу треугольника, поэтому излом рваный. Материалы, нормали и UV сохраняются, а у кусков излома материалы становятся двусторонними. Обломок получает собственное динамическое тело SceneKit, массу, инерцию и начальную скорость в месте отделения.

### Проверка

- **`Tools/CrashScenarioProbe/run.sh [id…]`** прогоняет по каждому аппарату пять сценариев: падение носом вниз, лежащий вращающийся обломок, планирование без питания до земли, потеря крыла и потеря оперения в крейсере. Проверяется, что обломок останавливается за 8 с после касания, что через 17 с он не вращается, и что за шаг без питания механическая энергия не растёт.
- **`Tools/DamageModelProbe/run.sh [id…]`** проверяет:
  - станции и отсутствие хвоста у летающих крыльев;
  - упругость при эксплуатационной перегрузке;
  - удары по крылу;
  - посадки: ничего не отваливается позже последнего удара, и посадка 1 м/с ничего не ломает — касание начинается в 3 см над полосой.
- **Отдельные эксперименты в scratchpad:**
  - тангаж: изгиб при штатном манёвре;
  - штопор: вход, развитие, выход;
  - крона: проход сквозь сосну.

  По ним и настроены описанные выше выводы.
- **`Tools/TurnCoordinationProbe`, `PitchTrackingProbe`, `ManoeuvreMarginProbe`, `ClimbProbe`** подтверждают, что безотрывный полёт исправного самолёта не изменился.

### Параметры модели

Это модель сосредоточенных масс на дискретных балках, контактных импульсов и аэродинамических полос. Прочность получается из правил проектирования и материалов, а не из расчёта конечными элементами или испытаний конкретного серийного аппарата. Каждое пороговое значение в коде сопровождается обоснованием; менять его следует вместе с проверками посадки, штатного полёта и энергетического баланса.

---

## VI. Python-слой CADNext (задел)

Каталог `CADNext/python` — это **намерение, а не функция**: в нём лежат `CMakeLists.txt` и
`bindings/cadnext.i`, обвязка не собрана и не используется. Флаг `CADNEXT_WITH_PYTHON` существует,
но включает заглушку. Ниже — правила, ради которых каталог заведён; они действуют на проектирование
C++ API уже сейчас.

- Python-слой должен открывать наружу все публичные C++ API CADNext.
- Предполагаемое применение: макросы, автоматизация, свои рабочие среды, некритичные инструменты,
  скриптовые тесты, в будущем — скриптование интерфейса через PySide.
- Правило: каждый публичный C++ API проектируется так, чтобы его можно было обернуть для Python.
- `python/workbenches` — рабочие среды, описанные на Python; должны пользоваться публичным API и
  могут позже подключать Qt/PySide для некритичной оркестрации интерфейса.
- `python/macros` — пользовательские макросы поверх обвязок. Критичные геометрические операции
  остаются в C++; макрос вызывает обёрнутый C++ API, не зависит от Swift-типов DroneUAVDemo и
  переносит модель в UAVsim только через экспорт bridge.

---

## VII. Сборка, тесты и пробы

### DroneUAVDemo

Xcode-проект `DroneUAVDemo` (Swift 5, macOS 14.6+). Обычный путь — открыть `DroneUAVDemo.xcodeproj`
и запустить схему `DroneUAVDemo`.

Полная сборка из командной строки без Metal Toolchain:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/uavsim-xcode-clang-cache \
xcodebuild -project DroneUAVDemo.xcodeproj \
  -scheme DroneUAVDemo \
  -configuration Debug \
  -derivedDataPath /tmp/uavsim-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  EXCLUDED_SOURCE_FILE_NAMES=WeatherDepthOfField.metal \
  build
```

Юнит-тесты пакета:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/uavsim-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/uavsim-swiftpm-cache \
swift test --disable-sandbox
```

### CADNext

Отдельный CMake-проект на C++20, не участвующий в сборке Swift-приложения.

Без GUI и внешних зависимостей (core/kernel/bridge + тесты):

```bash
cmake -S CADNext -B CADNext/build
cmake --build CADNext/build
ctest --test-dir CADNext/build
```

С графическим интерфейсом (нужны Qt6, Coin3D и SoQt, например `brew install coin3d`):

```bash
cmake -S CADNext -B CADNext/build-gui -DCADNEXT_BUILD_APP=ON -DCADNEXT_WITH_QT=ON -DCADNEXT_WITH_COIN3D=ON
cmake --build CADNext/build-gui
```

С точной геометрией через Open CASCADE (`brew install opencascade`):

```bash
cmake -S CADNext -B CADNext/build-gui-occt -DCADNEXT_BUILD_APP=ON -DCADNEXT_WITH_QT=ON -DCADNEXT_WITH_COIN3D=ON -DCADNEXT_WITH_OCCT=ON
cmake --build CADNext/build-gui-occt
```

С сеточником для прочности и физических испытаний (OCCT + Netgen, см. `CADNext/tools/build_netgen.sh`):

```bash
cmake -S CADNext -B CADNext/build-netgen -DCADNEXT_WITH_OCCT=ON -DCADNEXT_WITH_NETGEN=ON -DNetgen_DIR="$PWD/CADNext/third_party/netgen/install/Contents/Resources/CMake"
cmake --build CADNext/build-netgen -j6
ctest --test-dir CADNext/build-netgen
```

Флаги: `CADNEXT_WITH_OCCT` — точное BRep-ядро вместо процедурного stub; `CADNEXT_WITH_COIN3D` /
`CADNEXT_WITH_QT` — 3D-вьюпорт и интерфейс Qt6 (Qt требует Coin3D); `CADNEXT_BUILD_APP` — собрать
`cadnext_app`; `CADNEXT_WITH_NETGEN` — сеточник для прочности и испытаний; `CADNEXT_WITH_PYTHON` —
обвязка Python (заглушка); `CADNEXT_BUILD_TESTS` — тесты (включены по умолчанию).

Пункт меню *CAD → Open CADNext* ищет уже собранный бинарник по пути
`CADNext/build-gui-occt/app/cadnext_app` (предпочтительно, с OCCT) или
`CADNext/build-gui/app/cadnext_app` (процедурный fallback, без булева вычитания).

### Что чем проверяется

| Что | Чем |
| --- | --- |
| Геометрия, сборки, прочность, испытания, CFD | `ctest --test-dir CADNext/build-netgen` (120 файлов тестов) |
| Интерфейс CADNext | тесты с суффиксом `gui` в сборке с Qt |
| Лётная модель, автопилот, миссии, звук, повреждения | 50 безголовых проб в `Tools/` |
| Модель повреждений на всём каталоге | `Tools/DamageModelProbe/run.sh` |
| Падения, удары и поведение обломка до остановки | `Tools/CrashScenarioProbe/run.sh` |
| Инженерная валидация: устаревание и зависимости | `Tools/EngineeringValidationProbe` |

Пробы в `Tools/` гоняют настоящий автопилот и настоящую физику без SceneKit и печатают измеренные
числа — именно они, а не глаз, решают, стало ли лучше.

---
