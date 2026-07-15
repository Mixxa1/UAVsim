#pragma once

#include <string>

#include "cadnext/assembly/AssemblyMath.hpp"
#include "cadnext/assembly/GeometryReferenceResolver.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

namespace cadnext::assembly {

// Combined mesh + topology of a subassembly, in subassembly-local space
// (spec §15). Pure geometry — no Qt/GUI types — so it is unit-testable.
struct MergedGeometry {
    kernel::TriangleMesh mesh;
    PartTopology topology;
};

// Appends one internal part's mesh + topology to `target`, transformed by
// its solved subassembly-local `placement`, with every topology id and
// mesh faceId namespaced by `prefix` (typically "<internalComponentId>::")
// so the parent can address exported elements unambiguously and stably.
void appendTransformedGeometry(MergedGeometry& target, const kernel::TriangleMesh& mesh,
                               const PartTopology& topology, const Placement& placement,
                               const std::string& prefix);

} // namespace cadnext::assembly
