#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>
#include <cmath>

int main() {
    cadnext::kernel::OcctKernel kernel;
    assert(kernel.isAvailable());

    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    cadnext::kernel::EdgeAnalyzer analyzer(kernel);
    const auto edges = analyzer.edgesForBody("body-1", box.value());
    assert(edges.size() == 12);
    for (const cadnext::kernel::EdgeReference& edge : edges) {
        assert(edge.bodyId == "body-1");
        assert(edge.edgeId.rfind("edge-", 0) == 0);
        assert(edge.kind == cadnext::kernel::EdgeKind::Line);
        assert(std::isfinite(edge.start.x));
        assert(std::isfinite(edge.end.y));
        assert(std::isfinite(edge.length));
        assert(edge.length > 0.0);
        assert(edge.isChamferable);
        assert(edge.isFilletable);
        assert(edge.previewPolyline.size() >= 2);
    }

    const auto missing = analyzer.edgesForBody("body-1", cadnext::kernel::ShapeHandle("missing"));
    assert(missing.empty());

    return 0;
}
