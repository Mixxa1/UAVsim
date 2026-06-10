# CAD v0 — архив старой Swift/SceneKit CAD-системы

## Статус

Эта CAD-система удалена из активного проекта и больше не развивается.  
Документ фиксирует функционал, который существовал в старой CAD-мастерской до перехода на новую архитектуру CADNext.

Причина отказа от CAD v0:

- геометрическое ядро было самописным и ограниченным;
- булевые операции, пересекающиеся вырезы и вырезы с разных граней приводили к артефактам;
- SceneKit mesh-rebuild подход не подходит как основа полноценного CAD;
- дальнейшее развитие требует промышленного геометрического ядра;
- новая CAD-система будет строиться отдельно на C++ / OCCT / Qt / Coin3D / Python.

---

## Технологии CAD v0

CAD v0 была встроена прямо в macOS-приложение DroneUAVDemo.

Использовались:

- Swift;
- SwiftUI;
- SceneKit;
- Codable-документы;
- самописные доменные CAD-модели;
- самописная логика sketch / extrude / cut;
- частичный mesh-rebuild для визуализации вырезов;
- частичный экспериментальный boolean/kernel слой.

---

## Основные точки входа CAD v0

Старая CAD-система была связана со следующими зонами проекта:

- `CADWorkshopViewModel` — основной orchestration слой CAD-мастерской;
- `DesignWorkshopWorkspaceView` — основной SwiftUI workspace;
- `CADWorkshopModuleView` — UI-вход в CAD;
- `DesignDocument` — документ CAD;
- `DesignAsset` / `DesignAssetKind` — элементы CAD-документа;
- `DesignPreviewSceneBuilder` — SceneKit viewport;
- `DesignPreviewSceneViewRepresentable` — SwiftUI -> SceneKit bridge;
- `DesignAssetNodeFactory` — генерация SceneKit-геометрии;
- `CADSolidBackend` — частичный solid/backend слой;
- `CADCutRequest`, `CADCutValidator`, `CADCutCommitEngine`, `CADCutMeshRebuilder` — cut v2 pipeline;
- `CADFeatureTypes` — операции, depth modes, validation, mesh diagnostics;
- `DesignSketchProfileGraph` — поиск sketch-профилей.

---

## Функционал CAD v0

### 1. CAD-документ

CAD v0 поддерживала документ с:

- UUID документа;
- именем;
- единицами измерения;
- списком assets;
- выбранным asset;
- Codable-сохранением;
- восстановлением производных свойств после загрузки.

Поддерживались единицы:

- metric;
- imperial.

---

### 2. CAD-assets

Система поддерживала несколько типов конструктивных элементов:

- базовое крыло;
- frame plate;
- beam;
- tube;
- mount bracket;
- payload box;
- sketch2D;
- extruded solid.

Каждый asset имел:

- UUID;
- имя;
- тип;
- transform;
- материал;
- attachment points;
- mass properties.

---

### 3. Материалы

Поддерживались материалы:

- plastic;
- carbon fiber;
- aluminum;
- steel;
- composite.

Для материалов хранились:

- отображаемое имя;
- плотность;
- preview color.

---

### 4. Массовые свойства

Для CAD-assets рассчитывались:

- масса;
- центр масс;
- bounding width;
- bounding height;
- bounding depth;
- drag penalty;
- structural rating.

---

### 5. Attachment points

Система имела attachment point модель для будущей сборки и связи с payload / симуляцией.

Attachment point включал:

- UUID;
- имя;
- local position;
- local rotation;
- роль;
- флаг system/custom;
- флаг enabled.

Роли attachment points:

- frame;
- wing;
- payload;
- camera;
- sensor;
- landing gear;
- motor;
- battery;
- antenna;
- generic.

Также существовал placeholder `DesignAssemblyLink` для будущего assembly editor.

---

### 6. Sketch planes и workplanes

CAD v0 поддерживала:

- XY;
- XZ;
- YZ;
- canonical planes;
- planar face references;
- sketch на выбранной грани;
- workplane hover / selection;
- active sketch plane overlay;
- переход в sketch2D mode;
- normal-to-sketch camera view.

---

### 7. Sketch entities

Поддерживались sketch-элементы:

- line;
- rectangle;
- circle;
- polyline;
- arc;
- construction line;
- autoline / polyline workflow.

---

### 8. Sketch styles и line styles

Существовали роли линий:

- main;
- construction.

Были добавлены CAD line styles:

- main;
- thin;
- center;
- hidden;
- thick;
- breakLine.

Важно: line style отвечал за визуальный стиль, а участие в extrude/cut должно было определяться отдельной ролью main/construction/reference.

---

### 9. Constraints и dimensions

Поддерживались sketch constraints:

- horizontal;
- vertical;
- fixed start;
- fixed end;
- coincident;
- equal length;
- parallel;
- perpendicular.

Поддерживались dimensions:

- line length;
- line angle;
- horizontal distance;
- vertical distance;
- rectangle width;
- rectangle height;
- circle radius;
- circle diameter.

---

### 10. Snapping

Существовал snap pipeline с приоритетами.

Поддерживались snap-типы:

- sketch vertex;
- active circle center;
- body vertex;
- body edge;
- edge midpoint;
- construction vertex;
- construction line;
- construction intersection;
- grid;
- reference sketch vertex;
- reference sketch edge midpoint;
- projected sketch vertex;
- projected sketch edge midpoint.

Grid был fallback, а не приоритетный snap.

---

### 11. Viewport

CAD v0 использовала SceneKit viewport.

Поддерживались:

- world grid;
- sketch grid;
- world axes;
- plane axes;
- reference planes;
- active plane overlay;
- asset container;
- phantom line/path;
- cursor marker;
- snap marker;
- dimension overlay.

Камеры:

- iso;
- top;
- front;
- side;
- fit.

---

### 12. Sketch profile graph

Система умела строить profile graph по main sketch entities:

- поиск замкнутых line loops;
- rectangle profile;
- circle profile;
- polyline profile;
- nested loops;
- holes;
- area;
- centroid;
- выбор области профиля.

---

### 13. Extrude

Поддерживалось создание extruded solid из sketch-профиля.

Extruded solid включал:

- source sketch reference;
- profile points;
- depth;
- direction;
- material;
- generated faces;
- visual mesh.

---

### 14. Cut v2

Существовал cut pipeline:

- CADCutRequest;
- CADCutPreviewBuilder;
- CADCutValidator;
- CADMultiCutValidator;
- CADCutCommitEngine;
- CADCutMeshRebuilder.

Поддерживались профили:

- rectangle;
- circle;
- частично polygon / unsupported path.

Depth modes:

- distance;
- throughAll;
- upToObject — объявлено, но не реализовано;
- upToNearestFace — объявлено, но не реализовано.

Фактически реализованы:

- distance;
- throughAll.

---

### 15. Cut limitations

CAD v0 имела серьезные ограничения:

- нестабильные пересекающиеся вырезы;
- проблемы при вырезах с разных граней;
- артефакты на mesh;
- зубцы на гранях вырезов;
- возможные внутренние лишние поверхности;
- проблемы с цилиндрическими стенками;
- сложная диагностика triangulation artifacts;
- высокий CPU при некоторых операциях;
- boolean kernel был частичным и не являлся полноценным solid kernel.

---

### 16. Частичный CAD solid backend

Существовал частичный backend:

- CADSolid;
- CADBody;
- CADFeature;
- CADDocument;
- CADVolume;
- CADBooleanOperation;
- CADBooleanKernel;
- CADKernelMeshCandidate;
- CADSolidMaterialClassifier;
- CADBoundarySurfaceBuilder;
- topology validation;
- mesh diagnostics.

Поддерживались boolean operation enum:

- union;
- subtract;
- intersect.

Фактическая поддержка была ограниченной. Intersect не был полноценно реализован.

---

### 17. Что нельзя переносить в новую систему напрямую

Нельзя напрямую переносить:

- самописную mesh-boolean логику;
- CADCutMeshRebuilder как основу boolean;
- SceneKit как CAD viewport backend;
- старую cut v2 архитектуру;
- workaround-и для артефактов triangulation;
- смешивание preview mesh и real solid model;
- CAD-документ, завязанный на Swift Codable как основной формат будущей CAD-системы.

Можно использовать только как reference:

- список пользовательских инструментов;
- UX-направления;
- attachment point идею;
- связь CAD-модели с симуляцией;
- материалы и mass properties как требования;
- sketch constraints как будущий функциональный ориентир.

---

## Вывод

CAD v0 была полезным прототипом для проверки UX и workflow, но не подходит как база полноценной CAD-системы.  
Новая CAD-система должна использовать промышленное геометрическое ядро, отдельный C++ core, Python wrappers, Qt UI, Coin3D viewport и явный bridge к симулятору.
