# RF-система UAVsim: финальный статус

Источник требований: `UAVsim_RF_System_Technical_Specification_RU.pdf`, версия 1.0 от 31 августа 2026 года.

## Архитектура

Обычная радиосвязь теперь всегда авторитетно рассчитывается физическим RF core:

1. `RFPropagationEngine` вычисляет FSPL, усиление и ориентацию антенн, потери, RSSI, noise floor, SNR, SINR и link margin.
2. `DigitalLinkQualityModel` переводит бюджет в PER, latency, jitter и effective bitrate; `AnalogVideoQualityModel` отдельно моделирует плавный аналоговый шум без цифрового frame freeze.
3. `RFPacketDeliveryEngine` и `RFSharedChannelScheduler` моделируют пакеты, retry, TTL, очереди, MCS, общий bitrate budget, резервы, borrowing и динамический CONTROL boost.
4. CONTROL, VIDEO, TELEMETRY и PAYLOAD DATA имеют независимые конфигурации, состояния и потребителей.

Расстояние является только входом FSPL. Скрытого порога дальности в runtime нет. `nominalLinkRangeM` читается исключительно миграционным конвертером, который один раз создаёт физический compatibility preset для старого профиля. Оптоволоконный канал остаётся отдельной подсистемой.

## Реализовано

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

## Критерии готовности

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

## Проверка

```bash
CLANG_MODULE_CACHE_PATH=/tmp/uavsim-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/uavsim-swiftpm-cache \
swift test --disable-sandbox
```

Полная локальная сборка без отсутствующего в текущей установке Metal Toolchain:

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
