#pragma once

#include <string>

#include "UAVPartJson.hpp"
#include "cadnext/bridge/UAVPartFormat.hpp"

// Внутреннее кодирование payload секций .uavpart (struct ↔ JSON).
// Используется writer'ом и reader'ом; не входит в публичный API.

namespace cadnext::bridge::sections {

std::string encodeManifest(const UAVPartManifest& manifest);
std::string encodeMaterial(const UAVPartMaterial& material);
std::string encodeMassProperties(const UAVPartMassProperties& mass);
std::string encodeAttachmentPoints(const std::vector<UAVPartAttachmentPoint>& points);
std::string encodeSimulationProxy(const UAVPartSimulationProxy& proxy);
std::string encodeCompatibility(const UAVPartCompatibility& compatibility);

bool decodeManifest(const std::string& payload, UAVPartManifest& out, std::string& error);
bool decodeMaterial(const std::string& payload, UAVPartMaterial& out, std::string& error);
bool decodeMassProperties(const std::string& payload, UAVPartMassProperties& out,
                          std::string& error);
bool decodeAttachmentPoints(const std::string& payload,
                            std::vector<UAVPartAttachmentPoint>& out, std::string& error);
bool decodeSimulationProxy(const std::string& payload, UAVPartSimulationProxy& out,
                           std::string& error);
bool decodeCompatibility(const std::string& payload, UAVPartCompatibility& out,
                         std::string& error);

std::string encodeVisualMesh(const UAVPartVisualMesh& mesh);
std::string encodeExactGeometry(const UAVPartExactGeometry& geo);

bool decodeVisualMesh(const std::string& payload, UAVPartVisualMesh& out, std::string& error);
bool decodeExactGeometry(const std::string& payload, UAVPartExactGeometry& out,
                         std::string& error);

} // namespace cadnext::bridge::sections
