// DirectPlacementSolver: frame-snap formula T_child = T_parent × T_pRef ×
// T_joint × inv(T_cRef) against hand-computed placements, plus the
// minimal-rotation paths for direction constraints.
#include "cadnext/assembly/DirectPlacementSolver.hpp"

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
    // --- Coincident opposed: unit cube stacked on a unit cube ---------------
    // Parent centered at origin, top face frame: origin (0,0,0.5), Z up.
    // Child's bottom face frame in its local space: origin (0,0,-0.5), Z down.
    // Opposed mate → child ends centered at (0,0,1), no rotation.
    DirectPlacementSolver::Input input;
    input.type = JointType::Coincident;
    input.alignment = JointAlignment::Opposed;
    input.parentPlacement = Placement::identity();
    input.parentLocalFrame =
        Frame::fromOriginZX({0.0, 0.0, 0.5}, {0.0, 0.0, 1.0}, {1.0, 0.0, 0.0});
    input.childPlacement = Placement::identity();
    input.childPlacement.translation = {5.0, 5.0, 5.0}; // somewhere far
    input.childLocalFrame =
        Frame::fromOriginZX({0.0, 0.0, -0.5}, {0.0, 0.0, -1.0}, {1.0, 0.0, 0.0});

    Placement solved = DirectPlacementSolver::solveChildPlacement(input);
    checkVector(solved.translation, 0.0, 0.0, 1.0);
    // Child ref frame lands exactly on the joint target: Z_world of the
    // child's bottom face must be -Z.
    const Frame childRefWorld = input.childLocalFrame.transformedBy(solved);
    checkVector(childRefWorld.origin, 0.0, 0.0, 0.5);
    checkVector(childRefWorld.zAxis, 0.0, 0.0, -1.0);

    // --- Distance: same mate with 0.1 offset along parent Z ------------------
    input.type = JointType::Distance;
    input.offsetMeters = 0.1;
    solved = DirectPlacementSolver::solveChildPlacement(input);
    checkVector(solved.translation, 0.0, 0.0, 1.1);
    input.offsetMeters = 0.0;

    // --- Angle about the mated Z (aligned) ------------------------------------
    input.type = JointType::Coincident;
    input.alignment = JointAlignment::Aligned;
    input.angleRadians = M_PI / 2.0;
    solved = DirectPlacementSolver::solveChildPlacement(input);
    {
        const Frame ref = input.childLocalFrame.transformedBy(solved);
        // Aligned: child ref Z == parent ref Z; X rotated by 90° about Z.
        checkVector(ref.zAxis, 0.0, 0.0, 1.0);
        checkVector(ref.xAxis, 0.0, 1.0, 0.0);
    }
    input.angleRadians = 0.0;

    // --- Rigid with captured relative placement -------------------------------
    input.type = JointType::Rigid;
    input.hasCapturedRelativePlacement = true;
    input.capturedRelativePlacement.translation = {0.0, 2.0, 0.0};
    input.capturedRelativePlacement.rotation =
        Quaternion::fromAxisAngle({0.0, 0.0, 1.0}, M_PI / 2.0);
    input.parentPlacement.translation = {1.0, 0.0, 0.0};
    solved = DirectPlacementSolver::solveChildPlacement(input);
    checkVector(solved.translation, 1.0, 2.0, 0.0);
    checkVector(solved.rotation.rotate({1.0, 0.0, 0.0}), 0.0, 1.0, 0.0);
    input.hasCapturedRelativePlacement = false;
    input.parentPlacement = Placement::identity();

    // --- Parallel: minimal rotation, position preserved -----------------------
    // Child ref Z currently 90° off (pointing +X), parallel-aligned target +Z.
    input.type = JointType::Parallel;
    input.alignment = JointAlignment::Aligned;
    input.childPlacement = Placement::identity();
    input.childPlacement.translation = {3.0, 0.0, 0.0};
    input.childPlacement.rotation =
        Quaternion::fromAxisAngle({0.0, 1.0, 0.0}, M_PI / 2.0); // Z → X
    input.childLocalFrame =
        Frame::fromOriginZX({0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, {1.0, 0.0, 0.0});
    solved = DirectPlacementSolver::solveChildPlacement(input);
    {
        const Frame ref = input.childLocalFrame.transformedBy(solved);
        checkVector(ref.zAxis, 0.0, 0.0, 1.0, 1.0e-8);
        // The reference origin (== component origin here) must not move.
        checkVector(ref.origin, 3.0, 0.0, 0.0, 1.0e-8);
    }

    // --- Perpendicular ---------------------------------------------------------
    input.type = JointType::Perpendicular;
    input.childPlacement.rotation = Quaternion::identity(); // Z parallel to parent Z
    solved = DirectPlacementSolver::solveChildPlacement(input);
    {
        const Frame ref = input.childLocalFrame.transformedBy(solved);
        assert(nearlyEqual(dot(ref.zAxis, {0.0, 0.0, 1.0}), 0.0, 1.0e-8));
        checkVector(ref.origin, 3.0, 0.0, 0.0, 1.0e-8);
    }

    // --- Angle 45° --------------------------------------------------------------
    input.type = JointType::Angle;
    input.angleRadians = M_PI / 4.0;
    solved = DirectPlacementSolver::solveChildPlacement(input);
    {
        const Frame ref = input.childLocalFrame.transformedBy(solved);
        assert(nearlyEqual(dot(ref.zAxis, {0.0, 0.0, 1.0}), std::cos(M_PI / 4.0), 1.0e-8));
    }

    return 0;
}
