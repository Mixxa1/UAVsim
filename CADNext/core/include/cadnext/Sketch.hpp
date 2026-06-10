#pragma once

#include <string>
#include <vector>

namespace cadnext {

// CADNext 0.5 sketch model. Sketches are 2D and live on one of the three
// canonical planes; entity coordinates are local u/v values:
//
//   XY: u=X, v=Y, normal=Z (default; the viewport grid plane, Z-up)
//   XZ: u=X, v=Z, normal=Y
//   YZ: u=Y, v=Z, normal=X
enum class SketchPlane {
    XY,
    XZ,
    YZ
};

struct SketchPoint2D {
    double u = 0.0;
    double v = 0.0;
};

enum class SketchEntityType {
    Line,
    Rectangle,
    Circle
};

struct SketchLine {
    SketchPoint2D start;
    SketchPoint2D end;
};

struct SketchRectangle {
    SketchPoint2D origin; // lower-left corner (normalized width/height >= 0)
    double width = 1.0;
    double height = 1.0;
};

struct SketchCircle {
    SketchPoint2D center;
    double radius = 0.5;
};

// One sketch element. Only the member matching `type` is meaningful; this
// is intentionally a plain tagged struct (not std::variant) to keep the
// 0.5 model and its serialization simple.
struct SketchEntity {
    std::string id;
    std::string name;
    SketchEntityType type = SketchEntityType::Line;

    SketchLine line;
    SketchRectangle rectangle;
    SketchCircle circle;
};

struct Sketch {
    std::string id;
    std::string name;
    SketchPlane plane = SketchPlane::XY;
    std::vector<SketchEntity> entities;
};

const char* sketchPlaneName(SketchPlane plane);
SketchPlane sketchPlaneFromName(const std::string& name);

const char* sketchEntityTypeName(SketchEntityType type);
SketchEntityType sketchEntityTypeFromName(const std::string& name);

SketchEntity* findSketchEntity(Sketch& sketch, const std::string& entityId);
const SketchEntity* findSketchEntity(const Sketch& sketch, const std::string& entityId);
bool removeSketchEntity(Sketch& sketch, const std::string& entityId);

} // namespace cadnext
