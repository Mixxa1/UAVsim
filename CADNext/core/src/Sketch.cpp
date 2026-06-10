#include "cadnext/Sketch.hpp"

#include <algorithm>

namespace cadnext {

const char* sketchPlaneName(SketchPlane plane) {
    switch (plane) {
    case SketchPlane::XY: return "XY";
    case SketchPlane::XZ: return "XZ";
    case SketchPlane::YZ: return "YZ";
    }
    return "XY";
}

SketchPlane sketchPlaneFromName(const std::string& name) {
    if (name == "XZ") return SketchPlane::XZ;
    if (name == "YZ") return SketchPlane::YZ;
    return SketchPlane::XY;
}

const char* sketchEntityTypeName(SketchEntityType type) {
    switch (type) {
    case SketchEntityType::Line: return "Line";
    case SketchEntityType::Rectangle: return "Rectangle";
    case SketchEntityType::Circle: return "Circle";
    }
    return "Line";
}

SketchEntityType sketchEntityTypeFromName(const std::string& name) {
    if (name == "Rectangle") return SketchEntityType::Rectangle;
    if (name == "Circle") return SketchEntityType::Circle;
    return SketchEntityType::Line;
}

SketchEntity* findSketchEntity(Sketch& sketch, const std::string& entityId) {
    auto it = std::find_if(sketch.entities.begin(), sketch.entities.end(),
                           [&](const SketchEntity& entity) { return entity.id == entityId; });
    return it == sketch.entities.end() ? nullptr : &*it;
}

const SketchEntity* findSketchEntity(const Sketch& sketch, const std::string& entityId) {
    auto it = std::find_if(sketch.entities.begin(), sketch.entities.end(),
                           [&](const SketchEntity& entity) { return entity.id == entityId; });
    return it == sketch.entities.end() ? nullptr : &*it;
}

bool removeSketchEntity(Sketch& sketch, const std::string& entityId) {
    auto it = std::find_if(sketch.entities.begin(), sketch.entities.end(),
                           [&](const SketchEntity& entity) { return entity.id == entityId; });
    if (it == sketch.entities.end()) {
        return false;
    }
    sketch.entities.erase(it);
    return true;
}

} // namespace cadnext
