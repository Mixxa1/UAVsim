#pragma once

#include <string>

#include "cadnext/Result.hpp"
#include "cadnext/bridge/UAVPartFormat.hpp"

namespace cadnext::bridge {

// Запись .uavpart одним физическим файлом. Порядок работы writePart:
//
//   1. финализировать дескриптор (производные поля, readiness);
//   2. пройти предзаписную валидацию (ошибки блокируют сохранение);
//   3. собрать байты: header + payload секций + таблица секций + CRC;
//   4. записать во временный файл рядом с целевым;
//   5. прочитать временный файл обратно через UAVPartReader и проверить
//      header/таблицу/контрольные суммы/массу;
//   6. только после успешной проверки переименовать в целевой путь.
//
// При любой ошибке временный файл удаляется — битый .uavpart не
// остаётся на диске; тексты ошибок — на русском.
class UAVPartWriter {
public:
    static constexpr std::uint32_t kWriterVersion = 1;

    Result<UAVPartWriteResult> writePart(const std::string& path,
                                         UAVPartDescriptor descriptor) const;
};

} // namespace cadnext::bridge
