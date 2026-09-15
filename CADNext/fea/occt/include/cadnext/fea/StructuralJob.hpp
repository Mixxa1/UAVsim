#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/ModalStudy.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <optional>
#include <string>

// File contract between the Workbench (Swift) and the structural solver (this library and the
// `cadnext_structural` command line tool).
//
//   job    "cadnext-structural-job/1"     what to calculate; "analysis" is "static" (default) or
//                                         "modal"
//   result "cadnext-structural-result/1"  static: what the solver concluded — the solver half of
//                                         an Engineering Validation TestRecord (spec §4); the
//                                         Validation Engine stamps inputs and upstream on it
//          "cadnext-modal-result/1"       modal: the same envelope (outcome, metrics, warnings,
//                                         settings, fieldRef) plus modes and resonance findings
//   field  "cadnext-structural-field/1"   surface displacement and stress for display
//          "cadnext-modal-field/1"        surface mode shapes for display
//
// Examples live in CADNext/fea/schema/. Both sides are tested against those files, so a key
// renamed on one side fails a test on the other.

namespace cadnext::fea {

inline constexpr const char* kStructuralJobSchema = "cadnext-structural-job/1";
inline constexpr const char* kStructuralResultSchema = "cadnext-structural-result/1";
inline constexpr const char* kStructuralFieldSchema = "cadnext-structural-field/1";
inline constexpr const char* kModalResultSchema = "cadnext-modal-result/1";
inline constexpr const char* kModalFieldSchema = "cadnext-modal-field/1";

enum class StructuralAnalysis { Static, Modal };

struct ModalJobSettings {
    int modeCount = 0;
    // Rotors become their 1P and NP bands; other excitation (2P, engine orders) is listed as
    // explicit bands.
    std::vector<RotorExcitation> rotors;
    std::vector<ExcitationBand> bands;
    double separationMargin = 0.0;
    // Equipment mass on faces: {"face": "face-3", "massKg": 0.18}.
    std::vector<AttachedMass> attachedMasses;

    std::vector<ExcitationBand> allBands() const;
};

struct StructuralJob {
    StructuralAnalysis analysis = StructuralAnalysis::Static;
    std::string geometryPath;   // absolute after parsing
    std::string geometryFormat; // "brep" | "uavpart"
    // Library id; when absent a .uavpart's own material is used.
    std::optional<std::string> materialId;
    // Modal: only the supports are used, and loads are refused — a linear modal analysis does not
    // see them, and a job carrying loads would suggest it did.
    StructuralLoadCase loadCase;
    StructuralStudySettings settings;
    ModalJobSettings modal;
    std::string resultPath;
    std::string fieldPath;
    // Optional self-contained HTML report (verdict, uncertainty, 3D utilisation plot).
    std::string reportPath;
};

ModalStudySettings modalStudySettings(const StructuralJob& job);

// Relative paths resolve against `baseDirectory` (the job file's folder).
Result<StructuralJob> parseStructuralJob(const std::string& jsonText, const std::string& baseDirectory);

// Writes a job file that parseStructuralJob reads back to the same job. Paths are written as
// stored in the job (relative ones stay relative to the file's folder).
std::string structuralJobJson(const StructuralJob& job);

std::string structuralResultJson(const StructuralStudyResult& result, const StructuralJob& job,
                                 const std::string& fieldReference);

// A calculation that did not complete is ERROR, never FAIL (spec §16).
std::string structuralErrorJson(const std::string& message, const StructuralJob* job);

std::string structuralFieldJson(const StructuralStudyResult& result);

// Modal verdict: WARNING when a mode overlaps an excitation band (spec §6.2), when no band was
// given (resonance then is not checked at all), when a band reaches above the last computed mode
// (modes above it are not checked), or when a frequency has no usable mesh uncertainty; PASS
// otherwise. Never FAIL — a computed overlap is a risk for the vibration test
// to confirm, not a demonstrated failure.
std::string modalResultJson(const ModalStudyResult& result, const StructuralJob& job, const std::string& fieldReference);

std::string modalFieldJson(const ModalStudyResult& result);

} // namespace cadnext::fea
