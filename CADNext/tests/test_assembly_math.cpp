// Assembly math: quaternion algebra, placement composition and frame
// conversion invariants used by both assembly solvers.
#include "cadnext/assembly/AssemblyMath.hpp"

#include <cassert>
#include <cmath>

using namespace cadnext::assembly;

namespace {

constexpr double kTol = 1.0e-9;

void checkVector(const cadnext::Vector3& v, double x, double y, double z,
                 double tolerance = kTol) {
    assert(nearlyEqual(v.x, x, tolerance));
    assert(nearlyEqual(v.y, y, tolerance));
    assert(nearlyEqual(v.z, z, tolerance));
}

} // namespace

int main() {
    // 90° around Z maps X onto Y.
    const Quaternion qz = Quaternion::fromAxisAngle({0.0, 0.0, 1.0}, M_PI / 2.0);
    checkVector(qz.rotate({1.0, 0.0, 0.0}), 0.0, 1.0, 0.0);

    // Composition: 90°Z then 90°X (multiply applies rhs first).
    const Quaternion qx = Quaternion::fromAxisAngle({1.0, 0.0, 0.0}, M_PI / 2.0);
    const Quaternion combined = qx.multiply(qz);
    // X → (90°Z) → Y → (90°X) → Z.
    checkVector(combined.rotate({1.0, 0.0, 0.0}), 0.0, 0.0, 1.0);

    // Conjugate inverts the rotation.
    checkVector(qz.conjugate().rotate(qz.rotate({1.0, 0.0, 0.0})), 1.0, 0.0, 0.0);

    // rotationBetween maps `from` onto `to`, including the antiparallel case.
    const Quaternion between =
        Quaternion::rotationBetween({1.0, 0.0, 0.0}, {0.0, 0.0, 1.0});
    checkVector(between.rotate({1.0, 0.0, 0.0}), 0.0, 0.0, 1.0);
    const Quaternion flip =
        Quaternion::rotationBetween({0.0, 0.0, 1.0}, {0.0, 0.0, -1.0});
    checkVector(flip.rotate({0.0, 0.0, 1.0}), 0.0, 0.0, -1.0);

    // Placement compose/apply: parent(translate +X, rotate 90°Z) ∘ child(translate +Y).
    Placement parent;
    parent.translation = {1.0, 0.0, 0.0};
    parent.rotation = qz;
    Placement child;
    child.translation = {0.0, 1.0, 0.0};
    const Placement composed = parent.compose(child);
    // Child origin: rotate (0,1,0) by 90°Z → (-1,0,0), plus (1,0,0) → (0,0,0).
    checkVector(composed.apply({0.0, 0.0, 0.0}), 0.0, 0.0, 0.0);

    // inverse ∘ placement == identity.
    const Placement roundTrip = parent.inverse().compose(parent);
    checkVector(roundTrip.apply({0.3, -0.7, 2.5}), 0.3, -0.7, 2.5);
    checkVector(roundTrip.translation, 0.0, 0.0, 0.0);

    // Frame::fromOriginZX orthonormalizes and stays right-handed.
    const Frame frame = Frame::fromOriginZX({1.0, 2.0, 3.0}, {0.0, 0.0, 2.0},
                                            {0.7, 0.1, 0.4});
    assert(nearlyEqual(length(frame.xAxis), 1.0, kTol));
    assert(nearlyEqual(length(frame.yAxis), 1.0, kTol));
    assert(nearlyEqual(length(frame.zAxis), 1.0, kTol));
    assert(nearlyEqual(dot(frame.xAxis, frame.zAxis), 0.0, kTol));
    assert(nearlyEqual(dot(frame.yAxis, frame.zAxis), 0.0, kTol));
    checkVector(cross(frame.xAxis, frame.yAxis), frame.zAxis.x, frame.zAxis.y,
                frame.zAxis.z);

    // Frame → Placement: rotation maps unit axes onto the frame axes and
    // the translation is the origin.
    const Placement framePlacement = frame.toPlacement();
    checkVector(framePlacement.applyDirection({1.0, 0.0, 0.0}), frame.xAxis.x,
                frame.xAxis.y, frame.xAxis.z, 1.0e-8);
    checkVector(framePlacement.applyDirection({0.0, 0.0, 1.0}), frame.zAxis.x,
                frame.zAxis.y, frame.zAxis.z, 1.0e-8);
    checkVector(framePlacement.apply({0.0, 0.0, 0.0}), 1.0, 2.0, 3.0);

    // Degenerate X hint (parallel to Z) still yields an orthonormal frame.
    const Frame degenerate = Frame::fromOriginZX({0.0, 0.0, 0.0}, {0.0, 0.0, 1.0},
                                                 {0.0, 0.0, 5.0});
    assert(nearlyEqual(length(degenerate.xAxis), 1.0, kTol));
    assert(nearlyEqual(dot(degenerate.xAxis, degenerate.zAxis), 0.0, kTol));

    // stablePerpendicular is deterministic and perpendicular.
    const cadnext::Vector3 perpendicular = stablePerpendicular({0.0, 0.0, 1.0});
    assert(nearlyEqual(dot(perpendicular, {0.0, 0.0, 1.0}), 0.0, kTol));
    assert(nearlyEqual(length(perpendicular), 1.0, kTol));

    // transformedBy moves origin and axes rigidly.
    const Frame moved = frame.transformedBy(parent);
    checkVector(moved.origin, parent.apply(frame.origin).x, parent.apply(frame.origin).y,
                parent.apply(frame.origin).z);

    return 0;
}
