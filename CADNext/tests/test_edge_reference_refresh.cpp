#include "cadnext/Selection.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/StubKernel.hpp"

#include <cassert>
#include <string>
#include <vector>

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

bool staleSelectionRejected(const cadnext::SelectionState& selection,
                            const std::vector<cadnext::kernel::EdgeReference>& refreshed) {
    return selection.kind == cadnext::SelectionKind::BodyEdge && selection.bodyId &&
           selection.edgeId && !containsEdge(refreshed, *selection.edgeId);
}

} // namespace

int main() {
    const std::string oldEdge =
        cadnext::kernel::makeEdgeId(0, {0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, 1.0);
    const std::string rebuiltEdge =
        cadnext::kernel::makeEdgeId(0, {0.0, 0.0, 0.0}, {0.5, 0.0, 0.0}, 0.5);
    assert(oldEdge != rebuiltEdge);

    cadnext::SelectionState selection;
    selection.kind = cadnext::SelectionKind::BodyEdge;
    selection.bodyId = "body-1";
    selection.edgeId = oldEdge;

    cadnext::kernel::EdgeReference current;
    current.bodyId = "body-1";
    current.edgeId = rebuiltEdge;
    current.isChamferable = true;
    current.isFilletable = true;
    assert(staleSelectionRejected(selection, {current}));

    selection.edgeId = rebuiltEdge;
    assert(!staleSelectionRejected(selection, {current}));

    cadnext::kernel::StubKernel kernel;
    cadnext::kernel::EdgeAnalyzer analyzer(kernel);
    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());
    assert(staleSelectionRejected(selection, analyzer.edgesForBody("body-1", box.value())));

    return 0;
}
