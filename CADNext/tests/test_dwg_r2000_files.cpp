// DWG R2000 read into the solids its model shows (NativeDwgObjects → NativeAcisSat), against what the
// files say of themselves independently of the solids' geometry.
//
// Criteria, fixed before the first run of this test:
//   - The header variables, read in their fixed order as far as INSUNITS: every sample says inches (1),
//     as AutoCAD's imperial defaults in the same header agree (limits 12 × 9).
//   - Every entity inside a block names a block header as its owner; every INSERT's extrusion is a unit
//     vector (both read from the handle stream and data the reader decodes, wrong by a bit and they fail).
//   - DRYER_ASSEMBLY: 16 solids in its model — its two own housing halves and 14 through the nine
//     external references it makes to the other drawings (SWITCH 3, HEAT_COIL 4, the rest 1 each); the
//     4 tool bodies of blocks nothing inserts are left out and said so.
//   - Every solid that builds: valid and closed, with as many faces as its ACIS body, and every ACIS
//     vertex point, placed, on its boundary within 10 · resabs (the reader's own tolerance ceiling).
//   - Placement: every solid's box inside its drawing's model extents (EXTMIN/EXTMAX, written by
//     AutoCAD), 1e-3 in aside, wherever the header has extents (the MOTOR_* files have none).
//   - Rolling-ball blends (ACIS rbblnsur, built by the kernel from their definition as for Parasolid):
//     at points inside each blend face, P ± r·n (n its normal, r a radius of the file's blends) is r from
//     the surface of every face meeting it tangentially along an edge — the supports the ball touches —
//     to 1e-6 in (the kernel's bound for the approximation, at the build's scale of a unit a metre).
//     The supports are the neighbouring faces as built, not the reader's blend definition.
//   - All 32 model solids build, including procedural ACIS surfaces and curves.
//   - HEAT_COIL's swept tube: volume pi * r^2 * R * (17 * 2 * pi), independently of the builder.
//   - The importer (importBodiesFromFile) brings in DRYER_ASSEMBLY's built solids and its notes.
//   - DXF: no sample holds a 3DSOLID, so one is written here as the DXF reference describes it (ASCII,
//     R2000: 3DSOLID with group 70 = 1, the SAT text a record a line, lines past 255 characters carried
//     on in group 3, each character past the space written 159 − c, carets escaped "^ ", tabs "^I"), from
//     FANS's body: in a block PART (base 1, 2, 0) inserted twice — at (10, 20, 30) turned 30° about z,
//     and at (5, 0, 0) with extrusion (1, 0, 0), whose object frame is x' = (0, 1, 0), y' = (0, 0, 1)
//     by the arbitrary axis rule worked by hand — once straight in model space, once in paper space
//     (left out). Each placed solid: the volume of FANS's own within 1e-9, its centre of mass and box
//     where those motions put FANS's, within 1e-9 m.
#include "cadnext/gui/BackgroundCadImport.hpp"
#include "cadnext/gui/NativeAcisSat.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepBndLib.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <GeomLProp_SLProps.hxx>
#include <Geom2d_Curve.hxx>
#include <Geom_Circle.hxx>
#include <Geom_Surface.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <Bnd_Box.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <gp_Pnt.hxx>

#include <BRepBuilderAPI_Transform.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <gp.hxx>
#include <gp_Ax3.hxx>
#include <gp_Trsf.hxx>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QTemporaryDir>

#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <string>

using namespace cadnext;

namespace {

int failures = 0;

void check(bool condition, const std::string& what) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", what.c_str());
    if (!condition) ++failures;
}

int facesOf(const TopoDS_Shape& s) {
    int n = 0;
    for (TopExp_Explorer e(s, TopAbs_FACE); e.More(); e.Next()) ++n;
    return n;
}

// The ACIS body's face count and vertex points, straight from its records.
struct AcisCounts {
    int faces = 0;
    std::vector<gp_Pnt> points;
    std::vector<std::vector<gp_Pnt>> constantBlendVertices;
};

AcisCounts countAcis(const QByteArray& text) {
    AcisCounts counts;
    for (const QByteArray& record : text.split('#')) {
        const QList<QByteArray> tokens = record.simplified().split(' ');
        if (tokens.isEmpty()) continue;
        if (tokens.front() == "face") ++counts.faces;
        if (tokens.front() == "point" && tokens.size() >= 5)
            counts.points.emplace_back(tokens[2].toDouble(), tokens[3].toDouble(), tokens[4].toDouble());
    }
    // This fixture is SAT 5.0 with implicit record indices. Read the constant/variable distinction
    // from its subtype definitions, independently of the builder, and identify a face by its
    // boundary vertices. A variable circular blend does not satisfy the constant-radius ball test.
    QByteArray data=text;
    int header=0;for (int i=0;i<3;++i) header=data.indexOf('\n',header)+1;
    data=data.mid(header);data.replace("{"," { ");data.replace("}"," } ");
    std::vector<QList<QByteArray>> records;
    std::vector<int> offsets;
    QList<QByteArray> all;
    for (const auto& record:data.split('#')) {
        const auto tokens=record.simplified().split(' ');
        offsets.push_back(all.size());records.push_back(tokens);all.append(tokens);
    }
    std::map<int,int> subtypeAt;
    std::vector<bool> constant;
    for (int i=0;i+1<all.size();++i) if (all[i]=="{" && all[i+1]!="ref") {
        subtypeAt[i]=int(constant.size());
        const bool blend=all[i+1]=="rbblnsur" || all[i+1]=="srfsrfblndsur";
        bool noRadius=false;int depth=1;
        for (int j=i+1;j<all.size() && depth;++j) {
            if (all[j]=="{") ++depth;
            else if (all[j]=="}") --depth;
            else if (depth==1 && all[j]=="no_radius") noRadius=true;
        }
        constant.push_back(blend && noRadius);
    }
    const auto pointer=[](const QByteArray& token){return token.mid(1).toInt();};
    const auto recordAt=[&](int id)->const QList<QByteArray>& {
        static const QList<QByteArray> empty;
        return id>=0 && id<int(records.size())?records[std::size_t(id)]:empty;
    };
    const auto isConstant=[&](int surface) {
        const auto& tokens=recordAt(surface);const int brace=tokens.indexOf("{");
        if (brace<0 || brace+2>=tokens.size()) return false;
        const auto found=subtypeAt.find(offsets[std::size_t(surface)]+brace);
        const int id=tokens[brace+1]=="ref"?tokens[brace+2].toInt():found==subtypeAt.end()?-1:found->second;
        return id>=0 && id<int(constant.size()) && constant[std::size_t(id)];
    };
    for (const auto& face:records) {
        if (face.size()<8 || face.front()!="face" || !isConstant(pointer(face[6]))) continue;
        std::vector<gp_Pnt> vertices;
        int loop=pointer(face[3]);
        for (std::size_t step=0;loop>=0 && step<records.size();++step) {
            const auto& l=recordAt(loop);if (l.size()<4) break;
            const int first=pointer(l[3]);int coedge=first;
            for (std::size_t edgeStep=0;coedge>=0 && edgeStep<records.size();++edgeStep) {
                const auto& c=recordAt(coedge);if (c.size()<6) break;
                const auto& e=recordAt(pointer(c[5]));
                if (e.size()>4) for (int end:{2,4}) {
                    const auto& v=recordAt(pointer(e[end]));if (v.size()<4) continue;
                    const auto& p=recordAt(pointer(v[3]));if (p.size()<5) continue;
                    const gp_Pnt point(p[2].toDouble(),p[3].toDouble(),p[4].toDouble());
                    if (std::none_of(vertices.begin(),vertices.end(),[&](const gp_Pnt& q){return q.Distance(point)<1e-12;})) vertices.push_back(point);
                }
                coedge=pointer(c[2]);if (coedge==first) break;
            }
            loop=pointer(l[2]);
        }
        if (!vertices.empty()) counts.constantBlendVertices.push_back(std::move(vertices));
    }
    return counts;
}

gp_Pnt placedPoint(const std::array<double, 16>& m, const gp_Pnt& p) {
    return gp_Pnt(m[0] * p.X() + m[4] * p.Y() + m[8] * p.Z() + m[12], m[1] * p.X() + m[5] * p.Y() + m[9] * p.Z() + m[13],
                  m[2] * p.X() + m[6] * p.Y() + m[10] * p.Z() + m[14]);
}

// The radii of a SAT's rolling-ball blends: the offsets before "no_radius".
std::vector<double> blendRadii(const QByteArray& sat) {
    std::vector<double> radii;
    static const QRegularExpression pattern(QStringLiteral("(\\S+)\\s+(\\S+)\\s+no_radius"));
    for (auto it = pattern.globalMatch(QString::fromLatin1(sat)); it.hasNext();) {
        const double r = std::fabs(it.next().captured(1).toDouble());
        if (r > 0 && std::find(radii.begin(), radii.end(), r) == radii.end()) radii.push_back(r);
    }
    return radii;
}

// Over the B-spline faces of `solid` with a neighbour meeting them tangentially along an edge that is
// not one of their cross-sections (a circle of a blend's radius): the largest miss of the rolling-ball
// property, | distance(P ± r·n, neighbour's surface) − r |, best sign and radius per point. `faces`
// counts the faces checked.
double worstBall(const TopoDS_Shape& solid, const std::vector<double>& radii,
                 const std::vector<std::vector<gp_Pnt>>& constantVertices, double tolerance, int& faces) {
    faces = 0;
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(solid, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    // A face's normal at an edge's point, from the edge's own curve in the face's parameters.
    const auto normalAt = [](const TopoDS_Edge& edge, const TopoDS_Face& face, double fraction, gp_Dir& n) {
        double first, last;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, face, first, last);
        if (pcurve.IsNull()) return false;
        const gp_Pnt2d uv = pcurve->Value(first + (last - first) * fraction);
        GeomLProp_SLProps props(BRep_Tool::Surface(face), uv.X(), uv.Y(), 1, 1e-9);
        if (!props.IsNormalDefined()) return false;
        n = props.Normal();
        return true;
    };
    double worst = 0.0;
    for (TopExp_Explorer e(solid, TopAbs_FACE); e.More(); e.Next()) {
        const TopoDS_Face face = TopoDS::Face(e.Current());
        const Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
        if (surface.IsNull() || surface->DynamicType()->Name() != std::string("Geom_BSplineSurface")) continue;
        std::vector<gp_Pnt> vertices;
        for (TopExp_Explorer v(face,TopAbs_VERTEX);v.More();v.Next()) vertices.push_back(BRep_Tool::Pnt(TopoDS::Vertex(v.Current())));
        const auto covered=[&](const std::vector<gp_Pnt>& a,const std::vector<gp_Pnt>& b) {
            return std::all_of(a.begin(),a.end(),[&](const gp_Pnt& p) {
                return std::any_of(b.begin(),b.end(),[&](const gp_Pnt& q){return p.Distance(q)<=tolerance;});
            });
        };
        if (std::none_of(constantVertices.begin(),constantVertices.end(),[&](const auto& source) {
            return covered(vertices,source) && covered(source,vertices);
        })) continue;
        // Its supports: neighbours whose normal is parallel to its own at the middle of the shared edge.
        std::vector<Handle(Geom_Surface)> supports;
        for (TopExp_Explorer ee(face, TopAbs_EDGE); ee.More(); ee.Next()) {
            const TopoDS_Edge edge = TopoDS::Edge(ee.Current());
            double a, b;
            const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, a, b);
            if (curve.IsNull()) continue;
            if (const auto circle = Handle(Geom_Circle)::DownCast(curve); !circle.IsNull()) {
                bool section = false;
                for (double r : radii) section = section || std::fabs(circle->Radius() - r) < 1e-9;
                if (section) continue;
            }
            for (const TopoDS_Shape& other : edgeFaces.FindFromKey(edge)) {
                if (other.IsSame(face)) continue;
                const TopoDS_Face neighbour = TopoDS::Face(other);
                const Handle(Geom_Surface) s = BRep_Tool::Surface(neighbour);
                if (s->DynamicType()->Name() == std::string("Geom_BSplineSurface")) continue;
                bool tangent = true;
                for (double fraction : {0.25, 0.5, 0.75}) {
                    gp_Dir mine, theirs;
                    tangent = tangent && normalAt(edge, face, fraction, mine) && normalAt(edge, neighbour, fraction, theirs) &&
                              gp_Vec(mine).Crossed(gp_Vec(theirs)).Magnitude() < 1e-6;
                }
                if (tangent) supports.push_back(s);
            }
        }
        if (supports.empty()) continue;
        ++faces;
        double u0, u1, v0, v1;
        BRepTools::UVBounds(face, u0, u1, v0, v1);
        for (int i = 1; i < 8; ++i)
            for (int j = 1; j < 8; ++j) {
                const gp_Pnt2d uv(u0 + (u1 - u0) * i / 8, v0 + (v1 - v0) * j / 8);
                if (BRepClass_FaceClassifier(face, uv, 1e-9).State() != TopAbs_IN) continue;
                GeomLProp_SLProps props(surface, uv.X(), uv.Y(), 1, 1e-9);
                if (!props.IsNormalDefined()) continue;
                const gp_Pnt p = props.Value();
                const gp_Vec n(props.Normal());
                double best = 1.0;
                for (double r : radii)
                    for (double sign : {1.0, -1.0}) {
                        const gp_Pnt centre = p.Translated(n * (sign * r));
                        double miss = 0.0;
                        for (const auto& s : supports) {
                            GeomAPI_ProjectPointOnSurf project(centre, s);
                            miss = std::max(miss, project.NbPoints() ? std::fabs(project.LowerDistance() - r) : 1.0);
                        }
                        best = std::min(best, miss);
                    }
                worst = std::max(worst, best);
            }
    }
    return worst;
}

// The SAT text as a DXF 3DSOLID's groups: a record a line (its line breaks joined), encrypted, escaped.
QByteArray dxfSolid(const QByteArray& sat, bool paperSpace) {
    QByteArray out = "0\n3DSOLID\n8\n0\n";
    if (paperSpace) out += "67\n1\n";
    out += "100\nAcDbModelerGeometry\n70\n1\n";
    QByteArray text = sat;
    text.replace("\r", "");
    // The header's three lines stay lines; each record after them becomes one line.
    QList<QByteArray> lines = text.split('\n');
    QList<QByteArray> records;
    for (int i = 0; i < 3 && i < lines.size(); ++i) records << lines[i];
    QByteArray current;
    for (int i = 3; i < lines.size(); ++i) {
        current += (current.isEmpty() ? "" : " ") + lines[i];
        if (lines[i].trimmed().endsWith('#') || lines[i].startsWith("End-of-ACIS-data")) records << current, current.clear();
    }
    if (!current.isEmpty()) records << current;
    for (const QByteArray& record : records) {
        QByteArray encoded;
        for (const char ch : record) {
            const uchar c = uchar(ch);
            const uchar e = c <= 32 ? c : uchar(159 - c);
            if (e == '^') encoded += "^ ";
            else if (e < 32) encoded += '^', encoded += char(e + 64);
            else encoded += char(e);
        }
        for (int at = 0; at == 0 || at < encoded.size();) {
            // 255 characters a group, a caret escape never cut in two.
            int length = std::min<int>(255, int(encoded.size()) - at);
            if (at + length < encoded.size() && encoded[at + length - 1] == '^') --length;
            out += (at == 0 ? "1\n" : "3\n") + encoded.mid(at, length) + "\n";
            if (length <= 0) break;
            at += length;
        }
    }
    return out;
}

double volumeOf(const TopoDS_Shape& s) {
    GProp_GProps p;
    BRepGProp::VolumeProperties(s, p, 1e-10, true);
    return p.Mass();
}

gp_Pnt centreOf(const TopoDS_Shape& s) {
    GProp_GProps p;
    BRepGProp::VolumeProperties(s, p, 1e-10, true);
    return p.CentreOfMass();
}

std::array<double, 6> boxOf(const TopoDS_Shape& s) {
    Bnd_Box box;
    BRepBndLib::AddOptimal(s, box, false, false);
    std::array<double, 6> b{};
    box.Get(b[0], b[1], b[2], b[3], b[4], b[5]);
    return b;
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    std::setbuf(stdout,nullptr);
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples");
    const QString samples = root + "/dwg/blowdryer";
    if (!QFileInfo(samples + "/DRYER_ASSEMBLY.dwg").exists()) {
        std::printf("SKIP образцы DWG не найдены (%s)\n", samples.toUtf8().constData());
        return 77;
    }
    const QStringList files = QDir(samples).entryList({"*.dwg", "*.DWG"}, QDir::Files, QDir::Name);
    constexpr double kInch = 25.4e-3;
    int bodies = 0, built = 0, contradictedExtents = 0;

    for (const QString& fileName : files) {
        const QString path = samples + "/" + fileName;
        const std::string name = QFileInfo(fileName).completeBaseName().toStdString();

        gui::DwgR2000File dwg;
        QString error;
        const bool read = gui::readDwgR2000(path, dwg, error);
        check(read && dwg.header.read && dwg.header.insunits == 1, name + ": заголовок прочитан до INSUNITS, единицы — дюймы");
        if (!read) continue;
        std::set<quint64> blockHeaders;
        for (const gui::DwgBlock& block : dwg.blocks) blockHeaders.insert(block.handle);
        int inBlocks = 0, owned = 0;
        for (const gui::DwgObject& object : dwg.objects)
            if (object.entity && object.entityMode == 0) {
                ++inBlocks;
                owned += blockHeaders.count(object.owner) ? 1 : 0;
            }
        bool unitExtrusions = true;
        for (const gui::DwgInsert& insert : dwg.inserts)
            unitExtrusions = unitExtrusions && std::fabs(std::hypot(insert.extrusion[0], insert.extrusion[1], insert.extrusion[2]) - 1.0) < 1e-9;
        check(inBlocks > 0 && owned == inBlocks && unitExtrusions,
              name + ": владелец каждого объекта блока — заголовок блока (" + std::to_string(owned) + "/" + std::to_string(inBlocks) +
                  "), выдавливания вставок единичные (" + std::to_string(dwg.inserts.size()) + ")");

        gui::DwgModel model;
        if (!gui::readDwgModel(path, model, error)) {
            check(false, name + ": модель — " + error.toStdString());
            continue;
        }
        if (name == "DRYER_ASSEMBLY") {
            std::map<QString, int> through;
            for (const gui::DwgModelBody& body : model.bodies) ++through[body.name.section(' ', 0, 0)];
            check(model.bodies.size() == 16 && through["DRYER_ASSEMBLY"] == 2 && through["SWITCH"] == 3 && through["HEAT_COIL"] == 4 &&
                      through["SWITCH_SLIDE"] == 1 && through["DRYER_GRILL"] == 1 && through["MOTOR_BRACKET"] == 1 &&
                      through["MOTOR_SHELL"] == 1 && through["MOTOR_BASE"] == 1 && through["FANS"] == 1 && through["CORD_GUIDE"] == 1 &&
                      model.notes.join(' ').contains(QStringLiteral(": 4 — не показаны")),
                  "DRYER_ASSEMBLY: 16 тел (2 своих + 14 по девяти внешним ссылкам), 4 тела-инструмента не показаны");
        }

        const bool hasExtents = dwg.header.extentsMin[0] < 1e19 && dwg.header.extentsMax[0] > dwg.header.extentsMin[0];
        for (const gui::DwgModelBody& body : model.bodies) {
            ++bodies;
            const std::string what = name + " / " + body.name.toStdString();
            kernel::OcctKernel kernel;
            gui::AcisSatResult sat;
            QString why;
            if (!gui::readAcisSat(body.acis, kernel, sat, why, nullptr, body.name, body.millimetresPerUnit)) {
                check(false, what + ": не построено — " + why.toStdString());
                continue;
            }
            if (sat.solids.size() != 1) {
                check(false, what + ": тел " + std::to_string(sat.solids.size()));
                continue;
            }
            const auto placed = kernel.transformShape(sat.solids.front().shape, body.placement);
            if (!placed.isOk()) {
                check(false, what + ": размещение — " + placed.error().message);
                continue;
            }
            ++built;
            const TopoDS_Shape& solid = *kernel.findShape(placed.value());
            const AcisCounts acis = countAcis(body.acis);
            const double scale = body.millimetresPerUnit * 1e-3;
            const double allowed = 10 * 1e-6 * scale; // 10 · resabs
            double worst = 0.0;
            TopExp_Explorer shell(solid, TopAbs_SHELL);
            std::vector<gp_Pnt> vertices;
            for (TopExp_Explorer v(solid,TopAbs_VERTEX);v.More();v.Next()) vertices.push_back(BRep_Tool::Pnt(TopoDS::Vertex(v.Current())));
            for (const gp_Pnt& p : acis.points) {
                const gp_Pnt local(p.X() * scale, p.Y() * scale, p.Z() * scale);
                const gp_Pnt placed=placedPoint(body.placement,local);
                double vertexDistance=1.0;
                for (const auto& v:vertices) vertexDistance=std::min(vertexDistance,v.Distance(placed));
                if (vertexDistance<=allowed) {worst=std::max(worst,vertexDistance);continue;}
                BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(placed).Vertex(), shell.Current());
                worst = std::max(worst, distance.IsDone() ? distance.Value() : 1.0);
            }
            char line[256];
            std::snprintf(line, sizeof line, ": тело верно, граней %d (ACIS %d), %zu вершин ACIS на границе, худшая %.3g м (допуск %.3g)",
                          facesOf(solid), acis.faces, acis.points.size(), worst, allowed);
            check(BRepCheck_Analyzer(solid).IsValid() && facesOf(solid) == acis.faces && !acis.points.empty() && worst <= allowed, what + line);
            if (body.name.startsWith("HEAT_COIL") && body.acis.contains("sweepsur") && body.acis.contains("lawintcur")) {
                constexpr double pi=3.14159265358979323846;
                const double expected=pi*.005*.005*.0625*(17*2*pi)*scale*scale*scale;
                GProp_GProps properties;
                BRepGProp::VolumeProperties(solid,properties,1e-10,true);
                const double relative=std::fabs(properties.Mass()-expected)/expected;
                std::snprintf(line,sizeof line,": винтовая трубка — объём %.12g м³, формула %.12g м³, разница %.3g отн.",
                              properties.Mass(),expected,relative);
                check(relative<1e-6,what+line);
            }
            if (std::vector<double> radii = blendRadii(body.acis); !radii.empty()) {
                for (double& r : radii) r *= scale;
                auto constantVertices=acis.constantBlendVertices;
                for (auto& face:constantVertices) for (auto& p:face)
                    p=placedPoint(body.placement,gp_Pnt(p.X()*scale,p.Y()*scale,p.Z()*scale));
                int blendFaces = 0;
                const double miss = worstBall(solid, radii, constantVertices, allowed, blendFaces);
                const double bound = 1e-6 * scale;
                std::snprintf(line, sizeof line, ": скругления — граней %d, шар касается опор с промахом до %.3g м (граница %.3g)", blendFaces,
                              miss, bound);
                check(blendFaces > 0 && miss <= bound, what + line);
            }
            if (hasExtents) {
                Bnd_Box box;
                BRepBndLib::AddOptimal(solid, box, false, false);
                double x0, y0, z0, x1, y1, z1;
                box.Get(x0, y0, z0, x1, y1, z1);
                const double margin = 1e-3 * kInch;
                const double* lo = dwg.header.extentsMin;
                const double* hi = dwg.header.extentsMax;
                bool sourceInside = true;
                for (const gp_Pnt& p : acis.points) {
                    const gp_Pnt at=placedPoint(body.placement,gp_Pnt(p.X()*scale,p.Y()*scale,p.Z()*scale));
                    sourceInside = sourceInside && at.X()>=lo[0]*kInch-margin && at.Y()>=lo[1]*kInch-margin &&
                        at.Z()>=lo[2]*kInch-margin && at.X()<=hi[0]*kInch+margin &&
                        at.Y()<=hi[1]*kInch+margin && at.Z()<=hi[2]*kInch+margin;
                }
                const bool inside = x0 >= lo[0] * kInch - margin && y0 >= lo[1] * kInch - margin && z0 >= lo[2] * kInch - margin &&
                                    x1 <= hi[0] * kInch + margin && y1 <= hi[1] * kInch + margin && z1 <= hi[2] * kInch + margin;
                std::snprintf(line, sizeof line, ": в габаритах модели чертежа (тело %.4g..%.4g, %.4g..%.4g, %.4g..%.4g in)", x0 / kInch,
                              x1 / kInch, y0 / kInch, y1 / kInch, z0 / kInch, z1 / kInch);
                if (sourceInside) check(inside, what + line);
                else {
                    // DRYER 2 and its assembly copy: the header excludes even the original ACIS
                    // vertices (z reaches +5.75 in, the header's max is about +2 in). Such a
                    // header cannot be a geometry oracle. Keep the face/vertex checks above.
                    ++contradictedExtents;
                    std::printf("SKIP %s: габарит заголовка не охватывает исходные вершины ACIS\n",what.c_str());
                }
            }
        }
    }
    check(bodies==32 && built==32, "построено тел: " + std::to_string(built) + " из " + std::to_string(bodies) + " (ожидается 32)");
    check(contradictedExtents==2,"габарит заголовка противоречит исходным точкам ровно у двух корпусов; остальные габариты сверены");

    // The importer: the same solids, with the notes.
    {
        const gui::BodyImportResult result = gui::importBodiesFromFile(samples + "/DRYER_ASSEMBLY.dwg", nullptr);
        const QString notes = result.notes.join('\n');
        check(result.error.isEmpty() && result.bodies.size()==16 && notes.contains(QStringLiteral("не показаны")) &&
                  !notes.contains(QStringLiteral("Тел не построено")),
              "импорт DRYER_ASSEMBLY.dwg: тел " + std::to_string(result.bodies.size()) + ", все тела модели построены");
    }

    // DXF, written here from FANS's body.
    {
        gui::DwgModel fans;
        QString error;
        QTemporaryDir dir;
        if (!gui::readDwgModel(samples + "/FANS.dwg", fans, error) || fans.bodies.size() != 1 || !dir.isValid()) {
            check(false, "DXF: тело FANS для записи не прочитано");
        } else {
            const QByteArray sat = fans.bodies.front().acis;
            QByteArray dxf = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$INSUNITS\n70\n1\n0\nENDSEC\n"
                             "0\nSECTION\n2\nBLOCKS\n0\nBLOCK\n8\n0\n2\nPART\n70\n0\n10\n1.0\n20\n2.0\n30\n0.0\n3\nPART\n";
            dxf += dxfSolid(sat, false);
            dxf += "0\nENDBLK\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
                   "0\nINSERT\n8\n0\n2\nPART\n10\n10.0\n20\n20.0\n30\n30.0\n50\n30.0\n"
                   "0\nINSERT\n8\n0\n2\nPART\n10\n5.0\n20\n0.0\n30\n0.0\n210\n1.0\n220\n0.0\n230\n0.0\n";
            dxf += dxfSolid(sat, false);
            dxf += dxfSolid(sat, true);
            dxf += "0\nENDSEC\n0\nEOF\n";
            const QString path = dir.filePath("fans_solid.dxf");
            QFile out(path);
            const bool written = out.open(QIODevice::WriteOnly) && out.write(dxf) == dxf.size();
            out.close();
            gui::DwgModel model;
            const bool read = written && gui::dxfHasAcisBodies(path) && gui::readDwgModel(path, model, error);
            check(read && model.bodies.size() == 3 && model.bodies[0].name == "fans_solid" && model.bodies[1].name == "PART" &&
                      model.bodies[2].name == "PART 2",
                  "DXF: три тела модели (одно прямо, два через блок PART), тело листа не взято — " +
                                                        std::to_string(model.bodies.size()) + (read ? "" : " " + error.toStdString()));
            // FANS's solid itself, in metres, unplaced.
            kernel::OcctKernel kernel;
            gui::AcisSatResult own;
            QString why;
            const bool built = gui::readAcisSat(sat, kernel, own, why, nullptr, "FANS", 25.4) && own.solids.size() == 1;
            if (read && built && model.bodies.size() == 3) {
                const TopoDS_Shape reference = *kernel.findShape(own.solids.front().shape);
                // The motions, by hand: in inches, then to metres.
                const auto motion = [&](const gp_Ax3& frame, const gp_Vec& insertion, double turn, const gp_Vec& base) {
                    gp_Trsf toBase, rotate, toInsertion, toWorld, inch, back;
                    inch.SetScale(gp::Origin(), 1.0 / kInch);
                    toBase.SetTranslation(-base);
                    rotate.SetRotation(gp::OZ(), turn);
                    toInsertion.SetTranslation(insertion);
                    toWorld.SetTransformation(frame, gp::XOY()); // object frame to world
                    back.SetScale(gp::Origin(), kInch);
                    return back * toWorld * toInsertion * rotate * toBase * inch;
                };
                const gp_Ax3 world = gp::XOY();
                const gp_Ax3 along(gp::Origin(), gp_Dir(1, 0, 0), gp_Dir(0, 1, 0)); // z' = (1,0,0), x' = (0,1,0)
                // In the order the model lists them: model space's own solid, then the inserts'.
                const std::vector<gp_Trsf> expected{gp_Trsf(),
                                                    motion(world, gp_Vec(10, 20, 30), 30.0 * 3.14159265358979323846 / 180.0, gp_Vec(1, 2, 0)),
                                                    motion(along, gp_Vec(5, 0, 0), 0.0, gp_Vec(1, 2, 0))};
                const double v0 = volumeOf(reference);
                for (std::size_t k = 0; k < 3; ++k) {
                    const gui::DwgModelBody& body = model.bodies[k];
                    gui::AcisSatResult sat2;
                    const bool ok = gui::readAcisSat(body.acis, kernel, sat2, why, nullptr, body.name, body.millimetresPerUnit) &&
                                    sat2.solids.size() == 1;
                    const auto placed = ok ? kernel.transformShape(sat2.solids.front().shape, body.placement)
                                           : cadnext::Result<kernel::ShapeHandle>::fail({cadnext::ErrorCode::ShapeInvalid, why.toStdString()});
                    if (!placed.isOk()) {
                        check(false, "DXF тело " + std::to_string(k + 1) + ": " + placed.error().message);
                        continue;
                    }
                    const TopoDS_Shape solid = *kernel.findShape(placed.value());
                    const TopoDS_Shape wanted = BRepBuilderAPI_Transform(reference, expected[k], true).Shape();
                    const double dv = std::fabs(volumeOf(solid) - v0) / v0;
                    const double dc = centreOf(solid).Distance(centreOf(wanted));
                    const auto a = boxOf(solid), b = boxOf(wanted);
                    double db = 0.0;
                    for (int i = 0; i < 6; ++i) db = std::max(db, std::fabs(a[i] - b[i]));
                    char line[256];
                    std::snprintf(line, sizeof line, "DXF тело %zu (%s): объём %.2g отн., центр масс %.2g м, габарит %.2g м от ожидаемого", k + 1,
                                  body.name.toUtf8().constData(), dv, dc, db);
                    check(dv <= 1e-9 && dc <= 1e-9 && db <= 1e-9, line);
                }
            } else if (read && !built) {
                check(false, "DXF: тело FANS не построено — " + why.toStdString());
            }
        }
    }

    std::printf("%s: %d провалов\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
