// Subassembly merge (spec §15): internal parts merge into one
// subassembly-local geometry — transformed by their solved placement,
// topology ids namespaced — and the parent then treats the subassembly as
// one rigid component whose exported faces are addressable by joints.
#include "cadnext/assembly/AssemblyRecomputeEngine.hpp"
#include "cadnext/assembly/SubassemblyMerge.hpp"

#include <cassert>
#include <cmath>

using namespace cadnext::assembly;
namespace kernel = cadnext::kernel;

namespace {

constexpr double kTol = 1.0e-6;

kernel::TriangleMesh unitTriangleMesh() {
    kernel::TriangleMesh mesh;
    mesh.vertices = {{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}};
    kernel::MeshTriangle triangle;
    triangle.a = 0;
    triangle.b = 1;
    triangle.c = 2;
    triangle.faceId = "face-top";
    mesh.triangles.push_back(triangle);
    return mesh;
}

PartTopology topTopology() {
    PartTopology topology;
    kernel::FaceReference top;
    top.bodyId = "b";
    top.faceId = "face-top";
    top.kind = kernel::FaceKind::Planar;
    top.origin = {0.0, 0.0, 0.5};
    top.normal = {0.0, 0.0, 1.0};
    top.uAxis = {1.0, 0.0, 0.0};
    top.vAxis = {0.0, 1.0, 0.0};
    top.area = 1.0;
    topology.faces.push_back(top);

    kernel::VertexReference vertex;
    vertex.bodyId = "b";
    vertex.vertexId = "vertex-0";
    vertex.position = {0.5, 0.5, 0.5};
    topology.vertices.push_back(vertex);
    return topology;
}

void checkVector(const cadnext::Vector3& v, double x, double y, double z,
                 double tolerance = kTol) {
    assert(nearlyEqual(v.x, x, tolerance));
    assert(nearlyEqual(v.y, y, tolerance));
    assert(nearlyEqual(v.z, z, tolerance));
}

} // namespace

int main() {
    // --- Merge two internal parts at different placements -------------------
    MergedGeometry merged;

    // Part 1: identity placement.
    appendTransformedGeometry(merged, unitTriangleMesh(), topTopology(),
                              Placement::identity(), "left::");

    // Part 2: translated +2 in X and rotated 90° about Z.
    Placement placement2;
    placement2.translation = {2.0, 0.0, 0.0};
    placement2.rotation = Quaternion::fromAxisAngle({0.0, 0.0, 1.0}, M_PI / 2.0);
    appendTransformedGeometry(merged, unitTriangleMesh(), topTopology(), placement2,
                              "right::");

    // Mesh merged: 6 vertices, 2 triangles with offset + namespaced ids.
    assert(merged.mesh.vertices.size() == 6);
    assert(merged.mesh.triangles.size() == 2);
    assert(merged.mesh.triangles[0].faceId == "left::face-top");
    assert(merged.mesh.triangles[1].faceId == "right::face-top");
    // Second triangle's indices offset past the first part's vertices.
    assert(merged.mesh.triangles[1].a == 3);

    // Topology merged + namespaced + transformed.
    assert(merged.topology.faces.size() == 2);
    assert(merged.topology.faces[0].faceId == "left::face-top");
    assert(merged.topology.faces[1].faceId == "right::face-top");
    checkVector(merged.topology.faces[0].origin, 0.0, 0.0, 0.5);
    // Right face: origin (0,0,0.5) rotated 90°Z (unchanged, on axis) + (2,0,0).
    checkVector(merged.topology.faces[1].origin, 2.0, 0.0, 0.5);
    // Right face normal stays +Z (rotation about Z).
    checkVector(merged.topology.faces[1].normal, 0.0, 0.0, 1.0);
    assert(merged.topology.vertices.size() == 2);
    assert(merged.topology.vertices[1].vertexId == "right::vertex-0");
    // Vertex (0.5,0.5,0.5) rotated 90°Z → (-0.5,0.5,0.5) + (2,0,0) = (1.5,0.5,0.5).
    checkVector(merged.topology.vertices[1].position, 1.5, 0.5, 0.5);

    // --- Parent recompute: subassembly as one rigid, grounded component -----
    // The merged topology is what the loader hands the recompute engine for
    // the subassembly component; a part mates onto an exported (namespaced)
    // face and solves normally.
    AssemblyDocument document;

    AssemblyComponent subassembly;
    subassembly.id = "sub";
    subassembly.name = "Motor Pod";
    subassembly.source.kind = PartSourceKind::Assembly;
    subassembly.source.filePath = "/tmp/pod.cadasm";
    subassembly.isGrounded = true;
    document.addComponent(subassembly);

    AssemblyComponent part;
    part.id = "cover";
    part.name = "Cover";
    part.source.kind = PartSourceKind::UavPart;
    part.source.filePath = "/tmp/cover.uavpart";
    part.placement.translation = {9.0, 9.0, 9.0};
    document.addComponent(part);

    // Cover's own bottom face.
    PartTopology coverTopology;
    kernel::FaceReference coverBottom;
    coverBottom.bodyId = "b";
    coverBottom.faceId = "face-bottom";
    coverBottom.kind = kernel::FaceKind::Planar;
    coverBottom.origin = {0.0, 0.0, -0.5};
    coverBottom.normal = {0.0, 0.0, -1.0};
    coverBottom.uAxis = {1.0, 0.0, 0.0};
    coverBottom.vAxis = {0.0, -1.0, 0.0};
    coverBottom.area = 1.0;
    coverTopology.faces.push_back(coverBottom);

    AssemblyJoint joint;
    joint.id = "joint-1";
    joint.name = "Coincident001";
    joint.type = JointType::Coincident;
    joint.alignment = JointAlignment::Opposed;
    // Mate onto the subassembly's exported "left::face-top" (at z=0.5).
    joint.first = GeometryReferenceResolver::makeFaceReference(
        {"sub"}, merged.topology.faces[0]);
    joint.second =
        GeometryReferenceResolver::makeFaceReference({"cover"}, coverTopology.faces[0]);
    document.addJoint(joint);

    const auto provider =
        [&](const AssemblyComponent& component) -> const PartTopology* {
        if (component.id == "sub") {
            return &merged.topology;
        }
        return &coverTopology;
    };

    AssemblyRecomputeEngine engine;
    const auto result = engine.recompute(document, provider);
    (void)result;

    assert(document.jointById("joint-1").value().solveState.status ==
           JointSolveStatus::Solved);
    // Subassembly stays put (grounded); cover mates onto its exported face.
    checkVector(document.componentById("sub").value().placement.translation, 0.0, 0.0,
                0.0);
    const Placement coverPlacement = document.componentById("cover").value().placement;
    const Frame coverBottomWorld =
        GeometryReferenceResolver::resolve(joint.second, coverTopology)
            .localFrame.transformedBy(coverPlacement);
    // Cover's bottom face contacts the subassembly's top face plane (z=0.5).
    assert(nearlyEqual(coverBottomWorld.origin.z, 0.5, 1.0e-4));

    return 0;
}
