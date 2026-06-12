#include "cadnext/Sketch.hpp"
#include "cadnext/SketchProfile.hpp"

#include <algorithm>
#include <cassert>
#include <utility>

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

std::vector<cadnext::SketchProfile> validPolygons(const cadnext::Sketch& sketch) {
    std::vector<cadnext::SketchProfile> out;
    for (cadnext::SketchProfile& profile : cadnext::SketchProfileDetector().detect(sketch)) {
        if (profile.kind == cadnext::SketchProfileKind::Polygon && profile.isValid) {
            out.push_back(std::move(profile));
        }
    }
    return out;
}

bool containsId(const std::vector<std::string>& ids, const char* id) {
    return std::find(ids.begin(), ids.end(), id) != ids.end();
}

} // namespace

int main() {
    cadnext::Sketch sketch;
    sketch.id = "sketch-stability";
    sketch.entities.push_back(makeLine("l1", 0.0, 0.0, 1.0, 0.0));
    sketch.entities.push_back(makeLine("l2", 1.0, 0.0, 0.0, 1.0));
    sketch.entities.push_back(makeLine("l3", 0.0, 1.0, 0.0, 0.0));

    std::vector<cadnext::SketchProfile> profiles = validPolygons(sketch);
    assert(profiles.size() == 1);
    const std::string stableId = profiles[0].id;
    assert(stableId.rfind("profile-poly-", 0) == 0);
    assert(containsId(profiles[0].sourceEntityIds, "l1"));
    assert(containsId(profiles[0].sourceEntityIds, "l2"));
    assert(containsId(profiles[0].sourceEntityIds, "l3"));

    // Cancel pending line: no committed entity is added, so rebuild result is unchanged.
    profiles = validPolygons(sketch);
    assert(profiles.size() == 1);
    assert(profiles[0].id == stableId);

    assert(cadnext::removeSketchEntity(sketch, "l2"));
    profiles = validPolygons(sketch);
    assert(profiles.empty());

    sketch.entities.push_back(makeLine("l4", 1.0, 0.0, 0.0, 1.0));
    profiles = validPolygons(sketch);
    assert(profiles.size() == 1);
    assert(profiles[0].id != stableId);
    assert(!containsId(profiles[0].sourceEntityIds, "l2"));
    assert(containsId(profiles[0].sourceEntityIds, "l4"));

    cadnext::Sketch open;
    open.id = "sketch-open";
    open.entities.push_back(makeLine("o1", 0.0, 0.0, 1.0, 0.0));
    open.entities.push_back(makeLine("o2", 1.0, 0.0, 1.0, 1.0));
    open.entities.push_back(makeLine("o3", 1.0, 1.0, 0.0, 1.0));
    assert(validPolygons(open).empty());

    cadnext::Sketch rectangle;
    rectangle.id = "sketch-rectangle-lines";
    rectangle.entities.push_back(makeLine("r1", 0.0, 0.0, 2.0, 0.0));
    rectangle.entities.push_back(makeLine("r2", 2.0, 0.0, 2.0, 1.0));
    rectangle.entities.push_back(makeLine("r3", 2.0, 1.0, 0.0, 1.0));
    rectangle.entities.push_back(makeLine("r4", 0.0, 1.0, 0.0, 0.0));
    profiles = validPolygons(rectangle);
    assert(profiles.size() == 1);
    assert(profiles[0].sourceEntityIds.size() == 4);

    cadnext::Sketch bowTie;
    bowTie.id = "sketch-bowtie";
    bowTie.entities.push_back(makeLine("b1", 0.0, 0.0, 1.0, 1.0));
    bowTie.entities.push_back(makeLine("b2", 1.0, 1.0, 1.0, 0.0));
    bowTie.entities.push_back(makeLine("b3", 1.0, 0.0, 0.0, 1.0));
    bowTie.entities.push_back(makeLine("b4", 0.0, 1.0, 0.0, 0.0));
    const auto bowTieProfiles = cadnext::SketchProfileDetector().detect(bowTie);
    assert(bowTieProfiles.size() == 1);
    assert(!bowTieProfiles[0].isValid);
    assert(bowTieProfiles[0].invalidReason ==
           cadnext::SketchProfileInvalidReason::SelfIntersecting);

    return 0;
}
