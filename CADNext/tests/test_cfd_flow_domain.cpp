// The fluid domain around a `.uavframe` airframe: bodies cut out of a box in one boolean, every wall
// face traced back to its body and body face, walls meshed as one marker per body.
//
//   cadnext_test_cfd_flow_domain <bridge schema directory>
//
// The airframe is the v2 schema example: a plate 0.2 × 0.2 × 0.01 (z 0…0.01) and an arm 0.3 long,
// 0.02 × 0.02 (z 0…0.02) butting against one of the plate's edge faces. The bodies' BRep is in the
// CAD frame (the example's cadAxes: forward +x, up +z), so the arm runs along +x here. Where they touch, a 0.02 × 0.01 rectangle,
// both faces are inside the aircraft and must leave the wall. Everything checked is exact geometry:
//   wall area of the plate 0.088 − 0.0002, of the arm 0.0248 − 0.0002, both planar, so the meshed
//   marker areas must equal them to rounding.

#include "fea_test_support.hpp"

#include "cadnext/bridge/ConstructionExport.hpp"
#include "cadnext/cfd/FlowDomain.hpp"
#include "cadnext/cfd/FluidMesher.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cmath>
#include <map>

using namespace cadnext;
using fea_test::check;

namespace {

double triangleArea(const cfd::Su2Mesh& mesh, const cfd::Su2Element& e) {
    const auto& a = mesh.points[e.nodes[0]];
    const auto& b = mesh.points[e.nodes[1]];
    const auto& c = mesh.points[e.nodes[2]];
    const double u[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
    const double v[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
    const double n[3] = {u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]};
    return 0.5 * std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::printf("usage: %s <bridge schema directory>\n", argv[0]);
        return 64;
    }
    const auto frame = bridge::ConstructionExport::loadFromFile(std::string(argv[1]) + "/uavframe-v2.example.json");
    if (!frame.isOk()) {
        check(false, "schema example loads", frame.error().message);
        return fea_test::finish("test_cfd_flow_domain");
    }
    kernel::OcctKernel kernel;
    std::vector<cfd::FlowBody> bodies;
    for (const auto& body : frame.value().bodies) {
        const auto shape = kernel.importBRep(std::vector<std::uint8_t>(body.brep.begin(), body.brep.end()));
        check(shape.isOk(), body.id + ": exact geometry imports");
        if (!shape.isOk()) return fea_test::finish("test_cfd_flow_domain");
        bodies.push_back({body.id, shape.value()});
    }
    check(bodies.size() == 2 && bodies[0].id == "plate" && bodies[1].id == "arm", "the example is a plate and an arm");

    check(!cfd::buildFlowDomain(kernel, bodies, {}).isOk(), "a domain without a far-field distance is refused");
    const auto built = cfd::buildFlowDomain(kernel, bodies, {2.0});
    if (!built.isOk()) {
        check(false, "flow domain builds", built.error().message);
        return fea_test::finish("test_cfd_flow_domain");
    }
    const auto& domain = built.value();
    check(std::fabs(domain.referenceLengthM - 0.5) < 1e-9, "reference length is the aircraft's largest dimension, 0.5 m");
    std::printf("  box %.3f…%.3f × %.3f…%.3f × %.3f…%.3f, reference length %.4f\n", domain.boundsMin[0], domain.boundsMax[0],
                domain.boundsMin[1], domain.boundsMax[1], domain.boundsMin[2], domain.boundsMax[2], domain.referenceLengthM);

    const auto faces = kernel::FaceAnalyzer(kernel).planarFacesForBody("domain", domain.domain);
    std::map<std::string, double> wallArea;
    std::map<std::string, int> wallFaces;
    for (const auto& wall : domain.walls) {
        wallArea[wall.bodyId] += faces.at(wall.domainFace).area;
        ++wallFaces[wall.bodyId];
        std::printf("  domain face %d ← %s %s, area %.6f\n", wall.domainFace, wall.bodyId.c_str(), wall.bodyFace.c_str(),
                    faces.at(wall.domainFace).area);
    }
    check(faces.size() == domain.walls.size() + 6, "every domain face is a wall or one of the six box faces");
    check(domain.hiddenFaces.empty(), "no body face is entirely covered (the contact covers only part of each)");
    // The contact runs across the plate's whole 0.01 thickness and splits its edge face in two; on the
    // arm's 0.02 end face it takes the lower half and leaves one face.
    check(wallFaces["plate"] == 7 && wallFaces["arm"] == 6, "plate: seven wall faces (edge face split by the arm); arm: six");
    check(std::fabs(wallArea["plate"] - (0.088 - 0.0002)) < 1e-9, "plate wall area excludes the contact patch");
    check(std::fabs(wallArea["arm"] - (0.0248 - 0.0002)) < 1e-9, "arm wall area excludes the contact patch");

    std::map<int, std::string> markers;
    for (const auto& wall : domain.walls) markers[wall.domainFace] = wall.bodyId;
    cfd::FluidMeshSettings settings;
    settings.wallElementSizeM = 0.01;
    settings.farfieldElementSizeM = 0.25;
    check(!cfd::meshFluidDomain(kernel, domain.domain, {{domain.walls[0].domainFace, "far field"}}, settings).isOk(),
          "a wall marker name with a space is refused");
    check(!cfd::meshFluidDomain(kernel, domain.domain, {{domain.walls[0].domainFace, "farfield"}}, settings).isOk(),
          "a wall marker cannot be called farfield");
    const auto meshed = cfd::meshFluidDomain(kernel, domain.domain, markers, settings);
    if (!meshed.isOk()) {
        check(false, "flow domain meshes", meshed.error().message);
        return fea_test::finish("test_cfd_flow_domain");
    }
    const auto& mesh = meshed.value().mesh;
    check(mesh.markers.size() == 3 && mesh.markers[0].first == "arm" && mesh.markers[1].first == "plate" && mesh.markers[2].first == "farfield",
          "markers: one per body in name order, then the far field");
    std::map<std::string, double> meshedArea;
    for (const auto& [name, elements] : mesh.markers) {
        for (const auto& e : elements) meshedArea[name] += triangleArea(mesh, e);
    }
    std::printf("  meshed: %zu tetrahedra; arm %.8f, plate %.8f, far field %.6f m²\n", meshed.value().tetrahedra, meshedArea["arm"],
                meshedArea["plate"], meshedArea["farfield"]);
    check(std::fabs(meshedArea["plate"] - (0.088 - 0.0002)) < 1e-9 && std::fabs(meshedArea["arm"] - (0.0248 - 0.0002)) < 1e-9,
          "meshed wall markers carry exactly each body's wetted area");
    const double margin = 2.0 * domain.referenceLengthM;
    const double dx = domain.boundsMax[0] - domain.boundsMin[0] + 2 * margin;
    const double dy = domain.boundsMax[1] - domain.boundsMin[1] + 2 * margin;
    const double dz = domain.boundsMax[2] - domain.boundsMin[2] + 2 * margin;
    const double boxArea = 2 * (dx * dy + dy * dz + dz * dx);
    check(std::fabs(meshedArea["farfield"] - boxArea) < 1e-9 * boxArea, "the far-field marker is the whole box surface");
    return fea_test::finish("test_cfd_flow_domain");
}
