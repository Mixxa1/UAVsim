#include "cadnext/Extrude.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/WorkPlane.hpp"
#include "cadnext/kernel/ExtrudeMesh.hpp"

#include <cassert>
#include <cmath>

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1.0e-9;
}

void assertVector(cadnext::Vector3 v, double x, double y, double z) {
    assert(nearlyEqual(v.x, x));
    assert(nearlyEqual(v.y, y));
    assert(nearlyEqual(v.z, z));
}

cadnext::SketchProfile unitSquareProfile() {
    cadnext::SketchProfile profile;
    profile.id = "profile-1";
    profile.sketchId = "sketch-1";
    profile.kind = cadnext::SketchProfileKind::Rectangle;
    profile.outerLoop = {{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 1.0}};
    profile.area = 1.0;
    profile.isClosed = true;
    profile.isValid = true;
    return profile;
}

// Bounding extent of all mesh vertices along one world axis.
void meshRange(const cadnext::kernel::TriangleMesh& mesh, int axis, double& minimum,
               double& maximum) {
    minimum = 1.0e30;
    maximum = -1.0e30;
    for (const cadnext::kernel::MeshVertex& vertex : mesh.vertices) {
        const double value = axis == 0 ? vertex.x : (axis == 1 ? vertex.y : vertex.z);
        minimum = std::fmin(minimum, value);
        maximum = std::fmax(maximum, value);
    }
}

void checkPrismSpan(cadnext::SketchPlane plane, cadnext::ExtrudeDirection direction,
                    int normalAxis, double expectedMin, double expectedMax) {
    const cadnext::SketchReference reference = cadnext::canonicalSketchReference(plane);
    cadnext::ExtrudeParameters parameters;
    parameters.sketchId = "sketch-1";
    parameters.profileId = "profile-1";
    parameters.direction = direction;
    parameters.distance = 2.0;

    const auto mesh = cadnext::kernel::buildExtrudedProfileMesh(
        reference, unitSquareProfile(), parameters);
    assert(mesh.isOk());
    assert(!mesh.value().isEmpty());
    // Prism: 2 cap triangles per cap + 2 per side wall = 2*2 + 4*2.
    assert(mesh.value().triangles.size() == 12);

    double minimum = 0.0;
    double maximum = 0.0;
    meshRange(mesh.value(), normalAxis, minimum, maximum);
    assert(nearlyEqual(minimum, expectedMin));
    assert(nearlyEqual(maximum, expectedMax));
}

} // namespace

int main() {
    const cadnext::SketchReference xy = cadnext::canonicalSketchReference(cadnext::SketchPlane::XY);
    const cadnext::SketchReference xz = cadnext::canonicalSketchReference(cadnext::SketchPlane::XZ);
    const cadnext::SketchReference yz = cadnext::canonicalSketchReference(cadnext::SketchPlane::YZ);

    // Positive direction follows the sketch plane normal.
    assertVector(cadnext::extrudeDirectionVector(xy, cadnext::ExtrudeDirection::Positive),
                 0.0, 0.0, 1.0); // XY → +Z
    assertVector(cadnext::extrudeDirectionVector(xz, cadnext::ExtrudeDirection::Positive),
                 0.0, 1.0, 0.0); // XZ → +Y
    assertVector(cadnext::extrudeDirectionVector(yz, cadnext::ExtrudeDirection::Positive),
                 1.0, 0.0, 0.0); // YZ → +X

    // Negative direction is the exact opposite.
    assertVector(cadnext::extrudeDirectionVector(xy, cadnext::ExtrudeDirection::Negative),
                 0.0, 0.0, -1.0);
    assertVector(cadnext::extrudeDirectionVector(xz, cadnext::ExtrudeDirection::Negative),
                 0.0, -1.0, 0.0);
    assertVector(cadnext::extrudeDirectionVector(yz, cadnext::ExtrudeDirection::Negative),
                 -1.0, 0.0, 0.0);

    // Span offsets along +normal.
    cadnext::ExtrudeParameters parameters;
    parameters.distance = 2.0;
    double start = 0.0;
    double end = 0.0;
    parameters.direction = cadnext::ExtrudeDirection::Positive;
    cadnext::extrudeSpan(parameters, start, end);
    assert(nearlyEqual(start, 0.0) && nearlyEqual(end, 2.0));
    parameters.direction = cadnext::ExtrudeDirection::Negative;
    cadnext::extrudeSpan(parameters, start, end);
    assert(nearlyEqual(start, -2.0) && nearlyEqual(end, 0.0));
    parameters.direction = cadnext::ExtrudeDirection::Symmetric;
    cadnext::extrudeSpan(parameters, start, end);
    assert(nearlyEqual(start, -1.0) && nearlyEqual(end, 1.0));

    // The generated prism mesh actually spans the expected world range
    // along each plane normal (axis: 0=X, 1=Y, 2=Z).
    checkPrismSpan(cadnext::SketchPlane::XY, cadnext::ExtrudeDirection::Positive, 2, 0.0, 2.0);
    checkPrismSpan(cadnext::SketchPlane::XZ, cadnext::ExtrudeDirection::Positive, 1, 0.0, 2.0);
    checkPrismSpan(cadnext::SketchPlane::YZ, cadnext::ExtrudeDirection::Positive, 0, 0.0, 2.0);
    checkPrismSpan(cadnext::SketchPlane::XY, cadnext::ExtrudeDirection::Negative, 2, -2.0, 0.0);
    checkPrismSpan(cadnext::SketchPlane::XY, cadnext::ExtrudeDirection::Symmetric, 2, -1.0, 1.0);

    // Invalid input: zero distance and open profiles are rejected.
    cadnext::ExtrudeParameters zeroDistance;
    zeroDistance.sketchId = "sketch-1";
    zeroDistance.profileId = "profile-1";
    zeroDistance.distance = 0.0;
    assert(!cadnext::kernel::buildExtrudedProfileMesh(xy, unitSquareProfile(), zeroDistance)
                .isOk());

    cadnext::SketchProfile open = unitSquareProfile();
    open.isClosed = false;
    open.isValid = false;
    cadnext::ExtrudeParameters ok;
    ok.sketchId = "sketch-1";
    ok.profileId = "profile-1";
    assert(!cadnext::kernel::buildExtrudedProfileMesh(xy, open, ok).isOk());

    return 0;
}
