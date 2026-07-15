// GeometryReferenceResolver: exact id match → signature heuristic →
// broken (never silently re-bound), on synthetic kernel topology (no OCCT
// needed — the resolver is pure geometry).
#include "cadnext/assembly/GeometryReferenceResolver.hpp"

#include <cassert>
#include <cmath>

using namespace cadnext::assembly;
namespace kernel = cadnext::kernel;

namespace {

constexpr double kTol = 1.0e-9;

kernel::FaceReference planarFace(const std::string& faceId, cadnext::Vector3 origin,
                                 cadnext::Vector3 normal, double area) {
    kernel::FaceReference face;
    face.bodyId = "body-1";
    face.faceId = faceId;
    face.kind = kernel::FaceKind::Planar;
    face.origin = origin;
    face.normal = normal;
    face.uAxis = stablePerpendicular(normal);
    face.vAxis = cross(normal, face.uAxis);
    face.area = area;
    return face;
}

kernel::FaceReference cylindricalFace(const std::string& faceId, cadnext::Vector3 axisOrigin,
                                      cadnext::Vector3 axisDirection, double radius,
                                      double area) {
    kernel::FaceReference face;
    face.bodyId = "body-1";
    face.faceId = faceId;
    face.kind = kernel::FaceKind::Cylindrical;
    face.axisOrigin = axisOrigin;
    face.axisDirection = axisDirection;
    face.radius = radius;
    face.area = area;
    return face;
}

kernel::EdgeReference circularEdge(const std::string& edgeId, cadnext::Vector3 center,
                                   cadnext::Vector3 axis, double radius) {
    kernel::EdgeReference edge;
    edge.bodyId = "body-1";
    edge.edgeId = edgeId;
    edge.kind = kernel::EdgeKind::Circle;
    edge.center = center;
    edge.axisDirection = axis;
    edge.radius = radius;
    edge.length = 2.0 * M_PI * radius;
    return edge;
}

kernel::VertexReference vertex(const std::string& vertexId, cadnext::Vector3 position) {
    kernel::VertexReference v;
    v.bodyId = "body-1";
    v.vertexId = vertexId;
    v.position = position;
    return v;
}

} // namespace

int main() {
    PartTopology topology;
    topology.faces.push_back(planarFace("face-0-aa", {0.0, 0.0, 0.5}, {0.0, 0.0, 1.0}, 1.0));
    topology.faces.push_back(planarFace("face-1-bb", {0.0, 0.0, -0.5}, {0.0, 0.0, -1.0}, 1.0));
    topology.faces.push_back(
        cylindricalFace("face-2-cc", {0.2, 0.3, 0.0}, {0.0, 0.0, 1.0}, 0.05, 0.31));
    topology.edges.push_back(
        circularEdge("edge-0-dd", {0.2, 0.3, 0.5}, {0.0, 0.0, 1.0}, 0.05));
    topology.vertices.push_back(vertex("vertex-0-ee", {0.5, 0.5, 0.5}));

    // --- Exact id match -----------------------------------------------------
    const GeometryReference topFaceRef =
        GeometryReferenceResolver::makeFaceReference({"component-1"}, topology.faces[0]);
    assert(topFaceRef.kind == GeometryReferenceKind::PlanarFace);
    assert(topFaceRef.persistentTopologyId == "face-0-aa");

    ResolvedReference resolved = GeometryReferenceResolver::resolve(topFaceRef, topology);
    assert(resolved.status == ReferenceResolutionStatus::Exact);
    assert(resolved.resolvedTopologyId == "face-0-aa");
    assert(nearlyEqual(resolved.localFrame.origin, {0.0, 0.0, 0.5}, kTol));
    assert(nearlyEqual(resolved.localFrame.zAxis, {0.0, 0.0, 1.0}, kTol));

    // --- Heuristic re-bind (id changed, geometry близка) ---------------------
    GeometryReference movedRef = topFaceRef;
    movedRef.persistentTopologyId = "face-0-STALE";
    resolved = GeometryReferenceResolver::resolve(movedRef, topology);
    assert(resolved.status == ReferenceResolutionStatus::Heuristic);
    assert(resolved.resolvedTopologyId == "face-0-aa");

    // The bottom face has the opposite normal but the heuristic must not
    // grab it when the position differs beyond tolerance.
    GeometryReference farRef = topFaceRef;
    farRef.persistentTopologyId = "face-0-STALE";
    farRef.signature.origin = {0.0, 0.0, 5.0};
    farRef.fallbackFrame.origin = {0.0, 0.0, 5.0};
    resolved = GeometryReferenceResolver::resolve(farRef, topology);
    assert(resolved.status == ReferenceResolutionStatus::Broken);
    // Broken keeps the fallback frame for display.
    assert(nearlyEqual(resolved.localFrame.origin, {0.0, 0.0, 5.0}, kTol));

    // Area mismatch beyond tolerance → broken, not silent re-bind.
    GeometryReference wrongArea = topFaceRef;
    wrongArea.persistentTopologyId = "face-0-STALE";
    wrongArea.signature.area = 2.0;
    resolved = GeometryReferenceResolver::resolve(wrongArea, topology);
    assert(resolved.status == ReferenceResolutionStatus::Broken);

    // --- Cylindrical face frame: Z along the axis ---------------------------
    const GeometryReference cylRef =
        GeometryReferenceResolver::makeFaceReference({"component-1"}, topology.faces[2]);
    assert(cylRef.kind == GeometryReferenceKind::CylindricalFace);
    resolved = GeometryReferenceResolver::resolve(cylRef, topology);
    assert(resolved.status == ReferenceResolutionStatus::Exact);
    assert(nearlyEqual(resolved.localFrame.origin, {0.2, 0.3, 0.0}, kTol));
    assert(nearlyEqual(resolved.localFrame.zAxis, {0.0, 0.0, 1.0}, kTol));

    // Radius mismatch blocks the heuristic.
    GeometryReference wrongRadius = cylRef;
    wrongRadius.persistentTopologyId = "face-2-STALE";
    wrongRadius.signature.radius = 0.5;
    resolved = GeometryReferenceResolver::resolve(wrongRadius, topology);
    assert(resolved.status == ReferenceResolutionStatus::Broken);

    // --- Circular edge -------------------------------------------------------
    const GeometryReference edgeRef =
        GeometryReferenceResolver::makeEdgeReference({"component-1"}, topology.edges[0]);
    assert(edgeRef.kind == GeometryReferenceKind::CircularEdge);
    resolved = GeometryReferenceResolver::resolve(edgeRef, topology);
    assert(resolved.status == ReferenceResolutionStatus::Exact);
    assert(nearlyEqual(resolved.localFrame.origin, {0.2, 0.3, 0.5}, kTol));
    assert(nearlyEqual(resolved.localFrame.zAxis, {0.0, 0.0, 1.0}, kTol));

    // A planar-face reference never resolves to an edge and vice versa:
    // kind gates the candidate set.
    GeometryReference kindMismatch = edgeRef;
    kindMismatch.kind = GeometryReferenceKind::LinearEdge;
    kindMismatch.persistentTopologyId = "edge-0-STALE";
    resolved = GeometryReferenceResolver::resolve(kindMismatch, topology);
    assert(resolved.status == ReferenceResolutionStatus::Broken);

    // --- Vertex --------------------------------------------------------------
    const GeometryReference vertexRef =
        GeometryReferenceResolver::makeVertexReference({"component-1"},
                                                       topology.vertices[0]);
    resolved = GeometryReferenceResolver::resolve(vertexRef, topology);
    assert(resolved.status == ReferenceResolutionStatus::Exact);
    assert(nearlyEqual(resolved.localFrame.origin, {0.5, 0.5, 0.5}, kTol));

    GeometryReference staleVertex = vertexRef;
    staleVertex.persistentTopologyId = "vertex-0-STALE";
    resolved = GeometryReferenceResolver::resolve(staleVertex, topology);
    assert(resolved.status == ReferenceResolutionStatus::Heuristic);
    assert(resolved.resolvedTopologyId == "vertex-0-ee");

    // --- LCS always resolves to the component origin frame -------------------
    const GeometryReference lcsRef =
        GeometryReferenceResolver::makeLcsReference({"component-1"});
    resolved = GeometryReferenceResolver::resolve(lcsRef, PartTopology{});
    assert(resolved.status == ReferenceResolutionStatus::Exact);
    assert(nearlyEqual(resolved.localFrame.origin, {0.0, 0.0, 0.0}, kTol));

    return 0;
}
