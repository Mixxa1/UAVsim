#pragma once

#include <string>
#include <vector>

#include "cadnext/Chamfer.hpp"
#include "cadnext/Extrude.hpp"
#include "cadnext/ExtrudeCut.hpp"
#include "cadnext/Fillet.hpp"

namespace cadnext {

enum class FeatureType {
    Sketch,
    Extrude,
    ExtrudeCut,
    Chamfer,
    Fillet,
    Cut,
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

    // FeatureType::ExtrudeCut: the cut recipe; the cut modifies the target
    // body in place, so modifiedBodyId == extrudeCut.targetBodyId in v1.
    // Cut features are replayed in order on load (OCCT builds).
    ExtrudeCutParameters extrudeCut;
    std::string modifiedBodyId;

    // FeatureType::Chamfer / FeatureType::Fillet: edge-operation recipes.
    // Edge ids are stable-ish for the current evaluated body state and are
    // re-resolved during replay; robust topological naming is future work.
    ChamferParameters chamfer;
    FilletParameters fillet;
};

} // namespace cadnext
