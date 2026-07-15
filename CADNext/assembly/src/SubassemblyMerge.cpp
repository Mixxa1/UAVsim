#include "cadnext/assembly/SubassemblyMerge.hpp"

#include <cstdint>

namespace cadnext::assembly {

namespace {

Vector3 transformPoint(const Placement& placement, const Vector3& point) {
    return placement.apply(point);
}

Vector3 transformDirection(const Placement& placement, const Vector3& direction) {
    return placement.applyDirection(direction);
}

} // namespace

void appendTransformedGeometry(MergedGeometry& target, const kernel::TriangleMesh& mesh,
                               const PartTopology& topology, const Placement& placement,
                               const std::string& prefix) {
    const std::uint32_t vertexOffset =
        static_cast<std::uint32_t>(target.mesh.vertices.size());
    for (const kernel::MeshVertex& vertex : mesh.vertices) {
        const Vector3 world = transformPoint(placement, {vertex.x, vertex.y, vertex.z});
        target.mesh.vertices.push_back({world.x, world.y, world.z});
    }
    for (const kernel::MeshTriangle& triangle : mesh.triangles) {
        kernel::MeshTriangle moved = triangle;
        moved.a += vertexOffset;
        moved.b += vertexOffset;
        moved.c += vertexOffset;
        if (!moved.faceId.empty()) {
            moved.faceId = prefix + moved.faceId;
        }
        target.mesh.triangles.push_back(moved);
    }

    for (const kernel::FaceReference& face : topology.faces) {
        kernel::FaceReference moved = face;
        moved.faceId = prefix + face.faceId;
        moved.origin = transformPoint(placement, face.origin);
        moved.uAxis = transformDirection(placement, face.uAxis);
        moved.vAxis = transformDirection(placement, face.vAxis);
        moved.normal = transformDirection(placement, face.normal);
        moved.axisOrigin = transformPoint(placement, face.axisOrigin);
        moved.axisDirection = transformDirection(placement, face.axisDirection);
        for (kernel::MeshVertex& vertex : moved.previewMesh.vertices) {
            const Vector3 world =
                transformPoint(placement, {vertex.x, vertex.y, vertex.z});
            vertex = {world.x, world.y, world.z};
        }
        for (kernel::MeshTriangle& triangle : moved.previewMesh.triangles) {
            if (!triangle.faceId.empty()) {
                triangle.faceId = prefix + triangle.faceId;
            }
        }
        target.topology.faces.push_back(std::move(moved));
    }
    for (const kernel::EdgeReference& edge : topology.edges) {
        kernel::EdgeReference moved = edge;
        moved.edgeId = prefix + edge.edgeId;
        moved.start = transformPoint(placement, edge.start);
        moved.end = transformPoint(placement, edge.end);
        moved.center = transformPoint(placement, edge.center);
        moved.axisDirection = transformDirection(placement, edge.axisDirection);
        for (Vector3& point : moved.previewPolyline) {
            point = transformPoint(placement, point);
        }
        target.topology.edges.push_back(std::move(moved));
    }
    for (const kernel::VertexReference& vertex : topology.vertices) {
        kernel::VertexReference moved = vertex;
        moved.vertexId = prefix + vertex.vertexId;
        moved.position = transformPoint(placement, vertex.position);
        target.topology.vertices.push_back(std::move(moved));
    }
}

} // namespace cadnext::assembly
