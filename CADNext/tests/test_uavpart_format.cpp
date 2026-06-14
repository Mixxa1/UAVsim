// UAVPart v1: бинарный формат .uavpart — запись, контрольное чтение,
// валидация и обнаружение повреждений. Дескриптор собирается из готовых
// чисел (масса считается ядром в GUI-слое), поэтому тест не требует OCCT.

#include <cassert>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

#include "cadnext/bridge/UAVPartFormat.hpp"
#include "cadnext/bridge/UAVPartReader.hpp"
#include "cadnext/bridge/UAVPartValidator.hpp"
#include "cadnext/bridge/UAVPartWriter.hpp"

using namespace cadnext;
using namespace cadnext::bridge;

namespace {

std::string tempPartPath(const char* name) {
    return (std::filesystem::temp_directory_path() / name).string();
}

bool nearlyEqual(double a, double b, double tolerance = 1e-12) {
    return std::fabs(a - b) <= tolerance;
}

// Валидная деталь: брусок 120 × 60 × 80 мм из ABS (1050 кг/м³),
// центрированный на начале координат.
UAVPartDescriptor makeValidDescriptor() {
    UAVPartDescriptor descriptor;
    descriptor.manifest.id = "body-1";
    descriptor.manifest.name = "PayloadBox";
    descriptor.manifest.displayName = "PayloadBox";
    descriptor.manifest.createdAt = "2026-06-13T10:00:00Z";
    descriptor.manifest.modifiedAt = "2026-06-13T10:00:00Z";

    descriptor.material = uavpartDefaultMaterial();

    descriptor.mass.volumeM3 = 0.12 * 0.06 * 0.08;
    descriptor.mass.densityKgPerM3 = descriptor.material.densityKgPerM3;
    descriptor.mass.massKg = descriptor.mass.volumeM3 * descriptor.mass.densityKgPerM3;
    descriptor.mass.centerOfMass = {0.0, 0.0, 0.0};
    descriptor.mass.boundingBoxMin = {-0.06, -0.03, -0.04};
    descriptor.mass.boundingBoxMax = {0.06, 0.03, 0.04};
    descriptor.mass.calculationMethod = kMassCalculationExact;
    descriptor.mass.valid = true;
    return descriptor;
}

void testFinalizeComputesDerivedFields() {
    UAVPartDescriptor descriptor = makeValidDescriptor();
    uavpartFinalizeDescriptor(descriptor);

    assert(nearlyEqual(descriptor.mass.boundingWidth, 0.12));
    assert(nearlyEqual(descriptor.mass.boundingDepth, 0.06));
    assert(nearlyEqual(descriptor.mass.boundingHeight, 0.08));
    // Наибольшая грань габаритного бокса: 0.12 × 0.08.
    assert(nearlyEqual(descriptor.mass.dragPenalty, 0.12 * 0.08));
    assert(descriptor.mass.structuralRating > 0.0);
    assert(descriptor.mass.valid);

    assert(descriptor.simulationProxy.valid);
    assert(descriptor.simulationProxy.type == "box");
    assert(nearlyEqual(descriptor.simulationProxy.size.x, 0.12));
    assert(nearlyEqual(descriptor.simulationProxy.center.x, 0.0));

    // Без точек крепления деталь сохраняется, но не готова к симуляции.
    assert(descriptor.manifest.massComputed);
    assert(!descriptor.manifest.attachmentPointsDefined);
    assert(!descriptor.manifest.simulationReady);
    assert(descriptor.manifest.readinessIssues.size() == 1);
    assert(descriptor.manifest.readinessIssues[0] == kIssueNoAttachmentPoints);

    // С включённой точкой крепления — готова.
    UAVPartDescriptor ready = makeValidDescriptor();
    UAVPartAttachmentPoint point;
    point.id = "ap-1";
    point.name = "Mount";
    point.role = "payload";
    point.localPosition = {0.0, 0.0, 0.04};
    ready.attachmentPoints.push_back(point);
    uavpartFinalizeDescriptor(ready);
    assert(ready.manifest.attachmentPointsDefined);
    assert(ready.manifest.simulationReady);
    assert(ready.manifest.readinessIssues.empty());
}

void testWriteReadRoundTrip() {
    const std::string path = tempPartPath("cadnext_test_roundtrip.uavpart");
    std::filesystem::remove(path);

    UAVPartDescriptor descriptor = makeValidDescriptor();
    UAVPartAttachmentPoint point;
    point.id = "ap-1";
    point.name = "Крепление";
    point.role = "payload";
    point.localPosition = {0.01, -0.02, 0.04};
    point.localRotation = {0.0, 90.0, 0.0};
    point.isSystem = false;
    descriptor.attachmentPoints.push_back(point);

    const UAVPartWriter writer;
    const Result<UAVPartWriteResult> written = writer.writePart(path, descriptor);
    assert(written.isOk());
    assert(written.value().path == path);
    assert(std::filesystem::exists(path));
    // Временный файл не остаётся.
    assert(!std::filesystem::exists(path + ".tmp"));

    const UAVPartReader reader;

    const Result<UAVPartHeader> header = reader.readHeader(path);
    assert(header.isOk());
    assert(header.value().magicMatches());
    assert(header.value().formatVersion == kUAVPartFormatVersion);
    assert(header.value().sectionCount == 6);
    assert(header.value().fileSize == std::filesystem::file_size(path));

    const Result<std::vector<UAVPartSectionEntry>> table = reader.readSectionTable(path);
    assert(table.isOk());
    assert(table.value().size() == 6);

    const Result<UAVPartReadResult> full = reader.readFullPart(path);
    assert(full.isOk());
    const UAVPartDescriptor& part = full.value().part;

    assert(part.manifest.id == "body-1");
    assert(part.manifest.name == "PayloadBox");
    assert(part.manifest.source == "CADNext");
    assert(part.manifest.units == "metric");
    assert(part.manifest.partKind == "payload");
    assert(part.manifest.massComputed);
    assert(part.manifest.attachmentPointsDefined);
    assert(part.manifest.simulationReady);
    assert(!part.manifest.geometryStored);
    assert(!part.manifest.visualMeshStored);

    assert(part.material.materialId == "default_abs");
    assert(nearlyEqual(part.material.densityKgPerM3, 1050.0));

    assert(nearlyEqual(part.mass.volumeM3, 0.12 * 0.06 * 0.08));
    assert(nearlyEqual(part.mass.massKg, 0.12 * 0.06 * 0.08 * 1050.0));
    assert(part.mass.massKg > 0.0);
    assert(nearlyEqual(part.mass.boundingWidth, 0.12));
    assert(nearlyEqual(part.mass.boundingDepth, 0.06));
    assert(nearlyEqual(part.mass.boundingHeight, 0.08));
    assert(part.mass.calculationMethod == kMassCalculationExact);
    assert(part.mass.valid);

    assert(part.attachmentPoints.size() == 1);
    assert(part.attachmentPoints[0].id == "ap-1");
    assert(part.attachmentPoints[0].name == "Крепление");
    assert(part.attachmentPoints[0].role == "payload");
    assert(nearlyEqual(part.attachmentPoints[0].localPosition.y, -0.02));
    assert(nearlyEqual(part.attachmentPoints[0].localRotation.y, 90.0));
    assert(!part.attachmentPoints[0].isSystem);
    assert(part.attachmentPoints[0].isEnabled);

    assert(part.simulationProxy.valid);
    assert(part.simulationProxy.source == "mass_properties_bounds");
    assert(part.compatibility.allowedUAVTypes.size() == 3);
    assert(!part.compatibility.maxRecommendedSpeedMps.has_value());

    const Result<UAVPartCatalogInfo> catalog = reader.readCatalogInfo(path);
    assert(catalog.isOk());
    assert(catalog.value().manifest.id == "body-1");
    assert(nearlyEqual(catalog.value().mass.massKg, part.mass.massKg));

    std::filesystem::remove(path);
}

void testValidatorBlocksInvalidMass() {
    const UAVPartValidator validator;

    UAVPartDescriptor zeroMass = makeValidDescriptor();
    zeroMass.mass.volumeM3 = 0.0;
    zeroMass.mass.massKg = 0.0;
    uavpartFinalizeDescriptor(zeroMass);
    assert(!validator.validateForWrite(zeroMass).ok());

    UAVPartDescriptor nanMass = makeValidDescriptor();
    nanMass.mass.centerOfMass.x = std::numeric_limits<double>::quiet_NaN();
    uavpartFinalizeDescriptor(nanMass);
    assert(!validator.validateForWrite(nanMass).ok());

    UAVPartDescriptor noDensity = makeValidDescriptor();
    noDensity.material.densityKgPerM3 = 0.0;
    uavpartFinalizeDescriptor(noDensity);
    assert(!validator.validateForWrite(noDensity).ok());

    // Валидная деталь без точек крепления: ошибок нет, есть
    // предупреждения (default-материал + точка крепления).
    UAVPartDescriptor valid = makeValidDescriptor();
    uavpartFinalizeDescriptor(valid);
    const UAVPartValidationResult result = validator.validateForWrite(valid);
    assert(result.ok());
    assert(result.warnings.size() >= 2);
}

void testWriterRefusesInvalidDescriptor() {
    const std::string path = tempPartPath("cadnext_test_invalid.uavpart");
    std::filesystem::remove(path);

    UAVPartDescriptor descriptor = makeValidDescriptor();
    descriptor.mass.valid = false;
    descriptor.mass.massKg = 0.0;

    const UAVPartWriter writer;
    const Result<UAVPartWriteResult> written = writer.writePart(path, descriptor);
    assert(!written.isOk());
    // Битый файл не остаётся на диске.
    assert(!std::filesystem::exists(path));
    assert(!std::filesystem::exists(path + ".tmp"));
}

void testReaderDetectsCorruption() {
    const std::string path = tempPartPath("cadnext_test_corrupt.uavpart");
    std::filesystem::remove(path);

    const UAVPartWriter writer;
    assert(writer.writePart(path, makeValidDescriptor()).isOk());

    const UAVPartReader reader;

    // Повреждение payload в середине файла.
    {
        std::fstream stream(path, std::ios::binary | std::ios::in | std::ios::out);
        stream.seekp(static_cast<std::streamoff>(kUAVPartHeaderSize + 10));
        const char garbage = '\xFF';
        stream.write(&garbage, 1);
    }
    assert(!reader.readFullPart(path).isOk());
    assert(!reader.readHeader(path).isOk());

    // Усечённый файл.
    assert(writer.writePart(path, makeValidDescriptor()).isOk());
    {
        const auto fullSize = std::filesystem::file_size(path);
        std::filesystem::resize_file(path, fullSize / 2);
    }
    assert(!reader.readFullPart(path).isOk());

    // Чужой файл с неверной сигнатурой.
    {
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        const std::string junk(256, 'x');
        stream.write(junk.data(), static_cast<std::streamsize>(junk.size()));
    }
    const Result<UAVPartReadResult> junkRead = reader.readFullPart(path);
    assert(!junkRead.isOk());
    assert(junkRead.error().message.find("повреждён") != std::string::npos);

    std::filesystem::remove(path);
}

} // namespace

int main() {
    testFinalizeComputesDerivedFields();
    testWriteReadRoundTrip();
    testValidatorBlocksInvalidMass();
    testWriterRefusesInvalidDescriptor();
    testReaderDetectsCorruption();
    std::printf("test_uavpart_format: OK\n");
    return 0;
}
