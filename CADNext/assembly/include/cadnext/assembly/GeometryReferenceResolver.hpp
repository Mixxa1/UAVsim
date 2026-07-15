#pragma once

#include <string>
#include <vector>

#include "cadnext/assembly/AssemblyMath.hpp"
#include "cadnext/assembly/AssemblyModel.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/VertexAnalyzer.hpp"

namespace cadnext::assembly {

// Extracted topology of one part body, in part-local space. Built by the
// part loader from the kernel analyzers; transient derived data.
struct PartTopology {
    std::vector<kernel::FaceReference> faces;
    std::vector<kernel::EdgeReference> edges;
    std::vector<kernel::VertexReference> vertices;
};

enum class ReferenceResolutionStatus {
    Exact,     // persistent topology id found
    Heuristic, // re-bound by geometric signature (needs user confirmation)
    Broken     // no acceptable match; fallback frame kept for display
};

struct ResolvedReference {
    ReferenceResolutionStatus status = ReferenceResolutionStatus::Broken;

    // Local frame of the element in part space (assembly spec §6/§9:
    // origin = center, Z = normal/axis/direction, X stable).
    Frame localFrame;

    // Topology id after resolution (differs from the stored one after a
    // heuristic re-bind).
    std::string resolvedTopologyId;
    GeometrySignature refreshedSignature;
    std::string message;
};

// Resolves geometry references against extracted part topology and builds
// new references from picked elements. Matching order (assembly spec §6):
// persistent topology id → geometric signature heuristic → broken. A
// broken reference is NEVER silently re-bound to an arbitrary element.
class GeometryReferenceResolver {
public:
    static ResolvedReference resolve(const GeometryReference& reference,
                                     const PartTopology& topology);

    // Reference builders from picked kernel topology. componentPath is
    // the owning component chain (outer → inner for subassemblies).
    static GeometryReference makeFaceReference(std::vector<std::string> componentPath,
                                               const kernel::FaceReference& face);
    static GeometryReference makeEdgeReference(std::vector<std::string> componentPath,
                                               const kernel::EdgeReference& edge);
    static GeometryReference makeVertexReference(std::vector<std::string> componentPath,
                                                 const kernel::VertexReference& vertex);
    static GeometryReference makeLcsReference(std::vector<std::string> componentPath);

    // Element frames (part space).
    static Frame frameForFace(const kernel::FaceReference& face);
    static Frame frameForEdge(const kernel::EdgeReference& edge);
    static Frame frameForVertex(const kernel::VertexReference& vertex);

    static GeometrySignature signatureForFace(const kernel::FaceReference& face);
    static GeometrySignature signatureForEdge(const kernel::EdgeReference& edge);
    static GeometrySignature signatureForVertex(const kernel::VertexReference& vertex);
};

} // namespace cadnext::assembly
