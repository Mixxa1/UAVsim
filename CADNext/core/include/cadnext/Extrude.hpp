#pragma once

#include <string>

#include "cadnext/Sketch.hpp"
#include "cadnext/Vector3.hpp"

namespace cadnext {

// Extrude v1 (CADNext 0.6): one closed sketch profile extruded along the
// sketch plane normal into a new body. Cut / fuse / through-all / up-to
// arrive in later stages. The parameters (plus the source sketch profile)
// are the source of truth; generated body geometry is always derived.
enum class ExtrudeOperation {
    NewBody
};

enum class ExtrudeDirection {
    Positive,
    Negative,
    Symmetric
};

enum class ExtrudeDepthMode {
    Distance
};

struct ExtrudeParameters {
    std::string sketchId;
    std::string profileId;

    ExtrudeOperation operation = ExtrudeOperation::NewBody;
    ExtrudeDirection direction = ExtrudeDirection::Positive;
    ExtrudeDepthMode depthMode = ExtrudeDepthMode::Distance;

    double distance = 1.0;
};

// True when the parameters can produce geometry: non-empty sketch/profile
// ids and a finite, strictly positive distance.
bool extrudeParametersValid(const ExtrudeParameters& parameters);

// Unit world-space extrusion direction for the sketch plane: Positive →
// +normal, Negative → -normal. Symmetric also returns +normal; the
// two-sided span comes from extrudeSpan().
Vector3 extrudeDirectionVector(const SketchReference& reference, ExtrudeDirection direction);

// Signed offsets along the +normal axis covered by the extrusion:
// Positive [0, d], Negative [-d, 0], Symmetric [-d/2, +d/2].
void extrudeSpan(const ExtrudeParameters& parameters, double& startOffset, double& endOffset);

// Serialization names (stable .cadnext strings).
const char* extrudeOperationName(ExtrudeOperation operation);
ExtrudeOperation extrudeOperationFromName(const std::string& name);
const char* extrudeDirectionName(ExtrudeDirection direction);
ExtrudeDirection extrudeDirectionFromName(const std::string& name);
const char* extrudeDepthModeName(ExtrudeDepthMode mode);
ExtrudeDepthMode extrudeDepthModeFromName(const std::string& name);

} // namespace cadnext
