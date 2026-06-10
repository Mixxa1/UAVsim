#include "cadnext/kernel/MeshExtractor.hpp"

#include <cmath>

#ifdef CADNEXT_WITH_OCCT
#include <algorithm>

#include <BRepBndLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>

#include "cadnext/kernel/OcctKernel.hpp"
#endif

namespace cadnext::kernel {

namespace {

cadnext::Result<TriangleMesh> meshFailure(cadnext::ErrorCode code, std::string message) {
    return cadnext::Result<TriangleMesh>::fail({code, std::move(message)});
}

#ifdef CADNEXT_WITH_OCCT

class OcctMeshExtractor final : public MeshExtractor {
public:
    cadnext::Result<TriangleMesh> extract(Kernel& kernel, const ShapeHandle& shape) override {
        auto* occtKernel = dynamic_cast<OcctKernel*>(&kernel);
        if (!occtKernel) {
            return meshFailure(cadnext::ErrorCode::KernelUnavailable,
                               "Mesh extraction requires the OCCT kernel backend");
        }
        const TopoDS_Shape* topoShape = occtKernel->findShape(shape);
        if (!topoShape) {
            return meshFailure(cadnext::ErrorCode::NotFound,
                               "Unknown shape handle: " + shape.id());
        }
        if (topoShape->IsNull()) {
            return meshFailure(cadnext::ErrorCode::ShapeInvalid, "Shape is null");
        }

        try {
            return extractMesh(*topoShape);
        } catch (const Standard_Failure& failure) {
            return meshFailure(cadnext::ErrorCode::KernelOperationFailed,
                               std::string("OCCT meshing failed: ") +
                                   failure.GetMessageString());
        }
    }

private:
    static cadnext::Result<TriangleMesh> extractMesh(const TopoDS_Shape& shape) {
        // Deflection scales with the model so small and large bodies get
        // comparable visual quality.
        Bnd_Box bounds;
        BRepBndLib::Add(shape, bounds);
        double diagonal = 1.0;
        if (!bounds.IsVoid()) {
            double xMin = 0.0, yMin = 0.0, zMin = 0.0, xMax = 0.0, yMax = 0.0, zMax = 0.0;
            bounds.Get(xMin, yMin, zMin, xMax, yMax, zMax);
            diagonal = std::sqrt((xMax - xMin) * (xMax - xMin) +
                                 (yMax - yMin) * (yMax - yMin) +
                                 (zMax - zMin) * (zMax - zMin));
        }
        const double linearDeflection = std::max(diagonal * 0.004, 1.0e-4);
        constexpr double kAngularDeflection = 0.3; // radians

        BRepMesh_IncrementalMesh mesher(shape, linearDeflection, Standard_False,
                                        kAngularDeflection, Standard_True);

        TriangleMesh mesh;
        for (TopExp_Explorer faces(shape, TopAbs_FACE); faces.More(); faces.Next()) {
            const TopoDS_Face face = TopoDS::Face(faces.Current());
            TopLoc_Location location;
            const Handle(Poly_Triangulation) triangulation =
                BRep_Tool::Triangulation(face, location);
            if (triangulation.IsNull()) {
                continue;
            }

            const std::uint32_t vertexOffset =
                static_cast<std::uint32_t>(mesh.vertices.size());
            const gp_Trsf transform = location.Transformation();

            for (Standard_Integer i = 1; i <= triangulation->NbNodes(); ++i) {
                gp_Pnt point = triangulation->Node(i);
                point.Transform(transform);
                mesh.vertices.push_back({point.X(), point.Y(), point.Z()});
            }

            // OCCT triangulation is CCW for FORWARD faces; REVERSED faces
            // need flipped winding so outward normals stay consistent.
            const bool reversed = face.Orientation() == TopAbs_REVERSED;
            for (Standard_Integer i = 1; i <= triangulation->NbTriangles(); ++i) {
                Standard_Integer n1 = 0, n2 = 0, n3 = 0;
                triangulation->Triangle(i).Get(n1, n2, n3);
                MeshTriangle triangle;
                triangle.a = vertexOffset + static_cast<std::uint32_t>(n1 - 1);
                if (reversed) {
                    triangle.b = vertexOffset + static_cast<std::uint32_t>(n3 - 1);
                    triangle.c = vertexOffset + static_cast<std::uint32_t>(n2 - 1);
                } else {
                    triangle.b = vertexOffset + static_cast<std::uint32_t>(n2 - 1);
                    triangle.c = vertexOffset + static_cast<std::uint32_t>(n3 - 1);
                }
                mesh.triangles.push_back(triangle);
            }
        }

        return validate(std::move(mesh));
    }

    static cadnext::Result<TriangleMesh> validate(TriangleMesh mesh) {
        if (mesh.isEmpty()) {
            return meshFailure(cadnext::ErrorCode::KernelOperationFailed,
                               "OCCT meshing produced an empty triangulation");
        }
        const std::uint32_t vertexCount = static_cast<std::uint32_t>(mesh.vertices.size());
        for (const MeshTriangle& triangle : mesh.triangles) {
            if (triangle.a >= vertexCount || triangle.b >= vertexCount ||
                triangle.c >= vertexCount) {
                return meshFailure(cadnext::ErrorCode::KernelOperationFailed,
                                   "OCCT meshing produced out-of-range triangle indices");
            }
        }
        for (const MeshVertex& vertex : mesh.vertices) {
            if (!std::isfinite(vertex.x) || !std::isfinite(vertex.y) ||
                !std::isfinite(vertex.z)) {
                return meshFailure(cadnext::ErrorCode::KernelOperationFailed,
                                   "OCCT meshing produced non-finite vertices");
            }
        }
        return cadnext::Result<TriangleMesh>::ok(std::move(mesh));
    }
};

#else // !CADNEXT_WITH_OCCT

class StubMeshExtractor final : public MeshExtractor {
public:
    cadnext::Result<TriangleMesh> extract(Kernel&, const ShapeHandle&) override {
        return meshFailure(cadnext::ErrorCode::KernelUnavailable,
                           "Mesh extraction requires an OCCT-enabled build "
                           "(CADNEXT_WITH_OCCT=ON)");
    }
};

#endif // CADNEXT_WITH_OCCT

} // namespace

std::unique_ptr<MeshExtractor> makeMeshExtractor() {
#ifdef CADNEXT_WITH_OCCT
    return std::make_unique<OcctMeshExtractor>();
#else
    return std::make_unique<StubMeshExtractor>();
#endif
}

} // namespace cadnext::kernel
