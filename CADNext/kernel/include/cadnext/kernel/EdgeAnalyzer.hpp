#pragma once

#include <string>
#include <vector>

#include "cadnext/Vector3.hpp"
#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

namespace cadnext::kernel {

enum class EdgeKind {
    Line,
    Circle,
    Ellipse,
    BSpline,
    Other
};

struct EdgeReference {
    std::string bodyId;
    std::string edgeId;

    EdgeKind kind = EdgeKind::Other;

    cadnext::Vector3 start;
    cadnext::Vector3 end;
    cadnext::Vector3 center;

    // Circle edges only: the circle axis (unit) and radius (assembly
    // concentric mates). Zero radius means "no axis data".
    cadnext::Vector3 axisDirection;
    double radius = 0.0;

    double length = 0.0;
    bool isChamferable = false;
    bool isFilletable = false;

    // Viewer-only sampling of the curve for picking/highlight. The BRep
    // edge remains the source of truth for operations.
    std::vector<cadnext::Vector3> previewPolyline;
};

std::string makeEdgeId(int index,
                       const cadnext::Vector3& start,
                       const cadnext::Vector3& end,
                       double length);

class EdgeAnalyzer {
public:
    explicit EdgeAnalyzer(Kernel& kernel);

    std::vector<EdgeReference> edgesForBody(
        const std::string& bodyId,
        const ShapeHandle& shape
    );

private:
    Kernel& kernel_;
};

} // namespace cadnext::kernel
