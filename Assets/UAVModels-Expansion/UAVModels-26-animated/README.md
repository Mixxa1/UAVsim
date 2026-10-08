# 26 дополнительных моделей БЛА

23 самолётных аппарата (включая 4 VTOL) и 3 коптера. Все 26 USDZ имеют встроенную анимацию, собственные материалы и текстуры. Это авторские приближённые визуальные реконструкции по открытым референсам, а не заводские CAD.

[Открыть каталог](catalog.html) · [26 USDZ](UAVModels-26-animated.zip) · [Исходники и превью](UAVModels-26-source-and-previews.zip)

## Содержимое

- `models/`: 26 самостоятельных USDZ. Внешние фотографии и сетевые ресурсы им не требуются.
- `sources/`: редактируемые USDA и оригинальные процедурные текстуры/маркировки.
- `previews/`: пять ракурсов и GIF каждого аппарата, обзор всей коллекции.
- `manifest.json`: размеры, анимируемые узлы, материалы и SHA-256.
- `reference-manifest.json`: источники, опубликованные размеры и параметры визуальной реконструкции.
- `validation/`, `validation-summary.json`, `connection-audit.json`: результаты проверок.

## Анимация и масштаб

Единицы — метры, вверх +Y, нос +Z. Имена вращающихся узлов и осей перечислены в manifest. Статические опоры остаются неподвижными; винт вращается вокруг собственного локального центра. У коптеров направления на противоположных углах совпадают.

Обычный цикл длится 2 секунды, цикл VTOL — 12 секунд. Частота ключей — 60 кадров/с; вращение до 120 об/мин замедлено для просмотра. Камеры с подвесом выполняют небольшой панорамный или наклонный ход. WingtraRAY поворачивает весь аппарат между вертикальной и горизонтальной ориентациями. У CW-20E, JUMP 20 и DeltaQuad Evo подъёмные винты останавливаются в крейсерской фазе и запускаются при возврате. Роторы, камера и управляющие поверхности сохраняют отдельные узлы.

Коллекция подключена к симулятору UAVsim через install_expansion.py. Во время полёта демонстрационные циклы отключаются; скорость винтов, камеры и управляющие поверхности читают состояние симуляции. Лётные профили имеют оценочные параметры, отдельно отмеченные в каталоге приложения. Внешний размах крыла, включая наклонные законцовки, привязан к указанному размаху; положение лопастей влияет на статические границы. Размеры, которые источник не публикует, отмечены как оценочные. Для WingtraRAY опубликованный размер не включает посадочный киль.

## Живая механика в приложении

У всех 23 крылатых моделей выделены шарниры рулей: элероны и рули высоты либо элевоны, рули направления и V-образное смешивание по конструкции аппарата. Закрылки есть у 8 моделей; убираемые стойки и створки — у 3 (Heron TP, Falco Xplorer и P.1HH). Коптеры сохраняют вращение винтов и подвесы камер.

В панели «Полёт» → «Механизация» доступны автоматический режим закрылков и шасси, взлётное/посадочное положение и ручной выпуск/уборка. Рули получают фактические положения физических сервоприводов, включая задержку и заклинивание. Закрылки меняют подъёмную силу, сопротивление и моменты; шасси меняет сопротивление и контакты колёс. Створки открываются перед движением стоек и закрываются после фиксации. Ограничения и времена приводов рассчитываются для выбранного аппарата. Чрезмерные нагрузки могут повредить панели, стойки и створки; незапертые стойки не удерживают аппарат при контакте с землёй.

У каждого из восьми аппаратов с закрылками своя длина, хорда, сужение и раскладка секций. У двухбалочных аппаратов оставлены промежутки под балки, у P.1HH — под мотогондолы. Доли площадей и хорд измерены по тем же сеткам и записаны в `mechanics.flap_geometry`; коэффициенты читают эти значения. Щелевые панели и закрылки Фаулера перемещаются на направляющих с подвижными опорами; передние закрылки P.1HH связаны с основным приводом.

[Heron TP: уборка/выпуск шасси](previews/iai-heron-tp-gear-cycle.gif) · [Falco Xplorer: уборка/выпуск](previews/leonardo-falco-xplorer-gear-cycle.gif) · [P.1HH: уборка/выпуск](previews/piaggio-p1hh-hammerhead-gear-cycle.gif)

Положение осей, кинематика, углы, времена приводов и аэродинамические поправки являются оценочными. Состояния узлов записываются существующим replay; команды механизации сохраняются с проектом.

## Проверки

Все 26 файлов проходят системный usdchecker --arkit и импортируются в SceneKit. Проверены 186 движущихся узла, совпадение начала и конца циклов, оси шарниров и траектории направляющих. У шасси проверены полная уборка всех стоек и закрытие створок. Во всех 26 моделях статический граф контактов сеток связный; не обнаружены отдельные детали или неподдержанные ступицы. Проверены CRC, 64-байтное выравнивание USDZ, наличие текстур и SHA-256 именно отрендеренных файлов.

Эти проверки подтверждают совместимость файлов, воспроизведение и соединения в исходной позе. Они не подтверждают заводскую точность, механическую прочность или весь диапазон кинематических зазоров. Исходный вывод валидатора macOS сохранён; возможная диагностика повторной регистрации UsdShade не заменяет проверку итогового Success.

## Аппараты и источники

| Аппарат | Класс | Опубликованные размеры / масштаб | Источник |
|---|---|---|---|
| WingtraRAY | Самолёт VTOL | 125 × 68 × 12 cm, without landing fin | [Источник](https://wingtra.com/ray/) |
| AgEagle eBee X | Самолёт | Wingspan 116 cm; length is estimated from imagery | [Источник](https://eaglenxt.com/products/drones/ebee-series/ebee-x/) |
| Delair DT26 Open Payload | Самолёт | Wingspan / length: 3.3 m / 1.6 m | [Источник](https://delair.aero/delair-commercial-drones-2/dt26-open-payload/) |
| JOUAV CW-20E | Самолёт VTOL | Technical Specifications: wingspan 3.50 m; fuselage 2.07 m | [Источник](https://www.jouav.com/products/cw-20e.html) |
| Delair UX11 | Самолёт | Wingspan 1.2 m; length is estimated from imagery | [Источник](https://delair.aero/drone-solutions-for-geospatial-surveying-and-mapping/) |
| C-Astral Bramor C4EYE | Самолёт | Wingspan 230 cm; platform length 96 cm; centre module length 67 cm | [Источник](https://www.c-astral.com/en/unmanned-systems/bramor-c4eye) |
| AeroVironment Puma LE | Самолёт | Wingspan 4.6 m; length 2.2 m | [Источник](https://www.avinc.com/solution/puma-le/) |
| TEKEVER AR3 | Самолёт | AR3: wingspan 3.5 m; length 1.7 m; fixed-wing configuration | [Источник](https://www.tekever.com/wp-content/uploads/2023/06/Products_v02_2023.pdf) |
| DeltaQuad Evo | Самолёт VTOL | Wingspan 269 cm; length 75 cm; height 33 cm with landing gear | [Источник](https://www.deltaquad.com/resources/technical-specifications/) |
| TEKEVER AR5 | Самолёт | AR5: wingspan 7.3 m; length 4.0 m | [Источник](https://www.tekever.com/wp-content/uploads/2023/06/Products_v02_2023.pdf) |
| AeroVironment Raven B | Самолёт | Wingspan 1.4 m; length 0.9 m | [Источник](https://www.avinc.com/solution/raven-b/) |
| AeroVironment Puma 3 AE | Самолёт | Wingspan 2.8 m; length 1.4 m | [Источник](https://www.avinc.com/solution/puma-3-ae/) |
| AeroVironment JUMP 20 | Самолёт VTOL | Wingspan 5.7 m; length 2.8 m | [Источник](https://www.avinc.com/solution/jump-20/) |
| Insitu ScanEagle | Самолёт | Wingspan 3.1 m; length 1.71 m | [Источник](https://www.insitu.com/products/scaneagle) |
| Aeronautics Orbiter 3 | Самолёт | Wingspan 4.2 m; length is estimated from reference imagery | [Источник](https://aeronautics-sys.com/systems/orbiter-3/) |
| Aeronautics Orbiter 4 | Самолёт | Wingspan 5.4 m; length is estimated from reference imagery | [Источник](https://www.aeronautics-sys.com/wp-content/uploads/2023/01/Orbiter4.pdf) |
| Aeronautics Aerostar | Самолёт | Wingspan 8.7 m; fuselage length 4.5 m | [Источник](https://aeronautics-sys.com/systems/aerostar/) |
| Elbit Hermes 450 | Самолёт | Wingspan 10.5 m; length 6.1 m | [Источник](https://www.mindef.gov.sg/news-and-events/latest-releases/2015mar30-news-releases-01655/) |
| IAI Heron Mk II | Самолёт | Wingspan 16.6 m; fuselage length 8.5 m | [Источник](https://www.iai.co.il/product/heron-mk-ii/) |
| IAI Heron TP | Самолёт | Wingspan 26 m; length 14 m | [Источник](https://www.iai.co.il/product/heron-tp/) |
| Leonardo Falco EVO | Самолёт | Wingspan 12.5 m; length 5.2 m | [Источник](https://aeronautics.leonardo.com/documents/30508878/30801272/FALCO_EVO_MM07818-VEL.pdf?t=1675434951098) |
| Leonardo Falco Xplorer | Самолёт | Wingspan 18.5 m; length 9 m | [Источник](https://aeronautics.leonardo.com/en/products/falco-xplorer) |
| Piaggio P.1HH HammerHead | Самолёт | Wingspan 15.6 m; length 14.4 m | [Источник](https://www.piaggioaerospace.it/yep-content/media/P1HH_HammerHead_B.pdf) |
| DJI Mini 5 Pro | Мультикоптер | Unfolded, with propellers: 304 × 380 × 91 mm (L × W × H) | [Источник](https://www.dji.com/mini-5-pro/specs) |
| DJI Avata 2 | Мультикоптер | 185 × 212 × 64 mm (L × W × H) | [Источник](https://www.dji.com/avata-2/specs) |
| Autel EVO Max 4T V2 | Мультикоптер | Unfolded with 1158 propellers: 563 × 657 × 147 mm (L × W × H); wheelbase 467 mm | [Источник](https://www.autelrobotics.com/wp-content/uploads/2025/05/EVO-Max-Series-Brochure.pdf) |

## Индивидуальная геометрия закрылков

Площади относятся к авторской сетке. Доля крыла — площадь участков крыла перед закрылками; доля хорды — площадь панелей, делённая на площадь этих участков. Размеры оценочные.

| Аппарат | Секций на крыло | Доля крыла | Средняя доля хорды |
|---|---:|---:|---:|
| TEKEVER AR5 | 2 | 37.7% | 20.9% |
| Aeronautics Aerostar | 2 | 41.9% | 26.0% |
| Elbit Hermes 450 | 1 | 54.0% | 28.4% |
| IAI Heron Mk II | 2 | 45.2% | 27.1% |
| IAI Heron TP | 2 | 50.9% | 30.2% |
| Leonardo Falco EVO | 2 | 43.5% | 31.2% |
| Leonardo Falco Xplorer | 1 | 54.9% | 29.8% |
| Piaggio P.1HH HammerHead | 2 | 49.1% | 30.1% |

## Воспроизводимая сборка

В репозитории UAVsim: `Tools/UAVModelAssets/build_expansion.py` создаёт ассеты, `audit_expansion.py` проверяет соединения, `render_expansion.swift` создаёт нативные превью, `validate_expansion.py` проверяет готовый набор, `publish_expansion.py` собирает каталог и архивы. Для Python нужны Pillow и NumPy; USD-инструменты и Swift используются системные macOS.

Пример последовательности:

```sh
python3 Tools/UAVModelAssets/build_expansion.py
python3 Tools/UAVModelAssets/audit_expansion.py
swiftc Tools/UAVModelAssets/render_expansion.swift -o /tmp/render-uav-expansion
/tmp/render-uav-expansion Assets/UAVModels-Expansion
python3 Tools/UAVModelAssets/publish_expansion.py
```
