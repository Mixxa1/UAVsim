#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/TetMesh.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

#include <string>

namespace cadnext::kernel {
class OcctKernel;
}

// Volume meshing of CAD solids with Netgen (LGPL-2.1, linked dynamically).
//
// No OCCT or Netgen type crosses this header, like the kernel itself. The result is a plain
// TetMesh whose boundary faces are grouped by the CAD face they lie on, named exactly like the
// kernel's face ids ("face-<index>", index in TopExp_Explorer order — see FaceAnalyzer), so a
// support or load picked on a face in CADNext lands on the same triangles here.

namespace cadnext::fea {

struct SolidMeshingSettings {
    // Largest element edge, metres. Deliberately without a default: element size is a modelling
    // decision, and the answer to "is the mesh fine enough" is a convergence study, not a guess.
    double maximumElementSizeM = 0.0;
    // The rest are Netgen's own defaults, spelled out so a recorded result can state them.
    double grading = 0.3;
    double curvatureSafety = 2.0;
    double segmentsPerEdge = 1.0;
    int optimizationSteps3d = 3;
    // Quadratic elements have their midside nodes projected onto the CAD surfaces.
    ElementOrder order = ElementOrder::Quadratic;
};

struct SolidMesh {
    TetMesh mesh;
    int cadFaceCount = 0;
    double cadVolumeM3 = 0.0;
    // Integrated over the (curved) elements.
    double meshVolumeM3 = 0.0;
    std::string mesherVersion;
};

std::string solidFaceGroup(int faceIndex);

Result<SolidMesh> meshSolid(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape,
                            const SolidMeshingSettings& settings);

} // namespace cadnext::fea
