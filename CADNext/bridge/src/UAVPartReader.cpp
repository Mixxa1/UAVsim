#include "cadnext/bridge/UAVPartReader.hpp"

#include <cstring>
#include <fstream>
#include <optional>

#include "UAVPartBinary.hpp"
#include "UAVPartSections.hpp"

namespace cadnext::bridge {

namespace {

constexpr const char* kCorruptMessage =
    "Файл детали повреждён или имеет неподдерживаемый формат";

template <typename T>
Result<T> corrupt(const std::string& detail) {
    std::string message = kCorruptMessage;
    if (!detail.empty()) {
        message += " (" + detail + ")";
    }
    return Result<T>::fail({ErrorCode::SerializationFailed, std::move(message)});
}

struct LoadedFile {
    std::vector<std::uint8_t> bytes;
    UAVPartHeader header;
    std::vector<UAVPartSectionEntry> sections;
};

// Загружает файл и проверяет всё, что не зависит от содержимого секций:
// magic, версию формата, контрольную сумму файла, границы таблицы секций
// и CRC каждого payload'а.
Result<LoadedFile> loadValidated(const std::string& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return Result<LoadedFile>::fail(
            {ErrorCode::NotFound, "Не удалось открыть файл детали: " + path});
    }
    LoadedFile loaded;
    stream.seekg(0, std::ios::end);
    const std::streamoff size = stream.tellg();
    stream.seekg(0, std::ios::beg);
    if (size < static_cast<std::streamoff>(kUAVPartHeaderSize)) {
        return corrupt<LoadedFile>("файл меньше заголовка");
    }
    loaded.bytes.resize(static_cast<std::size_t>(size));
    stream.read(reinterpret_cast<char*>(loaded.bytes.data()), size);
    if (!stream) {
        return corrupt<LoadedFile>("не удалось прочитать файл целиком");
    }

    if (!binary::decodeHeader(loaded.bytes, loaded.header)) {
        return corrupt<LoadedFile>("повреждён заголовок");
    }
    if (!loaded.header.magicMatches()) {
        return corrupt<LoadedFile>("неверная сигнатура файла");
    }
    if (loaded.header.formatVersion != kUAVPartFormatVersion) {
        return corrupt<LoadedFile>("неподдерживаемая версия формата " +
                                   std::to_string(loaded.header.formatVersion));
    }
    if (loaded.header.fileSize != loaded.bytes.size()) {
        return corrupt<LoadedFile>("размер файла не совпадает с заголовком");
    }
    if (binary::computeFileChecksum(loaded.bytes) != loaded.header.fileChecksum) {
        return corrupt<LoadedFile>("контрольная сумма файла не совпадает");
    }

    const std::uint64_t tableOffset = loaded.header.sectionTableOffset;
    const std::uint64_t tableLength =
        static_cast<std::uint64_t>(loaded.header.sectionCount) * kUAVPartSectionEntrySize;
    if (tableOffset < kUAVPartHeaderSize || tableOffset > loaded.bytes.size() ||
        tableLength > loaded.bytes.size() - tableOffset) {
        return corrupt<LoadedFile>("повреждена таблица секций");
    }
    for (std::uint32_t i = 0; i < loaded.header.sectionCount; ++i) {
        const std::size_t entryOffset =
            static_cast<std::size_t>(tableOffset) + i * kUAVPartSectionEntrySize;
        UAVPartSectionEntry entry = binary::decodeSectionEntry(loaded.bytes, entryOffset);
        if (entry.offset < kUAVPartHeaderSize || entry.offset > loaded.bytes.size() ||
            entry.length > loaded.bytes.size() - entry.offset) {
            return corrupt<LoadedFile>("секция выходит за пределы файла");
        }
        const std::uint32_t payloadCrc = uavpartCrc32(
            loaded.bytes.data() + entry.offset, static_cast<std::size_t>(entry.length));
        if (payloadCrc != entry.checksum) {
            return corrupt<LoadedFile>("контрольная сумма секции не совпадает");
        }
        loaded.sections.push_back(entry);
    }
    return Result<LoadedFile>::ok(std::move(loaded));
}

std::optional<std::string> sectionPayload(const LoadedFile& loaded, UAVPartSectionType type) {
    for (const UAVPartSectionEntry& entry : loaded.sections) {
        if (entry.type == type) {
            return std::string(
                reinterpret_cast<const char*>(loaded.bytes.data() + entry.offset),
                static_cast<std::size_t>(entry.length));
        }
    }
    return std::nullopt;
}

template <typename T, typename Decoder>
Result<T> decodeRequiredSection(const LoadedFile& loaded, UAVPartSectionType type,
                                const char* sectionName, Decoder decoder) {
    const std::optional<std::string> payload = sectionPayload(loaded, type);
    if (!payload) {
        return corrupt<T>(std::string("отсутствует секция ") + sectionName);
    }
    T value{};
    std::string error;
    if (!decoder(*payload, value, error)) {
        return corrupt<T>(std::string("секция ") + sectionName + ": " + error);
    }
    return Result<T>::ok(std::move(value));
}

} // namespace

Result<UAVPartHeader> UAVPartReader::readHeader(const std::string& path) const {
    Result<LoadedFile> loaded = loadValidated(path);
    if (!loaded.isOk()) {
        return Result<UAVPartHeader>::fail(loaded.error());
    }
    return Result<UAVPartHeader>::ok(loaded.value().header);
}

Result<std::vector<UAVPartSectionEntry>> UAVPartReader::readSectionTable(
    const std::string& path) const {
    Result<LoadedFile> loaded = loadValidated(path);
    if (!loaded.isOk()) {
        return Result<std::vector<UAVPartSectionEntry>>::fail(loaded.error());
    }
    return Result<std::vector<UAVPartSectionEntry>>::ok(loaded.value().sections);
}

Result<UAVPartManifest> UAVPartReader::readManifest(const std::string& path) const {
    Result<LoadedFile> loaded = loadValidated(path);
    if (!loaded.isOk()) {
        return Result<UAVPartManifest>::fail(loaded.error());
    }
    return decodeRequiredSection<UAVPartManifest>(
        loaded.value(), UAVPartSectionType::Manifest, "Manifest", sections::decodeManifest);
}

Result<UAVPartMassProperties> UAVPartReader::readMassProperties(const std::string& path) const {
    Result<LoadedFile> loaded = loadValidated(path);
    if (!loaded.isOk()) {
        return Result<UAVPartMassProperties>::fail(loaded.error());
    }
    return decodeRequiredSection<UAVPartMassProperties>(
        loaded.value(), UAVPartSectionType::MassProperties, "MassProperties",
        sections::decodeMassProperties);
}

Result<UAVPartCatalogInfo> UAVPartReader::readCatalogInfo(const std::string& path) const {
    Result<LoadedFile> loaded = loadValidated(path);
    if (!loaded.isOk()) {
        return Result<UAVPartCatalogInfo>::fail(loaded.error());
    }
    const LoadedFile& file = loaded.value();
    UAVPartCatalogInfo info;
    Result<UAVPartManifest> manifest = decodeRequiredSection<UAVPartManifest>(
        file, UAVPartSectionType::Manifest, "Manifest", sections::decodeManifest);
    if (!manifest.isOk()) {
        return Result<UAVPartCatalogInfo>::fail(manifest.error());
    }
    info.manifest = manifest.value();
    Result<UAVPartMaterial> material = decodeRequiredSection<UAVPartMaterial>(
        file, UAVPartSectionType::Material, "Material", sections::decodeMaterial);
    if (!material.isOk()) {
        return Result<UAVPartCatalogInfo>::fail(material.error());
    }
    info.material = material.value();
    Result<UAVPartMassProperties> mass = decodeRequiredSection<UAVPartMassProperties>(
        file, UAVPartSectionType::MassProperties, "MassProperties",
        sections::decodeMassProperties);
    if (!mass.isOk()) {
        return Result<UAVPartCatalogInfo>::fail(mass.error());
    }
    info.mass = mass.value();
    return Result<UAVPartCatalogInfo>::ok(std::move(info));
}

Result<UAVPartReadResult> UAVPartReader::readFullPart(const std::string& path) const {
    Result<LoadedFile> loaded = loadValidated(path);
    if (!loaded.isOk()) {
        return Result<UAVPartReadResult>::fail(loaded.error());
    }
    const LoadedFile& file = loaded.value();

    UAVPartReadResult result;
    result.header = file.header;
    result.sections = file.sections;

    Result<UAVPartManifest> manifest = decodeRequiredSection<UAVPartManifest>(
        file, UAVPartSectionType::Manifest, "Manifest", sections::decodeManifest);
    if (!manifest.isOk()) {
        return Result<UAVPartReadResult>::fail(manifest.error());
    }
    result.part.manifest = manifest.value();

    Result<UAVPartMaterial> material = decodeRequiredSection<UAVPartMaterial>(
        file, UAVPartSectionType::Material, "Material", sections::decodeMaterial);
    if (!material.isOk()) {
        return Result<UAVPartReadResult>::fail(material.error());
    }
    result.part.material = material.value();

    Result<UAVPartMassProperties> mass = decodeRequiredSection<UAVPartMassProperties>(
        file, UAVPartSectionType::MassProperties, "MassProperties",
        sections::decodeMassProperties);
    if (!mass.isOk()) {
        return Result<UAVPartReadResult>::fail(mass.error());
    }
    result.part.mass = mass.value();

    Result<std::vector<UAVPartAttachmentPoint>> attachments =
        decodeRequiredSection<std::vector<UAVPartAttachmentPoint>>(
            file, UAVPartSectionType::AttachmentPoints, "AttachmentPoints",
            sections::decodeAttachmentPoints);
    if (!attachments.isOk()) {
        return Result<UAVPartReadResult>::fail(attachments.error());
    }
    result.part.attachmentPoints = attachments.value();

    Result<UAVPartSimulationProxy> proxy = decodeRequiredSection<UAVPartSimulationProxy>(
        file, UAVPartSectionType::SimulationProxy, "SimulationProxy",
        sections::decodeSimulationProxy);
    if (!proxy.isOk()) {
        return Result<UAVPartReadResult>::fail(proxy.error());
    }
    result.part.simulationProxy = proxy.value();

    Result<UAVPartCompatibility> compatibility = decodeRequiredSection<UAVPartCompatibility>(
        file, UAVPartSectionType::Compatibility, "Compatibility",
        sections::decodeCompatibility);
    if (!compatibility.isOk()) {
        return Result<UAVPartReadResult>::fail(compatibility.error());
    }
    result.part.compatibility = compatibility.value();

    return Result<UAVPartReadResult>::ok(std::move(result));
}

} // namespace cadnext::bridge
