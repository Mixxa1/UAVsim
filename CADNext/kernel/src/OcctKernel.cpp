#include "cadnext/kernel/OcctKernel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#ifdef CADNEXT_WITH_OCCT
#include <unordered_map>

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepBndLib.hxx>
#include <BRep_Tool.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRep_Builder.hxx>
#include <BRepGProp.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepTools.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <Standard_Failure.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListIteratorOfListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>

#include "cadnext/kernel/EdgeAnalyzer.hpp"
#endif

namespace cadnext::kernel {

namespace {

cadnext::Result<ShapeHandle> unavailable(const char* what) {
    return cadnext::Result<ShapeHandle>::fail({
        cadnext::ErrorCode::KernelUnavailable,
        std::string(what) + " requires an OCCT-enabled build (CADNEXT_WITH_OCCT=ON)"
    });
}

cadnext::Result<ShapeHandle> notImplemented(const char* what) {
    return cadnext::Result<ShapeHandle>::fail({
        cadnext::ErrorCode::UnsupportedOperation,
        std::string(what) + " is intentionally not implemented in CADNext 0.4"
    });
}

bool isPositiveFinite(double value) {
    return std::isfinite(value) && value > 0.0;
}

} // namespace

#ifdef CADNEXT_WITH_OCCT

cadnext::Vector3 toVector(const gp_Pnt& point) {
    return {point.X(), point.Y(), point.Z()};
}

double edgeLength(const TopoDS_Edge& edge) {
    GProp_GProps properties;
    BRepGProp::LinearProperties(edge, properties);
    const double length = properties.Mass();
    return std::isfinite(length) ? length : 0.0;
}

double faceArea(const TopoDS_Face& face) {
    GProp_GProps properties;
    BRepGProp::SurfaceProperties(face, properties);
    const double area = properties.Mass();
    return std::isfinite(area) ? area : 0.0;
}

TopoDS_Face largestAdjacentFace(const TopTools_ListOfShape& faces) {
    TopoDS_Face best;
    double bestArea = -1.0;
    for (TopTools_ListIteratorOfListOfShape it(faces); it.More(); it.Next()) {
        const TopoDS_Face face = TopoDS::Face(it.Value());
        const double area = faceArea(face);
        if (area > bestArea) {
            best = face;
            bestArea = area;
        }
    }
    return best;
}

std::string edgeIdForTopoEdge(int index, const TopoDS_Edge& edge) {
    BRepAdaptor_Curve curve(edge);
    cadnext::Vector3 start;
    cadnext::Vector3 end;
    const double first = curve.FirstParameter();
    const double last = curve.LastParameter();
    if (std::isfinite(first)) {
        start = toVector(curve.Value(first));
    }
    if (std::isfinite(last)) {
        end = toVector(curve.Value(last));
    }
    return makeEdgeId(index, start, end, edgeLength(edge));
}

// Edges chamfer/fillet can never operate on: degenerated edges (sphere
// poles, cone apexes) and edges without a 3D curve. EdgeAnalyzer skips
// them with the same predicate so ids and indices stay aligned.
bool isOperableEdge(const TopoDS_Edge& edge) {
    if (BRep_Tool::Degenerated(edge)) {
        return false;
    }
    Standard_Real first = 0.0;
    Standard_Real last = 0.0;
    return !BRep_Tool::Curve(edge, first, last).IsNull();
}

cadnext::Result<std::vector<TopoDS_Edge>> resolveEdgesById(
    const TopoDS_Shape& shape,
    const std::vector<std::string>& edgeIds
) {
    if (edgeIds.empty()) {
        return cadnext::Result<std::vector<TopoDS_Edge>>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "At least one edge id is required"
        });
    }
    std::set<std::string> requested(edgeIds.begin(), edgeIds.end());
    if (requested.empty() || requested.find("") != requested.end()) {
        return cadnext::Result<std::vector<TopoDS_Edge>>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Edge ids must be non-empty"
        });
    }

    std::vector<TopoDS_Edge> edges;
    TopTools_IndexedMapOfShape edgeMap;
    TopExp::MapShapes(shape, TopAbs_EDGE, edgeMap);
    for (int i = 1; i <= edgeMap.Extent(); ++i) {
        const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
        try {
            if (!isOperableEdge(edge)) {
                continue;
            }
            const std::string id = edgeIdForTopoEdge(i - 1, edge);
            if (requested.find(id) != requested.end()) {
                edges.push_back(edge);
            }
        } catch (const Standard_Failure&) {
            // One broken edge must not abort resolution of the others.
        }
    }
    if (edges.size() != requested.size()) {
        return cadnext::Result<std::vector<TopoDS_Edge>>::fail({
            cadnext::ErrorCode::NotFound,
            "One or more selected edge ids no longer resolve on the target body"
        });
    }
    return cadnext::Result<std::vector<TopoDS_Edge>>::ok(std::move(edges));
}

struct OcctKernel::Impl {
    std::unordered_map<std::string, TopoDS_Shape> shapes;
    std::uint64_t nextId = 1;

    ShapeHandle store(const TopoDS_Shape& shape, const char* prefix) {
        const std::string id = std::string(prefix) + "-" + std::to_string(nextId++);
        shapes.emplace(id, shape);
        return ShapeHandle(id);
    }
};

OcctKernel::OcctKernel() : impl_(std::make_unique<Impl>()) {}

OcctKernel::~OcctKernel() = default;

cadnext::Result<ShapeHandle> OcctKernel::makeBox(const BoxParameters& params) {
    if (!isPositiveFinite(params.width) || !isPositiveFinite(params.height) ||
        !isPositiveFinite(params.depth)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Box dimensions must be finite and positive"
        });
    }
    try {
        // Centered on the local origin; width=X, depth=Y, height=Z.
        const gp_Pnt corner(-params.width / 2.0, -params.depth / 2.0, -params.height / 2.0);
        BRepPrimAPI_MakeBox builder(corner, params.width, params.depth, params.height);
        builder.Build();
        if (!builder.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT box construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(builder.Shape(), "occt-box"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT box construction failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeCylinder(const CylinderParameters& params) {
    if (!isPositiveFinite(params.radius) || !isPositiveFinite(params.height)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Cylinder radius and height must be finite and positive"
        });
    }
    try {
        // Axis along local Z, centered: spans [-height/2, +height/2].
        const gp_Ax2 axis(gp_Pnt(0.0, 0.0, -params.height / 2.0), gp_Dir(0.0, 0.0, 1.0));
        BRepPrimAPI_MakeCylinder builder(axis, params.radius, params.height);
        builder.Build();
        if (!builder.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT cylinder construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(builder.Shape(), "occt-cylinder"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT cylinder construction failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeSphere(const SphereParameters& params) {
    if (!isPositiveFinite(params.radius)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Sphere radius must be finite and positive"
        });
    }
    try {
        // Centered on the local origin.
        BRepPrimAPI_MakeSphere builder(params.radius);
        builder.Build();
        if (!builder.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT sphere construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(builder.Shape(), "occt-sphere"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT sphere construction failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedPolygon(
    const ExtrudedPolygonParameters& params) {
    if (params.loop.size() < 3) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extruded polygon needs at least 3 loop points"
        });
    }
    const gp_Vec extrusion(params.extrusion.x, params.extrusion.y, params.extrusion.z);
    if (extrusion.Magnitude() <= 1.0e-12) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extrusion vector must be non-zero"
        });
    }
    try {
        // Closed planar loop → wire → face → prism along the world vector.
        BRepBuilderAPI_MakePolygon polygon;
        for (const cadnext::Vector3& point : params.loop) {
            polygon.Add(gp_Pnt(point.x, point.y, point.z));
        }
        polygon.Close();
        if (!polygon.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "OCCT polygon wire construction failed"});
        }
        BRepBuilderAPI_MakeFace face(polygon.Wire());
        if (!face.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "OCCT profile face construction failed (loop not planar/closed?)"});
        }
        BRepPrimAPI_MakePrism prism(face.Face(), extrusion);
        prism.Build();
        if (!prism.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT prism construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(prism.Shape(), "occt-extrude"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT polygon extrude failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedCircle(
    const ExtrudedCircleParameters& params) {
    if (!isPositiveFinite(params.radius)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extruded circle radius must be finite and positive"
        });
    }
    const gp_Vec extrusion(params.extrusion.x, params.extrusion.y, params.extrusion.z);
    if (extrusion.Magnitude() <= 1.0e-12) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extrusion vector must be non-zero"
        });
    }
    try {
        // Exact circular wire (no polygon approximation in the BRep path).
        const gp_Ax2 axis(gp_Pnt(params.center.x, params.center.y, params.center.z),
                          gp_Dir(params.normal.x, params.normal.y, params.normal.z));
        const gp_Circ circle(axis, params.radius);
        BRepBuilderAPI_MakeEdge edge(circle);
        BRepBuilderAPI_MakeWire wire(edge.Edge());
        BRepBuilderAPI_MakeFace face(wire.Wire());
        if (!face.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "OCCT circle face construction failed"});
        }
        BRepPrimAPI_MakePrism prism(face.Face(), extrusion);
        prism.Build();
        if (!prism.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT prism construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(
            impl_->store(prism.Shape(), "occt-extrude-circle"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT circle extrude failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::booleanCut(const ShapeHandle& target,
                                                    const ShapeHandle& tool) {
    const TopoDS_Shape* targetShape = findShape(target);
    const TopoDS_Shape* toolShape = findShape(tool);
    if (!targetShape || targetShape->IsNull() || !toolShape || toolShape->IsNull()) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::ShapeInvalid,
            "Boolean cut requires two valid shape handles"
        });
    }
    try {
        // Topological BRep boolean (never a mesh subtraction).
        BRepAlgoAPI_Cut cut(*targetShape, *toolShape);
        cut.Build();
        if (!cut.IsDone() || cut.HasErrors()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT boolean cut failed"});
        }
        const TopoDS_Shape result = cut.Shape();
        if (result.IsNull()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "OCCT boolean cut produced an empty shape"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(result, "occt-cut"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT boolean cut failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::chamferEdges(
    const ShapeHandle& target,
    const std::vector<std::string>& edgeIds,
    double distance,
    cadnext::ChamferMode mode,
    double angleDeg
) {
    if (!isPositiveFinite(distance)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Chamfer distance must be finite and positive"
        });
    }
    if (mode == cadnext::ChamferMode::DistanceAngle &&
        (!std::isfinite(angleDeg) || angleDeg <= 0.0 || angleDeg >= 90.0)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Chamfer angle must be in (0, 90) degrees"
        });
    }
    const TopoDS_Shape* targetShape = findShape(target);
    if (!targetShape || targetShape->IsNull()) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::ShapeInvalid,
            "Chamfer requires a valid target shape"
        });
    }
    try {
        const cadnext::Result<std::vector<TopoDS_Edge>> edges =
            resolveEdgesById(*targetShape, edgeIds);
        if (!edges.isOk()) {
            return cadnext::Result<ShapeHandle>::fail(edges.error());
        }

        // Distance+angle chamfers are measured on a reference face, so map
        // every edge to its adjacent faces up front.
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaceMap;
        if (mode == cadnext::ChamferMode::DistanceAngle) {
            TopExp::MapShapesAndAncestors(*targetShape, TopAbs_EDGE, TopAbs_FACE,
                                          edgeFaceMap);
        }

        BRepFilletAPI_MakeChamfer chamfer(*targetShape);
        for (const TopoDS_Edge& edge : edges.value()) {
            const bool defaultAngle =
                mode == cadnext::ChamferMode::DistanceAngle &&
                std::abs(angleDeg - 45.0) <= 1.0e-9;
            if (mode == cadnext::ChamferMode::DistanceAngle && !defaultAngle) {
                const Standard_Integer index = edgeFaceMap.FindIndex(edge);
                if (index == 0 || edgeFaceMap(index).IsEmpty()) {
                    return cadnext::Result<ShapeHandle>::fail({
                        cadnext::ErrorCode::NotFound,
                        "Chamfer edge has no adjacent reference face"
                    });
                }
                const TopoDS_Face face = largestAdjacentFace(edgeFaceMap(index));
                if (face.IsNull()) {
                    return cadnext::Result<ShapeHandle>::fail({
                        cadnext::ErrorCode::NotFound,
                        "Chamfer edge has no usable adjacent reference face"
                    });
                }
                chamfer.AddDA(distance, angleDeg * M_PI / 180.0, edge, face);
            } else {
                chamfer.Add(distance, edge);
            }
        }
        chamfer.Build();
        if (!chamfer.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::KernelOperationFailed,
                "OCCT chamfer failed"
            });
        }
        const TopoDS_Shape result = chamfer.Shape();
        if (result.IsNull()) {
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::KernelOperationFailed,
                "OCCT chamfer produced an empty shape"
            });
        }
        const BRepCheck_Analyzer analyzer(result);
        if (analyzer.IsValid() != Standard_True) {
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::ShapeInvalid,
                "OCCT chamfer produced an invalid shape"
            });
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(result, "occt-chamfer"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT chamfer failed: ") + failure.GetMessageString()});
    } catch (const std::exception& exception) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT chamfer failed: ") + exception.what()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::filletEdges(
    const ShapeHandle& target,
    const std::vector<std::string>& edgeIds,
    double radius
) {
    if (!isPositiveFinite(radius)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Fillet radius must be finite and positive"
        });
    }
    const TopoDS_Shape* targetShape = findShape(target);
    if (!targetShape || targetShape->IsNull()) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::ShapeInvalid,
            "Fillet requires a valid target shape"
        });
    }
    try {
        const cadnext::Result<std::vector<TopoDS_Edge>> edges =
            resolveEdgesById(*targetShape, edgeIds);
        if (!edges.isOk()) {
            return cadnext::Result<ShapeHandle>::fail(edges.error());
        }

        BRepFilletAPI_MakeFillet fillet(*targetShape);
        for (const TopoDS_Edge& edge : edges.value()) {
            fillet.Add(radius, edge);
        }
        fillet.Build();
        if (!fillet.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::KernelOperationFailed,
                "OCCT fillet failed"
            });
        }
        const TopoDS_Shape result = fillet.Shape();
        if (result.IsNull()) {
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::KernelOperationFailed,
                "OCCT fillet produced an empty shape"
            });
        }
        const BRepCheck_Analyzer analyzer(result);
        if (analyzer.IsValid() != Standard_True) {
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::ShapeInvalid,
                "OCCT fillet produced an invalid shape"
            });
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(result, "occt-fillet"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT fillet failed: ") + failure.GetMessageString()});
    } catch (const std::exception& exception) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT fillet failed: ") + exception.what()});
    }
}

cadnext::Result<ShapeBounds> OcctKernel::boundingBox(const ShapeHandle& shape) {
    const TopoDS_Shape* topoShape = findShape(shape);
    if (!topoShape || topoShape->IsNull()) {
        return cadnext::Result<ShapeBounds>::fail({
            cadnext::ErrorCode::ShapeInvalid,
            "Bounding box requires a valid shape handle"
        });
    }
    try {
        Bnd_Box box;
        BRepBndLib::Add(*topoShape, box);
        if (box.IsVoid()) {
            return cadnext::Result<ShapeBounds>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "Shape bounding box is void"});
        }
        Standard_Real xMin = 0.0;
        Standard_Real yMin = 0.0;
        Standard_Real zMin = 0.0;
        Standard_Real xMax = 0.0;
        Standard_Real yMax = 0.0;
        Standard_Real zMax = 0.0;
        box.Get(xMin, yMin, zMin, xMax, yMax, zMax);
        ShapeBounds bounds;
        bounds.min = {xMin, yMin, zMin};
        bounds.max = {xMax, yMax, zMax};
        return cadnext::Result<ShapeBounds>::ok(bounds);
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeBounds>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT bounding box failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeMassProperties> OcctKernel::volumeProperties(const ShapeHandle& shape) {
    const TopoDS_Shape* topoShape = findShape(shape);
    if (!topoShape || topoShape->IsNull()) {
        return cadnext::Result<ShapeMassProperties>::fail({
            cadnext::ErrorCode::ShapeInvalid,
            "Volume properties require a valid shape handle"
        });
    }
    try {
        GProp_GProps properties;
        BRepGProp::VolumeProperties(*topoShape, properties);
        const double volume = properties.Mass();
        if (!std::isfinite(volume) || volume <= 0.0) {
            return cadnext::Result<ShapeMassProperties>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "Shape volume is not finite and positive"});
        }
        ShapeMassProperties result;
        result.volumeM3 = volume;
        result.centerOfMass = toVector(properties.CentreOfMass());
        if (!std::isfinite(result.centerOfMass.x) || !std::isfinite(result.centerOfMass.y) ||
            !std::isfinite(result.centerOfMass.z)) {
            return cadnext::Result<ShapeMassProperties>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "Shape center of mass is not finite"});
        }
        return cadnext::Result<ShapeMassProperties>::ok(result);
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeMassProperties>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT volume properties failed: ") + failure.GetMessageString()});
    }
}

bool OcctKernel::isShapeValid(const ShapeHandle& shape) const {
    const TopoDS_Shape* topoShape = findShape(shape);
    if (!topoShape || topoShape->IsNull()) {
        return false;
    }
    try {
        const BRepCheck_Analyzer analyzer(*topoShape);
        return analyzer.IsValid() == Standard_True;
    } catch (const Standard_Failure&) {
        return false;
    }
}

cadnext::Result<std::vector<std::uint8_t>> OcctKernel::exportBRep(const ShapeHandle& handle) {
    const TopoDS_Shape* shape = findShape(handle);
    if (!shape || shape->IsNull()) {
        return cadnext::Result<std::vector<std::uint8_t>>::fail(
            {cadnext::ErrorCode::ShapeInvalid, "Shape not found for BRep export"});
    }
    try {
        std::ostringstream oss;
        BRepTools::Write(*shape, oss);
        const std::string text = oss.str();
        return cadnext::Result<std::vector<std::uint8_t>>::ok(
            std::vector<std::uint8_t>(text.begin(), text.end()));
    } catch (const Standard_Failure& e) {
        return cadnext::Result<std::vector<std::uint8_t>>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("BRep export failed: ") + e.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::importBRep(const std::vector<std::uint8_t>& brepData) {
    if (brepData.empty()) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::InvalidArgument, "BRep payload is empty"});
    }
    try {
        const std::string brepText(brepData.begin(), brepData.end());
        std::istringstream iss(brepText);
        BRep_Builder builder;
        TopoDS_Shape shape;
        BRepTools::Read(shape, iss, builder);
        if (shape.IsNull()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::SerializationFailed, "Imported BRep shape is null"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(shape, "occt-imported"));
    } catch (const Standard_Failure& e) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("BRep import failed: ") + e.GetMessageString()});
    }
}

const TopoDS_Shape* OcctKernel::findShape(const ShapeHandle& handle) const {
    if (handle.isNull()) {
        return nullptr;
    }
    const auto it = impl_->shapes.find(handle.id());
    return it == impl_->shapes.end() ? nullptr : &it->second;
}

#else // !CADNEXT_WITH_OCCT

struct OcctKernel::Impl {};

OcctKernel::OcctKernel() : impl_(std::make_unique<Impl>()) {}

OcctKernel::~OcctKernel() = default;

cadnext::Result<ShapeHandle> OcctKernel::makeBox(const BoxParameters&) {
    return unavailable("OCCT box");
}

cadnext::Result<ShapeHandle> OcctKernel::makeCylinder(const CylinderParameters&) {
    return unavailable("OCCT cylinder");
}

cadnext::Result<ShapeHandle> OcctKernel::makeSphere(const SphereParameters&) {
    return unavailable("OCCT sphere");
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedPolygon(const ExtrudedPolygonParameters&) {
    return unavailable("OCCT polygon extrude");
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedCircle(const ExtrudedCircleParameters&) {
    return unavailable("OCCT circle extrude");
}

cadnext::Result<ShapeHandle> OcctKernel::booleanCut(const ShapeHandle&, const ShapeHandle&) {
    return unavailable("OCCT boolean cut");
}

cadnext::Result<ShapeHandle> OcctKernel::chamferEdges(
    const ShapeHandle&,
    const std::vector<std::string>&,
    double,
    cadnext::ChamferMode,
    double
) {
    return unavailable("Chamfer");
}

cadnext::Result<ShapeHandle> OcctKernel::filletEdges(
    const ShapeHandle&,
    const std::vector<std::string>&,
    double
) {
    return unavailable("Fillet");
}

cadnext::Result<ShapeBounds> OcctKernel::boundingBox(const ShapeHandle&) {
    return cadnext::Result<ShapeBounds>::fail({
        cadnext::ErrorCode::KernelUnavailable,
        "Shape bounds require an OCCT-enabled build (CADNEXT_WITH_OCCT=ON)"
    });
}

cadnext::Result<ShapeMassProperties> OcctKernel::volumeProperties(const ShapeHandle&) {
    return cadnext::Result<ShapeMassProperties>::fail({
        cadnext::ErrorCode::KernelUnavailable,
        "Volume properties require an OCCT-enabled build (CADNEXT_WITH_OCCT=ON)"
    });
}

cadnext::Result<std::vector<std::uint8_t>> OcctKernel::exportBRep(const ShapeHandle&) {
    return cadnext::Result<std::vector<std::uint8_t>>::fail({
        cadnext::ErrorCode::KernelUnavailable,
        "BRep export requires an OCCT-enabled build (CADNEXT_WITH_OCCT=ON)"
    });
}

cadnext::Result<ShapeHandle> OcctKernel::importBRep(const std::vector<std::uint8_t>&) {
    return unavailable("OCCT BRep import");
}

bool OcctKernel::isShapeValid(const ShapeHandle&) const {
    return false;
}

#endif // CADNEXT_WITH_OCCT

cadnext::Result<ShapeHandle> OcctKernel::booleanFuse(const ShapeHandle&, const ShapeHandle&) {
    return notImplemented("OCCT boolean fuse");
}

cadnext::Result<ShapeHandle> OcctKernel::booleanCommon(const ShapeHandle&, const ShapeHandle&) {
    return notImplemented("OCCT boolean common");
}

bool OcctKernel::isAvailable() const {
#ifdef CADNEXT_WITH_OCCT
    return true;
#else
    return false;
#endif
}

} // namespace cadnext::kernel
