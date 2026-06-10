#pragma once

#include <string>
#include <vector>

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
};

// Placeholder for the CADNext 0.6 Sketch → Face → Extrude workflow.
// Not evaluated anywhere yet; declared so the feature pipeline shape is
// settled before the OCCT extrude implementation lands.
struct ExtrudeParameters {
    std::string sketchId;
    std::string profileId;
    double depth = 1.0;
};

} // namespace cadnext
