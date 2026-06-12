// CADNext 0.9: public edge reference/id contract. Runs in every build:
// with the stub kernel the analyzer must simply return no edges.

#include "cadnext/Selection.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/StubKernel.hpp"

#include <cassert>
#include <cmath>
#include <string>

int main() {
    using cadnext::Vector3;
    using cadnext::kernel::EdgeKind;
    using cadnext::kernel::EdgeReference;
    using cadnext::kernel::makeEdgeId;

    EdgeReference reference;
    assert(reference.kind == EdgeKind::Other);
    assert(!reference.isChamferable);
    assert(!reference.isFilletable);
    assert(reference.previewPolyline.empty());

    const Vector3 start{0.0, 0.0, 0.0};
    const Vector3 end{1.0, 0.0, 0.0};
    const std::string id = makeEdgeId(3, start, end, 1.0);
    assert(id == makeEdgeId(3, start, end, 1.0));
    assert(id.rfind("edge-3-s", 0) == 0);
    assert(id.find("-e") != std::string::npos);
    assert(id.find("-l") != std::string::npos);
    assert(id != "edge-3");

    // Sub-quantum noise (1e-3 grid) keeps ids stable; real changes do not.
    assert(id == makeEdgeId(3, {1.0e-5, 0.0, 0.0}, {1.0 + 1.0e-5, 0.0, 0.0},
                            1.0 + 1.0e-5));
    assert(id != makeEdgeId(4, start, end, 1.0));
    assert(id != makeEdgeId(3, start, {1.1, 0.0, 0.0}, 1.1));
    assert(id != makeEdgeId(3, start, end, 2.0));

    const std::string nanId = makeEdgeId(0, {std::nan(""), 0.0, 0.0}, end, 1.0);
    assert(nanId == makeEdgeId(0, {std::nan(""), 0.0, 0.0}, end, 1.0));

    cadnext::BodyEdgeSelection selected{"body-1", id};
    cadnext::SelectionState state;
    state.kind = cadnext::SelectionKind::BodyEdge;
    state.bodyId = selected.bodyId;
    state.edgeId = selected.edgeId;
    assert(state.kind == cadnext::SelectionKind::BodyEdge);
    assert(state.bodyId && *state.bodyId == "body-1");
    assert(state.edgeId && *state.edgeId == id);

    cadnext::kernel::StubKernel kernel;
    cadnext::kernel::EdgeAnalyzer analyzer(kernel);
    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());
    assert(analyzer.edgesForBody("body-1", box.value()).empty());

    return 0;
}
