#include "cadnext/ViewportPolicy.hpp"
#include "cadnext/WorkPlane.hpp"

#include <cassert>
#include <string>

int main() {
    const std::string xy = cadnext::canonicalWorkPlaneId(cadnext::SketchPlane::XY);
    const std::string xz = cadnext::canonicalWorkPlaneId(cadnext::SketchPlane::XZ);
    const std::string yz = cadnext::canonicalWorkPlaneId(cadnext::SketchPlane::YZ);

    cadnext::ViewportPolicy policy;

    // Free3D default: every plane frame and the world helpers are visible.
    assert(policy.mode() == cadnext::ViewportViewMode::Free3D);
    assert(policy.workPlaneVisible(xy));
    assert(policy.workPlaneVisible(xz));
    assert(policy.workPlaneVisible(yz));
    assert(policy.worldGridVisible());
    assert(policy.worldAxesVisible());

    // Hide Other Planes keeps only the selected plane.
    policy.setSelectedWorkPlane(xz);
    policy.setOtherWorkPlanesHidden(true);
    assert(!policy.workPlaneVisible(xy));
    assert(policy.workPlaneVisible(xz));
    assert(!policy.workPlaneVisible(yz));

    // Changing the selection moves the visible plane with it.
    policy.setSelectedWorkPlane(yz);
    assert(!policy.workPlaneVisible(xz));
    assert(policy.workPlaneVisible(yz));

    // Hide Other Planes with no selection hides everything.
    policy.setSelectedWorkPlane("");
    assert(!policy.workPlaneVisible(xy));
    assert(!policy.workPlaneVisible(yz));
    policy.setOtherWorkPlanesHidden(false);
    policy.setSelectedWorkPlane(yz);

    // Entering Sketch2D hides all work plane helpers and world grid/axes
    // regardless of the Free3D flags.
    policy.enterSketch2D(cadnext::canonicalSketchReference(cadnext::SketchPlane::YZ));
    assert(!policy.workPlaneVisible(xy));
    assert(!policy.workPlaneVisible(xz));
    assert(!policy.workPlaneVisible(yz));
    assert(!policy.worldGridVisible());
    assert(!policy.worldAxesVisible());

    // Exiting Sketch2D restores the Free3D policy exactly.
    policy.exitSketch2D();
    assert(policy.workPlaneVisible(xy));
    assert(policy.workPlaneVisible(xz));
    assert(policy.workPlaneVisible(yz));
    assert(policy.worldGridVisible());
    assert(policy.worldAxesVisible());

    // The user's hide-others choice survives a Sketch2D round trip.
    policy.setOtherWorkPlanesHidden(true);
    policy.enterSketch2D(cadnext::canonicalSketchReference(cadnext::SketchPlane::XY));
    policy.exitSketch2D();
    assert(policy.otherWorkPlanesHidden());
    assert(!policy.workPlaneVisible(xy));
    assert(policy.workPlaneVisible(yz));

    return 0;
}
