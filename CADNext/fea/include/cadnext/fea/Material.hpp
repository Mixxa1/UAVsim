#pragma once

#include <optional>
#include <string>
#include <vector>

namespace cadnext::fea {

// Linear-elastic isotropic material with the strengths the assessment needs.
//
// ⚠️ These are *typical* properties, not design allowables. A-/B-basis values (MMPDS,
// CMH-17) are statistically reduced and lower; a margin computed against a typical value
// is a simulator's engineering estimate, never a certification claim. The UI must say so.
struct IsotropicMaterial {
    std::string id;
    std::string displayName;
    double densityKgPerM3 = 0.0;
    double youngsModulusPa = 0.0;
    double poissonRatio = 0.0;
    // Absent for materials that are linear to failure (laminates, most printed polymers):
    // they are checked against ultimate only, never against an invented "yield".
    std::optional<double> yieldStrengthPa;
    double ultimateStrengthPa = 0.0;
    // The real material is anisotropic (a laminate, a printed part) and is modelled here
    // with in-plane effective constants. Stiffness is then an estimate and interlaminar or
    // layer-adhesion failure is not represented at all — every result carries a warning.
    bool isotropicApproximation = false;
    std::string source;
    std::string notes;

    bool isValid() const {
        return densityKgPerM3 > 0.0 && youngsModulusPa > 0.0 && poissonRatio > -1.0
               && poissonRatio < 0.5 && ultimateStrengthPa > 0.0
               && (!yieldStrengthPa || (*yieldStrengthPa > 0.0 && *yieldStrengthPa <= ultimateStrengthPa));
    }
};

// Version of the table below. Recorded with every structural result (spec §17): a margin
// that moves after an update must be traceable to a changed property.
inline constexpr int kMaterialDatabaseVersion = 1;

const std::vector<IsotropicMaterial>& materialLibrary();

// Accepts library ids and the CAD part defaults that predate this table ("default_abs").
std::optional<IsotropicMaterial> findMaterial(const std::string& id);

} // namespace cadnext::fea
