#pragma once

#include "cadnext/bridge/UAVPartFormat.hpp"

namespace cadnext::bridge {

// Валидация детали до записи и после контрольного чтения. Тексты ошибок
// и предупреждений — пользовательские, на русском. Ошибки блокируют
// сохранение; предупреждения не блокируют, но simulationReady может
// быть false.
class UAVPartValidator {
public:
    // Перед сохранением: дескриптор должен быть финализирован
    // (uavpartFinalizeDescriptor).
    UAVPartValidationResult validateForWrite(const UAVPartDescriptor& descriptor) const;

    // После сохранения: содержимое, прочитанное обратно reader'ом
    // (magic/версия/таблица секций/контрольные суммы уже проверены им).
    UAVPartValidationResult validateSavedPart(const UAVPartReadResult& readResult) const;
};

} // namespace cadnext::bridge
