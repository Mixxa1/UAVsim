#pragma once

#include <string>

#include "cadnext/Result.hpp"

namespace cadnext {

// Extrude Cut v1 (CADNext 0.7): a closed sketch profile is extruded into a
// cutter solid and subtracted from the target body through the OCCT BRep
// boolean pipeline (never a mesh boolean). The cut modifies the target
// body in place; the feature records the recipe.
enum class CutDepthMode {
    Distance,
    ThroughAll,
    ToObject
};

enum class CutDirection {
    Positive,
    Negative,
    Symmetric
};

struct ExtrudeCutParameters {
    std::string targetBodyId;
    std::string sketchId;
    std::string profileId;

    CutDepthMode depthMode = CutDepthMode::Distance;
    CutDirection direction = CutDirection::Positive;

    double distance = 1.0;

    // Used only for ToObject.
    std::string limitObjectId;
};

// Static validation (no geometry): ids present per mode, finite positive
// distance for Distance mode. ToObject supports Positive/Negative only —
// a symmetric "up to object" is ambiguous and rejected in v1.
bool extrudeCutParametersValid(const ExtrudeCutParameters& parameters);

// Cutter extent along the +normal axis of the sketch plane, relative to
// the sketch origin (start < end). ThroughAll/ToObject need the bounding
// extents below; Distance ignores them.
struct CutSpan {
    double start = 0.0;
    double end = 0.0;
};

// Bounding extents along the +normal axis, relative to the sketch plane
// origin (projections of the body AABB corners onto the normal).
struct CutExtents {
    double targetMin = 0.0;
    double targetMax = 0.0;
    // Safety margin source for ThroughAll (target AABB diagonal length).
    double targetDiagonal = 0.0;
    double limitMin = 0.0;
    double limitMax = 0.0;
    bool hasLimit = false;
};

// Computes the cutter span:
//  - Distance: Positive [0,d], Negative [-d,0], Symmetric [-d/2,+d/2];
//  - ThroughAll: guaranteed past the target extents (margin = diagonal+1)
//    on the cut side(s) of the plane;
//  - ToObject: from the plane to the near face of the limit object's
//    AABB along the cut direction; fails when the limit object is not in
//    the cut direction.
Result<CutSpan> computeCutSpan(const ExtrudeCutParameters& parameters,
                               const CutExtents& extents);

// Serialization names (stable .cadnext strings).
const char* cutDepthModeName(CutDepthMode mode);
CutDepthMode cutDepthModeFromName(const std::string& name);
const char* cutDirectionName(CutDirection direction);
CutDirection cutDirectionFromName(const std::string& name);

} // namespace cadnext
