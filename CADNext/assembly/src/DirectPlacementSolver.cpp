#include "cadnext/assembly/DirectPlacementSolver.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::assembly {

namespace {

// Rotation of the whole child component about a world-space pivot,
// preserving its position elsewhere (the minimal-motion path for
// direction-only constraints).
Placement rotateAboutPivot(const Placement& placement, const Vector3& pivot,
                           const Quaternion& rotation) {
    Placement result;
    result.rotation = rotation.multiply(placement.rotation).normalized();
    result.translation =
        add(pivot, rotation.rotate(subtract(placement.translation, pivot)));
    return result;
}

// Minimal rotation bringing the angle between the child direction and the
// parent direction to `targetAngle`.
Placement solveDirectionAngle(const DirectPlacementSolver::Input& input,
                              double targetAngle) {
    const Placement parentRef =
        input.parentPlacement.compose(input.parentLocalFrame.toPlacement());
    const Placement childRef =
        input.childPlacement.compose(input.childLocalFrame.toPlacement());

    const Vector3 parentZ = parentRef.applyDirection({0.0, 0.0, 1.0});
    const Vector3 childZ = childRef.applyDirection({0.0, 0.0, 1.0});

    const double cosine = std::clamp(dot(childZ, parentZ), -1.0, 1.0);
    const double currentAngle = std::acos(cosine);

    Vector3 axis = cross(childZ, parentZ);
    if (length(axis) <= 1.0e-9) {
        // Parallel or antiparallel directions: any perpendicular works.
        axis = stablePerpendicular(parentZ);
    }
    axis = normalizedOr(axis, {0.0, 0.0, 1.0});

    // R(axis, δ) moves childZ towards parentZ by δ.
    const double delta = currentAngle - targetAngle;
    const Quaternion rotation = Quaternion::fromAxisAngle(axis, delta);
    return rotateAboutPivot(input.childPlacement, childRef.translation, rotation);
}

} // namespace

Placement DirectPlacementSolver::solveChildPlacement(const Input& input) {
    switch (input.type) {
    case JointType::Rigid:
        if (input.hasCapturedRelativePlacement) {
            return input.parentPlacement.compose(input.capturedRelativePlacement);
        }
        [[fallthrough]];
    case JointType::Coincident:
    case JointType::Concentric:
    case JointType::Distance: {
        // Frame snap: T_child = T_parent ∘ F_parent ∘ T_joint ∘ inv(F_child).
        const Placement parentRef =
            input.parentPlacement.compose(input.parentLocalFrame.toPlacement());

        Placement joint = Placement::identity();
        joint.translation = {0.0, 0.0, input.offsetMeters};
        joint.rotation = Quaternion::fromAxisAngle({0.0, 0.0, 1.0}, input.angleRadians);
        if (input.alignment == JointAlignment::Opposed) {
            // Flip about X: mated Z becomes -Z.
            const Quaternion flip = Quaternion::fromAxisAngle({1.0, 0.0, 0.0}, M_PI);
            joint.rotation = joint.rotation.multiply(flip).normalized();
        }

        const Placement childRefTarget = parentRef.compose(joint);
        return childRefTarget.compose(input.childLocalFrame.toPlacement().inverse());
    }
    case JointType::Parallel:
        return solveDirectionAngle(
            input, input.alignment == JointAlignment::Opposed ? M_PI : 0.0);
    case JointType::Perpendicular:
        return solveDirectionAngle(input, M_PI / 2.0);
    case JointType::Angle:
        return solveDirectionAngle(input, input.angleRadians);
    }
    return input.childPlacement;
}

} // namespace cadnext::assembly
