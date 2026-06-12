#pragma once

#include <string>
#include <vector>

#include "cadnext/Vector3.hpp"
#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

namespace cadnext::kernel {

// Face analysis for OCCT-backed bodies (CADNext 0.8 Sketch on Face).
// FaceReference is transient derived data, re-extracted from the body's
// current BRep shape after every evaluation; it is never serialized.
// Sketches created on a face persist a resolved SketchReference (core
// model) plus the bodyId/faceId pair to re-attach on load.
enum class FaceKind {
    Planar,
    Cylindrical,
    Conical,
    Spherical,
    Other
};

struct FaceReference {
    std::string bodyId;
    std::string faceId;

    FaceKind kind = FaceKind::Other;

    // Plane frame of a planar face: origin at the center of the face
    // bounds, orthonormal right-handed u/v/normal triad (u x v == normal),
    // normal pointing out of the solid. Curved faces keep the defaults.
    cadnext::Vector3 origin;
    cadnext::Vector3 uAxis{1.0, 0.0, 0.0};
    cadnext::Vector3 vAxis{0.0, 1.0, 0.0};
    cadnext::Vector3 normal{0.0, 0.0, 1.0};

    // Face extents along uAxis/vAxis (bounds rectangle of the face).
    double width = 1.0;
    double height = 1.0;

    double area = 0.0;

    // Only planar faces can host sketches in CADNext 0.8.
    bool isSketchable = false;

    // World-space triangulation of just this face — the viewport highlight
    // overlay. Display data only, never the geometric source of truth.
    TriangleMesh previewMesh;
};

// Stable-ish face id v1: "face-<index>-<normalHash>-<centerHash>-<areaHash>"
// from quantized geometry, so re-evaluating the same recipe (including
// after save/load) reproduces the same ids for simple bodies. Full
// topological naming is intentionally out of scope; when an id cannot be
// re-resolved after a model change, callers fall back to the resolved
// plane stored in the SketchReference.
std::string makeFaceId(int index, cadnext::Vector3 normal, cadnext::Vector3 center,
                       double area);

// Mesh-only fallback for procedural bodies (for example the non-OCCT
// extrude preview/body path). Groups triangles by MeshTriangle::faceId
// and derives planar FaceReference data from each owned triangle subset.
// Triangles with an empty faceId are ignored.
std::vector<FaceReference> planarFacesForMesh(const std::string& bodyId,
                                              const TriangleMesh& mesh);

class FaceAnalyzer {
public:
    explicit FaceAnalyzer(Kernel& kernel);

    // All faces of the body's current shape, classified by surface type.
    // Planar faces carry a full plane frame and isSketchable=true; curved
    // faces are reported (so they can be picked and explained in the UI)
    // but are not sketchable. Returns an empty list without an OCCT
    // backend or for unknown handles — face workflows simply stay
    // unavailable in stub builds.
    std::vector<FaceReference> planarFacesForBody(const std::string& bodyId,
                                                  const ShapeHandle& shape);

private:
    Kernel& kernel_;
};

} // namespace cadnext::kernel
