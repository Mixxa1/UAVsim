#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "cadnext/bridge/UAVPartFormat.hpp"

// Внутренний бинарный слой .uavpart: little-endian кодирование заголовка
// и таблицы секций. Не входит в публичный API моста.

namespace cadnext::bridge::binary {

void appendU32(std::vector<std::uint8_t>& out, std::uint32_t value);
void appendU64(std::vector<std::uint8_t>& out, std::uint64_t value);
std::uint32_t readU32(const std::vector<std::uint8_t>& bytes, std::size_t offset);
std::uint64_t readU64(const std::vector<std::uint8_t>& bytes, std::size_t offset);

// Заголовок фиксированного размера kUAVPartHeaderSize (64 байта).
std::vector<std::uint8_t> encodeHeader(const UAVPartHeader& header);
bool decodeHeader(const std::vector<std::uint8_t>& bytes, UAVPartHeader& out);

// Запись таблицы секций фиксированного размера kUAVPartSectionEntrySize.
void appendSectionEntry(std::vector<std::uint8_t>& out, const UAVPartSectionEntry& entry);
UAVPartSectionEntry decodeSectionEntry(const std::vector<std::uint8_t>& bytes,
                                       std::size_t offset);

// CRC32 всего файла с обнулённым полем fileChecksum (смещение 40).
std::uint32_t computeFileChecksum(std::vector<std::uint8_t> bytes);

inline constexpr std::size_t kFileChecksumOffset = 40;

} // namespace cadnext::bridge::binary
