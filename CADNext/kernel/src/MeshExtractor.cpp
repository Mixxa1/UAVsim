#include "cadnext/kernel/MeshExtractor.hpp"

#include <cmath>
#include <limits>
#include <utility>

#ifdef CADNEXT_WITH_OCCT
#include <algorithm>

#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>

#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#endif

namespace cadnext::kernel {

namespace {

cadnext::Result<TriangleMesh> meshFailure(cadnext::ErrorCode code, std::string message) {
    return cadnext::Result<TriangleMesh>::fail({code, std::move(message)});
}

#ifdef CADNEXT_WITH_OCCT

cadnext::Vector3 cross(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

double dot(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

double triangleMeshArea(const std::vector<MeshVertex>& vertices,
                        const std::vector<MeshTriangle>& triangles) {
    double area = 0.0;
    for (const MeshTriangle& triangle : triangles) {
        const MeshVertex& a = vertices[triangle.a];
        const MeshVertex& b = vertices[triangle.b];
        const MeshVertex& c = vertices[triangle.c];
        const cadnext::Vector3 ab{b.x - a.x, b.y - a.y, b.z - a.z};
        const cadnext::Vector3 ac{c.x - a.x, c.y - a.y, c.z - a.z};
        const cadnext::Vector3 normal = cross(ab, ac);
        area += 0.5 * std::sqrt(dot(normal, normal));
    }
    return area;
}

std::string faceIdForOcctFace(int index, const TopoDS_Face& face,
                              const std::vector<MeshVertex>& vertices,
                              const std::vector<MeshTriangle>& triangles) {
    cadnext::Vector3 normal{0.0, 0.0, 1.0};
    cadnext::Vector3 origin{0.0, 0.0, 0.0};
    const double area = triangleMeshArea(vertices, triangles);

    const BRepAdaptor_Surface surface(face);
    if (surface.GetType() == GeomAbs_Plane) {
        const gp_Pln plane = surface.Plane();
        normal = {plane.Axis().Direction().X(), plane.Axis().Direction().Y(),
                  plane.Axis().Direction().Z()};
        if (face.Orientation() == TopAbs_REVERSED) {
            normal = {-normal.x, -normal.y, -normal.z};
        }
        const cadnext::Vector3 uAxis{plane.Position().XDirection().X(),
                                     plane.Position().XDirection().Y(),
                                     plane.Position().XDirection().Z()};
        const cadnext::Vector3 vAxis = cross(normal, uAxis);
        const cadnext::Vector3 planeOrigin{plane.Location().X(), plane.Location().Y(),
                                           plane.Location().Z()};

        double uMin = std::numeric_limits<double>::infinity();
        double uMax = -uMin;
        double vMin = uMin;
        double vMax = -uMin;
        for (const MeshVertex& vertex : vertices) {
            const cadnext::Vector3 delta{vertex.x - planeOrigin.x,
                                         vertex.y - planeOrigin.y,
                                         vertex.z - planeOrigin.z};
            const double u = dot(delta, uAxis);
            const double v = dot(delta, vAxis);
            uMin = std::min(uMin, u);
            uMax = std::max(uMax, u);
            vMin = std::min(vMin, v);
            vMax = std::max(vMax, v);
        }
        if (vertices.empty()) {
            uMin = uMax = vMin = vMax = 0.0;
        }
        const double uMid = (uMin + uMax) * 0.5;
        const double vMid = (vMin + vMax) * 0.5;
        origin = {planeOrigin.x + uAxis.x * uMid + vAxis.x * vMid,
                  planeOrigin.y + uAxis.y * uMid + vAxis.y * vMid,
                  planeOrigin.z + uAxis.z * uMid + vAxis.z * vMid};
    } else {
        Bnd_Box faceBounds;
        BRepBndLib::Add(face, faceBounds);
        if (!faceBounds.IsVoid()) {
            double xMin = 0.0, yMin = 0.0, zMin = 0.0;
            double xMax = 0.0, yMax = 0.0, zMax = 0.0;
            faceBounds.Get(xMin, yMin, zMin, xMax, yMax, zMax);
            origin = {(xMin + xMax) * 0.5, (yMin + yMax) * 0.5,
                      (zMin + zMax) * 0.5};
        }
    }
    return makeFaceId(index, normal, origin, area);
}

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
        int faceIndex = 0;
        for (TopExp_Explorer faces(shape, TopAbs_FACE); faces.More(); faces.Next(), ++faceIndex) {
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
            std::vector<MeshVertex> faceVertices;
            faceVertices.reserve(static_cast<size_t>(triangulation->NbNodes()));

            for (Standard_Integer i = 1; i <= triangulation->NbNodes(); ++i) {
                gp_Pnt point = triangulation->Node(i);
                point.Transform(transform);
                faceVertices.push_back({point.X(), point.Y(), point.Z()});
            }

            // OCCT triangulation is CCW for FORWARD faces; REVERSED faces
            // need flipped winding so outward normals stay consistent.
            const bool reversed = face.Orientation() == TopAbs_REVERSED;
            std::vector<MeshTriangle> faceTriangles;
            faceTriangles.reserve(static_cast<size_t>(triangulation->NbTriangles()));
            for (Standard_Integer i = 1; i <= triangulation->NbTriangles(); ++i) {
                Standard_Integer n1 = 0, n2 = 0, n3 = 0;
                triangulation->Triangle(i).Get(n1, n2, n3);
                MeshTriangle triangle;
                triangle.a = static_cast<std::uint32_t>(n1 - 1);
                if (reversed) {
                    triangle.b = static_cast<std::uint32_t>(n3 - 1);
                    triangle.c = static_cast<std::uint32_t>(n2 - 1);
                } else {
                    triangle.b = static_cast<std::uint32_t>(n2 - 1);
                    triangle.c = static_cast<std::uint32_t>(n3 - 1);
                }
                faceTriangles.push_back(triangle);
            }

            const std::string faceId =
                faceIdForOcctFace(faceIndex, face, faceVertices, faceTriangles);
            for (const MeshVertex& vertex : faceVertices) {
                mesh.vertices.push_back(vertex);
            }
            for (MeshTriangle triangle : faceTriangles) {
                triangle.a += vertexOffset;
                triangle.b += vertexOffset;
                triangle.c += vertexOffset;
                triangle.faceId = faceId;
                mesh.triangles.push_back(std::move(triangle));
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
