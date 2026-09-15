#include "cadnext/cfd/FluidMesher.hpp"

#include "cadnext/kernel/OcctKernel.hpp"

#include <meshing.hpp>
#include <meshing/boundarylayer.hpp>
#include <netgen_version.hpp>
#include <occgeom.hpp>

#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <limits>
#include <map>
#include <mutex>
#include <set>

namespace cadnext::cfd {

namespace {

Result<FluidMesh> failure(ErrorCode code, const std::string& message) {
    return Result<FluidMesh>::fail({code, message});
}

std::mutex& netgenMutex() {
    static std::mutex mutex;
    return mutex;
}

using Point = std::array<double, 3>;

double tetVolume(const Point& a, const Point& b, const Point& c, const Point& d) {
    const Point u{b[0] - a[0], b[1] - a[1], b[2] - a[2]};
    const Point v{c[0] - a[0], c[1] - a[1], c[2] - a[2]};
    const Point w{d[0] - a[0], d[1] - a[1], d[2] - a[2]};
    return (u[0] * (v[1] * w[2] - v[2] * w[1]) - u[1] * (v[0] * w[2] - v[2] * w[0]) + u[2] * (v[0] * w[1] - v[1] * w[0])) / 6.0;
}

// Signed volume in VTK node order: tetrahedron (0,1,2,3); wedge bottom (0,1,2), top (3,4,5); pyramid
// base (0,1,2,3), apex 4. Positive when the VTK convention holds.
double signedVolume(const std::vector<Point>& p, const Su2Element& e) {
    const auto& n = e.nodes;
    switch (e.type) {
    case Su2ElementType::Tetrahedron:
        return tetVolume(p[n[0]], p[n[1]], p[n[2]], p[n[3]]);
    case Su2ElementType::Prism:
        return tetVolume(p[n[0]], p[n[1]], p[n[2]], p[n[3]]) + tetVolume(p[n[1]], p[n[2]], p[n[3]], p[n[4]])
               + tetVolume(p[n[2]], p[n[3]], p[n[4]], p[n[5]]);
    case Su2ElementType::Pyramid:
        return tetVolume(p[n[0]], p[n[1]], p[n[2]], p[n[4]]) + tetVolume(p[n[0]], p[n[2]], p[n[3]], p[n[4]]);
    default:
        return 0.0;
    }
}

void mirror(Su2Element& e) {
    auto& n = e.nodes;
    switch (e.type) {
    case Su2ElementType::Tetrahedron: std::swap(n[1], n[2]); break;
    case Su2ElementType::Prism: std::swap(n[1], n[2]); std::swap(n[4], n[5]); break;
    case Su2ElementType::Pyramid: std::swap(n[1], n[3]); break;
    default: break;
    }
}

} // namespace

Result<FluidMesh> meshFluidDomain(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& handle,
                                  const std::map<int, std::string>& wallMarkers, const FluidMeshSettings& settings) {
    const TopoDS_Shape* shape = kernel.findShape(handle);
    if (shape == nullptr || shape->IsNull()) return failure(ErrorCode::NotFound, "нет расчётной области");
    if (!(settings.farfieldElementSizeM > 0.0) || !(settings.wallElementSizeM > 0.0)) {
        return failure(ErrorCode::InvalidArgument, "не заданы размеры элементов у стенки и в дальнем поле");
    }
    if (wallMarkers.empty()) return failure(ErrorCode::InvalidArgument, "не указаны стенки");
    std::set<std::string> markerNames;
    for (const auto& [face, name] : wallMarkers) {
        const bool plain = !name.empty() && std::all_of(name.begin(), name.end(), [](unsigned char c) { return std::isalnum(c) || c == '_' || c == '-'; });
        if (!plain || name == "farfield") return failure(ErrorCode::InvalidArgument, "недопустимое имя стенки «" + name + "»");
        markerNames.insert(name);
    }
    for (double height : settings.layerHeightsM) {
        if (!(height > 0.0)) return failure(ErrorCode::InvalidArgument, "высота призматического слоя должна быть положительной");
    }

    std::vector<TopoDS_Shape> kernelFaces;
    for (TopExp_Explorer explorer(*shape, TopAbs_FACE); explorer.More(); explorer.Next()) kernelFaces.push_back(explorer.Current());
    for (const auto& [face, name] : wallMarkers) {
        if (face < 0 || face >= static_cast<int>(kernelFaces.size())) {
            return failure(ErrorCode::NotFound, "нет грани face-" + std::to_string(face));
        }
    }

    std::lock_guard<std::mutex> lock(netgenMutex());
    netgen::printmessage_importance = 0;
    // Names and sizes travel with the faces; Netgen reads them when it builds the geometry.
    for (int k = 0; k < static_cast<int>(kernelFaces.size()); ++k) {
        auto& properties = netgen::OCCGeometry::GetProperties(kernelFaces[k]);
        const auto wall = wallMarkers.find(k);
        properties.name = wall != wallMarkers.end() ? wall->second : "farfield";
        properties.maxh = wall != wallMarkers.end() ? settings.wallElementSizeM : 1e99;
    }

    std::shared_ptr<netgen::Mesh> ngMesh;
    std::shared_ptr<netgen::OCCGeometry> geometry;
    try {
        geometry = std::make_shared<netgen::OCCGeometry>(*shape);
        netgen::MeshingParameters parameters;
        parameters.maxh = settings.farfieldElementSizeM;
        parameters.grading = settings.grading;
        ngMesh = std::make_shared<netgen::Mesh>();
        ngMesh->SetGeometry(geometry);
        if (geometry->GenerateMesh(ngMesh, parameters) != 0) {
            return failure(ErrorCode::KernelOperationFailed, "Netgen не построил объёмную сетку области течения");
        }
        if (!settings.layerHeightsM.empty()) {
            netgen::BoundaryLayerParameters layer;
            layer.thickness = settings.layerHeightsM;
            // Names are plain (checked above), so they are their own regular expressions.
            std::string walls;
            for (const auto& name : markerNames) walls += (walls.empty() ? "" : "|") + name;
            layer.boundary = "(" + walls + ")";
            layer.domain = 1;
            // Shrink a layer where it would run into itself (narrow gaps, sharp concave corners)
            // instead of producing crossing prisms.
            layer.limit_growth_vectors = true;
            netgen::GenerateBoundaryLayer(*ngMesh, layer);
        }
    } catch (const std::exception& error) {
        return failure(ErrorCode::KernelOperationFailed, std::string("Netgen: ") + error.what());
    }

    FluidMesh result;
    Su2Mesh& mesh = result.mesh;
    mesh.dimension = 3;
    const int first = static_cast<int>(netgen::PointIndex::BASE);
    for (const auto& point : ngMesh->Points()) mesh.points.push_back({point(0), point(1), point(2)});

    result.smallestVolumeM3 = std::numeric_limits<double>::infinity();
    for (const auto& element : ngMesh->VolumeElements()) {
        Su2Element out;
        switch (element.GetNP()) {
        case 4: out.type = Su2ElementType::Tetrahedron; ++result.tetrahedra; break;
        case 5: out.type = Su2ElementType::Pyramid; ++result.pyramids; break;
        case 6: out.type = Su2ElementType::Prism; ++result.prisms; break;
        default: return failure(ErrorCode::KernelOperationFailed, "Netgen вернул элемент с " + std::to_string(element.GetNP()) + " узлами");
        }
        for (int n = 0; n < element.GetNP(); ++n) out.nodes.push_back(static_cast<int>(element[n]) - first);
        double volume = signedVolume(mesh.points, out);
        if (volume < 0.0) {
            mirror(out);
            volume = -volume;
        }
        if (!(volume > 0.0)) return failure(ErrorCode::ShapeInvalid, "вырожденный элемент в сетке области течения");
        result.smallestVolumeM3 = std::min(result.smallestVolumeM3, volume);
        mesh.elements.push_back(std::move(out));
    }

    std::map<std::string, std::vector<Su2Element>> boundaries;
    for (const auto& surface : ngMesh->SurfaceElements()) {
        Su2Element out;
        out.type = surface.GetNP() == 3 ? Su2ElementType::Triangle : Su2ElementType::Quadrilateral;
        for (int n = 0; n < surface.GetNP(); ++n) out.nodes.push_back(static_cast<int>(surface[n]) - first);
        boundaries[ngMesh->GetFaceDescriptor(surface.GetIndex()).GetBCName()].push_back(std::move(out));
    }
    for (const auto& name : markerNames) {
        auto it = boundaries.find(name);
        if (it == boundaries.end() || it->second.empty()) {
            return failure(ErrorCode::KernelOperationFailed, "в сетке нет поверхности стенки «" + name + "»");
        }
        mesh.markers.emplace_back(name, std::move(it->second));
        boundaries.erase(it);
    }
    for (auto& [name, elements] : boundaries) {
        if (name != "farfield") return failure(ErrorCode::KernelOperationFailed, "в сетке неизвестная граница «" + name + "»");
        mesh.markers.emplace_back(name, std::move(elements));
    }
    result.mesherVersion = std::string("netgen ") + NETGEN_VERSION;
    return Result<FluidMesh>::ok(std::move(result));
}

} // namespace cadnext::cfd
