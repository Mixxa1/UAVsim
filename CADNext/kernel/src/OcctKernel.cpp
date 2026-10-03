#include "cadnext/kernel/OcctKernel.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#ifdef CADNEXT_WITH_OCCT
#include <unordered_map>
#include <queue>

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRep_Tool.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BinTools.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeFix_Wire.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <ShapeFix_Shell.hxx>
#include <ShapeFix_Edge.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRep_Builder.hxx>
#include <BRepLib.hxx>
#include <BRepGProp.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepTools.hxx>
#include <BRepTools_ReShape.hxx>
#include <TopTools_FormatVersion.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GeomAPI_IntSS.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom_Plane.hxx>
#include <Geom_SphericalSurface.hxx>
#include <Geom_ToroidalSurface.hxx>
#include <Geom_OffsetSurface.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom2d_Line.hxx>
#include <TColgp_Array1OfPnt2d.hxx>
#include <Geom_SurfaceOfLinearExtrusion.hxx>
#include <Geom_SurfaceOfRevolution.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <gp_Pnt2d.hxx>
#include <Geom_RectangularTrimmedSurface.hxx>
#include <Geom_Circle.hxx>
#include <Geom_Ellipse.hxx>
#include <Geom_Line.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Standard_Failure.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopAbs_State.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListIteratorOfListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Iterator.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Wire.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <IGESControl_Reader.hxx>
#include <IGESControl_Writer.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <gp_Trsf.hxx>
#include <gp_GTrsf.hxx>
#include <gp_Mat.hxx>
#include <gp_Ax2.hxx>
#include <gp_Ax3.hxx>
#include <gp_Ax1.hxx>
#include <gp_Circ.hxx>
#include <gp_Elips.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Cone.hxx>
#include <gp_Torus.hxx>
#include <gp_Pnt.hxx>
#include <gp_Pln.hxx>
#include <gp_Vec.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <TCollection_ExtendedString.hxx>
#include <TDataStd_Name.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDocStd_Document.hxx>
#include <TopLoc_Location.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>

#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "OcctRollingBall.hpp"

#include <map>
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

namespace {
std::string exchangeExtension(const std::string& path) {
    const auto dot = path.find_last_of('.');
    if (dot == std::string::npos) return {};
    std::string result = path.substr(dot);
    std::transform(result.begin(), result.end(), result.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return result;
}

TopoDS_Shape scaledShape(const TopoDS_Shape& shape, double factor) {
    gp_Trsf scale;
    scale.SetScale(gp_Pnt(0.0, 0.0, 0.0), factor);
    return BRepBuilderAPI_Transform(shape, scale, true).Shape();
}

class BoundarySewing final : public BRepBuilderAPI_Sewing {
public:
    BoundarySewing(double tolerance, bool preserveBoundaries)
        : BRepBuilderAPI_Sewing(tolerance), preserveBoundaries_(preserveBoundaries) {}

protected:
    void SameParameter(const TopoDS_Edge& edge) const override {
        if (preserveBoundaries_ && BRep_Tool::SameRange(edge) && BRep_Tool::SameParameter(edge)) return;
        if (preserveBoundaries_ && hasCommonParameter(edge)) {
            // Sewing can clear these flags while keeping already compatible
            // curves. Re-fitting their UV geometry to the shared 3D curve
            // would change a face's boundary inside its native tolerance.
            // Set the flags only after checking all stored representations.
            BRep_Builder builder;
            builder.SameRange(edge, true);
            builder.SameParameter(edge, true);
        } else if (preserveBoundaries_)
            // OCCT's merge calls this with its default precision, even when a
            // valid UV boundary differs from the shared 3D curve by the edge's
            // declared tolerance. Keep that tolerance during reparameterisation.
            BRepLib::SameParameter(edge, BRep_Tool::Tolerance(edge));
        else
            BRepBuilderAPI_Sewing::SameParameter(edge);
    }

private:
    static bool hasCommonParameter(const TopoDS_Edge& edge) {
        try {
            double first, last;
            TopLoc_Location curveLocation;
            const auto curve = BRep_Tool::Curve(edge, curveLocation, first, last);
            if (curve.IsNull() || !(last > first) || !std::isfinite(first) || !std::isfinite(last)) return false;
            const double tolerance = BRep_Tool::Tolerance(edge);
            if (!std::isfinite(tolerance) || !(tolerance > 0)) return false;
            bool hasBoundary = false;
            for (int index = 1;; ++index) {
                Handle(Geom2d_Curve) pcurve;
                Handle(Geom_Surface) surface;
                TopLoc_Location surfaceLocation;
                double from, to;
                BRep_Tool::CurveOnSurface(edge, pcurve, surface, surfaceLocation, from, to, index);
                if (pcurve.IsNull() || surface.IsNull()) break;
                const double scale = std::max({1.0, std::fabs(first), std::fabs(last)});
                if (std::fabs(from - first) > 1e-12 * scale || std::fabs(to - last) > 1e-12 * scale)
                    return false;
                for (int sample = 0; sample <= 64; ++sample) {
                    const double parameter = first + (last - first) * sample / 64.0;
                    const auto uv = pcurve->Value(parameter);
                    const auto onSurface = surface->Value(uv.X(), uv.Y()).Transformed(surfaceLocation.Transformation());
                    const auto inSpace = curve->Value(parameter).Transformed(curveLocation.Transformation());
                    if (!(onSurface.Distance(inSpace) <= tolerance)) return false;
                }
                hasBoundary = true;
            }
            return hasBoundary;
        } catch (const Standard_Failure&) {
            return false;
        }
    }

    bool preserveBoundaries_;
};

TopoDS_Shape placedShape(const TopoDS_Shape& shape, const cadnext::Transform& placement) {
    const auto& s = placement.scale;
    TopoDS_Shape sized = shape;
    if (s.x == s.y && s.y == s.z) {
        // GTransform can turn even an unscaled circle/cylinder into a
        // B-spline. A gp_Trsf keeps analytic geometry for uniform scaling.
        if (s.x != 1.0) {
            gp_Trsf scaling;
            scaling.SetScale(gp_Pnt(0.0, 0.0, 0.0), s.x);
            sized = BRepBuilderAPI_Transform(shape, scaling, true).Shape();
        }
    } else {
        gp_GTrsf scaling;
        scaling.SetVectorialPart(gp_Mat(s.x, 0.0, 0.0,
                                       0.0, s.y, 0.0,
                                       0.0, 0.0, s.z));
        sized = BRepBuilderAPI_GTransform(shape, scaling, true).Shape();
    }
    if (placement.position.x == 0.0 && placement.position.y == 0.0 && placement.position.z == 0.0 &&
        placement.rotationEuler.x == 0.0 && placement.rotationEuler.y == 0.0 && placement.rotationEuler.z == 0.0)
        return sized;
    constexpr double kRadians = M_PI / 180.0;
    gp_Trsf rx, ry, rz, translation;
    rx.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0)),
                   placement.rotationEuler.x * kRadians);
    ry.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 1, 0)),
                   placement.rotationEuler.y * kRadians);
    rz.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)),
                   placement.rotationEuler.z * kRadians);
    translation.SetTranslation(gp_Vec(placement.position.x, placement.position.y,
                                      placement.position.z));
    // A rigid placement is a location. Copying every underlying support and pcurve here can
    // expand shared spline grids and needlessly re-parameterise tolerant boundaries.
    return BRepBuilderAPI_Transform(sized, translation * rz * ry * rx, false).Shape();
}

// A solid may touch itself along an edge: ACIS then has four coedges in a partner ring.
// Sewing represents it by two coincident edges, but can pair the wrong faces. The ordinary
// edges determine the orientation of all neighbouring faces; use that orientation to pair
// the touching faces without changing their geometry or dropping any face. Require one
// connected orientation constraint for each group, so disconnected pieces are not guessed.
bool reconnectTouchingEdges(TopoDS_Shell& shell, std::string& diagnostic) {
    TopTools_IndexedMapOfShape faces, edges, vertices;
    TopExp::MapShapes(shell, TopAbs_FACE, faces);
    TopExp::MapShapes(shell, TopAbs_EDGE, edges);
    TopExp::MapShapes(shell, TopAbs_VERTEX, vertices);
    struct Use { int face, edge; bool reversed; };
    std::vector<std::vector<Use>> uses(std::size_t(edges.Extent()+1));
    for (int f=1; f<=faces.Extent(); ++f)
        for (TopExp_Explorer it(faces(f), TopAbs_EDGE); it.More(); it.Next()) {
            const auto edge=TopoDS::Edge(it.Current());
            if (!BRep_Tool::Degenerated(edge))
                uses[std::size_t(edges.FindIndex(edge))].push_back({f, edges.FindIndex(edge),
                    edge.Orientation()==TopAbs_REVERSED});
        }
    std::map<std::pair<int,int>, std::vector<int>> atEnds;
    for (int e=1; e<=edges.Extent(); ++e) {
        const auto& incidence=uses[std::size_t(e)];
        if (incidence.size()!=2 || incidence[0].face==incidence[1].face) continue;
        TopoDS_Vertex first, last;
        TopExp::Vertices(TopoDS::Edge(edges(e)), first, last, false);
        if (first.IsNull() || last.IsNull() || first.IsSame(last)) continue;
        const int a=vertices.FindIndex(first), b=vertices.FindIndex(last);
        atEnds[{std::min(a,b),std::max(a,b)}].push_back(e);
    }
    const auto coincident=[&](int a, int b) {
        const auto ea=TopoDS::Edge(edges(a)), eb=TopoDS::Edge(edges(b));
        TopoDS_Vertex af, al, bf, bl;
        TopExp::Vertices(ea,af,al,false); TopExp::Vertices(eb,bf,bl,false);
        const bool opposite=!af.IsSame(bf);
        const BRepAdaptor_Curve ca(ea), cb(eb);
        // Only genuinely coincident curves qualify: equal endpoints alone also describe
        // complementary arcs on a periodic support. Check the interior and arc length.
        if (std::fabs(edgeLength(ea)-edgeLength(eb))>1e-7) return false;
        for (double fraction : {0.125,0.25,0.5,0.75,0.875}) {
            const gp_Pnt pa=ca.Value(ca.FirstParameter()+(ca.LastParameter()-ca.FirstParameter())*fraction);
            const double along=opposite ? 1.0-fraction : fraction;
            const gp_Pnt pb=cb.Value(cb.FirstParameter()+(cb.LastParameter()-cb.FirstParameter())*along);
            if (pa.Distance(pb)>1e-7) return false;
        }
        return true;
    };
    std::vector<std::vector<int>> groups;
    std::vector<bool> touching(std::size_t(edges.Extent()+1),false);
    for (const auto& [ends, candidates] : atEnds) {
        std::vector<bool> assigned(candidates.size(),false);
        for (std::size_t i=0; i<candidates.size(); ++i) {
            if (assigned[i]) continue;
            std::vector<int> group{candidates[i]};
            for (std::size_t j=i+1; j<candidates.size(); ++j)
                if (!assigned[j] && coincident(candidates[i],candidates[j])) {
                    assigned[j]=true; group.push_back(candidates[j]);
                }
            if (group.size()<2) continue;
            for (int e : group) touching[std::size_t(e)]=true;
            groups.push_back(std::move(group));
        }
    }
    if (groups.empty()) { diagnostic="no coincident touching edges"; return false; }
    std::vector<std::vector<std::pair<int,bool>>> neighbours(std::size_t(faces.Extent()+1));
    for (int e=1; e<=edges.Extent(); ++e) {
        const auto& incidence=uses[std::size_t(e)];
        if (touching[std::size_t(e)] || incidence.size()!=2 || incidence[0].face==incidence[1].face) continue;
        const auto& a=incidence[0]; const auto& b=incidence[1];
        const bool parity=a.reversed==b.reversed;
        neighbours[std::size_t(a.face)].push_back({b.face,parity});
        neighbours[std::size_t(b.face)].push_back({a.face,parity});
    }
    std::vector<int> flipped(std::size_t(faces.Extent()+1),-1), component(flipped.size(),-1);
    for (int seed=1; seed<=faces.Extent(); ++seed) {
        if (flipped[std::size_t(seed)]>=0) continue;
        std::queue<int> pending; pending.push(seed);
        flipped[std::size_t(seed)]=0; component[std::size_t(seed)]=seed;
        while (!pending.empty()) {
            const int face=pending.front(); pending.pop();
            for (const auto& [next,parity] : neighbours[std::size_t(face)]) {
                const int expected=flipped[std::size_t(face)]^int(parity);
                if (flipped[std::size_t(next)]<0) {
                    flipped[std::size_t(next)]=expected; component[std::size_t(next)]=seed;
                    pending.push(next);
                } else if (flipped[std::size_t(next)]!=expected) {
                    diagnostic="ordinary edges have inconsistent face orientations"; return false;
                }
            }
        }
    }
    std::vector<Handle(BRepTools_ReShape)> replacements(flipped.size());
    for (int f=1; f<=faces.Extent(); ++f) replacements[std::size_t(f)]=new BRepTools_ReShape;
    BRep_Builder builder;
    for (const auto& group : groups) {
        TopoDS_Vertex first, last;
        TopExp::Vertices(TopoDS::Edge(edges(group.front())),first,last,false);
        std::vector<Use> sides[2];
        const int connected=component[std::size_t(uses[std::size_t(group.front())].front().face)];
        for (int e : group) for (const auto& use : uses[std::size_t(e)]) {
            if (component[std::size_t(use.face)]!=connected) {
                diagnostic="touching pieces do not determine a common orientation"; return false;
            }
            TopoDS_Vertex from, to;
            const auto along=TopoDS::Edge(edges(e).Oriented(use.reversed?TopAbs_REVERSED:TopAbs_FORWARD));
            TopExp::Vertices(along,from,to,true);
            const bool backwards=!first.IsSame(from);
            sides[backwards^bool(flipped[std::size_t(use.face)])].push_back(use);
        }
        if (sides[0].size()!=sides[1].size()) {
            diagnostic="touching edge has unbalanced face directions"; return false;
        }
        for (const auto& a : sides[0]) {
            // Keep an existing correct pair when possible.
            auto other=std::find_if(sides[1].begin(),sides[1].end(),[&](const Use& u){ return u.edge==a.edge; });
            if (other==sides[1].end()) other=sides[1].begin();
            const Use b=*other; sides[1].erase(other);
            if (a.edge==b.edge) continue;
            const auto base=TopoDS::Edge(edges(a.edge).Oriented(TopAbs_FORWARD));
            auto fresh=TopoDS::Edge(base.EmptyCopied());
            // EmptyCopied keeps the geometric representation. Reuse the already sewn vertices.
            for (TopoDS_Iterator v(base); v.More(); v.Next()) builder.Add(fresh,v.Value());
            ShapeFix_Edge edgeFix;
            if (!edgeFix.FixAddPCurve(fresh,TopoDS::Face(faces(b.face)),false,1e-7) &&
                !edgeFix.Status(ShapeExtend_OK)) {
                diagnostic="could not attach touching edge to its neighbour"; return false;
            }
            edgeFix.FixSameParameter(fresh,1e-7);
            if (BRep_Tool::Tolerance(fresh)>1.01*std::max({1e-7,BRep_Tool::Tolerance(base),
                                                          BRep_Tool::Tolerance(TopoDS::Edge(edges(b.edge)))})) {
                diagnostic="touching edge exceeds its original tolerance"; return false;
            }
            TopoDS_Vertex from, to; TopExp::Vertices(base,from,to,false);
            for (const auto& use : {a,b}) {
                const auto old=TopoDS::Edge(edges(use.edge).Oriented(TopAbs_FORWARD));
                TopoDS_Vertex oldFirst, oldLast; TopExp::Vertices(old,oldFirst,oldLast,false);
                replacements[std::size_t(use.face)]->Replace(old,
                    fresh.Oriented(from.IsSame(oldFirst)?TopAbs_FORWARD:TopAbs_REVERSED));
            }
        }
    }
    TopoDS_Shell rebuilt; builder.MakeShell(rebuilt);
    for (int f=1; f<=faces.Extent(); ++f) {
        const auto face=replacements[std::size_t(f)]->Apply(faces(f));
        if (!BRepCheck_Analyzer(face).IsValid()) {
            diagnostic="reconnecting touching edges made an invalid face"; return false;
        }
        builder.Add(rebuilt,face);
    }
    shell=rebuilt;
    return true;
}
} // namespace

cadnext::Result<ShapeHandle> OcctKernel::placeExchangeBody(const ExchangeBody& body) {
    const TopoDS_Shape* original = findShape(body.shape);
    if (!original || original->IsNull()) return cadnext::Result<ShapeHandle>::fail(
        {cadnext::ErrorCode::ShapeInvalid, "Unknown body for CAD export"});
    const auto& p = body.placement;
    for (double value : {p.position.x, p.position.y, p.position.z,
                         p.rotationEuler.x, p.rotationEuler.y, p.rotationEuler.z,
                         p.scale.x, p.scale.y, p.scale.z})
        if (!std::isfinite(value)) return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::InvalidArgument, "Body placement is not finite"});
    if (p.scale.x <= 0.0 || p.scale.y <= 0.0 || p.scale.z <= 0.0)
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::InvalidArgument, "Body scale must be positive"});
    try {
        return cadnext::Result<ShapeHandle>::ok(impl_->store(placedShape(*original, p), "occt-exchange-placed"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail({cadnext::ErrorCode::KernelOperationFailed,
            std::string("CAD body placement failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::importExchangeFile(const std::string& path) {
    if (path.empty()) return cadnext::Result<ShapeHandle>::fail(
        {cadnext::ErrorCode::InvalidArgument, "Empty CAD exchange path"});
    const std::string ext = exchangeExtension(path);
    try {
        TopoDS_Shape shape;
        if (ext == ".step" || ext == ".stp") {
            STEPControl_Reader reader;
            if (reader.ReadFile(path.c_str()) != IFSelect_RetDone ||
                reader.TransferRoots() <= 0) {
                return cadnext::Result<ShapeHandle>::fail(
                    {cadnext::ErrorCode::SerializationFailed, "Could not read STEP geometry"});
            }
            shape = reader.OneShape();
        } else if (ext == ".iges" || ext == ".igs") {
            IGESControl_Reader reader;
            if (reader.ReadFile(path.c_str()) != IFSelect_RetDone ||
                reader.TransferRoots() <= 0) {
                return cadnext::Result<ShapeHandle>::fail(
                    {cadnext::ErrorCode::SerializationFailed, "Could not read IGES geometry"});
            }
            shape = reader.OneShape();
        } else {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::UnsupportedOperation, "Use .step, .stp, .iges or .igs"});
        }
        if (shape.IsNull()) return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::SerializationFailed, "CAD exchange file contains no geometry"});
        return cadnext::Result<ShapeHandle>::ok(
            impl_->store(scaledShape(shape, 0.001), "occt-import"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("CAD import failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<bool> OcctKernel::exportExchangeFile(
    const std::vector<ExchangeBody>& shapes, const std::string& path) {
    if (shapes.empty() || path.empty()) return cadnext::Result<bool>::fail(
        {cadnext::ErrorCode::InvalidArgument, "Choose at least one body and an output path"});
    try {
        TopoDS_Compound compound;
        BRep_Builder builder;
        builder.MakeCompound(compound);
        for (const ExchangeBody& body : shapes) {
            const TopoDS_Shape* shape = findShape(body.shape);
            if (!shape || shape->IsNull()) return cadnext::Result<bool>::fail(
                {cadnext::ErrorCode::NotFound, "A selected body has no BRep geometry"});
            builder.Add(compound, scaledShape(placedShape(*shape, body.placement), 1000.0));
        }
        const std::string ext = exchangeExtension(path);
        if (ext == ".step" || ext == ".stp") {
            STEPControl_Writer writer;
            if (writer.Transfer(compound, STEPControl_AsIs) != IFSelect_RetDone ||
                writer.Write(path.c_str()) != IFSelect_RetDone) {
                return cadnext::Result<bool>::fail(
                    {cadnext::ErrorCode::SerializationFailed, "STEP export failed"});
            }
        } else if (ext == ".iges" || ext == ".igs") {
            // Mode 1 writes IGES BRep topology (manifold solid entity 186). Mode 0 writes only
            // separate trimmed surfaces and loses the solid contract on our own readback.
            IGESControl_Writer writer("MM", 1);
            writer.AddShape(compound);
            if (!writer.Write(path.c_str())) return cadnext::Result<bool>::fail(
                {cadnext::ErrorCode::SerializationFailed, "IGES export failed"});
        } else {
            return cadnext::Result<bool>::fail(
                {cadnext::ErrorCode::UnsupportedOperation, "Use .step, .stp, .iges or .igs"});
        }
        return cadnext::Result<bool>::ok(true);
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<bool>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("CAD export failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<std::vector<ImportedExchangeBody>> OcctKernel::importStepAssembly(
    const std::string& path) {
    if (path.empty()) return cadnext::Result<std::vector<ImportedExchangeBody>>::fail(
        {cadnext::ErrorCode::InvalidArgument, "Empty STEP path"});
    try {
        Handle(TDocStd_Document) document = new TDocStd_Document("BinXCAF");
        STEPCAFControl_Reader reader;
        reader.SetNameMode(Standard_True);
        if (reader.ReadFile(path.c_str()) != IFSelect_RetDone ||
            !reader.Transfer(document)) {
            return cadnext::Result<std::vector<ImportedExchangeBody>>::fail(
                {cadnext::ErrorCode::SerializationFailed, "Could not read STEP assembly"});
        }
        const Handle(XCAFDoc_ShapeTool) shapes =
            XCAFDoc_DocumentTool::ShapeTool(document->Main());
        TDF_LabelSequence roots;
        shapes->GetFreeShapes(roots);
        std::vector<ImportedExchangeBody> result;
        const auto labelName = [](const TDF_Label& label) {
            Handle(TDataStd_Name) attribute;
            if (!label.FindAttribute(TDataStd_Name::GetID(), attribute))
                return std::string{};
            const TCollection_ExtendedString& wide = attribute->Get();
            std::string utf8(std::size_t(wide.LengthOfCString()) + 1, '\0');
            char* buffer = utf8.data();
            wide.ToUTF8CString(buffer);
            utf8.resize(std::strlen(utf8.c_str()));
            return utf8;
        };
        const auto visit = [&](auto&& self, const TDF_Label& label,
                               const TopLoc_Location& parent,
                               const std::string& instanceName, int depth) -> bool {
            if (depth > 64 || result.size() > 10000) return false;
            if (XCAFDoc_ShapeTool::IsReference(label)) {
                TDF_Label referred;
                if (!XCAFDoc_ShapeTool::GetReferredShape(label, referred)) return false;
                std::string name = labelName(label);
                // OCCT can replace a Unicode occurrence name by the numeric
                // STEP usage id, while retaining the product's UTF-8 name.
                const bool generatedId = !name.empty() &&
                    std::all_of(name.begin(), name.end(), [](unsigned char c) {
                        return std::isdigit(c);
                    });
                if (name.empty() || name.starts_with("=>") || generatedId) {
                    const std::string productName = labelName(referred);
                    name = productName.empty() ? instanceName : productName;
                }
                return self(self, referred,
                            parent * XCAFDoc_ShapeTool::GetLocation(label), name,
                            depth + 1);
            }
            if (XCAFDoc_ShapeTool::IsAssembly(label)) {
                TDF_LabelSequence components;
                if (!XCAFDoc_ShapeTool::GetComponents(label, components)) return false;
                for (Standard_Integer i = 1; i <= components.Length(); ++i) {
                    if (!self(self, components.Value(i), parent, {}, depth + 1))
                        return false;
                }
                return true;
            }
            TopoDS_Shape shape = XCAFDoc_ShapeTool::GetShape(label);
            if (shape.IsNull()) return false;
            shape = scaledShape(shape.Moved(parent), 0.001);
            // Some STEP products group their solid with presentation or
            // wireframe geometry. Keep the exact solids as the importable
            // body, without allowing auxiliary shapes to cancel its volume.
            if (shape.ShapeType() == TopAbs_COMPOUND) {
                TopTools_IndexedMapOfShape solids;
                TopExp::MapShapes(shape, TopAbs_SOLID, solids);
                if (solids.Extent() == 1) {
                    shape = solids(1);
                } else if (solids.Extent() > 1) {
                    TopoDS_Compound solidCompound;
                    BRep_Builder builder;
                    builder.MakeCompound(solidCompound);
                    for (Standard_Integer i = 1; i <= solids.Extent(); ++i)
                        builder.Add(solidCompound, solids(i));
                    shape = solidCompound;
                }
            }
            // STEP files can expose annotation or construction wireframes as
            // separate XDE products. CADNext imports displayable BRep bodies;
            // an edge-only product cannot be meshed as a body.
            TopTools_IndexedMapOfShape faces;
            TopExp::MapShapes(shape, TopAbs_FACE, faces);
            if (faces.IsEmpty()) return true;
            if (!BRepCheck_Analyzer(shape).IsValid()) return false;
            std::string name = instanceName.empty() ? labelName(label) : instanceName;
            if (name.empty()) name = "Body " + std::to_string(result.size() + 1);
            result.push_back({name, impl_->store(shape, "occt-step-part")});
            return true;
        };
        for (Standard_Integer i = 1; i <= roots.Length(); ++i) {
            if (!visit(visit, roots.Value(i), TopLoc_Location{}, {}, 0)) {
                return cadnext::Result<std::vector<ImportedExchangeBody>>::fail(
                    {cadnext::ErrorCode::SerializationFailed,
                     "STEP assembly contains invalid or unsupported components"});
            }
        }
        if (result.empty()) return cadnext::Result<std::vector<ImportedExchangeBody>>::fail(
            {cadnext::ErrorCode::SerializationFailed, "STEP assembly contains no bodies"});
        return cadnext::Result<std::vector<ImportedExchangeBody>>::ok(std::move(result));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<std::vector<ImportedExchangeBody>>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("STEP assembly import failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<bool> OcctKernel::exportStepAssembly(
    const std::vector<NamedExchangeBody>& bodies, const std::string& path) {
    if (bodies.empty() || path.empty()) return cadnext::Result<bool>::fail(
        {cadnext::ErrorCode::InvalidArgument, "Choose bodies and a STEP path"});
    try {
        Handle(TDocStd_Document) document = new TDocStd_Document("BinXCAF");
        const Handle(XCAFDoc_ShapeTool) shapes =
            XCAFDoc_DocumentTool::ShapeTool(document->Main());
        TopoDS_Compound empty;
        BRep_Builder builder;
        builder.MakeCompound(empty);
        const TDF_Label assembly = shapes->AddShape(empty, Standard_True);
        if (assembly.IsNull() || !XCAFDoc_ShapeTool::IsAssembly(assembly)) {
            return cadnext::Result<bool>::fail(
                {cadnext::ErrorCode::SerializationFailed, "Could not create STEP assembly"});
        }
        TDataStd_Name::Set(assembly, TCollection_ExtendedString("CADNext Assembly", true));
        for (const NamedExchangeBody& item : bodies) {
            const TopoDS_Shape* source = findShape(item.body.shape);
            if (!source || source->IsNull()) return cadnext::Result<bool>::fail(
                {cadnext::ErrorCode::NotFound, "A STEP component has no BRep geometry"});
            const TopoDS_Shape placed = scaledShape(
                placedShape(*source, item.body.placement), 1000.0);
            const TDF_Label part = shapes->AddShape(placed, Standard_False);
            if (part.IsNull()) return cadnext::Result<bool>::fail(
                {cadnext::ErrorCode::SerializationFailed, "Could not add STEP component"});
            const std::string name = item.name.empty() ? "Body" : item.name;
            const TCollection_ExtendedString wideName(name.c_str(), Standard_True);
            TDataStd_Name::Set(part, wideName);
            const TDF_Label instance = shapes->AddComponent(
                assembly, part, TopLoc_Location{});
            if (instance.IsNull()) return cadnext::Result<bool>::fail(
                {cadnext::ErrorCode::SerializationFailed, "Could not link STEP component"});
            TDataStd_Name::Set(instance, wideName);
        }
        shapes->UpdateAssemblies();
        STEPCAFControl_Writer writer;
        writer.SetNameMode(Standard_True);
        if (!writer.Transfer(document, STEPControl_AsIs) ||
            writer.Write(path.c_str()) != IFSelect_RetDone) {
            return cadnext::Result<bool>::fail(
                {cadnext::ErrorCode::SerializationFailed, "STEP assembly export failed"});
        }
        return cadnext::Result<bool>::ok(true);
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<bool>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("STEP assembly export failed: ") + failure.GetMessageString()});
    }
}

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

static bool makeExactProfileWire(const std::vector<ExactProfileEdge>& edges,
                                 TopoDS_Wire& result) {
    if (edges.size() < 2) return false;
    BRepBuilderAPI_MakeWire wire;
    for (const auto& segment : edges) {
        const gp_Pnt start(segment.start.x, segment.start.y, segment.start.z);
        const gp_Pnt end(segment.end.x, segment.end.y, segment.end.z);
        if (segment.isArc) {
            const gp_Pnt middle(segment.middle.x, segment.middle.y, segment.middle.z);
            GC_MakeArcOfCircle arc(start, middle, end);
            if (!arc.IsDone()) return false;
            wire.Add(BRepBuilderAPI_MakeEdge(arc.Value()).Edge());
        } else {
            if (start.Distance(end) <= 1.0e-12) return false;
            wire.Add(BRepBuilderAPI_MakeEdge(start, end).Edge());
        }
        if (!wire.IsDone()) return false;
    }
    result = wire.Wire();
    return !result.IsNull() && BRep_Tool::IsClosed(result);
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedCurvedProfile(
    const ExtrudedCurvedProfileParameters& params) {
    const gp_Vec extrusion(params.extrusion.x, params.extrusion.y, params.extrusion.z);
    if (params.edges.size() < 2 || extrusion.Magnitude() <= 1.0e-12)
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument, "Invalid curved extrusion profile"});
    try {
        TopoDS_Wire wire;
        if (!makeExactProfileWire(params.edges, wire))
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::ShapeInvalid, "Curved profile is not a closed exact wire"});
        BRepBuilderAPI_MakeFace face(wire);
        if (!face.IsDone() || !BRepCheck_Analyzer(face.Face()).IsValid())
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::ShapeInvalid, "Curved profile does not bound a valid face"});
        BRepPrimAPI_MakePrism prism(face.Face(), extrusion);
        prism.Build();
        if (!prism.IsDone() || prism.Shape().IsNull() ||
            !BRepCheck_Analyzer(prism.Shape()).IsValid())
            return cadnext::Result<ShapeHandle>::fail({
                cadnext::ErrorCode::ShapeInvalid, "Curved extrusion produced invalid geometry"});
        return cadnext::Result<ShapeHandle>::ok(
            impl_->store(prism.Shape(), "occt-curved-extrude"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::KernelOperationFailed,
            std::string("OCCT curved extrusion failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makePlanarFaceCompound(
    const std::vector<PlanarFacePatch>& patches) {
    if (patches.empty()) return cadnext::Result<ShapeHandle>::fail(
        {cadnext::ErrorCode::InvalidArgument, "At least one planar face is required"});
    try {
        TopoDS_Compound compound;
        BRep_Builder builder;
        builder.MakeCompound(compound);
        for (const PlanarFacePatch& patch : patches) {
            if (patch.outline.size() < 3) return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::InvalidArgument, "Planar face has fewer than 3 vertices"});
            const auto& n = patch.planeNormal;
            const double length = std::hypot(n.x, n.y, n.z);
            if (!std::isfinite(length) || length < 1e-12) return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::InvalidArgument, "Planar face has no valid normal"});
            const auto& o = patch.planeOrigin;
            const gp_Pln plane(gp_Pnt(o.x, o.y, o.z), gp_Dir(n.x, n.y, n.z));
            BRepBuilderAPI_MakePolygon polygon;
            for (const cadnext::Vector3& point : patch.outline) {
                if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
                    !std::isfinite(point.z)) return cadnext::Result<ShapeHandle>::fail(
                        {cadnext::ErrorCode::InvalidArgument, "Planar face has non-finite coordinates"});
                polygon.Add(gp_Pnt(point.x, point.y, point.z));
            }
            polygon.Close();
            if (!polygon.IsDone()) return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "Could not create planar face wire"});
            BRepBuilderAPI_MakeFace maker(plane, polygon.Wire(), true);
            if (!maker.IsDone() || maker.Face().IsNull() ||
                !BRepCheck_Analyzer(maker.Face()).IsValid()) {
                return cadnext::Result<ShapeHandle>::fail(
                    {cadnext::ErrorCode::KernelOperationFailed, "Could not create exact planar face"});
            }
            builder.Add(compound, maker.Face());
        }
        return cadnext::Result<ShapeHandle>::ok(
            impl_->store(compound, "occt-planar-faces"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT planar face construction failed: ") +
                 failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makePlanarSolid(
    const std::vector<PlanarFacePatch>& patches) {
    if (patches.size() < 4) return cadnext::Result<ShapeHandle>::fail(
        {cadnext::ErrorCode::InvalidArgument, "At least four faces are required for a solid"});
    const auto faces = makePlanarFaceCompound(patches);
    if (!faces.isOk()) return faces;
    const TopoDS_Shape* compound = findShape(faces.value());
    if (!compound || compound->IsNull()) return cadnext::Result<ShapeHandle>::fail(
        {cadnext::ErrorCode::KernelOperationFailed, "Planar faces were not retained"});
    try {
        BRepBuilderAPI_Sewing sewing(1.0e-8);
        sewing.Add(*compound);
        sewing.Perform();
        const TopoDS_Shape& sewed = sewing.SewedShape();
        if (sewed.IsNull() || sewing.NbFreeEdges() != 0 ||
            sewing.NbMultipleEdges() != 0) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::ShapeInvalid, "Planar faces do not form a closed manifold"});
        }
        TopoDS_Shell shell;
        if (sewed.ShapeType() == TopAbs_SHELL) {
            shell = TopoDS::Shell(sewed);
        } else {
            TopExp_Explorer shells(sewed, TopAbs_SHELL);
            if (!shells.More()) return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::ShapeInvalid, "No closed shell was assembled"});
            shell = TopoDS::Shell(shells.Current());
            shells.Next();
            if (shells.More()) return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::ShapeInvalid, "Planar faces form multiple shells"});
        }
        std::size_t sewnFaceCount = 0;
        for (TopExp_Explorer it(sewed, TopAbs_FACE); it.More(); it.Next())
            ++sewnFaceCount;
        if (sewnFaceCount != patches.size() || !BRep_Tool::IsClosed(shell)) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::ShapeInvalid, "The sewn shell is incomplete"});
        }
        BRepBuilderAPI_MakeSolid maker(shell);
        if (!maker.IsDone() || maker.Solid().IsNull()) return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed, "Could not make a solid from the shell"});
        TopoDS_Solid solid = maker.Solid();
        if (!BRepLib::OrientClosedSolid(solid) || !BRepCheck_Analyzer(solid).IsValid()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::ShapeInvalid, "The resulting solid is invalid"});
        }
        GProp_GProps properties;
        BRepGProp::VolumeProperties(solid, properties);
        if (!std::isfinite(properties.Mass()) || properties.Mass() <= 0.0) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::ShapeInvalid, "The resulting solid has no positive volume"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(solid, "occt-planar-solid"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT planar solid construction failed: ") +
                 failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeAnalyticSolid(
    const std::vector<AnalyticFacePatch>& patches, AnalyticSolidReport* report) {
    const bool wholePeriodic = patches.size() == 1 && patches.front().loops.empty() &&
        (patches.front().kind == AnalyticFacePatch::Kind::Sphere || patches.front().kind == AnalyticFacePatch::Kind::Torus);
    if (patches.size() < 2 && !wholePeriodic) return cadnext::Result<ShapeHandle>::fail(
        {cadnext::ErrorCode::InvalidArgument, "At least two analytic faces are required"});
    if (report) *report = {};
    // Each blend is built once, whether a face lies on it or an edge crosses it.
    rolling_ball::BuildScope blendScope;
    std::map<const RollingBallBlend*, std::shared_ptr<const rolling_ball::Blend>> blends;
    std::string blendDiagnostic; // why the last blend, or an edge along one, could not be built
    const auto blendOf = [&](const std::shared_ptr<const RollingBallBlend>& definition)
        -> const rolling_ball::Blend* {
        if (!definition) return nullptr;
        auto& slot = blends[definition.get()];
        if (!slot) {
            slot = rolling_ball::buildBlend(definition);
        }
        if (slot->surface().IsNull()) {
            blendDiagnostic = "blend: " + slot->error();
            return nullptr;
        }
        return slot.get();
    };
    // How far an edge may be from the surface it bounds: 1e-7, or for a blend the bound its
    // approximation is held to; the largest gap met while trimming the last face.
    double supportTolerance = 1e-7;
    double largestSupportGap = 0.0;
    double largestBlendGap = 0.0; // over every blend face: what sewing must close
    const auto point = [](const cadnext::Vector3& p) {
        return gp_Pnt(p.x, p.y, p.z);
    };
    const auto direction = [](const cadnext::Vector3& v) {
        return gp_Dir(v.x, v.y, v.z);
    };
    std::size_t currentFace = std::numeric_limits<std::size_t>::max(); // the patch being built
    const auto fail = [&currentFace, report](const std::string& message) {
        if (report) report->failedPatch = currentFace;
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::ShapeInvalid, message});
    };
    const auto bsplineSurface = [&](const BSplineSurfaceDefinition& definition,
                                    int ordering) -> Handle(Geom_BSplineSurface) {
        const int nu = definition.uPoleCount;
        const int nv = definition.vPoleCount;
        if (nu < 2 || nv < 2 || nu > 100'000 / nv ||
            definition.poles.size() != std::size_t(nu * nv) ||
            definition.weights.size() != std::size_t(nu * nv) ||
            definition.uKnots.size() != definition.uMultiplicities.size() ||
            definition.vKnots.size() != definition.vMultiplicities.size() ||
            definition.uKnots.size() < 2 || definition.vKnots.size() < 2)
            return {};
        TColStd_Array1OfReal uKnots(1, int(definition.uKnots.size()));
        TColStd_Array1OfReal vKnots(1, int(definition.vKnots.size()));
        TColStd_Array1OfInteger uMult(1, int(definition.uMultiplicities.size()));
        TColStd_Array1OfInteger vMult(1, int(definition.vMultiplicities.size()));
        for (int i = 0; i < uKnots.Length(); ++i) {
            uKnots.SetValue(i + 1, definition.uKnots[i]);
            uMult.SetValue(i + 1, definition.uMultiplicities[i]);
        }
        for (int i = 0; i < vKnots.Length(); ++i) {
            vKnots.SetValue(i + 1, definition.vKnots[i]);
            vMult.SetValue(i + 1, definition.vMultiplicities[i]);
        }
        TColgp_Array2OfPnt poles(1, nu, 1, nv);
        TColStd_Array2OfReal weights(1, nu, 1, nv);
        for (int u = 0; u < nu; ++u) {
            for (int v = 0; v < nv; ++v) {
                const int i = ordering == 0 ? u * nv + v : v * nu + u;
                poles.SetValue(u + 1, v + 1, point(definition.poles[i]));
                weights.SetValue(u + 1, v + 1, definition.weights[i]);
            }
        }
        const Handle(Geom_BSplineSurface) surface = new Geom_BSplineSurface(poles, weights, uKnots, vKnots,
            uMult, vMult, definition.uDegree, definition.vDegree,
            definition.uPeriodic, definition.vPeriodic);
        // SAT and XT also store a closed spline unwrapped with clamped end knots. OCCT's
        // seam builder needs its periodic form; SetPeriodic preserves the surface geometry.
        if (!surface->IsUPeriodic() && surface->IsUClosed()) surface->SetUPeriodic();
        if (!surface->IsVPeriodic() && surface->IsVClosed()) surface->SetVPeriodic();
        return surface;
    };
    // A curve given as an edge segment (a swept surface's section, an edge support) as OCCT geometry.
    const auto curveOf = [&](const AnalyticEdgeSegment& s) -> Handle(Geom_Curve) {
        try {
            switch (s.kind) {
            case AnalyticEdgeKind::Line: return new Geom_Line(point(s.center), direction(s.normal));
            case AnalyticEdgeKind::Circle:
                return new Geom_Circle(gp_Ax2(point(s.center), direction(s.normal), direction(s.xAxis)), s.radius);
            case AnalyticEdgeKind::Ellipse:
                return new Geom_Ellipse(gp_Ax2(point(s.center), direction(s.normal), direction(s.xAxis)), s.majorRadius,
                                        s.minorRadius);
            case AnalyticEdgeKind::BSpline: {
                const auto& d = s.bspline;
                TColgp_Array1OfPnt poles(1, int(d.poles.size()));
                TColStd_Array1OfReal weights(1, int(d.poles.size())), knots(1, int(d.knots.size()));
                TColStd_Array1OfInteger multiplicities(1, int(d.knots.size()));
                for (int i = 0; i < int(d.poles.size()); ++i) {
                    poles.SetValue(i + 1, point(d.poles[std::size_t(i)]));
                    weights.SetValue(i + 1, d.weights[std::size_t(i)]);
                }
                for (int i = 0; i < int(d.knots.size()); ++i) {
                    knots.SetValue(i + 1, d.knots[std::size_t(i)]);
                    multiplicities.SetValue(i + 1, d.multiplicities[std::size_t(i)]);
                }
                return new Geom_BSplineCurve(poles, weights, knots, multiplicities, d.degree, d.periodic);
            }
            default: return {};
            }
        } catch (const Standard_Failure&) {
            return {};
        }
    };
    // The surface an XT curve lies on, parametrised as XT parametrises it (plane, cylinder, sphere,
    // torus, B-spline and swept surface agree with OCCT; XT's cone is not known to, and is refused).
    const auto parametrisedSurface = [&](const AnalyticSurfaceSupport& support) -> Handle(Geom_Surface) {
        try {
            switch (support.kind) {
            case AnalyticSurfaceSupport::Kind::Plane:
                return new Geom_Plane(gp_Ax3(point(support.origin), direction(support.normal), direction(support.xAxis)));
            case AnalyticSurfaceSupport::Kind::Cylinder:
                return new Geom_CylindricalSurface(
                    gp_Ax3(point(support.origin), direction(support.normal), direction(support.xAxis)), support.radius);
            case AnalyticSurfaceSupport::Kind::Cone:
                // OCCT's own: v the distance along a generator from the circle of `radius` (KOMPAS C3D curves
                // are mapped to it by their reader; XT's cone parametrisation is not established there).
                return new Geom_ConicalSurface(gp_Ax3(point(support.origin), direction(support.normal), direction(support.xAxis)),
                                               support.semiAngle, support.radius);
            case AnalyticSurfaceSupport::Kind::Sphere:
                return new Geom_SphericalSurface(
                    gp_Ax3(point(support.origin), direction(support.normal), direction(support.xAxis)), support.radius);
            case AnalyticSurfaceSupport::Kind::Torus:
                return new Geom_ToroidalSurface(gp_Ax3(point(support.origin), direction(support.normal), direction(support.xAxis)),
                                                support.majorRadius, support.minorRadius);
            case AnalyticSurfaceSupport::Kind::BSpline: return bsplineSurface(support.bspline, 0);
            case AnalyticSurfaceSupport::Kind::BSplineOffset: {
                const Handle(Geom_BSplineSurface) basis = bsplineSurface(support.bspline, 0);
                return basis.IsNull() ? Handle(Geom_Surface)() : new Geom_OffsetSurface(basis, support.offsetDistance);
            }
            case AnalyticSurfaceSupport::Kind::Swept: {
                const Handle(Geom_Curve) section = support.edge ? curveOf(*support.edge) : Handle(Geom_Curve)();
                return section.IsNull() ? Handle(Geom_Surface)()
                                        : new Geom_SurfaceOfLinearExtrusion(section, direction(support.normal));
            }
            default: return {};
            }
        } catch (const Standard_Failure&) {
            return {};
        }
    };
    // Tolerant edges: each face holds its own curve for one, within twice the edge's tolerance of the
    // other face's (each within the tolerance of the edge) — what sewing must close.
    double largestEdgeTolerance = 0.0;
    for (const auto& patch : patches)
        for (const auto& loop : patch.loops)
            for (const auto& segment : loop)
                if (std::isfinite(segment.tolerance)) largestEdgeTolerance = std::max(largestEdgeTolerance, segment.tolerance);
    const auto boundaryTolerance = [](const AnalyticEdgeSegment& segment) {
        // A shared 3D representative chosen from one FIN can be twice the declared
        // EDGE tolerance from the other FIN (each FIN is within that tolerance of EDGE).
        return segment.kind == AnalyticEdgeKind::SurfaceCurve && segment.sourceId
            ? 2.0 * segment.tolerance : segment.tolerance;
    };
    // A valid sewn shell can still contain the wrong half of a periodic
    // cylinder, cone, sphere, or torus. Compare every generated 3D edge with
    // the exact XT edge that delimits its face before accepting the shell.
    const auto uncachedSourceEdge = [&](const AnalyticEdgeSegment& segment) -> TopoDS_Edge {
        if (segment.kind == AnalyticEdgeKind::SurfaceCurve) {
            // A curve in its surface's parameters: the edge on that surface, its 3D curve built from
            // it, its ends at the source's vertices within the edge's tolerance.
            const Handle(Geom_Surface) surface = parametrisedSurface(segment.intersectionSurfaces[0]);
            if (surface.IsNull()) {
                blendDiagnostic = "surface curve: no parametrised surface for it";
                return {};
            }
            try {
                const auto& d = segment.bspline;
                TColgp_Array1OfPnt2d poles(1, int(d.poles.size()));
                TColStd_Array1OfReal weights(1, int(d.poles.size())), knots(1, int(d.knots.size()));
                TColStd_Array1OfInteger multiplicities(1, int(d.knots.size()));
                for (int i = 0; i < int(d.poles.size()); ++i) {
                    poles.SetValue(i + 1, gp_Pnt2d(d.poles[std::size_t(i)].x, d.poles[std::size_t(i)].y));
                    weights.SetValue(i + 1, d.weights[std::size_t(i)]);
                }
                for (int i = 0; i < int(d.knots.size()); ++i) {
                    knots.SetValue(i + 1, d.knots[std::size_t(i)]);
                    multiplicities.SetValue(i + 1, d.multiplicities[std::size_t(i)]);
                }
                const Handle(Geom2d_BSplineCurve) curve =
                    new Geom2d_BSplineCurve(poles, weights, knots, multiplicities, d.degree, d.periodic);
                double first = std::min(segment.curveFirst, segment.curveLast);
                double last = std::max(segment.curveFirst, segment.curveLast);
                if (!(last > first)) {
                    first = curve->FirstParameter();
                    last = curve->LastParameter();
                }
                const bool full = !segment.hasEndpoints || point(segment.start).Distance(point(segment.end)) < 1e-10;
                double tolerance = std::max(1e-7, boundaryTolerance(segment));
                BRep_Builder builder;
                TopoDS_Edge edge;
                if (!full) {
                    // Ends at the source's vertices (so that the exact edges next to it meet it at the
                    // same points), their tolerance covering the curve's ends; along the traversal.
                    const gp_Pnt a = surface->Value(curve->Value(first).X(), curve->Value(first).Y());
                    const gp_Pnt b = surface->Value(curve->Value(last).X(), curve->Value(last).Y());
                    const bool along = a.Distance(point(segment.start)) + b.Distance(point(segment.end)) <=
                                       a.Distance(point(segment.end)) + b.Distance(point(segment.start));
                    const gp_Pnt atFirst = point(along ? segment.start : segment.end);
                    const gp_Pnt atLast = point(along ? segment.end : segment.start);
                    const double gap = std::max(a.Distance(atFirst), b.Distance(atLast));
                    if (gap > std::max(1e-6, 2.0 * segment.tolerance)) {
                        blendDiagnostic = "surface curve ends " + std::to_string(gap) + " m from its vertices";
                        return {};
                    }
                    tolerance = std::max(tolerance, gap + 1e-9);
                    TopoDS_Vertex v1, v2;
                    builder.MakeVertex(v1, atFirst, tolerance);
                    builder.MakeVertex(v2, atLast, tolerance);
                    BRepBuilderAPI_MakeEdge maker(curve, surface, v1, v2, first, last);
                    if (!maker.IsDone()) {
                        blendDiagnostic = "surface curve: no edge between its vertices";
                        return {};
                    }
                    edge = maker.Edge();
                    if (!along) edge.Reverse();
                } else {
                    BRepBuilderAPI_MakeEdge maker(curve, surface, first, last);
                    if (!maker.IsDone()) {
                        blendDiagnostic = "surface curve: no edge";
                        return {};
                    }
                    edge = maker.Edge();
                    if (!segment.forward) edge.Reverse();
                }
                if (!BRepLib::BuildCurve3d(edge, 1e-9)) {
                    blendDiagnostic = "surface curve: no 3D curve";
                    return {};
                }
                builder.UpdateEdge(edge, tolerance);
                return edge;
            } catch (const Standard_Failure& failure) {
                blendDiagnostic = std::string("surface curve: ") + failure.GetMessageString();
                return {};
            }
        }
        if (segment.kind == AnalyticEdgeKind::BlendBoundary) {
            const rolling_ball::Blend* blend = blendOf(segment.blend);
            if (!blend) return {};
            TopoDS_Edge edge = blend->boundaryEdge(segment.blendBoundary, segment);
            if (edge.IsNull()) blendDiagnostic = "contact edge: " + blend->edgeError();
            return edge;
        }
        if (segment.kind == AnalyticEdgeKind::Line) {
            BRepBuilderAPI_MakeEdge maker(point(segment.start), point(segment.end));
            return maker.IsDone() ? maker.Edge() : TopoDS_Edge{};
        }
        if (segment.kind == AnalyticEdgeKind::SurfaceIntersection) {
            // Across a blend: from the edge's chart, onto the blend's definition (an intersection
            // with the approximating surface came back in pieces that miss the vertices).
            for (int side = 0; side < 2; ++side) {
                if (segment.intersectionSurfaces[side].kind != AnalyticSurfaceSupport::Kind::Blend) continue;
                const rolling_ball::Blend* blend = blendOf(segment.intersectionSurfaces[side].blend);
                if (!blend) return {};
                TopoDS_Edge edge = blend->crossingEdge(segment, side);
                if (edge.IsNull()) blendDiagnostic = "edge across a blend: " + blend->edgeError();
                return edge;
            }
            const auto sameLocus = [](const TopoDS_Edge& left,
                                      const TopoDS_Edge& right) {
                const BRepAdaptor_Curve a(left);
                const BRepAdaptor_Curve b(right);
                GProp_GProps aLength, bLength;
                BRepGProp::LinearProperties(left, aLength);
                BRepGProp::LinearProperties(right, bLength);
                if (std::fabs(aLength.Mass() - bLength.Mass()) > 1e-7) return false;
                bool direct = true, reverse = true;
                for (double fraction : {0.25, 0.5, 0.75}) {
                    const gp_Pnt pa = a.Value(a.FirstParameter() +
                        (a.LastParameter()-a.FirstParameter()) * fraction);
                    direct &= pa.Distance(b.Value(b.FirstParameter() +
                        (b.LastParameter()-b.FirstParameter()) * fraction)) < 1e-7;
                    reverse &= pa.Distance(b.Value(b.FirstParameter() +
                        (b.LastParameter()-b.FirstParameter()) * (1.0-fraction))) < 1e-7;
                }
                return direct || reverse;
            };
            const auto attempt = [&](int ordering) -> TopoDS_Edge {
            const auto& a = segment.intersectionSurfaces[0];
            const auto& b = segment.intersectionSurfaces[1];
            const auto supportSurface = [&](const AnalyticSurfaceSupport& support)
                -> Handle(Geom_Surface) {
                if (support.kind == AnalyticSurfaceSupport::Kind::Blend) {
                    const rolling_ball::Blend* blend = blendOf(support.blend);
                    return blend ? Handle(Geom_Surface)(blend->surface()) : Handle(Geom_Surface)();
                }
                if (support.kind == AnalyticSurfaceSupport::Kind::BSpline)
                    return bsplineSurface(support.bspline, ordering);
                if (support.kind == AnalyticSurfaceSupport::Kind::Swept)
                    return parametrisedSurface(support);
                if (support.kind == AnalyticSurfaceSupport::Kind::BSplineOffset) {
                    if (!std::isfinite(support.offsetDistance) ||
                        std::fabs(support.offsetDistance) < 1e-12) return {};
                    const Handle(Geom_BSplineSurface) basis =
                        bsplineSurface(support.bspline, ordering);
                    if (basis.IsNull()) return {};
                    try {
                        return new Geom_OffsetSurface(basis, support.offsetDistance);
                    } catch (const Standard_Failure& failure) {
                        blendDiagnostic = std::string("offset support: ") + failure.GetMessageString();
                        return {};
                    }
                }
                const gp_Ax3 frame(point(support.origin), direction(support.normal),
                                   direction(support.xAxis));
                switch (support.kind) {
                case AnalyticSurfaceSupport::Kind::Plane:
                    return new Geom_Plane(frame);
                case AnalyticSurfaceSupport::Kind::Cylinder:
                    if (isPositiveFinite(support.radius))
                        return new Geom_CylindricalSurface(frame, support.radius);
                    break;
                case AnalyticSurfaceSupport::Kind::Cone:
                    if (isPositiveFinite(support.radius) &&
                        std::isfinite(support.semiAngle) &&
                        std::fabs(support.semiAngle) > 1e-10 &&
                        std::fabs(support.semiAngle) < 1.5707963267948966 - 1e-10)
                        return new Geom_ConicalSurface(frame, support.semiAngle,
                                                       support.radius);
                    break;
                case AnalyticSurfaceSupport::Kind::Sphere:
                    if (isPositiveFinite(support.radius))
                        return new Geom_SphericalSurface(frame, support.radius);
                    break;
                case AnalyticSurfaceSupport::Kind::Torus:
                    if (isPositiveFinite(support.majorRadius) &&
                        isPositiveFinite(support.minorRadius) &&
                        support.majorRadius > support.minorRadius)
                        return new Geom_ToroidalSurface(frame, support.majorRadius,
                                                        support.minorRadius);
                    break;
                case AnalyticSurfaceSupport::Kind::BSplineOffset:
                case AnalyticSurfaceSupport::Kind::BSpline:
                case AnalyticSurfaceSupport::Kind::Blend:
                case AnalyticSurfaceSupport::Kind::Edge: // not a surface: only a blend's support
                case AnalyticSurfaceSupport::Kind::Swept:
                    break;
                }
                return {};
            };
            const Handle(Geom_Surface) first = supportSurface(a);
            const Handle(Geom_Surface) second = supportSurface(b);
            if (first.IsNull() || second.IsNull()) return {};
            const GeomAPI_IntSS intersection(first, second, 1e-8);
            if (!intersection.IsDone()) return {};
            // An edge across a blend is as near its vertices, and its vertices as near the
            // blend, as the blend's surface is to its definition.
            const auto blendTolerance = [&](const AnalyticSurfaceSupport& support) {
                const rolling_ball::Blend* blend =
                    support.kind == AnalyticSurfaceSupport::Kind::Blend ? blendOf(support.blend) : nullptr;
                return blend ? blend->tolerance() : 0.0;
            };
            const double reach = 1e-7 + blendTolerance(a) + blendTolerance(b) +
                                 (std::isfinite(segment.tolerance) ? segment.tolerance : 0.0);
            const auto residual = [&](const gp_Pnt& sample,
                                      const AnalyticSurfaceSupport& support,
                                      const Handle(Geom_Surface)& geometry) {
                if (support.kind == AnalyticSurfaceSupport::Kind::BSplineOffset ||
                    support.kind == AnalyticSurfaceSupport::Kind::BSpline ||
                    support.kind == AnalyticSurfaceSupport::Kind::Blend ||
                    support.kind == AnalyticSurfaceSupport::Kind::Swept) {
                    const GeomAPI_ProjectPointOnSurf projection(sample, geometry);
                    return projection.NbPoints() > 0 ? projection.LowerDistance() :
                        std::numeric_limits<double>::infinity();
                }
                const gp_Vec offset(point(support.origin), sample);
                const gp_Vec axis(direction(support.normal));
                const double axial = offset.Dot(axis);
                const gp_Vec radial = offset - axis * axial;
                const double radialDistance = radial.Magnitude();
                switch (support.kind) {
                case AnalyticSurfaceSupport::Kind::Plane:
                    return std::fabs(axial);
                case AnalyticSurfaceSupport::Kind::Cylinder:
                    return std::fabs(radialDistance - support.radius);
                case AnalyticSurfaceSupport::Kind::Cone:
                    return std::fabs(radialDistance - support.radius -
                                     axial * std::tan(support.semiAngle));
                case AnalyticSurfaceSupport::Kind::Sphere:
                    return std::fabs(offset.Magnitude() - support.radius);
                case AnalyticSurfaceSupport::Kind::Torus:
                    return std::fabs(std::hypot(radialDistance - support.majorRadius,
                                                axial) - support.minorRadius);
                case AnalyticSurfaceSupport::Kind::BSplineOffset:
                case AnalyticSurfaceSupport::Kind::BSpline:
                case AnalyticSurfaceSupport::Kind::Blend:
                case AnalyticSurfaceSupport::Kind::Edge:
                case AnalyticSurfaceSupport::Kind::Swept:
                    break;
                }
                return std::numeric_limits<double>::infinity();
            };
            if (!segment.hasEndpoints) {
                int branch = intersection.NbLines() == 1 ? 1 : 0;
                for (int i = 1; i <= intersection.NbLines() && segment.hasBranchPoint &&
                                intersection.NbLines() > 1; ++i) {
                    const GeomAPI_ProjectPointOnCurve on(point(segment.branchPoint), intersection.Line(i));
                    if (on.NbPoints() == 0 || on.LowerDistance() > reach) continue;
                    if (branch != 0) return {}; // the point does not tell the branches apart
                    branch = i;
                }
                if (branch == 0) return {};
                const Handle(Geom_Curve)& curve = intersection.Line(branch);
                const double firstParameter = curve->FirstParameter();
                const double lastParameter = curve->LastParameter();
                if (!std::isfinite(firstParameter) || !std::isfinite(lastParameter) ||
                    lastParameter <= firstParameter) return {};
                // A ring is closed: a branch OCCT returns in pieces (open) is left to the chart.
                if (curve->Value(firstParameter).Distance(curve->Value(lastParameter)) > reach) return {};
                for (int sample = 0; sample <= 16; ++sample) {
                    const gp_Pnt location = curve->Value(firstParameter +
                        (lastParameter-firstParameter) * (double(sample) / 16.0));
                    if (residual(location, a, first) > 1e-7 ||
                        residual(location, b, second) > 1e-7) return {};
                }
                BRepBuilderAPI_MakeEdge maker(curve);
                if (!maker.IsDone()) return {};
                TopoDS_Edge edge = maker.Edge();
                if (!segment.forward) edge.Reverse();
                return edge;
            }
            TopoDS_Edge chosen;
            double nearestEnds = std::numeric_limits<double>::infinity();
            for (int i = 1; i <= intersection.NbLines(); ++i) {
                const Handle(Geom_Curve)& curve = intersection.Line(i);
                const GeomAPI_ProjectPointOnCurve start(point(segment.start), curve);
                const GeomAPI_ProjectPointOnCurve end(point(segment.end), curve);
                if (start.NbPoints() && end.NbPoints())
                    nearestEnds = std::min(nearestEnds, std::max(start.LowerDistance(), end.LowerDistance()));
                if (start.NbPoints() == 0 || end.NbPoints() == 0 ||
                    start.LowerDistance() > reach || end.LowerDistance() > reach)
                    continue;
                const double from = start.LowerDistanceParameter();
                const double to = end.LowerDistanceParameter();
                if (std::fabs(from-to) < 1e-10) continue;
                // A closed branch holds two arcs between the ends: the edge is the one through its branch
                // point where that lies inside it (ACIS: the middle of the file's own curve), the other
                // way round the branch's parameter seam if not. An XT chart starts at the edge's end,
                // which both arcs hold.
                Handle(Geom_Curve) along = curve;
                double low = std::min(from, to), high = std::max(from, to);
                bool reversed = from > to;
                if (segment.hasBranchPoint) {
                    const GeomAPI_ProjectPointOnCurve middle(point(segment.branchPoint), curve);
                    const bool projected = middle.NbPoints() && middle.LowerDistance() <= reach;
                    double t = projected ? middle.LowerDistanceParameter() : low;
                    // Not within reach of the branch (a tolerant source's curve, KOMPAS C3D): of the closed
                    // branch's two arcs between the ends, the one whose middle is nearer the branch point —
                    // instead of the one between the parameters, whichever that is.
                    if (!projected && curve->IsClosed()) {
                        const double period = curve->LastParameter() - curve->FirstParameter();
                        const gp_Pnt direct = curve->Value(0.5 * (low + high));
                        double round = 0.5 * (high + low + period);
                        if (round > curve->LastParameter()) round -= period;
                        const gp_Pnt other = curve->Value(round);
                        if (other.Distance(point(segment.branchPoint)) < direct.Distance(point(segment.branchPoint))) t = high + 1.0;
                    }
                    if ((t < low - 1e-9 || t > high + 1e-9) && curve->IsClosed()) {
                        if (!curve->IsPeriodic()) {
                            // A closed B-spline branch made periodic, to be read across its seam.
                            Handle(Geom_BSplineCurve) periodic = Handle(Geom_BSplineCurve)::DownCast(curve->Copy());
                            if (periodic.IsNull()) continue;
                            try {
                                periodic->SetPeriodic();
                            } catch (const Standard_Failure&) {
                                continue;
                            }
                            along = periodic;
                        }
                        const double period = along->Period();
                        // From `from` the long way round to `to`.
                        if (from > to) {
                            low = from;
                            high = to + period;
                            reversed = false;
                        } else {
                            low = to;
                            high = from + period;
                            reversed = true;
                        }
                    }
                }
                bool onBothSurfaces = true;
                for (int sample = 0; sample <= 8; ++sample) {
                    const gp_Pnt location = along->Value(
                        low + (high-low) * (double(sample) / 8.0));
                    onBothSurfaces = onBothSurfaces &&
                        residual(location, a, first) < 1e-7 &&
                        residual(location, b, second) < 1e-7;
                }
                if (!onBothSurfaces) continue;
                BRepBuilderAPI_MakeEdge maker(along, low, high);
                if (!maker.IsDone()) continue;
                TopoDS_Edge edge = maker.Edge();
                if (reversed) edge.Reverse();
                if (!chosen.IsNull() && !sameLocus(chosen, edge)) return {};
                chosen = edge;
            }
            if (chosen.IsNull())
                blendDiagnostic = "intersection: " + std::to_string(intersection.NbLines()) +
                    " branches, the nearest passes its ends at " + std::to_string(nearestEnds) + " m";
            return chosen;
            };
            // Transposing the control grid reverses the surface normal. For an
            // offset surface that also reverses the signed offset and may make
            // an incorrect XT offset appear to meet the edge endpoints. Use
            // one deterministic grid layout here; reject an unsupported
            // layout rather than silently constructing the opposite offset.
            TopoDS_Edge edge = attempt(0);
            // Where OCCT's intersection does not follow the surfaces through the edge's vertices
            // (threads: helical B-spline surfaces): from the edge's chart, each point exact.
            if (edge.IsNull() && segment.chart.size() >= 2) {
                std::string why;
                edge = rolling_ball::intersectionEdge(segment, why);
                if (edge.IsNull())
                    blendDiagnostic = (blendDiagnostic.empty() ? std::string("intersection") : blendDiagnostic) +
                                      "; from its chart: " + why;
            }
            return edge;
        }
        if (segment.kind == AnalyticEdgeKind::BSpline) {
            const auto& definition = segment.bspline;
            const int count = int(definition.poles.size());
            const int knotCount = int(definition.knots.size());
            if (count < 2 || count != int(definition.weights.size()) ||
                knotCount < 2 || knotCount != int(definition.multiplicities.size()) ||
                definition.degree < 1 || definition.degree >= count)
                return {};
            TColgp_Array1OfPnt poles(1, count);
            TColStd_Array1OfReal weights(1, count);
            TColStd_Array1OfReal knots(1, knotCount);
            TColStd_Array1OfInteger multiplicities(1, knotCount);
            for (int i = 0; i < count; ++i) {
                poles.SetValue(i + 1, point(definition.poles[i]));
                weights.SetValue(i + 1, definition.weights[i]);
            }
            for (int i = 0; i < knotCount; ++i) {
                knots.SetValue(i + 1, definition.knots[i]);
                multiplicities.SetValue(i + 1, definition.multiplicities[i]);
            }
            const Handle(Geom_BSplineCurve) curve = new Geom_BSplineCurve(
                poles, weights, knots, multiplicities, definition.degree,
                definition.periodic);
            if (!segment.hasEndpoints ||
                point(segment.start).Distance(point(segment.end)) < 1e-10) {
                BRepBuilderAPI_MakeEdge maker(curve);
                if (!maker.IsDone()) return {};
                TopoDS_Edge edge = maker.Edge();
                if (!segment.forward) edge.Reverse();
                return edge;
            }
            if (std::isfinite(segment.curveFirst) && std::isfinite(segment.curveLast) &&
                segment.curveLast > segment.curveFirst) {
                const double first = segment.curveFirst, last = segment.curveLast;
                const double near = std::max(1e-7, std::isfinite(segment.tolerance) ? segment.tolerance : 0.0);
                const gp_Pnt a = curve->Value(segment.forward ? first : last);
                const gp_Pnt b = curve->Value(segment.forward ? last : first);
                if (a.Distance(point(segment.start)) > near || b.Distance(point(segment.end)) > near) return {};
                BRepBuilderAPI_MakeEdge maker(curve, first, last);
                if (!maker.IsDone()) return {};
                TopoDS_Edge edge = maker.Edge();
                if (!segment.forward) edge.Reverse();
                return edge;
            }
            const GeomAPI_ProjectPointOnCurve start(point(segment.start), curve);
            const GeomAPI_ProjectPointOnCurve end(point(segment.end), curve);
            // A tolerant vertex is reached only within its tolerance.
            const double near = std::max(1e-7, std::isfinite(segment.tolerance) ? segment.tolerance : 0.0);
            if (start.NbPoints() == 0 || end.NbPoints() == 0 ||
                start.LowerDistance() > near || end.LowerDistance() > near)
                return {};
            const double from = start.LowerDistanceParameter();
            const double to = end.LowerDistanceParameter();
            if (std::fabs(from - to) < 1e-10) return {};
            if (curve->IsPeriodic()) {
                // As an arc of a circle: along the curve from the start when the edge runs with it,
                // against it otherwise — across the period's end if need be, not simply between the
                // two parameters (a thread's end loop: 0.196 m taken for its 0.0126 m).
                const double period = curve->Period();
                double first = segment.forward ? from : to, last = segment.forward ? to : from;
                while (last <= first) last += period;
                BRepBuilderAPI_MakeEdge maker(curve, first, last);
                if (!maker.IsDone()) return {};
                TopoDS_Edge edge = maker.Edge();
                if (!segment.forward) edge.Reverse();
                return edge;
            }
            BRepBuilderAPI_MakeEdge maker(curve, std::min(from, to),
                                          std::max(from, to));
            if (!maker.IsDone()) return {};
            TopoDS_Edge edge = maker.Edge();
            if (from > to) edge.Reverse();
            return edge;
        }
        const bool full = !segment.hasEndpoints ||
            point(segment.start).Distance(point(segment.end)) < 1e-10;
        const gp_Ax2 frame(point(segment.center), direction(segment.normal),
                           direction(segment.xAxis));
        const auto angle = [&](const gp_Vec& offset, double xRadius,
                               double yRadius) {
            return std::atan2(offset.Dot(gp_Vec(frame.YDirection())) / yRadius,
                              offset.Dot(gp_Vec(frame.XDirection())) / xRadius);
        };
        const gp_Vec start(point(segment.center), point(segment.start));
        const gp_Vec end(point(segment.center), point(segment.end));
        const double major = segment.kind == AnalyticEdgeKind::Circle
            ? segment.radius : segment.majorRadius;
        const double minor = segment.kind == AnalyticEdgeKind::Circle
            ? segment.radius : segment.minorRadius;
        double first = full ? 0.0 : angle(start, major, minor);
        double last = full ? 2.0 * 3.14159265358979323846 : angle(end, major, minor);
        if (!full) {
            if (segment.forward) {
                while (last <= first) last += 2.0 * 3.14159265358979323846;
            } else {
                while (last >= first) last -= 2.0 * 3.14159265358979323846;
                std::swap(first, last);
            }
        }
        if (std::isfinite(segment.curveFirst) && std::isfinite(segment.curveLast) && segment.curveLast > segment.curveFirst) {
            first = segment.curveFirst;
            last = segment.curveLast;
        }
        if (segment.kind == AnalyticEdgeKind::Circle) {
            const gp_Circ circle(frame, segment.radius);
            BRepBuilderAPI_MakeEdge maker(circle, first, last);
            if (!maker.IsDone()) return {};
            TopoDS_Edge edge = maker.Edge();
            if (!segment.forward) edge.Reverse();
            return edge;
        }
        const gp_Elips ellipse(frame, segment.majorRadius, segment.minorRadius);
        BRepBuilderAPI_MakeEdge maker(ellipse, first, last);
        if (!maker.IsDone()) return {};
        TopoDS_Edge edge = maker.Edge();
        if (!segment.forward) edge.Reverse();
        return edge;
    };
    struct SourceEdge {TopoDS_Edge edge;bool forward;};
    std::unordered_map<std::uint64_t,SourceEdge> sourceEdges;
    std::unordered_map<std::uint64_t,double> sourceTolerances;
    for (const auto& patch:patches) for (const auto& loop:patch.loops) for (const auto& segment:loop)
        if (segment.sourceId && std::isfinite(segment.tolerance))
            sourceTolerances[segment.sourceId]=std::max(sourceTolerances[segment.sourceId],segment.tolerance);
    const auto sourceEdge=[&](const AnalyticEdgeSegment& segment)->TopoDS_Edge {
        if (!segment.sourceId) return uncachedSourceEdge(segment);
        if (const auto found=sourceEdges.find(segment.sourceId);found!=sourceEdges.end()) {
            TopoDS_Edge edge=found->second.edge;
            if (found->second.forward!=segment.forward) edge.Reverse();
            return edge;
        }
        auto definition=segment;definition.tolerance=sourceTolerances[segment.sourceId];
        TopoDS_Edge edge=uncachedSourceEdge(definition);
        if (!edge.IsNull()) sourceEdges.emplace(segment.sourceId,SourceEdge{edge,segment.forward});
        return edge;
    };
    const auto sourceBoundary = [&](const AnalyticEdgeSegment& segment) -> TopoDS_Edge {
        const TopoDS_Edge edge = sourceEdge(segment);
        // Healing one face must not alter the source used to verify another face sharing
        // this edge. Copy topology and geometry; some healing operations edit a curve in place.
        return edge.IsNull() ? edge : TopoDS::Edge(BRepBuilderAPI_Copy(edge, true, false).Shape());
    };
    // Whether `actual` (a face's edges, or a set of faces' outer ones) is the source's boundary: each
    // source edge found once, whole or in pieces, and every edge left over `spare` (a seam).
    const auto edgesMatch = [&](const std::vector<TopoDS_Edge>& actual,
                                const std::function<bool(const TopoDS_Edge&)>& spare,
                                const AnalyticFacePatch& patch,
                                std::string& detail) {
        std::vector<bool> used(actual.size(), false);
        std::size_t expectedCount = 0;
        for (const auto& loop : patch.loops) {
            for (const auto& segment : loop) {
                ++expectedCount;
                const TopoDS_Edge expected = sourceEdge(segment);
                if (expected.IsNull()) {
                    detail = "source edge cannot be constructed";
                    return false;
                }
                const BRepAdaptor_Curve wanted(expected);
                GProp_GProps wantedProperties;
                BRepGProp::LinearProperties(expected, wantedProperties);
                const double wantedLength = wantedProperties.Mass();
                const bool full = !segment.hasEndpoints ||
                    point(segment.start).Distance(point(segment.end)) < 1e-10;
                bool found = false;
                for (std::size_t i = 0; i < actual.size(); ++i) {
                    if (used[i]) continue;
                    const BRepAdaptor_Curve got(actual[i]);
                    if (got.GetType() != wanted.GetType()) continue;
                    GProp_GProps gotProperties;
                    BRepGProp::LinearProperties(actual[i], gotProperties);
                    if (std::fabs(gotProperties.Mass() - wantedLength) >
                        std::max(2e-7, wantedLength * 1e-6)) continue;
                    if (segment.kind == AnalyticEdgeKind::Circle) {
                        if (got.Circle().Location().Distance(wanted.Circle().Location()) > 2e-7 ||
                            std::fabs(got.Circle().Radius() - segment.radius) > 2e-7 ||
                            !got.Circle().Axis().Direction().IsParallel(
                                wanted.Circle().Axis().Direction(), 1e-6)) continue;
                    } else if (segment.kind == AnalyticEdgeKind::Ellipse) {
                        if (got.Ellipse().Location().Distance(wanted.Ellipse().Location()) > 2e-7 ||
                            std::fabs(got.Ellipse().MajorRadius() - segment.majorRadius) > 2e-7 ||
                            std::fabs(got.Ellipse().MinorRadius() - segment.minorRadius) > 2e-7 ||
                            !got.Ellipse().Axis().Direction().IsParallel(
                                wanted.Ellipse().Axis().Direction(), 1e-6)) continue;
                    }
                    if (!full) {
                        const gp_Pnt a = wanted.Value(wanted.FirstParameter());
                        const gp_Pnt b = wanted.Value(wanted.LastParameter());
                        const gp_Pnt c = got.Value(got.FirstParameter());
                        const gp_Pnt d = got.Value(got.LastParameter());
                        if (!((a.Distance(c) < 2e-7 && b.Distance(d) < 2e-7) ||
                              (a.Distance(d) < 2e-7 && b.Distance(c) < 2e-7))) continue;
                        if (wanted.Value((wanted.FirstParameter()+wanted.LastParameter())/2.0)
                                .Distance(got.Value((got.FirstParameter()+got.LastParameter())/2.0)) >
                            2e-7) continue;
                    }
                    used[i] = true;
                    found = true;
                    break;
                }
                if (!found && segment.kind == AnalyticEdgeKind::Circle) {
                    // OCCT may split one exact circular XT edge at the
                    // periodic seam of a trimmed surface. Match the chain of
                    // pieces on the same circle instead of requiring one edge
                    // (a full circle too: split where the seam crosses it).
                    const gp_Circ circle = wanted.Circle();
                    const gp_Pnt sourceStart = wanted.Value(wanted.FirstParameter());
                    const gp_Pnt sourceEnd = wanted.Value(wanted.LastParameter());
                    const double lengthTolerance = std::max(2e-7, wantedLength * 1e-6);
                    const auto onWantedArc = [&](const gp_Pnt& sample) {
                        const gp_Vec radial(circle.Location(), sample);
                        double angle = std::atan2(
                            radial.Dot(gp_Vec(circle.Position().YDirection())),
                            radial.Dot(gp_Vec(circle.Position().XDirection())));
                        const double middle = (wanted.FirstParameter()+
                                               wanted.LastParameter()) / 2.0;
                        angle += std::round((middle-angle)/(2.0*3.14159265358979323846)) * 2.0*3.14159265358979323846;
                        return angle >= wanted.FirstParameter()-1e-5 &&
                               angle <= wanted.LastParameter()+1e-5;
                    };
                    std::vector<bool> selected(actual.size(), false);
                    std::vector<std::size_t> path;
                    const auto search = [&](auto&& self, const gp_Pnt& cursor,
                                            double length) -> bool {
                        if (!path.empty() && cursor.Distance(sourceEnd) < 2e-7 &&
                            std::fabs(length-wantedLength) < lengthTolerance)
                            return true;
                        if (path.size() >= actual.size() ||
                            length > wantedLength+lengthTolerance) return false;
                        for (std::size_t i = 0; i < actual.size(); ++i) {
                            if (used[i] || selected[i]) continue;
                            const BRepAdaptor_Curve curve(actual[i]);
                            if (curve.GetType() != GeomAbs_Circle ||
                                curve.Circle().Location().Distance(circle.Location()) > 2e-7 ||
                                std::fabs(curve.Circle().Radius()-circle.Radius()) > 2e-7 ||
                                !curve.Circle().Axis().Direction().IsParallel(
                                    circle.Axis().Direction(), 1e-6) ||
                                !onWantedArc(curve.Value((curve.FirstParameter()+
                                                          curve.LastParameter())/2.0)))
                                continue;
                            const gp_Pnt a = curve.Value(curve.FirstParameter());
                            const gp_Pnt b = curve.Value(curve.LastParameter());
                            gp_Pnt next;
                            if (cursor.Distance(a) < 2e-7) next = b;
                            else if (cursor.Distance(b) < 2e-7) next = a;
                            else continue;
                            GProp_GProps properties;
                            BRepGProp::LinearProperties(actual[i], properties);
                            selected[i] = true;
                            path.push_back(i);
                            if (self(self, next, length+properties.Mass())) return true;
                            path.pop_back();
                            selected[i] = false;
                        }
                        return false;
                    };
                    if (search(search, sourceStart, 0.0)) {
                        for (const auto index : path) used[index] = true;
                        found = true;
                    }
                }
                if (!found && segment.kind != AnalyticEdgeKind::Circle) {
                    // A ring of another kind, or an edge winding round (a thread's helix), cut at a
                    // periodic surface's seam: the unused pieces that lie on it and together are as
                    // long as it.
                    double wantedFirst = 0.0, wantedLast = 0.0;
                    const Handle(Geom_Curve) wantedCurve = BRep_Tool::Curve(expected, wantedFirst, wantedLast);
                    double length = 0.0;
                    std::vector<std::size_t> pieces;
                    for (std::size_t i = 0; i < actual.size() && !wantedCurve.IsNull(); ++i) {
                        if (used[i]) continue;
                        const BRepAdaptor_Curve got(actual[i]);
                        bool on = true;
                        for (double fraction : {0.1, 0.5, 0.9}) {
                            const GeomAPI_ProjectPointOnCurve projection(
                                got.Value(got.FirstParameter() + (got.LastParameter()-got.FirstParameter()) * fraction),
                                wantedCurve);
                            on = on && projection.NbPoints() && projection.LowerDistance() < 2e-7;
                        }
                        if (!on) continue;
                        GProp_GProps properties;
                        BRepGProp::LinearProperties(actual[i], properties);
                        length += properties.Mass();
                        pieces.push_back(i);
                    }
                    if (pieces.size() > 1 &&
                        std::fabs(length - wantedLength) <= std::max(2e-7, wantedLength * 1e-6)) {
                        for (const auto index : pieces) used[index] = true;
                        found = true;
                    }
                }
                if (!found) {
                    // With the nearest candidate of its curve type, to tell a near miss from none.
                    double nearestEnds = std::numeric_limits<double>::infinity(), nearestLength = 0.0;
                    const gp_Pnt a = wanted.Value(wanted.FirstParameter()), b = wanted.Value(wanted.LastParameter());
                    for (std::size_t i = 0; i < actual.size(); ++i) {
                        const BRepAdaptor_Curve got(actual[i]);
                        if (used[i] || got.GetType() != wanted.GetType()) continue;
                        const gp_Pnt c = got.Value(got.FirstParameter()), d = got.Value(got.LastParameter());
                        const double ends = std::min(std::max(a.Distance(c), b.Distance(d)), std::max(a.Distance(d), b.Distance(c)));
                        if (ends < nearestEnds) {
                            nearestEnds = ends;
                            GProp_GProps properties;
                            BRepGProp::LinearProperties(actual[i], properties);
                            nearestLength = properties.Mass();
                        }
                    }
                    char figures[200];
                    std::snprintf(figures, sizeof figures, " (kind %d, curve type %d, length %.9g; nearest unused of its type: ends %.3g m, length %.9g)",
                                  int(segment.kind), int(wanted.GetType()), wantedLength, nearestEnds, nearestLength);
                    detail = "source edge " + std::to_string(expectedCount) +
                             " has no matching generated edge" + figures;
                    return false;
                }
            }
        }
        for (std::size_t i = 0; i < actual.size(); ++i) {
            if (!used[i] && !spare(actual[i])) {
                detail = "generated edge " + std::to_string(i + 1) +
                         " has no matching source edge";
                return false;
            }
        }
        return true;
    };
    const auto boundaryMatches = [&](const TopoDS_Face& face,
                                     const AnalyticFacePatch& patch,
                                     std::string& detail) {
        std::vector<TopoDS_Edge> actual;
        for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
            const auto edge = TopoDS::Edge(it.Current());
            if (!BRep_Tool::Degenerated(edge)) actual.push_back(edge);
        }
        // OCCT represents the periodic seam twice on a full curved face.
        // The source may omit this artificial parameter boundary.
        return edgesMatch(actual, [&](const TopoDS_Edge& edge) { return BRep_Tool::IsClosed(edge, face); },
                          patch, detail);
    };
    std::string trimDiagnostic;
    // A tolerant segment on a curved face, as on a plane (atSourceVertices below): the edge ends at the
    // source's vertices, their tolerance covering the gap to the curve's ends, so that the next edge, built
    // from the same vertex, meets it. An exact segment (tolerance 0) is left as it is.
    const auto atVertices = [&](const TopoDS_Edge& edge, const AnalyticEdgeSegment& segment) -> TopoDS_Edge {
        if (edge.IsNull() || !segment.hasEndpoints || !std::isfinite(segment.tolerance) || segment.tolerance <= 0.0 ||
            segment.kind == AnalyticEdgeKind::SurfaceCurve || segment.kind == AnalyticEdgeKind::BlendBoundary ||
            point(segment.start).Distance(point(segment.end)) < 1e-10)
            return edge;
        double first = 0.0, last = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
        if (curve.IsNull()) return edge;
        const bool backwards = edge.Orientation() == TopAbs_REVERSED;
        const gp_Pnt atFirst = point(backwards ? segment.end : segment.start);
        const gp_Pnt atLast = point(backwards ? segment.start : segment.end);
        const double gap = std::max(curve->Value(first).Distance(atFirst), curve->Value(last).Distance(atLast));
        if (gap <= 1e-7 || gap > 2.0 * segment.tolerance) return edge;
        BRep_Builder vertices;
        TopoDS_Vertex v1, v2;
        vertices.MakeVertex(v1, atFirst, 1.01 * gap);
        vertices.MakeVertex(v2, atLast, 1.01 * gap);
        BRepBuilderAPI_MakeEdge maker(curve, v1, v2, first, last);
        if (!maker.IsDone()) return edge;
        TopoDS_Edge rebuilt = maker.Edge();
        if (backwards) rebuilt.Reverse();
        return rebuilt;
    };
    const auto trimmedSurfaceFace = [&](const auto& surface,
                                        const AnalyticFacePatch& patch) -> TopoDS_Face {
        trimDiagnostic.clear();
        try {
            BRepBuilderAPI_MakeFace supportMaker = [&] {
                if constexpr (std::is_convertible_v<decltype(surface),
                                                    Handle(Geom_Surface)>)
                    return BRepBuilderAPI_MakeFace(surface, 1e-7);
                else
                    return BRepBuilderAPI_MakeFace(surface);
            }();
            if (!supportMaker.IsDone()) { trimDiagnostic = "support"; return {}; }
            const TopoDS_Face support = supportMaker.Face();
            bool explicitBoundaries = false;
            bool allExplicitBoundaries = true;
            std::vector<TopoDS_Wire> wires;
            std::size_t outer = 0;
            double longest = -1.0;
            for (const auto& loop : patch.loops) {
                BRepBuilderAPI_MakeWire wireMaker;
                ShapeFix_Edge edgeFixer;
                for (const auto& segment : loop) {
                    TopoDS_Edge edge = atVertices(sourceBoundary(segment), segment);
                    if (edge.IsNull()) {
                        trimDiagnostic = "source edge of kind " + std::to_string(int(segment.kind)) +
                            (blendDiagnostic.empty() ? std::string() : " (" + blendDiagnostic + ")");
                        return {};
                    }
                    bool explicitBoundary = false;
                    if constexpr (std::is_convertible_v<decltype(surface), Handle(Geom_Surface)>) {
                        if (segment.pcurve) {
                            const auto& d = *segment.pcurve;
                            TColgp_Array1OfPnt2d poles(1, int(d.poles.size()));
                            TColStd_Array1OfReal weights(1, int(d.weights.size())), knots(1, int(d.knots.size()));
                            TColStd_Array1OfInteger multiplicities(1, int(d.multiplicities.size()));
                            for (int p = 1; p <= poles.Length(); ++p) {
                                const auto& uv = d.poles[std::size_t(p - 1)];
                                poles.SetValue(p, gp_Pnt2d(uv.x, uv.y)); weights.SetValue(p, d.weights[std::size_t(p - 1)]);
                            }
                            for (int k = 1; k <= knots.Length(); ++k) {
                                knots.SetValue(k, d.knots[std::size_t(k - 1)]);
                                multiplicities.SetValue(k, d.multiplicities[std::size_t(k - 1)]);
                            }
                            const Handle(Geom2d_BSplineCurve) pcurve = new Geom2d_BSplineCurve(
                                poles, weights, knots, multiplicities, d.degree, d.periodic);
                            if (segment.kind == AnalyticEdgeKind::SurfaceCurve && segment.curveLast != segment.curveFirst)
                                pcurve->Segment(std::min(segment.curveFirst, segment.curveLast),
                                                std::max(segment.curveFirst, segment.curveLast));
                            const BRepAdaptor_Curve curve(edge);
                            const double first = curve.FirstParameter(), last = curve.LastParameter();
                            const double pcFirst = pcurve->FirstParameter(), pcLast = pcurve->LastParameter();
                            double gaps[2]{};
                            for (int sample = 0; sample <= 32; ++sample) {
                                const double fraction = sample / 32.0;
                                const auto p = curve.Value(first + (last - first) * fraction);
                                for (int sense = 0; sense < 2; ++sense) {
                                    const auto uv = pcurve->Value(pcFirst + (pcLast - pcFirst) * (sense ? 1 - fraction : fraction));
                                    gaps[sense] = std::max(gaps[sense], surface->Value(uv.X(), uv.Y()).Distance(p));
                                }
                            }
                            const bool reverse = gaps[1] < gaps[0];
                            const double gap = gaps[reverse ? 1 : 0];
                            const double allowed = std::max({supportTolerance, boundaryTolerance(segment), BRep_Tool::Tolerance(edge)});
                            bool independent = false;
                            if (gap > allowed && segment.pcurveIndependentParameter) {
                                double f, l;
                                const auto boundary3d = BRep_Tool::Curve(edge, f, l);
                                independent = !boundary3d.IsNull();
                                for (int sample = 0; sample <= 32 && independent; ++sample) {
                                    const auto uv = pcurve->Value(pcFirst + (pcLast - pcFirst) * sample / 32.0);
                                    const auto at = surface->Value(uv.X(), uv.Y());
                                    const GeomAPI_ProjectPointOnCurve projection(at, boundary3d, f, l);
                                    // The distance to a bounded curve: its nearest foot or one of its ends. A
                                    // point at the edge's end, a hair past it, has no foot inside the range.
                                    const double distance = std::min({projection.NbPoints() ? projection.LowerDistance()
                                                                                             : std::numeric_limits<double>::infinity(),
                                                                      at.Distance(boundary3d->Value(f)), at.Distance(boundary3d->Value(l))});
                                    independent = distance <= allowed;
                                }
                                // Both ends must cover the edge, not merely a sub-arc of it.
                                const auto a = pcurve->Value(pcFirst), b = pcurve->Value(pcLast);
                                const auto pa = surface->Value(a.X(), a.Y()), pb = surface->Value(b.X(), b.Y());
                                const auto ca = curve.Value(first), cb = curve.Value(last);
                                independent &= std::min(std::max(pa.Distance(ca), pb.Distance(cb)),
                                                        std::max(pa.Distance(cb), pb.Distance(ca))) <= allowed;
                            }
                            if (gap > allowed && !independent) {
                                char ranges[160];
                                std::snprintf(ranges, sizeof ranges, "%.3g (allowed %.3g, UV %.9g..%.9g, 3D %.9g..%.9g)",
                                              gap, allowed, pcFirst, pcLast, first, last);
                                trimDiagnostic = std::string("explicit pcurve is off its 3D boundary by ") + ranges;
                                return {};
                            }
                            if (!independent) {
                                if (reverse) pcurve->Reverse();
                                if (first != pcFirst || last != pcLast) {
                                    TColStd_Array1OfReal matchingKnots(1, pcurve->NbKnots());
                                    for (int k = 1; k <= matchingKnots.Length(); ++k)
                                        matchingKnots.SetValue(k, first + (pcurve->Knot(k) - pcFirst) * (last - first) / (pcLast - pcFirst));
                                    pcurve->SetKnots(matchingKnots);
                                }
                                largestSupportGap = std::max(largestSupportGap, gap);
                                Handle(Geom2d_Curve) storedBoundary = pcurve;
                                if (pcurve->Degree() == 1 && pcurve->NbPoles() == 2 &&
                                    pcurve->Weight(1) == pcurve->Weight(2)) {
                                    const gp_Vec2d derivative(pcurve->Pole(1), pcurve->Pole(2));
                                    const double speed = derivative.Magnitude() / (last - first);
                                    if (std::fabs(speed - 1.0) <= 8 * std::numeric_limits<double>::epsilon()) {
                                        // A metric affine UV law is exactly a line. Keep that
                                        // representation: adaptive integration handles a line
                                        // differently from an equivalent degree-one spline.
                                        const gp_Dir2d direction(derivative);
                                        storedBoundary = new Geom2d_Line(
                                            pcurve->Pole(1).Translated(gp_Vec2d(direction) * -first), direction);
                                    }
                                }
                                BRep_Builder boundary;
                                boundary.UpdateEdge(edge, storedBoundary, support,
                                    std::max({BRep_Tool::Tolerance(edge), segment.tolerance, 1.01 * gap}));
                                boundary.Range(edge, support, first, last);
                                boundary.SameRange(edge, true);
                                boundary.SameParameter(edge, true);
                                explicitBoundary = explicitBoundaries = true;
                            }
                        }
                    }
                    if constexpr (std::is_convertible_v<decltype(surface),
                                                    Handle(Geom_Surface)>) {
                        // FixAddPCurve may project an off-surface source edge
                        // onto the support. That would silently change a
                        // signed XT offset while preserving a closed shell.
                        const Handle(Geom_Surface) geometry = surface;
                        if (!explicitBoundary) {
                            const BRepAdaptor_Curve curve(edge);
                            ShapeAnalysis_Surface analysis(geometry);
                            for (int sample = 0; sample <= 8; ++sample) {
                                const double parameter = curve.FirstParameter() +
                                    (curve.LastParameter()-curve.FirstParameter()) *
                                        (double(sample) / 8.0);
                                // Two searches for the foot, the nearer one kept: both return true
                                // points of the surface, so the distance is never understated. OCCT
                                // 7.9's GeomAPI projection alone returned a domain bound 1.7 mm away
                                // for a point lying on an NX plate's swept face.
                                const gp_Pnt at = curve.Value(parameter);
                                const GeomAPI_ProjectPointOnSurf projection(at, geometry);
                                double gap = projection.NbPoints() ? projection.LowerDistance()
                                                                   : std::numeric_limits<double>::infinity();
                                const gp_Pnt2d foot = analysis.ValueOfUV(at, 1e-9);
                                gap = std::min(gap, geometry->Value(foot.X(), foot.Y()).Distance(at));
                                largestSupportGap = std::max(largestSupportGap, gap);
                                // A tolerant edge lies on its faces only to within its own tolerance.
                                const double allowed = std::max(supportTolerance,
                                                                std::isfinite(segment.tolerance) ? boundaryTolerance(segment) : 0.0);
                                if (!(gap <= allowed)) {
                                    char figures[160];
                                    std::snprintf(figures, sizeof figures, "%.3g m (allowed %.3g) at (%.6f, %.6f, %.6f)",
                                                  gap, allowed, at.X(), at.Y(), at.Z());
                                    trimDiagnostic = std::string("source edge is off support by ") + figures;
                                    return {};
                                }
                            }
                        }
                    }
                    // Onto the surface at 1e-7, or failing that at the precision a tolerant edge (or
                    // vertex) lies on it. False with an OK status means the edge has a pcurve there
                    // already: on a plane OCCT derives one for any edge.
                    double precision = 1e-7;
                    bool placed = explicitBoundary || edgeFixer.FixAddPCurve(edge, support, false, precision) ||
                                  edgeFixer.Status(ShapeExtend_OK);
                    if (!placed && std::isfinite(segment.tolerance) && boundaryTolerance(segment) > precision) {
                        precision = boundaryTolerance(segment);
                        placed = edgeFixer.FixAddPCurve(edge, support, false, precision) ||
                                 edgeFixer.Status(ShapeExtend_OK);
                    }
                    if (!placed) {
                        const BRepAdaptor_Curve along(edge);
                        const gp_Pnt at = along.Value(0.5 * (along.FirstParameter() + along.LastParameter()));
                        char figures[160];
                        std::snprintf(figures, sizeof figures, "pcurve of an edge of kind %d (tolerance %.3g, status %d%d) at (%.6f, %.6f, %.6f)",
                                      int(segment.kind), segment.tolerance, int(edgeFixer.Status(ShapeExtend_OK)),
                                      int(edgeFixer.Status(ShapeExtend_FAIL)), at.X(), at.Y(), at.Z());
                        trimDiagnostic = figures;
                        return {};
                    }
                    if (!explicitBoundary) edgeFixer.FixSameParameter(edge, precision);
                    allExplicitBoundaries &= explicitBoundary;
                    wireMaker.Add(edge);
                    if (!wireMaker.IsDone()) { trimDiagnostic = "wire"; return {}; }
                }
                if (!wireMaker.Wire().Closed()) {
                    trimDiagnostic = "open wire";
                    return {};
                }
                wires.push_back(wireMaker.Wire());
                GProp_GProps properties;
                BRepGProp::LinearProperties(wires.back(), properties);
                if (properties.Mass() > longest) {
                    longest = properties.Mass();
                    outer = wires.size() - 1;
                }
            }
            // Distinct source loops can touch at a declared vertex. Copies of
            // their edges need that shared topology too; geometric coincidence
            // alone is reported as intersecting wires by OCCT. Match the source
            // endpoints first so nearby, distinct vertices are never merged.
            if (wires.size() > 1) {
                Handle(BRepTools_ReShape) shared = new BRepTools_ReShape;
                std::map<std::array<double, 3>, std::vector<std::size_t>> endpointLoops;
                std::vector<TopTools_IndexedMapOfShape> vertices(wires.size());
                for (std::size_t loop = 0; loop < patch.loops.size(); ++loop) {
                    TopExp::MapShapes(wires[loop], TopAbs_VERTEX, vertices[loop]);
                    for (const auto& edge : patch.loops[loop])
                        for (const auto& p : {edge.start, edge.end}) {
                            auto& owners = endpointLoops[{p.x, p.y, p.z}];
                            if (owners.empty() || owners.back() != loop) owners.push_back(loop);
                        }
                }
                bool changed = false;
                for (const auto& [position, owners] : endpointLoops) {
                    if (owners.size() < 2) continue;
                    const gp_Pnt expected(position[0], position[1], position[2]);
                    TopoDS_Vertex kept;
                    for (const auto loop : owners) {
                        TopoDS_Vertex nearest;
                        double distance = std::numeric_limits<double>::infinity();
                        for (int k = 1; k <= vertices[loop].Extent(); ++k) {
                            const auto vertex = TopoDS::Vertex(vertices[loop](k));
                            const double gap = BRep_Tool::Pnt(vertex).Distance(expected);
                            if (gap <= BRep_Tool::Tolerance(vertex) && gap < distance) {
                                nearest = vertex; distance = gap;
                            }
                        }
                        if (nearest.IsNull()) continue;
                        if (kept.IsNull()) { kept = nearest; continue; }
                        if (kept.IsSame(nearest)) continue;
                        BRep_Builder vertexBuilder;
                        vertexBuilder.UpdateVertex(kept, expected,
                            std::max(BRep_Tool::Tolerance(kept), BRep_Tool::Tolerance(nearest)));
                        shared->Replace(nearest.Oriented(TopAbs_FORWARD), kept.Oriented(TopAbs_FORWARD));
                        changed = true;
                    }
                }
                if (changed)
                    for (auto& wire : wires) wire = TopoDS::Wire(shared->Apply(wire));
            }
            bool periodicSupport = false;
            if constexpr (std::is_convertible_v<decltype(surface), Handle(Geom_Surface)>)
                periodicSupport = surface->IsUPeriodic() || surface->IsVPeriodic();
            // A wire with some of its boundaries transferred, on a support that is not periodic,
            // keeps its edge curves as placed (first pass). Where that leaves a face OCCT does not
            // accept — an NX box of the samples has one, its other edges' curves not valid on the
            // surface until repaired — the wire is repaired as a whole (second pass), and the
            // boundary check below still decides.
            const bool partlyExplicit = explicitBoundaries && !allExplicitBoundaries && !periodicSupport;
            // A support with a side drawn into a point (a B-spline patch whose row of poles meets in
            // one, under a three-sided face): the face's edges meet there in space but not in UV,
            // where OCCT wants a degenerate edge along that side. A face OCCT does not accept on such
            // a support is made again with those edges added, its own edges untouched (last pass).
            double poleTolerance = 1e-7;
            for (const auto& loop : patch.loops)
                for (const auto& segment : loop)
                    if (std::isfinite(segment.tolerance)) poleTolerance = std::max(poleTolerance, boundaryTolerance(segment));
            bool singularSupport = false;
            if constexpr (std::is_convertible_v<decltype(surface), Handle(Geom_Surface)>)
                singularSupport = !periodicSupport && ShapeAnalysis_Surface(surface).HasSingularities(poleTolerance);
            // A support that overlaps itself (a helix swept along its axis: a turn on, the same points
            // again) can carry a face whose fins' curves the source put on different turns: the loop
            // is closed in space but apart in UV, twice, by one step and back. The shorter run of
            // edges moves by that step when every point of it then stays where it was in space (to
            // the edge's tolerance); OCCT then gets a loop closed in UV (last pass).
            const auto joinSheets = [&](const TopoDS_Face& onSupport) -> bool {
                if constexpr (!std::is_convertible_v<decltype(surface), Handle(Geom_Surface)>) {
                    return false;
                } else {
                    const Handle(Geom_Surface) geometry = surface;
                    struct Piece {
                        TopoDS_Edge edge;
                        Handle(Geom2d_Curve) pcurve;
                        double first = 0, last = 0, tolerance = 0;
                        gp_Pnt2d start, end;
                    };
                    // A UV step's length in space at a point, to first order.
                    const auto spatial = [&](const gp_Pnt2d& at, const gp_Vec2d& step) {
                        gp_Pnt p;
                        gp_Vec du, dv;
                        geometry->D1(at.X(), at.Y(), p, du, dv);
                        return (du * step.X() + dv * step.Y()).Magnitude();
                    };
                    bool moved = false;
                    for (TopExp_Explorer w(onSupport, TopAbs_WIRE); w.More(); w.Next()) {
                        std::vector<Piece> pieces;
                        for (BRepTools_WireExplorer e(TopoDS::Wire(w.Current()), onSupport); e.More(); e.Next()) {
                            Piece piece;
                            piece.edge = e.Current();
                            piece.pcurve = BRep_Tool::CurveOnSurface(piece.edge, onSupport, piece.first, piece.last);
                            if (piece.pcurve.IsNull()) return false;
                            const bool backwards = piece.edge.Orientation() == TopAbs_REVERSED;
                            piece.start = piece.pcurve->Value(backwards ? piece.last : piece.first);
                            piece.end = piece.pcurve->Value(backwards ? piece.first : piece.last);
                            piece.tolerance = std::max(1e-7, BRep_Tool::Tolerance(piece.edge));
                            pieces.push_back(piece);
                        }
                        const std::size_t n = pieces.size();
                        std::vector<std::size_t> open; // junction k: the end of piece k to the start of k + 1
                        for (std::size_t k = 0; k < n; ++k) {
                            const gp_Vec2d gap(pieces[k].end, pieces[(k + 1) % n].start);
                            if (spatial(pieces[k].end, gap) > 10.0 * std::max(pieces[k].tolerance, pieces[(k + 1) % n].tolerance))
                                open.push_back(k);
                        }
                        if (open.empty()) continue;
                        if (open.size() != 2) return false;
                        const std::size_t i = open[0], j = open[1];
                        const gp_Vec2d out(pieces[i].end, pieces[(i + 1) % n].start), back(pieces[j].end, pieces[(j + 1) % n].start);
                        if (spatial(pieces[i].end, out + back) > 10.0 * std::max(pieces[i].tolerance, pieces[j].tolerance)) return false;
                        // Pieces i+1..j move by `back`, or pieces j+1..i (round the loop) by `out`.
                        const bool inner = j - i <= n - (j - i);
                        const gp_Vec2d step = inner ? back : out;
                        std::vector<std::size_t> run;
                        for (std::size_t k = inner ? i + 1 : j + 1, count = inner ? j - i : n - (j - i); count > 0; --count, k = (k + 1) % n)
                            run.push_back(k % n);
                        for (const std::size_t k : run)
                            for (int sample = 0; sample <= 16; ++sample) {
                                const gp_Pnt2d at = pieces[k].pcurve->Value(pieces[k].first + (pieces[k].last - pieces[k].first) * sample / 16.0);
                                const gp_Pnt2d there = at.Translated(step);
                                if (!(geometry->Value(at.X(), at.Y()).Distance(geometry->Value(there.X(), there.Y())) <= pieces[k].tolerance))
                                    return false;
                            }
                        BRep_Builder builder;
                        for (const std::size_t k : run) {
                            const Handle(Geom2d_Curve) shifted = Handle(Geom2d_Curve)::DownCast(pieces[k].pcurve->Translated(step));
                            builder.UpdateEdge(pieces[k].edge, shifted, onSupport, BRep_Tool::Tolerance(pieces[k].edge));
                            builder.Range(pieces[k].edge, onSupport, pieces[k].first, pieces[k].last);
                        }
                        moved = true;
                    }
                    return moved;
                }
            };
            enum class Pass { AsPlaced, RepairWhole, ClosePoles, JoinSheets };
            std::vector<Pass> passes{Pass::AsPlaced};
            if (partlyExplicit) passes.push_back(Pass::RepairWhole);
            if (singularSupport) passes.push_back(Pass::ClosePoles);
            if (explicitBoundaries && !periodicSupport) passes.push_back(Pass::JoinSheets);
            for (std::size_t attempt = 0; attempt < 2 * passes.size(); ++attempt) {
                const int orientation = int(attempt % 2);
                const Pass pass = passes[attempt / 2];
                const bool repairWhole = pass == Pass::RepairWhole;
                TopoDS_Wire wire = wires[outer];
                if (orientation) wire.Reverse();
                BRepBuilderAPI_MakeFace maker(surface, wire, false);
                if (!maker.IsDone()) { trimDiagnostic = "face"; continue; }
                for (std::size_t i = 0; i < wires.size(); ++i)
                    if (i != outer) maker.Add(wires[i]);
                if (!maker.IsDone()) { trimDiagnostic = "hole"; continue; }
                TopoDS_Face trimmed = maker.Face();
                if (pass == Pass::ClosePoles) {
                    std::vector<TopoDS_Wire> closed;
                    for (TopExp_Explorer w(trimmed, TopAbs_WIRE); w.More(); w.Next()) {
                        ShapeFix_Wire poles(TopoDS::Wire(w.Current()), trimmed, poleTolerance);
                        poles.FixDegenerated();
                        closed.push_back(poles.Wire());
                    }
                    if (closed.empty()) { trimDiagnostic = "poles"; continue; }
                    BRepBuilderAPI_MakeFace again(surface, closed.front(), false);
                    for (std::size_t i = 1; i < closed.size() && again.IsDone(); ++i) again.Add(closed[i]);
                    if (!again.IsDone()) { trimDiagnostic = "poles"; continue; }
                    trimmed = again.Face();
                }
                if (pass == Pass::JoinSheets && orientation == 0 && !joinSheets(trimmed)) {
                    trimDiagnostic = "sheets";
                    break;
                }
                ShapeFix_Face fixer(trimmed);
                // Adding the degenerate edge of an enclosed pole itself: on a cone's tip bounded by an
                // intersection ring (ACIS: the apex a curveless edge) OCCT 7.9 dereferences a null
                // handle there and the process dies. Such a face goes to splitSupportFace instead.
                fixer.FixPeriodicDegeneratedMode() = 0;
                if (allExplicitBoundaries || (partlyExplicit && !repairWhole)) {
                    // Non-transferred edges were already placed and checked
                    // above. Wire repair may still add periodic seams, but
                    // repairing all edge curves would also replace a valid
                    // transferred boundary on a partly explicit planar wire.
                    // Partly explicit periodic wires still need seam repair.
                    fixer.FixWireTool()->FixEdgeCurvesMode() = 0;
                    fixer.FixWireTool()->FixSameParameterMode() = 0;
                    // The native vertex tolerance already covers small UV
                    // endpoint gaps. FixLacking would bend both pcurves to
                    // their average endpoint and change the enclosed area.
                    // Keep periodic shifts and seam repair enabled.
                    fixer.FixWireTool()->FixLackingMode() = 0;
                }
                const bool needsRepair = !allExplicitBoundaries || periodicSupport;
                if (needsRepair) fixer.Perform();
                fixer.FixOrientation();
                const TopoDS_Face face = fixer.Face();
                // A seam ShapeFix adds on a periodic B-spline comes without its same-range and
                // same-parameter flags set.
                if (explicitBoundaries) {
                    double seamTolerance = 1e-7;
                    for (const auto& loop : patch.loops)
                        for (const auto& segment : loop)
                            seamTolerance = std::max(seamTolerance, boundaryTolerance(segment));
                    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
                        const auto edge = TopoDS::Edge(e.Current());
                        if (BRep_Tool::SameRange(edge) && BRep_Tool::SameParameter(edge)) continue;
                        // A generated seam has no source tolerance of its own. Inherit the
                        // adjacent boundaries' precision when building its shared parameter.
                        BRep_Builder seam;
                        seam.UpdateEdge(edge, std::max(seamTolerance, BRep_Tool::Tolerance(edge)));
                        BRepLib::SameRange(edge, 1e-12);
                        BRepLib::SameParameter(edge, BRep_Tool::Tolerance(edge));
                    }
                } else {
                    BRepLib::SameParameter(face, 1e-7, true);
                }
                std::string ignored;
                if (const BRepCheck_Analyzer check(face); !check.IsValid()) {
                    trimDiagnostic = "invalid trimmed face";
                    try {
                        const auto& result = check.Result(face);
                        if (!result.IsNull())
                            for (const auto status : result->Status())
                                if (status != BRepCheck_NoError) trimDiagnostic += " f" + std::to_string(int(status));
                        for (TopExp_Explorer wire(face, TopAbs_WIRE); wire.More(); wire.Next()) {
                            const auto& wireResult = check.Result(wire.Current());
                            if (wireResult.IsNull()) continue;
                            for (const auto status : wireResult->Status())
                                if (status != BRepCheck_NoError) trimDiagnostic += " w" + std::to_string(int(status));
                        }
                        for (TopExp_Explorer edge(face, TopAbs_EDGE); edge.More(); edge.Next()) {
                            const auto& edgeResult = check.Result(edge.Current());
                            if (edgeResult.IsNull()) continue;
                            for (const auto status : edgeResult->Status())
                                if (status != BRepCheck_NoError) trimDiagnostic += " e" + std::to_string(int(status));
                            edgeResult->InitContextIterator();
                            for (; edgeResult->MoreShapeInContext(); edgeResult->NextShapeInContext())
                                for (const auto status : edgeResult->StatusOnShape())
                                    if (status != BRepCheck_NoError)
                                        trimDiagnostic += " e/f" + std::to_string(int(status)) + "(tol " +
                                            std::to_string(BRep_Tool::Tolerance(TopoDS::Edge(edge.Current()))) + ")";
                        }
                    } catch (const Standard_Failure&) {
                    }
                    continue;
                }
                if (boundaryMatches(face, patch, ignored)) return face;
                trimDiagnostic = ignored;
            }
        } catch (const Standard_Failure& error) {
            trimDiagnostic = error.GetMessageString();
        }
        return {};
    };
    // Separate faces can share a closed blend. Its seam may cut a face's loop even though the
    // complete blend is a ring. Move that seam into the largest interval away from this face's
    // boundary; only the periodic B-spline's parametrisation changes.
    const auto splineWithSeamAway = [&](const Handle(Geom_BSplineSurface)& original,
                                        const AnalyticFacePatch& patch) -> Handle(Geom_BSplineSurface) {
        if (!original->IsUPeriodic() && !original->IsVPeriodic()) return original;
        std::vector<double> u, v;
        ShapeAnalysis_Surface analysis(original);
        for (const auto& loop : patch.loops) for (const auto& segment : loop) {
            const TopoDS_Edge edge = sourceBoundary(segment);
            if (edge.IsNull()) return original;
            const BRepAdaptor_Curve curve(edge);
            for (int sample=0; sample<=32; ++sample) {
                const gp_Pnt2d uv=analysis.ValueOfUV(curve.Value(curve.FirstParameter()+
                    (curve.LastParameter()-curve.FirstParameter())*sample/32.0),1e-9);
                u.push_back(uv.X()); v.push_back(uv.Y());
            }
        }
        const auto shifted = Handle(Geom_BSplineSurface)::DownCast(original->Copy());
        const auto move = [&](std::vector<double>& values, bool alongU) {
            if (values.empty() || !(alongU?shifted->IsUPeriodic():shifted->IsVPeriodic())) return;
            const double first=alongU?shifted->UKnot(1):shifted->VKnot(1);
            const double period=alongU?shifted->UPeriod():shifted->VPeriod();
            for (double& value:values) {
                value=std::fmod(value-first,period);
                if (value<0) value+=period;
            }
            std::sort(values.begin(),values.end());
            double gap=0, middle=0;
            for (std::size_t i=0; i<values.size(); ++i) {
                const double a=values[i], b=i+1<values.size()?values[i+1]:values.front()+period;
                if (b-a>gap) { gap=b-a; middle=std::fmod((a+b)*.5,period); }
            }
            // A boundary all round the ring needs a seam in the face, which ShapeFix adds.
            if (gap<period*.1) return;
            int index=1;
            double nearest=period;
            const int knots=alongU?shifted->NbUKnots():shifted->NbVKnots();
            for (int k=1;k<knots;++k) {
                const double knot=(alongU?shifted->UKnot(k):shifted->VKnot(k))-first;
                const double distance=std::fabs(std::remainder(knot-middle,period));
                if (distance<nearest) { nearest=distance; index=k; }
            }
            if (nearest<gap*.5) {
                if (alongU) shifted->SetUOrigin(index); else shifted->SetVOrigin(index);
            }
        };
        move(u,true); move(v,false);
        return shifted;
    };
    // A face that winds round a periodic surface (u) more than once — a thread's root, a band whose
    // helical edges cross the seam at every turn. ShapeFix places a seam as if a face kept within one
    // period, and loses the turns. Here OCCT's boolean splitter cuts the surface, over a full period
    // and well past the edges along v, by the source edges; the seam and the edges' pieces are its
    // own. Edges lie on the surface within 1e-7 (checked as for the trimming above): the splitter's
    // fuzzy value. The face is the pieces on its side of the source edges: those touching the band's
    // own bounds are outside, a source edge between two pieces changes side, a piece of the seam does
    // not. Within one period OCCT holds such a face only as one face per turn (their seam pieces
    // shared), so the result may be several faces; together their outer edges must be the source's
    // boundary.
    const auto splitSupportFace = [&](const Handle(Geom_Surface)& surface,
                                      const AnalyticFacePatch& patch) -> std::vector<TopoDS_Face> {
        try {
            std::vector<TopoDS_Edge> edges;
            double vMin = std::numeric_limits<double>::infinity(), vMax = -vMin;
            ShapeAnalysis_Surface analysis(surface);
            for (const auto& loop : patch.loops)
                for (const auto& segment : loop) {
                    const TopoDS_Edge edge = atVertices(sourceBoundary(segment), segment);
                    if (edge.IsNull()) {
                        trimDiagnostic = "split: source edge of kind " + std::to_string(int(segment.kind));
                        return {};
                    }
                    edges.push_back(edge);
                    const BRepAdaptor_Curve curve(edge);
                    for (int sample = 0; sample <= 64; ++sample) {
                        const double v = analysis.ValueOfUV(curve.Value(curve.FirstParameter() +
                            (curve.LastParameter() - curve.FirstParameter()) * sample / 64.0), 1e-9).Y();
                        vMin = std::min(vMin, v);
                        vMax = std::max(vMax, v);
                    }
                }
            if (!(vMax > vMin) || !surface->IsUPeriodic()) {
                trimDiagnostic = "split: no band of the surface";
                return {};
            }
            // Past the edges by a quarter of their span, short of a cone's apex — or up to it, for a face
            // that holds it.
            double low = vMin - 0.25 * (vMax - vMin), high = vMax + 0.25 * (vMax - vMin);
            if (const Handle(Geom_ConicalSurface) cone = Handle(Geom_ConicalSurface)::DownCast(surface); !cone.IsNull()) {
                const double apex = -cone->RefRadius() / std::sin(cone->SemiAngle());
                if (apex <= vMin) low = patch.holdsApex ? apex : std::max(low, 0.5 * (apex + vMin));
                if (apex >= vMax) high = patch.holdsApex ? apex : std::min(high, 0.5 * (apex + vMax));
            }
            if (!Handle(Geom_SphericalSurface)::DownCast(surface).IsNull()) {
                low = std::max(low, -0.5 * M_PI);
                high = std::min(high, 0.5 * M_PI);
            }
            BRepBuilderAPI_MakeFace band(surface, 0.0, surface->UPeriod(), low, high, 1e-7);
            if (!band.IsDone()) {
                trimDiagnostic = "split: band";
                return {};
            }
            TopTools_ListOfShape arguments, tools;
            arguments.Append(band.Face());
            for (const auto& edge : edges) tools.Append(edge);
            BRepAlgoAPI_Splitter splitter;
            splitter.SetArguments(arguments);
            splitter.SetTools(tools);
            splitter.SetFuzzyValue(1e-7);
            splitter.Build();
            if (!splitter.IsDone()) {
                trimDiagnostic = "split: the splitter failed";
                return {};
            }
            const TopoDS_Shape& result = splitter.Shape();
            // The result's edges from the source edges, and from the band's bounds (not its seam).
            TopTools_IndexedMapOfShape fromSource, fromBounds;
            const auto images = [&](const TopoDS_Shape& original, TopTools_IndexedMapOfShape& into) {
                const TopTools_ListOfShape& modified = splitter.Modified(original);
                if (modified.IsEmpty()) {
                    if (!splitter.IsDeleted(original)) into.Add(original);
                } else {
                    for (TopTools_ListIteratorOfListOfShape it(modified); it.More(); it.Next()) into.Add(it.Value());
                }
            };
            for (const auto& edge : edges) images(edge, fromSource);
            // (Not a degenerate one: an apex the face holds is inside it, not outside.)
            for (TopExp_Explorer it(band.Face(), TopAbs_EDGE); it.More(); it.Next())
                if (!BRep_Tool::IsClosed(TopoDS::Edge(it.Current()), band.Face()) &&
                    !BRep_Tool::Degenerated(TopoDS::Edge(it.Current())))
                    images(it.Current(), fromBounds);
            TopTools_IndexedMapOfShape pieces;
            TopExp::MapShapes(result, TopAbs_FACE, pieces);
            TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
            TopExp::MapShapesAndAncestors(result, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
            std::vector<int> side(pieces.Extent() + 1, -1);
            std::vector<int> queue;
            for (int i = 1; i <= pieces.Extent(); ++i)
                for (TopExp_Explorer it(pieces(i), TopAbs_EDGE); it.More() && side[i] < 0; it.Next())
                    if (fromBounds.Contains(it.Current())) {
                        side[i] = 0;
                        queue.push_back(i);
                    }
            for (std::size_t next = 0; next < queue.size(); ++next) {
                const int i = queue[next];
                for (TopExp_Explorer it(pieces(i), TopAbs_EDGE); it.More(); it.Next()) {
                    if (!edgeFaces.Contains(it.Current())) continue;
                    const int expected = fromSource.Contains(it.Current()) ? 1 - side[i] : side[i];
                    for (TopTools_ListIteratorOfListOfShape f(edgeFaces.FindFromKey(it.Current())); f.More(); f.Next()) {
                        const int j = pieces.FindIndex(f.Value());
                        if (j == i || j == 0) continue;
                        if (side[j] < 0) {
                            side[j] = expected;
                            queue.push_back(j);
                        } else if (side[j] != expected) {
                            trimDiagnostic = "split: a piece on both sides of the source edges";
                            return {};
                        }
                    }
                }
            }
            std::vector<TopoDS_Face> inside;
            for (int i = 1; i <= pieces.Extent(); ++i) {
                if (side[i] < 0) {
                    trimDiagnostic = "split: a piece not reached from the band's bounds";
                    return {};
                }
                if (side[i] == 1) inside.push_back(TopoDS::Face(pieces(i)));
            }
            // Their outer edges: not shared by two of them; a seam of one of them is spare.
            TopTools_IndexedDataMapOfShapeListOfShape insideEdges;
            for (const auto& face : inside) TopExp::MapShapesAndAncestors(face, TopAbs_EDGE, TopAbs_FACE, insideEdges);
            std::vector<TopoDS_Edge> outer;
            TopTools_IndexedMapOfShape seams;
            for (int i = 1; i <= insideEdges.Extent(); ++i) {
                const TopoDS_Edge edge = TopoDS::Edge(insideEdges.FindKey(i));
                if (BRep_Tool::Degenerated(edge)) continue;
                TopTools_IndexedMapOfShape owners;
                for (TopTools_ListIteratorOfListOfShape f(insideEdges(i)); f.More(); f.Next()) owners.Add(f.Value());
                if (owners.Extent() > 1) continue;
                outer.push_back(edge);
                if (BRep_Tool::IsClosed(edge, TopoDS::Face(owners(1)))) seams.Add(edge);
            }
            std::string detail;
            if (inside.empty() ||
                !edgesMatch(outer, [&](const TopoDS_Edge& edge) { return seams.Contains(edge); }, patch, detail)) {
                trimDiagnostic = "split into " + std::to_string(pieces.Extent()) + " pieces, " +
                                 std::to_string(inside.size()) + " inside, not the source's boundary: " + detail;
                return {};
            }
            return inside;
        } catch (const Standard_Failure& error) {
            trimDiagnostic = std::string("split: ") + error.GetMessageString();
        }
        return {};
    };
    // A loop that runs along an edge and back again (a slit: both of the edge's fins on this face,
    // as the seam a STEP cylinder brings along) bounds the face's region only as its two other
    // parts do: the loop is those parts, the edge none of the face's boundary. The edge is one
    // traversed both ways when the two uses have the same kind, swapped ends and the same middle —
    // the same, not close: two distinct edges nearer than their tolerance (a strip thinner than it)
    // are both boundary.
    const auto withoutSlits = [&](const AnalyticFacePatch& source) -> std::optional<AnalyticFacePatch> {
        const auto slit = [&](const AnalyticEdgeSegment& x, const AnalyticEdgeSegment& y) {
            if (x.kind != y.kind || !x.hasEndpoints || !y.hasEndpoints || x.forward == y.forward) return false;
            constexpr double tolerance = 1e-12;
            if (point(x.start).Distance(point(x.end)) <= 1e-7 || point(x.start).Distance(point(y.end)) > tolerance ||
                point(x.end).Distance(point(y.start)) > tolerance) return false;
            try {
                const TopoDS_Edge a = sourceBoundary(x), b = sourceBoundary(y);
                if (a.IsNull() || b.IsNull()) return false;
                const BRepAdaptor_Curve ca(a), cb(b);
                return ca.Value(0.5 * (ca.FirstParameter() + ca.LastParameter()))
                           .Distance(cb.Value(0.5 * (cb.FirstParameter() + cb.LastParameter()))) <= 1e-10;
            } catch (const Standard_Failure&) {
                return false;
            }
        };
        std::vector<std::vector<AnalyticEdgeSegment>> pending(source.loops.begin(), source.loops.end()), loops;
        bool changed = false;
        while (!pending.empty()) {
            std::vector<AnalyticEdgeSegment> loop = std::move(pending.back());
            pending.pop_back();
            bool split = false;
            for (std::size_t a = 0; a < loop.size() && !split; ++a)
                for (std::size_t b = a + 1; b < loop.size() && !split; ++b) {
                    if (!slit(loop[a], loop[b])) continue;
                    std::vector<AnalyticEdgeSegment> between(loop.begin() + std::ptrdiff_t(a + 1), loop.begin() + std::ptrdiff_t(b));
                    std::vector<AnalyticEdgeSegment> around(loop.begin() + std::ptrdiff_t(b + 1), loop.end());
                    around.insert(around.end(), loop.begin(), loop.begin() + std::ptrdiff_t(a));
                    if (!between.empty()) pending.push_back(std::move(between));
                    if (!around.empty()) pending.push_back(std::move(around));
                    split = changed = true;
                }
            if (!split) loops.push_back(std::move(loop));
        }
        if (!changed) return std::nullopt;
        AnalyticFacePatch result = source;
        // The source's order of loops kept as far as it goes: the loop holding the first segment first.
        std::reverse(loops.begin(), loops.end());
        result.loops = std::move(loops);
        return result;
    };
    try {
        TopoDS_Compound compound;
        BRep_Builder builder;
        builder.MakeCompound(compound);
        for (std::size_t faceIndex = 0; faceIndex < patches.size(); ++faceIndex) {
            currentFace = faceIndex;
            const std::optional<AnalyticFacePatch> unslit = withoutSlits(patches[faceIndex]);
            const auto& patch = unslit ? *unslit : patches[faceIndex];
            if (patch.loops.empty() && patch.kind != AnalyticFacePatch::Kind::Sphere && patch.kind != AnalyticFacePatch::Kind::Torus)
                return fail("Analytic face " + std::to_string(faceIndex) + " has no boundary");
            const gp_Ax3 frame(point(patch.origin), direction(patch.normal),
                               direction(patch.xAxis));
            TopoDS_Face face;
            // A face OCCT holds only as one face per turn round a periodic surface (splitSupportFace).
            std::vector<TopoDS_Face> turnFaces;
            std::vector<TopoDS_Wire> diagnosticWires;
            bool reversed = patch.reversed;
            if (patch.loops.empty() && patch.kind == AnalyticFacePatch::Kind::Torus &&
                (!isPositiveFinite(patch.majorRadius) || !isPositiveFinite(patch.minorRadius) || patch.majorRadius <= patch.minorRadius))
                return fail("A whole torus must have positive radii with major > minor");
            const bool explicitBoundary = std::any_of(patch.loops.begin(), patch.loops.end(), [](const auto& loop) {
                return std::any_of(loop.begin(), loop.end(), [](const auto& segment) { return segment.pcurve.has_value(); });
            });
            // The bounded cone path supplies the apex's degenerate edge analytically.
            // Generic wire healing cannot create it safely from a lone explicit ring.
            const bool coneTip = patch.kind == AnalyticFacePatch::Kind::Cone && patch.loops.size() == 1 &&
                patch.loops.front().size() == 1 && patch.loops.front().front().kind == AnalyticEdgeKind::Circle &&
                !patch.loops.front().front().hasEndpoints;
            if ((explicitBoundary && !coneTip) || patch.loops.empty()) {
                Handle(Geom_Surface) support;
                switch (patch.kind) {
                case AnalyticFacePatch::Kind::Plane: support = new Geom_Plane(frame); break;
                case AnalyticFacePatch::Kind::Cylinder: support = new Geom_CylindricalSurface(frame, patch.radius); break;
                case AnalyticFacePatch::Kind::Cone: support = new Geom_ConicalSurface(frame, patch.semiAngle, patch.radius); break;
                case AnalyticFacePatch::Kind::Sphere: support = new Geom_SphericalSurface(frame, patch.radius); break;
                case AnalyticFacePatch::Kind::Torus: support = new Geom_ToroidalSurface(frame, patch.majorRadius, patch.minorRadius); break;
                default: break;
                }
                if (!support.IsNull()) {
                    if (patch.loops.empty()) {
                        constexpr double pi = 3.14159265358979323846;
                        BRepBuilderAPI_MakeFace whole(support, 0, 2 * pi,
                            patch.kind == AnalyticFacePatch::Kind::Sphere ? -pi / 2 : 0,
                            patch.kind == AnalyticFacePatch::Kind::Sphere ? pi / 2 : 2 * pi, 1e-7);
                        if (whole.IsDone()) face = whole.Face();
                    } else {
                        face = trimmedSurfaceFace(support, patch);
                        if (face.IsNull()) return fail("Transferred UV boundary of analytic face " +
                            std::to_string(faceIndex) + ": " + trimDiagnostic);
                    }
                }
            }
            if (!face.IsNull()) {
                // Constructed directly from the transferred UV boundary or the whole periodic support.
            } else if (patch.kind == AnalyticFacePatch::Kind::Blend) {
                // Not a closed form: the kernel's own rational B-spline, within its measured
                // deviation of the rolling-ball definition, trimmed by the face's edges at that
                // deviation (and the source's own contact gap) instead of 1e-7.
                const rolling_ball::Blend* blend = blendOf(patch.blend);
                if (!blend) {
                    const auto found = patch.blend ? blends.find(patch.blend.get()) : blends.end();
                    return fail("Blend face " + std::to_string(faceIndex) + ": " +
                                (found != blends.end() && found->second ? found->second->error()
                                                                        : std::string("no definition")));
                }
                // Its edges are exact (or fitted to 1e-8) and the surface only near them: they may
                // be as far from it as the bound the approximation is held to, 1e-6 m. How far they
                // are is part of the face's deviation in the report.
                supportTolerance = 1e-6;
                largestSupportGap = 0.0;
                face = trimmedSurfaceFace(Handle(Geom_Surface)(blend->surface()), patch);
                if (face.IsNull() && (blend->surface()->IsUPeriodic() || blend->surface()->IsVPeriodic()))
                    face = trimmedSurfaceFace(splineWithSeamAway(blend->surface(),patch),patch);
                supportTolerance = 1e-7;
                if (face.IsNull())
                    return fail("Blend face " + std::to_string(faceIndex) +
                                " boundary does not fit its surface: " + trimDiagnostic);
                if (blend->faceSense() != 0) reversed = blend->faceSense() < 0;
                const double deviation = std::max(blend->deviation(), largestSupportGap);
                largestBlendGap = std::max(largestBlendGap, deviation + blend->contactGap());
                if (report)
                    report->approximated.push_back({faceIndex, deviation, blend->contactGap(), blend->sections()});
            } else if (patch.kind == AnalyticFacePatch::Kind::BSplineOffset) {
                // The signed offset depends on the control-grid orientation.
                // A transposed fallback could accept the opposite surface.
                if (!std::isfinite(patch.offsetDistance) ||
                    std::fabs(patch.offsetDistance) < 1e-12)
                    return fail("Invalid B-spline offset distance");
                const Handle(Geom_BSplineSurface) basis =
                    bsplineSurface(patch.bspline, 0);
                if (basis.IsNull())
                    return fail("Invalid B-spline offset support");
                const Handle(Geom_OffsetSurface) support =
                    new Geom_OffsetSurface(basis, patch.offsetDistance);
                face = trimmedSurfaceFace(support, patch);
                if (face.IsNull())
                    return fail("B-spline offset boundary does not match its exact support: " +
                                trimDiagnostic);
            } else if (patch.kind == AnalyticFacePatch::Kind::BSpline) {
                if (!std::isfinite(patch.approximationDeviation) || patch.approximationDeviation<0)
                    return fail("Invalid procedural surface deviation");
                supportTolerance=1e-7+patch.approximationDeviation;
                largestSupportGap=0;
                // XT stores a flat control grid. Validate each possible
                // stride against the transmitted 3D boundary before choosing.
                std::string strides;
                for (int ordering = 0; ordering < 2 && face.IsNull(); ++ordering) {
                    try {
                        const Handle(Geom_BSplineSurface) support =
                            bsplineSurface(patch.bspline, ordering);
                        if (support.IsNull())
                            return fail("Invalid B-spline surface definition");
                        face = trimmedSurfaceFace(support, patch);
                    } catch (const Standard_Failure&) {
                        // The second XT grid stride may still be valid.
                    }
                    if (face.IsNull())
                        strides += (ordering ? "; transposed: " : "as stored: ") + trimDiagnostic;
                }
                if (face.IsNull())
                    return fail("B-spline surface " + std::to_string(faceIndex) +
                                " boundary does not match its exact poles: " + strides);
                supportTolerance=1e-7;
                if (patch.approximationDeviation>0) {
                    const double deviation=std::max(patch.approximationDeviation,largestSupportGap);
                    largestBlendGap=std::max(largestBlendGap,deviation);
                    if (report) report->approximated.push_back({faceIndex,deviation,0,patch.bspline.vPoleCount});
                }
            } else if (patch.kind == AnalyticFacePatch::Kind::Swept) {
                // XT SWEPT_SURF, R(u, v) = C(u) + v·D: OCCT's surface of linear extrusion has the
                // same parametrisation. It is unbounded along D, so it is trimmed to a span that
                // surely holds the face: the boundary's extent along D less the section's, both
                // taken from bounds (a B-spline section lies in the hull of its poles).
                const AnalyticEdgeSegment& s = patch.section;
                const gp_Vec along(direction(patch.sweep));
                Handle(Geom_Curve) section;
                double sectionLow = 0.0, sectionHigh = 0.0;
                if (s.kind == AnalyticEdgeKind::Circle || s.kind == AnalyticEdgeKind::Ellipse) {
                    const gp_Ax2 axes(point(s.center), direction(s.normal), direction(s.xAxis));
                    const double major = s.kind == AnalyticEdgeKind::Circle ? s.radius : s.majorRadius;
                    const double minor = s.kind == AnalyticEdgeKind::Circle ? s.radius : s.minorRadius;
                    if (!isPositiveFinite(major) || !isPositiveFinite(minor))
                        return fail("Swept surface section has an invalid radius");
                    if (s.kind == AnalyticEdgeKind::Circle) section = new Geom_Circle(axes, major);
                    else section = new Geom_Ellipse(axes, major, minor);
                    const double reach = std::hypot(major * gp_Vec(axes.XDirection()).Dot(along),
                                                    minor * gp_Vec(axes.YDirection()).Dot(along));
                    const double middle = gp_Vec(point(s.center).XYZ()).Dot(along);
                    sectionLow = middle - reach;
                    sectionHigh = middle + reach;
                } else if (s.kind == AnalyticEdgeKind::BSpline) {
                    const auto& d = s.bspline;
                    const int count = int(d.poles.size()), knotCount = int(d.knots.size());
                    if (count < 2 || count != int(d.weights.size()) || knotCount < 2 ||
                        knotCount != int(d.multiplicities.size()) || d.degree < 1 || d.degree >= count)
                        return fail("Swept surface section has an invalid B-spline");
                    TColgp_Array1OfPnt poles(1, count);
                    TColStd_Array1OfReal weights(1, count), knots(1, knotCount);
                    TColStd_Array1OfInteger multiplicities(1, knotCount);
                    sectionLow = std::numeric_limits<double>::infinity();
                    sectionHigh = -std::numeric_limits<double>::infinity();
                    for (int i = 0; i < count; ++i) {
                        poles.SetValue(i + 1, point(d.poles[i]));
                        weights.SetValue(i + 1, d.weights[i]);
                        const double height = gp_Vec(point(d.poles[i]).XYZ()).Dot(along);
                        sectionLow = std::min(sectionLow, height);
                        sectionHigh = std::max(sectionHigh, height);
                    }
                    for (int i = 0; i < knotCount; ++i) {
                        knots.SetValue(i + 1, d.knots[i]);
                        multiplicities.SetValue(i + 1, d.multiplicities[i]);
                    }
                    section = new Geom_BSplineCurve(poles, weights, knots, multiplicities, d.degree, d.periodic);
                } else if (s.kind == AnalyticEdgeKind::Line) {
                    // A straight section across the sweep is a plane; kept for completeness, the
                    // line given by its point (center) and direction (normal).
                    const gp_Dir lineDirection = direction(s.normal);
                    if (std::fabs(gp_Vec(lineDirection).Dot(along)) > 1e-9)
                        return fail("Swept surface with a section along its sweep is degenerate");
                    section = new Geom_Line(point(s.center), lineDirection);
                    sectionLow = sectionHigh = gp_Vec(point(s.center).XYZ()).Dot(along);
                } else {
                    return fail("Swept surface section kind is not supported");
                }
                double boundaryLow = std::numeric_limits<double>::infinity();
                double boundaryHigh = -std::numeric_limits<double>::infinity();
                for (const auto& loop : patch.loops) {
                    for (const auto& segment : loop) {
                        const TopoDS_Edge edge = sourceBoundary(segment);
                        if (edge.IsNull()) return fail("Swept surface has an invalid boundary edge");
                        const BRepAdaptor_Curve curve(edge);
                        for (int sample = 0; sample <= 16; ++sample) {
                            const gp_Pnt at = curve.Value(curve.FirstParameter() +
                                (curve.LastParameter() - curve.FirstParameter()) * sample / 16.0);
                            const double height = gp_Vec(at.XYZ()).Dot(along);
                            boundaryLow = std::min(boundaryLow, height);
                            boundaryHigh = std::max(boundaryHigh, height);
                        }
                    }
                }
                double vMin = boundaryLow - sectionHigh, vMax = boundaryHigh - sectionLow;
                if (!std::isfinite(vMin) || !std::isfinite(vMax) || vMax - vMin <= 1e-12)
                    return fail("Swept surface has no extent along its sweep");
                // A generous margin: the support is larger than the face, which its edges trim anyway.
                const double margin = 0.1 * (vMax - vMin) + 1e-6;
                vMin -= margin;
                vMax += margin;
                const Handle(Geom_SurfaceOfLinearExtrusion) swept =
                    new Geom_SurfaceOfLinearExtrusion(section, gp_Dir(along));
                const Handle(Geom_RectangularTrimmedSurface) trimmed =
                    new Geom_RectangularTrimmedSurface(swept, vMin, vMax, false);
                face = trimmedSurfaceFace(Handle(Geom_Surface)(trimmed), patch);
                if (face.IsNull())
                    return fail("Swept surface face " + std::to_string(faceIndex) +
                                " boundary does not match its exact support: " + trimDiagnostic);
            } else if (patch.kind == AnalyticFacePatch::Kind::Cylinder) {
                if (!isPositiveFinite(patch.radius))
                    return fail("Analytic cylinder has invalid radius");
                const gp_Cylinder cylinder(frame, patch.radius);
                bool hasIntersection = false;
                for (const auto& loop : patch.loops)
                    for (const auto& segment : loop)
                        hasIntersection |= segment.kind ==
                            AnalyticEdgeKind::SurfaceIntersection ||
                            segment.kind == AnalyticEdgeKind::BlendBoundary ||
                            // a full ellipse: an oblique plane's ring, no box of parameters
                            (segment.kind == AnalyticEdgeKind::Ellipse && !segment.hasEndpoints);
                // B-spline edges (an XT written from an OCCT model carries its intersections so): the
                // general trimming first, the older trimmed-cylinder path below if it fails.
                for (const auto& loop : patch.loops)
                    for (const auto& segment : loop)
                        hasIntersection |= segment.kind == AnalyticEdgeKind::BSpline ||
                                           segment.kind == AnalyticEdgeKind::SurfaceCurve;
                // A bounded contour beside another loop needs trimming: a cylindrical face can
                // have a hole inside an arc-and-line boundary as well as an oblique elliptic end.
                // The parameter-band path below only handles complete circular end rings.
                if (patch.loops.size() > 1)
                    for (const auto& loop : patch.loops)
                        for (const auto& segment : loop)
                            hasIntersection |= segment.kind == AnalyticEdgeKind::Ellipse ||
                                               segment.kind == AnalyticEdgeKind::Line ||
                                               (segment.kind == AnalyticEdgeKind::Circle && segment.hasEndpoints);
                if (hasIntersection) {
                    face = trimmedSurfaceFace(cylinder, patch);
                    // A periodic seam through a hole can prevent ShapeFix from closing its
                    // wires. Move only the parameter seam; the cylinder geometry is unchanged.
                    const std::array<gp_Dir, 3> axes{frame.YDirection(),
                        frame.XDirection().Reversed(), frame.YDirection().Reversed()};
                    for (const auto& xAxis : axes) {
                        if (!face.IsNull()) break;
                        const gp_Cylinder candidate(
                            gp_Ax3(point(patch.origin), direction(patch.normal), xAxis), patch.radius);
                        face = trimmedSurfaceFace(candidate, patch);
                    }
                }
                if (face.IsNull()) {
                double vMin = std::numeric_limits<double>::infinity();
                double vMax = -std::numeric_limits<double>::infinity();
                bool fullCircle = false;
                bool foundArc = false;
                double uMin = 0.0, uMax = 0.0;
                for (const auto& loop : patch.loops) {
                    if (loop.empty()) return fail("Analytic cylinder has an empty loop");
                    for (const auto& segment : loop) {
                        if (segment.kind == AnalyticEdgeKind::Circle &&
                            !segment.hasEndpoints) {
                            fullCircle = true;
                            const gp_Vec offset(point(patch.origin), point(segment.center));
                            const double v = offset.Dot(gp_Vec(frame.Direction()));
                            vMin = std::min(vMin, v);
                            vMax = std::max(vMax, v);
                        } else if (segment.hasEndpoints) {
                            for (const auto& endpoint : {segment.start, segment.end}) {
                                const gp_Vec offset(point(patch.origin), point(endpoint));
                                const double v = offset.Dot(gp_Vec(frame.Direction()));
                                vMin = std::min(vMin, v);
                                vMax = std::max(vMax, v);
                            }
                        }
                        if (segment.kind != AnalyticEdgeKind::Circle ||
                            !segment.hasEndpoints || foundArc) continue;
                        const gp_Vec start(point(segment.center), point(segment.start));
                        const gp_Vec end(point(segment.center), point(segment.end));
                        const auto parameter = [&](const gp_Vec& vector) {
                            return std::atan2(vector.Dot(gp_Vec(frame.YDirection())),
                                              vector.Dot(gp_Vec(frame.XDirection())));
                        };
                        const double begin = parameter(start);
                        double finish = parameter(end);
                        const bool positive = segment.forward ==
                            (gp_Vec(direction(segment.normal)).Dot(
                                gp_Vec(frame.Direction())) > 0.0);
                        constexpr double turn = 2.0 * 3.14159265358979323846;
                        if (positive) {
                            while (finish <= begin) finish += turn;
                            uMin = begin;
                            uMax = finish;
                        } else {
                            while (finish >= begin) finish -= turn;
                            uMin = finish;
                            uMax = begin;
                        }
                        foundArc = true;
                    }
                }
                if (!fullCircle && !foundArc && patch.loops.size() == 1) {
                    // Keep a trimmed patch away from the periodic seam. An
                    // ellipse projected across U=0 otherwise acquires a
                    // discontinuous p-curve even though its 3D edge is sound.
                    gp_Vec radialSum(0, 0, 0);
                    for (const auto& segment : patch.loops.front()) {
                        for (const auto& endpoint : {segment.start, segment.end}) {
                            gp_Vec radial(point(patch.origin), point(endpoint));
                            radial -= gp_Vec(frame.Direction()) *
                                      radial.Dot(gp_Vec(frame.Direction()));
                            if (radial.Magnitude() > 1e-12)
                                radialSum += radial.Normalized();
                        }
                    }
                    const gp_Ax3 trimmedFrame = radialSum.Magnitude() > 1e-6
                        ? gp_Ax3(point(patch.origin), direction(patch.normal),
                                 gp_Dir(radialSum.Reversed()))
                        : frame;
                    const gp_Cylinder trimmedSupport(trimmedFrame, patch.radius);
                    BRepBuilderAPI_MakeFace surfaceMaker(trimmedSupport);
                    if (!surfaceMaker.IsDone())
                        return fail("Could not construct analytic cylinder surface");
                    const TopoDS_Face support = surfaceMaker.Face();
                    BRepBuilderAPI_MakeWire wireMaker;
                    ShapeFix_Edge edgeFixer;
                    for (const auto& segment : patch.loops.front()) {
                        TopoDS_Edge edge;
                        if (segment.kind == AnalyticEdgeKind::Line) {
                            BRepBuilderAPI_MakeEdge maker(point(segment.start),
                                                          point(segment.end));
                            if (!maker.IsDone())
                                return fail("Invalid trimmed cylinder line edge");
                            edge = maker.Edge();
                        } else if (segment.kind == AnalyticEdgeKind::Ellipse) {
                            if (!isPositiveFinite(segment.majorRadius) ||
                                !isPositiveFinite(segment.minorRadius) ||
                                segment.majorRadius < segment.minorRadius)
                                return fail("Invalid trimmed cylinder ellipse radii");
                            const gp_Ax2 ellipseFrame(point(segment.center),
                                direction(segment.normal), direction(segment.xAxis));
                            const gp_Elips ellipse(ellipseFrame, segment.majorRadius,
                                                   segment.minorRadius);
                            const auto parameter = [&](const cadnext::Vector3& endpoint) {
                                const gp_Vec offset(point(segment.center), point(endpoint));
                                return std::atan2(
                                    offset.Dot(gp_Vec(ellipseFrame.YDirection())) /
                                        segment.minorRadius,
                                    offset.Dot(gp_Vec(ellipseFrame.XDirection())) /
                                        segment.majorRadius);
                            };
                            const double begin = parameter(segment.start);
                            double end = parameter(segment.end);
                            constexpr double turn = 2.0 * 3.14159265358979323846;
                            if (segment.forward) {
                                while (end <= begin) end += turn;
                                BRepBuilderAPI_MakeEdge maker(ellipse, begin, end);
                                if (!maker.IsDone())
                                    return fail("Invalid trimmed cylinder ellipse edge");
                                edge = maker.Edge();
                            } else {
                                while (end >= begin) end -= turn;
                                BRepBuilderAPI_MakeEdge maker(ellipse, end, begin);
                                if (!maker.IsDone())
                                    return fail("Invalid trimmed cylinder ellipse edge");
                                edge = maker.Edge();
                                edge.Reverse();
                            }
                        } else if (segment.kind == AnalyticEdgeKind::BSpline ||
                                   segment.kind == AnalyticEdgeKind::BlendBoundary ||
                                   segment.kind == AnalyticEdgeKind::SurfaceCurve) {
                            // An intersection with another surface as its B-spline: how a
                            // Parasolid XT written from an OCCT model carries it.
                            edge = sourceBoundary(segment);
                            if (edge.IsNull())
                                return fail("Invalid trimmed cylinder B-spline edge");
                        } else {
                            return fail("Trimmed cylinder boundary has unsupported curve");
                        }
                        if (!edgeFixer.FixAddPCurve(edge, support, false, 1e-7))
                            return fail("Could not project trimmed cylinder edge onto surface");
                        edgeFixer.FixSameParameter(edge, 1e-7);
                        wireMaker.Add(edge);
                        if (!wireMaker.IsDone())
                            return fail("Trimmed cylinder has disconnected edges");
                    }
                    if (!wireMaker.IsDone() || !wireMaker.Wire().Closed())
                        return fail("Trimmed cylinder has an open wire");
                    const auto makeTrimmedFace = [&](const TopoDS_Wire& wire) {
                        BRepBuilderAPI_MakeFace maker(trimmedSupport, wire, false);
                        if (!maker.IsDone()) return TopoDS_Face{};
                        ShapeFix_Face fixer(maker.Face());
                        fixer.Perform();
                        fixer.FixOrientation();
                        return fixer.Result().ShapeType() == TopAbs_FACE
                            ? TopoDS::Face(fixer.Result()) : maker.Face();
                    };
                    TopoDS_Wire trimmedWire = wireMaker.Wire();
                    face = makeTrimmedFace(trimmedWire);
                    if (!face.IsNull() && !BRepCheck_Analyzer(face).IsValid()) {
                        trimmedWire.Reverse();
                        face = makeTrimmedFace(trimmedWire);
                    }
                    if (face.IsNull())
                        return fail("Could not construct trimmed cylinder face");
                } else {
                    if (fullCircle) {
                        uMin = 0.0;
                        uMax = 2.0 * 3.14159265358979323846;
                    } else if (!foundArc || patch.loops.size() != 1) {
                        return fail("Analytic cylinder face " + std::to_string(faceIndex) +
                                    " boundary is unsupported: loops=" +
                                    std::to_string(patch.loops.size()) +
                                    " foundArc=" + std::to_string(foundArc) +
                                    (trimDiagnostic.empty() ? std::string() : "; " + trimDiagnostic));
                    }
                    if (!std::isfinite(vMin) || !std::isfinite(vMax) ||
                        vMax - vMin <= 1e-10 || uMax - uMin <= 1e-10)
                        return fail("Analytic cylinder " + std::to_string(faceIndex) + " has degenerate bounds" +
                                    (trimDiagnostic.empty() ? std::string() : " (trim: " + trimDiagnostic + ")"));
                    BRepBuilderAPI_MakeFace maker(cylinder, uMin, uMax, vMin, vMax);
                    if (!maker.IsDone())
                        return fail("Could not construct analytic cylinder face " +
                                    std::to_string(faceIndex));
                    face = maker.Face();
                }
                }
                std::string cylinderBoundary;
                if (!boundaryMatches(face, patch, cylinderBoundary)) {
                    const std::array<gp_Dir, 4> axes{
                        frame.XDirection(), frame.YDirection(),
                        frame.XDirection().Reversed(), frame.YDirection().Reversed()};
                    bool trimmedOk = false;
                    for (const auto& xAxis : axes) {
                        const gp_Cylinder candidate(
                            gp_Ax3(point(patch.origin), direction(patch.normal), xAxis),
                            patch.radius);
                        TopoDS_Face trimmed = trimmedSurfaceFace(candidate, patch);
                        if (!trimmed.IsNull()) { face = trimmed; trimmedOk = true; break; }
                    }
                    if (!trimmedOk) {
                        const std::string trimmedWhy = trimDiagnostic;
                        turnFaces = splitSupportFace(new Geom_CylindricalSurface(cylinder), patch);
                        if (!turnFaces.empty()) face = turnFaces.front();
                        else trimDiagnostic = trimmedWhy + "; " + trimDiagnostic;
                    }
                }
            } else if (patch.kind == AnalyticFacePatch::Kind::Cone) {
                constexpr double turn = 2.0 * 3.14159265358979323846;
                if (!isPositiveFinite(patch.radius) || !std::isfinite(patch.semiAngle) ||
                    std::fabs(patch.semiAngle) <= 1e-10 ||
                    std::fabs(patch.semiAngle) >= 1.5707963267948966 - 1e-10) {
                    return fail("Analytic cone has invalid radius or semi-angle");
                }
                const double sine = std::sin(patch.semiAngle);
                const double cosine = std::cos(patch.semiAngle);
                if (std::fabs(cosine) <= 1e-10)
                    return fail("Analytic cone has an axial semi-angle");
                const gp_Cone cone(frame, patch.semiAngle, patch.radius);
                if (patch.loops.size() == 1 && patch.loops.front().size() == 4) {
                    const AnalyticEdgeSegment* firstCircle = nullptr;
                    int circleCount = 0;
                    int lineCount = 0;
                    for (const auto& segment : patch.loops.front()) {
                        if (segment.kind == AnalyticEdgeKind::Circle &&
                            segment.hasEndpoints) {
                            if (!firstCircle) firstCircle = &segment;
                            ++circleCount;
                        } else if (segment.kind == AnalyticEdgeKind::Line &&
                                   segment.hasEndpoints) {
                            ++lineCount;
                        }
                    }
                    if (circleCount == 2 && lineCount == 2) {
                        const auto coneUV = [&](const cadnext::Vector3& endpoint) {
                            const gp_Vec offset(point(patch.origin), point(endpoint));
                            const double axial = offset.Dot(gp_Vec(frame.Direction()));
                            const gp_Vec radial = offset - gp_Vec(frame.Direction()) * axial;
                            const double u = std::atan2(
                                radial.Dot(gp_Vec(frame.YDirection())),
                                radial.Dot(gp_Vec(frame.XDirection())));
                            return std::pair<double, double>{u, axial / cosine};
                        };
                        const auto firstStart = coneUV(firstCircle->start);
                        const auto firstEnd = coneUV(firstCircle->end);
                        double uMin = 0.0, uMax = 0.0;
                        double end = firstEnd.first;
                        const bool positive = firstCircle->forward ==
                            (gp_Vec(direction(firstCircle->normal)).Dot(
                                gp_Vec(frame.Direction())) > 0.0);
                        if (positive) {
                            while (end <= firstStart.first) end += turn;
                            uMin = firstStart.first;
                            uMax = end;
                        } else {
                            while (end >= firstStart.first) end -= turn;
                            uMin = end;
                            uMax = firstStart.first;
                        }
                        double vMin = std::numeric_limits<double>::infinity();
                        double vMax = -std::numeric_limits<double>::infinity();
                        for (const auto& segment : patch.loops.front()) {
                            if (segment.kind != AnalyticEdgeKind::Circle) continue;
                            const double v = coneUV(segment.start).second;
                            vMin = std::min(vMin, v);
                            vMax = std::max(vMax, v);
                        }
                        const auto sameAngle = [&](double a, double b) {
                            return std::fabs(std::remainder(a - b, turn)) < 1e-5;
                        };
                        const auto onEnd = [&](double value, double low, double high) {
                            return std::fabs(value - low) < 1e-7 ||
                                   std::fabs(value - high) < 1e-7;
                        };
                        bool consistent = uMax - uMin > 1e-10 &&
                            uMax - uMin < turn - 1e-10 && vMax - vMin > 1e-10;
                        for (const auto& segment : patch.loops.front()) {
                            const auto start = coneUV(segment.start);
                            const auto finish = coneUV(segment.end);
                            consistent = consistent &&
                                (sameAngle(start.first, uMin) ||
                                 sameAngle(start.first, uMax)) &&
                                (sameAngle(finish.first, uMin) ||
                                 sameAngle(finish.first, uMax)) &&
                                onEnd(start.second, vMin, vMax) &&
                                onEnd(finish.second, vMin, vMax) &&
                                (segment.kind == AnalyticEdgeKind::Line
                                    ? sameAngle(start.first, finish.first)
                                    : std::fabs(start.second-finish.second) < 1e-7);
                            if (segment.kind == AnalyticEdgeKind::Circle) {
                                const gp_Ax2 circleFrame(point(segment.center),
                                    direction(segment.normal), direction(segment.xAxis));
                                const auto parameter = [&](const cadnext::Vector3& endpoint) {
                                    const gp_Vec offset(point(segment.center), point(endpoint));
                                    return std::atan2(
                                        offset.Dot(gp_Vec(circleFrame.YDirection())),
                                        offset.Dot(gp_Vec(circleFrame.XDirection())));
                                };
                                const double begin = parameter(segment.start);
                                double finishAngle = parameter(segment.end);
                                if (segment.forward) {
                                    while (finishAngle <= begin) finishAngle += turn;
                                } else {
                                    while (finishAngle >= begin) finishAngle -= turn;
                                }
                                consistent = consistent &&
                                    std::fabs(std::fabs(finishAngle-begin) -
                                              (uMax-uMin)) < 1e-5;
                            }
                            for (const auto& endpoint : {segment.start, segment.end}) {
                                const gp_Vec offset(point(patch.origin), point(endpoint));
                                const double axial = offset.Dot(gp_Vec(frame.Direction()));
                                const gp_Vec radial = offset -
                                    gp_Vec(frame.Direction()) * axial;
                                const double expectedRadius = patch.radius +
                                    axial * sine / cosine;
                                consistent = consistent && expectedRadius > 0.0 &&
                                    std::fabs(radial.Magnitude()-expectedRadius) < 1e-7;
                            }
                        }
                        if (consistent) {
                            BRepBuilderAPI_MakeFace maker(cone, uMin, uMax, vMin, vMax);
                            if (maker.IsDone()) face = maker.Face();
                        }
                    }
                }
                // Loops of other than circles (a blend's contact ring): the general trimming.
                bool circles = true;
                for (const auto& loop : patch.loops)
                    for (const auto& candidate : loop)
                        circles = circles && candidate.kind == AnalyticEdgeKind::Circle;
                if (face.IsNull() && !circles) {
                    face = trimmedSurfaceFace(cone, patch);
                    if (face.IsNull()) {
                        const std::string trimmedWhy = trimDiagnostic;
                        turnFaces = splitSupportFace(new Geom_ConicalSurface(cone), patch);
                        if (turnFaces.empty())
                            return fail("Analytic cone face " + std::to_string(faceIndex) +
                                        " boundary does not match its exact support: " + trimmedWhy + "; " + trimDiagnostic);
                        face = turnFaces.front();
                    }
                }
                if (face.IsNull()) {
                    double vMin = std::numeric_limits<double>::infinity();
                    double vMax = -std::numeric_limits<double>::infinity();
                    for (const auto& loop : patch.loops) {
                        const AnalyticEdgeSegment* circle = nullptr;
                        for (const auto& candidate : loop) {
                            if (candidate.kind != AnalyticEdgeKind::Circle)
                                return fail("Analytic cone face " +
                                            std::to_string(faceIndex) +
                                            " requires circular boundary loops");
                            if (!circle) circle = &candidate;
                            else if (std::fabs(candidate.radius - circle->radius) > 1e-7 ||
                                     point(candidate.center).Distance(point(circle->center)) > 1e-7)
                                return fail("Analytic cone boundary changes radius");
                        }
                        if (!circle) return fail("Analytic cone has an empty boundary loop");
                        const auto& segment = *circle;
                        const gp_Vec offset(point(patch.origin), point(segment.center));
                        const double axial = offset.Dot(gp_Vec(frame.Direction()));
                        const double v = axial / cosine;
                        const double expectedRadius = patch.radius + v * sine;
                        if (!std::isfinite(v) || expectedRadius <= 0.0 ||
                            std::fabs(expectedRadius - segment.radius) > 1e-7) {
                            return fail("Analytic cone boundary is not on its surface");
                        }
                        vMin = std::min(vMin, v);
                        vMax = std::max(vMax, v);
                    }
                    if (patch.loops.size() == 1) {
                        const double apex = -patch.radius / sine;
                        vMin = std::min(vMin, apex);
                        vMax = std::max(vMax, apex);
                    }
                    if (!std::isfinite(vMin) || !std::isfinite(vMax) ||
                        vMax - vMin <= 1e-10)
                        return fail("Analytic cone has degenerate bounds");
                    BRepBuilderAPI_MakeFace maker(cone, 0.0, turn, vMin, vMax);
                    if (!maker.IsDone())
                        return fail("Could not construct analytic cone face " +
                                    std::to_string(faceIndex));
                    face = maker.Face();
                    // The band's boundary circle is one edge; the source may cut it into arcs at
                    // vertices other edges use: then the general trimming, as for a torus.
                    if (std::string unmatched; !boundaryMatches(face, patch, unmatched)) {
                        const TopoDS_Face trimmed = trimmedSurfaceFace(cone, patch);
                        if (!trimmed.IsNull()) face = trimmed;
                    }
                }
            } else if (patch.kind == AnalyticFacePatch::Kind::Sphere) {
                if (!isPositiveFinite(patch.radius))
                    return fail("Analytic sphere has invalid radius");
                // A sphere has no distinguished pole. Choose the pole from
                // the latitude boundary, which need not match XT's stored
                // surface frame (for example, a Y-normal cap on a Z-frame).
                const auto& firstLoop = patch.loops.front();
                if (firstLoop.empty() || firstLoop.front().kind != AnalyticEdgeKind::Circle)
                    return fail("Analytic sphere requires a circular boundary");
                if (patch.loops.size() == 1 && firstLoop.size() > 1) {
                    const TopoDS_Edge leadingEdge = sourceBoundary(firstLoop.front());
                    if (leadingEdge.IsNull())
                        return fail("Analytic sphere has an invalid first boundary edge");
                    const BRepAdaptor_Curve leadingCurve(leadingEdge);
                    const double middle = (leadingCurve.FirstParameter() +
                                           leadingCurve.LastParameter()) / 2.0;
                    gp_Pnt edgeMiddle;
                    gp_Vec tangent;
                    leadingCurve.D1(middle, edgeMiddle, tangent);
                    if (!firstLoop.front().forward) tangent.Reverse();
                    gp_Vec radial(point(patch.origin), edgeMiddle);
                    gp_Vec normal = radial;
                    if (patch.reversed) normal.Reverse();
                    const gp_Vec interior = normal.Crossed(tangent);
                    if (interior.Magnitude() < 1e-12)
                        return fail("Analytic sphere boundary has no interior direction");
                    radial += interior.Normalized() * (patch.radius * 1e-3);
                    radial.Normalize();
                    const gp_Pnt interiorProbe = point(patch.origin).Translated(
                        radial * patch.radius);
                    gp_Vec centroid(0, 0, 0);
                    for (const auto& segment : firstLoop) {
                        centroid += gp_Vec(point(patch.origin), point(segment.start));
                        centroid += gp_Vec(point(patch.origin), point(segment.end));
                    }
                    // The source's own frame first: the face is then parametrised as the source
                    // has it, and OCCT's integration over a sphere patch depends on the frame at
                    // about 1e-8 (the same corner patch: area 6.8e-9 apart in two frames), so a
                    // round trip reproduces its numbers only in the same frame.
                    std::vector<gp_Ax3> frames;
                    try {
                        frames.emplace_back(point(patch.origin), direction(patch.normal), direction(patch.xAxis));
                    } catch (const Standard_Failure&) {
                    }
                    std::vector<gp_Dir> poles;
                    if (centroid.Magnitude() > 1e-10)
                        poles.emplace_back(centroid);
                    poles.push_back(direction(patch.normal));
                    poles.push_back(direction(firstLoop.front().normal));
                    poles.emplace_back(gp_Vec(1, 0, 0));
                    poles.emplace_back(gp_Vec(0, 1, 0));
                    poles.emplace_back(gp_Vec(0, 0, 1));
                    for (const auto& pole : poles) frames.emplace_back(point(patch.origin), pole);
                    double smallestArea = std::numeric_limits<double>::infinity();
                    for (const auto& sphereFrame : frames) {
                        try {
                            const gp_Sphere trimmedSphere(sphereFrame, patch.radius);
                            BRepBuilderAPI_MakeFace supportMaker(trimmedSphere);
                            if (!supportMaker.IsDone()) continue;
                            const TopoDS_Face support = supportMaker.Face();
                            BRepBuilderAPI_MakeWire wireMaker;
                            ShapeFix_Edge fixer;
                            bool projected = true;
                            for (const auto& segment : firstLoop) {
                                TopoDS_Edge edge = sourceBoundary(segment);
                                if (edge.IsNull() ||
                                    !fixer.FixAddPCurve(edge, support, false, 1e-7)) {
                                    projected = false;
                                    break;
                                }
                                fixer.FixSameParameter(edge, 1e-7);
                                wireMaker.Add(edge);
                                if (!wireMaker.IsDone()) {
                                    projected = false;
                                    break;
                                }
                            }
                            if (!projected || !wireMaker.Wire().Closed()) continue;
                            BRepBuilderAPI_MakeFace maker(trimmedSphere,
                                                          wireMaker.Wire(), false);
                            if (!maker.IsDone()) continue;
                            ShapeFix_Face faceFixer(maker.Face());
                            faceFixer.Perform();
                            faceFixer.FixOrientation();
                            const TopoDS_Face candidate = faceFixer.Face();
                            std::string ignored;
                            if (BRepCheck_Analyzer(candidate).IsValid() &&
                                boundaryMatches(candidate, patch, ignored) &&
                                BRepClass_FaceClassifier(candidate, interiorProbe, 1e-7)
                                    .State() == TopAbs_IN) {
                                GProp_GProps properties;
                                BRepGProp::SurfaceProperties(candidate, properties);
                                // The smaller of two regions the arcs bound; areas within 1e-6
                                // are the same region, and the earlier frame is kept.
                                if (properties.Mass() > 0.0 &&
                                    properties.Mass() < smallestArea * (1.0 - 1e-6)) {
                                    smallestArea = properties.Mass();
                                    face = candidate;
                                }
                            }
                        } catch (const Standard_Failure&) {
                            // A pole or periodic seam may intersect this
                            // boundary. Try another analytic parameter frame.
                        }
                    }
                    // Arcs and intersections neither region of which the frames above take (an ACIS cap
                    // cut by a plane and two intersections): the general trimming, then the support
                    // split as for a cone.
                    if (face.IsNull()) {
                        const Handle(Geom_SphericalSurface) sphere = new Geom_SphericalSurface(frame, patch.radius);
                        face = trimmedSurfaceFace(sphere, patch);
                        if (face.IsNull()) {
                            const std::string trimmedWhy = trimDiagnostic;
                            turnFaces = splitSupportFace(sphere, patch);
                            if (turnFaces.empty())
                                return fail("Analytic sphere face " + std::to_string(faceIndex) +
                                            " could not be trimmed to its source arcs: " + trimmedWhy + "; " + trimDiagnostic);
                            face = turnFaces.front();
                        }
                    }
                } else {
                const gp_Ax3 sphereFrame(point(patch.origin),
                                         direction(firstLoop.front().normal));
                const gp_Sphere sphere(sphereFrame, patch.radius);
                constexpr double turn = 2.0 * 3.14159265358979323846;
                std::vector<double> angles;
                for (const auto& loop : patch.loops) {
                    const AnalyticEdgeSegment* circle = nullptr;
                    for (const auto& candidate : loop) {
                        if (candidate.kind != AnalyticEdgeKind::Circle) {
                            return fail("Analytic sphere currently requires circular boundary loops");
                        }
                        if (!circle) circle = &candidate;
                        else if (std::fabs(candidate.radius - circle->radius) > 1e-7 ||
                                 point(candidate.center).Distance(point(circle->center)) > 1e-7) {
                            return fail("Analytic sphere boundary changes latitude");
                        }
                    }
                    if (!circle) return fail("Analytic sphere has an empty boundary loop");
                    const auto& segment = *circle;
                    const gp_Vec offset(point(patch.origin), point(segment.center));
                    if (!direction(segment.normal).IsParallel(
                            sphereFrame.Direction(), 1e-7))
                        return fail("Analytic sphere boundary normals differ");
                    const double axial = offset.Dot(gp_Vec(sphereFrame.Direction()));
                    const gp_Vec radialOffset = offset -
                        gp_Vec(sphereFrame.Direction()) * axial;
                    const double radial = segment.radius;
                    const double residual = radial * radial + axial * axial -
                                            patch.radius * patch.radius;
                    if (!std::isfinite(residual) || std::fabs(residual) > 1e-7 ||
                        radialOffset.Magnitude() > 1e-7)
                        return fail("Analytic sphere face " + std::to_string(faceIndex) +
                                    " boundary is not on its surface: residual=" +
                                    std::to_string(residual));
                    angles.push_back(std::atan2(axial, radial));
                }
                if (angles.empty() || angles.size() > 2)
                    return fail("Analytic sphere has unsupported boundary count");
                double vMin = 0.0;
                double vMax = 0.0;
                if (angles.size() == 1) {
                    // One circle leaves two faces on the sphere, one on each side of it; which
                    // one this is follows from the loop's direction, as in the branch above, not
                    // from the latitude's sign. By the sign alone both halves of a sphere cut at
                    // its equator came out northern (flow-around-sphere-v3.x_t: a cavity of two
                    // coincident hemispheres, zero volume, and BRepCheck still valid), and the
                    // larger part of a sphere cut off the equator came out as the small cap.
                    const AnalyticEdgeSegment& boundary = firstLoop.front();
                    const TopoDS_Edge boundaryEdge = sourceBoundary(boundary);
                    if (boundaryEdge.IsNull())
                        return fail("Analytic sphere has an invalid boundary edge");
                    const BRepAdaptor_Curve boundaryCurve(boundaryEdge);
                    gp_Pnt onBoundary;
                    gp_Vec tangent;
                    boundaryCurve.D1(0.5 * (boundaryCurve.FirstParameter() +
                                            boundaryCurve.LastParameter()),
                                     onBoundary, tangent);
                    if (!boundary.forward) tangent.Reverse();
                    gp_Vec normal(point(patch.origin), onBoundary);
                    if (patch.reversed) normal.Reverse();
                    const double towardPole =
                        normal.Crossed(tangent).Dot(gp_Vec(sphereFrame.Direction()));
                    if (!std::isfinite(towardPole) ||
                        std::fabs(towardPole) <= 1e-12 * normal.Magnitude() * tangent.Magnitude())
                        return fail("Analytic sphere boundary has no interior direction");
                    if (towardPole > 0.0) {
                        vMin = angles.front();
                        vMax = 0.5 * 3.14159265358979323846;
                    } else {
                        vMin = -0.5 * 3.14159265358979323846;
                        vMax = angles.front();
                    }
                } else {
                    vMin = std::min(angles[0], angles[1]);
                    vMax = std::max(angles[0], angles[1]);
                }
                if (vMax - vMin <= 1e-10)
                    return fail("Analytic sphere has degenerate bounds");
                BRepBuilderAPI_MakeFace maker(sphere, 0.0, turn, vMin, vMax);
                if (!maker.IsDone())
                    return fail("Could not construct analytic sphere face " +
                                std::to_string(faceIndex));
                face = maker.Face();
                // A latitude the source splits into arcs (a band whose circles are two edges each):
                // the band's whole circles are not its edges, so the face is trimmed by the arcs
                // themselves on the same sphere. The boundary check below still decides.
                std::string band;
                if (!boundaryMatches(face, patch, band)) {
                    const Handle(Geom_SphericalSurface) arcs = new Geom_SphericalSurface(sphereFrame, patch.radius);
                    const TopoDS_Face trimmed = trimmedSurfaceFace(arcs, patch);
                    if (!trimmed.IsNull()) face = trimmed;
                }
                }
            } else if (patch.kind == AnalyticFacePatch::Kind::Torus &&
                       isPositiveFinite(patch.majorRadius) && isPositiveFinite(patch.minorRadius) &&
                       patch.majorRadius <= patch.minorRadius) {
                // An "apple" torus (0 < major <= minor), the outer part of a self-intersecting one:
                // what a corner blend with a radius above its axis offset leaves (the NIST MTC
                // cover has four). The parametric shortcuts below assume a doughnut; this face is
                // trimmed by its exact edges instead, with the same boundary check.
                const Handle(Geom_Surface) apple =
                    new Geom_ToroidalSurface(frame, patch.majorRadius, patch.minorRadius);
                face = trimmedSurfaceFace(apple, patch);
                if (face.IsNull())
                    return fail("Apple torus boundary does not match its exact support: " + trimDiagnostic);
            } else if (patch.kind == AnalyticFacePatch::Kind::Torus &&
                       std::isfinite(patch.majorRadius) && patch.majorRadius < 0.0 &&
                       isPositiveFinite(patch.minorRadius) && -patch.majorRadius < patch.minorRadius) {
                // A "lemon" torus (XT: a negative major radius a, |a| < minor b), the inner part of
                // a self-intersecting one: R(u, v) = C + (a + b·cos v)(cos u·X + sin u·Y) + b·sin v·A
                // where a + b·cos v >= 0 (a crowned wheel's tread is one). OCCT's torus has no
                // negative radius, so the support is that formula as it stands: the meridian's arc
                // between the two points on the axis, revolved; same parameters, same normal.
                const double reach = std::acos(-patch.majorRadius / patch.minorRadius);
                const gp_Ax2 meridian(frame.Location().Translated(gp_Vec(frame.XDirection()) * patch.majorRadius),
                                      frame.YDirection().Reversed(), frame.XDirection());
                const Handle(Geom_Curve) arc =
                    new Geom_TrimmedCurve(new Geom_Circle(meridian, patch.minorRadius), -reach, reach);
                const Handle(Geom_Surface) lemon =
                    new Geom_SurfaceOfRevolution(arc, gp_Ax1(frame.Location(), frame.Direction()));
                face = trimmedSurfaceFace(lemon, patch);
                if (face.IsNull())
                    return fail("Lemon torus boundary does not match its exact support: " + trimDiagnostic);
            } else if (patch.kind == AnalyticFacePatch::Kind::Torus) {
                if (!isPositiveFinite(patch.majorRadius) ||
                    !isPositiveFinite(patch.minorRadius) ||
                    patch.majorRadius <= patch.minorRadius) {
                    return fail("Analytic torus has invalid radii");
                }
                const gp_Torus torus(frame, patch.majorRadius, patch.minorRadius);
                constexpr double turn = 2.0 * 3.14159265358979323846;
                // Four circular arcs can bound an exact rectangular patch in
                // torus parameters: two meridians and two parallels.
                if (patch.loops.size() == 1 && patch.loops.front().size() == 4) {
                    const AnalyticEdgeSegment* meridian = nullptr;
                    const AnalyticEdgeSegment* parallel = nullptr;
                    int meridianCount = 0;
                    int parallelCount = 0;
                    for (const auto& segment : patch.loops.front()) {
                        if (segment.kind != AnalyticEdgeKind::Circle ||
                            !segment.hasEndpoints ||
                            point(segment.start).Distance(point(segment.end)) < 1e-10)
                            break;
                        const gp_Vec offset(point(patch.origin), point(segment.center));
                        const double axial = offset.Dot(gp_Vec(frame.Direction()));
                        const gp_Vec radial = offset - gp_Vec(frame.Direction()) * axial;
                        const double normalDot = std::fabs(gp_Vec(direction(segment.normal))
                            .Dot(gp_Vec(frame.Direction())));
                        if (normalDot < 1e-6 && std::fabs(axial) < 1e-7 &&
                            std::fabs(radial.Magnitude() - patch.majorRadius) < 1e-7 &&
                            std::fabs(segment.radius - patch.minorRadius) < 1e-7) {
                            if (!meridian) meridian = &segment;
                            ++meridianCount;
                        } else if (normalDot > 1.0 - 1e-6 &&
                                   radial.Magnitude() < 1e-7) {
                            const double cosine = (segment.radius - patch.majorRadius) /
                                                  patch.minorRadius;
                            const double sine = axial / patch.minorRadius;
                            if (std::fabs(cosine*cosine + sine*sine - 1.0) > 1e-5)
                                break;
                            if (!parallel) parallel = &segment;
                            ++parallelCount;
                        } else {
                            break;
                        }
                    }
                    if (meridianCount == 2 && parallelCount == 2) {
                        const auto torusUV = [&](const cadnext::Vector3& endpoint) {
                            const gp_Vec offset(point(patch.origin), point(endpoint));
                            const double axial = offset.Dot(gp_Vec(frame.Direction()));
                            const gp_Vec radial = offset - gp_Vec(frame.Direction()) * axial;
                            double u = std::atan2(radial.Dot(gp_Vec(frame.YDirection())),
                                                  radial.Dot(gp_Vec(frame.XDirection())));
                            double v = std::atan2(axial,
                                radial.Magnitude() - patch.majorRadius);
                            if (u < 0.0) u += turn;
                            if (v < 0.0) v += turn;
                            return std::pair<double, double>{u, v};
                        };
                        const auto circleSweep = [&](const AnalyticEdgeSegment& segment) {
                            const gp_Ax2 circleFrame(point(segment.center),
                                direction(segment.normal), direction(segment.xAxis));
                            const auto angle = [&](const cadnext::Vector3& endpoint) {
                                const gp_Vec offset(point(segment.center), point(endpoint));
                                return std::atan2(
                                    offset.Dot(gp_Vec(circleFrame.YDirection())),
                                    offset.Dot(gp_Vec(circleFrame.XDirection())));
                            };
                            const double start = angle(segment.start);
                            double end = angle(segment.end);
                            if (segment.forward) {
                                while (end <= start) end += turn;
                                return end - start;
                            }
                            while (end >= start) end -= turn;
                            return start - end;
                        };
                        const auto interval = [&](double start, double end, double sweep,
                                                  double& low, double& high) {
                            const double positive = std::fmod(end - start + turn, turn);
                            const double negative = turn - positive;
                            if (std::fabs(positive - sweep) < 1e-5) {
                                low = start; high = start + positive; return true;
                            }
                            if (std::fabs(negative - sweep) < 1e-5) {
                                low = end; high = end + negative; return true;
                            }
                            return false;
                        };
                        const auto uStart = torusUV(parallel->start);
                        const auto uEnd = torusUV(parallel->end);
                        const auto vStart = torusUV(meridian->start);
                        const auto vEnd = torusUV(meridian->end);
                        double uMin = 0.0, uMax = 0.0, vMin = 0.0, vMax = 0.0;
                        if (interval(uStart.first, uEnd.first, circleSweep(*parallel),
                                     uMin, uMax) &&
                            interval(vStart.second, vEnd.second, circleSweep(*meridian),
                                     vMin, vMax)) {
                            const auto sameAngle = [&](double a, double b) {
                                const double delta = std::remainder(a - b, turn);
                                return std::fabs(delta) < 1e-5;
                            };
                            const auto onEnd = [&](double value, double low, double high) {
                                return sameAngle(value, low) || sameAngle(value, high);
                            };
                            bool consistent = true;
                            for (const auto& segment : patch.loops.front()) {
                                const auto start = torusUV(segment.start);
                                const auto end = torusUV(segment.end);
                                const double normalDot = std::fabs(
                                    gp_Vec(direction(segment.normal)).Dot(
                                        gp_Vec(frame.Direction())));
                                const bool isMeridian = normalDot < 1e-6;
                                const double expectedSweep = isMeridian ? vMax-vMin : uMax-uMin;
                                consistent = consistent &&
                                    std::fabs(circleSweep(segment) - expectedSweep) < 1e-5 &&
                                    onEnd(start.first, uMin, uMax) &&
                                    onEnd(end.first, uMin, uMax) &&
                                    onEnd(start.second, vMin, vMax) &&
                                    onEnd(end.second, vMin, vMax) &&
                                    (isMeridian
                                        ? sameAngle(start.first, end.first)
                                        : sameAngle(start.second, end.second));
                                for (const auto& endpoint : {segment.start, segment.end}) {
                                    const gp_Vec vertex(point(patch.origin), point(endpoint));
                                    const double axial = vertex.Dot(gp_Vec(frame.Direction()));
                                    const gp_Vec radial = vertex -
                                        gp_Vec(frame.Direction()) * axial;
                                    consistent = consistent &&
                                        std::fabs(std::hypot(radial.Magnitude() -
                                            patch.majorRadius, axial) -
                                            patch.minorRadius) < 1e-7;
                                }
                            }
                            if (consistent) {
                                BRepBuilderAPI_MakeFace maker(torus, uMin, uMax, vMin, vMax);
                                if (maker.IsDone()) face = maker.Face();
                            }
                        }
                    }
                }
                // Two whole meridians (a pipe's elbow between two straight runs): the band of u
                // between them, all of v. Which of the two bands the face is, its loops' sense
                // tells: a face lies left of its loop seen from its normal, so at meridian u_i it
                // runs towards increasing u where (F × t)·∂u > 0 — F the face normal, t the loop's
                // direction there.
                if (face.IsNull() && patch.loops.size() == 2) {
                    double angles[2] = {0.0, 0.0};
                    int toward[2] = {0, 0};
                    bool meridians = true;
                    for (std::size_t i = 0; i < 2 && meridians; ++i) {
                        const auto& loop = patch.loops[i];
                        if (loop.empty() || loop.front().kind != AnalyticEdgeKind::Circle) {
                            meridians = false;
                            break;
                        }
                        const auto& segment = loop.front();
                        double sweep=0.0;
                        for (const auto& arc:loop) {
                            if (arc.kind!=AnalyticEdgeKind::Circle ||
                                point(arc.center).Distance(point(segment.center))>1e-7 ||
                                std::fabs(arc.radius-segment.radius)>1e-7 ||
                                std::fabs(direction(arc.normal).Dot(direction(segment.normal)))<1.0-1e-10 ||
                                (direction(arc.normal).Dot(direction(segment.normal))>0)!=(arc.forward==segment.forward)) {
                                meridians=false;break;
                            }
                            if (!arc.hasEndpoints || point(arc.start).Distance(point(arc.end))<1e-10) {
                                sweep+=turn;continue;
                            }
                            const gp_Ax2 circleFrame(point(arc.center),direction(arc.normal),direction(arc.xAxis));
                            const auto angle=[&](const cadnext::Vector3& endpoint) {
                                const gp_Vec offset(point(arc.center),point(endpoint));
                                return std::atan2(offset.Dot(gp_Vec(circleFrame.YDirection())),
                                                  offset.Dot(gp_Vec(circleFrame.XDirection())));
                            };
                            const double start=angle(arc.start);
                            double end=angle(arc.end);
                            if (arc.forward) {while(end<=start)end+=turn;sweep+=end-start;}
                            else {while(end>=start)end-=turn;sweep+=start-end;}
                        }
                        if (!meridians || std::fabs(sweep-turn)>1e-6) {meridians=false;break;}
                        const gp_Vec offset(point(patch.origin), point(segment.center));
                        const double axial = offset.Dot(gp_Vec(frame.Direction()));
                        const gp_Vec radial = offset - gp_Vec(frame.Direction()) * axial;
                        const gp_Vec normal(direction(segment.normal));
                        meridians = std::fabs(normal.Dot(gp_Vec(frame.Direction()))) < 1e-6 &&
                                    std::fabs(axial) < 1e-7 &&
                                    std::fabs(radial.Magnitude() - patch.majorRadius) < 1e-7 &&
                                    std::fabs(segment.radius - patch.minorRadius) < 1e-7;
                        if (!meridians) break;
                        const double u = std::atan2(radial.Dot(gp_Vec(frame.YDirection())),
                                                    radial.Dot(gp_Vec(frame.XDirection())));
                        const gp_Vec alongU = gp_Vec(frame.XDirection()) * -std::sin(u) +
                                              gp_Vec(frame.YDirection()) * std::cos(u);
                        const gp_Vec out(direction(segment.xAxis)); // centre to a point of the loop
                        gp_Vec tangent = normal.Crossed(out);
                        if (!segment.forward) tangent.Reverse();
                        const gp_Vec faceNormal = reversed ? out.Reversed() : out;
                        const double side = faceNormal.Crossed(tangent).Dot(alongU);
                        angles[i] = u;
                        toward[i] = side > 0.0 ? 1 : side < 0.0 ? -1 : 0;
                    }
                    if (meridians && toward[0] != 0 && toward[0] == -toward[1]) {
                        double uMin = angles[0], uMax = angles[1];
                        if (toward[0] > 0) {
                            while (uMax <= uMin) uMax += turn;
                            while (uMax - uMin > turn) uMax -= turn;
                        } else {
                            uMax = angles[0];
                            uMin = angles[1];
                            while (uMin >= uMax) uMin -= turn;
                            while (uMax - uMin > turn) uMin += turn;
                        }
                        BRepBuilderAPI_MakeFace maker(torus, uMin, uMax, 0.0, turn);
                        if (maker.IsDone()) face = maker.Face();
                    }
                }
                // Loops of latitude circles only make a band of the torus; any other edge (one
                // across a blend) is left to the general trimming below.
                bool latitudes = true;
                for (const auto& loop : patch.loops)
                    for (const auto& candidate : loop) {
                        if(candidate.kind!=AnalyticEdgeKind::Circle) {latitudes=false;continue;}
                        const gp_Vec offset(point(patch.origin),point(candidate.center));
                        const double axial=offset.Dot(gp_Vec(frame.Direction()));
                        latitudes=latitudes &&
                            std::fabs(direction(candidate.normal).Dot(frame.Direction()))>1.0-1e-6 &&
                            (offset-gp_Vec(frame.Direction())*axial).Magnitude()<1e-7;
                    }
                if (face.IsNull() && latitudes) {
                    std::vector<double> angles;
                    for (const auto& loop : patch.loops) {
                        const AnalyticEdgeSegment* circle = nullptr;
                        for (const auto& candidate : loop) {
                            if (candidate.kind != AnalyticEdgeKind::Circle)
                                return fail("Analytic torus currently requires circular boundary loops");
                            if (!circle) circle = &candidate;
                            else if (std::fabs(candidate.radius - circle->radius) > 1e-7 ||
                                     point(candidate.center).Distance(point(circle->center)) > 1e-7)
                                return fail("Analytic torus face " +
                                            std::to_string(faceIndex) +
                                            " boundary changes latitude");
                        }
                        if (!circle) return fail("Analytic torus has an empty boundary loop");
                        const auto& segment = *circle;
                        const gp_Vec offset(point(patch.origin), point(segment.center));
                        const double axial = offset.Dot(gp_Vec(frame.Direction()));
                        // A constant-v torus parameter is represented in XT by
                        // a circle centred on the torus axis. Its circle radius
                        // is the distance from that axis; the circle centre only
                        // carries the axial offset.
                        const double radial = segment.radius;
                        const double cosine = (radial - patch.majorRadius) /
                                              patch.minorRadius;
                        const double sine = axial / patch.minorRadius;
                        const double residual = cosine * cosine + sine * sine - 1.0;
                    if (!std::isfinite(cosine) || !std::isfinite(sine) ||
                        std::fabs(residual) > 1e-5) {
                            return fail("Analytic torus face " +
                                        std::to_string(faceIndex) +
                                        " boundary is not on its surface");
                        }
                        double angle = std::atan2(sine, cosine);
                        if (angle < 0.0) angle += turn;
                        angles.push_back(angle);
                    }
                    if (angles.size() < 2)
                        return fail("Analytic torus has too few boundary loops");
                    double vMin = 0.0;
                    double vMax = 0.0;
                    if (angles.size() == 2) {
                        const double forward = std::fmod(angles[1] - angles[0] + turn, turn);
                        const double backward = turn - forward;
                        if (forward <= 1e-10 || backward <= 1e-10)
                            return fail("Analytic torus has coincident boundary loops");
                        if (forward <= backward) {
                            vMin = angles[0];
                            vMax = angles[0] + forward;
                        } else {
                            vMin = angles[1];
                            vMax = angles[1] + backward;
                        }
                    } else {
                        vMin = *std::min_element(angles.begin(), angles.end());
                        vMax = *std::max_element(angles.begin(), angles.end());
                    }
                    if (vMax - vMin <= 1e-10 || vMax - vMin >= turn - 1e-10)
                        return fail("Analytic torus has degenerate bounds");
                    BRepBuilderAPI_MakeFace maker(torus, 0.0, turn, vMin, vMax);
                    if (!maker.IsDone())
                        return fail("Could not construct analytic torus face " +
                                    std::to_string(faceIndex));
                    face = maker.Face();
                }
                std::string torusBoundary;
                if (!boundaryMatches(face, patch, torusBoundary)) {
                    const std::array<gp_Dir, 4> axes{
                        frame.XDirection(), frame.YDirection(),
                        frame.XDirection().Reversed(), frame.YDirection().Reversed()};
                    for (const auto& xAxis : axes) {
                        const gp_Torus candidate(
                            gp_Ax3(point(patch.origin), direction(patch.normal), xAxis),
                            patch.majorRadius, patch.minorRadius);
                        TopoDS_Face trimmed = trimmedSurfaceFace(candidate, patch);
                        if (!trimmed.IsNull()) { face = trimmed; break; }
                    }
                }
            } else {
                const gp_Pln plane(frame);
                // A tolerant segment (ACIS: exact to its resabs, a vertex off the curve within it): the
                // edge ends at the source's vertices, their tolerance covering the gap to the curve's
                // ends, so that the next edge, built from the same vertex, meets it.
                const auto atSourceVertices = [&](const TopoDS_Edge& edge, const AnalyticEdgeSegment& segment) {
                    // (A curve in the surface's parameters, or a blend's contact, ends at its vertices already
                    // and holds its 2D curve, which a rebuild from the 3D curve would lose.)
                    if (!segment.hasEndpoints || !std::isfinite(segment.tolerance) || segment.tolerance <= 0.0 ||
                        segment.kind == AnalyticEdgeKind::SurfaceCurve || segment.kind == AnalyticEdgeKind::BlendBoundary ||
                        point(segment.start).Distance(point(segment.end)) < 1e-10)
                        return edge;
                    double first = 0.0, last = 0.0;
                    const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
                    if (curve.IsNull()) return edge;
                    const bool backwards = edge.Orientation() == TopAbs_REVERSED;
                    const gp_Pnt atFirst = point(backwards ? segment.end : segment.start);
                    const gp_Pnt atLast = point(backwards ? segment.start : segment.end);
                    const double gap = std::max(curve->Value(first).Distance(atFirst), curve->Value(last).Distance(atLast));
                    if (gap > 2.0 * segment.tolerance) return edge;
                    const double tolerance = std::max(1e-7, 1.01 * gap);
                    BRep_Builder vertices;
                    TopoDS_Vertex v1, v2;
                    vertices.MakeVertex(v1, atFirst, tolerance);
                    vertices.MakeVertex(v2, atLast, tolerance);
                    BRepBuilderAPI_MakeEdge maker(curve, v1, v2, first, last);
                    if (!maker.IsDone()) return edge;
                    TopoDS_Edge rebuilt = maker.Edge();
                    if (backwards) rebuilt.Reverse();
                    return rebuilt;
                };
                std::vector<TopoDS_Wire> wires;
                wires.reserve(patch.loops.size());
                for (const auto& loop : patch.loops) {
                    BRepBuilderAPI_MakeWire wireMaker;
                    for (const auto& segment : loop) {
                        TopoDS_Edge edge;
                        if (segment.kind == AnalyticEdgeKind::Line) {
                            BRepBuilderAPI_MakeEdge maker(point(segment.start),
                                                          point(segment.end));
                            if (!maker.IsDone()) return fail("Invalid analytic line edge");
                            edge = maker.Edge();
                        } else if (segment.kind == AnalyticEdgeKind::Circle) {
                            if (!isPositiveFinite(segment.radius))
                                return fail("Invalid analytic circle radius");
                            const gp_Ax2 circleFrame(point(segment.center),
                                direction(segment.normal), direction(segment.xAxis));
                            const gp_Circ circle(circleFrame, segment.radius);
                            if (!segment.hasEndpoints ||
                                point(segment.start).Distance(point(segment.end)) < 1e-10) {
                                BRepBuilderAPI_MakeEdge maker(circle);
                                if (!maker.IsDone()) return fail("Invalid full circle edge");
                                edge = maker.Edge();
                                if (!segment.forward) edge.Reverse();
                            } else {
                                const gp_Vec from(point(segment.center), point(segment.start));
                                const gp_Vec to(point(segment.center), point(segment.end));
                                const auto angle = [&](const gp_Vec& v) {
                                    return std::atan2(v.Dot(gp_Vec(circleFrame.YDirection())),
                                                      v.Dot(gp_Vec(circleFrame.XDirection())));
                                };
                                const double start = angle(from);
                                double end = angle(to);
                                constexpr double turn = 2.0 * 3.14159265358979323846;
                                if (segment.forward) {
                                    while (end <= start) end += turn;
                                    BRepBuilderAPI_MakeEdge maker(circle, start, end);
                                    if (!maker.IsDone()) return fail("Invalid circular arc edge");
                                    edge = maker.Edge();
                                } else {
                                    while (end >= start) end -= turn;
                                    BRepBuilderAPI_MakeEdge maker(circle, end, start);
                                    if (!maker.IsDone()) return fail("Invalid circular arc edge");
                                    edge = maker.Edge();
                                    edge.Reverse();
                                }
                            }
                        } else if (segment.kind == AnalyticEdgeKind::Ellipse) {
                            if (!isPositiveFinite(segment.majorRadius) ||
                                !isPositiveFinite(segment.minorRadius) ||
                                segment.majorRadius < segment.minorRadius)
                                return fail("Invalid analytic ellipse radii");
                            const gp_Ax2 ellipseFrame(point(segment.center),
                                direction(segment.normal), direction(segment.xAxis));
                            const gp_Elips ellipse(ellipseFrame, segment.majorRadius,
                                                   segment.minorRadius);
                            if (!segment.hasEndpoints ||
                                point(segment.start).Distance(point(segment.end)) < 1e-10) {
                                BRepBuilderAPI_MakeEdge maker(ellipse);
                                if (!maker.IsDone()) return fail("Invalid full ellipse edge");
                                edge = maker.Edge();
                                if (!segment.forward) edge.Reverse();
                            } else {
                                const gp_Vec from(point(segment.center), point(segment.start));
                                const gp_Vec to(point(segment.center), point(segment.end));
                                const auto angle = [&](const gp_Vec& v) {
                                    return std::atan2(v.Dot(gp_Vec(ellipseFrame.YDirection())) /
                                                          segment.minorRadius,
                                                      v.Dot(gp_Vec(ellipseFrame.XDirection())) /
                                                          segment.majorRadius);
                                };
                                const double start = angle(from);
                                double end = angle(to);
                                constexpr double turn = 2.0 * 3.14159265358979323846;
                                if (segment.forward) {
                                    while (end <= start) end += turn;
                                    BRepBuilderAPI_MakeEdge maker(ellipse, start, end);
                                    if (!maker.IsDone()) return fail("Invalid elliptical arc edge");
                                    edge = maker.Edge();
                                } else {
                                    while (end >= start) end -= turn;
                                    BRepBuilderAPI_MakeEdge maker(ellipse, end, start);
                                    if (!maker.IsDone()) return fail("Invalid elliptical arc edge");
                                    edge = maker.Edge();
                                    edge.Reverse();
                                }
                            }
                        } else {
                            edge = sourceBoundary(segment);
                            if (edge.IsNull())
                                return fail("Could not construct intersection edge of plane face " +
                                            std::to_string(faceIndex) + " (kind " +
                                            std::to_string(int(segment.kind)) + (blendDiagnostic.empty()
                                                ? std::string(")") : "; " + blendDiagnostic + ")"));
                        }
                        edge = atSourceVertices(edge, segment);
                        wireMaker.Add(edge);
                        if (!wireMaker.IsDone())
                            return fail("Analytic face " + std::to_string(faceIndex) +
                                        " has disconnected edges");
                    }
                    if (!wireMaker.IsDone() || !wireMaker.Wire().Closed())
                        return fail("Analytic face " + std::to_string(faceIndex) +
                                    " has an open wire");
                    wires.push_back(wireMaker.Wire());
                }
                // Loops touching at a point (a hole touching the boundary: KOMPAS C3D) share their
                // vertex there, as OCCT requires of a valid face; built apart, each has its own.
                if (wires.size() > 1) {
                    std::vector<TopoDS_Vertex> kept;
                    Handle(BRepTools_ReShape) shared = new BRepTools_ReShape;
                    bool changed = false;
                    for (std::size_t w = 0; w < wires.size(); ++w) {
                        TopTools_IndexedMapOfShape own;
                        TopExp::MapShapes(wires[w], TopAbs_VERTEX, own);
                        std::vector<TopoDS_Vertex> mine;
                        for (int k = 1; k <= own.Extent(); ++k) {
                            const TopoDS_Vertex vertex = TopoDS::Vertex(own(k));
                            const gp_Pnt at = BRep_Tool::Pnt(vertex);
                            for (const TopoDS_Vertex& other : kept) {
                                const double reach = std::max(BRep_Tool::Tolerance(vertex), BRep_Tool::Tolerance(other));
                                if (BRep_Tool::Pnt(other).Distance(at) <= reach) {
                                    shared->Replace(vertex.Oriented(TopAbs_FORWARD), other.Oriented(TopAbs_FORWARD));
                                    changed = true;
                                    break;
                                }
                            }
                            mine.push_back(vertex);
                        }
                        kept.insert(kept.end(), mine.begin(), mine.end());
                    }
                    if (changed)
                        for (auto& wire : wires) wire = TopoDS::Wire(shared->Apply(wire));
                }
                // XT does not require the exterior loop to precede hole loops.
                // Select the widest loop before handing the remaining wires to
                // OCCT; a full circular hole may have no explicit vertices.
                std::size_t outer = 0;
                double outerSpan = -1.0;
                for (std::size_t i = 0; i < wires.size(); ++i) {
                    Bnd_Box bounds;
                    BRepBndLib::Add(wires[i], bounds);
                    double x0, y0, z0, x1, y1, z1;
                    bounds.Get(x0, y0, z0, x1, y1, z1);
                    const double span = (x1-x0)*(x1-x0) +
                                        (y1-y0)*(y1-y0) +
                                        (z1-z0)*(z1-z0);
                    if (span > outerSpan) { outer = i; outerSpan = span; }
                }
                BRepBuilderAPI_MakeFace maker(plane, wires[outer], true);
                if (!maker.IsDone())
                    return fail("Could not construct analytic plane face " +
                                std::to_string(faceIndex));
                for (std::size_t loopIndex = 0; loopIndex < wires.size(); ++loopIndex)
                    if (loopIndex != outer) maker.Add(wires[loopIndex]);
                if (!maker.IsDone())
                    return fail("Could not trim analytic plane face " +
                                std::to_string(faceIndex));
                face = maker.Face();
                diagnosticWires = wires;
                if (std::any_of(patch.loops.begin(), patch.loops.end(), [](const auto& loop) {
                        return std::any_of(loop.begin(), loop.end(), [](const AnalyticEdgeSegment& segment) {
                            return segment.kind == AnalyticEdgeKind::SurfaceCurve;
                        });
                    })) {
                    // A plane with tolerant edges (curves in its parameters): the wires as given, or
                    // where OCCT finds that face invalid, the general trimming, which projects every
                    // edge onto the plane and orders and orients the loops itself.
                    TopoDS_Face given = face;
                    if (patch.loops.size() > 1) {
                        ShapeFix_Face fixer(given);
                        fixer.FixOrientation();
                        given = fixer.Face();
                    }
                    if (!BRepCheck_Analyzer(given).IsValid()) {
                        const TopoDS_Face trimmed = trimmedSurfaceFace(Handle(Geom_Surface)(new Geom_Plane(frame)), patch);
                        if (trimmed.IsNull())
                            return fail("Plane face " + std::to_string(faceIndex) + " with tolerant edges: " + trimDiagnostic);
                        face = trimmed;
                    }
                }
            }
            if (turnFaces.size() > 1) {
                if (report) report->split.push_back({faceIndex, int(turnFaces.size())});
                // Their boundary was checked together; each is to be a valid face.
                for (TopoDS_Face turn : turnFaces) {
                    if (reversed) turn.Reverse();
                    if (!BRepCheck_Analyzer(turn).IsValid())
                        return fail("Analytic face " + std::to_string(faceIndex) + ": a turn of it is invalid");
                    builder.Add(compound, turn);
                }
                continue;
            }
            if (patch.kind == AnalyticFacePatch::Kind::Plane && patch.loops.size() > 1) {
                ShapeFix_Face fixer(face);
                fixer.FixOrientation();
                face = fixer.Face();
            }
            if (reversed) face.Reverse();
            if (face.IsNull())
                return fail("Analytic face " + std::to_string(faceIndex) + " is null" +
                            (trimDiagnostic.empty() ? std::string() : "; trim: " + trimDiagnostic));
            // Tolerant edges (an ACIS model is exact only to its resabs: a vertex off a face's surface
            // within it): where the face comes out invalid, each edge takes as its tolerance how far it
            // lies off the face's surface — up to the largest its segments declare, never more.
            if (double allowed = 0.0; !BRepCheck_Analyzer(face).IsValid()) {
                for (const auto& loop : patch.loops)
                    for (const auto& segment : loop)
                        if (std::isfinite(segment.tolerance)) allowed = std::max(allowed, segment.tolerance);
                if (allowed > 0.0) {
                    BRep_Builder toleranceBuilder;
                    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
                        const TopoDS_Edge edge = TopoDS::Edge(e.Current());
                        double off = 0.0;
                        try {
                            const BRepAdaptor_Curve along(edge), onFace(edge, face);
                            for (int i = 0; i <= 16; ++i) {
                                const double t = along.FirstParameter() + (along.LastParameter() - along.FirstParameter()) * i / 16;
                                off = std::max(off, along.Value(t).Distance(onFace.Value(t)));
                            }
                        } catch (const Standard_Failure&) {
                            continue;
                        }
                        if (off <= BRep_Tool::Tolerance(edge) || off > allowed) continue;
                        toleranceBuilder.UpdateEdge(edge, 1.01 * off);
                        for (TopExp_Explorer v(edge, TopAbs_VERTEX); v.More(); v.Next())
                            if (BRep_Tool::Tolerance(TopoDS::Vertex(v.Current())) < 1.01 * off)
                                toleranceBuilder.UpdateVertex(TopoDS::Vertex(v.Current()), 1.01 * off);
                    }
                }
            }
            BRepCheck_Analyzer faceAnalyzer(face);
            if (!faceAnalyzer.IsValid()) {
                const char* kindName = patch.kind == AnalyticFacePatch::Kind::Plane ? "plane" :
                    patch.kind == AnalyticFacePatch::Kind::Cylinder ? "cylinder" :
                    patch.kind == AnalyticFacePatch::Kind::Cone ? "cone" :
                    patch.kind == AnalyticFacePatch::Kind::Sphere ? "sphere" :
                    patch.kind == AnalyticFacePatch::Kind::Torus ? "torus" :
                    patch.kind == AnalyticFacePatch::Kind::Swept ? "swept" :
                    patch.kind == AnalyticFacePatch::Kind::Blend ? "blend" : "b-spline";
                std::string detail;
                try {
                    const auto& faceResult = faceAnalyzer.Result(face);
                    if (!faceResult.IsNull()) {
                        for (const auto status : faceResult->Status()) {
                            if (status == BRepCheck_NoError) continue;
                            detail += " face:" + std::to_string(static_cast<int>(status));
                        }
                    }
                } catch (const Standard_Failure&) {
                }
                for (std::size_t wireIndex = 0; wireIndex < diagnosticWires.size(); ++wireIndex) {
                    try {
                        const auto& result = faceAnalyzer.Result(diagnosticWires[wireIndex]);
                        if (result.IsNull()) continue;
                        for (const auto status : result->Status()) {
                            if (status == BRepCheck_NoError) continue;
                            detail += " w" + std::to_string(wireIndex) + ":" +
                                      std::to_string(static_cast<int>(status));
                        }
                    } catch (const Standard_Failure&) {
                    }
                }
                return fail("Analytic face " + std::to_string(faceIndex) + " (" + kindName +
                            ") is invalid" + detail);
            }
            std::string boundaryDetail;
            if (!boundaryMatches(face, patch, boundaryDetail))
                return fail("Analytic face " + std::to_string(faceIndex) +
                            " kind=" + std::to_string(static_cast<int>(patch.kind)) +
                            " loops=" + std::to_string(patch.loops.size()) +
                            " trim=" + trimDiagnostic +
                            " does not preserve its source boundary: " + boundaryDetail);
            builder.Add(compound, face);
        }
        // Edges across a blend end as near their vertices as the blend is to its definition.
        currentFace = std::numeric_limits<std::size_t>::max(); // past the faces: the shell as a whole
        double sewingTolerance = 1.0e-7;
        for (const auto& [definition, blend] : blends)
            if (blend && !blend->surface().IsNull())
                sewingTolerance = std::max(sewingTolerance, 1.0e-7 + blend->tolerance());
        sewingTolerance = std::max(sewingTolerance, 1.0e-7 + largestBlendGap);
        sewingTolerance = std::max(sewingTolerance, 1.0e-7 + 2.0 * largestEdgeTolerance);
        if (report) report->largestEdgeTolerance = largestEdgeTolerance;
        const bool transferredUv = std::any_of(patches.begin(), patches.end(), [](const auto& patch) {
            return std::any_of(patch.loops.begin(), patch.loops.end(), [](const auto& loop) {
                return std::any_of(loop.begin(), loop.end(), [](const auto& edge) {
                    return edge.pcurve.has_value();
                });
            });
        });
        BoundarySewing sewing(sewingTolerance, transferredUv);
        sewing.Add(compound);
        sewing.Perform();
        TopoDS_Shape sewed = sewing.SewedShape();
        if (wholePeriodic && !sewed.IsNull() && sewed.ShapeType() == TopAbs_FACE) {
            TopoDS_Shell shell;
            builder.MakeShell(shell);
            builder.Add(shell, sewed);
            shell.Closed(true);
            sewed = shell;
        }
        if (sewed.IsNull() || sewing.NbFreeEdges() || sewing.NbMultipleEdges()) {
            std::ostringstream detail;
            detail.precision(12);
            for (int i = 1; i <= std::min(sewing.NbFreeEdges(), 2); ++i) {
                try {
                    const BRepAdaptor_Curve curve(sewing.FreeEdge(i));
                    detail << "; free edge " << i;
                    for (const double t : {curve.FirstParameter(),
                                          (curve.FirstParameter() + curve.LastParameter()) / 2,
                                          curve.LastParameter()}) {
                        const gp_Pnt p = curve.Value(t);
                        detail << " (" << p.X() << "," << p.Y() << "," << p.Z() << ")";
                    }
                } catch (const Standard_Failure&) {
                }
            }
            return fail("Analytic faces do not form a closed shell: " +
                        std::to_string(sewing.NbFreeEdges()) + " free edges, " +
                        std::to_string(sewing.NbMultipleEdges()) + " multiple edges" + detail.str());
        }
        // Sewing merges the vertices its faces' edges end at into one, placed between them: 2.55e-8 m
        // off the file's vertex at a corner of NIST ctc_02, where an edge on an apple torus ended a
        // little apart. Each goes back to the source's vertex nearest it, when that lies within the
        // vertex's own tolerance; the tolerance then covers every edge's end there.
        {
            std::vector<gp_Pnt> sourceVertices;
            for (const auto& patch : patches)
                for (const auto& loop : patch.loops)
                    for (const auto& segment : loop)
                        if (segment.hasEndpoints) {
                            sourceVertices.push_back(point(segment.start));
                            sourceVertices.push_back(point(segment.end));
                        }
            TopTools_IndexedDataMapOfShapeListOfShape vertexEdges;
            TopExp::MapShapesAndAncestors(sewed, TopAbs_VERTEX, TopAbs_EDGE, vertexEdges);
            BRep_Builder vertexBuilder;
            for (int i = 1; i <= vertexEdges.Extent(); ++i) {
                const TopoDS_Vertex vertex = TopoDS::Vertex(vertexEdges.FindKey(i));
                const gp_Pnt at = BRep_Tool::Pnt(vertex);
                double tolerance = BRep_Tool::Tolerance(vertex), nearest = std::numeric_limits<double>::infinity();
                gp_Pnt source;
                for (const gp_Pnt& candidate : sourceVertices)
                    if (const double d = candidate.Distance(at); d < nearest) {
                        nearest = d;
                        source = candidate;
                    }
                if (!(nearest > 0.0) || nearest > tolerance) continue;
                for (TopTools_ListIteratorOfListOfShape e(vertexEdges(i)); e.More(); e.Next()) {
                    const TopoDS_Edge edge = TopoDS::Edge(e.Value());
                    if (BRep_Tool::Degenerated(edge)) continue;
                    const BRepAdaptor_Curve curve(edge);
                    tolerance = std::max(tolerance,
                                         curve.Value(BRep_Tool::Parameter(vertex, edge)).Distance(source) + 1e-12);
                }
                vertexBuilder.UpdateVertex(vertex, source, tolerance);
            }
        }
        std::vector<TopoDS_Shell> shells;
        if (sewed.ShapeType() == TopAbs_SHELL) {
            shells.push_back(TopoDS::Shell(sewed));
        } else {
            for (TopExp_Explorer it(sewed, TopAbs_SHELL); it.More(); it.Next())
                shells.push_back(TopoDS::Shell(it.Current()));
            if (shells.empty()) return fail("No analytic shell was assembled");
        }
        // Every face built is sewn in: one per patch, or one per turn of a face winding round.
        std::size_t sewnFaces = 0, builtFaces = 0;
        for (TopExp_Explorer it(sewed, TopAbs_FACE); it.More(); it.Next()) ++sewnFaces;
        for (TopExp_Explorer it(compound, TopAbs_FACE); it.More(); it.Next()) ++builtFaces;
        if (sewnFaces != builtFaces) return fail("Analytic shell is incomplete");
        // Procedural supports can reverse their parameter frame relative to ACIS. Once sewn,
        // shared edges determine each face's orientation independently of that frame. Orient
        // neighbours together without changing the faces, curves or the shell's membership.
        for (TopoDS_Shell& shell : shells) {
            ShapeFix_Shell orient(shell);
            orient.FixFaceOrientation(shell, false, false);
            TopoDS_Shell fixed=orient.Shell();
            int orientedShells=orient.NbShells();
            int errors=0;
            for (TopExp_Explorer f(orient.ErrorFaces(),TopAbs_FACE);f.More();f.Next()) ++errors;
            if (fixed.IsNull() || orientedShells!=1 || errors) {
                std::string why;
                if (!reconnectTouchingEdges(shell,why))
                    return fail("Analytic shell has inconsistent face orientations: "+why);
                // Init() retains ShapeFix's error compound; use a fresh fixer after reconnecting.
                ShapeFix_Shell retried(shell);
                retried.FixFaceOrientation(shell,false,false);
                fixed=retried.Shell(); orientedShells=retried.NbShells(); errors=0;
                for (TopExp_Explorer f(retried.ErrorFaces(),TopAbs_FACE);f.More();f.Next()) ++errors;
            }
            if (fixed.IsNull() || orientedShells!=1 || errors)
                return fail("Analytic shell has inconsistent face orientations: "+std::to_string(orientedShells)+
                            " shells, "+std::to_string(errors)+" unoriented faces");
            int before=0,after=0;
            for (TopExp_Explorer f(shell,TopAbs_FACE);f.More();f.Next()) ++before;
            for (TopExp_Explorer f(fixed,TopAbs_FACE);f.More();f.Next()) ++after;
            if (before!=after) return fail("Orienting the analytic shell changed its face count");
            shell=fixed;
        }
        for (const TopoDS_Shell& shell : shells)
            if (!BRep_Tool::IsClosed(shell)) return fail("Analytic shell is incomplete");
        // One closed shell is one solid. Several are what a Parasolid solid body holds when it has
        // cavities (a fluid domain around an obstacle) or several lumps: ordered by containment,
        // a shell at even depth bounds matter and the shells directly inside it are its cavities.
        const auto alone = [](const TopoDS_Shell& shell) {
            BRepBuilderAPI_MakeSolid maker(shell);
            TopoDS_Solid solid = maker.Solid();
            BRepLib::OrientClosedSolid(solid);
            return solid;
        };
        std::vector<TopoDS_Solid> enclosed;
        for (const TopoDS_Shell& shell : shells) enclosed.push_back(alone(shell));
        const auto inside = [&](std::size_t inner, std::size_t outer) {
            TopExp_Explorer vertex(shells[inner], TopAbs_VERTEX);
            gp_Pnt probe;
            if (vertex.More()) {
                probe = BRep_Tool::Pnt(TopoDS::Vertex(vertex.Current()));
            } else {
                // A shell without vertices (a sphere, a torus): a point of one of its faces.
                TopExp_Explorer face(shells[inner], TopAbs_FACE);
                BRepAdaptor_Surface surface(TopoDS::Face(face.Current()));
                probe = surface.Value(0.5 * (surface.FirstUParameter() + surface.LastUParameter()),
                                      0.5 * (surface.FirstVParameter() + surface.LastVParameter()));
            }
            BRepClass3d_SolidClassifier classifier(enclosed[outer], probe, 1.0e-7);
            return classifier.State() == TopAbs_IN;
        };
        std::vector<int> depth(shells.size(), 0);
        std::vector<int> parent(shells.size(), -1);
        for (std::size_t i = 0; i < shells.size(); ++i) {
            for (std::size_t j = 0; j < shells.size(); ++j) {
                if (i == j || !inside(i, j)) continue;
                ++depth[i];
                // The direct container is the one that is itself deepest.
                if (parent[i] < 0 || inside(j, std::size_t(parent[i]))) parent[i] = int(j);
            }
        }
        std::vector<TopoDS_Solid> solids;
        for (std::size_t i = 0; i < shells.size(); ++i) {
            if (depth[i] % 2 != 0) continue;
            BRepBuilderAPI_MakeSolid maker(shells[i]);
            for (std::size_t j = 0; j < shells.size(); ++j) {
                if (parent[j] != int(i) || depth[j] != depth[i] + 1) continue;
                // A hole's faces turn their normals into it, away from the material: taken alone, it
                // encloses a negative volume. Turned so where it came out the other way (a KOMPAS C3D screw's
                // conical cavity: without it OCCT's check calls it an enclosed region, not a hole).
                TopoDS_Shell hole = shells[j];
                try {
                    BRepBuilderAPI_MakeSolid alone(hole);
                    if (alone.IsDone()) {
                        GProp_GProps enclosed;
                        BRepGProp::VolumeProperties(alone.Solid(), enclosed);
                        if (enclosed.Mass() > 0.0) hole.Reverse();
                    }
                } catch (const Standard_Failure&) {
                }
                maker.Add(hole);
            }
            if (!maker.IsDone()) return fail("Could not make an analytic solid");
            TopoDS_Solid solid = maker.Solid();
            if (!BRepLib::OrientClosedSolid(solid))
                return fail("Resulting analytic solid could not be oriented");
            if (const BRepCheck_Analyzer check(solid); !check.IsValid()) {
                // Which of it, its shells, faces, wires, edges and vertices fail, and how (BRepCheck_Status
                // values: 35 EnclosedRegion, 28 NotClosed, …), for the diagnosis.
                std::string detail;
                try {
                    TopTools_IndexedMapOfShape faces;
                    TopExp::MapShapes(solid, TopAbs_FACE, faces);
                    int shown = 0;
                    for (TopAbs_ShapeEnum kind : {TopAbs_SOLID, TopAbs_SHELL, TopAbs_FACE, TopAbs_WIRE, TopAbs_EDGE, TopAbs_VERTEX}) {
                        const bool whole = kind == TopAbs_SOLID;
                        for (TopExp_Explorer it(solid, kind); (whole || it.More()) && shown < 12; whole ? void() : it.Next()) {
                            const TopoDS_Shape current = whole ? TopoDS_Shape(solid) : it.Current();
                            const auto& result = check.Result(current);
                            if (result.IsNull()) continue;
                            std::string statuses;
                            for (const auto status : result->Status())
                                if (status != BRepCheck_NoError) statuses += " " + std::to_string(int(status));
                            result->InitContextIterator();
                            for (; result->MoreShapeInContext(); result->NextShapeInContext())
                                for (const auto status : result->StatusOnShape())
                                    if (status != BRepCheck_NoError) statuses += " /" + std::to_string(int(status));
                            if (statuses.empty()) {
                                if (whole) break;
                                continue;
                            }
                            static const char* names[] = {"compound", "compsolid", "solid", "shell", "face", "wire", "edge", "vertex"};
                            detail += std::string("; ") + names[int(kind)] + statuses;
                            if (kind == TopAbs_EDGE) {
                                TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
                                TopExp::MapShapesAndAncestors(solid, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
                                if (edgeFaces.Contains(current))
                                    for (TopTools_ListIteratorOfListOfShape f(edgeFaces.FindFromKey(current)); f.More(); f.Next())
                                        detail += " (face " + std::to_string(faces.FindIndex(f.Value())) + ")";
                                char tolerance[48];
                                std::snprintf(tolerance, sizeof tolerance, " tol %.2g", BRep_Tool::Tolerance(TopoDS::Edge(current)));
                                detail += tolerance;
                            }
                            ++shown;
                            if (whole) break;
                        }
                    }
                } catch (const Standard_Failure&) {
                }
                detail += "; shells " + std::to_string(shells.size()) + ":";
                for (std::size_t k = 0; k < shells.size(); ++k) {
                    int count = 0;
                    for (TopExp_Explorer f(shells[k], TopAbs_FACE); f.More(); f.Next()) ++count;
                    detail += " " + std::to_string(count) + " faces (depth " + std::to_string(depth[k]) + ")";
                }
                return fail("Resulting analytic solid failed BRep validation" + detail);
            }
            GProp_GProps properties;
            BRepGProp::VolumeProperties(solid, properties);
            if (!std::isfinite(properties.Mass()) || properties.Mass() <= 0.0)
                return fail("Resulting analytic solid has no positive volume");
            solids.push_back(solid);
        }
        if (solids.empty()) return fail("Could not make an analytic solid");
        if (solids.size() == 1)
            return cadnext::Result<ShapeHandle>::ok(
                impl_->store(solids.front(), "occt-analytic-solid"));
        TopoDS_Compound lumps;
        builder.MakeCompound(lumps);
        for (const TopoDS_Solid& solid : solids) builder.Add(lumps, solid);
        return cadnext::Result<ShapeHandle>::ok(
            impl_->store(lumps, "occt-analytic-solid"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT analytic solid construction failed: ") +
                 failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::transformShape(
    const ShapeHandle& handle, const std::array<double, 16>& m) {
    const TopoDS_Shape* original = findShape(handle);
    if (!original || original->IsNull()) return cadnext::Result<ShapeHandle>::fail(
        {cadnext::ErrorCode::ShapeInvalid, "Unknown shape for instance transform"});
    for (double value : m)
        if (!std::isfinite(value)) return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::InvalidArgument, "Instance transform is not finite"});
    const auto dotColumns = [&](int a, int b) {
        return m[a] * m[b] + m[a+1] * m[b+1] + m[a+2] * m[b+2];
    };
    if (std::fabs(m[3]) > 1e-9 || std::fabs(m[7]) > 1e-9 ||
        std::fabs(m[11]) > 1e-9 || std::fabs(m[15] - 1.0) > 1e-9 ||
        std::fabs(dotColumns(0, 0) - 1.0) > 1e-6 ||
        std::fabs(dotColumns(4, 4) - 1.0) > 1e-6 ||
        std::fabs(dotColumns(8, 8) - 1.0) > 1e-6 ||
        std::fabs(dotColumns(0, 4)) > 1e-6 ||
        std::fabs(dotColumns(0, 8)) > 1e-6 ||
        std::fabs(dotColumns(4, 8)) > 1e-6)
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::InvalidArgument,
             "Instance transform must be a rigid affine matrix"});
    try {
        gp_Trsf placement;
        placement.SetValues(m[0], m[4], m[8], m[12],
                            m[1], m[5], m[9], m[13],
                            m[2], m[6], m[10], m[14]);
        BRepBuilderAPI_Transform transform(*original, placement, true);
        if (!transform.IsDone() || transform.Shape().IsNull() ||
            !BRepCheck_Analyzer(transform.Shape()).IsValid())
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::ShapeInvalid,
                 "Transformed instance is not a valid BRep"});
        return cadnext::Result<ShapeHandle>::ok(
            impl_->store(transform.Shape(), "occt-instance"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT instance transform failed: ") +
                 failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeRevolvedProfile(
    const RevolvedProfileParameters& params) {
    if ((!params.isCircle && params.edges.empty() && params.loop.size() < 3) ||
        (params.isCircle && !isPositiveFinite(params.circleRadius)) ||
        !std::isfinite(params.angleDegrees) || params.angleDegrees <= 0.0 ||
        params.angleDegrees > 360.0) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::InvalidArgument, "Invalid revolve profile or angle"});
    }
    try {
        TopoDS_Face face;
        if (params.isCircle) {
            const gp_Ax2 frame(gp_Pnt(params.circleCenter.x, params.circleCenter.y,
                                      params.circleCenter.z),
                               gp_Dir(params.circleNormal.x, params.circleNormal.y,
                                      params.circleNormal.z));
            const gp_Circ circle(frame, params.circleRadius);
            BRepBuilderAPI_MakeWire wire(BRepBuilderAPI_MakeEdge(circle).Edge());
            BRepBuilderAPI_MakeFace maker(wire.Wire());
            if (!maker.IsDone()) {
                return cadnext::Result<ShapeHandle>::fail(
                    {cadnext::ErrorCode::KernelOperationFailed, "Circle face construction failed"});
            }
            face = maker.Face();
        } else if (!params.edges.empty()) {
            TopoDS_Wire wire;
            if (!makeExactProfileWire(params.edges, wire))
                return cadnext::Result<ShapeHandle>::fail({
                    cadnext::ErrorCode::ShapeInvalid, "Revolve profile is not a closed exact wire"});
            BRepBuilderAPI_MakeFace maker(wire);
            if (!maker.IsDone() || !BRepCheck_Analyzer(maker.Face()).IsValid())
                return cadnext::Result<ShapeHandle>::fail({
                    cadnext::ErrorCode::ShapeInvalid, "Curved revolve face is invalid"});
            face = maker.Face();
        } else {
            BRepBuilderAPI_MakePolygon polygon;
            for (const auto& p : params.loop) polygon.Add(gp_Pnt(p.x, p.y, p.z));
            polygon.Close();
            BRepBuilderAPI_MakeFace maker(polygon.Wire());
            if (!maker.IsDone()) {
                return cadnext::Result<ShapeHandle>::fail(
                    {cadnext::ErrorCode::KernelOperationFailed, "Profile face construction failed"});
            }
            face = maker.Face();
        }
        const gp_Ax1 axis(gp_Pnt(params.axisOrigin.x, params.axisOrigin.y,
                                 params.axisOrigin.z),
                          gp_Dir(params.axisDirection.x, params.axisDirection.y,
                                 params.axisDirection.z));
        const double radians = params.angleDegrees * M_PI / 180.0;
        BRepPrimAPI_MakeRevol maker(face, axis, radians);
        maker.Build();
        if (!maker.IsDone() || maker.Shape().IsNull() ||
            !BRepCheck_Analyzer(maker.Shape()).IsValid()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "Revolve produced invalid geometry"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(maker.Shape(), "occt-revolve"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT revolve failed: ") + failure.GetMessageString()});
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

cadnext::Result<std::vector<std::uint8_t>> OcctKernel::exportBRepGeometry(const ShapeHandle& handle) {
    const TopoDS_Shape* shape = findShape(handle);
    if (!shape || shape->IsNull()) {
        return cadnext::Result<std::vector<std::uint8_t>>::fail(
            {cadnext::ErrorCode::ShapeInvalid, "Shape not found for BRep export"});
    }
    try {
        std::ostringstream oss;
        // The one-argument Write also writes any triangulation the viewer attached.
        BRepTools::Write(*shape, oss, Standard_False, Standard_False, TopTools_FormatVersion_CURRENT);
        const std::string text = oss.str();
        return cadnext::Result<std::vector<std::uint8_t>>::ok(
            std::vector<std::uint8_t>(text.begin(), text.end()));
    } catch (const Standard_Failure& e) {
        return cadnext::Result<std::vector<std::uint8_t>>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("BRep export failed: ") + e.GetMessageString()});
    }
}

cadnext::Result<std::vector<std::uint8_t>> OcctKernel::exportFreeCadBRep(
    const ExchangeBody& body) {
    const TopoDS_Shape* shape = findShape(body.shape);
    if (!shape || shape->IsNull()) {
        return cadnext::Result<std::vector<std::uint8_t>>::fail(
            {cadnext::ErrorCode::ShapeInvalid, "Shape not found for FreeCAD export"});
    }
    try {
        const TopoDS_Shape inMillimetres =
            scaledShape(placedShape(*shape, body.placement), 1000.0);
        std::ostringstream output;
        BRepTools::Write(inMillimetres, output, Standard_False, Standard_False,
                         TopTools_FormatVersion_CURRENT);
        const std::string serialized = output.str();
        if (serialized.empty()) {
            return cadnext::Result<std::vector<std::uint8_t>>::fail(
                {cadnext::ErrorCode::SerializationFailed, "FreeCAD BRep export was empty"});
        }
        return cadnext::Result<std::vector<std::uint8_t>>::ok(
            std::vector<std::uint8_t>(serialized.begin(), serialized.end()));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<std::vector<std::uint8_t>>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("FreeCAD BRep export failed: ") + failure.GetMessageString()});
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

cadnext::Result<ShapeHandle> OcctKernel::importFreeCadBRep(
    const std::vector<std::uint8_t>& brepData, bool binary) {
    if (brepData.empty()) return cadnext::Result<ShapeHandle>::fail(
        {cadnext::ErrorCode::InvalidArgument, "FreeCAD BRep is empty"});
    try {
        TopoDS_Shape shape;
        const std::string payload(brepData.begin(), brepData.end());
        std::istringstream stream(payload);
        if (binary) {
            BinTools::Read(shape, stream);
        } else {
            BRep_Builder builder;
            BRepTools::Read(shape, stream, builder);
        }
        if (shape.IsNull()) return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::ShapeInvalid, "FreeCAD BRep is empty"});
        return cadnext::Result<ShapeHandle>::ok(
            impl_->store(scaledShape(shape, 0.001), "occt-freecad"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::SerializationFailed,
             std::string("FreeCAD BRep import failed: ") + failure.GetMessageString()});
    }
}

const TopoDS_Shape* OcctKernel::findShape(const ShapeHandle& handle) const {
    if (handle.isNull()) {
        return nullptr;
    }
    const auto it = impl_->shapes.find(handle.id());
    return it == impl_->shapes.end() ? nullptr : &it->second;
}

ShapeHandle OcctKernel::adoptShape(const TopoDS_Shape& shape, const char* prefix) {
    return impl_->store(shape, prefix);
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

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedCurvedProfile(
    const ExtrudedCurvedProfileParameters&) {
    return unavailable("OCCT curved profile extrude");
}

cadnext::Result<ShapeHandle> OcctKernel::makePlanarFaceCompound(
    const std::vector<PlanarFacePatch>&) {
    return unavailable("OCCT planar faces");
}

cadnext::Result<ShapeHandle> OcctKernel::makePlanarSolid(
    const std::vector<PlanarFacePatch>&) {
    return unavailable("OCCT planar solid");
}

cadnext::Result<ShapeHandle> OcctKernel::makeAnalyticSolid(
    const std::vector<AnalyticFacePatch>&, AnalyticSolidReport*) {
    return unavailable("OCCT analytic solid");
}

cadnext::Result<ShapeHandle> OcctKernel::transformShape(
    const ShapeHandle&, const std::array<double, 16>&) {
    return unavailable("OCCT instance transform");
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedCircle(const ExtrudedCircleParameters&) {
    return unavailable("OCCT circle extrude");
}

cadnext::Result<ShapeHandle> OcctKernel::makeRevolvedProfile(const RevolvedProfileParameters&) {
    return unavailable("OCCT revolve");
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

cadnext::Result<std::vector<std::uint8_t>> OcctKernel::exportBRepGeometry(const ShapeHandle& handle) {
    return exportBRep(handle);
}

cadnext::Result<ShapeHandle> OcctKernel::importBRep(const std::vector<std::uint8_t>&) {
    return unavailable("OCCT BRep import");
}

cadnext::Result<ShapeHandle> OcctKernel::importFreeCadBRep(
    const std::vector<std::uint8_t>&, bool) {
    return unavailable("FreeCAD BRep import");
}

cadnext::Result<ShapeHandle> OcctKernel::placeExchangeBody(const ExchangeBody&) {
    return unavailable("CAD body placement");
}

cadnext::Result<std::vector<std::uint8_t>> OcctKernel::exportFreeCadBRep(
    const ExchangeBody&) {
    return cadnext::Result<std::vector<std::uint8_t>>::fail({
        cadnext::ErrorCode::KernelUnavailable,
        "FreeCAD BRep export requires an OCCT-enabled build"
    });
}

cadnext::Result<ShapeHandle> OcctKernel::importExchangeFile(const std::string&) {
    return unavailable("CAD exchange import");
}

cadnext::Result<bool> OcctKernel::exportExchangeFile(
    const std::vector<ExchangeBody>&, const std::string&) {
    return cadnext::Result<bool>::fail({cadnext::ErrorCode::KernelUnavailable,
                                       "CAD exchange export requires OCCT"});
}

cadnext::Result<std::vector<ImportedExchangeBody>> OcctKernel::importStepAssembly(
    const std::string&) {
    return cadnext::Result<std::vector<ImportedExchangeBody>>::fail(
        {cadnext::ErrorCode::KernelUnavailable, "STEP assembly import requires OCCT"});
}

cadnext::Result<bool> OcctKernel::exportStepAssembly(
    const std::vector<NamedExchangeBody>&, const std::string&) {
    return cadnext::Result<bool>::fail(
        {cadnext::ErrorCode::KernelUnavailable, "STEP assembly export requires OCCT"});
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
