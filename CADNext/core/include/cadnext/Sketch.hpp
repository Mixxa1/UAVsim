#pragma once

#include <string>
#include <vector>

#include "cadnext/Vector3.hpp"

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

// What a sketch is attached to. Canonical planes cover XY/XZ/YZ; WorkPlane
// covers reference-plane objects (sourceId = object id); Face is reserved
// for body faces in a later stage.
enum class SketchReferenceType {
    CanonicalPlane,
    WorkPlane,
    Face
};

struct SketchReference {
    SketchReferenceType type = SketchReferenceType::CanonicalPlane;
    std::string sourceId;
    Vector3 origin;
    Vector3 uAxis{1.0, 0.0, 0.0};
    Vector3 vAxis{0.0, 1.0, 0.0};
    Vector3 normal{0.0, 0.0, 1.0};
};

struct Sketch {
    std::string id;
    std::string name;
    // Legacy/convenience canonical plane tag; `reference` is the geometric
    // source of truth for rendering, input projection and the 2D view.
    SketchPlane plane = SketchPlane::XY;
    SketchReference reference;
    std::vector<SketchEntity> entities;
};

const char* sketchPlaneName(SketchPlane plane);
SketchPlane sketchPlaneFromName(const std::string& name);

const char* sketchReferenceTypeName(SketchReferenceType type);
SketchReferenceType sketchReferenceTypeFromName(const std::string& name);

const char* sketchEntityTypeName(SketchEntityType type);
SketchEntityType sketchEntityTypeFromName(const std::string& name);

// Reference-plane transforms. These are the single source of truth for
// mapping sketch-local u/v to world coordinates and back — input
// projection, transient previews and committed entity rendering must all
// go through them so they can never disagree about the active plane.
//
//   world = origin + uAxis * u + vAxis * v
//   u = dot(world - origin, normalized(uAxis))
//   v = dot(world - origin, normalized(vAxis))
Vector3 sketchPointToWorld(const SketchPoint2D& point, const SketchReference& reference);
SketchPoint2D worldToSketchPoint(const Vector3& world, const SketchReference& reference);

// True when `world` lies on the reference plane:
// |dot(world - origin, normalized(normal))| < tolerance.
bool isWorldPointOnSketchPlane(const Vector3& world, const SketchReference& reference,
                               double tolerance = 1.0e-6);

SketchEntity* findSketchEntity(Sketch& sketch, const std::string& entityId);
const SketchEntity* findSketchEntity(const Sketch& sketch, const std::string& entityId);
bool removeSketchEntity(Sketch& sketch, const std::string& entityId);

} // namespace cadnext
