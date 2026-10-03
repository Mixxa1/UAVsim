#include "cadnext/gui/NativeKompasC3d.hpp"

#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeKompasCatalog.hpp"
#include "cadnext/gui/NativeKompasGeometry.hpp"
#include "NativeKompasNurbsCurve.hpp"

#include <QDir>
#include <QFileInfo>
#include <QObject>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <unordered_map>

namespace cadnext::gui {

namespace {

using cadnext::Vector3;

// Classes of the C3D serialisation read here.
enum : quint16 {
    kShell = 0x6239,
    kFace = 0x666e,
    kLoop = 0x7d68,
    kEdge = 0x4313,
    kVertex = 0x0b04,
    kIntersection = 0x776d,
    kPlane = 0x601e,
    kCylinder = 0x145d,
    kCone = 0x1848,
    kTorus = 0x5d66,
    kSphere = 0x622e,
    kSpline = 0x6e36,
    kLine2 = 0x0847,
    kArc2 = 0x106a,
    kTrimmed2 = 0x537d,
    kContour2 = 0x0c74,
    kHermite2 = 0x1e16,
    kNurbs2 = 0x7505,
    kLine3 = 0x3b01,
    kArc3 = 0x232c,
    kNurbs3 = 0x464f,
    kSpline3 = 0x1c38,    // a curve through points: points, parameters (met as a cached 3D curve only)
    kTrimmed3 = 0x1750,   // a trimmed 3D curve: its basis, a byte, two parameters (cached 3D curve only)
    kBasedCurve3 = 0x0859, // a basis curve, two parameters, a word (cached 3D curve only)
    kColour = 0x6217,     // a topology item's attribute: a base of 10 bytes and 12 of its own (all zero seen)
};

struct Obj {
    quint16 cls = 0;
    int id = -1;
    std::vector<double> d;                     // the class's reals, in order
    std::vector<Obj*> list;                    // a shell's faces, a face's loops, a contour's pieces
    std::vector<std::pair<Obj*, int>> entries; // a loop's edges and their directions
    Obj* surface = nullptr;                    // a face's
    Obj* curve = nullptr;                      // an edge's intersection curve; a trimmed curve's basis
    Obj* begin = nullptr;                      // an edge's vertices
    Obj* end = nullptr;
    Obj* s1 = nullptr;                         // an intersection's surfaces and its curves in them
    Obj* c1 = nullptr;
    Obj* s2 = nullptr;
    Obj* c2 = nullptr;
    int flag = 0; // a face: its normal the surface's (1); an intersection: running with its edge (1)
    int buildType = 0; // native MbeCurveBuildType of an intersection
    std::vector<double> points, params, vectors; // a Hermite spline; a spline surface's poles (points)
    // A spline surface: its grid of poles, rows along v and columns along u, each row's poles in turn
    // (points), their weights, orders and knots (all of them, repeats written out).
    quint64 rows = 0, columns = 0, uOrder = 0, vOrder = 0;
    bool closedU = false, closedV = false;
    std::vector<double> weights, uKnots, vKnots;
    detail::KompasNurbs2 nurbs2;
};

struct Stream {
    const QByteArray& bytes;
    qsizetype at;
    std::vector<std::unique_ptr<Obj>>& store;
    std::unordered_map<int, Obj*>& registry;
    QString why;

    bool has(qsizetype n) const { return at + n <= bytes.size(); }
    bool fail(const QString& reason) {
        if (why.isEmpty()) why = reason;
        return false;
    }
    bool u8(int& v) {
        if (!has(1)) return fail(QObject::tr("поток C3D обрезан"));
        v = uchar(bytes[at++]);
        return true;
    }
    bool u16(int& v) {
        if (!has(2)) return fail(QObject::tr("поток C3D обрезан"));
        v = uchar(bytes[at]) | (uchar(bytes[at + 1]) << 8);
        at += 2;
        return true;
    }
    bool u64(quint64& v) {
        if (!has(8)) return fail(QObject::tr("поток C3D обрезан"));
        v = 0;
        for (int i = 0; i < 8; ++i) v |= quint64(uchar(bytes[at + i])) << (8 * i);
        at += 8;
        return true;
    }
    bool count(quint64& v, quint64 limit = 1000000) {
        if (!u64(v)) return false;
        return v <= limit || fail(QObject::tr("число элементов C3D %1 невероятно").arg(v));
    }
    bool skip(qsizetype n) {
        if (!has(n)) return fail(QObject::tr("поток C3D обрезан"));
        at += n;
        return true;
    }
    bool reals(std::vector<double>& out, quint64 n) {
        if (!has(qsizetype(n) * 8)) return fail(QObject::tr("поток C3D обрезан"));
        for (quint64 i = 0; i < n; ++i) {
            double v;
            std::memcpy(&v, bytes.constData() + at, 8);
            at += 8;
            if (!std::isfinite(v)) return fail(QObject::tr("не число в данных C3D"));
            out.push_back(v);
        }
        return true;
    }
    bool expect(const char* data, int n, const QString& what) {
        if (!has(n) || std::memcmp(bytes.constData() + at, data, std::size_t(n)) != 0)
            return fail(QObject::tr("C3D: нет %1 на байте %2").arg(what).arg(at));
        at += n;
        return true;
    }
    // A topology item's header: a count, that many words (its name), three bytes, its attributes (a count
    // and each one an object).
    bool topology(int depth) {
        int n = 0;
        quint64 attributes = 0;
        if (!u8(n) || n > 16 || !skip(4 * n) || !skip(3) || !count(attributes, 64)) return false;
        for (quint64 i = 0; i < attributes; ++i) {
            Obj* attribute = nullptr;
            if (!pointer(attribute, depth)) return false;
            if (!attribute) return fail(QObject::tr("пустой атрибут топологии C3D"));
        }
        return true;
    }

    // A pointer: 00 none, 01 and a number a written object, 02 a new one.
    bool pointer(Obj*& out, int depth = 0) {
        out = nullptr;
        int tag = 0;
        if (!u8(tag)) return false;
        if (tag == 0) return true;
        if (tag == 1) {
            int id = 0;
            if (!u16(id)) return false;
            const auto it = registry.find(id);
            if (it == registry.end()) return fail(QObject::tr("ссылка C3D на объект %1, которого ещё не было").arg(id));
            out = it->second;
            return true;
        }
        if (tag != 2) return fail(QObject::tr("C3D: метка указателя %1 на байте %2").arg(tag).arg(at - 1));
        if (depth > 64) return fail(QObject::tr("C3D: вложенность объектов слишком глубока"));
        int flag = 0, cls = 0;
        if (!u8(flag) || !u16(cls)) return false;
        auto object = std::make_unique<Obj>();
        object->cls = quint16(cls);
        if (flag == 0x80) {
            int tagId = 0, id = 0;
            if (!u8(tagId) || !u16(id)) return false;
            if (tagId != 1) return fail(QObject::tr("C3D: метка номера объекта %1").arg(tagId));
            object->id = id;
            registry[id] = object.get();
        } else if (flag != 0) {
            return fail(QObject::tr("C3D: признак объекта %1").arg(flag));
        }
        Obj* o = object.get();
        store.push_back(std::move(object));
        out = o;
        return body(*o, depth + 1);
    }

    bool surfaceCurve(Obj*& surface, Obj*& curve, int depth) {
        return expect("\x00\x65\x46", 3, QObject::tr("кривой на поверхности")) && pointer(surface, depth) && pointer(curve, depth);
    }

    bool body(Obj& o, int depth) {
        quint64 n = 0;
        int byte = 0;
        switch (o.cls) {
        case kShell:
            if (!count(n)) return false;
            for (quint64 i = 0; i < n; ++i) {
                Obj* face = nullptr;
                if (!pointer(face, depth)) return false;
                if (!face || face->cls != kFace) return fail(QObject::tr("в оболочке C3D не грань"));
                o.list.push_back(face);
            }
            return true;
        case kFace:
            if (!topology(depth) || !skip(1) || !pointer(o.surface, depth) || !u8(o.flag) || !count(n)) return false;
            for (quint64 i = 0; i < n; ++i) {
                Obj* loop = nullptr;
                if (!pointer(loop, depth)) return false;
                if (!loop || loop->cls != kLoop) return fail(QObject::tr("у грани C3D не цикл"));
                o.list.push_back(loop);
            }
            return reals(o.d, 6);
        case kLoop:
            if (!count(n)) return false;
            for (quint64 i = 0; i < n; ++i) {
                Obj* edge = nullptr;
                if (!pointer(edge, depth) || !u8(byte)) return false;
                if (!edge || edge->cls != kEdge) return fail(QObject::tr("в цикле C3D не ребро"));
                o.entries.push_back({edge, byte});
            }
            return reals(o.d, 4);
        case kEdge:
            return topology(depth) && pointer(o.curve, depth) && pointer(o.begin, depth) && pointer(o.end, depth) &&
                   o.curve && o.begin && o.end && o.begin->cls == kVertex && o.end->cls == kVertex;
        case kVertex:
            return topology(depth) && reals(o.d, 4);
        case kIntersection: {
            Obj* cached = nullptr;
            return surfaceCurve(o.s1, o.c1, depth) && surfaceCurve(o.s2, o.c2, depth) && u8(byte) && u8(o.buildType) && reals(o.d, 8) &&
                   pointer(cached, depth) && u8(o.flag);
        }
        case kPlane: return reals(o.d, 22);
        case kCylinder: return reals(o.d, 24);
        case kCone: return reals(o.d, 25);
        case kTorus: return reals(o.d, 24);
        case kSphere: return reals(o.d, 23);
        case kSpline: {
            // Bounding box; closed along u, along v (0 or 1); the grid; orders; weights; knots; four bytes
            // 'BBBB'; the parameter range. Closed along a direction: its first and last poles the same and its
            // knots continued by order − 1 more (a period on), of which the first poles + order describe it.
            int first = 0, second = 0;
            quint64 nu = 0, nv = 0;
            if (!reals(o.d, 6) || !u8(first) || !u8(second)) return false;
            if (first > 1 || second > 1)
                return fail(QObject::tr("признаки сплайновой поверхности C3D %1 %2 в образцах не встречались").arg(first).arg(second));
            o.closedU = first == 1;
            o.closedV = second == 1;
            if (!count(o.rows, 10000) || !count(o.columns, 10000) || o.rows * o.columns > 1000000 ||
                !reals(o.points, 3 * o.rows * o.columns) || !count(o.uOrder, 64) || !count(o.vOrder, 64) ||
                !reals(o.weights, o.rows * o.columns) || !count(nu) || !reals(o.uKnots, nu) || !count(nv) || !reals(o.vKnots, nv) ||
                !expect("BBBB", 4, QObject::tr("метки сплайновой поверхности")) || !reals(o.d, 4))
                return false;
            if (o.uOrder < 2 || o.vOrder < 2 || o.columns < o.uOrder || o.rows < o.vOrder ||
                nu != o.columns + o.uOrder + (o.closedU ? o.uOrder - 1 : 0) || nv != o.rows + o.vOrder + (o.closedV ? o.vOrder - 1 : 0))
                return fail(QObject::tr("сетка сплайновой поверхности C3D не согласована с порядками и узлами"));
            o.uKnots.resize(std::size_t(o.columns + o.uOrder));
            o.vKnots.resize(std::size_t(o.rows + o.vOrder));
            for (quint64 j = 0; j < o.rows && o.closedU; ++j)
                for (int k = 0; k < 3; ++k)
                    if (o.points[3 * (j * o.columns) + k] != o.points[3 * (j * o.columns + o.columns - 1) + k])
                        return fail(QObject::tr("замкнутая по u сплайновая поверхность C3D с разными крайними полюсами"));
            for (quint64 i = 0; i < o.columns && o.closedV; ++i)
                for (int k = 0; k < 3; ++k)
                    if (o.points[3 * i + k] != o.points[3 * ((o.rows - 1) * o.columns + i) + k])
                        return fail(QObject::tr("замкнутая по v сплайновая поверхность C3D с разными крайними полюсами"));
            for (double w : o.weights)
                if (!(w > 0.0)) return fail(QObject::tr("неположительный вес сплайновой поверхности C3D"));
            for (const auto* knots : {&o.uKnots, &o.vKnots})
                for (std::size_t i = 1; i < knots->size(); ++i)
                    if ((*knots)[i] < (*knots)[i - 1]) return fail(QObject::tr("убывающие узлы сплайновой поверхности C3D"));
            return true;
        }
        case kLine2: return reals(o.d, 4);
        case kNurbs2: {
            qsizetype consumed=0;QString error;
            if(!detail::decodeKompasNurbs2Data(bytes,at,o.nurbs2,consumed,error))return fail(error);
            at+=consumed;return true;
        }
        case kArc2: return reals(o.d, 10) && skip(6);
        case kTrimmed2:
            // Its basis, reversed or not, the two parameters. (Read before as t1, the byte, t2: the same bytes
            // wherever t1 is 0, as it was in every trimmed curve of the first five parts.)
            return pointer(o.curve, depth) && o.curve && u8(o.flag) && reals(o.d, 2);
        case kContour2:
            if (!reals(o.d, 6) || !u8(byte) || !count(n)) return false;
            for (quint64 i = 0; i < n; ++i) {
                Obj* piece = nullptr;
                if (!pointer(piece, depth)) return false;
                if (!piece) return fail(QObject::tr("пустой сегмент контура C3D"));
                o.list.push_back(piece);
            }
            return true;
        case kHermite2: {
            // Points, five reals, closed (1) or not, parameters — one more than the points when closed, the
            // last segment running back to the first point — and a tangent at each point.
            quint64 m = 0;
            return count(n) && reals(o.points, 2 * (n + 1)) && reals(o.d, 5) && u8(o.flag) && o.flag <= 1 && count(m) &&
                   reals(o.params, m + 1) && reals(o.vectors, 2 * (n + 1)) && m == n + quint64(o.flag);
        }
        case kLine3: return reals(o.d, 6);
        case kArc3: return reals(o.d, 16) && u8(byte);
        case kNurbs3: {
            quint64 m = 0, order = 0;
            std::vector<double> ignored;
            return count(n) && reals(ignored, 3 * (n + 1)) && reals(ignored, 7) && u8(byte) && u64(order) && count(m) && skip(2) &&
                   reals(ignored, n + 1) && reals(ignored, m + 1);
        }
        case kSpline3: {
            quint64 m = 0;
            std::vector<double> ignored;
            return count(n) && reals(ignored, 3 * (n + 1)) && reals(ignored, 7) && u8(byte) && count(m) && reals(ignored, m + 1);
        }
        case kTrimmed3: {
            std::vector<double> ignored;
            return pointer(o.curve, depth) && o.curve && u8(byte) && reals(ignored, 2);
        }
        case kBasedCurve3: {
            std::vector<double> ignored;
            return pointer(o.curve, depth) && o.curve && reals(ignored, 2) && skip(4);
        }
        case kColour: return skip(10) && skip(12);
        default:
            return fail(QObject::tr("класс C3D %1 пока не разобран").arg(QString::number(o.cls, 16)));
        }
    }
};

// --- Geometry in the file's units (millimetres) -------------------------------------------------------

Vector3 v3(const double* d) { return {d[0], d[1], d[2]}; }
Vector3 plus(const Vector3& a, const Vector3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vector3 times(const Vector3& a, double k) { return {a.x * k, a.y * k, a.z * k}; }
Vector3 cross(const Vector3& a, const Vector3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double dot(const Vector3& a, const Vector3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double length(const Vector3& a) { return std::sqrt(dot(a, a)); }
Vector3 unit(const Vector3& a) {
    const double l = length(a);
    return l > 0 ? times(a, 1.0 / l) : a;
}
double distance(const Vector3& a, const Vector3& b) { return length(plus(a, times(b, -1.0))); }

// A surface's frame: the reals after its bounding box.
struct Frame {
    Vector3 origin, x, y, z;
};
Frame frameOf(const Obj& s) {
    if (s.d.size() < 18) return {};
    return {v3(&s.d[6]), v3(&s.d[9]), v3(&s.d[12]), v3(&s.d[15])};
}

// The non-zero B-spline basis functions of degree p at t (The NURBS Book, A2.1 and A2.2): their first
// index, and N[0..p]. t is clamped to the knots' working range.
int basisAt(const std::vector<double>& knots, int poles, int p, double t, std::vector<double>& N) {
    t = std::clamp(t, knots[std::size_t(p)], knots[std::size_t(poles)]);
    int span = p;
    if (t >= knots[std::size_t(poles)]) {
        span = poles - 1;
        while (span > p && knots[std::size_t(span)] == knots[std::size_t(span + 1)]) --span;
    } else {
        while (span + 1 < poles && t >= knots[std::size_t(span + 1)]) ++span;
    }
    N.assign(std::size_t(p + 1), 0.0);
    std::vector<double> left(std::size_t(p + 1)), right(std::size_t(p + 1));
    N[0] = 1.0;
    for (int j = 1; j <= p; ++j) {
        left[std::size_t(j)] = t - knots[std::size_t(span + 1 - j)];
        right[std::size_t(j)] = knots[std::size_t(span + j)] - t;
        double saved = 0.0;
        for (int r = 0; r < j; ++r) {
            const double denominator = right[std::size_t(r + 1)] + left[std::size_t(j - r)];
            const double temp = denominator != 0.0 ? N[std::size_t(r)] / denominator : 0.0;
            N[std::size_t(r)] = saved + right[std::size_t(r + 1)] * temp;
            saved = left[std::size_t(j - r)] * temp;
        }
        N[std::size_t(j)] = saved;
    }
    return span - p;
}

// A spline surface's pole (column i along u, row j along v) and its weight.
Vector3 poleOf(const Obj& s, quint64 i, quint64 j) { return v3(&s.points[3 * (j * s.columns + i)]); }
double weightOf(const Obj& s, quint64 i, quint64 j) { return s.weights[j * s.columns + i]; }

// A closed direction's parameter brought into its first period (its curves may run on past it).
double wrapped(const std::vector<double>& knots, quint64 poles, quint64 order, bool closed, double t) {
    if (!closed) return t;
    const double low = knots[std::size_t(order - 1)], high = knots[std::size_t(poles)], period = high - low;
    if (!(period > 0.0)) return t;
    const double r = std::fmod(t - low, period);
    return low + (r < 0.0 ? r + period : r);
}

bool splinePoint(const Obj& s, double u, double v, Vector3& p) {
    u = wrapped(s.uKnots, s.columns, s.uOrder, s.closedU, u);
    v = wrapped(s.vKnots, s.rows, s.vOrder, s.closedV, v);
    std::vector<double> Nu, Nv;
    const int p0 = int(s.uOrder) - 1, q0 = int(s.vOrder) - 1;
    const int i0 = basisAt(s.uKnots, int(s.columns), p0, u, Nu), j0 = basisAt(s.vKnots, int(s.rows), q0, v, Nv);
    Vector3 sum;
    double weight = 0.0;
    for (int a = 0; a <= p0; ++a)
        for (int b = 0; b <= q0; ++b) {
            const double w = Nu[std::size_t(a)] * Nv[std::size_t(b)] * weightOf(s, quint64(i0 + a), quint64(j0 + b));
            sum = plus(sum, times(poleOf(s, quint64(i0 + a), quint64(j0 + b)), w));
            weight += w;
        }
    if (!(weight > 0.0)) return false;
    p = times(sum, 1.0 / weight);
    return true;
}

// Knots with their repeats written out, as distinct knots and multiplicities.
void knotsOf(const std::vector<double>& flat, std::vector<double>& knots, std::vector<int>& multiplicities) {
    for (double k : flat) {
        if (!knots.empty() && k == knots.back()) {
            ++multiplicities.back();
        } else {
            knots.push_back(k);
            multiplicities.push_back(1);
        }
    }
}

// A spline surface's parameter line — u = t running along v (alongV), or v = t running along u — as a
// B-spline curve, exactly: the poles across it blended by their basis functions at t, in homogeneous
// coordinates. Millimetres.
kernel::BSplineCurveDefinition isoCurve(const Obj& s, bool alongV, double t) {
    kernel::BSplineCurveDefinition c;
    t = alongV ? wrapped(s.uKnots, s.columns, s.uOrder, s.closedU, t) : wrapped(s.vKnots, s.rows, s.vOrder, s.closedV, t);
    std::vector<double> N;
    const quint64 across = alongV ? s.columns : s.rows, along = alongV ? s.rows : s.columns;
    const int first = alongV ? basisAt(s.uKnots, int(s.columns), int(s.uOrder) - 1, t, N)
                             : basisAt(s.vKnots, int(s.rows), int(s.vOrder) - 1, t, N);
    for (quint64 k = 0; k < along; ++k) {
        Vector3 sum;
        double weight = 0.0;
        for (std::size_t a = 0; a < N.size() && quint64(first) + a < across; ++a) {
            const quint64 i = alongV ? quint64(first) + a : k, j = alongV ? k : quint64(first) + a;
            const double w = N[a] * weightOf(s, i, j);
            sum = plus(sum, times(poleOf(s, i, j), w));
            weight += w;
        }
        c.poles.push_back(times(sum, 1.0 / weight));
        c.weights.push_back(weight);
    }
    c.degree = int(alongV ? s.vOrder : s.uOrder) - 1;
    knotsOf(alongV ? s.vKnots : s.uKnots, c.knots, c.multiplicities);
    if (alongV ? s.closedV : s.closedU) {
        // The iso curve keeps the surface's periodic direction. A clamped
        // one-period curve cannot trim an edge that crosses the parameter seam.
        if (c.multiplicities.front() != c.degree + 1 || c.multiplicities.back() != c.degree + 1)
            return {};
        c.poles.pop_back(); c.weights.pop_back();
        --c.multiplicities.front(); --c.multiplicities.back();
        c.periodic = true;
    }
    return c;
}

bool surfacePoint(const Obj& s, double u, double v, Vector3& p) {
    const Frame f = frameOf(s);
    const auto round = [&](double radius) { return plus(times(f.x, radius * std::cos(u)), times(f.y, radius * std::sin(u))); };
    switch (s.cls) {
    case kPlane: p = plus(f.origin, plus(times(f.x, u), times(f.y, v))); return true;
    case kCylinder: p = plus(f.origin, plus(round(s.d[18]), times(f.z, v * s.d[19]))); return true;
    case kCone: p = plus(f.origin, plus(round(s.d[18] + v * s.d[20] * std::tan(s.d[19])), times(f.z, v * s.d[20]))); return true;
    case kTorus: p = plus(f.origin, plus(round(s.d[18] + s.d[19] * std::cos(v)), times(f.z, s.d[19] * std::sin(v)))); return true;
    case kSphere: p = plus(f.origin, plus(round(s.d[18] * std::cos(v)), times(f.z, s.d[18] * std::sin(v)))); return true;
    case kSpline: return splinePoint(s, u, v, p);
    default: return false;
    }
}

bool curveRange(const Obj& c, double& t0, double& t1) {
    switch (c.cls) {
    case kLine2:
        t0 = 0.0;
        t1 = std::hypot(c.d[2] - c.d[0], c.d[3] - c.d[1]);
        return t1 > 0.0;
    case kArc2: t0 = c.d[8], t1 = c.d[9]; return true;
    case kTrimmed2: t0 = c.d[0], t1 = c.d[1]; return true;
    case kContour2: {
        t0 = t1 = 0.0;
        for (const Obj* piece : c.list) {
            double a, b;
            if (!curveRange(*piece, a, b)) return false;
            t1 += b - a;
        }
        return true;
    }
    case kHermite2: t0 = c.params.front(), t1 = c.params.back(); return true;
    case kNurbs2:
        t0=c.nurbs2.knots[std::size_t(c.nurbs2.order-1)];
        t1=c.nurbs2.knots[c.nurbs2.poles.size()+(c.nurbs2.closed?std::size_t(c.nurbs2.order-1):0)];
        return true;
    default: return false;
    }
}

bool curvePoint(const Obj& c, double t, double& u, double& v) {
    switch (c.cls) {
    case kLine2: {
        const double l = std::hypot(c.d[2] - c.d[0], c.d[3] - c.d[1]);
        if (!(l > 0.0)) return false;
        u = c.d[0] + t * (c.d[2] - c.d[0]) / l;
        v = c.d[1] + t * (c.d[3] - c.d[1]) / l;
        return true;
    }
    case kArc2:
        u = c.d[0] + c.d[6] * std::cos(t) * c.d[2] + c.d[7] * std::sin(t) * c.d[4];
        v = c.d[1] + c.d[6] * std::cos(t) * c.d[3] + c.d[7] * std::sin(t) * c.d[5];
        return true;
    case kTrimmed2: {
        if (!c.curve || c.flag != 0) return false; // a reversed trim: not met in the samples
        if (c.curve->cls != kLine2) return curvePoint(*c.curve, t, u, v);
        // A trimmed line runs from its line's first point to its second over its own two parameters. Those
        // are the segment's length from its start (595 of the samples' 883 trimmed lines), its ends'
        // projections on its direction, or a surface parameter scaled (a thread's, 6-3.m3d); the edge's
        // vertices at its two points in every one checked.
        const double h = c.d[1] - c.d[0];
        if (h == 0.0) return false;
        const double f = (t - c.d[0]) / h;
        const auto& l = c.curve->d;
        u = l[0] + f * (l[2] - l[0]);
        v = l[1] + f * (l[3] - l[1]);
        return true;
    }
    case kContour2: {
        double at = 0.0;
        for (std::size_t i = 0; i < c.list.size(); ++i) {
            double a, b;
            if (!curveRange(*c.list[i], a, b)) return false;
            if (t <= at + (b - a) + 1e-12 || i + 1 == c.list.size()) return curvePoint(*c.list[i], a + (t - at), u, v);
            at += b - a;
        }
        return false;
    }
    case kHermite2: {
        // Segment i from point i to the next — back to the first after the last on a closed curve.
        const auto& ps = c.params;
        const std::size_t points = c.points.size() / 2;
        for (std::size_t i = 0; i + 1 < ps.size(); ++i) {
            if (t > ps[i + 1] && i + 2 < ps.size()) continue;
            const std::size_t j = (i + 1) % points;
            const double h = ps[i + 1] - ps[i];
            const double s = h != 0.0 ? (t - ps[i]) / h : 0.0;
            const double h00 = 2 * s * s * s - 3 * s * s + 1, h10 = s * s * s - 2 * s * s + s, h01 = -2 * s * s * s + 3 * s * s,
                         h11 = s * s * s - s * s;
            const auto at = [&](int k) {
                return h00 * c.points[2 * i + k] + h10 * h * c.vectors[2 * i + k] + h01 * c.points[2 * j + k] +
                       h11 * h * c.vectors[2 * j + k];
            };
            u = at(0);
            v = at(1);
            return true;
        }
        return false;
    }
    case kNurbs2: {
        double first=0,last=0;
        if(!curveRange(c,first,last))return false;
        const double slack=1e-12*std::max({1.,std::fabs(first),std::fabs(last)});
        if(t<first-slack || t>last+slack)return false;
        try {
            const auto point=detail::pointOnKompasNurbs2(c.nurbs2,std::clamp(t,first,last));
            u=point[0];v=point[1];return true;
        } catch(const std::exception&) {return false;}
    }
    default: return false;
    }
}

// The innermost curve under trimming, and whether trimming keeps its direction.
const Obj* basis(const Obj* c) {
    while (c && c->cls == kTrimmed2) {
        if (c->flag != 0) return nullptr; // a reversed trim: not met in the samples
        c = c->curve;
    }
    return c;
}

constexpr double kMetre = 1e-3;
Vector3 metres(const Vector3& p) { return times(p, kMetre); }

// A surface as the builder's support (metres).
bool support(const Obj& s, kernel::AnalyticSurfaceSupport& out, kernel::AnalyticFacePatch* patch = nullptr) {
    using K = kernel::AnalyticSurfaceSupport::Kind;
    using P = kernel::AnalyticFacePatch::Kind;
    const Frame f = frameOf(s);
    out = {};
    out.origin = metres(f.origin);
    out.normal = unit(f.z);
    out.xAxis = unit(f.x);
    P kind = P::Plane;
    switch (s.cls) {
    case kPlane: out.kind = K::Plane; kind = P::Plane; break;
    case kCylinder: out.kind = K::Cylinder, kind = P::Cylinder, out.radius = s.d[18] * kMetre; break;
    case kCone:
        out.kind = K::Cone, kind = P::Cone;
        out.radius = s.d[18] * kMetre;
        out.semiAngle = s.d[19]; // radius r + z·tan α along z (the height scales v and z alike)
        break;
    case kTorus: out.kind = K::Torus, kind = P::Torus, out.majorRadius = s.d[18] * kMetre, out.minorRadius = s.d[19] * kMetre; break;
    case kSphere:
        // Its natural normal points out in a right-handed frame; a left-handed one is in none of the samples.
        if (dot(cross(f.x, f.y), f.z) <= 0.0) return false;
        out.kind = K::Sphere, kind = P::Sphere, out.radius = s.d[18] * kMetre;
        break;
    case kSpline: {
        // The builder's grid runs v fastest (pole u·nv + v); its normal Su × Sv, as the file's. The frame
        // is unused but must be one.
        out = {};
        out.normal = {0, 0, 1};
        out.xAxis = {1, 0, 0};
        out.kind = K::BSpline, kind = P::BSpline;
        auto& b = out.bspline;
        b.uDegree = int(s.uOrder) - 1, b.vDegree = int(s.vOrder) - 1;
        // A closed direction as OCCT's periodic one (a face round it keeps no seam of its own): its last
        // poles — the first again — left out, its end knots of multiplicity degree instead of order (the
        // same curve: C0 through the first pole there). Only for knots clamped at both ends, as read.
        const auto periodic = [](bool closed, std::vector<double>& knots, std::vector<int>& multiplicities, int order) {
            if (!closed) return true;
            if (multiplicities.size() < 2 || multiplicities.front() != order || multiplicities.back() != order) return false;
            multiplicities.front() = order - 1;
            multiplicities.back() = order - 1;
            return true;
        };
        knotsOf(s.uKnots, b.uKnots, b.uMultiplicities);
        knotsOf(s.vKnots, b.vKnots, b.vMultiplicities);
        if (!periodic(s.closedU, b.uKnots, b.uMultiplicities, int(s.uOrder)) ||
            !periodic(s.closedV, b.vKnots, b.vMultiplicities, int(s.vOrder)))
            return false;
        b.uPeriodic = s.closedU;
        b.vPeriodic = s.closedV;
        const quint64 columns = s.closedU ? s.columns - 1 : s.columns, rows = s.closedV ? s.rows - 1 : s.rows;
        b.uPoleCount = int(columns), b.vPoleCount = int(rows);
        for (quint64 i = 0; i < columns; ++i)
            for (quint64 j = 0; j < rows; ++j) {
                b.poles.push_back(metres(poleOf(s, i, j)));
                b.weights.push_back(weightOf(s, i, j));
            }
        break;
    }
    default: return false;
    }
    if (patch) {
        patch->kind = kind;
        patch->origin = out.origin;
        patch->normal = out.normal;
        patch->xAxis = out.xAxis;
        patch->radius = out.radius;
        patch->semiAngle = out.semiAngle;
        patch->majorRadius = out.majorRadius;
        patch->minorRadius = out.minorRadius;
        patch->bspline = out.bspline;
    }
    return true;
}

// An edge's exact geometry, read from one of its curves in surface parameters: a line, or a circle or
// ellipse with its centre, normal, major axis and whether the curve's parameter runs about the normal
// counterclockwise. False where neither curve is one of those.
struct Conic {
    kernel::AnalyticEdgeKind kind = kernel::AnalyticEdgeKind::Line;
    Vector3 center, normal, xAxis;
    double major = 0, minor = 0;
    bool counterclockwise = true;
    kernel::BSplineCurveDefinition bspline; // kind BSpline: a spline surface's parameter line, millimetres
    double splineFirst = 0, splineLast = 0;
    bool planarNurbs = false;
};

bool conicOf(const Obj& surface, const Obj& curve, Conic& out) {
    using E = kernel::AnalyticEdgeKind;
    // A composite curve is one conic when all its pieces are the same one, run the same way.
    if (curve.cls == kContour2) {
        if (curve.list.empty()) return false;
        for (std::size_t i = 0; i < curve.list.size(); ++i) {
            Conic piece;
            if (!conicOf(surface, *curve.list[i], piece)) return false;
            if (i == 0) {
                out = piece;
                continue;
            }
            const double size = std::max(1.0, out.major);
            if (piece.kind != out.kind || piece.counterclockwise != out.counterclockwise ||
                (out.kind != E::Line && (distance(piece.center, out.center) > 1e-9 * size || distance(piece.normal, out.normal) > 1e-12 ||
                                         std::fabs(piece.major - out.major) > 1e-9 * size || std::fabs(piece.minor - out.minor) > 1e-9 * size)))
                return false;
            if (out.kind == E::BSpline) {
                // Only contiguous intervals of the same iso curve make one
                // spline edge. Its UV direction and range must survive, too.
                if (out.bspline.degree != piece.bspline.degree || out.bspline.periodic != piece.bspline.periodic ||
                    out.bspline.knots != piece.bspline.knots || out.bspline.multiplicities != piece.bspline.multiplicities ||
                    out.bspline.weights != piece.bspline.weights || out.bspline.poles.size() != piece.bspline.poles.size() ||
                    out.splineLast != piece.splineFirst) return false;
                for (std::size_t j=0;j<out.bspline.poles.size();++j) {
                    const auto& a=out.bspline.poles[j];const auto& b=piece.bspline.poles[j];
                    if(a.x!=b.x || a.y!=b.y || a.z!=b.z)return false;
                }
                out.splineLast=piece.splineLast;
            }
        }
        return true;
    }
    const Obj* c = basis(&curve);
    if (!c) return false;
    if (c->cls == kHermite2 && c->points.size() >= 4 && !c->flag) {
        // Straight UV boundaries may retain the common edge parameter through
        // Hermite derivatives rather than through a line's metric parameter.
        const auto& p=c->points;
        const double du=p[p.size()-2]-p[0], dv=p.back()-p[1];
        const double squared=du*du+dv*dv;
        const double first=c->params.front(),span=c->params.back()-first;
        bool straight=squared>0 && span>0;
        for(std::size_t i=0;i<p.size()/2 && straight;++i) {
            const double x=p[2*i]-p[0], y=p[2*i+1]-p[1];
            const double tx=c->vectors[2*i],ty=c->vectors[2*i+1];
            const double fraction=(c->params[i]-first)/span;
            const double slack=1e-12*std::max(1.0,std::sqrt(squared));
            straight=std::hypot(x-fraction*du,y-fraction*dv)<=slack &&
                std::hypot(tx-du/span,ty-dv/span)<=slack/span;
        }
        if(straight) {
            Obj line; line.cls=kLine2; line.d={p[0],p[1],p[p.size()-2],p.back()};
            return conicOf(surface,line,out);
        }
    }
    const Frame f = frameOf(surface);
    if (surface.cls == kPlane) {
        if (c->cls == kLine2) return out.kind = E::Line, true;
        if(c->cls==kNurbs2) {
            const auto native=detail::unwrapKompasNurbs2(c->nurbs2);
            auto& b=out.bspline;b={};b.degree=int(native.order-1);
            b.weights=native.weights;
            for(const auto& pole:native.poles)
                b.poles.push_back(plus(f.origin,plus(times(f.x,pole[0]),times(f.y,pole[1]))));
            for(const auto knot:native.knots) {
                if(b.knots.empty() || knot!=b.knots.back()) {b.knots.push_back(knot);b.multiplicities.push_back(1);}
                else ++b.multiplicities.back();
            }
            out.kind=E::BSpline;out.planarNurbs=true;
            return curveRange(curve,out.splineFirst,out.splineLast);
        }
        if (c->cls != kArc2) return false;
        const Vector3 x = plus(times(f.x, c->d[2]), times(f.y, c->d[3])), y = plus(times(f.x, c->d[4]), times(f.y, c->d[5]));
        Vector3 centre;
        surfacePoint(surface, c->d[0], c->d[1], centre);
        const double a = c->d[6] * length(x), b = c->d[7] * length(y);
        out.center = centre;
        out.normal = unit(cross(x, y));
        out.counterclockwise = true;
        if (std::fabs(a - b) <= 1e-12 * std::max(a, b)) {
            out.kind = E::Circle, out.major = out.minor = a, out.xAxis = unit(x);
        } else {
            out.kind = E::Ellipse;
            out.major = std::max(a, b), out.minor = std::min(a, b);
            out.xAxis = unit(a >= b ? x : y);
        }
        return true;
    }
    if (surface.cls == kSpline) {
        // A parameter line of the surface — a line in its parameters along u or v, or a Hermite spline
        // keeping one of them fixed (its points and tangents), the other running one way through its
        // points — is the surface's iso curve there: a straight line when that is of degree 1 between
        // two poles. The edge is the part between its vertices.
        bool alongV = false;
        double at = 0.0;
        const bool affineNurbs = c->cls == kNurbs2 && !c->nurbs2.closed && c->nurbs2.order == 2 &&
            c->nurbs2.poles.size() == 2 && c->nurbs2.weights[0] == c->nurbs2.weights[1];
        if (c->cls == kLine2 || affineNurbs) {
            const double u0 = affineNurbs ? c->nurbs2.poles[0][0] : c->d[0];
            const double v0 = affineNurbs ? c->nurbs2.poles[0][1] : c->d[1];
            const double du = (affineNurbs ? c->nurbs2.poles[1][0] : c->d[2]) - u0;
            const double dv = (affineNurbs ? c->nurbs2.poles[1][1] : c->d[3]) - v0;
            const double l = std::hypot(du, dv);
            if (!(l > 0.0)) return false;
            if (std::fabs(du) <= 1e-12 * l) alongV = true, at = u0;
            else if (std::fabs(dv) <= 1e-12 * l) alongV = false, at = v0;
            else return false;
        } else if (c->cls == kHermite2) {
            const std::size_t n = c->points.size() / 2;
            if (n < 2) return false;
            const auto fixed = [&](int k) {
                for (std::size_t i = 0; i < n; ++i) {
                    const double tangent = std::hypot(c->vectors[2 * i], c->vectors[2 * i + 1]);
                    if (std::fabs(c->points[2 * i + std::size_t(k)] - c->points[std::size_t(k)]) > 1e-12 * std::max(1.0, std::fabs(c->points[std::size_t(k)])) ||
                        std::fabs(c->vectors[2 * i + std::size_t(k)]) > 1e-12 * tangent)
                        return false;
                }
                const std::size_t o = std::size_t(1 - k);
                const double way = c->points[2 * (n - 1) + o] - c->points[o];
                for (std::size_t i = 1; i < n; ++i)
                    if ((c->points[2 * i + o] - c->points[2 * (i - 1) + o]) * way <= 0.0) return false;
                return true;
            };
            if (fixed(0)) alongV = true, at = c->points[0];
            else if (fixed(1)) alongV = false, at = c->points[1];
            else return false;
        } else {
            return false;
        }
        out.bspline = isoCurve(surface, alongV, at);
        out.kind = !out.bspline.periodic && out.bspline.degree == 1 && out.bspline.poles.size() == 2 ? E::Line : E::BSpline;
        // A straight UV NURBS on a curved or rational iso support can have
        // a different parameter law from the extracted spatial curve.
        // Recognize only affine spatial lines; retain other surface curves.
        if (affineNurbs && (out.kind != E::Line || out.bspline.weights[0] != out.bspline.weights[1]))
            return false;
        if(out.kind==E::BSpline) {
            double first,last,u0,v0,u1,v1;
            if(!curveRange(curve,first,last) || !curvePoint(curve,first,u0,v0) || !curvePoint(curve,last,u1,v1))return false;
            out.splineFirst=alongV?v0:u0;out.splineLast=alongV?v1:u1;
            out.counterclockwise=out.splineLast>out.splineFirst;
        }
        return true;
    }
    if (c->cls != kLine2) return false;
    const double du = c->d[2] - c->d[0], dv = c->d[3] - c->d[1], l = std::hypot(du, dv);
    const double u = c->d[0], v = c->d[1];
    if (surface.cls == kCylinder || surface.cls == kCone) {
        if (std::fabs(du) <= 1e-12 * l) return out.kind = E::Line, true; // a generator
        if (std::fabs(dv) > 1e-12 * l) return false;
        const double h = surface.cls == kCylinder ? surface.d[19] : surface.d[20];
        const double radius = surface.cls == kCylinder ? surface.d[18] : surface.d[18] + v * h * std::tan(surface.d[19]);
        out.kind = E::Circle;
        out.center = plus(f.origin, times(f.z, v * h));
        out.normal = unit(cross(f.x, f.y));
        out.xAxis = unit(f.x);
        out.major = out.minor = radius;
        out.counterclockwise = du > 0;
        return radius > 0;
    }
    if (surface.cls == kTorus) {
        const double R = surface.d[18], r = surface.d[19];
        if (std::fabs(du) <= 1e-12 * l) { // a meridian: about the tube's centre circle
            const Vector3 d = plus(times(f.x, std::cos(u)), times(f.y, std::sin(u)));
            out.kind = E::Circle;
            out.center = plus(f.origin, times(d, R));
            out.xAxis = unit(d);
            out.normal = unit(cross(d, f.z));
            out.major = out.minor = r;
            out.counterclockwise = dv > 0;
            return true;
        }
        if (std::fabs(dv) > 1e-12 * l) return false;
        out.kind = E::Circle; // a parallel
        out.center = plus(f.origin, times(f.z, r * std::sin(v)));
        out.normal = unit(cross(f.x, f.y));
        out.xAxis = unit(f.x);
        out.major = out.minor = R + r * std::cos(v);
        out.counterclockwise = du > 0;
        return out.major > 0;
    }
    if (surface.cls == kSphere) {
        const double r = surface.d[18];
        out.kind = E::Circle;
        if (std::fabs(du) <= 1e-12 * l) { // a meridian: a great circle through the poles
            const Vector3 d = plus(times(f.x, std::cos(u)), times(f.y, std::sin(u)));
            out.center = f.origin;
            out.xAxis = unit(d);
            out.normal = unit(cross(d, f.z));
            out.major = out.minor = r;
            out.counterclockwise = dv > 0;
            return r > 0;
        }
        if (std::fabs(dv) > 1e-12 * l) return false;
        out.center = plus(f.origin, times(f.z, r * std::sin(v))); // a parallel (radius 0 at a pole)
        out.normal = unit(cross(f.x, f.y));
        out.xAxis = unit(f.x);
        out.major = out.minor = std::max(0.0, r * std::cos(v));
        out.counterclockwise = du > 0;
        return true;
    }
    return false;
}

// Edges taken as C3D holds them, a curve in a surface's parameters (segmentOf): how many, how far their two
// curves are apart at most (mm).
struct CurveEdges {
    int count = 0;
    double largestGap = 0.0;
    double sliver = 0.0;       // Σ gap² × length / sin θ, mm³
    double smallestSine = 1.0; // of the angle its two surfaces meet at, along any of them
    std::set<const Obj*> seen; // each edge once, though both its faces walk it
};

// A curve in a surface's parameters as the builder's surface curve: a B-spline in the parameters of the
// surface as OCCT has it (the maps between the two are affine per coordinate: a plane's in metres, a
// cylinder's and cone's height or generator length in metres, u mirrored in a left-handed frame), exactly —
// a line as itself, a Hermite spline's segments as Bézier arcs (knots at its parameters, threefold inside).
bool surfaceCurveOf(const Obj& surface, const Obj& curve, kernel::AnalyticEdgeSegment& seg) {
    if (!support(surface, seg.intersectionSurfaces[0])) return false;
    const Frame f = frameOf(surface);
    const bool right = surface.cls == kSpline || dot(cross(f.x, f.y), f.z) > 0.0;
    double su = right ? 1.0 : -1.0, sv = 1.0;
    switch (surface.cls) {
    case kPlane: su = kMetre, sv = right ? kMetre : -kMetre; break;
    case kCylinder: sv = surface.d[19] * kMetre; break;
    case kCone: sv = surface.d[20] * kMetre / std::cos(surface.d[19]); break;
    case kSphere:
    case kTorus:
    case kSpline: break;
    default: return false;
    }
    const Obj* nativeCurve=basis(&curve);
    if(nativeCurve && nativeCurve->cls==kNurbs2) {
        const auto native=detail::unwrapKompasNurbs2(nativeCurve->nurbs2);
        auto& b=seg.bspline;b={};b.degree=int(native.order-1);b.weights=native.weights;
        for(const auto& pole:native.poles)b.poles.push_back({pole[0]*su,pole[1]*sv,0});
        for(const auto knot:native.knots) {
            if(b.knots.empty() || knot!=b.knots.back()) {b.knots.push_back(knot);b.multiplicities.push_back(1);}
            else ++b.multiplicities.back();
        }
        seg.kind=kernel::AnalyticEdgeKind::SurfaceCurve;
        return curveRange(curve,seg.curveFirst,seg.curveLast);
    }
    // The curve as cubic Bézier arcs over its own parameter: a line (or a trimmed one: its two points over its
    // two parameters) as one, a Hermite spline's segments as they are, a composite's pieces one after
    // another (its parameter runs on through them).
    struct Arc {
        double from, to;
        double p[4][2];
    };
    std::vector<Arc> arcs;
    const std::function<bool(const Obj&, double)> append = [&](const Obj& c, double shift) -> bool {
        if (c.cls == kLine2 || (c.cls == kTrimmed2 && c.curve && c.flag == 0 && c.curve->cls == kLine2)) {
            const auto& d = c.cls == kLine2 ? c.d : c.curve->d;
            double a = 0.0, b = std::hypot(d[2] - d[0], d[3] - d[1]);
            if (c.cls == kTrimmed2) a = c.d[0], b = c.d[1];
            if (!(b > a)) return false;
            Arc arc{a + shift, b + shift, {}};
            for (int k = 0; k < 4; ++k)
                for (int j = 0; j < 2; ++j) arc.p[k][j] = d[j] + (d[2 + j] - d[j]) * k / 3.0;
            arcs.push_back(arc);
            return true;
        }
        const Obj* h = &c;
        if (c.cls == kTrimmed2) {
            // A trimmed Hermite spline only over its whole range (the samples' only kind).
            if (!c.curve || c.flag != 0 || c.curve->cls != kHermite2) return false;
            h = c.curve;
            const double scale = std::max(1.0, std::fabs(h->params.back()));
            if (std::fabs(c.d[0] - h->params.front()) > 1e-12 * scale || std::fabs(c.d[1] - h->params.back()) > 1e-12 * scale) return false;
        }
        if (h->cls == kHermite2) {
            const auto& ps = h->params;
            const std::size_t points = h->points.size() / 2;
            for (std::size_t i = 0; i + 1 < ps.size(); ++i) {
                const double step = ps[i + 1] - ps[i];
                if (!(step > 0.0)) return false;
                const std::size_t j = (i + 1) % points;
                Arc arc{ps[i] + shift, ps[i + 1] + shift, {}};
                for (int k = 0; k < 2; ++k) {
                    arc.p[0][k] = h->points[2 * i + std::size_t(k)];
                    arc.p[1][k] = h->points[2 * i + std::size_t(k)] + h->vectors[2 * i + std::size_t(k)] * step / 3;
                    arc.p[2][k] = h->points[2 * j + std::size_t(k)] - h->vectors[2 * j + std::size_t(k)] * step / 3;
                    arc.p[3][k] = h->points[2 * j + std::size_t(k)];
                }
                arcs.push_back(arc);
            }
            return !ps.empty();
        }
        if (c.cls == kContour2) {
            double at = shift;
            for (const Obj* piece : c.list) {
                double a, b;
                if (!curveRange(*piece, a, b) || !append(*piece, at - a)) return false;
                at += b - a;
            }
            return !c.list.empty();
        }
        return false;
    };
    double first = 0.0, last = 0.0;
    if (!curveRange(curve, first, last) || !append(curve, 0.0) || arcs.empty()) return false;
    auto& b = seg.bspline;
    b = {};
    b.degree = 3;
    const auto pole = [&](double u, double v) { b.poles.push_back({u * su, v * sv, 0.0}); b.weights.push_back(1.0); };
    for (std::size_t i = 0; i < arcs.size(); ++i) {
        const Arc& arc = arcs[i];
        if (i > 0 && std::fabs(arc.from - arcs[i - 1].to) > 1e-9 * std::max(1.0, std::fabs(arc.from))) return false;
        if (i == 0) pole(arc.p[0][0], arc.p[0][1]);
        pole(arc.p[1][0], arc.p[1][1]);
        pole(arc.p[2][0], arc.p[2][1]);
        // A joint between pieces: the two ends, which meet, as one pole (their middle).
        if (i + 1 < arcs.size())
            pole(0.5 * (arc.p[3][0] + arcs[i + 1].p[0][0]), 0.5 * (arc.p[3][1] + arcs[i + 1].p[0][1]));
        else
            pole(arc.p[3][0], arc.p[3][1]);
        b.knots.push_back(arc.from);
        b.multiplicities.push_back(i == 0 ? 4 : 3);
    }
    b.knots.push_back(arcs.back().to);
    b.multiplicities.push_back(4);
    seg.kind = kernel::AnalyticEdgeKind::SurfaceCurve;
    seg.curveFirst = first;
    seg.curveLast = last;
    return true;
}

// A plane's intersection with a cylinder not parallel to it: exactly an ellipse (a circle across the axis) —
// centre where the axis meets the plane, semi-minor axis the radius, semi-major the radius over the cosine
// between axis and normal, along the axis's shadow on the plane. Its direction from the edge's curve, which
// must lie on both surfaces within 1 % of the radius: a check that it is this edge (a misreading would miss
// by the radius; C3D's own curves lie within 1e-3 mm), not a measure of its accuracy.
bool sectionOf(const Obj& curve, Conic& out) {
    const Obj* plane = curve.s1->cls == kPlane ? curve.s1 : curve.s2->cls == kPlane ? curve.s2 : nullptr;
    const Obj* cylinder = curve.s1->cls == kCylinder ? curve.s1 : curve.s2->cls == kCylinder ? curve.s2 : nullptr;
    if (!plane || !cylinder) return false;
    const Frame fp = frameOf(*plane), fc = frameOf(*cylinder);
    const Vector3 n = unit(fp.z), axis = unit(fc.z);
    const double r = cylinder->d[18], cosine = dot(axis, n);
    if (!(r > 0.0) || std::fabs(cosine) < 1e-9) return false; // along the axis: lines
    const Vector3 centre = plus(fc.origin, times(axis, dot(plus(fp.origin, times(fc.origin, -1.0)), n) / cosine));
    const Vector3 shadow = plus(axis, times(n, -cosine));
    const bool round = length(shadow) < 1e-12;
    const Vector3 major = round ? unit(fc.x) : unit(shadow), minor = unit(cross(n, major));
    const double a = r / std::fabs(cosine), b = r;
    double t0, t1, u, v;
    if (!curveRange(*curve.c1, t0, t1)) return false;
    double sweep = 0.0, previous = 0.0;
    for (int i = 0; i <= 32; ++i) {
        Vector3 p;
        if (!curvePoint(*curve.c1, t0 + (t1 - t0) * i / 32, u, v) || !surfacePoint(*curve.s1, u, v, p)) return false;
        const Vector3 d = plus(p, times(fc.origin, -1.0));
        const double offPlane = std::fabs(dot(plus(p, times(fp.origin, -1.0)), n));
        const double offCylinder = std::fabs(length(plus(d, times(axis, -dot(d, axis)))) - r);
        if (std::max(offPlane, offCylinder) > 1e-2 * r) return false;
        const Vector3 q = plus(p, times(centre, -1.0));
        const double angle = std::atan2(dot(q, minor) / b, dot(q, major) / a);
        if (i > 0) sweep += std::remainder(angle - previous, 2.0 * M_PI);
        previous = angle;
    }
    if (std::fabs(sweep) < 1e-12) return false;
    out.kind = round ? kernel::AnalyticEdgeKind::Circle : kernel::AnalyticEdgeKind::Ellipse;
    out.center = centre;
    out.normal = n;
    out.xAxis = major;
    out.major = a;
    out.minor = b;
    out.counterclockwise = sweep > 0.0;
    return true;
}

// A cylinder's intersection with a cone on the same axis: exactly a circle, the cylinder's radius, where the
// cone's radius r + z·tan α reaches it. Checked against the edge's curve and directed by it as sectionOf.
bool coaxialOf(const Obj& curve, Conic& out) {
    const Obj* cylinder = curve.s1->cls == kCylinder ? curve.s1 : curve.s2->cls == kCylinder ? curve.s2 : nullptr;
    const Obj* cone = curve.s1->cls == kCone ? curve.s1 : curve.s2->cls == kCone ? curve.s2 : nullptr;
    if (!cylinder || !cone) return false;
    const Frame fy = frameOf(*cylinder), fk = frameOf(*cone);
    const Vector3 axis = unit(fk.z);
    const double radius = cylinder->d[18], r0 = cone->d[18], tangent = std::tan(cone->d[19]);
    const Vector3 offset = plus(fy.origin, times(fk.origin, -1.0));
    if (length(cross(unit(fy.z), axis)) > 1e-12 || length(plus(offset, times(axis, -dot(offset, axis)))) > 1e-9 * std::max(1.0, radius) ||
        !(radius > 0.0) || std::fabs(tangent) < 1e-12)
        return false;
    const Vector3 centre = plus(fk.origin, times(axis, (radius - r0) / tangent));
    const Vector3 x = unit(fk.x), y = unit(cross(axis, x));
    double t0, t1, u, v;
    if (!curveRange(*curve.c1, t0, t1)) return false;
    double sweep = 0.0, previous = 0.0;
    for (int i = 0; i <= 32; ++i) {
        Vector3 p;
        if (!curvePoint(*curve.c1, t0 + (t1 - t0) * i / 32, u, v) || !surfacePoint(*curve.s1, u, v, p)) return false;
        const Vector3 q = plus(p, times(centre, -1.0));
        const double along = dot(q, axis), across = length(plus(q, times(axis, -along)));
        if (std::max(std::fabs(along), std::fabs(across - radius)) > 1e-2 * radius) return false;
        const double angle = std::atan2(dot(q, y), dot(q, x));
        if (i > 0) sweep += std::remainder(angle - previous, 2.0 * M_PI);
        previous = angle;
    }
    if (std::fabs(sweep) < 1e-12) return false;
    out.kind = kernel::AnalyticEdgeKind::Circle;
    out.center = centre;
    out.normal = axis;
    out.xAxis = x;
    out.major = out.minor = radius;
    out.counterclockwise = sweep > 0.0;
    return true;
}

// A sphere's intersection with a cylinder whose axis passes through its centre: exactly a circle, the
// cylinder's radius, as far along the axis as √(R² − r²) — on the side the edge's curve is. Checked against
// that curve and directed by it as sectionOf.
bool sphereCylinderOf(const Obj& curve, Conic& out) {
    const Obj* cylinder = curve.s1->cls == kCylinder ? curve.s1 : curve.s2->cls == kCylinder ? curve.s2 : nullptr;
    const Obj* sphere = curve.s1->cls == kSphere ? curve.s1 : curve.s2->cls == kSphere ? curve.s2 : nullptr;
    if (!cylinder || !sphere) return false;
    const Frame fy = frameOf(*cylinder), fs = frameOf(*sphere);
    const Vector3 axis = unit(fy.z);
    const double r = cylinder->d[18], R = sphere->d[18];
    const Vector3 offset = plus(fs.origin, times(fy.origin, -1.0));
    if (!(r > 0.0) || !(R > r) || length(plus(offset, times(axis, -dot(offset, axis)))) > 1e-9 * std::max(1.0, R)) return false;
    double t0, t1, u, v;
    Vector3 middle;
    if (!curveRange(*curve.c1, t0, t1) || !curvePoint(*curve.c1, 0.5 * (t0 + t1), u, v) || !surfacePoint(*curve.s1, u, v, middle)) return false;
    const double reach = std::sqrt(R * R - r * r);
    const Vector3 centre = plus(fs.origin, times(axis, dot(plus(middle, times(fs.origin, -1.0)), axis) >= 0.0 ? reach : -reach));
    const Vector3 x = unit(fy.x), y = unit(cross(axis, x));
    double sweep = 0.0, previous = 0.0;
    for (int i = 0; i <= 32; ++i) {
        Vector3 p;
        if (!curvePoint(*curve.c1, t0 + (t1 - t0) * i / 32, u, v) || !surfacePoint(*curve.s1, u, v, p)) return false;
        const Vector3 q = plus(p, times(centre, -1.0));
        const double along = dot(q, axis), across = length(plus(q, times(axis, -along)));
        if (std::max(std::fabs(along), std::fabs(across - r)) > 1e-2 * r) return false;
        const double angle = std::atan2(dot(q, y), dot(q, x));
        if (i > 0) sweep += std::remainder(angle - previous, 2.0 * M_PI);
        previous = angle;
    }
    if (std::fabs(sweep) < 1e-12) return false;
    out.kind = kernel::AnalyticEdgeKind::Circle;
    out.center = centre;
    out.normal = axis;
    out.xAxis = x;
    out.major = out.minor = r;
    out.counterclockwise = sweep > 0.0;
    return true;
}

// An oriented edge of a loop as the builder's segment.
bool segmentOf(const Obj& edge, bool along, kernel::AnalyticEdgeSegment& seg, QString& why,
               CurveEdges* curveEdges = nullptr, const Obj* faceSurface = nullptr) {
    const Obj& curve = *edge.curve;
    if (curve.cls != kIntersection || !curve.s1 || !curve.c1 || !curve.s2 || !curve.c2)
        return why = QObject::tr("кривая ребра C3D — не пересечение поверхностей"), false;
    const Vector3 b = v3(&edge.begin->d[0]), e = v3(&edge.end->d[0]);
    const bool closed = edge.begin == edge.end;
    const bool withEdge = curve.flag == 1;
    // The curve's ends against the edge's: a check of the direction flag where the ends differ. An inexact edge
    // (6-3.m3d): its two curves apart by `gap` (whichever way the second runs), its vertices each with a
    // tolerance — the curve starts at its vertex within those, and nearer to it than to the other; the builder
    // is given the edge's tolerance.
    double t0, t1, s0, s1, u, v;
    Vector3 first, last, otherFirst, otherLast;
    if (!curveRange(*curve.c1, t0, t1) || !curvePoint(*curve.c1, t0, u, v) || !surfacePoint(*curve.s1, u, v, first) ||
        !curvePoint(*curve.c1, t1, u, v) || !surfacePoint(*curve.s1, u, v, last) || !curveRange(*curve.c2, s0, s1) ||
        !curvePoint(*curve.c2, s0, u, v) || !surfacePoint(*curve.s2, u, v, otherFirst) || !curvePoint(*curve.c2, s1, u, v) ||
        !surfacePoint(*curve.s2, u, v, otherLast))
        return why = QObject::tr("кривая ребра C3D на поверхности не вычисляется"), false;
    const double gap = std::min(std::max(distance(first, otherFirst), distance(last, otherLast)),
                                std::max(distance(first, otherLast), distance(last, otherFirst)));
    const double slack = std::max({gap, edge.begin->d[3], edge.end->d[3]});
    const double exact = 1e-6 * std::max(1.0, length(first));
    const Vector3 from = withEdge ? b : e, to = withEdge ? e : b;
    if (!closed && (distance(first, from) > std::max(exact, slack) || distance(first, from) >= distance(first, to)))
        return why = QObject::tr("кривая ребра C3D не выходит из его вершины (%1 мм)").arg(distance(first, from)), false;
    const double off = closed ? distance(first, b) : std::max(distance(first, from), distance(last, to));
    // A coincident endpoint does not cancel the precision declared by its
    // native vertex. The two faces can carry different tolerant boundaries
    // between their endpoints, even when both endpoints are exact.
    seg.tolerance = std::max(edge.begin->d[3], edge.end->d[3]) * kMetre;
    if (std::max(gap, off) > exact) seg.tolerance = std::max({gap, off, edge.begin->d[3], edge.end->d[3]}) * kMetre;
    seg.start = metres(along ? b : e);
    seg.end = metres(along ? e : b);
    seg.hasEndpoints = !closed;
    const auto transferBoundary = [&](const Obj& sourceSurface, const Obj& sourceCurve, bool pairedParameter=false) {
        const auto* firstBasis=basis(curve.c1);
        const auto* secondBasis=basis(curve.c2);
        const bool nurbsPair=(firstBasis && firstBasis->cls==kNurbs2) ||
                             (secondBasis && secondBasis->cls==kNurbs2);
        if (!faceSurface || (faceSurface!=&sourceSurface && faceSurface->cls!=kPlane && !nurbsPair && !pairedParameter)) return;
        const Obj* boundaryCurve = faceSurface == curve.s1 ? curve.c1 : faceSurface == curve.s2 ? curve.c2 : nullptr;
        if (!boundaryCurve) return;
        kernel::AnalyticEdgeSegment boundary;
        if (!surfaceCurveOf(*faceSurface, *boundaryCurve, boundary)) return;
        double sourceFirst, sourceLast, boundaryFirst, boundaryLast;
        if (!curveRange(sourceCurve, sourceFirst, sourceLast) ||
            !curveRange(*boundaryCurve, boundaryFirst, boundaryLast) ||
            !(sourceLast > sourceFirst) || !(boundaryLast > boundaryFirst)) return;
        const double allowed = std::max(1e-7, seg.tolerance);
        for (int sample = 0; sample <= 32; ++sample) {
            const double f = sample / 32.0;
            double su, sv, bu, bv;
            Vector3 sourcePoint, boundaryPoint;
            if (!curvePoint(sourceCurve, sourceFirst + (sourceLast - sourceFirst) * f, su, sv) ||
                !surfacePoint(sourceSurface, su, sv, sourcePoint) ||
                !curvePoint(*boundaryCurve, boundaryFirst + (boundaryLast - boundaryFirst) * f, bu, bv) ||
                !surfacePoint(*faceSurface, bu, bv, boundaryPoint) ||
                distance(sourcePoint, boundaryPoint) * kMetre > allowed) return;
        }
        // Both native curves follow the same edge fraction. Keep that law
        // when their stored parameter origins or lengths differ.
        if (sourceFirst != boundaryFirst || sourceLast != boundaryLast)
            for (double& knot : boundary.bspline.knots)
                knot = sourceFirst + (knot - boundaryFirst) * (sourceLast - sourceFirst) /
                                      (boundaryLast - boundaryFirst);
        seg.pcurve = std::move(boundary.bspline);
    };
    Conic conic;
    const Obj* conicSurface=nullptr;
    const Obj* conicCurve=nullptr;
    const auto nativeConic=[&] {
        for(const auto pair:{std::make_pair(curve.s1,curve.c1),std::make_pair(curve.s2,curve.c2)})
            if(conicOf(*pair.first,*pair.second,conic)) {
                conicSurface=pair.first;conicCurve=pair.second;return true;
            }
        return false;
    };
    if (nativeConic() || sectionOf(curve, conic) || coaxialOf(curve, conic) ||
        sphereCylinderOf(curve, conic)) {
        seg.kind = conic.kind;
        if (conic.kind == kernel::AnalyticEdgeKind::BSpline) {
            const Obj* plane = curve.s1->cls == kPlane ? curve.s1 : curve.s2->cls == kPlane ? curve.s2 : nullptr;
            const Obj* spline = curve.s1->cls == kSpline ? curve.s1 : curve.s2->cls == kSpline ? curve.s2 : nullptr;
            if (!conic.planarNurbs && plane && spline) {
                const Obj& planeCurve = plane == curve.s1 ? *curve.c1 : *curve.c2;
                const Obj& splineCurve = spline == curve.s1 ? *curve.c1 : *curve.c2;
                double a, z, sa, sz, u0, v0, u1, v1;
                bool matches = curveRange(planeCurve, a, z) && curveRange(splineCurve, sa, sz) &&
                    curvePoint(splineCurve, sa, u0, v0) && curvePoint(splineCurve, sz, u1, v1);
                bool paired = matches;
                const double allowed = std::max(1e-7, seg.tolerance);
                for (int sample = 0; sample <= 32 && (matches || paired); ++sample) {
                    const double fraction = sample / 32.0;
                    double pu, pv, su, sv;
                    Vector3 onPlane, onSpline, onPairedSpline;
                    // The extracted iso curve uses the surface coordinate as
                    // its parameter. Check that same affine law, rather than
                    // assuming the native 2D curve uses it too.
                    const bool on = curvePoint(planeCurve, a + (z - a) * fraction, pu, pv) &&
                        surfacePoint(*plane, pu, pv, onPlane);
                    matches = matches && on && surfacePoint(*spline,
                        u0 + (u1 - u0) * fraction, v0 + (v1 - v0) * fraction, onSpline) &&
                        distance(onPlane, onSpline) * kMetre <= allowed;
                    paired = paired && on && curvePoint(splineCurve, sa + (sz - sa) * fraction, su, sv) &&
                        surfacePoint(*spline, su, sv, onPairedSpline) &&
                        distance(onPlane, onPairedSpline) * kMetre <= allowed;
                }
                kernel::AnalyticEdgeSegment boundary;
                if ((matches || paired) && surfaceCurveOf(*plane, planeCurve, boundary)) {
                    if (!matches && paired) {
                        // The native pair has a common parameter, but it is
                        // not the iso curve's affine surface coordinate. Use
                        // that pair's planar boundary as the spatial source,
                        // rather than projecting away its parameter law.
                        seg.kind = boundary.kind;
                        seg.bspline = std::move(boundary.bspline);
                        seg.intersectionSurfaces = std::move(boundary.intersectionSurfaces);
                        seg.curveFirst = boundary.curveFirst;
                        seg.curveLast = boundary.curveLast;
                        seg.forward = withEdge ? along : !along;
                        transferBoundary(*plane, planeCurve);
                        return true;
                    }
                    if (plane == faceSurface) seg.pcurve = std::move(boundary.bspline);
                }
            }
            if(!plane && conicSurface && conicCurve) {
                double a,z,u0,v0,u1,v1;
                bool affine=curveRange(*conicCurve,a,z) && curvePoint(*conicCurve,a,u0,v0) &&
                    curvePoint(*conicCurve,z,u1,v1);
                for(int sample=1;sample<32 && affine;++sample) {
                    double u,v;const double f=sample/32.;
                    affine=curvePoint(*conicCurve,a+(z-a)*f,u,v) &&
                        std::hypot(u-u0-(u1-u0)*f,v-v0-(v1-v0)*f)<=1e-12*std::max(1.,std::hypot(u1-u0,v1-v0));
                }
                // The iso curve is exact as a locus, but its coordinate is
                // not necessarily the native intersection's parameter. Keep
                // that common nonlinear law through a surface curve instead.
                if(!affine) {
                    bool paired=true;const double allowed=std::max(1e-7,seg.tolerance);
                    for(int sample=0;sample<=32 && paired;++sample) {
                        double u,v,su,sv;Vector3 p,q;const double f=sample/32.;
                        paired=curvePoint(*curve.c1,t0+(t1-t0)*f,u,v) && surfacePoint(*curve.s1,u,v,p) &&
                            curvePoint(*curve.c2,s0+(s1-s0)*f,su,sv) && surfacePoint(*curve.s2,su,sv,q) &&
                            distance(p,q)*kMetre<=allowed;
                    }
                    const bool second=curve.s1->cls==kSpline && curve.s2->cls!=kSpline;
                    const Obj& sourceSurface=second ? *curve.s2 : *curve.s1;
                    const Obj& sourceCurve=second ? *curve.c2 : *curve.c1;
                    kernel::AnalyticEdgeSegment boundary;
                    if(paired && surfaceCurveOf(sourceSurface,sourceCurve,boundary)) {
                        seg.kind=boundary.kind;seg.bspline=std::move(boundary.bspline);
                        seg.intersectionSurfaces=std::move(boundary.intersectionSurfaces);
                        seg.curveFirst=boundary.curveFirst;seg.curveLast=boundary.curveLast;
                        seg.forward=withEdge ? along : !along;
                        transferBoundary(sourceSurface,sourceCurve,true);
                        return true;
                    }
                }
            }
            seg.bspline = std::move(conic.bspline);
            for (Vector3& pole : seg.bspline.poles) pole = metres(pole);
            seg.forward = conic.counterclockwise == withEdge ? along : !along;
            seg.curveFirst=std::min(conic.splineFirst,conic.splineLast);
            seg.curveLast=std::max(conic.splineFirst,conic.splineLast);
            if(conic.planarNurbs && plane)
                transferBoundary(*plane, plane==curve.s1 ? *curve.c1 : *curve.c2);
            else if(!plane && conicSurface && conicCurve) {
                double a,z,u0,v0,u1,v1;
                bool affine=curveRange(*conicCurve,a,z) && curvePoint(*conicCurve,a,u0,v0) &&
                    curvePoint(*conicCurve,z,u1,v1);
                for(int sample=1;sample<32 && affine;++sample) {
                    double u,v;const double f=sample/32.;
                    affine=curvePoint(*conicCurve,a+(z-a)*f,u,v) &&
                        std::hypot(u-u0-(u1-u0)*f,v-v0-(v1-v0)*f)<=1e-12*std::max(1.,std::hypot(u1-u0,v1-v0));
                }
                if(affine)transferBoundary(*conicSurface,*conicCurve);
            }
            return true;
        }
        if (conic.kind == kernel::AnalyticEdgeKind::Line) {
            if (closed) return why = QObject::tr("замкнутое прямое ребро C3D"), false;
            const auto* firstBasis = basis(curve.c1);
            const auto* secondBasis = basis(curve.c2);
            if (conicSurface && conicCurve &&
                ((firstBasis && firstBasis->cls == kNurbs2) || (secondBasis && secondBasis->cls == kNurbs2)))
                transferBoundary(*conicSurface, *conicCurve);
            return true;
        }
        // Its vertices off the exact curve (inexact ones, 6-3.m3d: 1.7e-4 mm) within the edge's tolerance.
        if (!closed) {
            const Vector3 y = unit(cross(conic.normal, conic.xAxis));
            for (const Vector3& p : {b, e}) {
                const Vector3 q = plus(p, times(conic.center, -1.0));
                const double angle = std::atan2(dot(q, y) / conic.minor, dot(q, conic.xAxis) / conic.major);
                const Vector3 on = plus(conic.center, plus(times(conic.xAxis, conic.major * std::cos(angle)), times(y, conic.minor * std::sin(angle))));
                if (distance(p, on) > exact) seg.tolerance = std::max(seg.tolerance, distance(p, on) * kMetre);
            }
        }
        seg.center = metres(conic.center);
        seg.normal = conic.normal;
        seg.xAxis = conic.xAxis;
        seg.radius = conic.major * kMetre;
        seg.majorRadius = conic.major * kMetre;
        seg.minorRadius = conic.minor * kMetre;
        // Counterclockwise about the normal along the curve; the edge with or against the curve; the loop
        // with or against the edge.
        seg.forward = conic.counterclockwise == withEdge ? along : !along;
        // A recognized spatial conic can still have a tolerant NURBS
        // boundary on its other face. Preserve that stored UV law after
        // validating the native pair; deriving it again from the circle or
        // ellipse would change the adjacent face's enclosed area.
        const auto* firstBasis = basis(curve.c1);
        const auto* secondBasis = basis(curve.c2);
        const bool nurbsPair = (firstBasis && firstBasis->cls == kNurbs2) ||
                              (secondBasis && secondBasis->cls == kNurbs2);
        if (nurbsPair && conicSurface && conicCurve) transferBoundary(*conicSurface, *conicCurve);
        return true;
    }
    // Crossing a spline surface off its parameter lines (a thread's run-out): OCCT's intersection of the two
    // surfaces misses such an edge's ends (3 to 15 branches, 6-3.m3d, 6-4.m3d). Taken as C3D holds it: its
    // curve in the parameters of the other surface (the first, both splines), its tolerance the largest
    // distance between its two curves along it (at 33 points where both run over the same parameters, at
    // its ends otherwise) and its vertices' own.
    const auto* firstUvBasis=basis(curve.c1);
    const auto* secondUvBasis=basis(curve.c2);
    const bool nativeNurbsBoundary=(firstUvBasis && firstUvBasis->cls==kNurbs2) ||
                                   (secondUvBasis && secondUvBasis->cls==kNurbs2);
    if (curve.s1->cls == kSpline || curve.s2->cls == kSpline || nativeNurbsBoundary) {
        const bool second = curve.s1->cls == kSpline && curve.s2->cls != kSpline;
        const Obj& curveSurface = second ? *curve.s2 : *curve.s1;
        if (surfaceCurveOf(curveSurface, second ? *curve.c2 : *curve.c1, seg)) {
            // This is the boundary from which the spatial edge is built, in
            // this plane's own frame and parameter. Retain it on that face:
            // deriving a fresh pcurve from BuildCurve3d's result can change
            // the area of a tolerant spline boundary. Other supports still
            // need their own boundary; this UV curve cannot be reused there.
            double apart = gap, run = 0.0, sine = 1.0;
            const bool together =
                std::fabs(t0 - s0) <= 1e-12 * std::max(1.0, std::fabs(t1)) && std::fabs(t1 - s1) <= 1e-12 * std::max(1.0, std::fabs(t1));
            // A surface's normal at (u, v), by central differences.
            const auto normalAt = [](const Obj& surface, double su, double sv, Vector3& n) {
                const double hu = 1e-6 * std::max(1.0, std::fabs(su)), hv = 1e-6 * std::max(1.0, std::fabs(sv));
                Vector3 a, b, c, d;
                if (!surfacePoint(surface, su + hu, sv, a) || !surfacePoint(surface, su - hu, sv, b) || !surfacePoint(surface, su, sv + hv, c) ||
                    !surfacePoint(surface, su, sv - hv, d))
                    return false;
                n = unit(cross(plus(a, times(b, -1.0)), plus(c, times(d, -1.0))));
                return length(n) > 0.5;
            };
            Vector3 previous = first;
            for (int i = 0; i <= 32; ++i) {
                const double t = t0 + (t1 - t0) * i / 32, t2 = s0 + (s1 - s0) * i / 32;
                Vector3 p, q, n1, n2;
                double u2 = 0.0, v2 = 0.0;
                if (!curvePoint(*curve.c1, t, u, v) || !surfacePoint(*curve.s1, u, v, p)) continue;
                run += distance(previous, p);
                previous = p;
                if (!curvePoint(*curve.c2, together ? t : t2, u2, v2)) continue;
                if (together && surfacePoint(*curve.s2, u2, v2, q)) apart = std::max(apart, distance(p, q));
                if (normalAt(*curve.s1, u, v, n1) && normalAt(*curve.s2, u2, v2, n2)) sine = std::min(sine, length(cross(n1, n2)));
            }
            seg.tolerance = std::max({seg.tolerance, apart * kMetre, edge.begin->d[3] * kMetre, edge.end->d[3] * kMetre});
            seg.forward = along;
            if (curveEdges && (curve.s1->cls == kSpline || curve.s2->cls == kSpline) &&
                curveEdges->seen.insert(&edge).second) {
                ++curveEdges->count;
                curveEdges->largestGap = std::max(curveEdges->largestGap, apart);
                // The edge lies on one surface and within `apart` of the other; where they meet at an angle θ
                // it may lie as far as apart / sin θ from their true intersection along the first: a sliver
                // of section under apart² / sin θ (none bounded where they touch).
                curveEdges->sliver += sine > 1e-9 ? apart * apart * run / sine : std::numeric_limits<double>::infinity();
                curveEdges->smallestSine = std::min(curveEdges->smallestSine, sine);
            }
            transferBoundary(curveSurface, second ? *curve.c2 : *curve.c1);
            return true;
        }
        seg.intersectionSurfaces = {};
    }
    // Neither: the intersection of the two surfaces, through the curve's points (the edge's direction).
    seg.kind = kernel::AnalyticEdgeKind::SurfaceIntersection;
    if (!support(*curve.s1, seg.intersectionSurfaces[0]) || !support(*curve.s2, seg.intersectionSurfaces[1]))
        return why = QObject::tr("поверхность ребра C3D пока не поддержана"), false;
    constexpr int kChart = 32;
    for (int i = 0; i <= kChart; ++i) {
        const double t = withEdge ? t0 + (t1 - t0) * i / kChart : t1 - (t1 - t0) * i / kChart;
        Vector3 p;
        if (!curvePoint(*curve.c1, t, u, v) || !surfacePoint(*curve.s1, u, v, p))
            return why = QObject::tr("кривая ребра C3D на поверхности не вычисляется"), false;
        seg.chart.push_back(metres(p));
    }
    seg.hasBranchPoint = true;
    seg.branchPoint = seg.chart[kChart / 2];
    seg.chartClosed = closed;
    if (closed) seg.chart.pop_back();
    seg.forward = along;
    return true;
}

} // namespace

bool readKompasC3dSolids(const QString& path, kernel::OcctKernel& kernel, KompasC3dResult& result, QString& error,
                         ParasolidXtBuildReport* report) {
    result = {};
    error.clear();
    QByteArray contents;
    if (!readKompasContents(path, contents, error)) return false;
    KompasContentsRecords records;
    if (!decodeKompasContentsRecords(contents, records, error)) return false;

    // The directory owns body records independently of their geometry. Two
    // named bodies may have identical vertices or even share their faces.
    // Read the math registry in physical order, but select the current bodies
    // from /170/300 instead of treating history copies as additional bodies.
    std::set<std::size_t> bodyOwners;
    bool catalogBodies = false;
    if (records.tail.startsWith(QByteArray::fromHex("804330"))) {
        std::vector<KompasRecordLocation> locations;
        quint64 cluster = 0;
        for (const auto& record : records.records) {
            const quint64 count = (quint64(record.compressedSize) + 4095) / 4096;
            locations.push_back({record.offset, record.compressedSize, cluster, count});
            cluster += count;
        }
        KompasCatalog catalog;
        if (!decodeKompasCatalog(records.tail, locations, catalog, error)) return false;
        for (const auto& model : catalog.entries) {
            if (!model.directory || model.numericName != 170) continue;
            for (const auto& bodies : model.children) {
                if (!bodies.directory || bodies.numericName != 300) continue;
                catalogBodies = true;
                if (!model.enabled || !bodies.enabled) continue;
                for (const auto& body : bodies.children)
                    if (!body.directory) bodyOwners.insert(body.recordIndex);
            }
        }
    }

    // Every face shell of the stream, the records read in order with one set of numbered objects. The part's
    // bodies are listed in records of their own — 01, the body's number (a word), ff ff ff ff, then its shell,
    // mostly naming faces written before — in every sample (28 parts); the other shells are the history of the
    // part's making (the tools of operations, bodies before a cut) and are read only for the objects the
    // listed bodies name.
    std::vector<std::unique_ptr<Obj>> store;
    std::unordered_map<int, Obj*> registry;
    std::vector<Obj*> shells;
    std::vector<std::pair<quint32, Obj*>> listed;
    QStringList unread, history, failed;
    bool anyListed = false;
    for (std::size_t recordIndex = 0; recordIndex < records.records.size(); ++recordIndex) {
        const auto& record = records.records[recordIndex];
        const QByteArray& bytes = record.decoded;
        const bool bodyRecord = (!catalogBodies || bodyOwners.count(recordIndex)) &&
                                bytes.size() > 13 && uchar(bytes[0]) == 1 && std::memcmp(bytes.constData() + 5, "\xff\xff\xff\xff", 4) == 0 &&
                                uchar(bytes[9]) == 2 && uchar(bytes[11]) == 0x39 && uchar(bytes[12]) == 0x62;
        quint32 number = 0;
        if (bodyRecord) std::memcpy(&number, bytes.constData() + 1, 4);
        anyListed = anyListed || bodyRecord;
        for (qsizetype at = 0; at + 4 <= bytes.size(); ++at) {
            if (uchar(bytes[at]) != 2 || (uchar(bytes[at + 1]) != 0x80 && uchar(bytes[at + 1]) != 0x00) || uchar(bytes[at + 2]) != 0x39 ||
                uchar(bytes[at + 3]) != 0x62)
                continue;
            const bool body = bodyRecord && at == 9;
            Stream s{bytes, at, store, registry, {}};
            Obj* shell = nullptr;
            if (s.pointer(shell) && shell && shell->cls == kShell && !shell->list.empty()) {
                shells.push_back(shell);
                if (body) listed.push_back({number, shell});
                at = s.at - 1;
                continue;
            }
            const QString why = s.why.isEmpty() ? QObject::tr("пустая оболочка") : s.why;
            if (!unread.contains(why)) unread << why;
            if (body) {
                failed << QObject::tr("тело %1: %2").arg(number).arg(why);
            } else if (!history.contains(why)) {
                history << why;
            }
        }
    }
    // A listed body naming objects of a history shell not read: said with what stopped that shell.
    if (!history.isEmpty())
        for (QString& line : failed)
            if (line.contains(QObject::tr("которого ещё не было"))) line += QObject::tr(" (раньше в потоке: %1)").arg(history.join(QStringLiteral("; ")));
    std::vector<const Obj*> chosen;
    for (const auto& entry : listed) chosen.push_back(entry.second);
    if (!anyListed && !catalogBodies) {
        // No list of bodies (not met in the samples): every distinct shell, as the file holds them.
        chosen.assign(shells.begin(), shells.end());
        if (!chosen.empty()) result.notes << QObject::tr("Списка тел в файле нет: взяты все оболочки потока");
    }
    if (chosen.empty()) {
        error = QObject::tr("В модели КОМПАС-3D не прочитано ни одного тела C3D%1")
                    .arg(failed.isEmpty() ? (unread.isEmpty() ? QString() : QStringLiteral(": ") + unread.join(QStringLiteral("; ")))
                                          : QStringLiteral(":\n") + failed.join(QLatin1Char('\n')));
        return false;
    }

    // Without named body owners, retain the older heuristic for legacy streams.
    // With a catalog, geometry equality cannot erase a distinct document body.
    std::set<const Obj*> taken;
    std::set<std::pair<std::size_t, std::vector<std::array<double, 3>>>> bodyVertices;
    const QString stem = QFileInfo(path).completeBaseName();
    int bodies = int(failed.size()), copies = 0;
    CurveEdges curveEdges;
    for (const Obj* shell : chosen) {
        bool seen = false;
        for (const Obj* face : shell->list) seen = seen || taken.count(face);
        if (seen && !catalogBodies) continue;
        for (const Obj* face : shell->list) taken.insert(face);
        std::set<std::array<double, 3>> vertices;
        for (const Obj* face : shell->list)
            for (const Obj* loop : face->list)
                for (const auto& entry : loop->entries)
                    for (const Obj* vertex : {entry.first->begin, entry.first->end})
                        vertices.insert({vertex->d[0], vertex->d[1], vertex->d[2]});
        if (!catalogBodies && !bodyVertices.insert({shell->list.size(), {vertices.begin(), vertices.end()}}).second) {
            ++copies;
            continue;
        }
        ++bodies;
        std::vector<kernel::AnalyticFacePatch> patches;
        QString why;
        for (const Obj* face : shell->list) {
            kernel::AnalyticFacePatch patch;
            kernel::AnalyticSurfaceSupport ignored;
            if (!face->surface || !support(*face->surface, ignored, &patch)) {
                why = QObject::tr("поверхность грани C3D (класс %1) пока не поддержана")
                          .arg(face->surface ? QString::number(face->surface->cls, 16) : QStringLiteral("—"));
                break;
            }
            patch.reversed = face->flag == 0;
            for (const Obj* loop : face->list) {
                // As the builder takes a face (as XT and ACIS write one): no seam — an edge a loop runs
                // along twice, there and back, where a periodic surface closes on itself; the builder
                // cuts such surfaces itself. What remains is joined into loops by the vertices; a closed
                // edge alone is a ring, a closed edge among others a full turn from its vertex. A loop
                // passing one vertex twice (a hole touching the boundary there, walked as part of it) is
                // split there: a wire passes a vertex once.
                struct Piece {
                    kernel::AnalyticEdgeSegment segment;
                    const Obj* from;
                    const Obj* to;
                    const Obj* edge;
                };
                std::map<const Obj*, int> uses;
                for (const auto& entry : loop->entries) ++uses[entry.first];
                std::vector<Piece> pieces;
                for (const auto& [edge, direction] : loop->entries) {
                    if (uses[edge] > 1) continue;
                    kernel::AnalyticEdgeSegment seg;
                    if (!segmentOf(*edge, direction == 1, seg, why, &curveEdges, face->surface)) break;
                    // A cone's apex: a closed edge of no length (a circle of radius 0) the face runs up to.
                    if (edge->begin == edge->end && seg.kind == kernel::AnalyticEdgeKind::Circle && !(seg.radius > 1e-9)) {
                        if (patch.kind == kernel::AnalyticFacePatch::Kind::Cone) patch.holdsApex = true;
                        continue;
                    }
                    pieces.push_back({std::move(seg), direction == 1 ? edge->begin : edge->end, direction == 1 ? edge->end : edge->begin, edge});
                }
                if (!why.isEmpty()) break;
                // Chains of pieces joined end to start, the last one continuing into the first where it does.
                std::vector<std::vector<Piece>> chains;
                for (Piece& piece : pieces) {
                    if (chains.empty() || chains.back().back().to != piece.from) chains.emplace_back();
                    chains.back().push_back(std::move(piece));
                }
                if (chains.size() > 1 && chains.back().back().to == chains.front().front().from) {
                    chains.back().insert(chains.back().end(), std::make_move_iterator(chains.front().begin()),
                                         std::make_move_iterator(chains.front().end()));
                    chains.erase(chains.begin());
                }
                for (std::vector<Piece>& chain : chains) {
                    if (chain.front().from != chain.back().to) {
                        why = QObject::tr("цикл грани C3D не замыкается");
                        break;
                    }
                    std::vector<kernel::AnalyticEdgeSegment> segments;
                    std::vector<const Obj*> starts;
                    for (Piece& piece : chain) {
                        piece.segment.hasEndpoints = !(piece.edge->begin == piece.edge->end && chain.size() == 1);
                        segments.push_back(std::move(piece.segment));
                        starts.push_back(piece.from);
                        for (std::size_t k = 1; k + 1 < starts.size(); ++k) {
                            if (starts[k] != piece.to) continue;
                            patch.loops.emplace_back(std::make_move_iterator(segments.begin() + std::ptrdiff_t(k)),
                                                     std::make_move_iterator(segments.end()));
                            segments.erase(segments.begin() + std::ptrdiff_t(k), segments.end());
                            starts.erase(starts.begin() + std::ptrdiff_t(k), starts.end());
                            break;
                        }
                    }
                    if (!segments.empty()) patch.loops.push_back(std::move(segments));
                }
                if (!why.isEmpty()) break;
            }
            if (!why.isEmpty()) break;
            // The builder takes a sphere's latitude from its first loop's first edge, a circle: a closed loop
            // led by one of its circles, that loop first (the same loops, begun elsewhere).
            if (patch.kind == kernel::AnalyticFacePatch::Kind::Sphere) {
                for (std::size_t k = 0; k < patch.loops.size(); ++k) {
                    auto& loop = patch.loops[k];
                    const auto circle = std::find_if(loop.begin(), loop.end(), [](const kernel::AnalyticEdgeSegment& e) {
                        return e.kind == kernel::AnalyticEdgeKind::Circle;
                    });
                    if (circle == loop.end()) continue;
                    std::rotate(loop.begin(), circle, loop.end());
                    std::swap(patch.loops[0], loop);
                    break;
                }
            }
            patches.push_back(std::move(patch));
        }
        const QString name = bodies == 1 ? stem : QObject::tr("%1 (%2)").arg(stem).arg(bodies);
        if (!why.isEmpty()) {
            failed << QObject::tr("%1: %2").arg(name, why);
            continue;
        }
        kernel::AnalyticSolidReport built;
        const auto solid = kernel.makeAnalyticSolid(patches, &built);
        if (!solid.isOk()) {
            const QString where = built.failedPatch < shell->list.size()
                                      ? QObject::tr(" (грань %1 из %2, поверхность класса %3)")
                                            .arg(built.failedPatch + 1)
                                            .arg(shell->list.size())
                                            .arg(QString::number(shell->list[built.failedPatch]->surface->cls, 16))
                                      : QString();
            failed << QObject::tr("%1: грани C3D не образуют проверенное тело%2 — %3")
                          .arg(name, where, QString::fromStdString(solid.error().message));
            continue;
        }
        result.solids.push_back({name, solid.value(), int(shell->list.size())});
        if (report) {
            for (const auto& face : built.approximated) report->approximated.push_back({quint32(face.patchIndex), face.deviation, face.contactGap});
            report->largestEdgeTolerance = std::max(report->largestEdgeTolerance, built.largestEdgeTolerance);
        }
    }
    if (result.solids.empty()) {
        error = QObject::tr("Ни одно тело модели КОМПАС-3D не построено:\n%1").arg(failed.join('\n'));
        return false;
    }
    // The first solid of a multi-body part carries its number too.
    if (result.solids.size() > 1 && bodies > 1) result.solids.front().name = QObject::tr("%1 (1)").arg(stem);
    if (!failed.isEmpty()) result.notes << QObject::tr("Тел не построено: %1 из %2").arg(failed.size()).arg(bodies) << failed;
    if (copies > 0) result.notes << QObject::tr("Повторных копий тел в файле (те же грани и вершины) пропущено: %1").arg(copies);
    result.curveEdges = curveEdges.count;
    result.curveEdgeGap = curveEdges.largestGap;
    result.curveEdgeSliver = curveEdges.sliver;
    result.curveEdgeSine = curveEdges.smallestSine;
    if (curveEdges.count > 0)
        result.notes << QObject::tr("Рёбер со сплайновой поверхностью, взятых по кривой C3D в параметрах поверхности: %1; две кривые "
                                    "такого ребра расходятся не больше чем на %2 мм")
                            .arg(curveEdges.count)
                            .arg(curveEdges.largestGap, 0, 'g', 3);
    return true;
}

bool readKompasAssembly(const QString& path, KompasAssembly& assembly, QString& error) {
    QByteArray contents;
    if (!readKompasContents(path, contents, error)) return false;
    KompasContentsRecords records;
    if (!decodeKompasContentsRecords(contents, records, error)) return false;
    assembly = {};
    std::map<int, std::pair<QString, QString>> links;
    std::vector<std::unique_ptr<Obj>> store;
    std::unordered_map<int, Obj*> registry;
    const auto text = [](Stream& s, QString& out) {
        quint64 n = 0;
        int low = 0, high = 0;
        if (!s.u16(low) || !s.u16(high)) return false;
        n = quint64(low) | (quint64(high) << 16);
        if (n > 4096) return s.fail(QObject::tr("путь к детали длиннее 4096 знаков"));
        out.clear();
        for (quint64 i = 0; i < n; ++i) {
            int c = 0;
            if (!s.u16(c)) return false;
            out += QChar(char16_t(c));
        }
        return true;
    };
    // File links: 02 80 21 48, the link's number, 01, the path relative to the assembly, the absolute path.
    for (const KompasContentsRecord& record : records.records) {
        const QByteArray& bytes = record.decoded;
        for (qsizetype at = 0; at + 4 <= bytes.size(); ++at) {
            if (uchar(bytes[at]) != 2 || uchar(bytes[at + 1]) != 0x80 || uchar(bytes[at + 2]) != 0x21 || uchar(bytes[at + 3]) != 0x48)
                continue;
            Stream s{bytes, at + 4, store, registry, {}};
            int tag = 0, id = 0, flag = 0;
            QString relative, absolute;
            if (s.u8(tag) && tag == 1 && s.u16(id) && s.u8(flag) && flag == 1 && text(s, relative) && text(s, absolute) &&
                (!relative.isEmpty() || !absolute.isEmpty()))
                links[id] = {relative, absolute};
        }
    }
    // Components: a record of their own, a word, then 02 00 16 04 (class 0x0416, unnumbered), the component's
    // number, a byte, its box three times, 32 bytes, origin and axes, and a reference (01, a number) to its
    // file link — so in all 20 components of the samples.
    for (const KompasContentsRecord& record : records.records) {
        const QByteArray& bytes = record.decoded;
        if (bytes.size() < 300 || std::memcmp(bytes.constData() + 4, "\x02\x00\x16\x04", 4) != 0) continue;
        Stream s{bytes, 8, store, registry, {}};
        int low = 0, high = 0, ignored = 0, tag = 0, link = 0;
        std::vector<double> boxes, frame;
        if (!s.u16(low) || !s.u16(high) || !s.u8(ignored) || !s.reals(boxes, 18) || !s.skip(32) || !s.reals(frame, 12) || !s.u8(tag) ||
            tag != 1 || !s.u16(link)) {
            error = QObject::tr("Компонент сборки КОМПАС-3D не прочитан: %1").arg(s.why.isEmpty() ? QObject::tr("нет ссылки на файл детали") : s.why);
            return false;
        }
        KompasComponent c;
        c.index = low | (high << 16);
        const auto it = links.find(link);
        if (it == links.end()) {
            error = QObject::tr("Компонент %1 сборки КОМПАС-3D ссылается на файл %2, которого в сборке нет").arg(c.index).arg(link);
            return false;
        }
        c.relativePath = it->second.first;
        c.absolutePath = it->second.second;
        std::copy(frame.begin(), frame.begin() + 3, c.origin.begin());
        std::copy(frame.begin() + 3, frame.end(), c.axes.begin());
        // The axes: unit, at right angles, right-handed — to 1e-9, as a frame read as doubles is.
        const Vector3 x = v3(&c.axes[0]), y = v3(&c.axes[3]), z = v3(&c.axes[6]);
        if (std::fabs(length(x) - 1) > 1e-9 || std::fabs(length(y) - 1) > 1e-9 || std::fabs(length(z) - 1) > 1e-9 ||
            std::fabs(dot(x, y)) > 1e-9 || std::fabs(dot(x, z)) > 1e-9 || std::fabs(dot(y, z)) > 1e-9 || dot(cross(x, y), z) <= 0) {
            error = QObject::tr("Система координат компонента %1 сборки КОМПАС-3D не ортонормирована").arg(c.index);
            return false;
        }
        assembly.components.push_back(std::move(c));
    }
    if (assembly.components.empty()) {
        error = QObject::tr("В сборке КОМПАС-3D не найдено ни одного компонента");
        return false;
    }
    return true;
}

QString kompasComponentFile(const QString& assemblyPath, const KompasComponent& component) {
    const QDir folder = QFileInfo(assemblyPath).absoluteDir();
    QString relative = component.relativePath;
    relative.replace(QLatin1Char('\\'), QLatin1Char('/'));
    if (!relative.isEmpty() && QFileInfo(folder.filePath(relative)).isFile()) return QFileInfo(folder.filePath(relative)).absoluteFilePath();
    QString absolute = component.absolutePath;
    absolute.replace(QLatin1Char('\\'), QLatin1Char('/'));
    const QStringList entries = folder.entryList(QDir::Files);
    for (const QString& wanted : {relative.section(QLatin1Char('/'), -1), absolute.section(QLatin1Char('/'), -1)}) {
        if (wanted.isEmpty()) continue;
        for (const QString& entry : entries)
            if (entry.compare(wanted, Qt::CaseInsensitive) == 0) return folder.absoluteFilePath(entry);
    }
    return {};
}

kernel::ProductPlacement kompasComponentPlacement(const KompasComponent& c) {
    // The rotation's columns are the axes; its unit quaternion by the largest-component branch, so that no
    // division is by a small number.
    const auto r = [&c](int row, int column) { return c.axes[std::size_t(3 * column + row)]; };
    const double trace = r(0, 0) + r(1, 1) + r(2, 2);
    std::array<double, 4> q{};
    if (trace > 0.0) {
        const double s = std::sqrt(trace + 1.0) * 2.0;
        q = {0.25 * s, (r(2, 1) - r(1, 2)) / s, (r(0, 2) - r(2, 0)) / s, (r(1, 0) - r(0, 1)) / s};
    } else if (r(0, 0) > r(1, 1) && r(0, 0) > r(2, 2)) {
        const double s = std::sqrt(1.0 + r(0, 0) - r(1, 1) - r(2, 2)) * 2.0;
        q = {(r(2, 1) - r(1, 2)) / s, 0.25 * s, (r(0, 1) + r(1, 0)) / s, (r(0, 2) + r(2, 0)) / s};
    } else if (r(1, 1) > r(2, 2)) {
        const double s = std::sqrt(1.0 + r(1, 1) - r(0, 0) - r(2, 2)) * 2.0;
        q = {(r(0, 2) - r(2, 0)) / s, (r(0, 1) + r(1, 0)) / s, 0.25 * s, (r(1, 2) + r(2, 1)) / s};
    } else {
        const double s = std::sqrt(1.0 + r(2, 2) - r(0, 0) - r(1, 1)) * 2.0;
        q = {(r(1, 0) - r(0, 1)) / s, (r(0, 2) + r(2, 0)) / s, (r(1, 2) + r(2, 1)) / s, 0.25 * s};
    }
    const double norm = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    for (double& v : q) v /= norm;
    if (q[0] < 0.0)
        for (double& v : q) v = -v;
    kernel::ProductPlacement placement;
    placement.rotation = q;
    placement.translation = {c.origin[0] * kMetre, c.origin[1] * kMetre, c.origin[2] * kMetre};
    return placement;
}

bool readKompasAssemblyProduct(const QString& path, kernel::OcctKernel& kernel, kernel::ProductStructure& product,
                               QString& error, QStringList& notes, ParasolidXtBuildReport* report, const ImportProgress* progress) {
    KompasAssembly assembly;
    if (!readKompasAssembly(path, assembly, error)) return false;
    product = {};
    kernel::ProductAssembly root;
    root.name = QFileInfo(path).completeBaseName().toStdString();
    // Per part file: its parts (indices into product.parts), or why it gave none.
    std::map<QString, std::vector<int>> partsOf;
    std::map<QString, QString> failedFiles;
    std::map<QString, int> uses, occurrence;
    std::vector<QString> files;
    for (const KompasComponent& component : assembly.components) {
        files.push_back(kompasComponentFile(path, component));
        if (!files.back().isEmpty()) ++uses[files.back()];
    }
    QStringList missing, failed;
    for (std::size_t i = 0; i < assembly.components.size(); ++i) {
        const KompasComponent& component = assembly.components[i];
        if (progress) {
            if (progress->cancelled()) {
                error = importCancelledReason();
                return false;
            }
            progress->report(int(i), int(assembly.components.size()),
                             QObject::tr("Компонент %1 из %2").arg(i + 1).arg(assembly.components.size()));
        }
        QString written = component.relativePath.isEmpty() ? component.absolutePath : component.relativePath;
        written.replace(QLatin1Char('\\'), QLatin1Char('/'));
        const QString name = written.section(QLatin1Char('/'), -1);
        const QString& file = files[i];
        if (file.isEmpty()) {
            if (!missing.contains(name)) missing << name;
            continue;
        }
        if (!file.endsWith(QLatin1String(".m3d"), Qt::CaseInsensitive)) {
            failed << QObject::tr("%1: вложенная сборка — пока не читается (в образцах не встречалась)").arg(name);
            continue;
        }
        if (!partsOf.count(file) && !failedFiles.count(file)) {
            KompasC3dResult solids;
            QString why;
            if (!readKompasC3dSolids(file, kernel, solids, why, report)) {
                failedFiles[file] = why;
            } else {
                for (const KompasSolid& solid : solids.solids) {
                    partsOf[file].push_back(int(product.parts.size()));
                    kernel::ProductPart part;
                    part.name = solid.name.toStdString();
                    part.shape = solid.shape;
                    product.parts.push_back(part);
                }
                for (const QString& note : solids.notes) notes << QObject::tr("%1: %2").arg(name, note);
            }
        }
        if (failedFiles.count(file)) {
            failed << QObject::tr("%1: %2").arg(name, failedFiles[file]);
            continue;
        }
        const int n = ++occurrence[file];
        for (int part : partsOf[file]) {
            kernel::ProductInstance instance;
            const std::string partName = product.parts[std::size_t(part)].name;
            instance.name = uses[file] > 1 ? partName + " [" + std::to_string(n) + "]" : partName;
            instance.definition = part;
            instance.placement = kompasComponentPlacement(component);
            root.instances.push_back(instance);
        }
    }
    if (!missing.isEmpty())
        notes << QObject::tr("Не найдены рядом со сборкой файлы деталей (%1): %2").arg(missing.size()).arg(missing.join(QStringLiteral(", ")));
    if (!failed.isEmpty()) notes << QObject::tr("Не построены компоненты:") << failed;
    if (root.instances.empty()) {
        error = QObject::tr("Ни одна деталь сборки КОМПАС-3D не построена (компонентов %1).").arg(assembly.components.size());
        if (!missing.isEmpty())
            error += QLatin1Char('\n') + QObject::tr("Сборка хранит детали отдельными файлами — положите рядом с ней: %1")
                                              .arg(missing.join(QStringLiteral(", ")));
        if (!failed.isEmpty()) error += QLatin1Char('\n') + failed.join(QLatin1Char('\n'));
        return false;
    }
    product.assemblies.push_back(std::move(root));
    product.root = 0;
    return true;
}

} // namespace cadnext::gui
