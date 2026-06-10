#include "cadnext/SketchProfile.hpp"

#include <cassert>
#include <cmath>

namespace {

cadnext::SketchEntity makeLine(const char* id, double u1, double v1, double u2, double v2) {
    cadnext::SketchEntity entity;
    entity.id = id;
    entity.name = id;
    entity.type = cadnext::SketchEntityType::Line;
    entity.line.start = {u1, v1};
    entity.line.end = {u2, v2};
    return entity;
}

} // namespace

int main() {
    cadnext::SketchProfileDetector detector;

    // Empty sketch → no profiles.
    cadnext::Sketch empty;
    empty.id = "sketch-empty";
    assert(detector.detect(empty).empty());

    // Rectangle entity → rectangle profile.
    cadnext::Sketch withRect;
    withRect.id = "sketch-rect";
    cadnext::SketchEntity rect;
    rect.id = "rect-1";
    rect.type = cadnext::SketchEntityType::Rectangle;
    rect.rectangle.origin = {1.0, 2.0};
    rect.rectangle.width = 2.0;
    rect.rectangle.height = 0.5;
    withRect.entities.push_back(rect);

    const auto rectProfiles = detector.detect(withRect);
    assert(rectProfiles.size() == 1);
    assert(rectProfiles[0].kind == cadnext::SketchProfileKind::Rectangle);
    assert(rectProfiles[0].outerLoop.size() == 4);
    assert(std::fabs(rectProfiles[0].area - 1.0) < 1e-9);

    // Circle entity → circle profile.
    cadnext::Sketch withCircle;
    withCircle.id = "sketch-circle";
    cadnext::SketchEntity circle;
    circle.id = "circle-1";
    circle.type = cadnext::SketchEntityType::Circle;
    circle.circle.center = {0.0, 0.0};
    circle.circle.radius = 0.5;
    withCircle.entities.push_back(circle);

    const auto circleProfiles = detector.detect(withCircle);
    assert(circleProfiles.size() == 1);
    assert(circleProfiles[0].kind == cadnext::SketchProfileKind::Circle);
    assert(!circleProfiles[0].outerLoop.empty());
    assert(std::fabs(circleProfiles[0].area - M_PI * 0.25) < 1e-9);

    // Degenerate entities yield nothing.
    cadnext::Sketch degenerate;
    degenerate.id = "sketch-degenerate";
    cadnext::SketchEntity zeroCircle;
    zeroCircle.id = "circle-zero";
    zeroCircle.type = cadnext::SketchEntityType::Circle;
    zeroCircle.circle.radius = 0.0;
    degenerate.entities.push_back(zeroCircle);
    assert(detector.detect(degenerate).empty());

    // Sequential closed line loop → ClosedLoop profile (unit triangle).
    cadnext::Sketch loop;
    loop.id = "sketch-loop";
    loop.entities.push_back(makeLine("l1", 0.0, 0.0, 1.0, 0.0));
    loop.entities.push_back(makeLine("l2", 1.0, 0.0, 0.0, 1.0));
    loop.entities.push_back(makeLine("l3", 0.0, 1.0, 0.0, 0.0));

    const auto loopProfiles = detector.detect(loop);
    assert(loopProfiles.size() == 1);
    assert(loopProfiles[0].kind == cadnext::SketchProfileKind::ClosedLoop);
    assert(loopProfiles[0].outerLoop.size() == 3);
    assert(std::fabs(loopProfiles[0].area - 0.5) < 1e-9);

    // Open chain → no loop profile.
    cadnext::Sketch open;
    open.id = "sketch-open";
    open.entities.push_back(makeLine("l1", 0.0, 0.0, 1.0, 0.0));
    open.entities.push_back(makeLine("l2", 1.0, 0.0, 0.0, 1.0));
    assert(detector.detect(open).empty());

    return 0;
}
