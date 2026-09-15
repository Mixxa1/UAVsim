#include "cadnext/fea/SolidMesher.hpp"

#include "cadnext/fea/TetElement.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

// Netgen's C++ interface: nglib's C API cannot say which CAD face a surface triangle came from.
#include <meshing.hpp>
#include <netgen_version.hpp>
#include <occgeom.hpp>

#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS_Shape.hxx>

#include <algorithm>
#include <array>
#include <map>
#include <mutex>

namespace cadnext::fea {

namespace {

Result<SolidMesh> failure(ErrorCode code, const std::string& message) {
    return Result<SolidMesh>::fail({code, message});
}

// Netgen keeps meshing state in globals (parameters, message level, the multithread task
// record). One mesh at a time.
std::mutex& netgenMutex() {
    static std::mutex mutex;
    return mutex;
}

// Netgen's TET10 midsides are on edges (0,1) (0,2) (0,3) (1,2) (1,3) (2,3) — see
// netgen/libsrc/meshing/secondorder.cpp. Ours are (0,1) (1,2) (0,2) (0,3) (1,3) (2,3).
constexpr std::array<int, 6> kNetgenMidsideForOurs = {4, 7, 5, 6, 8, 9};

} // namespace

std::string solidFaceGroup(int faceIndex) {
    return "face-" + std::to_string(faceIndex);
}

Result<SolidMesh> meshSolid(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& handle,
                            const SolidMeshingSettings& settings) {
    const TopoDS_Shape* shape = kernel.findShape(handle);
    if (shape == nullptr || shape->IsNull()) {
        return failure(ErrorCode::NotFound, "нет тела для построения сетки");
    }
    if (!(settings.maximumElementSizeM > 0.0)) {
        return failure(ErrorCode::InvalidArgument, "не задан максимальный размер элемента");
    }

    SolidMesh result;
    {
        GProp_GProps properties;
        BRepGProp::VolumeProperties(*shape, properties);
        result.cadVolumeM3 = properties.Mass();
    }
    if (!(result.cadVolumeM3 > 0.0)) {
        return failure(ErrorCode::ShapeInvalid, "у тела нет положительного объёма (не твёрдое тело?)");
    }

    // The kernel's face numbering: TopExp_Explorer order over the whole shape.
    std::vector<TopoDS_Shape> kernelFaces;
    for (TopExp_Explorer explorer(*shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        kernelFaces.push_back(explorer.Current());
    }
    result.cadFaceCount = static_cast<int>(kernelFaces.size());

    std::lock_guard<std::mutex> lock(netgenMutex());
    netgen::printmessage_importance = 0;
    std::shared_ptr<netgen::Mesh> ngMesh;
    std::shared_ptr<netgen::OCCGeometry> geometry;
    try {
        geometry = std::make_shared<netgen::OCCGeometry>(*shape);
        netgen::MeshingParameters parameters;
        parameters.maxh = settings.maximumElementSizeM;
        parameters.grading = settings.grading;
        parameters.curvaturesafety = settings.curvatureSafety;
        parameters.segmentsperedge = settings.segmentsPerEdge;
        parameters.optsteps3d = settings.optimizationSteps3d;
        ngMesh = std::make_shared<netgen::Mesh>();
        ngMesh->SetGeometry(geometry);
        if (geometry->GenerateMesh(ngMesh, parameters) != 0) {
            return failure(ErrorCode::KernelOperationFailed, "Netgen не построил объёмную сетку");
        }
        if (settings.order == ElementOrder::Quadratic) {
            geometry->GetRefinement().MakeSecondOrder(*ngMesh);
        }
    } catch (const std::exception& error) {
        return failure(ErrorCode::KernelOperationFailed, std::string("Netgen: ") + error.what());
    }

    // Netgen face number (fmap index) → kernel face index, by shape identity rather than by
    // assuming both walks visit faces in the same order.
    std::map<int, int> kernelFaceOf;
    for (int k = 0; k < static_cast<int>(kernelFaces.size()); ++k) {
        const int netgenIndex = geometry->fmap.FindIndex(kernelFaces[k]);
        if (netgenIndex > 0 && kernelFaceOf.find(netgenIndex) == kernelFaceOf.end()) {
            kernelFaceOf[netgenIndex] = k;
        }
    }

    TetMesh& mesh = result.mesh;
    mesh.order = settings.order;
    const auto& points = ngMesh->Points();
    mesh.nodes.reserve(points.Size());
    for (const auto& point : points) {
        mesh.nodes.push_back({point(0), point(1), point(2)});
    }
    const int firstPoint = static_cast<int>(netgen::PointIndex::BASE);

    const int expectedNodes = settings.order == ElementOrder::Quadratic ? 10 : 4;
    for (const auto& element : ngMesh->VolumeElements()) {
        if (element.GetNP() != expectedNodes) {
            return failure(ErrorCode::KernelOperationFailed, "Netgen вернул не тетраэдр");
        }
        std::array<int, 10> nodes{};
        nodes.fill(-1);
        for (int n = 0; n < 4; ++n) nodes[n] = static_cast<int>(element[n]) - firstPoint;
        if (expectedNodes == 10) {
            for (int e = 0; e < 6; ++e) nodes[4 + e] = static_cast<int>(element[kNetgenMidsideForOurs[e]]) - firstPoint;
        }
        const Vec3 a = mesh.nodes[nodes[1]] - mesh.nodes[nodes[0]];
        const Vec3 b = mesh.nodes[nodes[2]] - mesh.nodes[nodes[0]];
        const Vec3 c = mesh.nodes[nodes[3]] - mesh.nodes[nodes[0]];
        if (dot(a, cross(b, c)) < 0.0) {
            // Mirror consistently: corners 1↔2 carry midsides (0,1)↔(0,2) and (1,3)↔(2,3).
            std::swap(nodes[1], nodes[2]);
            std::swap(nodes[4], nodes[6]);
            std::swap(nodes[8], nodes[9]);
        }
        mesh.elements.push_back(nodes);
    }

    // Boundary triangles → (element, local face) by their sorted corner triple.
    std::map<std::array<int, 3>, BoundaryFace> faceOfTriple;
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        for (int f = 0; f < 4; ++f) {
            std::array<int, 3> triple = {mesh.elements[e][kTetFaces[f][0]], mesh.elements[e][kTetFaces[f][1]],
                                         mesh.elements[e][kTetFaces[f][2]]};
            std::sort(triple.begin(), triple.end());
            faceOfTriple[triple] = {e, f};
        }
    }
    for (const auto& surface : ngMesh->SurfaceElements()) {
        std::array<int, 3> triple = {static_cast<int>(surface[0]) - firstPoint, static_cast<int>(surface[1]) - firstPoint,
                                     static_cast<int>(surface[2]) - firstPoint};
        std::sort(triple.begin(), triple.end());
        const auto found = faceOfTriple.find(triple);
        if (found == faceOfTriple.end()) {
            return failure(ErrorCode::KernelOperationFailed, "поверхностный треугольник Netgen не лежит на грани элемента");
        }
        const int netgenFace = ngMesh->GetFaceDescriptor(surface.GetIndex()).SurfNr();
        const auto kernelFace = kernelFaceOf.find(netgenFace);
        if (kernelFace == kernelFaceOf.end()) {
            return failure(ErrorCode::KernelOperationFailed, "грань Netgen не найдена среди граней тела");
        }
        mesh.faceGroups[solidFaceGroup(kernelFace->second)].push_back(found->second);
    }

    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        const double minimumJacobian = tetMinimumJacobian(mesh, e);
        if (!(minimumJacobian > 0.0)) {
            return failure(ErrorCode::ShapeInvalid,
                           "элемент " + std::to_string(e) + " после проецирования на поверхность вывернут");
        }
        result.meshVolumeM3 += tetVolume(mesh, e);
    }
    result.mesherVersion = std::string("netgen ") + NETGEN_VERSION;
    return Result<SolidMesh>::ok(std::move(result));
}

} // namespace cadnext::fea
