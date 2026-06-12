#include "UAVPartBinary.hpp"

#include <cstring>

namespace cadnext::bridge::binary {

void appendU32(std::vector<std::uint8_t>& out, std::uint32_t value) {
    out.push_back(static_cast<std::uint8_t>(value & 0xFFu));
    out.push_back(static_cast<std::uint8_t>((value >> 8) & 0xFFu));
    out.push_back(static_cast<std::uint8_t>((value >> 16) & 0xFFu));
    out.push_back(static_cast<std::uint8_t>((value >> 24) & 0xFFu));
}

void appendU64(std::vector<std::uint8_t>& out, std::uint64_t value) {
    for (int shift = 0; shift < 64; shift += 8) {
        out.push_back(static_cast<std::uint8_t>((value >> shift) & 0xFFu));
    }
}

std::uint32_t readU32(const std::vector<std::uint8_t>& bytes, std::size_t offset) {
    std::uint32_t value = 0;
    for (int i = 3; i >= 0; --i) {
        value = (value << 8) | bytes[offset + static_cast<std::size_t>(i)];
    }
    return value;
}

std::uint64_t readU64(const std::vector<std::uint8_t>& bytes, std::size_t offset) {
    std::uint64_t value = 0;
    for (int i = 7; i >= 0; --i) {
        value = (value << 8) | bytes[offset + static_cast<std::size_t>(i)];
    }
    return value;
}

std::vector<std::uint8_t> encodeHeader(const UAVPartHeader& header) {
    std::vector<std::uint8_t> out;
    out.reserve(kUAVPartHeaderSize);
    for (char c : header.magic) {
        out.push_back(static_cast<std::uint8_t>(c));
    }
    appendU32(out, header.formatVersion);
    appendU32(out, header.writerVersion);
    appendU32(out, header.sectionCount);
    appendU32(out, header.flags);
    appendU64(out, header.sectionTableOffset);
    appendU64(out, header.fileSize);
    appendU32(out, header.fileChecksum);
    out.resize(kUAVPartHeaderSize, 0); // reserved-байты до 64
    return out;
}

bool decodeHeader(const std::vector<std::uint8_t>& bytes, UAVPartHeader& out) {
    if (bytes.size() < kUAVPartHeaderSize) {
        return false;
    }
    std::memcpy(out.magic, bytes.data(), sizeof(out.magic));
    out.formatVersion = readU32(bytes, 8);
    out.writerVersion = readU32(bytes, 12);
    out.sectionCount = readU32(bytes, 16);
    out.flags = readU32(bytes, 20);
    out.sectionTableOffset = readU64(bytes, 24);
    out.fileSize = readU64(bytes, 32);
    out.fileChecksum = readU32(bytes, kFileChecksumOffset);
    return true;
}

void appendSectionEntry(std::vector<std::uint8_t>& out, const UAVPartSectionEntry& entry) {
    appendU32(out, static_cast<std::uint32_t>(entry.type));
    appendU32(out, entry.version);
    appendU64(out, entry.offset);
    appendU64(out, entry.length);
    appendU32(out, entry.checksum);
    appendU32(out, 0); // reserved
}

UAVPartSectionEntry decodeSectionEntry(const std::vector<std::uint8_t>& bytes,
                                       std::size_t offset) {
    UAVPartSectionEntry entry;
    entry.type = static_cast<UAVPartSectionType>(readU32(bytes, offset));
    entry.version = readU32(bytes, offset + 4);
    entry.offset = readU64(bytes, offset + 8);
    entry.length = readU64(bytes, offset + 16);
    entry.checksum = readU32(bytes, offset + 24);
    return entry;
}

std::uint32_t computeFileChecksum(std::vector<std::uint8_t> bytes) {
    if (bytes.size() >= kFileChecksumOffset + 4) {
        bytes[kFileChecksumOffset] = 0;
        bytes[kFileChecksumOffset + 1] = 0;
        bytes[kFileChecksumOffset + 2] = 0;
        bytes[kFileChecksumOffset + 3] = 0;
    }
    return uavpartCrc32(bytes.data(), bytes.size());
}

} // namespace cadnext::bridge::binary
