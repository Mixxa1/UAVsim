#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/Vector3.hpp"
#include "cadnext/bridge/ConstructionExport.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

#include <string>
#include <vector>

namespace cadnext::kernel {
class Kernel;
}

// Builds a version-2 `.uavframe` from kernel bodies: exact BRep per body (without triangulation,
// so its fingerprint is the geometry's), mass from the exact volume and the material's density,
// display triangles grouped by CAD face, everything the Workbench places converted to its model
// space.
//
// Refused rather than guessed: a body without a material (its mass and its strength would both be
// invented), axes that are not two perpendicular signed axes (the model would be mirrored or
// sheared), a body the kernel cannot measure or export.

namespace cadnext::bridge {

struct ConstructionBodyInput {
    std::string id;
    std::string name;
    kernel::ShapeHandle shape;
    std::string materialId;
    double densityKgPerM3 = 0.0;
};

struct ConstructionBuildRequest {
    std::string id;
    std::string name;
    ConstructionAxes cadAxes;
    std::vector<ConstructionBodyInput> bodies;
    // Attachment points are not taken yet: their Euler rotations would need a convention for
    // carrying angles between the frames, and a mount silently turned the wrong way is worse than
    // none.
};

// CAD frame → Workbench model space (+Y up, +Z forward, +X left) for the declared axes, and back.
// Both fail on an invalid axis pair.
Result<Vector3> cadToModel(const ConstructionAxes& axes, const Vector3& cad);
Result<Vector3> modelToCad(const ConstructionAxes& axes, const Vector3& model);

// CAD frame → the .uavframe export frame (Z up, nose −Y, X left; see ConstructionExport.hpp).
Result<Vector3> cadToExport(const ConstructionAxes& axes, const Vector3& cad);

// The Workbench importer's mapping of the export frame to its model space, (x, y, z) → (x, z, −y).
inline Vector3 exportToModel(const Vector3& e) { return {e.x, e.z, -e.y}; }

Result<ConstructionDescriptor> buildConstruction(kernel::Kernel& kernel, const ConstructionBuildRequest& request);

// Lower-case hex SHA-256 of the bytes.
std::string sha256Hex(const std::string& bytes);

} // namespace cadnext::bridge
