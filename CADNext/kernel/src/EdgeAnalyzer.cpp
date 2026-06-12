#include "cadnext/kernel/EdgeAnalyzer.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>

#ifdef CADNEXT_WITH_OCCT
#include <BRepAdaptor_Curve.hxx>
#include <BRepGProp.hxx>
#include <BRep_Tool.hxx>
#include <GeomAbs_CurveType.hxx>
#include <GProp_GProps.hxx>
#include <Standard_Failure.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Circ.hxx>
#include <gp_Elips.hxx>
#include <gp_Pnt.hxx>

#include "cadnext/kernel/OcctKernel.hpp"
#endif

namespace cadnext::kernel {

namespace {

std::uint32_t fnv1aMix(std::uint32_t hash, std::int64_t value) {
    for (int byte = 0; byte < 8; ++byte) {
        hash ^= static_cast<std::uint32_t>((value >> (byte * 8)) & 0xff);
        hash *= 16777619u;
    }
    return hash;
}

std::int64_t quantize(double value) {
    if (!std::isfinite(value)) {
        return 0;
    }
    return std::llround(value * 1000.0);
}

std::uint32_t hashValues(std::initializer_list<double> values) {
    std::uint32_t hash = 2166136261u;
    for (const double value : values) {
        hash = fnv1aMix(hash, quantize(value));
    }
    return hash;
}

std::string hex8(std::uint32_t value) {
    char buffer[16];
    std::snprintf(buffer, sizeof(buffer), "%08x", value);
    return buffer;
}

#ifdef CADNEXT_WITH_OCCT

cadnext::Vector3 toVector(const gp_Pnt& point) {
    return {point.X(), point.Y(), point.Z()};
}

EdgeKind edgeKindFor(GeomAbs_CurveType type) {
    switch (type) {
    case GeomAbs_Line: return EdgeKind::Line;
    case GeomAbs_Circle: return EdgeKind::Circle;
    case GeomAbs_Ellipse: return EdgeKind::Ellipse;
    case GeomAbs_BSplineCurve: return EdgeKind::BSpline;
    default: return EdgeKind::Other;
    }
}

double edgeLength(const TopoDS_Edge& edge) {
    GProp_GProps properties;
    BRepGProp::LinearProperties(edge, properties);
    const double length = properties.Mass();
    return std::isfinite(length) ? length : 0.0;
}

std::vector<cadnext::Vector3> sampleCurve(BRepAdaptor_Curve& curve,
                                          int segmentCount,
                                          cadnext::Vector3 fallbackStart,
                                          cadnext::Vector3 fallbackEnd) {
    std::vector<cadnext::Vector3> points;
    const double first = curve.FirstParameter();
    const double last = curve.LastParameter();
    if (!std::isfinite(first) || !std::isfinite(last) || first == last) {
        points.push_back(fallbackStart);
        points.push_back(fallbackEnd);
        return points;
    }
    const int count = std::max(segmentCount, 1);
    points.reserve(static_cast<size_t>(count + 1));
    for (int i = 0; i <= count; ++i) {
        const double t = first + (last - first) * static_cast<double>(i) /
                                     static_cast<double>(count);
        points.push_back(toVector(curve.Value(t)));
    }
    return points;
}

EdgeReference edgeReferenceFor(const std::string& bodyId, int index, const TopoDS_Edge& edge) {
    EdgeReference reference;
    reference.bodyId = bodyId;

    BRepAdaptor_Curve curve(edge);
    const double first = curve.FirstParameter();
    const double last = curve.LastParameter();
    if (std::isfinite(first)) {
        reference.start = toVector(curve.Value(first));
    }
    if (std::isfinite(last)) {
        reference.end = toVector(curve.Value(last));
    }
    reference.length = edgeLength(edge);
    reference.kind = edgeKindFor(curve.GetType());

    switch (reference.kind) {
    case EdgeKind::Circle:
        reference.center = toVector(curve.Circle().Location());
        break;
    case EdgeKind::Ellipse:
        reference.center = toVector(curve.Ellipse().Location());
        break;
    case EdgeKind::Line:
    case EdgeKind::BSpline:
    case EdgeKind::Other:
        reference.center = {(reference.start.x + reference.end.x) * 0.5,
                            (reference.start.y + reference.end.y) * 0.5,
                            (reference.start.z + reference.end.z) * 0.5};
        break;
    }

    const bool usableLength = std::isfinite(reference.length) && reference.length > 1.0e-9;
    reference.isChamferable = usableLength;
    reference.isFilletable = usableLength;
    reference.edgeId = makeEdgeId(index, reference.start, reference.end, reference.length);

    int segments = 1;
    switch (reference.kind) {
    case EdgeKind::Line:
        segments = 1;
        break;
    case EdgeKind::Circle:
    case EdgeKind::Ellipse:
        segments = 64;
        break;
    case EdgeKind::BSpline:
    case EdgeKind::Other:
        segments = 32;
        break;
    }
    reference.previewPolyline =
        sampleCurve(curve, segments, reference.start, reference.end);
    return reference;
}

#endif // CADNEXT_WITH_OCCT

} // namespace

std::string makeEdgeId(int index,
                       const cadnext::Vector3& start,
                       const cadnext::Vector3& end,
                       double length) {
    return "edge-" + std::to_string(index) + "-s" +
           hex8(hashValues({start.x, start.y, start.z})) + "-e" +
           hex8(hashValues({end.x, end.y, end.z})) + "-l" +
           hex8(hashValues({length}));
}

EdgeAnalyzer::EdgeAnalyzer(Kernel& kernel) : kernel_(kernel) {}

#ifdef CADNEXT_WITH_OCCT

std::vector<EdgeReference> EdgeAnalyzer::edgesForBody(const std::string& bodyId,
                                                      const ShapeHandle& shape) {
    std::vector<EdgeReference> edges;
    auto* occtKernel = dynamic_cast<OcctKernel*>(&kernel_);
    if (!occtKernel) {
        return edges;
    }
    const TopoDS_Shape* topoShape = occtKernel->findShape(shape);
    if (!topoShape || topoShape->IsNull()) {
        return edges;
    }

    try {
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(*topoShape, TopAbs_EDGE, edgeMap);
        for (int i = 1; i <= edgeMap.Extent(); ++i) {
            const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
            // Skip edges chamfer/fillet can never operate on (degenerated
            // edges, edges without a 3D curve); one broken edge must not
            // hide the rest of the body's edges. The map index stays the
            // id index either way so kernel-side resolution agrees.
            try {
                if (BRep_Tool::Degenerated(edge)) {
                    continue;
                }
                Standard_Real first = 0.0;
                Standard_Real last = 0.0;
                if (BRep_Tool::Curve(edge, first, last).IsNull()) {
                    continue;
                }
                edges.push_back(edgeReferenceFor(bodyId, i - 1, edge));
            } catch (const Standard_Failure&) {
            }
        }
    } catch (const Standard_Failure&) {
        edges.clear();
    }
    return edges;
}

#else // !CADNEXT_WITH_OCCT

std::vector<EdgeReference> EdgeAnalyzer::edgesForBody(const std::string&,
                                                      const ShapeHandle&) {
    return {};
}

#endif // CADNEXT_WITH_OCCT

} // namespace cadnext::kernel
