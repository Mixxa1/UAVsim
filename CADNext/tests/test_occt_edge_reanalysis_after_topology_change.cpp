#include "cadnext/Chamfer.hpp"
#include "cadnext/Fillet.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>

namespace {

bool containsEdge(const std::vector<cadnext::kernel::EdgeReference>& edges,
                  const std::string& edgeId) {
    for (const cadnext::kernel::EdgeReference& edge : edges) {
        if (edge.edgeId == edgeId) {
            return true;
        }
    }
    return false;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    cadnext::kernel::GeometryEvaluator evaluator(kernel);
    cadnext::kernel::EdgeAnalyzer analyzer(kernel);

    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    const auto initialEdges = analyzer.edgesForBody("body-1", box.value());
    assert(initialEdges.size() == 12);
    const std::string staleEdgeId = initialEdges.front().edgeId;

    cadnext::FilletParameters fillet;
    fillet.targetBodyId = "body-1";
    fillet.edgeIds = {staleEdgeId};
    fillet.radiusMm = 40.0;
    const auto filleted = evaluator.evaluateFillet(box.value(), fillet);
    assert(filleted.isOk());
    assert(filleted.value().isValid);

    const auto rebuiltEdges = analyzer.edgesForBody("body-1", filleted.value().shape);
    assert(!rebuiltEdges.empty());
    assert(!containsEdge(rebuiltEdges, staleEdgeId));

    cadnext::ChamferParameters staleChamfer;
    staleChamfer.targetBodyId = "body-1";
    staleChamfer.edgeIds = {staleEdgeId};
    staleChamfer.mode = cadnext::ChamferMode::DistanceAngle;
    staleChamfer.distanceMm = 20.0;
    staleChamfer.angleDeg = 45.0;
    const auto rejected = evaluator.evaluateChamfer(filleted.value().shape, staleChamfer);
    assert(!rejected.isOk());
    assert(rejected.error().code == cadnext::ErrorCode::NotFound);

    cadnext::ChamferParameters freshChamfer;
    freshChamfer.targetBodyId = "body-1";
    freshChamfer.edgeIds = {rebuiltEdges.back().edgeId};
    freshChamfer.mode = cadnext::ChamferMode::DistanceAngle;
    freshChamfer.distanceMm = 10.0;
    freshChamfer.angleDeg = 45.0;
    const auto chamfered = evaluator.evaluateChamfer(filleted.value().shape, freshChamfer);
    assert(chamfered.isOk());
    assert(chamfered.value().isValid);
    assert(!chamfered.value().previewMesh.isEmpty());
    assert(kernel.isShapeValid(chamfered.value().shape));

    return 0;
}
