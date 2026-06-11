#pragma once

#include <string>
#include <vector>

#include "cadnext/Extrude.hpp"

namespace cadnext {

enum class FeatureType {
    Sketch,
    Extrude,
    Cut,
    Fillet,
    Chamfer,
    BooleanFuse,
    BooleanCut,
    BooleanCommon
};

struct Feature {
    std::string id;
    std::string name;
    FeatureType type = FeatureType::Sketch;
    std::string targetObjectId;
    std::vector<std::string> inputObjectIds;
    bool suppressed = false;

    // FeatureType::Extrude: the parametric recipe (sketch + profile +
    // parameters) and the body it generated. The recipe is the source of
    // truth — body meshes are re-derived from it on load.
    ExtrudeParameters extrude;
    std::string createdBodyId;
};

} // namespace cadnext
