#include "cadnext/kernel/VertexAnalyzer.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <set>
#include <tuple>

#ifdef CADNEXT_WITH_OCCT
#include <BRep_Tool.hxx>
#include <Standard_Failure.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Vertex.hxx>
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

} // namespace

std::string makeVertexId(int index, const cadnext::Vector3& position) {
    return "vertex-" + std::to_string(index) + "-" +
           hex8(hashValues({position.x, position.y, position.z}));
}

VertexAnalyzer::VertexAnalyzer(Kernel& kernel) : kernel_(kernel) {}

#ifdef CADNEXT_WITH_OCCT

std::vector<VertexReference> VertexAnalyzer::verticesForBody(const std::string& bodyId,
                                                             const ShapeHandle& shape) {
    std::vector<VertexReference> vertices;
    auto* occtKernel = dynamic_cast<OcctKernel*>(&kernel_);
    if (!occtKernel) {
        return vertices;
    }
    const TopoDS_Shape* topoShape = occtKernel->findShape(shape);
    if (!topoShape || topoShape->IsNull()) {
        return vertices;
    }

    try {
        TopTools_IndexedMapOfShape vertexMap;
        TopExp::MapShapes(*topoShape, TopAbs_VERTEX, vertexMap);
        // The indexed map already merges shared TShapes; positions can
        // still coincide across seam vertices, so geometric duplicates
        // are dropped by quantized position. The map index keeps driving
        // the id so re-analysis of the same shape reproduces the ids.
        std::set<std::tuple<std::int64_t, std::int64_t, std::int64_t>> seen;
        for (int i = 1; i <= vertexMap.Extent(); ++i) {
            const TopoDS_Vertex vertex = TopoDS::Vertex(vertexMap(i));
            const gp_Pnt point = BRep_Tool::Pnt(vertex);
            const auto key = std::make_tuple(quantize(point.X()), quantize(point.Y()),
                                             quantize(point.Z()));
            if (!seen.insert(key).second) {
                continue;
            }
            VertexReference reference;
            reference.bodyId = bodyId;
            reference.position = {point.X(), point.Y(), point.Z()};
            reference.vertexId = makeVertexId(i - 1, reference.position);
            vertices.push_back(std::move(reference));
        }
    } catch (const Standard_Failure&) {
        vertices.clear();
    }
    return vertices;
}

#else // !CADNEXT_WITH_OCCT

std::vector<VertexReference> VertexAnalyzer::verticesForBody(const std::string&,
                                                             const ShapeHandle&) {
    return {};
}

#endif // CADNEXT_WITH_OCCT

} // namespace cadnext::kernel
