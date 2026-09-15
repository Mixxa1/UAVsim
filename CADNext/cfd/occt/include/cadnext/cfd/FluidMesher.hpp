#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/cfd/Su2Mesh.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

#include <map>
#include <string>
#include <vector>

namespace cadnext::kernel {
class OcctKernel;
}

// Volume meshes of a fluid domain for SU2, from exact CAD geometry with Netgen (LGPL-2.1).
//
// The domain is a solid — typically a box with the aircraft cut out of it. Faces listed as walls get
// their own element size and, for viscous flow, a prismatic boundary layer grown into the fluid;
// every other face is the far field. Walls are given by kernel face index (the "face-<index>"
// numbering used everywhere else) and grouped into named markers, one per body for a force
// breakdown; the far field is the marker "farfield".
//
// Linear elements only (tetrahedra, prisms, pyramids): SU2 is a vertex-based finite-volume code.

namespace cadnext::cfd {

struct FluidMeshSettings {
    // Both required: how fine the flow is resolved is the analyst's decision, answered by a
    // refinement study, not a default.
    double farfieldElementSizeM = 0.0;
    double wallElementSizeM = 0.0;
    double grading = 0.3;
    // Heights of the prism layers from the wall outward, metres; empty for inviscid flow.
    std::vector<double> layerHeightsM;
};

struct FluidMesh {
    Su2Mesh mesh; // the wall markers in name order, then "farfield"
    std::size_t tetrahedra = 0;
    std::size_t prisms = 0;
    std::size_t pyramids = 0;
    double smallestVolumeM3 = 0.0;
    std::string mesherVersion;
};

// wallMarkers: kernel face index → marker name (letters, digits, '_' and '-'; not "farfield").
Result<FluidMesh> meshFluidDomain(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& domain,
                                  const std::map<int, std::string>& wallMarkers, const FluidMeshSettings& settings);

} // namespace cadnext::cfd
