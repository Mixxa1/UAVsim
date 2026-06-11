#include "cadnext/ViewportPolicy.hpp"
#include "cadnext/WorkPlane.hpp"

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

} // namespace

int main() {
    cadnext::ViewportPolicy policy;

    // Free3D baseline: orbit allowed, no active reference.
    assert(policy.mode() == cadnext::ViewportViewMode::Free3D);
    assert(policy.orbitEnabled());
    assert(!policy.activeReference().has_value());

    // Entering Sketch2D stores the active reference and disables orbit.
    policy.enterSketch2D(cadnext::canonicalSketchReference(cadnext::SketchPlane::YZ));
    assert(policy.mode() == cadnext::ViewportViewMode::Sketch2D);
    assert(policy.inSketch2D());
    assert(!policy.orbitEnabled());
    assert(policy.activeReference().has_value());
    assertVector(policy.activeReference()->uAxis, 0.0, 1.0, 0.0);
    assertVector(policy.activeReference()->vAxis, 0.0, 0.0, 1.0);
    assertVector(policy.activeReference()->normal, 1.0, 0.0, 0.0);

    // Fit View in Sketch2D always frames the active sketch plane.
    assert(policy.fitTarget(true) == cadnext::ViewportFitTarget::ActiveSketchPlane);
    assert(policy.fitTarget(false) == cadnext::ViewportFitTarget::ActiveSketchPlane);

    // Re-entering with a different plane replaces the reference.
    policy.enterSketch2D(cadnext::canonicalSketchReference(cadnext::SketchPlane::XZ));
    assertVector(policy.activeReference()->normal, 0.0, 1.0, 0.0);

    // Exit restores Free3D and clears the reference.
    policy.exitSketch2D();
    assert(policy.mode() == cadnext::ViewportViewMode::Free3D);
    assert(policy.orbitEnabled());
    assert(!policy.activeReference().has_value());

    // Free3D Fit View: bodies first, the selected plane only without
    // bodies, the whole scene as the last resort.
    assert(policy.fitTarget(true) == cadnext::ViewportFitTarget::Bodies);
    assert(policy.fitTarget(false) == cadnext::ViewportFitTarget::WholeScene);
    policy.setSelectedWorkPlane(cadnext::canonicalWorkPlaneId(cadnext::SketchPlane::XY));
    assert(policy.fitTarget(false) == cadnext::ViewportFitTarget::SelectedPlane);
    assert(policy.fitTarget(true) == cadnext::ViewportFitTarget::Bodies);

    return 0;
}
