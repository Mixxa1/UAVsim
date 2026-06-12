#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "cadnext/AttachmentPoint.hpp"
#include "cadnext/Vector3.hpp"

// .uavpart — нативный бинарный формат детали CADNext для будущего моста
// CAD → UAV simulation (UAVPart v1). Один физический файл:
//
//   [UAVPartHeader (64 байта)] [payload секций ...] [таблица секций]
//
// Все многобайтовые поля — little-endian. Payload каждой секции — UTF-8
// JSON (JSON допустим только внутри секции; сам файл не является ни
// JSON, ни zip, ни папкой). Внутри файла только единицы СИ: метры,
// килограммы, кг/м³, м³.

namespace cadnext::bridge {

inline constexpr char kUAVPartMagic[8] = {'U', 'A', 'V', 'P', 'A', 'R', 'T', '\0'};
inline constexpr std::uint32_t kUAVPartFormatVersion = 1;
inline constexpr std::size_t kUAVPartHeaderSize = 64;
inline constexpr std::size_t kUAVPartSectionEntrySize = 32;

// Фиксированный заголовок файла. fileChecksum — CRC32 всего файла,
// посчитанный с обнулённым полем fileChecksum.
struct UAVPartHeader {
    char magic[8] = {};
    std::uint32_t formatVersion = kUAVPartFormatVersion;
    std::uint32_t writerVersion = 0;
    std::uint32_t sectionCount = 0;
    std::uint32_t flags = 0;
    std::uint64_t sectionTableOffset = 0;
    std::uint64_t fileSize = 0;
    std::uint32_t fileChecksum = 0;

    bool magicMatches() const;
};

// Типы секций. ExactGeometry и VisualMesh зарезервированы форматом, но
// в UAVPart v1 не записываются (чистый placeholder без fake-данных);
// их отсутствие отражено в манифесте: geometryStored/visualMeshStored.
enum class UAVPartSectionType : std::uint32_t {
    Manifest = 1,
    ExactGeometry = 2,
    VisualMesh = 3,
    Material = 4,
    MassProperties = 5,
    AttachmentPoints = 6,
    SimulationProxy = 7,
    Compatibility = 8
};

// Запись таблицы секций: где лежит payload и его CRC32.
struct UAVPartSectionEntry {
    UAVPartSectionType type = UAVPartSectionType::Manifest;
    std::uint32_t version = 1;
    std::uint64_t offset = 0;
    std::uint64_t length = 0;
    std::uint32_t checksum = 0;
};

// Коды причин, по которым simulationReady = false. В файле хранятся
// стабильные машинные коды; русские тексты для UI даёт
// uavpartReadinessIssueText().
inline constexpr const char* kIssueNoAttachmentPoints = "no_attachment_points";
inline constexpr const char* kIssueMassNotComputed = "mass_not_computed";
inline constexpr const char* kIssueInvalidBounds = "invalid_bounds";
inline constexpr const char* kIssueNoSimulationProxy = "no_simulation_proxy";

struct UAVPartManifest {
    std::string id;
    std::string name;
    std::string displayName;
    std::uint32_t formatVersion = kUAVPartFormatVersion;
    std::string source = "CADNext";
    std::string units = "metric";
    std::string partKind = "payload";
    std::string createdAt;  // ISO 8601 UTC
    std::string modifiedAt; // ISO 8601 UTC
    bool simulationReady = false;
    bool massComputed = false;
    bool attachmentPointsDefined = false;
    bool geometryStored = false;
    bool visualMeshStored = false;
    // Причины, по которым деталь ещё не готова к тестированию на БЛА
    // (коды kIssue*); пустой список при simulationReady = true.
    std::vector<std::string> readinessIssues;
};

struct UAVPartMaterial {
    std::string materialId;
    std::string displayName;
    double densityKgPerM3 = 0.0;
    std::string previewColor; // "#RRGGBB"
    std::string source;       // "default" | "userSelected"
};

// Метод расчёта массы для нормального случая (объём точной BRep-геометрии
// × плотность материала).
inline constexpr const char* kMassCalculationExact = "exact_geometry_volume_density";

struct UAVPartMassProperties {
    double volumeM3 = 0.0;
    double massKg = 0.0;
    Vector3 centerOfMass;
    Vector3 boundingBoxMin;
    Vector3 boundingBoxMax;
    double boundingWidth = 0.0;  // протяжённость по X, м
    double boundingDepth = 0.0;  // протяжённость по Y, м
    double boundingHeight = 0.0; // протяжённость по Z, м
    double dragPenalty = 0.0;
    double structuralRating = 1.0;
    double densityKgPerM3 = 0.0;
    std::string calculationMethod;
    bool valid = false;
};

struct UAVPartAttachmentPoint {
    std::string id;
    std::string name;
    std::string role;
    Vector3 localPosition;
    Vector3 localRotation;
    bool isSystem = true;
    bool isEnabled = true;
};

struct UAVPartSimulationProxy {
    std::string type = "box";
    Vector3 center;
    Vector3 size;
    std::string source = "mass_properties_bounds";
    bool valid = false;
};

struct UAVPartCompatibility {
    std::vector<std::string> allowedUAVTypes = {"multicopter", "fixedWing", "vtol"};
    std::vector<std::string> preferredMountRoles = {"payload", "generic"};
    // Не рассчитывается в UAVPart v1 — null в файле.
    std::optional<double> maxRecommendedSpeedMps;
    std::vector<std::string> warnings;
};

// Полное содержимое детали в памяти: вход writer'а и выход reader'а.
struct UAVPartDescriptor {
    UAVPartManifest manifest;
    UAVPartMaterial material;
    UAVPartMassProperties mass;
    std::vector<UAVPartAttachmentPoint> attachmentPoints;
    UAVPartSimulationProxy simulationProxy;
    UAVPartCompatibility compatibility;
};

struct UAVPartValidationResult {
    std::vector<std::string> errors;   // блокируют сохранение
    std::vector<std::string> warnings; // не блокируют
    bool ok() const { return errors.empty(); }
};

struct UAVPartWriteResult {
    std::string path;
    UAVPartDescriptor part;
    UAVPartValidationResult validation;
};

struct UAVPartReadResult {
    UAVPartHeader header;
    std::vector<UAVPartSectionEntry> sections;
    UAVPartDescriptor part;
};

// Краткая карточка для будущей библиотеки деталей (открывается без
// чтения геометрических секций).
struct UAVPartCatalogInfo {
    UAVPartManifest manifest;
    UAVPartMaterial material;
    UAVPartMassProperties mass;
};

// CRC32 (IEEE 802.3), используется для fileChecksum и checksum секций.
std::uint32_t uavpartCrc32(const std::uint8_t* data, std::size_t length,
                           std::uint32_t seed = 0);

// Производные поля дескриптора: simulationProxy из bounding box,
// dragPenalty/structuralRating, флаги манифеста и readinessIssues
// (simulationReady = масса + габариты + точка крепления + proxy).
void uavpartFinalizeDescriptor(UAVPartDescriptor& descriptor);

// Безопасный материал по умолчанию для деталей без выбранного материала
// (валидатор добавляет предупреждение для source == "default").
UAVPartMaterial uavpartDefaultMaterial();

// Имя роли точки крепления для файла ("payload", "camera", ...).
std::string uavpartAttachmentRoleName(AttachmentRole role);

// Русский текст для кода причины из readinessIssues (для UI).
std::string uavpartReadinessIssueText(const std::string& issueCode);

} // namespace cadnext::bridge
