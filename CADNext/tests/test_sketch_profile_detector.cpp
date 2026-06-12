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

    // Rectangle entity → valid rectangle profile.
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
    assert(rectProfiles[0].sketchId == "sketch-rect");
    assert(rectProfiles[0].sourceEntityId == "rect-1");
    assert(rectProfiles[0].outerLoop.size() == 4);
    assert(std::fabs(rectProfiles[0].area - 1.0) < 1e-9);
    assert(rectProfiles[0].isClosed);
    assert(rectProfiles[0].isValid);

    // Circle entity → valid circle profile.
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
    assert(circleProfiles[0].sourceEntityId == "circle-1");
    assert(!circleProfiles[0].outerLoop.empty());
    assert(std::fabs(circleProfiles[0].area - M_PI * 0.25) < 1e-9);
    assert(circleProfiles[0].isValid);

    // Degenerate entities yield nothing.
    cadnext::Sketch degenerate;
    degenerate.id = "sketch-degenerate";
    cadnext::SketchEntity zeroCircle;
    zeroCircle.id = "circle-zero";
    zeroCircle.type = cadnext::SketchEntityType::Circle;
    zeroCircle.circle.radius = 0.0;
    degenerate.entities.push_back(zeroCircle);
    assert(detector.detect(degenerate).empty());

    // Sequential closed line loop → valid Polygon profile (unit triangle).
    cadnext::Sketch loop;
    loop.id = "sketch-loop";
    loop.entities.push_back(makeLine("l1", 0.0, 0.0, 1.0, 0.0));
    loop.entities.push_back(makeLine("l2", 1.0, 0.0, 0.0, 1.0));
    loop.entities.push_back(makeLine("l3", 0.0, 1.0, 0.0, 0.0));

    const auto loopProfiles = detector.detect(loop);
    assert(loopProfiles.size() == 1);
    assert(loopProfiles[0].kind == cadnext::SketchProfileKind::Polygon);
    assert(loopProfiles[0].id.rfind("profile-poly-", 0) == 0);
    assert(loopProfiles[0].sketchId == "sketch-loop");
    assert(loopProfiles[0].sourceEntityIds.size() == 3);
    assert(loopProfiles[0].sourceEntityIds[0] == "l1");
    assert(loopProfiles[0].sourceEntityIds[2] == "l3");
    assert(loopProfiles[0].outerLoop.size() == 3);
    assert(std::fabs(loopProfiles[0].area - 0.5) < 1e-9);
    assert(loopProfiles[0].isClosed);
    assert(loopProfiles[0].isValid);

    // A concave (L-shaped) loop is still a valid polygon profile.
    cadnext::Sketch concave;
    concave.id = "sketch-concave";
    concave.entities.push_back(makeLine("c1", 0.0, 0.0, 2.0, 0.0));
    concave.entities.push_back(makeLine("c2", 2.0, 0.0, 2.0, 1.0));
    concave.entities.push_back(makeLine("c3", 2.0, 1.0, 1.0, 1.0));
    concave.entities.push_back(makeLine("c4", 1.0, 1.0, 1.0, 2.0));
    concave.entities.push_back(makeLine("c5", 1.0, 2.0, 0.0, 2.0));
    concave.entities.push_back(makeLine("c6", 0.0, 2.0, 0.0, 0.0));
    const auto concaveProfiles = detector.detect(concave);
    assert(concaveProfiles.size() == 1);
    assert(concaveProfiles[0].kind == cadnext::SketchProfileKind::Polygon);
    assert(std::fabs(concaveProfiles[0].area - 3.0) < 1e-9);
    assert(concaveProfiles[0].isValid);
    // ... and it triangulates (ear clipping handles the reflex corner).
    assert(cadnext::triangulatePolygon(concaveProfiles[0].outerLoop).size() == (6 - 2) * 3);

    // Open chain → no valid profile.
    cadnext::Sketch open;
    open.id = "sketch-open";
    open.entities.push_back(makeLine("l1", 0.0, 0.0, 1.0, 0.0));
    open.entities.push_back(makeLine("l2", 1.0, 0.0, 0.0, 1.0));
    assert(detector.detect(open).empty());

    // Self-intersecting (bow-tie) closed chain → closed but invalid profile.
    cadnext::Sketch bowTie;
    bowTie.id = "sketch-bowtie";
    bowTie.entities.push_back(makeLine("b1", 0.0, 0.0, 1.0, 1.0));
    bowTie.entities.push_back(makeLine("b2", 1.0, 1.0, 1.0, 0.0));
    bowTie.entities.push_back(makeLine("b3", 1.0, 0.0, 0.0, 1.0));
    bowTie.entities.push_back(makeLine("b4", 0.0, 1.0, 0.0, 0.0));
    const auto bowTieProfiles = detector.detect(bowTie);
    assert(bowTieProfiles.size() == 1);
    assert(bowTieProfiles[0].kind == cadnext::SketchProfileKind::Polygon);
    assert(bowTieProfiles[0].isClosed);
    assert(!bowTieProfiles[0].isValid);
    assert(bowTieProfiles[0].invalidReason ==
           cadnext::SketchProfileInvalidReason::SelfIntersecting);

    // Helper sanity: point-in-polygon for profile click selection.
    const std::vector<cadnext::SketchPoint2D> square = {
        {0.0, 0.0}, {2.0, 0.0}, {2.0, 2.0}, {0.0, 2.0}};
    assert(cadnext::polygonContainsPoint(square, {1.0, 1.0}));
    assert(!cadnext::polygonContainsPoint(square, {3.0, 1.0}));
    assert(cadnext::polygonContainsPoint(square, {2.0, 1.0})); // boundary

    return 0;
}
