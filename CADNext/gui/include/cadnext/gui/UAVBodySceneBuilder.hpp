#pragma once

#include <string>

class SoSeparator;

namespace cadnext::gui {

enum class UAVPreviewVehicleType;
enum class UAVPreviewMassCategory;

// Builds a faithful Coin3D scene graph for a specific UAV model.
// macOS loads the simulator USDZ manifest; a missing asset returns an empty scene
// with a diagnostic in source. Other platforms retain a procedural preview.
//
// Caller must ref() the returned separator or add it as a child immediately;
// the returned pointer has refcount 0 (Coin3D default for new nodes).
class UAVBodySceneBuilder {
public:
    static SoSeparator* buildScene(const std::string&    uavId,
                                   UAVPreviewVehicleType  type,
                                   UAVPreviewMassCategory massCategory,
                                   std::string* source = nullptr);
};

} // namespace cadnext::gui
