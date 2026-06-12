#pragma once

#include "cadnext/Extrude.hpp"
#include "cadnext/Result.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

namespace cadnext::kernel {

// Procedural prism mesh for an extruded sketch profile: triangulated caps
// (ear clipping, so concave custom polygons work) plus side wall quads,
// with outward-facing winding on every triangle.
//
// This is the display/preview path and the fallback when no BRep backend
// is compiled in. The profile + ExtrudeParameters stay the source of
// truth; the mesh is derived data and is never serialized.
cadnext::Result<TriangleMesh> buildExtrudedProfileMesh(
    const cadnext::SketchReference& reference,
    const cadnext::SketchProfile& profile,
    const cadnext::ExtrudeParameters& parameters);

// Same prism mesh over an explicit [startOffset, endOffset] span along
// the plane normal — used for the Cut Extrude cutter preview, whose span
// comes from computeCutSpan rather than ExtrudeParameters.
cadnext::Result<TriangleMesh> buildProfilePrismMesh(
    const cadnext::SketchReference& reference,
    const cadnext::SketchProfile& profile,
    double startOffset, double endOffset);

} // namespace cadnext::kernel
