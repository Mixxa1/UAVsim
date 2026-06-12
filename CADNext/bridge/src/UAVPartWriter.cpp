#include "cadnext/bridge/UAVPartWriter.hpp"

#include <cstring>
#include <filesystem>
#include <fstream>
#include <system_error>
#include <utility>
#include <vector>

#include "UAVPartBinary.hpp"
#include "UAVPartSections.hpp"
#include "cadnext/bridge/UAVPartReader.hpp"
#include "cadnext/bridge/UAVPartValidator.hpp"

namespace cadnext::bridge {

namespace {

std::string joinMessages(const std::vector<std::string>& messages) {
    std::string joined;
    for (const std::string& message : messages) {
        if (!joined.empty()) {
            joined += "\n";
        }
        joined += message;
    }
    return joined;
}

void removeFileQuietly(const std::string& path) {
    std::error_code ec;
    std::filesystem::remove(path, ec);
}

// Собирает весь файл в памяти: header (с пока нулевыми offset'ами),
// payload секций подряд, таблица секций в конце, затем правка header'а
// и контрольной суммы файла.
std::vector<std::uint8_t> serializePart(const UAVPartDescriptor& descriptor) {
    struct PendingSection {
        UAVPartSectionType type;
        std::string payload;
    };
    // UAVPart v1: ExactGeometry и VisualMesh не записываются (placeholder
    // без fake-данных; статус отражён в манифесте).
    const PendingSection pending[] = {
        {UAVPartSectionType::Manifest, sections::encodeManifest(descriptor.manifest)},
        {UAVPartSectionType::Material, sections::encodeMaterial(descriptor.material)},
        {UAVPartSectionType::MassProperties,
         sections::encodeMassProperties(descriptor.mass)},
        {UAVPartSectionType::AttachmentPoints,
         sections::encodeAttachmentPoints(descriptor.attachmentPoints)},
        {UAVPartSectionType::SimulationProxy,
         sections::encodeSimulationProxy(descriptor.simulationProxy)},
        {UAVPartSectionType::Compatibility,
         sections::encodeCompatibility(descriptor.compatibility)},
    };

    UAVPartHeader header;
    std::memcpy(header.magic, kUAVPartMagic, sizeof(header.magic));
    header.formatVersion = kUAVPartFormatVersion;
    header.writerVersion = UAVPartWriter::kWriterVersion;
    header.sectionCount = static_cast<std::uint32_t>(std::size(pending));

    std::vector<std::uint8_t> bytes(kUAVPartHeaderSize, 0);
    std::vector<UAVPartSectionEntry> entries;
    for (const PendingSection& section : pending) {
        UAVPartSectionEntry entry;
        entry.type = section.type;
        entry.version = 1;
        entry.offset = bytes.size();
        entry.length = section.payload.size();
        entry.checksum = uavpartCrc32(
            reinterpret_cast<const std::uint8_t*>(section.payload.data()),
            section.payload.size());
        entries.push_back(entry);
        bytes.insert(bytes.end(), section.payload.begin(), section.payload.end());
    }

    header.sectionTableOffset = bytes.size();
    for (const UAVPartSectionEntry& entry : entries) {
        binary::appendSectionEntry(bytes, entry);
    }
    header.fileSize = bytes.size();

    const std::vector<std::uint8_t> headerBytes = binary::encodeHeader(header);
    std::copy(headerBytes.begin(), headerBytes.end(), bytes.begin());

    const std::uint32_t checksum = binary::computeFileChecksum(bytes);
    bytes[binary::kFileChecksumOffset] = static_cast<std::uint8_t>(checksum & 0xFFu);
    bytes[binary::kFileChecksumOffset + 1] =
        static_cast<std::uint8_t>((checksum >> 8) & 0xFFu);
    bytes[binary::kFileChecksumOffset + 2] =
        static_cast<std::uint8_t>((checksum >> 16) & 0xFFu);
    bytes[binary::kFileChecksumOffset + 3] =
        static_cast<std::uint8_t>((checksum >> 24) & 0xFFu);
    return bytes;
}

} // namespace

Result<UAVPartWriteResult> UAVPartWriter::writePart(const std::string& path,
                                                    UAVPartDescriptor descriptor) const {
    uavpartFinalizeDescriptor(descriptor);

    const UAVPartValidator validator;
    UAVPartValidationResult validation = validator.validateForWrite(descriptor);
    if (!validation.ok()) {
        return Result<UAVPartWriteResult>::fail(
            {ErrorCode::InvalidArgument, joinMessages(validation.errors)});
    }

    const std::vector<std::uint8_t> bytes = serializePart(descriptor);

    const std::string tempPath = path + ".tmp";
    {
        std::ofstream stream(tempPath, std::ios::binary | std::ios::trunc);
        if (!stream) {
            return Result<UAVPartWriteResult>::fail(
                {ErrorCode::SerializationFailed,
                 "Не удалось создать файл для записи: " + tempPath});
        }
        stream.write(reinterpret_cast<const char*>(bytes.data()),
                     static_cast<std::streamsize>(bytes.size()));
        stream.flush();
        if (!stream) {
            stream.close();
            removeFileQuietly(tempPath);
            return Result<UAVPartWriteResult>::fail(
                {ErrorCode::SerializationFailed,
                 "Не удалось записать файл детали: " + tempPath});
        }
    }

    // Контрольное чтение временного файла до переименования: на диск
    // никогда не попадает .uavpart, который не прошёл проверку.
    const UAVPartReader reader;
    const Result<UAVPartReadResult> readBack = reader.readFullPart(tempPath);
    if (!readBack.isOk()) {
        removeFileQuietly(tempPath);
        return Result<UAVPartWriteResult>::fail(
            {ErrorCode::SerializationFailed,
             "Проверка сохранённого файла не пройдена: " + readBack.error().message});
    }
    const UAVPartValidationResult savedValidation =
        validator.validateSavedPart(readBack.value());
    if (!savedValidation.ok()) {
        removeFileQuietly(tempPath);
        return Result<UAVPartWriteResult>::fail(
            {ErrorCode::SerializationFailed,
             "Проверка сохранённого файла не пройдена: " +
                 joinMessages(savedValidation.errors)});
    }

    std::error_code ec;
    std::filesystem::rename(tempPath, path, ec);
    if (ec) {
        removeFileQuietly(tempPath);
        return Result<UAVPartWriteResult>::fail(
            {ErrorCode::SerializationFailed,
             "Не удалось сохранить файл детали: " + ec.message()});
    }

    UAVPartWriteResult result;
    result.path = path;
    result.part = std::move(descriptor);
    result.validation = std::move(validation);
    return Result<UAVPartWriteResult>::ok(std::move(result));
}

} // namespace cadnext::bridge
