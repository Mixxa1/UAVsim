#pragma once

#include <string>

class SoSeparator;

namespace cadnext::gui {

enum class UAVPreviewVehicleType;
enum class UAVPreviewMassCategory;

// Builds a faithful Coin3D scene graph for a specific UAV model.
// Geometry matches UAVVisualFactory.swift per-aircraft builders (15 aircraft).
// Falls back to a type-based generic silhouette for unknown IDs.
//
// Caller must ref() the returned separator or add it as a child immediately;
// the returned pointer has refcount 0 (Coin3D default for new nodes).
class UAVBodySceneBuilder {
public:
    static SoSeparator* buildScene(const std::string&    uavId,
                                   UAVPreviewVehicleType  type,
                                   UAVPreviewMassCategory massCategory);
};

} // namespace cadnext::gui
