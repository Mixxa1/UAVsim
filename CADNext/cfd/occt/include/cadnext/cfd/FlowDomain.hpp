#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

#include <array>
#include <set>
#include <string>
#include <vector>

namespace cadnext::kernel {
class OcctKernel;
}

// The fluid domain around an aircraft: a box with every body cut out of it, in one boolean, from the
// exact BRep bodies of a `.uavframe`.
//
// Every face of the result that came from a body is a wall and remembers where it came from (body id
// and that body's "face-<index>"), so forces can be broken down per body and a face picked on the
// model is the face in the flow result. Faces where two bodies touch are inside the solid aircraft
// and vanish from the domain; they are reported as hidden, not silently dropped.

namespace cadnext::cfd {

struct FlowBody {
    std::string id;
    kernel::ShapeHandle shape;
};

struct FlowDomainSettings {
    // Distance from the aircraft's bounding box to every side of the box, in reference lengths (the
    // box's largest dimension). Required: the far field's effect on the result is measured, not
    // assumed away.
    double farfieldDistanceLengths = 0.0;
};

struct WallOrigin {
    int domainFace = -1;  // kernel face index in the domain
    std::string bodyId;
    std::string bodyFace; // "face-<index>" in that body
};

struct FlowDomain {
    kernel::ShapeHandle domain;
    std::set<int> wallFaces;
    std::vector<WallOrigin> walls;
    // Body faces with no part in the domain's wall: covered by another body.
    std::vector<WallOrigin> hiddenFaces;
    double referenceLengthM = 0.0;
    std::array<double, 3> boundsMin{};
    std::array<double, 3> boundsMax{};
};

Result<FlowDomain> buildFlowDomain(kernel::OcctKernel& kernel, const std::vector<FlowBody>& bodies, const FlowDomainSettings& settings);

} // namespace cadnext::cfd
