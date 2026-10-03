#include "cadnext/gui/NativeKompasMesh.hpp"

#include <QObject>

#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepClass3d.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <gp_Pln.hxx>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <stdexcept>

namespace cadnext::gui {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr std::size_t kMaxItems = 50'000'000;

struct Writer {
    QByteArray bytes;
    void number(quint64 value, int width) {
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void real(double value) {
        quint64 bits;
        std::memcpy(&bits, &value, sizeof bits);
        number(bits, 8);
    }
    void single(float value) {
        quint32 bits;
        std::memcpy(&bits, &value, sizeof bits);
        number(bits, 4);
    }
};

struct Reader {
    const QByteArray& bytes;
    qsizetype at = 0;
    quint64 number(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("truncated");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 value, int width) {
        if (number(width) != value) throw std::runtime_error("layout");
    }
    double real() {
        const quint64 bits = number(8);
        double value;
        std::memcpy(&value, &bits, sizeof value);
        if (!std::isfinite(value)) throw std::runtime_error("real");
        return value;
    }
    float single() {
        const quint32 bits = quint32(number(4));
        float value;
        std::memcpy(&value, &bits, sizeof value);
        if (!std::isfinite(value)) throw std::runtime_error("real");
        return value;
    }
    std::size_t count(std::size_t itemBytes) {
        const quint64 n = number(8);
        if (n > kMaxItems || n * itemBytes > quint64(bytes.size() - at)) throw std::runtime_error("count");
        return std::size_t(n);
    }
};

// A grid: two set markers, the face's name (count, words, three header bytes), the extent, the planar normal,
// the planar flag and a set flag, 20 empty bytes, points, normals, triangles, quadrangles, a set flag and the
// step, a set flag and the boundaries (each a set flag and its point indices).
void writeGrid(Writer& w, const KompasMeshGrid& g) {
    if (g.names.empty() || g.names.size() > 255 || g.nameTail > 0xffffff || g.points.size() != g.normals.size())
        throw std::runtime_error("grid");
    w.number(1, 1);
    w.number(1, 1);
    w.number(g.names.size(), 1);
    for (const quint32 name : g.names) w.number(name, 4);
    w.number(g.nameTail, 3);
    for (const double v : g.extent) w.real(v);
    for (const double v : g.normal) w.real(v);
    w.number(g.planar ? 1 : 0, 1);
    w.number(1, 1);
    w.bytes.append(20, '\0');
    w.number(g.points.size(), 8);
    for (const auto& p : g.points)
        for (const float v : p) w.single(v);
    w.number(g.normals.size(), 8);
    for (const auto& n : g.normals)
        for (const float v : n) w.single(v);
    w.number(g.triangles.size(), 8);
    for (const auto& t : g.triangles)
        for (const quint32 i : t) {
            if (i >= g.points.size()) throw std::runtime_error("triangle");
            w.number(i, 4);
        }
    w.number(g.quadrangles.size(), 8);
    for (const auto& q : g.quadrangles)
        for (const quint32 i : q) {
            if (i >= g.points.size()) throw std::runtime_error("quadrangle");
            w.number(i, 4);
        }
    w.number(1, 1);
    for (const double v : g.step) w.real(v);
    w.number(1, 1);
    w.number(g.boundaries.size(), 8);
    for (const auto& b : g.boundaries) {
        w.number(1, 1);
        w.number(b.size(), 8);
        for (const quint32 i : b) {
            if (i >= g.points.size()) throw std::runtime_error("boundary");
            w.number(i, 4);
        }
    }
}

KompasMeshGrid readGrid(Reader& r) {
    KompasMeshGrid g;
    r.expect(1, 1);
    r.expect(1, 1);
    const auto names = r.number(1);
    if (!names) throw std::runtime_error("names");
    for (quint64 i = 0; i < names; ++i) g.names.push_back(quint32(r.number(4)));
    g.nameTail = quint32(r.number(3));
    for (double& v : g.extent) v = r.real();
    for (double& v : g.normal) v = r.real();
    const auto planar = r.number(1);
    if (planar > 1) throw std::runtime_error("planar");
    g.planar = planar != 0;
    r.expect(1, 1);
    for (int i = 0; i < 20; ++i) r.expect(0, 1);
    g.points.resize(r.count(12));
    for (auto& p : g.points)
        for (float& v : p) v = r.single();
    g.normals.resize(r.count(12));
    for (auto& n : g.normals)
        for (float& v : n) v = r.single();
    if (g.normals.size() != g.points.size()) throw std::runtime_error("normals");
    g.triangles.resize(r.count(12));
    for (auto& t : g.triangles)
        for (quint32& i : t) {
            i = quint32(r.number(4));
            if (i >= g.points.size()) throw std::runtime_error("triangle");
        }
    g.quadrangles.resize(r.count(16));
    for (auto& q : g.quadrangles)
        for (quint32& i : q) {
            i = quint32(r.number(4));
            if (i >= g.points.size()) throw std::runtime_error("quadrangle");
        }
    r.expect(1, 1);
    for (double& v : g.step) v = r.real();
    r.expect(1, 1);
    g.boundaries.resize(r.count(9));
    for (auto& b : g.boundaries) {
        r.expect(1, 1);
        b.resize(r.count(4));
        for (quint32& i : b) {
            i = quint32(r.number(4));
            if (i >= g.points.size()) throw std::runtime_error("boundary");
        }
    }
    return g;
}

// A group: a set marker, the colour, the material, flags, a key, a set marker, its grids, an empty byte.
void writeGroups(Writer& w, const std::vector<KompasMeshGroup>& groups) {
    w.number(groups.size(), 8);
    for (const auto& group : groups) {
        if (group.color > 0xffffff) throw std::runtime_error("colour");
        w.number(1, 1);
        w.number(group.color, 4);
        for (const quint8 v : group.material) w.number(v, 1);
        w.number(group.flags, 1);
        w.number(group.key, 4);
        w.number(1, 1);
        w.number(group.grids.size(), 8);
        for (const auto& g : group.grids) writeGrid(w, g);
        w.number(0, 1);
    }
}

std::vector<KompasMeshGroup> readGroups(Reader& r) {
    std::vector<KompasMeshGroup> groups(r.count(1));
    for (auto& group : groups) {
        r.expect(1, 1);
        group.color = quint32(r.number(4));
        for (quint8& v : group.material) v = quint8(r.number(1));
        group.flags = quint8(r.number(1));
        group.key = quint32(r.number(4));
        r.expect(1, 1);
        const std::size_t grids = r.count(60);
        for (std::size_t i = 0; i < grids; ++i) group.grids.push_back(readGrid(r));
        r.expect(0, 1);
    }
    return groups;
}

// Each boundary of a triangulation as KOMPAS writes it: the points of one closed run of edges that belong to
// one triangle only, in the triangles' sense, from its first point, open (the last point joins the first).
std::vector<std::vector<quint32>> boundariesOf(const std::vector<std::array<quint32, 3>>& triangles) {
    std::map<std::pair<quint32, quint32>, int> uses;
    for (const auto& t : triangles)
        for (int k = 0; k < 3; ++k) {
            const quint32 a = t[k], b = t[(k + 1) % 3];
            ++uses[{std::min(a, b), std::max(a, b)}];
        }
    std::multimap<quint32, quint32> next;
    for (const auto& t : triangles)
        for (int k = 0; k < 3; ++k) {
            const quint32 a = t[k], b = t[(k + 1) % 3];
            if (uses[{std::min(a, b), std::max(a, b)}] == 1) next.emplace(a, b);
        }
    std::vector<std::vector<quint32>> out;
    while (!next.empty()) {
        quint32 start = next.begin()->first;
        std::vector<quint32> loop;
        quint32 at = start;
        for (std::size_t guard = 0; guard <= triangles.size() * 3; ++guard) {
            loop.push_back(at);
            const auto found = next.find(at);
            if (found == next.end()) break;
            const quint32 to = found->second;
            next.erase(found);
            if (to == start) break;
            at = to;
        }
        out.push_back(std::move(loop));
    }
    return out;
}

} // namespace

bool encodeKompasMesh(const KompasMesh& mesh, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    try {
        Writer w;
        w.number(1, 1);
        writeGroups(w, mesh.curved);
        writeGroups(w, mesh.planar);
        w.number(1, 1);
        for (const double v : mesh.box) w.real(v);
        bytes = std::move(w.bytes);
        return true;
    } catch (const std::exception&) {
        error = QObject::tr("Недопустимая сетка отображения КОМПАС.");
        return false;
    }
}

bool decodeKompasMesh(const QByteArray& bytes, KompasMesh& mesh, QString& error) {
    mesh = {};
    error.clear();
    try {
        Reader r{bytes};
        r.expect(1, 1);
        mesh.curved = readGroups(r);
        mesh.planar = readGroups(r);
        r.expect(1, 1);
        for (double& v : mesh.box) v = r.real();
        if (r.at != bytes.size()) throw std::runtime_error("trailing");
        return true;
    } catch (const std::exception&) {
        mesh = {};
        error = QObject::tr("Сетка отображения КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

std::array<double, 3> kompasMeshStep(double modelDiagonalMm) {
    return {0.001472 * modelDiagonalMm, 2 * kPi / 50, 1e10};
}

bool kompasBodyMesh(kernel::OcctKernel& kernel, kernel::ShapeHandle body, quint32 mainName,
                    const std::array<double, 3>& step, quint32 color, const std::array<quint8, 6>& material,
                    KompasMesh& mesh, QString& error) {
    mesh = {};
    error.clear();
    const TopoDS_Shape* source = kernel.findShape(body);
    if (!source || source->IsNull() || !(step[0] > 0) || !(step[1] > 0) || color > 0xffffff) {
        error = QObject::tr("Сетка отображения КОМПАС: нет тела или недопустимый шаг.");
        return false;
    }
    try {
        // A copy keeps the kernel's own shape free of this triangulation; the copy's faces come in the
        // same order.
        const TopoDS_Shape shape = BRepBuilderAPI_Copy(*source, true, false).Shape();
        BRepMesh_IncrementalMesh mesher(shape, step[0] / 1000.0, false, step[1], false);
        if (!mesher.IsDone()) throw std::runtime_error("the triangulation failed");
        KompasMeshGroup curved, planar;
        curved.color = planar.color = color;
        curved.material = planar.material = material;
        // KOMPAS's own key of its default colour and material (in the parts of several authors); another
        // attribute set is written without a key, as KOMPAS also writes one.
        const bool standard = color == 0x00909090 && material == std::array<quint8, 6>{50, 60, 80, 80, 100, 50};
        curved.flags = planar.flags = standard ? 3 : 1;
        curved.key = planar.key = standard ? 0xbd397667u : 0u;
        // The faces in describeExactBRep's order: each solid's outer shell, then its other shells.
        std::vector<TopoDS_Face> faces;
        for (TopExp_Explorer solids(shape, TopAbs_SOLID); solids.More(); solids.Next()) {
            const TopoDS_Solid& solid = TopoDS::Solid(solids.Current());
            const TopoDS_Shell outer = BRepClass3d::OuterShell(solid);
            std::vector<TopoDS_Shell> shells{outer};
            for (TopExp_Explorer it(solid, TopAbs_SHELL); it.More(); it.Next())
                if (!it.Current().IsSame(outer)) shells.push_back(TopoDS::Shell(it.Current()));
            for (const auto& shell : shells)
                for (TopExp_Explorer it(shell, TopAbs_FACE); it.More(); it.Next()) faces.push_back(TopoDS::Face(it.Current()));
        }
        if (faces.empty()) throw std::runtime_error("the body has no faces");
        double low[3] = {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(),
                         std::numeric_limits<double>::infinity()};
        double high[3] = {-low[0], -low[1], -low[2]};
        for (std::size_t k = 0; k < faces.size(); ++k) {
            const TopoDS_Face& face = faces[k];
            TopLoc_Location location;
            const Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, location);
            if (triangulation.IsNull() || triangulation->NbNodes() < 3 || !triangulation->HasUVNodes())
                throw std::runtime_error("a face has no triangulation");
            const bool reversed = face.Orientation() == TopAbs_REVERSED;
            const BRepAdaptor_Surface surface(face, false);
            const gp_Trsf transform = location.Transformation();
            KompasMeshGrid grid;
            grid.names = {mainName, quint32(k + 1)};
            grid.step = step;
            double gLow[3] = {low[0], low[1], low[2]}, gHigh[3] = {high[0], high[1], high[2]};
            for (int i = 0; i < 3; ++i) gLow[i] = std::numeric_limits<double>::infinity(), gHigh[i] = -gLow[i];
            for (int i = 1; i <= triangulation->NbNodes(); ++i) {
                const gp_Pnt p = triangulation->Node(i).Transformed(transform);
                const gp_Pnt2d uv = triangulation->UVNode(i);
                gp_Pnt at;
                gp_Vec du, dv;
                surface.D1(uv.X(), uv.Y(), at, du, dv);
                gp_Vec n = du.Crossed(dv);
                if (n.Magnitude() < 1e-300) {
                    // A pole (a cone's apex, a sphere's): the normal of the nearest regular point.
                    surface.D1(uv.X() + 1e-7, uv.Y() + 1e-7, at, du, dv);
                    n = du.Crossed(dv);
                }
                if (n.Magnitude() > 1e-300) n.Normalize();
                n.Transform(transform);
                if (reversed) n.Reverse();
                const double mm[3] = {p.X() * 1000, p.Y() * 1000, p.Z() * 1000};
                for (int a = 0; a < 3; ++a) {
                    gLow[a] = std::min(gLow[a], mm[a]);
                    gHigh[a] = std::max(gHigh[a], mm[a]);
                }
                grid.points.push_back({float(mm[0]), float(mm[1]), float(mm[2])});
                grid.normals.push_back({float(n.X()), float(n.Y()), float(n.Z())});
            }
            for (int i = 1; i <= triangulation->NbTriangles(); ++i) {
                int a, b, c;
                triangulation->Triangle(i).Get(a, b, c);
                if (reversed) std::swap(b, c);
                grid.triangles.push_back({quint32(a - 1), quint32(b - 1), quint32(c - 1)});
            }
            for (int a = 0; a < 3; ++a) {
                grid.extent[std::size_t(a)] = gHigh[a] - gLow[a];
                low[a] = std::min(low[a], gLow[a]);
                high[a] = std::max(high[a], gHigh[a]);
            }
            grid.planar = surface.GetType() == GeomAbs_Plane;
            if (grid.planar) {
                gp_Dir n = surface.Plane().Axis().Direction();
                n.Transform(transform);
                if (reversed) n.Reverse();
                grid.normal = {n.X(), n.Y(), n.Z()};
            }
            // A planar face bounded by three or four points has its boundary unwritten, as KOMPAS has it.
            grid.boundaries = boundariesOf(grid.triangles);
            if (grid.planar && grid.boundaries.size() == 1 && grid.boundaries.front().size() <= 4) grid.boundaries.clear();
            (grid.planar ? planar : curved).grids.push_back(std::move(grid));
        }
        // The body's box, exactly; the mesh's where the exact one is not found.
        Bnd_Box box;
        BRepBndLib::AddOptimal(*source, box, false, false);
        if (!box.IsVoid()) {
            double x0, y0, z0, x1, y1, z1;
            box.Get(x0, y0, z0, x1, y1, z1);
            low[0] = x0 * 1000, low[1] = y0 * 1000, low[2] = z0 * 1000;
            high[0] = x1 * 1000, high[1] = y1 * 1000, high[2] = z1 * 1000;
        }
        mesh.box = {low[0], low[1], low[2], high[0], high[1], high[2], high[0] - low[0], high[1] - low[1], high[2] - low[2]};
        if (!curved.grids.empty()) mesh.curved.push_back(std::move(curved));
        if (!planar.grids.empty()) mesh.planar.push_back(std::move(planar));
        return true;
    } catch (const Standard_Failure& failure) {
        error = QObject::tr("Сетка отображения КОМПАС: %1").arg(QString::fromUtf8(failure.GetMessageString()));
    } catch (const std::exception& failure) {
        error = QObject::tr("Сетка отображения КОМПАС: %1").arg(QString::fromUtf8(failure.what()));
    }
    mesh = {};
    return false;
}

} // namespace cadnext::gui
