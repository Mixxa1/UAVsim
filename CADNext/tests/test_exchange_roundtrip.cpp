// Every CAD format with both a writer and a reader, through its public APIs. These checks always
// run, without downloaded samples. The same placed solids must survive: number, volume, area,
// centre of mass and bounds. DXF sketch geometry is compared separately in both encodings.
#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/bridge/UAVPartReader.hpp"
#include "cadnext/bridge/UAVPartWriter.hpp"
#include "cadnext/gui/AcisSatWriter.hpp"
#include "cadnext/gui/DwgWriter.hpp"
#include "cadnext/gui/NativeAcisSat.hpp"
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/gui/NativeDxfImport.hpp"
#include "cadnext/gui/ParasolidXtProduct.hpp"
#include "cadnext/gui/ParasolidXtWriter.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/ExactBRepDescription.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"

#include <BRep_Builder.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRep_Tool.hxx>
#include <BRepBndLib.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_NurbsConvert.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <Geom_BezierCurve.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_BSplineSurface.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <Geom_Circle.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <Geom2d_Line.hxx>
#include <Geom2d_Circle.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <TColgp_Array1OfPnt2d.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <GeomConvert.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS.hxx>
#include <gp_Elips.hxx>
#include <gp_Pln.hxx>

#include <QCoreApplication>
#include <QFile>
#include <QProcess>
#include <QTemporaryDir>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <functional>
#include <limits>

using namespace cadnext;
using namespace cadnext::kernel;
using namespace cadnext::gui;

namespace {
int failures = 0;
constexpr double pi = 3.14159265358979323846;
void check(bool ok, const std::string& label) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", label.c_str());
    failures += !ok;
}

TopoDS_Shape together(OcctKernel& kernel, const std::vector<ShapeHandle>& shapes) {
    BRep_Builder builder; TopoDS_Compound compound; builder.MakeCompound(compound);
    for (const auto& shape : shapes) builder.Add(compound, *kernel.findShape(shape));
    return compound;
}

struct Measurements {
    int solids = 0;
    double volume = 0.0, area = 0.0;
    gp_Pnt centre;
    std::array<double, 6> bounds{};
};
Measurements measure(const TopoDS_Shape& shape) {
    Measurements m;
    TopTools_IndexedMapOfShape solids; TopExp::MapShapes(shape, TopAbs_SOLID, solids); m.solids = solids.Extent();
    GProp_GProps volume, area;
    // Rational NURBS need adaptive integration: the default quadrature can differ by 1e-4
    // between two exact parameterisations of the same cylinder.
    BRepGProp::VolumeProperties(shape, volume, 1e-12);
    BRepGProp::SurfaceProperties(shape, area, 1e-12);
    m.volume = volume.Mass(); m.area = area.Mass(); m.centre = volume.CentreOfMass();
    Bnd_Box bounds; BRepBndLib::AddOptimal(shape, bounds, false, false);
    bounds.Get(m.bounds[0], m.bounds[1], m.bounds[2], m.bounds[3], m.bounds[4], m.bounds[5]);
    return m;
}

void compare(OcctKernel& kernel, const std::vector<ShapeHandle>& restored, const Measurements& expected,
             const std::string& format, double relative = 1e-8,
             const std::vector<Measurements>& expectedParts = {}) {
    if (restored.empty()) { check(false, format + ": no restored solids"); return; }
    const auto compound = together(kernel, restored);
    const auto actual = measure(compound);
    double bounds = 0.0;
    for (std::size_t i=0; i<6; ++i) bounds=std::max(bounds, std::fabs(actual.bounds[i]-expected.bounds[i]));
    const double dv = std::fabs(actual.volume-expected.volume)/expected.volume;
    const double da = std::fabs(actual.area-expected.area)/expected.area;
    const double dc = actual.centre.Distance(expected.centre);
    char metrics[256];
    std::snprintf(metrics, sizeof metrics, ": %d solids; volume %.3g, area %.3g relative; centre %.3g m, bounds %.3g m",
                  actual.solids, dv, da, dc, bounds);
    check(BRepCheck_Analyzer(compound).IsValid() && actual.solids==expected.solids && dv<=relative && da<=relative &&
          dc<=1e-7 && bounds<=1e-5, format + metrics);
    if (expectedParts.empty()) return;
    // Aggregate properties can hide compensating changes or swapped placements. Match each
    // separated solid by its centre and check its own geometry, including IGES's compound.
    TopTools_IndexedMapOfShape solids; TopExp::MapShapes(compound,TopAbs_SOLID,solids);
    std::vector<Measurements> remaining;
    for (int i=1;i<=solids.Extent();++i) remaining.push_back(measure(solids(i)));
    bool parts=remaining.size()==expectedParts.size();
    double maxVolume=0,maxArea=0,maxCentre=0,maxBounds=0;
    for (const auto& wanted : expectedParts) {
        if (remaining.empty()) { parts=false; break; }
        auto closest=std::min_element(remaining.begin(),remaining.end(),[&](const auto& a,const auto& b){
            return a.centre.Distance(wanted.centre)<b.centre.Distance(wanted.centre);
        });
        maxVolume=std::max(maxVolume,std::fabs(closest->volume-wanted.volume)/wanted.volume);
        maxArea=std::max(maxArea,std::fabs(closest->area-wanted.area)/wanted.area);
        maxCentre=std::max(maxCentre,closest->centre.Distance(wanted.centre));
        for (std::size_t i=0;i<6;++i) maxBounds=std::max(maxBounds,std::fabs(closest->bounds[i]-wanted.bounds[i]));
        remaining.erase(closest);
    }
    std::snprintf(metrics,sizeof metrics,": each solid; volume %.3g, area %.3g relative; centre %.3g m, bounds %.3g m",
                  maxVolume,maxArea,maxCentre,maxBounds);
    check(parts && maxVolume<=relative && maxArea<=relative && maxCentre<=1e-7 && maxBounds<=1e-5,format+metrics);
}

ProductStructure productOf(const std::vector<NamedExchangeBody>& bodies) {
    ProductStructure p; ProductAssembly root; root.name = "Assembly";
    for (std::size_t i=0; i<bodies.size(); ++i) {
        p.parts.push_back({bodies[i].name, bodies[i].body.shape});
        ProductInstance instance; instance.definition=int(i); instance.name=bodies[i].name; root.instances.push_back(instance);
    }
    p.assemblies.push_back(root); return p;
}

void dwgBlockBoundaries(const QTemporaryDir& directory) {
    const QString executable = qEnvironmentVariable("CADNEXT_DWG_WRITER");
    if (executable.isEmpty() || !dwgSolidWriterAvailable()) return;
    OcctKernel kernel;
    const auto box = kernel.makeBox({.01, .02, .03});
    AcisSatWriteReport report;
    const auto encoded = encodeAcisSat(kernel, {{"blocks", {box.value(), {}}}}, report);
    if (!encoded.isOk()) { check(false, "DWG block fixture: " + encoded.error().message); return; }
    const qsizetype firstMultiple = (encoded.value().size() / 4096 + 1) * 4096;
    for (const qsizetype size : {firstMultiple, firstMultiple + 4096, firstMultiple + 8193}) {
        QByteArray payload = encoded.value();
        if (payload.size() > size) { check(false, "DWG block fixture unexpectedly large"); return; }
        payload.append(QByteArray(size - payload.size(), '\n'));
        const QString input = directory.filePath("blocks.sat"), output = directory.filePath(QString("blocks_%1.dwg").arg(size));
        QFile file(input);
        if (!file.open(QIODevice::WriteOnly) || file.write(payload) != payload.size()) return;
        file.close();
        QProcess writer;
        writer.start(executable, {output, "-5", "-10", "-15", "5", "10", "15", input});
        const bool written = writer.waitForFinished(10000) && writer.exitStatus() == QProcess::NormalExit && writer.exitCode() == 0;
        if (!written) { writer.kill(); writer.waitForFinished(1000); }
        DwgModel restored; QString error;
        check(written && readDwgModel(output, restored, error) && restored.bodies.size() == 1 &&
              restored.bodies.front().acis.trimmed() == payload.trimmed(),
              "DWG: exact SAT payload across " + std::to_string(size) + " bytes and 4096-byte blocks");
    }
    const QString protectedPath = directory.filePath("existing.dwg");
    QFile existing(protectedPath);
    if (!existing.open(QIODevice::WriteOnly) || existing.write("keep") != 4) return;
    existing.close();
    qputenv("CADNEXT_DWG_WRITER", directory.filePath("missing_writer").toUtf8());
    const auto failed = writeDwgSolids(kernel, {{"box", {box.value(), {}}}}, protectedPath);
    qputenv("CADNEXT_DWG_WRITER", executable.toUtf8());
    if (!existing.open(QIODevice::ReadOnly)) return;
    check(!failed.isOk() && existing.readAll() == "keep", "DWG: missing backend preserves destination");
}

void sketchRoundTrips(const QTemporaryDir& dir) {
    Sketch sketch; sketch.id="curves"; sketch.name="Curves";
    SketchEntity line; line.id="line"; line.type=SketchEntityType::Line;
    line.line={{0.00123456789, -0.0123456789}, {0.027182818284, 0.003141592653}};
    SketchEntity circle; circle.id="circle"; circle.type=SketchEntityType::Circle;
    circle.circle={{0.0135789, -0.024681}, 0.006789123};
    SketchEntity arc; arc.id="arc"; arc.type=SketchEntityType::Arc;
    arc.arc={{-0.025, 0.012}, 0.007123456789, 317.123456, 212.987654};
    sketch.entities={line, circle, arc};
    for (bool binary : {false, true}) {
        const std::string name = binary ? "DXF sketch binary" : "DXF sketch ASCII";
        const QString path=dir.filePath(binary ? "sketch_binary.dxf" : "sketch_ascii.dxf");
        DxfSketchData data; QString error;
        const bool ok=writeDxfSketch(path, sketch, error, binary) && readDxfSketch(path, data, error);
        check(ok && data.drawingUnits==4 && data.entities.size()==3, name + ": read/write, millimetres");
        if (!ok || data.entities.size()!=3) continue;
        const auto& a=data.entities[0]; const auto& b=data.entities[1]; const auto& c=data.entities[2];
        const auto near=[](double x, double y) { return std::fabs(x-y)<1e-12; };
        check(a.type==line.type && near(a.line.start.u,line.line.start.u) && near(a.line.start.v,line.line.start.v) &&
              near(a.line.end.u,line.line.end.u) && near(a.line.end.v,line.line.end.v) && b.type==circle.type &&
              near(b.circle.center.u,circle.circle.center.u) && near(b.circle.center.v,circle.circle.center.v) && near(b.circle.radius,circle.circle.radius) &&
              c.type==arc.type && near(c.arc.center.u,arc.arc.center.u) && near(c.arc.center.v,arc.arc.center.v) && near(c.arc.radius,arc.arc.radius) &&
              near(c.arc.startAngleDegrees,arc.arc.startAngleDegrees) && near(c.arc.sweepDegrees,arc.arc.sweepDegrees), name+": exact curves and major arc");
    }
}

// A plane written as an ACIS sweep, with three independent definitions of its profile. This
// exercises procedural evaluation without relying on the downloaded DWG fixtures.
void proceduralSat() {
    OcctKernel source;
    const TopoDS_Shape box=BRepPrimAPI_MakeBox(.01,.02,.03).Shape();
    AcisSatWriteReport report;
    const auto encoded=encodeAcisSat(source,{{"Sweep",{source.adoptShape(box,"procedural-reference"),{}}}},report);
    check(encoded.isOk(),"procedural SAT: reference topology");
    if (!encoded.isOk()) return;
    const QByteArray sat=encoded.value();
    const auto records=sat.split('\n');
    QByteArray plane;
    for (const auto& record:records) {
        const auto tokens=record.simplified().split(' ');
        if (tokens.size()>11 && tokens[1]=="plane-surface" && tokens[6].toDouble()==0 &&
            tokens[8].toDouble()==0 && std::fabs(tokens[9].toDouble())==1 && tokens[10].toDouble()==0) { plane=record;break; }
    }
    check(!plane.isEmpty(),"procedural SAT: Y=0 face located");
    if (plane.isEmpty()) return;
    const auto tokens=plane.split(' ');
    const QByteArray prefix=tokens[0]+" spline-surface "+tokens[2]+" "+tokens[3]+" "+tokens[4]+
        (tokens[9].toDouble()<0?" forward":" reversed")+" { sweepsur normal ";
    const QByteArray guide="full nubs 1 open 2 0 1 10 1 0 0 0 10 0 0 0 null_surface null_surface nullbs nullbs I I 0 0 0 ";
    const std::vector<std::pair<std::string,QByteArray>> profiles={
        {"straight","straight 0 0 0 1 0 0 I I"},
        {"lawintcur","intcurve forward { lawintcur "+guide+"10 VEC(X,0,0) } I I"},
        {"offsetintcur","intcurve forward { offsetintcur "+guide+"straight 0 2 0 1 0 0 I I 0 10 0 0 1 1 2 } I I"}
    };
    for (const auto& [name,profile]:profiles) {
        const QByteArray surface=prefix+profile+
            " straight 0 0 0 0 0 1 I I normal 0 0 1 0 0 0 1 0 0 0 1 0 0 0 1 0 30 0 0"
            " 10 VEC(1,0,0) 0 1 0 0 10 VEC(1,1,1) 0 full nubs 1 1 open open none none 2 2"
            " 0 1 10 1 0 1 30 1 0 0 0 10 0 0 0 0 30 10 0 30 0 } I I I I #";
        QByteArray changed=sat;changed.replace(plane,surface);
        OcctKernel restored;AcisSatResult result;QString error;
        const bool ok=readAcisSat(changed,restored,result,error);
        check(ok,"procedural SAT "+name+": built"+(ok?"":" — "+error.toStdString()));
        std::vector<ShapeHandle> shapes;for (const auto& solid:result.solids) shapes.push_back(solid.shape);
        if (ok) compare(restored,shapes,measure(box),"procedural SAT "+name);
        if (name=="lawintcur") {
            changed.replace("VEC(X,0,0)","VEC(Q,0,0)");
            AcisSatResult rejected;QString reason;
            check(!readAcisSat(changed,restored,rejected,reason) && !reason.isEmpty(),
                  "procedural SAT: unsupported law reports failure");
        }
    }
}

bool exchangeExactBody(OcctKernel& source, ShapeHandle shape, const std::string& name,
                       const std::string& format, OcctKernel& restored, std::vector<ShapeHandle>& shapes) {
    QTemporaryDir directory;
    if (!directory.isValid()) { check(false, name + ": temporary directory"); return false; }
    const auto path = directory.filePath(QString::fromStdString("body." + format));
    const std::vector<NamedExchangeBody> bodies{{name, {shape, {}}}};
    if (format == "sat") {
        AcisSatWriteReport report;
        const auto bytes = encodeAcisSat(source, bodies, report);
        check(bytes.isOk(), name + " SAT: written" + (bytes.isOk() ? std::string() : " — " + bytes.error().message));
        if (!bytes.isOk()) return false;
        AcisSatResult read; QString error;
        const bool ok = readAcisSat(bytes.value(), restored, read, error);
        check(ok, name + " SAT: read" + (ok ? std::string() : " — " + error.toStdString()));
        if (!ok) return false;
        for (const auto& body : read.solids) shapes.push_back(body.shape);
    } else {
        const auto written = writeParasolidXtProduct(source, productOf(bodies), path.toStdString(),
            format == "x_t" ? ParasolidXtEncoding::Text : ParasolidXtEncoding::Binary);
        check(written.isOk(), name + " " + format + ": written" +
              (written.isOk() ? std::string() : " — " + written.error().message));
        if (!written.isOk()) return false;
        const auto read = readParasolidXtProduct(restored, path.toStdString());
        check(read.isOk(), name + " " + format + ": read" +
              (read.isOk() ? std::string() : " — " + read.error().message));
        if (!read.isOk()) return false;
        for (const auto& part : read.value().parts) shapes.push_back(part.shape);
    }
    return true;
}

void tolerantSat() {
    // A modeller permits a vertex to differ from its incident curve within its tolerance.
    // Its position must not shorten an exact NURBS edge's saved parameter interval.
    const auto box=BRepBuilderAPI_NurbsConvert(BRepPrimAPI_MakeBox(.01,.02,.03).Shape()).Shape();
    // The real procedural bodies keep their exact UV splines inside TrimmedCurve.
    // Unwrapping must retain the range and must not trigger reprojection of planar caps.
    BRep_Builder uvBuilder;
    for (TopExp_Explorer f(box, TopAbs_FACE); f.More(); f.Next()) {
        const auto face = TopoDS::Face(f.Current());
        for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
            const auto edge = TopoDS::Edge(e.Current());
            double first, last;
            const auto uv = BRep_Tool::CurveOnSurface(edge, face, first, last);
            if (!uv.IsNull() && last > first)
                uvBuilder.UpdateEdge(edge, new Geom2d_TrimmedCurve(uv, first, last), face, BRep_Tool::Tolerance(edge));
        }
    }
    TopTools_IndexedMapOfShape vertices;TopExp::MapShapes(box,TopAbs_VERTEX,vertices);
    for(int i=1;i<=vertices.Extent();++i) {
        const auto vertex=TopoDS::Vertex(vertices(i));
        if(BRep_Tool::Pnt(vertex).Distance(gp_Pnt(0,0,0))<1e-12) {
            BRep_Builder builder;builder.UpdateVertex(vertex,gp_Pnt(5e-8,0,0),BRep_Tool::Tolerance(vertex));
        }
    }
    check(BRepCheck_Analyzer(box).IsValid(),"tolerant SAT: reference vertex within its modeller tolerance");
    OcctKernel source;AcisSatWriteReport report;
    const auto encoded=encodeAcisSat(source,{{"Tolerant NURBS",{source.adoptShape(box,"tolerant-reference"),{}}}},report);
    check(encoded.isOk(),"tolerant SAT: written"+(encoded.isOk()?std::string():" — "+encoded.error().message));
    if(!encoded.isOk()) return;
    OcctKernel restored;AcisSatResult read;QString error;
    const bool ok=readAcisSat(encoded.value(),restored,read,error);
    check(ok,"tolerant SAT: read"+(ok?std::string():" — "+error.toStdString()));
    std::vector<ShapeHandle> shapes;for(const auto& b:read.solids) shapes.push_back(b.shape);
    if(ok) compare(restored,shapes,measure(box),"tolerant SAT",1e-8,{measure(box)});
}

void phasedRingSat() {
    const double phase = .3216406;
    const auto solid = BRepPrimAPI_MakeCylinder(.011, .03).Shape();
    BRep_Builder builder;
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(solid, TopAbs_EDGE, edges);
    for (int i = 1; i <= edges.Extent(); ++i) {
        const auto edge = TopoDS::Edge(edges(i));
        if (BRepAdaptor_Curve(edge).GetType() != GeomAbs_Circle) continue;
        double first, last;
        const auto original = Handle(Geom_Circle)::DownCast(BRep_Tool::Curve(edge, first, last));
        const auto circle = Handle(Geom_Circle)::DownCast(original->Copy());
        circle->Rotate(circle->Axis(), -phase);
        for (TopExp_Explorer f(solid, TopAbs_FACE); f.More(); f.Next()) {
            const auto face = TopoDS::Face(f.Current());
            bool contains = false;
            for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) contains |= e.Current().IsSame(edge);
            if (!contains) continue;
            double a, b;
            auto uv = BRep_Tool::CurveOnSurface(edge, face, a, b)->Copy();
            const auto curve = Handle(Geom2d_Curve)::DownCast(uv);
            if (const auto line = Handle(Geom2d_Line)::DownCast(curve))
                line->Translate(gp_Vec2d(line->Direction()) * -phase);
            else if (const auto circle = Handle(Geom2d_Circle)::DownCast(curve))
                circle->Rotate(circle->Location(), -phase);
            else { check(false, "phased ring: reference UV type"); return; }
            builder.UpdateEdge(edge, curve, face, BRep_Tool::Tolerance(edge));
            builder.Range(edge, face, first + phase, last + phase);
        }
        builder.UpdateEdge(edge, circle, BRep_Tool::Tolerance(edge));
        builder.Range(edge, first + phase, last + phase, true);
        const auto vertex = TopExp::FirstVertex(edge);
        builder.UpdateVertex(vertex, first + phase, edge, BRep_Tool::Tolerance(vertex));
    }
    check(BRepCheck_Analyzer(solid).IsValid(), "phased ring: reference cylinder");
    OcctKernel source; AcisSatWriteReport report;
    const auto bytes = encodeAcisSat(source, {{"Phase", {source.adoptShape(solid, "phase"), {}}}}, report);
    check(bytes.isOk(), "phased ring: SAT written" + (bytes.isOk() ? std::string() : " — " + bytes.error().message));
    if (!bytes.isOk()) return;
    OcctKernel restored; AcisSatResult read; QString error;
    const bool ok = readAcisSat(bytes.value(), restored, read, error);
    check(ok, "phased ring: SAT read" + (ok ? std::string() : " — " + error.toStdString()));
    if (!ok) return;
    std::vector<ShapeHandle> shapes;
    for (const auto& body : read.solids) shapes.push_back(body.shape);
    compare(restored, shapes, measure(solid), "phased ring");
}

void periodicBoundaryExchange() {
    // A valid tolerant torus boundary need not be the exact projection of its
    // shared 3D edge. Periodic wire repair used to replace this UV curve.
    const auto solid = BRepPrimAPI_MakeTorus(.025, .006, -.6, .7, pi / 2).Shape();
    BRep_Builder builder;
    bool changed = false;
    gp_Pnt edgeMiddle;
    std::array<gp_Pnt, 9> boundaryPoints;
    for (TopExp_Explorer f(solid, TopAbs_FACE); f.More() && !changed; f.Next()) {
        const auto face = TopoDS::Face(f.Current());
        if (BRepAdaptor_Surface(face).GetType() != GeomAbs_Torus) continue;
        for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
            const auto edge = TopoDS::Edge(e.Current());
            double first, last;
            const auto original = BRep_Tool::CurveOnSurface(edge, face, first, last);
            const auto a = original->Value(first), b = original->Value(last);
            if (std::fabs(a.X() - b.X()) < .1 || std::fabs(a.Y() - b.Y()) > 1e-12) continue;
            TColgp_Array1OfPnt2d poles(1, 4);
            for (int p = 1; p <= 4; ++p) {
                const double fraction = (p - 1) / 3.0;
                poles.SetValue(p, gp_Pnt2d(a.X() + (b.X() - a.X()) * fraction,
                                          a.Y() + ((p == 2 || p == 3) ? 1e-4 : 0)));
            }
            TColStd_Array1OfReal knots(1, 2);
            knots.SetValue(1, first); knots.SetValue(2, last);
            TColStd_Array1OfInteger multiplicities(1, 2);
            multiplicities.SetValue(1, 4); multiplicities.SetValue(2, 4);
            const Handle(Geom2d_Curve) curve = new Geom2d_BSplineCurve(poles, knots, multiplicities, 3);
            builder.UpdateEdge(edge, curve, face, 1e-5);
            builder.Range(edge, face, first, last);
            const BRepAdaptor_Curve edgeCurve(edge);
            edgeMiddle = edgeCurve.Value((edgeCurve.FirstParameter() + edgeCurve.LastParameter()) / 2);
            const auto support = BRep_Tool::Surface(face);
            for (std::size_t i = 0; i < boundaryPoints.size(); ++i) {
                const auto uv = curve->Value(first + (last - first) * i / (boundaryPoints.size() - 1));
                boundaryPoints[i] = support->Value(uv.X(), uv.Y());
            }
            changed = true;
            break;
        }
    }
    check(changed && BRepCheck_Analyzer(solid).IsValid(), "periodic boundary: tolerant torus reference");
    if (!changed) return;
    const auto expected = measure(solid);
    OcctKernel source;
    const auto body = source.adoptShape(solid, "uv-torus");
    for (const std::string format : {"sat"}) {
        OcctKernel restored;
        std::vector<ShapeHandle> shapes;
        if (!exchangeExactBody(source, body, "Periodic boundary", format, restored, shapes)) continue;
        compare(restored, shapes, expected, format + " periodic UV boundary");
        double boundaryGap = std::numeric_limits<double>::infinity();
        for (const auto& shape : shapes) for (TopExp_Explorer f(*restored.findShape(shape), TopAbs_FACE); f.More(); f.Next()) {
            const auto face = TopoDS::Face(f.Current());
            if (BRepAdaptor_Surface(face).GetType() != GeomAbs_Torus) continue;
            for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
                const auto edge = TopoDS::Edge(e.Current());
                const BRepAdaptor_Curve curve(edge);
                if (curve.Value((curve.FirstParameter() + curve.LastParameter()) / 2).Distance(edgeMiddle) > 1e-7) continue;
                double first, last;
                const auto uvCurve = BRep_Tool::CurveOnSurface(edge, face, first, last);
                if (uvCurve.IsNull()) continue;
                for (bool reverse : {false, true}) {
                    double gap = 0;
                    for (std::size_t i = 0; i < boundaryPoints.size(); ++i) {
                        double fraction = double(i) / (boundaryPoints.size() - 1);
                        if (reverse) fraction = 1 - fraction;
                        const auto uv = uvCurve->Value(first + (last - first) * fraction);
                        gap = std::max(gap, BRep_Tool::Surface(face)->Value(uv.X(), uv.Y()).Distance(boundaryPoints[i]));
                    }
                    boundaryGap = std::min(boundaryGap, gap);
                }
            }
        }
        char boundaryMetric[96];
        std::snprintf(boundaryMetric, sizeof boundaryMetric, ": deviation %.3g m", boundaryGap);
        check(boundaryGap < 1e-10, format + " periodic UV boundary: tolerant curve preserved on support" + boundaryMetric);
    }
}

void periodicSplineTube() {
    // A small analogue of HEAT_COIL: a periodic spline support, circular caps,
    // and a long UV range whose end differs by a few billionths. A generated
    // seam must have exactly the same 2D and 3D parameter range.
    constexpr int count = 64;
    const double step = 2 * pi / count, radius = .000127;
    TColgp_Array2OfPnt poles(1, count, 1, 2);
    TColStd_Array1OfReal uKnots(1, count + 1), vKnots(1, 2);
    TColStd_Array1OfInteger uMult(1, count + 1), vMult(1, 2);
    for (int k = 1; k <= count + 1; ++k) {
        uKnots(k) = (k - 1) * step; uMult(k) = 1;
    }
    vKnots(1) = 0; vKnots(2) = 100; vMult(1) = vMult(2) = 2;
    const double correctedRadius = radius * 3 / (2 + std::cos(step));
    for (int i = 1; i <= count; ++i) for (int j = 1; j <= 2; ++j)
        poles(i, j) = gp_Pnt(correctedRadius * std::cos((i - 1) * step),
                            correctedRadius * std::sin((i - 1) * step), (j - 1) * .02);
    const Handle(Geom_BSplineSurface) support =
        new Geom_BSplineSurface(poles, uKnots, vKnots, uMult, vMult, 3, 1, true, false);
    const auto side = BRepBuilderAPI_MakeFace(support, 0, 2 * pi, 0, 100, 1e-7).Face();
    BRep_Builder builder;
    std::vector<TopoDS_Face> caps;
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(side, TopAbs_EDGE, edges);
    for (int i = 1; i <= edges.Extent(); ++i) {
        const auto edge = TopoDS::Edge(edges(i));
        if (BRep_Tool::IsClosed(edge, side)) continue;
        double first, last;
        const auto uv = BRep_Tool::CurveOnSurface(edge, side, first, last);
        const auto a = uv->Value(first), b = uv->Value(last);
        const auto at = support->Value(a.X(), a.Y());
        const Handle(Geom_Circle) circle = new Geom_Circle(
            gp_Ax2(gp_Pnt(0, 0, at.Z()), gp_Dir(0, 0, 1), gp_Dir(at.X(), at.Y(), 0)),
            std::hypot(at.X(), at.Y()));
        builder.UpdateEdge(edge, circle, 1e-7);
        builder.Range(edge, 0, 2 * pi, true);
        builder.Range(edge, side, 0, 2 * pi);
        if (at.Z() > .01) {
            TColgp_Array1OfPnt2d boundaryPoles(1, 2);
            boundaryPoles(1) = gp_Pnt2d(a.X() - 1.5e-8, 100 - 4e-9);
            boundaryPoles(2) = gp_Pnt2d(b.X() - 1.5e-8, 100 - 4e-9);
            TColStd_Array1OfReal knots(1, 2);
            knots(1) = 0; knots(2) = 2 * pi;
            TColStd_Array1OfInteger mult(1, 2);
            mult(1) = mult(2) = 2;
            builder.UpdateEdge(edge, new Geom2d_BSplineCurve(boundaryPoles, knots, mult, 1), side, 1e-7);
        }
        const auto wire = BRepBuilderAPI_MakeWire(TopoDS::Edge(edge.Oriented(TopAbs_FORWARD))).Wire();
        auto cap = BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(0, 0, at.Z()), gp_Dir(0, 0, 1)), wire, true).Face();
        if (at.Z() < .01) cap.Reverse();
        caps.push_back(cap);
    }
    TopoDS_Shell shell;
    builder.MakeShell(shell); builder.Add(shell, side);
    for (const auto& cap : caps) builder.Add(shell, cap);
    shell.Closed(true);
    const auto solid = BRepBuilderAPI_MakeSolid(shell).Solid();
    const bool valid = caps.size() == 2 && BRepCheck_Analyzer(solid).IsValid();
    check(valid, "periodic spline tube: reference");
    if (!valid) return;
    const auto expected = measure(solid);
    OcctKernel source;
    const auto shape = source.adoptShape(solid, "periodic-spline-tube");
    for (const std::string format : {"sat", "x_t", "x_b"}) {
        OcctKernel restored;
        std::vector<ShapeHandle> shapes;
        if (exchangeExactBody(source, shape, "Periodic spline tube", format, restored, shapes))
            compare(restored, shapes, expected, format + " periodic spline tube");
    }
}

void analyticUvFrames() {
    // Fillets can keep an indirect Ax3 on their analytic supports. Transferring
    // their UV curves to a direct frame must preserve the physical boundary.
    OcctKernel source;
    const auto box = source.makeBox({.04, .03, .02});
    if (!box.isOk()) { check(false, "analytic UV frames: reference box"); return; }
    EdgeAnalyzer analyzer(source);
    std::vector<std::string> edges;
    for (const auto& edge : analyzer.edgesForBody("uv-box", box.value())) edges.push_back(edge.edgeId);
    const auto rounded = source.filletEdges(box.value(), edges, .004);
    check(rounded.isOk(), "analytic UV frames: filleted box");
    if (!rounded.isOk()) return;
    const auto& solid = *source.findShape(rounded.value());
    int indirect = 0;
    for (TopExp_Explorer f(solid, TopAbs_FACE); f.More(); f.Next()) {
        const BRepAdaptor_Surface surface(TopoDS::Face(f.Current()));
        switch (surface.GetType()) {
        case GeomAbs_Cylinder: indirect += !surface.Cylinder().Position().Direct(); break;
        case GeomAbs_Cone: indirect += !surface.Cone().Position().Direct(); break;
        case GeomAbs_Sphere: indirect += !surface.Sphere().Position().Direct(); break;
        case GeomAbs_Torus: indirect += !surface.Torus().Position().Direct(); break;
        default: break;
        }
    }
    check(indirect > 0 && BRepCheck_Analyzer(solid).IsValid(),
          "analytic UV frames: valid reference with indirect supports");
    const auto expected = measure(solid);
    for (const std::string format : {"sat", "x_t", "x_b"}) {
        OcctKernel restored;
        std::vector<ShapeHandle> shapes;
        if (exchangeExactBody(source, rounded.value(), "Indirect fillet frames", format, restored, shapes))
            compare(restored, shapes, expected, format + " indirect analytic UV frames");
    }
}

void thinPlanarStrip() {
    // Like the DRYER housing, this body has a planar strip narrower than the
    // modeller's tolerance. Reprojection must not collapse the strip or leave
    // its neighbours with free edges. A straight spline is still exact geometry.
    const std::vector<gp_Pnt> points{{0, 0, 0}, {.02, 0, 0}, {.02, .03, 0},
                                     {5e-7, .03, 0}, {0, .03, 0}};
    TColgp_Array1OfPnt poles(1, 2);
    poles(1) = points[0]; poles(2) = points[1];
    TColStd_Array1OfReal knots(1, 2);
    knots(1) = 0; knots(2) = 1;
    TColStd_Array1OfInteger mult(1, 2);
    mult(1) = mult(2) = 2;
    const Handle(Geom_BSplineCurve) spline = new Geom_BSplineCurve(poles, knots, mult, 1);
    BRepBuilderAPI_MakeWire wire;
    wire.Add(BRepBuilderAPI_MakeEdge(spline).Edge());
    for (std::size_t i = 1; i < points.size(); ++i)
        wire.Add(BRepBuilderAPI_MakeEdge(points[i], points[(i + 1) % points.size()]).Edge());
    const auto solid = BRepPrimAPI_MakePrism(
        BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), wire.Wire()).Face(),
        gp_Vec(0, 0, .04)).Shape();
    BRep_Builder builder;
    for (TopExp_Explorer e(solid, TopAbs_EDGE); e.More(); e.Next())
        builder.UpdateEdge(TopoDS::Edge(e.Current()), 1e-6);
    for (TopExp_Explorer v(solid, TopAbs_VERTEX); v.More(); v.Next())
        builder.UpdateVertex(TopoDS::Vertex(v.Current()), 1e-6);
    const bool valid = BRepCheck_Analyzer(solid).IsValid();
    check(valid, "thin planar strip: reference narrower than edge tolerance");
    if (!valid) return;
    const auto expected = measure(solid);
    OcctKernel source;
    const auto shape = source.adoptShape(solid, "thin-planar-strip");
    for (const std::string format : {"sat", "x_t", "x_b"}) {
        OcctKernel restored;
        std::vector<ShapeHandle> shapes;
        if (!exchangeExactBody(source, shape, "Thin planar strip", format, restored, shapes)) continue;
        compare(restored, shapes, expected, format + " thin planar strip");
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(together(restored, shapes), TopAbs_FACE, faces);
        check(faces.Extent() == 7, format + " thin planar strip: all seven faces retained");
    }
}

void touchingHole() {
    // The cone's upper ring touches the block's boundary in one vertex. Its
    // cap keeps two distinct wires with a common vertex, as the DRYER housing
    // does. Joining their loops or losing that vertex makes the face invalid.
    const auto block = BRepPrimAPI_MakeBox(.02, .03, .04).Shape();
    const auto tool = BRepPrimAPI_MakeCone(
        gp_Ax2(gp_Pnt(.014, .015, 0), gp_Dir(0, 0, 1), gp_Dir(std::cos(.37), std::sin(.37), 0)),
        .003, .006, .04).Shape();
    const auto solid = BRepAlgoAPI_Cut(block, tool).Shape();
    bool touching = false;
    for (TopExp_Explorer f(solid, TopAbs_FACE); f.More(); f.Next()) {
        std::vector<TopoDS_Wire> wires;
        for (TopExp_Explorer w(f.Current(), TopAbs_WIRE); w.More(); w.Next()) wires.push_back(TopoDS::Wire(w.Current()));
        if (wires.size() != 2) continue;
        TopTools_IndexedMapOfShape vertices;
        TopExp::MapShapes(wires.front(), TopAbs_VERTEX, vertices);
        for (TopExp_Explorer v(wires.back(), TopAbs_VERTEX); v.More(); v.Next()) touching |= vertices.Contains(v.Current());
    }
    const bool valid = touching && BRepCheck_Analyzer(solid).IsValid();
    check(valid, "touching hole: reference has separate wires sharing a vertex");
    if (!valid) return;
    const auto expected = measure(solid);
    OcctKernel source;
    const auto shape = source.adoptShape(solid, "touching-hole");
    for (const std::string format : {"sat", "x_t", "x_b"}) {
        OcctKernel restored;
        std::vector<ShapeHandle> shapes;
        if (exchangeExactBody(source, shape, "Touching hole", format, restored, shapes))
            compare(restored, shapes, expected, format + " touching hole");
    }
}

void binaryAcisLoopIndex() {
    OcctKernel source;
    const auto shape = source.adoptShape(BRepPrimAPI_MakeBox(.01, .02, .03).Shape(), "sab-reference");
    AcisSatWriteReport report;
    const auto text = encodeAcisSat(source, {{"SAB", {shape, {}}}}, report);
    if (!text.isOk()) { check(false, "SAB: reference topology"); return; }
    // Encode this small fixture's SAT records as tagged binary fields. Modern
    // ASM coedges include an integer between their loop and pcurve pointers.
    QByteArray binary("ACIS BinaryFile");
    const auto integer = [&](quint64 value, int size) {
        for (int b = 0; b < size; ++b) binary.append(char(value >> (8 * b)));
    };
    const auto real = [&](double value) {
        quint64 bits;
        std::memcpy(&bits, &value, sizeof bits);
        binary.append(char(6)); integer(bits, 8);
    };
    const auto identifier = [&](const QByteArray& value) {
        binary.append(char(13)); binary.append(char(value.size())); binary.append(value);
    };
    const auto string = [&](const QByteArray& value) {
        binary.append(char(18)); integer(value.size(), 4); binary.append(value);
    };
    integer(22300, 4); integer(0, 4); integer(1, 4); integer(0, 4);
    string("CADNext"); string("ACIS 22.3"); string("fixture");
    real(1); real(1e-6); real(1e-10);
    for (const auto& line : text.value().split('\n')) {
        if (!line.startsWith('-')) continue;
        const auto fields = line.simplified().split(' ');
        identifier(fields[1]);
        for (int i = 2; i < fields.size(); ++i) {
            const auto& field = fields[i];
            if (field == "#") binary.append(char(17));
            else if (field == "{") binary.append(char(15));
            else if (field == "}") binary.append(char(16));
            else if (field.startsWith('$')) { binary.append(char(12)); integer(quint32(field.mid(1).toInt()), 4); }
            else if (field.startsWith('@')) {
                if (i + 1 >= fields.size() || fields[i + 1].size() != field.mid(1).toInt()) {
                    check(false, "SAB: fixture string length"); return;
                }
                string(fields[++i]);
            } else if (field == "forward" || field == "I") binary.append(char(11));
            else if (field == "reversed") binary.append(char(10));
            else {
                bool numeric;
                const double value = field.toDouble(&numeric);
                if (numeric) real(value); else identifier(field);
            }
            if (fields[1] == "coedge" && i == 10) { binary.append(char(4)); integer(0, 4); }
        }
    }
    identifier("End-of-ACIS-data");
    OcctKernel restored; AcisSatResult read; QString error;
    const bool ok = readAcisSat(binary, restored, read, error);
    check(ok, "SAB: coedge loop index read" + (ok ? std::string() : " — " + error.toStdString()));
    if (!ok) return;
    std::vector<ShapeHandle> shapes;
    for (const auto& body : read.solids) shapes.push_back(body.shape);
    compare(restored, shapes, measure(*source.findShape(shape)), "SAB indexed loops");
}
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv); QTemporaryDir dir; if (!dir.isValid()) return 1;
    OcctKernel source;
    std::vector<NamedExchangeBody> bodies;
    const auto add=[&](const std::string& name, const TopoDS_Shape& s, const Vector3& scale=Vector3{1,1,1}) {
        Transform placement; placement.position={double(bodies.size())*0.08, 0.01, -0.005};
        placement.rotationEuler={17.0, -23.0, 41.0}; placement.scale=scale;
        bodies.push_back({name, {source.adoptShape(s, "roundtrip-source"), placement}});
    };
    add("Корпус", BRepPrimAPI_MakeBox(0.01, 0.02, 0.03).Shape());
    add("Cylinder", BRepPrimAPI_MakeCylinder(0.008, 0.03).Shape(), {1.25,1.25,1.25});
    add("Cone", BRepPrimAPI_MakeCone(0.012, 0.004, 0.02).Shape());
    add("Sphere", BRepPrimAPI_MakeSphere(0.01).Shape());
    add("Full torus", BRepPrimAPI_MakeTorus(0.015, 0.003).Shape());
    add("Torus quarter", BRepPrimAPI_MakeTorus(0.025, 0.006, pi/2).Shape());
    add("Closed NURBS", BRepBuilderAPI_NurbsConvert(BRepPrimAPI_MakeCylinder(0.005,0.015).Shape()).Shape());
    // An open arc on a periodic spline ends beyond its base period. Cutting it after
    // SetNotPeriodic loses the half after the seam (the real DRYER body has such an edge).
    const auto periodic = GeomConvert::CurveToBSplineCurve(
        new Geom_Circle(gp_Ax2(gp_Pnt(0,0,0),gp_Dir(0,0,1)),0.007));
    periodic->SetPeriodic();
    const double seamFirst=periodic->FirstParameter()+0.75*periodic->Period();
    const double seamLast=periodic->FirstParameter()+1.25*periodic->Period();
    BRepBuilderAPI_MakeWire seamWire;
    seamWire.Add(BRepBuilderAPI_MakeEdge(periodic,seamFirst,seamLast).Edge());
    seamWire.Add(BRepBuilderAPI_MakeEdge(periodic->Value(seamLast),periodic->Value(seamFirst)).Edge());
    const auto seamBody=BRepPrimAPI_MakePrism(
        BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(0,0,0),gp_Dir(0,0,1)),seamWire.Wire()).Face(),
        gp_Vec(0,0,0.012)).Shape();
    bool crossesSeam=false;
    for(TopExp_Explorer e(seamBody,TopAbs_EDGE);e.More();e.Next()) {
        double first,last;const auto curve=BRep_Tool::Curve(TopoDS::Edge(e.Current()),first,last);
        const auto spline=Handle(Geom_BSplineCurve)::DownCast(curve);
        crossesSeam |= !spline.IsNull() && spline->IsPeriodic() && last>spline->LastParameter()+1e-12;
    }
    check(crossesSeam && BRepCheck_Analyzer(seamBody).IsValid(),"reference: open periodic NURBS edge crosses its seam");
    const auto seamDescription=describeExactBRep(source,source.adoptShape(seamBody,"periodic-edge-regression"));
    check(seamDescription.isOk() && seamDescription.value().largestVertexGap<1e-12,
          "periodic edge: cut through the seam preserves both vertices"+
          (seamDescription.isOk()?std::string():" — "+seamDescription.error().message));
    const auto ellipse=BRepBuilderAPI_MakeEdge(gp_Elips(gp_Ax2(gp_Pnt(0,0,0), gp_Dir(0,0,1)),0.015,0.006)).Edge();
    add("Ellipse extrusion", BRepPrimAPI_MakePrism(BRepBuilderAPI_MakeFace(BRepBuilderAPI_MakeWire(ellipse).Wire()).Face(), gp_Vec(0,0,0.02)).Shape());
    TColgp_Array1OfPnt poles(1,4); poles.SetValue(1,gp_Pnt(0,0,0)); poles.SetValue(2,gp_Pnt(0.006,-0.004,0));
    poles.SetValue(3,gp_Pnt(0.014,-0.004,0)); poles.SetValue(4,gp_Pnt(0.02,0,0));
    BRepBuilderAPI_MakeWire wire; wire.Add(BRepBuilderAPI_MakeEdge(new Geom_BezierCurve(poles)).Edge());
    wire.Add(BRepBuilderAPI_MakeEdge(gp_Pnt(0.02,0,0),gp_Pnt(0.02,0.01,0)).Edge());
    wire.Add(BRepBuilderAPI_MakeEdge(gp_Pnt(0.02,0.01,0),gp_Pnt(0,0.01,0)).Edge());
    wire.Add(BRepBuilderAPI_MakeEdge(gp_Pnt(0,0.01,0),gp_Pnt(0,0,0)).Edge());
    add("Spline extrusion", BRepPrimAPI_MakePrism(BRepBuilderAPI_MakeFace(wire.Wire()).Face(),gp_Vec(0,0,0.008)).Shape());
    const auto box=source.adoptShape(BRepPrimAPI_MakeBox(0.02,0.02,0.02).Shape(), "box");
    const auto hole=source.adoptShape(BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0.01,0.01,-0.005),gp_Dir(0,0,1)),0.004,0.03).Shape(), "hole");
    const auto drilled=source.booleanCut(box,hole); if (!drilled.isOk()) return 1;
    add("Drilled", *source.findShape(drilled.value()));
    // A rectangular opening wholly inside a half-cylinder's curved face: two loops
    // made only of lines and circular arcs, which a parameter band cannot represent.
    const auto halfCylinder=source.adoptShape(BRepPrimAPI_MakeCylinder(0.01,0.02,pi).Shape(),"half-cylinder");
    const auto slot=source.adoptShape(BRepPrimAPI_MakeBox(gp_Pnt(-0.02,0.008,0.005),0.04,0.01,0.01).Shape(),"slot");
    const auto slotted=source.booleanCut(halfCylinder,slot); if (!slotted.isOk()) return 1;
    bool hasCylinderHole=false;
    const auto slottedDescription=describeExactBRep(source,slotted.value());
    if (slottedDescription.isOk()) for (const auto& face : slottedDescription.value().faces)
        hasCylinderHole |= slottedDescription.value().surfaces[std::size_t(face.surface)].kind==DescribedSurface::Kind::Cylinder && face.loops.size()==2;
    check(hasCylinderHole,"reference: cylindrical face with an interior arc-and-line contour");
    add("Slotted half cylinder", *source.findShape(slotted.value()));
    add("Scaled {box} $ # @ \\ 🙂", BRepPrimAPI_MakeBox(0.01,0.02,0.03).Shape(), {1.5,.75,1.2});

    std::vector<ShapeHandle> expectedShapes;
    std::vector<NamedExchangeBody> placedBodies;
    for (const auto& body : bodies) {
        const auto placed=source.placeExchangeBody(body.body); if (!placed.isOk()) return 1;
        expectedShapes.push_back(placed.value()); placedBodies.push_back({body.name,{placed.value(),{}}});
    }
    const auto expected=measure(together(source,expectedShapes));
    std::vector<Measurements> expectedParts;
    for (const auto& shape : expectedShapes) expectedParts.push_back(measure(*source.findShape(shape)));
    check(expected.solids==int(bodies.size()), "reference: twelve placed solids, uniform and nonuniform scales");

    std::vector<std::string> formats{"step", "iges", "FCStd", "x_t", "x_b", "sat", "dxf"};
    if (dwgSolidWriterAvailable()) formats.push_back("dwg");
    for (const std::string& ext : formats) {
        const QString path=dir.filePath(QString::fromStdString("model."+ext));
        bool written=false; std::string why; QString error;
        if (ext=="step") { const auto r=source.exportStepAssembly(bodies,path.toStdString()); written=r.isOk(); if (!written) why=r.error().message; }
        else if (ext=="iges") {
            std::vector<ExchangeBody> unnamed; for (const auto& b:bodies) unnamed.push_back(b.body);
            const auto r=source.exportExchangeFile(unnamed,path.toStdString()); written=r.isOk(); if (!written) why=r.error().message;
        } else if (ext=="FCStd") {
            std::vector<FreeCadShape> shapes;
            for (const auto& b:bodies) { const auto r=source.exportFreeCadBRep(b.body); if (!r.isOk()) return 1;
                shapes.push_back({QString::fromStdString(b.name),QByteArray(reinterpret_cast<const char*>(r.value().data()),qsizetype(r.value().size())),false}); }
            written=writeFreeCadShapes(path,shapes,error); why=error.toStdString();
        } else if (ext=="x_t" || ext=="x_b") {
            const auto r=writeParasolidXtProduct(source,productOf(placedBodies),path.toStdString(),ext=="x_t"?ParasolidXtEncoding::Text:ParasolidXtEncoding::Binary);
            written=r.isOk(); if (!written) why=r.error().message;
        } else { const auto r=ext=="sat"?writeAcisSat(source,bodies,path)
                            :ext=="dwg"?writeDwgSolids(source,bodies,path):writeDxfSolids(source,bodies,path);
            written=r.isOk(); if (!written) why=r.error().message; }
        check(written, ext+": written"+(why.empty()?"":" — "+why)); if (!written) continue;
        OcctKernel restored; std::vector<ShapeHandle> shapes;
        if (ext=="step") {
            const auto r=restored.importStepAssembly(path.toStdString()); if (r.isOk()) for (const auto& b:r.value()) shapes.push_back(b.shape);
        } else if (ext=="iges") {
            const auto r=restored.importExchangeFile(path.toStdString()); if (r.isOk()) shapes.push_back(r.value());
        } else if (ext=="FCStd") {
            std::vector<FreeCadShape> from;
            if (readFreeCadShapes(path,from,error)) for (const auto& b:from) {
                const std::vector<std::uint8_t> bytes(b.brep.begin(),b.brep.end()); const auto r=restored.importFreeCadBRep(bytes,b.binary);
                if (r.isOk()) shapes.push_back(r.value());
            }
            check(from.size()==bodies.size() && from.front().name==QString::fromStdString(bodies.front().name), ext+": body names");
        } else if (ext=="x_t" || ext=="x_b") {
            const auto r=readParasolidXtProduct(restored,path.toStdString()); if (r.isOk()) for (const auto& b:r.value().parts) shapes.push_back(b.shape);
        } else if (ext=="sat") {
            AcisSatResult from; if (readAcisSatFile(path,restored,from,error)) for (const auto& b:from.solids) shapes.push_back(b.shape);
            bool names=from.solids.size()==bodies.size();
            for (std::size_t i=0;names && i<bodies.size();++i) names &= from.solids[i].name==QString::fromStdString(bodies[i].name);
            check(from.millimetresPerUnit==1.0 && names, ext+": units and body names, reserved symbols and Unicode");
            QFile file(path);bool layout=file.open(QIODevice::ReadOnly);
            if (layout) {
                const auto lines=file.readAll().split('\n');
                layout=lines.size()>3 && lines[1].startsWith("7 CADNext 8 ACIS 7.0 24 ");
                for (const auto& line:lines) if (line.startsWith('-') && !line.contains("cadnext_name-st-attrib")) {
                    const auto fields=line.split(' ');
                    layout &= fields.size()>5 && fields[3]=="-1" && fields[4]=="$-1";
                }
            }
            check(layout,ext+": AutoCAD SAT 7 record layout and length-prefixed header strings");
        } else {
            DwgModel from; if (readDwgModel(path,from,error)) for (const auto& b:from.bodies) {
                AcisSatResult sat; if (!readAcisSat(b.acis,restored,sat,error,nullptr,b.name,b.millimetresPerUnit)) continue;
                for (const auto& s:sat.solids) { const auto r=restored.transformShape(s.shape,b.placement); if (r.isOk()) shapes.push_back(r.value()); }
            }
            check(from.bodies.size()==bodies.size() && (ext=="dwg" ? from.version=="AC1015" : dxfHasAcisBodies(path)), ext+": actual 3DSOLID entities");
            if (ext=="dxf") {
                std::vector<DxfGroup> groups;
                bool chunking=readDxfGroups(path,groups,error); for (const auto& g:groups) if (g.code==1 || g.code==3) chunking &= g.value.size()<255;
                check(chunking, ext+": ACIS lines respect DXF group limits");
            }
        }
        compare(restored,shapes,expected,ext,ext=="iges"?1e-6:1e-8,expectedParts);
    }

    // Native persistence and BRep exchange are part of the same two-way contract.
    Document document; document.setName("Imported model");
    for (std::size_t i=0;i<bodies.size();++i) {
        const auto bytes=source.exportBRepGeometry(bodies[i].body.shape); if (!bytes.isOk()) return 1;
        Object object; object.id=std::to_string(i); object.name=bodies[i].name; object.type=ObjectType::Body;
        object.transform=bodies[i].body.placement; object.importedBRep=bytes.value(); document.addObject(object);
    }
    const auto path=dir.filePath("model.cadnext").toStdString();
    const auto saved=DocumentSerializer::saveToFile(document,path); const auto loaded=DocumentSerializer::loadFromFile(path);
    check(saved.isOk() && loaded.isOk(), "cadnext: write/read exact imported bodies");
    if (loaded.isOk()) {
        OcctKernel kernel; std::vector<ShapeHandle> shapes;
        for (const auto& object:loaded.value().objects()) {
            const auto r=kernel.importBRep(object.importedBRep); if (!r.isOk()) continue;
            const auto p=kernel.placeExchangeBody({r.value(),object.transform}); if (p.isOk()) shapes.push_back(p.value());
        }
        compare(kernel,shapes,expected,"cadnext/BRep",1e-8,expectedParts);
    }
    // A .uavpart carries one exact body plus its engineering data. The container/CRC
    // tests alone cannot prove that the stored BRep still reconstructs the same solid.
    {
        OcctKernel restored;
        std::vector<ShapeHandle> shapes;
        bool written=true, names=true;
        for (std::size_t i=0;i<expectedShapes.size();++i) {
            bridge::UAVPartDescriptor part;
            part.manifest.id=std::to_string(i);
            part.manifest.name=part.manifest.displayName=bodies[i].name;
            part.material=bridge::uavpartDefaultMaterial();
            const auto& m=expectedParts[i];
            part.mass.volumeM3=m.volume;
            part.mass.densityKgPerM3=part.material.densityKgPerM3;
            part.mass.massKg=m.volume*part.mass.densityKgPerM3;
            part.mass.centerOfMass={m.centre.X(),m.centre.Y(),m.centre.Z()};
            part.mass.boundingBoxMin={m.bounds[0],m.bounds[1],m.bounds[2]};
            part.mass.boundingBoxMax={m.bounds[3],m.bounds[4],m.bounds[5]};
            part.mass.calculationMethod=bridge::kMassCalculationExact;
            part.mass.valid=true;
            const auto bytes=source.exportBRep(expectedShapes[i]);
            if (!bytes.isOk()) { written=false; continue; }
            part.exactGeometry.payload=bytes.value();
            part.exactGeometry.geometryKernel="opencascade";
            part.exactGeometry.representation="brep_ascii";
            part.exactGeometry.valid=true;
            const auto path=dir.filePath(QString("part_%1.uavpart").arg(i)).toStdString();
            const auto saved=bridge::UAVPartWriter().writePart(path,part);
            written &= saved.isOk();
            if (!saved.isOk()) continue;
            const auto loaded=bridge::UAVPartReader().readFullPart(path);
            if (!loaded.isOk()) { names=false; continue; }
            names &= loaded.value().part.manifest.name==bodies[i].name && loaded.value().part.exactGeometry.valid;
            const auto body=restored.importBRep(loaded.value().part.exactGeometry.payload);
            if (body.isOk()) shapes.push_back(body.value());
        }
        check(written && names,"uavpart: write/read exact geometry and body names");
        compare(restored,shapes,expected,"uavpart/BRep",1e-8,expectedParts);
    }
    // Unsupported and invalid exports must preserve an existing destination.
    const QString protectedPath=dir.filePath("existing.sat"); QFile existing(protectedPath);
    if (!existing.open(QIODevice::WriteOnly) || existing.write("keep") != 4) return 1;
    existing.close();
    const auto invalid=writeAcisSat(source,{{"unknown",{ShapeHandle("missing"),{}}}},protectedPath);
    if (!existing.open(QIODevice::ReadOnly)) return 1;
    check(!invalid.isOk() && existing.readAll()=="keep", "SAT: failed export preserves destination");
    sketchRoundTrips(dir);
    dwgBlockBoundaries(dir);
    proceduralSat();
    tolerantSat();
    phasedRingSat();
    periodicBoundaryExchange();
    periodicSplineTube();
    analyticUvFrames();
    thinPlanarStrip();
    touchingHole();
    binaryAcisLoopIndex();
    std::printf("%s: %d failures\n",failures?"FAILED":"OK",failures); return failures?1:0;
}
