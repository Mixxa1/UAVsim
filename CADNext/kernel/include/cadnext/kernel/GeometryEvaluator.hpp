#pragma once

#include <memory>
#include <string>

#include "cadnext/Extrude.hpp"
#include "cadnext/Object.hpp"
#include "cadnext/Result.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/kernel/MeshExtractor.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

namespace cadnext::kernel {

// Result of evaluating one document object:
//
//   PrimitiveParameters → Kernel (BRep shape) → MeshExtractor → previewMesh
//
// EvaluatedGeometry is transient derived data, never the source of truth.
// Objects are re-evaluated whenever their primitive parameters change and
// after every document load.
struct EvaluatedGeometry {
    std::string objectId;
    ShapeHandle shape;
    TriangleMesh previewMesh;
    bool isValid = false;
    std::string message;
};

class GeometryEvaluator {
public:
    explicit GeometryEvaluator(Kernel& kernel);

    // Hard parameter/usage errors return a failed Result. A geometry
    // backend that cannot produce BRep meshes (stub kernel, OCCT disabled)
    // returns ok with isValid=false and an explanatory message so callers
    // can fall back to procedural display. Reference planes are viewer-only
    // helpers in CADNext 0.4 and also come back with isValid=false.
    cadnext::Result<EvaluatedGeometry> evaluateObject(const cadnext::Object& object);

    // Extruded sketch profile → BRep prism → preview mesh. Follows the
    // same contract as evaluateObject: parameter errors fail the Result,
    // a missing BRep backend returns ok with isValid=false so the caller
    // can fall back to the procedural prism mesh (ExtrudeMesh.hpp).
    cadnext::Result<EvaluatedGeometry> evaluateExtrude(
        const cadnext::SketchReference& reference,
        const cadnext::SketchProfile& profile,
        const cadnext::ExtrudeParameters& parameters);

private:
    Kernel& kernel_;
    std::unique_ptr<MeshExtractor> meshExtractor_;
};

} // namespace cadnext::kernel
