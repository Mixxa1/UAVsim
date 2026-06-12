#pragma once

#include <string>
#include <vector>

#include "cadnext/Result.hpp"
#include "cadnext/bridge/UAVPartFormat.hpp"

namespace cadnext::bridge {

// Чтение .uavpart. Каждый вызов проверяет magic, версию формата,
// контрольную сумму файла, корректность таблицы секций и CRC payload'ов;
// повреждённый или чужой файл возвращает ошибку
// "Файл детали повреждён или имеет неподдерживаемый формат".
class UAVPartReader {
public:
    Result<UAVPartHeader> readHeader(const std::string& path) const;
    Result<std::vector<UAVPartSectionEntry>> readSectionTable(const std::string& path) const;
    Result<UAVPartManifest> readManifest(const std::string& path) const;
    Result<UAVPartMassProperties> readMassProperties(const std::string& path) const;
    // Карточка для библиотеки деталей: манифест + материал + масса.
    Result<UAVPartCatalogInfo> readCatalogInfo(const std::string& path) const;
    Result<UAVPartReadResult> readFullPart(const std::string& path) const;
};

} // namespace cadnext::bridge
