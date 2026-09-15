#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/FeaTypes.hpp"
#include "cadnext/fea/StructuralPresentation.hpp"

#include <array>
#include <string>
#include <vector>

namespace cadnext::fea {

// A "cadnext-structural-field/1" file in memory — what a viewer draws. The presentation values
// (colour stops, overflow colour, deformation magnification) are read from the file, not
// recomputed, so every viewer shows what the solver side decided.
struct StructuralFieldFile {
    std::vector<Vec3> nodes;
    std::vector<Vec3> displacement;
    std::vector<double> vonMisesPa;
    std::vector<std::array<int, 3>> triangles;

    double allowableStressPa = 0.0;
    std::string allowableBasis; // "yield" | "ultimateOverFactorOfSafety"
    double factorOfSafety = 1.5;
    Vec3 criticalPoint;
    double boundingDiagonalM = 0.0;
    double maxDisplacementM = 0.0;

    std::vector<ColorStop> colorStops;
    ColorStop overflowColor;
    double deformationAutoScale = 1.0;

    // Colour of one node for the given quantity, from the file's own stops. Utilisation is
    // absolute (allowable-anchored); stress and displacement are auto-ranged over this field.
    std::array<float, 3> utilizationColor(int node) const;
    std::array<float, 3> rampColor(double fraction) const;
    double maxVonMisesPa() const;
};

Result<StructuralFieldFile> parseStructuralField(const std::string& jsonText);

// A "cadnext-modal-field/1" file in memory. Mode shapes are dimensionless (largest displacement
// of each = 1); `displayAmplitudeM` is the conventional on-screen amplitude every viewer uses,
// and colour is relative amplitude on the file's scale.
struct ModalFieldMode {
    double frequencyHz = 0.0;
    std::vector<Vec3> shape;
};

struct ModalFieldFile {
    std::vector<Vec3> nodes;
    std::vector<std::array<int, 3>> triangles;
    std::vector<ModalFieldMode> modes;
    double boundingDiagonalM = 0.0;
    double displayAmplitudeM = 0.0;
    std::vector<ColorStop> colorStops;
};

Result<ModalFieldFile> parseModalField(const std::string& jsonText);

// Colour at `fraction` (0…1) of a scale.
std::array<float, 3> rampColor(const std::vector<ColorStop>& stops, double fraction);

} // namespace cadnext::fea
