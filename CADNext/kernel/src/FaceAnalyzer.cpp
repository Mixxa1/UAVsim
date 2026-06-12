#include "cadnext/kernel/FaceAnalyzer.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <map>
#include <unordered_map>
#include <utility>

#ifdef CADNEXT_WITH_OCCT
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopAbs_State.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Dir.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt.hxx>

#include "cadnext/kernel/OcctKernel.hpp"
#endif

namespace cadnext::kernel {

namespace {

// FNV-1a over quantized doubles. Quantization (1e-3) makes the hash
// tolerant to evaluation noise while still separating distinct faces.
std::uint32_t fnv1aMix(std::uint32_t hash, std::int64_t value) {
    for (int byte = 0; byte < 8; ++byte) {
        hash ^= static_cast<std::uint32_t>((value >> (byte * 8)) & 0xff);
        hash *= 16777619u;
    }
    return hash;
}

std::int64_t quantize(double value) {
    if (!std::isfinite(value)) {
        return 0;
    }
    return std::llround(value * 1000.0);
}

std::uint32_t hashValues(std::initializer_list<double> values) {
    std::uint32_t hash = 2166136261u;
    for (const double value : values) {
        hash = fnv1aMix(hash, quantize(value));
    }
    return hash;
}

cadnext::Vector3 vecSub(const MeshVertex& a, const MeshVertex& b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

cadnext::Vector3 vecCross(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

double vecDot(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

double vecLength(const cadnext::Vector3& v) {
    return std::sqrt(vecDot(v, v));
}

cadnext::Vector3 normalizedOr(const cadnext::Vector3& v, const cadnext::Vector3& fallback) {
    const double length = vecLength(v);
    if (!std::isfinite(length) || length <= 1.0e-12) {
        return fallback;
    }
    return {v.x / length, v.y / length, v.z / length};
}

std::string hex8(std::uint32_t value) {
    char buffer[16];
    std::snprintf(buffer, sizeof(buffer), "%08x", value);
    return buffer;
}

} // namespace

std::string makeFaceId(int index, cadnext::Vector3 normal, cadnext::Vector3 center,
                       double area) {
    return "face-" + std::to_string(index) + "-" +
           hex8(hashValues({normal.x, normal.y, normal.z})) + "-" +
           hex8(hashValues({center.x, center.y, center.z})) + "-" +
           hex8(hashValues({area}));
}

FaceAnalyzer::FaceAnalyzer(Kernel& kernel) : kernel_(kernel) {}

std::vector<FaceReference> planarFacesForMesh(const std::string& bodyId,
                                              const TriangleMesh& mesh) {
    std::map<std::string, std::vector<const MeshTriangle*>> groups;
    for (const MeshTriangle& triangle : mesh.triangles) {
        if (!triangle.faceId.empty() && triangle.a < mesh.vertices.size() &&
            triangle.b < mesh.vertices.size() && triangle.c < mesh.vertices.size()) {
            groups[triangle.faceId].push_back(&triangle);
        }
    }

    std::vector<FaceReference> faces;
    faces.reserve(groups.size());
    for (const auto& entry : groups) {
        const std::string& faceId = entry.first;
        const std::vector<const MeshTriangle*>& triangles = entry.second;
        if (triangles.empty()) {
            continue;
        }

        FaceReference reference;
        reference.bodyId = bodyId;
        reference.faceId = faceId;
        reference.kind = FaceKind::Planar;
        reference.isSketchable = true;

        std::unordered_map<std::uint32_t, std::uint32_t> reindex;
        cadnext::Vector3 summedNormal{0.0, 0.0, 0.0};
        cadnext::Vector3 weightedCentroid{0.0, 0.0, 0.0};
        double area = 0.0;

        const auto addVertex = [&](std::uint32_t original) {
            auto it = reindex.find(original);
            if (it != reindex.end()) {
                return it->second;
            }
            const std::uint32_t next =
                static_cast<std::uint32_t>(reference.previewMesh.vertices.size());
            reindex[original] = next;
            reference.previewMesh.vertices.push_back(mesh.vertices[original]);
            return next;
        };

        for (const MeshTriangle* triangle : triangles) {
            const MeshVertex& a = mesh.vertices[triangle->a];
            const MeshVertex& b = mesh.vertices[triangle->b];
            const MeshVertex& c = mesh.vertices[triangle->c];
            const cadnext::Vector3 ab = vecSub(b, a);
            const cadnext::Vector3 ac = vecSub(c, a);
            const cadnext::Vector3 normal = vecCross(ab, ac);
            const double triangleArea = vecLength(normal) * 0.5;
            summedNormal.x += normal.x;
            summedNormal.y += normal.y;
            summedNormal.z += normal.z;
            area += triangleArea;
            weightedCentroid.x += (a.x + b.x + c.x) / 3.0 * triangleArea;
            weightedCentroid.y += (a.y + b.y + c.y) / 3.0 * triangleArea;
            weightedCentroid.z += (a.z + b.z + c.z) / 3.0 * triangleArea;

            MeshTriangle out;
            out.a = addVertex(triangle->a);
            out.b = addVertex(triangle->b);
            out.c = addVertex(triangle->c);
            out.faceId = faceId;
            reference.previewMesh.triangles.push_back(std::move(out));
        }

        if (area <= 1.0e-12 || reference.previewMesh.vertices.empty()) {
            continue;
        }
        reference.area = area;
        reference.normal = normalizedOr(summedNormal, {0.0, 0.0, 1.0});
        reference.origin = {weightedCentroid.x / area, weightedCentroid.y / area,
                            weightedCentroid.z / area};

        cadnext::Vector3 uCandidate{1.0, 0.0, 0.0};
        for (const MeshTriangle* triangle : triangles) {
            uCandidate = vecSub(mesh.vertices[triangle->b], mesh.vertices[triangle->a]);
            const double alongNormal = vecDot(uCandidate, reference.normal);
            uCandidate.x -= reference.normal.x * alongNormal;
            uCandidate.y -= reference.normal.y * alongNormal;
            uCandidate.z -= reference.normal.z * alongNormal;
            if (vecLength(uCandidate) > 1.0e-9) {
                break;
            }
        }
        reference.uAxis = normalizedOr(uCandidate, {1.0, 0.0, 0.0});
        reference.vAxis = vecCross(reference.normal, reference.uAxis);
        reference.vAxis = normalizedOr(reference.vAxis, {0.0, 1.0, 0.0});

        double uMin = std::numeric_limits<double>::infinity();
        double uMax = -uMin;
        double vMin = uMin;
        double vMax = -uMin;
        for (const MeshVertex& vertex : reference.previewMesh.vertices) {
            const cadnext::Vector3 delta{vertex.x - reference.origin.x,
                                         vertex.y - reference.origin.y,
                                         vertex.z - reference.origin.z};
            const double u = vecDot(delta, reference.uAxis);
            const double v = vecDot(delta, reference.vAxis);
            uMin = std::min(uMin, u);
            uMax = std::max(uMax, u);
            vMin = std::min(vMin, v);
            vMax = std::max(vMax, v);
        }
        reference.width = std::max(uMax - uMin, 1.0e-6);
        reference.height = std::max(vMax - vMin, 1.0e-6);
        faces.push_back(std::move(reference));
    }
    return faces;
}

#ifdef CADNEXT_WITH_OCCT

namespace {

cadnext::Vector3 toVector(const gp_Pnt& point) {
    return {point.X(), point.Y(), point.Z()};
}

cadnext::Vector3 toVector(const gp_Dir& direction) {
    return {direction.X(), direction.Y(), direction.Z()};
}

cadnext::Vector3 cross(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

double dot(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

FaceKind faceKindFor(GeomAbs_SurfaceType type) {
    switch (type) {
    case GeomAbs_Plane: return FaceKind::Planar;
    case GeomAbs_Cylinder: return FaceKind::Cylindrical;
    case GeomAbs_Cone: return FaceKind::Conical;
    case GeomAbs_Sphere: return FaceKind::Spherical;
    default: return FaceKind::Other;
    }
}

// World-space triangulation of one face (same node/winding handling as
// the body mesh extractor, restricted to this face).
TriangleMesh faceTriangulation(const TopoDS_Face& face) {
    TriangleMesh mesh;
    TopLoc_Location location;
    const Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, location);
    if (triangulation.IsNull()) {
        return mesh;
    }
    const gp_Trsf transform = location.Transformation();
    mesh.vertices.reserve(static_cast<size_t>(triangulation->NbNodes()));
    for (Standard_Integer i = 1; i <= triangulation->NbNodes(); ++i) {
        gp_Pnt point = triangulation->Node(i);
        point.Transform(transform);
        mesh.vertices.push_back({point.X(), point.Y(), point.Z()});
    }
    const bool reversed = face.Orientation() == TopAbs_REVERSED;
    mesh.triangles.reserve(static_cast<size_t>(triangulation->NbTriangles()));
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
        mesh.triangles.push_back(triangle);
    }
    return mesh;
}

double meshArea(const TriangleMesh& mesh) {
    double area = 0.0;
    for (const MeshTriangle& triangle : mesh.triangles) {
        const MeshVertex& a = mesh.vertices[triangle.a];
        const MeshVertex& b = mesh.vertices[triangle.b];
        const MeshVertex& c = mesh.vertices[triangle.c];
        const cadnext::Vector3 ab{b.x - a.x, b.y - a.y, b.z - a.z};
        const cadnext::Vector3 ac{c.x - a.x, c.y - a.y, c.z - a.z};
        const cadnext::Vector3 normal = cross(ab, ac);
        area += 0.5 * std::sqrt(dot(normal, normal));
    }
    return area;
}

bool pointIsInsideShape(const TopoDS_Shape& shape, const cadnext::Vector3& point,
                        double tolerance) {
    BRepClass3d_SolidClassifier classifier(shape);
    classifier.Perform(gp_Pnt(point.x, point.y, point.z), tolerance);
    return classifier.State() == TopAbs_IN;
}

bool normalPointsIntoShape(const TopoDS_Shape& shape, const cadnext::Vector3& origin,
                           const cadnext::Vector3& normal, double diagonal) {
    const double offset = std::max(diagonal * 1.0e-5, 1.0e-6);
    const cadnext::Vector3 probe{origin.x + normal.x * offset,
                                 origin.y + normal.y * offset,
                                 origin.z + normal.z * offset};
    return pointIsInsideShape(shape, probe, std::max(offset * 0.1, 1.0e-7));
}

} // namespace

std::vector<FaceReference> FaceAnalyzer::planarFacesForBody(const std::string& bodyId,
                                                            const ShapeHandle& shape) {
    std::vector<FaceReference> faces;
    auto* occtKernel = dynamic_cast<OcctKernel*>(&kernel_);
    if (!occtKernel) {
        return faces;
    }
    const TopoDS_Shape* topoShape = occtKernel->findShape(shape);
    if (!topoShape || topoShape->IsNull()) {
        return faces;
    }

    try {
        // Reuse the display-mesh deflection so the overlay triangulation
        // matches the body mesh (and meshing is a no-op when the mesh
        // extractor already ran on this shape).
        Bnd_Box bounds;
        BRepBndLib::Add(*topoShape, bounds);
        double diagonal = 1.0;
        if (!bounds.IsVoid()) {
            double xMin = 0.0, yMin = 0.0, zMin = 0.0, xMax = 0.0, yMax = 0.0, zMax = 0.0;
            bounds.Get(xMin, yMin, zMin, xMax, yMax, zMax);
            diagonal = std::sqrt((xMax - xMin) * (xMax - xMin) +
                                 (yMax - yMin) * (yMax - yMin) +
                                 (zMax - zMin) * (zMax - zMin));
        }
        const double linearDeflection = std::max(diagonal * 0.004, 1.0e-4);
        BRepMesh_IncrementalMesh mesher(*topoShape, linearDeflection, Standard_False, 0.3,
                                        Standard_True);

        int index = 0;
        for (TopExp_Explorer explorer(*topoShape, TopAbs_FACE); explorer.More();
             explorer.Next(), ++index) {
            const TopoDS_Face face = TopoDS::Face(explorer.Current());

            FaceReference reference;
            reference.bodyId = bodyId;
            reference.previewMesh = faceTriangulation(face);
            reference.area = meshArea(reference.previewMesh);

            const BRepAdaptor_Surface surface(face);
            reference.kind = faceKindFor(surface.GetType());

            if (reference.kind == FaceKind::Planar) {
                const gp_Pln plane = surface.Plane();

                // Outward normal: the plane axis flipped for REVERSED
                // faces, then an orthonormal right-handed u/v completion
                // (u x v == normal) so face sketches behave exactly like
                // canonical-plane sketches.
                cadnext::Vector3 normal = toVector(plane.Axis().Direction());
                if (face.Orientation() == TopAbs_REVERSED) {
                    normal = {-normal.x, -normal.y, -normal.z};
                }
                const cadnext::Vector3 uAxis = toVector(plane.Position().XDirection());
                const cadnext::Vector3 vAxis = cross(normal, uAxis);

                // Face bounds along u/v from the triangulation: exact for
                // planar faces and already in world coordinates.
                const cadnext::Vector3 planeOrigin = toVector(plane.Location());
                double uMin = std::numeric_limits<double>::infinity();
                double uMax = -uMin;
                double vMin = uMin;
                double vMax = -uMin;
                for (const MeshVertex& vertex : reference.previewMesh.vertices) {
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
                if (reference.previewMesh.vertices.empty()) {
                    uMin = uMax = vMin = vMax = 0.0;
                }

                const double uMid = (uMin + uMax) * 0.5;
                const double vMid = (vMin + vMax) * 0.5;
                reference.origin = {planeOrigin.x + uAxis.x * uMid + vAxis.x * vMid,
                                    planeOrigin.y + uAxis.y * uMid + vAxis.y * vMid,
                                    planeOrigin.z + uAxis.z * uMid + vAxis.z * vMid};
                reference.uAxis = uAxis;
                reference.vAxis = vAxis;
                reference.normal = normal;
                if (normalPointsIntoShape(*topoShape, reference.origin, reference.normal,
                                          diagonal)) {
                    reference.normal = {-reference.normal.x, -reference.normal.y,
                                        -reference.normal.z};
                    reference.vAxis = cross(reference.normal, reference.uAxis);
                }
                reference.width = std::max(uMax - uMin, 1.0e-6);
                reference.height = std::max(vMax - vMin, 1.0e-6);
                reference.isSketchable = true;
            } else {
                // Curved face: report it with its bounds center so the
                // property panel has something to show.
                Bnd_Box faceBounds;
                BRepBndLib::Add(face, faceBounds);
                if (!faceBounds.IsVoid()) {
                    double xMin = 0.0, yMin = 0.0, zMin = 0.0;
                    double xMax = 0.0, yMax = 0.0, zMax = 0.0;
                    faceBounds.Get(xMin, yMin, zMin, xMax, yMax, zMax);
                    reference.origin = {(xMin + xMax) * 0.5, (yMin + yMax) * 0.5,
                                        (zMin + zMax) * 0.5};
                    reference.width = std::max(xMax - xMin, 1.0e-6);
                    reference.height = std::max(yMax - yMin, 1.0e-6);
                }
            }

            reference.faceId =
                makeFaceId(index, reference.normal, reference.origin, reference.area);
            for (MeshTriangle& triangle : reference.previewMesh.triangles) {
                triangle.faceId = reference.faceId;
            }
            faces.push_back(std::move(reference));
        }
    } catch (const Standard_Failure&) {
        faces.clear();
    }
    return faces;
}

#else // !CADNEXT_WITH_OCCT

std::vector<FaceReference> FaceAnalyzer::planarFacesForBody(const std::string&,
                                                            const ShapeHandle&) {
    // No BRep backend: face workflows are unavailable by design.
    return {};
}

#endif // CADNEXT_WITH_OCCT

} // namespace cadnext::kernel
