#include "cadnext/gui/ParasolidXtWriter.hpp"

#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/kernel/ExactBRepDescription.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QByteArray>
#include <QDateTime>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QSaveFile>
#include <QSet>

#include <array>
#include <bit>
#include <charconv>
#include <cmath>
#include <map>

namespace cadnext::gui {
namespace {

using cadnext::ErrorCode;

// The format level written, taken from real files: Parasolid 19.1 as SOLIDWORKS 2009 transmits.
constexpr char kModeller[] = ": TRANSMIT FILE created by modeller version 1901315";
constexpr char kSchemaKey[] = "SCH_1901315_19008_13006";
constexpr char kHeaderSchema[] = "SCH_1901315_19008";
constexpr quint16 kNodeTypes = 186;
constexpr double kUnsetReal = -3.14158e13;

struct Value {
    std::vector<qint64> integers; // pointers, integers, bytes, logicals
    std::vector<double> reals;    // reals; vectors as three each
    QByteArray characters;
};

struct Node {
    quint16 type = 0;
    quint32 index = 0;
    quint32 variableCount = 0;
    std::map<QByteArray, Value> fields;
};

// BODY as Parasolid 19.1 transmits it: the 23 base fields and four appended ones (all zero here).
const std::vector<ParasolidXtFieldSpec>& bodyFields() {
    static const std::vector<ParasolidXtFieldSpec> fields = [] {
        auto base = parasolidXtBaseSchema(12);
        base.push_back({"index_map_offset", 'd', 1, false});
        base.push_back({"index_map", 'p', 1, false});
        base.push_back({"node_id_index_map", 'p', 1, false});
        base.push_back({"schema_embedding_map", 'p', 1, false});
        return base;
    }();
    return fields;
}

// LIST and its blocks carry the heads of per-definition attribute chains.
// Use semantic fields through embedded edits, rather than transmitting the
// obsolete V13 list bookkeeping words as if they still had a meaning.
std::vector<ParasolidXtFieldSpec> nodeFields(quint16 type) {
    if (type == 12) return bodyFields();
    if (type == 70) return {
        {"node_id", 'd', 1, false}, {"list_type", 'd', 1, false},
        {"notransmit", 'l', 1, false}, {"owner", 'p', 1, false},
        {"next", 'p', 1, false}, {"previous", 'p', 1, false},
        {"list_length", 'd', 1, false}, {"block_length", 'd', 1, false},
        {"finger_index", 'd', 1, false}, {"finger_block", 'p', 1, false},
        {"list_block", 'p', 1, false}
    };
    if (type == 74) return {
        {"n_entries", 'd', 1, false}, {"index_map_offset", 'd', 1, false},
        {"next_block", 'p', 1, false}, {"entries", 'p', 1, true}
    };
    return parasolidXtBaseSchema(type);
}

class Graph {
public:
    quint32 add(quint16 type) {
        Node node;
        node.type = type;
        node.index = quint32(nodes.size() + 1);
        nodes.push_back(std::move(node));
        return nodes.back().index;
    }
    Node& at(quint32 index) { return nodes[index - 1]; }
    void pointer(quint32 node, const char* name, quint32 target) { at(node).fields[name].integers = {qint64(target)}; }
    void pointers(quint32 node, const char* name, const std::vector<quint32>& targets) {
        auto& value = at(node).fields[name].integers;
        value.assign(targets.begin(), targets.end());
    }
    void integer(quint32 node, const char* name, qint64 v) { at(node).fields[name].integers = {v}; }
    void integers(quint32 node, const char* name, std::vector<qint64> v) { at(node).fields[name].integers = std::move(v); }
    void real(quint32 node, const char* name, double v) { at(node).fields[name].reals = {v}; }
    void reals(quint32 node, const char* name, std::vector<double> v) { at(node).fields[name].reals = std::move(v); }
    void vector(quint32 node, const char* name, const cadnext::Vector3& v) { at(node).fields[name].reals = {v.x, v.y, v.z}; }
    void character(quint32 node, const char* name, char c) { at(node).fields[name].characters = QByteArray(1, c); }
    void logical(quint32 node, const char* name, bool v) { at(node).fields[name].integers = {v ? 1 : 0}; }

    // Doubly linked, null-terminated, as XT chains are.
    void chain(const std::vector<quint32>& items, const char* next, const char* previous) {
        for (std::size_t i = 0; i < items.size(); ++i) {
            if (i + 1 < items.size()) pointer(items[i], next, items[i + 1]);
            if (i > 0) pointer(items[i], previous, items[i - 1]);
        }
    }
    void singleChain(const std::vector<quint32>& items, const char* next) {
        for (std::size_t i = 0; i + 1 < items.size(); ++i) pointer(items[i], next, items[i + 1]);
    }

    std::vector<Node> nodes;
};

// The two physical encodings (XT Format Reference, "Physical layout"), the mirror of the reader's.
class Encoder {
public:
    explicit Encoder(bool text) : text_(text) {}
    QByteArray& data() { return data_; }

    void byteValue(qint64 v) {
        if (text_) number(v);
        else data_.append(char(quint8(v)));
    }
    void shortValue(qint64 v) {
        if (text_) number(v);
        else be16(quint16(v));
    }
    void intValue(qint64 v) {
        if (text_) number(v);
        else be32(quint32(v));
    }
    void index(quint32 v) {
        if (text_) {
            number(v);
            return;
        }
        // Small indices as index + 1; larger ones as a pair, the inverse of the reader's expansion.
        if (v < 32767u) {
            be16(quint16(v + 1));
            return;
        }
        const quint64 w = quint64(v) + 1;
        const quint64 quotient = (w - 1) / 32767u;
        const quint64 remainder = w - quotient * 32767u;
        be16(quint16(0x10000u - remainder));
        be16(quint16(quotient));
    }
    void realValue(double v) {
        if (text_) {
            char buffer[64];
            const auto result = std::to_chars(buffer, buffer + sizeof buffer, v);
            data_.append(buffer, result.ptr - buffer);
            data_.append(' ');
        } else {
            const quint64 bits = std::bit_cast<quint64>(v);
            be32(quint32(bits >> 32));
            be32(quint32(bits));
        }
    }
    // Unset reals, and a wholly unset vector, are one '?' in text, with no space after.
    void unsetReal() {
        if (text_) data_.append('?');
        else realValue(kUnsetReal);
    }
    void unsetVector() {
        if (text_) {
            data_.append('?');
        } else {
            for (int i = 0; i < 3; ++i) realValue(kUnsetReal);
        }
    }
    void character(char c) {
        if (!text_) {
            data_.append(c);
            return;
        }
        if (c == '\\') data_.append("\\\\");
        else if (c == '\n') data_.append("\\n");
        else if (c == '\r') data_.append("\\r");
        else if (c == '\0') data_.append("\\0");
        else data_.append(c);
    }
    void logical(bool v) {
        if (text_) data_.append(v ? 'T' : 'F');
        else data_.append(char(v ? 1 : 0));
    }
    void shortString(const QByteArray& s) {
        if (text_) number(s.size());
        else data_.append(char(quint8(s.size())));
        for (char c : s) character(c);
    }
    void raw(const QByteArray& s) { data_.append(s); }

private:
    void number(qint64 v) {
        data_.append(QByteArray::number(v));
        data_.append(' ');
    }
    void be16(quint16 v) {
        data_.append(char(v >> 8));
        data_.append(char(v & 0xff));
    }
    void be32(quint32 v) {
        be16(quint16(v >> 16));
        be16(quint16(v & 0xffff));
    }

    bool text_;
    QByteArray data_;
};

// The embedded schema of the first node of each type: 255 for "as the base", and for BODY the
// edits Parasolid 19.1 transmits (copy the 23 base fields, append four).
void writeSchema(Encoder& e, quint16 type) {
    if (type != 12 && type != 70 && type != 74) {
        e.byteValue(255);
        return;
    }
    const auto field = [&](char edit, const QByteArray& name, int pointerClass, const QByteArray& scalar) {
        e.character(edit);
        e.shortString(name);
        e.shortValue(pointerClass);
        e.index(0); // n_elts: a scalar
        if (pointerClass == 0) e.shortString(scalar);
    };
    if (type == 12) {
        e.byteValue(27);
        for (int i = 0; i < 23; ++i) e.character('C');
        field('A', "index_map_offset", 0, "d");
        field('A', "index_map", 82, {});
        field('A', "node_id_index_map", 82, {});
        field('A', "schema_embedding_map", 82, {});
    } else if (type == 70) {
        e.byteValue(11);
        e.character('C'); // node_id
        field('I', "list_type", 0, "d");
        field('I', "notransmit", 0, "l");
        for (int i = 0; i < 3; ++i) e.character('C'); // owner, next, previous
        e.character('D'); // obsolete list-type word
        e.character('C'); e.character('C'); // length and block length
        e.character('D'); // obsolete size-of-entry word
        field('I', "finger_index", 0, "d");
        field('I', "finger_block", 74, {});
        e.character('C'); // list_block
    } else {
        e.byteValue(4);
        e.character('C'); // n_entries
        field('I', "index_map_offset", 0, "d");
        e.character('C'); e.character('C'); // next_block and entries
    }
    e.character('Z');
}

bool writeNode(Encoder& e, const Node& node, QSet<quint16>& described, std::string& error) {
    const std::vector<ParasolidXtFieldSpec> base = nodeFields(node.type);
    if (base.empty()) {
        error = "нет базовой схемы для узла типа " + std::to_string(node.type);
        return false;
    }
    e.shortValue(node.type);
    if (!described.contains(node.type)) {
        described.insert(node.type);
        writeSchema(e, node.type);
    }
    if (base.back().variable) e.intValue(node.variableCount);
    e.index(node.index);
    for (const ParasolidXtFieldSpec& field : base) {
        const quint32 count = field.variable ? node.variableCount : field.count;
        const auto found = node.fields.find(field.name);
        const Value* value = found == node.fields.end() ? nullptr : &found->second;
        const auto integer = [&](quint32 i) -> qint64 {
            return value && i < value->integers.size() ? value->integers[i] : 0;
        };
        switch (field.type) {
        case 'p':
            for (quint32 i = 0; i < count; ++i) e.index(quint32(integer(i)));
            break;
        case 'd':
            for (quint32 i = 0; i < count; ++i) e.intValue(integer(i));
            break;
        case 'n':
        case 'w':
            for (quint32 i = 0; i < count; ++i) e.shortValue(integer(i));
            break;
        case 'u':
            for (quint32 i = 0; i < count; ++i) e.byteValue(integer(i));
            break;
        case 'l':
            for (quint32 i = 0; i < count; ++i) e.logical(integer(i) != 0);
            break;
        case 'c':
            if (!value || quint32(value->characters.size()) != count) {
                error = "поле " + field.name.toStdString() + " узла типа " + std::to_string(node.type) + " не задано";
                return false;
            }
            for (char c : value->characters) e.character(c);
            break;
        case 'f':
            for (quint32 i = 0; i < count; ++i) {
                if (value && i < value->reals.size()) e.realValue(value->reals[i]);
                else e.unsetReal();
            }
            break;
        case 'v':
        case 'h':
            for (quint32 i = 0; i < count; ++i) {
                if (value && value->reals.size() >= 3 * (i + 1)) {
                    for (int k = 0; k < 3; ++k) e.realValue(value->reals[3 * i + k]);
                } else {
                    e.unsetVector();
                }
            }
            break;
        case 'i':
        case 'b': {
            const quint32 components = field.type == 'i' ? 2 : 6;
            for (quint32 i = 0; i < count * components; ++i) {
                if (value && i < value->reals.size()) e.realValue(value->reals[i]);
                else e.unsetReal();
            }
            break;
        }
        default:
            error = "поле типа " + std::string(1, field.type) + " не поддержано писателем";
            return false;
        }
    }
    return true;
}

bool rational(const std::vector<double>& weights) {
    for (double w : weights)
        if (w != 1.0) return true;
    return false;
}

// Control vertices as XT keeps them: homogeneous (x·w, y·w, z·w, w) when rational.
std::vector<double> vertexValues(const std::vector<cadnext::Vector3>& poles, const std::vector<double>& weights,
                                 bool isRational, bool planar = false) {
    std::vector<double> values;
    values.reserve(poles.size() * (planar ? (isRational ? 3 : 2) : (isRational ? 4 : 3)));
    for (std::size_t i = 0; i < poles.size(); ++i) {
        const double w = isRational ? weights[i] : 1.0;
        values.push_back(poles[i].x * w);
        values.push_back(poles[i].y * w);
        if (!planar) values.push_back(poles[i].z * w);
        if (isRational) values.push_back(w);
    }
    return values;
}

quint32 knotNodes(Graph& g, const std::vector<double>& knots, const std::vector<int>& multiplicities, quint32& multNode) {
    multNode = g.add(127);
    g.at(multNode).variableCount = quint32(multiplicities.size());
    g.integers(multNode, "mult", std::vector<qint64>(multiplicities.begin(), multiplicities.end()));
    const quint32 knotNode = g.add(128);
    g.at(knotNode).variableCount = quint32(knots.size());
    g.reals(knotNode, "knots", knots);
    return knotNode;
}

// One BODY and everything under it; returns its node. Node ids count within the body.
quint32 writeBody(Graph& g, const kernel::ExactBRepDescription& d) {
    qint64 nodeId = 0;
    const auto id = [&](quint32 node) { g.integer(node, "node_id", ++nodeId); };
    const quint32 body = g.add(12);

    std::vector<double> vertexTolerances(d.vertices.size(), 1e-8);
    double resolution = 1e-8;
    for (const auto& edge : d.edges) {
        resolution = std::max(resolution, 2 * edge.tolerance);
        for (const int v : {edge.start, edge.end}) if (v >= 0)
            vertexTolerances[std::size_t(v)] = std::max(vertexTolerances[std::size_t(v)], edge.tolerance);
    }
    std::vector<quint32> vertices, points;
    for (const cadnext::Vector3& position : d.vertices) {
        const quint32 vertex = g.add(18), point = g.add(29);
        id(vertex);
        g.real(vertex, "tolerance", vertexTolerances[vertices.size()]);
        id(point);
        g.pointer(vertex, "point", point);
        g.pointer(vertex, "owner", body);
        g.pointer(point, "owner", vertex);
        g.vector(point, "pvec", position);
        vertices.push_back(vertex);
        points.push_back(point);
    }
    g.chain(vertices, "next", "previous");
    g.chain(points, "next", "previous");

    std::vector<quint32> edges, curves;
    // A tolerant EDGE has no 3D curve; both FINs carry trimmed SP-curves.
    // Keep straight, accurate polygonal bodies in their simple 3D form. Other
    // bodies retain all supported UV boundaries, including their planar faces:
    // reprojection can collapse a narrow planar strip between tolerant edges.
    const bool preserveBoundaries = d.largestVertexGap > 1e-10 ||
        std::any_of(d.surfaces.begin(), d.surfaces.end(), [](const auto& surface) {
            return surface.kind != kernel::DescribedSurface::Kind::Plane;
        }) || std::any_of(d.curves.begin(), d.curves.end(), [](const auto& curve) {
            return curve.kind != kernel::DescribedCurve::Kind::Line;
        });
    std::vector<int> uses(d.edges.size(), 0), uvUses(d.edges.size(), 0);
    std::vector<bool> surfaceEdges(d.edges.size(), false);
    for (const auto& face : d.faces) for (const auto& loop : face.loops) for (const auto& coedge : loop) {
        ++uses[std::size_t(coedge.edge)];
        if (coedge.pcurve)
            ++uvUses[std::size_t(coedge.edge)];
    }
    for (std::size_t e = 0; e < d.edges.size(); ++e)
        surfaceEdges[e] = preserveBoundaries && uses[e] == 2 && uvUses[e] == 2;
    // A curve node (with its NURBS data for a B-spline), node id and natural sense set; the caller
    // gives the owner and chains it.
    const auto curveNode = [&](const kernel::DescribedCurve& c, bool planar = false, bool chained = true) {
        quint32 curve = 0;
        switch (c.kind) {
        case kernel::DescribedCurve::Kind::Line:
            curve = g.add(30);
            g.vector(curve, "pvec", c.origin);
            g.vector(curve, "direction", c.direction);
            break;
        case kernel::DescribedCurve::Kind::Circle:
            curve = g.add(31);
            g.vector(curve, "centre", c.origin);
            g.vector(curve, "normal", c.direction);
            g.vector(curve, "x_axis", c.xAxis);
            g.real(curve, "radius", c.radius);
            break;
        case kernel::DescribedCurve::Kind::Ellipse:
            curve = g.add(32);
            g.vector(curve, "centre", c.origin);
            g.vector(curve, "normal", c.direction);
            g.vector(curve, "x_axis", c.xAxis);
            g.real(curve, "major_radius", c.majorRadius);
            g.real(curve, "minor_radius", c.minorRadius);
            break;
        case kernel::DescribedCurve::Kind::BSpline: {
            curve = g.add(134);
            const quint32 nurbs = g.add(136);
            const auto& b = c.bspline;
            const bool isRational = rational(b.weights);
            const quint32 vertexNode = g.add(45);
            const auto values = vertexValues(b.poles, b.weights, isRational, planar);
            g.at(vertexNode).variableCount = quint32(values.size());
            g.reals(vertexNode, "vertices", values);
            quint32 multNode = 0;
            const quint32 knotNode = knotNodes(g, b.knots, b.multiplicities, multNode);
            g.integer(nurbs, "degree", b.degree);
            g.integer(nurbs, "n_vertices", qint64(b.poles.size()));
            g.integer(nurbs, "vertex_dim", planar ? (isRational ? 3 : 2) : (isRational ? 4 : 3));
            g.integer(nurbs, "n_knots", qint64(b.knots.size()));
            g.integer(nurbs, "knot_type", 1); // SCH_unset: no claim about the spacing
            // Periodic: unwrapped as XT keeps it (ExactBRepDescription), and so closed.
            g.logical(nurbs, "periodic", c.periodic);
            g.logical(nurbs, "closed", c.periodic);
            g.logical(nurbs, "rational", isRational);
            g.integer(nurbs, "curve_form", 1); // SCH_unset
            g.pointer(nurbs, "bspline_vertices", vertexNode);
            g.pointer(nurbs, "knot_mult", multNode);
            g.pointer(nurbs, "knots", knotNode);
            g.pointer(curve, "nurbs", nurbs);
            break;
        }
        }
        id(curve);
        g.character(curve, "sense", '+');
        if (chained) curves.push_back(curve);
        return curve;
    };
    for (const kernel::DescribedEdge& e : d.edges) {
        const quint32 edge = g.add(16);
        id(edge);
        if (surfaceEdges[edges.size()]) {
            g.real(edge, "tolerance", std::max(1e-7, e.tolerance));
        } else {
            const auto& definition = d.curves[std::size_t(e.curve)];
            const quint32 basis = curveNode(definition);
            quint32 curve = basis;
            if (definition.kind == kernel::DescribedCurve::Kind::BSpline && e.lastParameter > e.firstParameter) {
                curve = g.add(133);
                id(curve);
                g.pointer(curve, "basis_curve", basis);
                g.character(curve, "sense", '+');
                g.real(curve, "parm_1", e.firstParameter);
                g.real(curve, "parm_2", e.lastParameter);
                if (e.start >= 0) {
                    g.vector(curve, "point_1", d.vertices[std::size_t(e.start)]);
                    g.vector(curve, "point_2", d.vertices[std::size_t(e.end)]);
                }
                g.pointer(basis, "owner", curve);
                curves.push_back(curve);
            }
            g.pointer(curve, "owner", edge);
            g.pointer(edge, "curve", curve);
        }
        g.pointer(edge, "owner", body);
        edges.push_back(edge);
    }
    g.chain(edges, "next", "previous");

    // Regions: the infinite void first, then each lump's solid region and one void per cavity.
    // Every boundary has two shells: the solid side (its faces are back-faces, their normals
    // pointing out of the region) and the void side (the same faces as front-faces).
    std::vector<quint32> regions, surfaces, faceNodes(d.faces.size(), 0);
    const quint32 outside = g.add(19);
    id(outside);
    g.character(outside, "type", 'V');
    regions.push_back(outside);
    std::vector<quint32> outsideShells;
    quint32 firstSolidShell = 0;
    for (const kernel::DescribedLump& lump : d.lumps) {
        const quint32 solid = g.add(19);
        id(solid);
        g.character(solid, "type", 'S');
        regions.push_back(solid);
        std::vector<quint32> solidShells;
        for (std::size_t k = 0; k < lump.shells.size(); ++k) {
            const quint32 solidShell = g.add(13), voidShell = g.add(13);
            id(solidShell);
            id(voidShell);
            if (!firstSolidShell) firstSolidShell = solidShell;
            g.pointer(solidShell, "body", body);
            g.pointer(solidShell, "region", solid);
            solidShells.push_back(solidShell);
            quint32 voidRegion = outside;
            if (k == 0) {
                outsideShells.push_back(voidShell);
            } else {
                voidRegion = g.add(19);
                id(voidRegion);
                g.character(voidRegion, "type", 'V');
                g.pointer(voidRegion, "shell", voidShell);
                regions.push_back(voidRegion);
            }
            g.pointer(voidShell, "region", voidRegion); // body stays null for a void shell
            std::vector<quint32> faces;
            for (int f : lump.shells[k]) {
                const kernel::DescribedFace& described = d.faces[std::size_t(f)];
                const kernel::DescribedSurface& s = d.surfaces[std::size_t(described.surface)];
                const quint32 face = g.add(14);
                id(face);
                faceNodes[std::size_t(f)] = face;
                quint32 surface = 0;
                switch (s.kind) {
                case kernel::DescribedSurface::Kind::Plane:
                    surface = g.add(50);
                    g.vector(surface, "pvec", s.origin);
                    g.vector(surface, "normal", s.axis);
                    g.vector(surface, "x_axis", s.xAxis);
                    break;
                case kernel::DescribedSurface::Kind::Cylinder:
                    surface = g.add(51);
                    g.vector(surface, "pvec", s.origin);
                    g.vector(surface, "axis", s.axis);
                    g.real(surface, "radius", s.radius);
                    g.vector(surface, "x_axis", s.xAxis);
                    break;
                case kernel::DescribedSurface::Kind::Cone:
                    surface = g.add(52);
                    g.vector(surface, "pvec", s.origin);
                    g.vector(surface, "axis", s.axis);
                    g.real(surface, "radius", s.radius);
                    g.real(surface, "sin_half_angle", s.sinHalfAngle);
                    g.real(surface, "cos_half_angle", s.cosHalfAngle);
                    g.vector(surface, "x_axis", s.xAxis);
                    break;
                case kernel::DescribedSurface::Kind::Sphere:
                    surface = g.add(53);
                    g.vector(surface, "centre", s.origin);
                    g.real(surface, "radius", s.radius);
                    g.vector(surface, "axis", s.axis);
                    g.vector(surface, "x_axis", s.xAxis);
                    break;
                case kernel::DescribedSurface::Kind::Torus:
                    surface = g.add(54);
                    g.vector(surface, "centre", s.origin);
                    g.vector(surface, "axis", s.axis);
                    g.real(surface, "major_radius", s.majorRadius);
                    g.real(surface, "minor_radius", s.minorRadius);
                    g.vector(surface, "x_axis", s.xAxis);
                    break;
                case kernel::DescribedSurface::Kind::Swept: {
                    // SWEPT_SURF: the section is geometry the surface depends on, owned by the body
                    // and pointing back through a GEOMETRIC_OWNER ring (XT Format Reference,
                    // "Geometric_owner"), as NX writes it.
                    surface = g.add(67);
                    const quint32 section = curveNode(s.section);
                    g.pointer(section, "owner", body);
                    const quint32 owner = g.add(141);
                    g.pointer(owner, "owner", surface);
                    g.pointer(owner, "next", owner);
                    g.pointer(owner, "previous", owner);
                    g.pointer(owner, "shared_geometry", section);
                    g.pointer(section, "geometric_owner", owner);
                    g.pointer(surface, "section", section);
                    g.vector(surface, "sweep", s.axis);
                    break;
                }
                case kernel::DescribedSurface::Kind::BSpline: {
                    surface = g.add(124);
                    const quint32 nurbs = g.add(126);
                    const auto& b = s.bspline;
                    const bool isRational = rational(b.weights);
                    const quint32 vertexNode = g.add(45);
                    const auto values = vertexValues(b.poles, b.weights, isRational);
                    g.at(vertexNode).variableCount = quint32(values.size());
                    g.reals(vertexNode, "vertices", values);
                    quint32 uMult = 0, vMult = 0;
                    const quint32 uKnots = knotNodes(g, b.uKnots, b.uMultiplicities, uMult);
                    const quint32 vKnots = knotNodes(g, b.vKnots, b.vMultiplicities, vMult);
                    g.logical(nurbs, "u_periodic", s.uPeriodic);
                    g.logical(nurbs, "v_periodic", s.vPeriodic);
                    g.integer(nurbs, "u_degree", b.uDegree);
                    g.integer(nurbs, "v_degree", b.vDegree);
                    g.integer(nurbs, "n_u_vertices", b.uPoleCount);
                    g.integer(nurbs, "n_v_vertices", b.vPoleCount);
                    g.integer(nurbs, "u_knot_type", 1);
                    g.integer(nurbs, "v_knot_type", 1);
                    g.integer(nurbs, "n_u_knots", qint64(b.uKnots.size()));
                    g.integer(nurbs, "n_v_knots", qint64(b.vKnots.size()));
                    g.logical(nurbs, "rational", isRational);
                    g.logical(nurbs, "u_closed", s.uPeriodic);
                    g.logical(nurbs, "v_closed", s.vPeriodic);
                    g.integer(nurbs, "surface_form", 1);
                    g.integer(nurbs, "vertex_dim", isRational ? 4 : 3);
                    g.pointer(nurbs, "bspline_vertices", vertexNode);
                    g.pointer(nurbs, "u_knot_mult", uMult);
                    g.pointer(nurbs, "v_knot_mult", vMult);
                    g.pointer(nurbs, "u_knots", uKnots);
                    g.pointer(nurbs, "v_knots", vKnots);
                    g.pointer(surface, "nurbs", nurbs);
                    break;
                }
                }
                id(surface);
                g.pointer(surface, "owner", face);
                g.character(surface, "sense", '+');
                surfaces.push_back(surface);
                g.pointer(face, "surface", surface);
                g.character(face, "sense", described.reversed ? '-' : '+');
                g.pointer(face, "shell", solidShell);
                g.pointer(face, "front_shell", voidShell);
                faces.push_back(face);
            }
            g.chain(faces, "next", "previous");
            g.chain(faces, "next_front", "previous_front");
            if (!faces.empty()) {
                g.pointer(solidShell, "face", faces.front());
                g.pointer(voidShell, "front_face", faces.front());
            }
        }
        g.singleChain(solidShells, "next");
        g.pointer(solid, "shell", solidShells.front());
    }
    g.singleChain(outsideShells, "next");
    g.pointer(outside, "shell", outsideShells.front());
    for (quint32 region : regions) g.pointer(region, "body", body);
    g.chain(regions, "next", "previous");
    g.chain(surfaces, "next", "previous");

    // Loops and fins. A fin runs as its coedge does; its vertex is the one it runs to.
    std::vector<quint32> positiveFin(d.edges.size(), 0), negativeFin(d.edges.size(), 0);
    std::map<quint32, std::vector<quint32>> geometryOwners;
    std::vector<std::vector<quint32>> finsAtVertex(d.vertices.size());
    for (std::size_t f = 0; f < d.faces.size(); ++f) {
        std::vector<quint32> loops;
        for (const auto& coedges : d.faces[f].loops) {
            const quint32 loop = g.add(15);
            id(loop);
            g.pointer(loop, "face", faceNodes[f]);
            std::vector<quint32> fins;
            for (const kernel::DescribedCoedge& coedge : coedges) {
                const quint32 fin = g.add(17);
                const kernel::DescribedEdge& edge = d.edges[std::size_t(coedge.edge)];
                const int vertex = coedge.forward ? edge.end : edge.start; // -1 on a ring edge
                g.pointer(fin, "loop", loop);
                g.pointer(fin, "edge", edges[std::size_t(coedge.edge)]);
                g.pointer(fin, "vertex", vertex < 0 ? 0 : vertices[std::size_t(vertex)]);
                g.character(fin, "sense", coedge.forward ? '+' : '-');
                if (surfaceEdges[std::size_t(coedge.edge)]) {
                    kernel::DescribedCurve boundary;
                    boundary.kind = kernel::DescribedCurve::Kind::BSpline;
                    boundary.bspline = *coedge.pcurve;
                    const auto& support = d.surfaces[std::size_t(d.faces[f].surface)];
                    if (support.kind == kernel::DescribedSurface::Kind::Cone) {
                        // XT cone v is axial length; the source OCCT pcurve
                        // uses length along the generator. This affine change
                        // preserves even a rational UV curve without fitting.
                        for (auto& pole : boundary.bspline.poles) pole.y *= support.cosHalfAngle;
                    }
                    const quint32 planar = curveNode(boundary, true, false);
                    const quint32 sp = g.add(137), trimmed = g.add(133);
                    id(sp); id(trimmed);
                    g.pointer(planar, "owner", sp);
                    const quint32 surface = quint32(g.at(faceNodes[f]).fields["surface"].integers.front());
                    g.pointer(sp, "surface", surface);
                    g.pointer(sp, "b_curve", planar);
                    g.pointer(sp, "owner", body);
                    g.character(sp, "sense", '+');
                    g.pointer(trimmed, "basis_curve", sp);
                    g.pointer(trimmed, "owner", fin);
                    g.character(trimmed, "sense", '+');
                    g.real(trimmed, "parm_1", boundary.bspline.knots.front());
                    g.real(trimmed, "parm_2", boundary.bspline.knots.back());
                    if (edge.start >= 0) {
                        g.vector(trimmed, "point_1", d.vertices[std::size_t(edge.start)]);
                        g.vector(trimmed, "point_2", d.vertices[std::size_t(edge.end)]);
                    }
                    g.pointer(fin, "curve", trimmed);
                    curves.push_back(sp); curves.push_back(trimmed);
                    for (const auto [dependent, owner] : {std::pair{surface, sp}, std::pair{sp, trimmed}}) {
                        const quint32 link = g.add(141);
                        g.pointer(link, "owner", owner);
                        g.pointer(link, "shared_geometry", dependent);
                        geometryOwners[dependent].push_back(link);
                    }
                }
                (coedge.forward ? positiveFin : negativeFin)[std::size_t(coedge.edge)] = fin;
                if (vertex >= 0) finsAtVertex[std::size_t(vertex)].push_back(fin);
                fins.push_back(fin);
            }
            for (std::size_t i = 0; i < fins.size(); ++i) {
                g.pointer(fins[i], "forward", fins[(i + 1) % fins.size()]);
                g.pointer(fins[i], "backward", fins[(i + fins.size() - 1) % fins.size()]);
            }
            g.pointer(loop, "fin", fins.front());
            loops.push_back(loop);
        }
        g.singleChain(loops, "next");
        if (!loops.empty()) g.pointer(faceNodes[f], "loop", loops.front());
    }
    for (const auto& [dependent, owners] : geometryOwners) {
        g.pointer(dependent, "geometric_owner", owners.front());
        for (std::size_t i = 0; i < owners.size(); ++i) {
            g.pointer(owners[i], "next", owners[(i + 1) % owners.size()]);
            g.pointer(owners[i], "previous", owners[(i + owners.size() - 1) % owners.size()]);
        }
    }
    g.chain(curves, "next", "previous");
    for (std::size_t e = 0; e < d.edges.size(); ++e) {
        // edge->fin is the positive fin: edge->fin->vertex is the edge's end, ->other->vertex its start.
        g.pointer(edges[e], "fin", positiveFin[e]);
        g.pointer(positiveFin[e], "other", negativeFin[e]);
        g.pointer(negativeFin[e], "other", positiveFin[e]);
    }
    for (std::size_t v = 0; v < d.vertices.size(); ++v) {
        g.singleChain(finsAtVertex[v], "next_at_vx");
        if (!finsAtVertex[v].empty()) g.pointer(vertices[v], "fin", finsAtVertex[v].front());
    }

    g.integer(body, "highest_node_id", nodeId);
    g.real(body, "res_size", 1e3);
    g.real(body, "res_linear", resolution);
    g.integer(body, "state", 1);
    g.integer(body, "body_type", 1); // solid
    g.integer(body, "nom_geom_state", 1);
    g.pointer(body, "shell", firstSolidShell);
    g.pointer(body, "boundary_surface", surfaces.empty() ? 0 : surfaces.front());
    g.pointer(body, "boundary_curve", curves.empty() ? 0 : curves.front());
    g.pointer(body, "boundary_point", points.empty() ? 0 : points.front());
    g.pointer(body, "region", outside);
    g.pointer(body, "edge", edges.empty() ? 0 : edges.front());
    g.pointer(body, "vertex", vertices.empty() ? 0 : vertices.front());
    return body;
}

std::string validateBodyAttributes(const std::vector<ParasolidXtIntegerBodyAttribute>& attributes) {
    if (attributes.size() > 4096) return "слишком много атрибутов тела Parasolid XT";
    QSet<QByteArray> names;
    for (const auto& attribute : attributes) {
        if (attribute.name.empty() || attribute.name.size() > 255 ||
            std::any_of(attribute.name.begin(), attribute.name.end(), [](unsigned char c) {
                return c < 0x20 || c > 0x7e;
            }) || attribute.values.empty() || attribute.values.size() > 4096)
            return "атрибут тела Parasolid XT должен иметь печатное ASCII-имя и от 1 до 4096 целых значений";
        const QByteArray name = QByteArray::fromStdString(attribute.name);
        if (names.contains(name)) return "имена атрибутов тела Parasolid XT должны быть уникальны";
        names.insert(name);
    }
    return {};
}

// Returns the head of the definition chain (WORLD.attrib_def in a partition).
quint32 writeBodyAttributes(Graph& g, quint32 body,
                           const std::vector<ParasolidXtIntegerBodyAttribute>& attributes) {
    if (attributes.empty()) return 0;
    qint64 highestId = g.at(body).fields["highest_node_id"].integers.front();
    std::vector<quint32> definitions, instances;
    for (const auto& attribute : attributes) {
        const quint32 definition = g.add(80), name = g.add(79), value = g.add(82), instance = g.add(81);
        g.at(name).variableCount = quint32(attribute.name.size());
        g.at(name).fields["String"].characters = QByteArray::fromStdString(attribute.name);
        g.at(value).variableCount = quint32(attribute.values.size());
        g.integers(value, "values", std::vector<qint64>(attribute.values.begin(), attribute.values.end()));
        g.at(definition).variableCount = attribute.emptyPointerField ? 2 : 1;
        g.pointer(definition, "identifier", name);
        g.integer(definition, "type_id", 9000); // application-defined
        g.integers(definition, "actions", {0, 0, 0, 0, 3, 5, 0, 0}); // class 1
        std::vector<qint64> owners(14, 0);
        owners[2] = 1; // SCH_by_owner
        g.integers(definition, "legal_owners", std::move(owners));
        g.integers(definition, "fields", attribute.emptyPointerField
            ? std::vector<qint64>{9, 1} : std::vector<qint64>{1});
        g.at(instance).variableCount = g.at(definition).variableCount;
        g.integer(instance, "node_id", ++highestId);
        g.pointer(instance, "definition", definition);
        g.pointer(instance, "owner", body);
        g.pointers(instance, "fields", attribute.emptyPointerField
            ? std::vector<quint32>{0, value} : std::vector<quint32>{value});
        definitions.push_back(definition);
        instances.push_back(instance);
    }
    g.singleChain(definitions, "next");
    g.chain(instances, "next", "previous");
    g.pointer(body, "attributes_groups", instances.front());
    g.integer(body, "highest_node_id", highestId);

    const quint32 list = g.add(70);
    g.pointer(body, "attribute_chains", list);
    g.integer(list, "list_type", 4);
    g.logical(list, "notransmit", true);
    g.pointer(list, "owner", body);
    g.integer(list, "list_length", instances.size());
    g.integer(list, "block_length", 20);
    g.integer(list, "finger_index", 1);
    std::vector<quint32> blocks;
    for (std::size_t begin = 0; begin < instances.size(); begin += 20) {
        const quint32 block = g.add(74);
        const std::size_t count = std::min<std::size_t>(20, instances.size() - begin);
        g.at(block).variableCount = 20;
        g.integer(block, "n_entries", count);
        // index_map_offset and unused entries remain zero as specified by XT.
        std::vector<quint32> entries(20, 0);
        std::copy_n(instances.begin() + begin, count, entries.begin());
        g.pointers(block, "entries", entries);
        blocks.push_back(block);
    }
    g.singleChain(blocks, "next_block");
    g.pointer(list, "list_block", blocks.front());
    g.pointer(list, "finger_block", blocks.front());
    return definitions.front();
}

// Row-major rotation of a unit quaternion (w, x, y, z): x' = R·x + t.
std::array<double, 9> rotationOf(const std::array<double, 4>& q) {
    const double w = q[0], x = q[1], y = q[2], z = q[3];
    return {1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
            2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
            2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)};
}

QByteArray keywordValue(QString text) {
    // Keyword values are printable and must not carry the separators of the header.
    QByteArray out;
    for (QChar c : text) {
        const ushort u = c.unicode();
        out.append(u >= 0x20 && u < 0x7f && c != QLatin1Char(';') && c != QLatin1Char('=') && c != QLatin1Char('\\')
                       ? char(u)
                       : '_');
    }
    return out;
}

QByteArray textHeader(const QString& name, bool text) {
    QByteArray h;
    h += "**ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz**************************\n";
    h += "**PARASOLID !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~0123456789**************************\n";
    h += "**PART1;\n";
    h += "MC=unknown;\nMC_MODEL=unknown;\nMC_ID=unknown;\nOS=unknown;\nOS_RELEASE=unknown;\n";
    h += "FRU=CADNext Parasolid XT writer;\n";
    h += "APPL=CADNext;\nSITE=unknown;\nUSER=unknown;\n";
    h += text ? "FORMAT=text;\n" : "FORMAT=binary;\n";
    h += "GUISE=transmit;\n";
    h += "KEY=" + keywordValue(name) + ";\n";
    h += "FILE=" + keywordValue(name) + (text ? ".x_t" : ".x_b") + ";\n";
    h += "DATE=" + QDateTime::currentDateTimeUtc().toString(Qt::ISODate).toLatin1() + " (UTC);\n";
    h += "**PART2;\n";
    h += QByteArray("SCH=") + kHeaderSchema + ";\n";
    h += "USFLD_SIZE=0;\n";
    h += "**PART3;\n";
    h += "**END_OF_HEADER*****************************************************************\n";
    return h;
}

// Records of at most 80 characters, none ending with a space: a reader drops the trailing spaces
// of a record, and a separating space there would join two numbers.
QByteArray records(QByteArray data) {
    while (data.endsWith(' ')) data.chop(1); // the separator after the terminator separates nothing
    QByteArray out;
    out.reserve(data.size() + data.size() / 70 + 2);
    qsizetype at = 0;
    while (at < data.size()) {
        qsizetype end = std::min(at + 80, data.size());
        while (end > at + 1 && data[end - 1] == ' ') --end;
        out.append(data.constData() + at, end - at);
        out.append('\n');
        at = end;
    }
    return out;
}

QByteArray encodeGraph(const Graph& g, bool text, bool partition, std::string& error) {
    Encoder e(text);
    QByteArray modeller(kModeller);
    if (partition) modeller.replace(": TRANSMIT FILE", ": TRANSMIT FILE (partition)");
    if (text) {
        e.raw("T");
        e.shortString(modeller);
        e.raw(QByteArray::number(qsizetype(sizeof kSchemaKey - 1)) + ' ' + kSchemaKey);
    } else {
        e.raw(QByteArray("PS\0\0", 4));
        e.shortValue(modeller.size());
        e.raw(modeller);
        e.intValue(qint64(sizeof kSchemaKey - 1));
        e.raw(kSchemaKey);
    }
    e.shortValue(kNodeTypes);
    e.intValue(0);
    QSet<quint16> describedTypes;
    for (const Node& node : g.nodes)
        if (!writeNode(e, node, describedTypes, error)) return {};
    e.shortValue(1);
    e.index(0);
    return e.data();
}

} // namespace

cadnext::Result<std::string> encodeParasolidXtPartition(kernel::OcctKernel& kernel,
    const kernel::ShapeHandle& shape,
    const std::vector<ParasolidXtIntegerBodyAttribute>& attributes) {
    using R = cadnext::Result<std::string>;
    if (const auto problem = validateBodyAttributes(attributes); !problem.empty())
        return R::fail({ErrorCode::InvalidArgument, problem});
    const auto described = kernel::describeExactBRep(kernel, shape);
    if (!described.isOk()) return R::fail(described.error());
    Graph g;
    const quint32 world = g.add(101);
    const quint32 body = writeBody(g, described.value());
    const quint32 definitions = writeBodyAttributes(g, body, attributes);
    g.pointer(world, "body", body);
    g.pointer(world, "attrib_def", definitions);
    g.logical(world, "alive", true);
    g.integer(world, "highest_id", g.nodes.size());
    g.pointer(body, "owner", world);
    std::string error;
    const QByteArray data = encodeGraph(g, false, true, error);
    if (data.isEmpty()) return R::fail({ErrorCode::SerializationFailed, error});
    ParasolidXtTopology topology;
    QString why;
    if (!readParasolidXtTopology(data, topology, why))
        return R::fail({ErrorCode::SerializationFailed, why.toStdString()});
    return R::ok(data.toStdString());
}

cadnext::Result<std::string> encodeParasolidXtBodyStream(kernel::OcctKernel& kernel,
    const kernel::ShapeHandle& shape,
    const std::vector<ParasolidXtIntegerBodyAttribute>& attributes) {
    using R = cadnext::Result<std::string>;
    if (const auto problem = validateBodyAttributes(attributes); !problem.empty())
        return R::fail({ErrorCode::InvalidArgument, problem});
    const auto described = kernel::describeExactBRep(kernel, shape);
    if (!described.isOk()) return R::fail(described.error());
    Graph graph;
    const quint32 body = writeBody(graph, described.value());
    writeBodyAttributes(graph, body, attributes);
    std::string error;
    const QByteArray data = encodeGraph(graph, false, false, error);
    if (data.isEmpty()) return R::fail({ErrorCode::SerializationFailed, error});
    ParasolidXtTopology topology;
    QString why;
    if (!readParasolidXtTransmitStream(data, topology, why))
        return R::fail({ErrorCode::SerializationFailed, why.toStdString()});
    return R::ok(data.toStdString());
}

cadnext::Result<std::string> encodeParasolidXtProduct(kernel::OcctKernel& kernel, const kernel::ProductStructure& product,
                                                      const std::string& name, ParasolidXtEncoding encoding,
                                                      ParasolidXtWriteReport& report) {
    using R = cadnext::Result<std::string>;
    report = {};
    if (const std::string problem = kernel::validateProductStructure(product); !problem.empty())
        return R::fail({ErrorCode::InvalidArgument, problem});

    // Each part described once, however often it is placed.
    std::vector<kernel::ExactBRepDescription> described;
    for (const kernel::ProductPart& part : product.parts) {
        auto description = kernel::describeExactBRep(kernel, part.shape);
        if (!description.isOk()) return R::fail({description.error().code, "деталь «" + part.name + "»: " + description.error().message});
        report.largestVertexGap = std::max(report.largestVertexGap, description.value().largestVertexGap);
        described.push_back(std::move(description.value()));
    }

    Graph g;
    const kernel::ProductAssembly& top = product.assemblies[std::size_t(product.root)];
    const bool singlePart = product.assemblies.size() == 1 && top.instances.size() == 1 && !top.instances[0].isAssembly &&
                            top.instances[0].placement.rotation == std::array<double, 4>{1, 0, 0, 0} &&
                            top.instances[0].placement.translation == std::array<double, 3>{0, 0, 0};
    if (singlePart) {
        writeBody(g, described[std::size_t(top.instances[0].definition)]);
        report.bodies = 1;
    } else {
        // Root assembly first: the node with index 1 is the root of a transmit file.
        std::vector<quint32> assemblyNodes(product.assemblies.size(), 0), bodyNodes(product.parts.size(), 0);
        assemblyNodes[std::size_t(product.root)] = g.add(10);
        for (std::size_t a = 0; a < product.assemblies.size(); ++a)
            if (!assemblyNodes[a]) assemblyNodes[a] = g.add(10);
        std::map<quint32, std::vector<quint32>> ofPart; // part node -> instances of it
        for (std::size_t a = 0; a < product.assemblies.size(); ++a) {
            const quint32 assembly = assemblyNodes[a];
            qint64 nodeId = 0;
            std::vector<quint32> instances;
            for (const kernel::ProductInstance& instance : product.assemblies[a].instances) {
                quint32 part = 0;
                if (instance.isAssembly) {
                    part = assemblyNodes[std::size_t(instance.definition)];
                } else {
                    quint32& body = bodyNodes[std::size_t(instance.definition)];
                    if (!body) {
                        body = writeBody(g, described[std::size_t(instance.definition)]);
                        ++report.bodies;
                    }
                    part = body;
                }
                const quint32 node = g.add(11);
                g.integer(node, "node_id", ++nodeId);
                g.integer(node, "type", 1); // positive
                g.pointer(node, "part", part);
                g.pointer(node, "assembly", assembly);
                const auto rotation = rotationOf(instance.placement.rotation);
                const auto& t = instance.placement.translation;
                const bool moved = t != std::array<double, 3>{0, 0, 0};
                const bool turned = rotation != std::array<double, 9>{1, 0, 0, 0, 1, 0, 0, 0, 1};
                if (moved || turned) {
                    const quint32 transform = g.add(100);
                    g.integer(transform, "node_id", ++nodeId);
                    g.pointer(transform, "owner", node);
                    g.reals(transform, "rotation_matrix", std::vector<double>(rotation.begin(), rotation.end()));
                    g.vector(transform, "translation_vector", {t[0], t[1], t[2]});
                    g.real(transform, "scale", 1.0);
                    g.integer(transform, "flag", (moved ? 1 : 0) | (turned ? 2 : 0));
                    g.pointer(node, "transform", transform);
                }
                instances.push_back(node);
                ofPart[part].push_back(node);
                ++report.instances;
            }
            g.chain(instances, "next_in_part", "prev_in_part");
            if (!instances.empty()) g.pointer(assembly, "sub_instance", instances.front());
            g.integer(assembly, "highest_node_id", nodeId);
            g.real(assembly, "res_size", 1e3);
            g.real(assembly, "res_linear", 1e-8);
            g.integer(assembly, "state", 1);
            g.integer(assembly, "type", 1); // collective
        }
        for (auto& [part, instances] : ofPart) {
            g.chain(instances, "next_of_part", "prev_of_part");
            g.pointer(part, "ref_instance", instances.front());
        }
        report.assemblies = int(product.assemblies.size());
    }

    const bool text = encoding == ParasolidXtEncoding::Text;
    std::string error;
    const QByteArray data = encodeGraph(g, text, false, error);
    if (data.isEmpty()) return R::fail({ErrorCode::SerializationFailed, error});

    const QString displayName = QString::fromStdString(name);
    QByteArray file = textHeader(displayName, text);
    file += text ? records(data) : data;

    if (report.largestVertexGap > 1e-8) {
        report.warnings.push_back("вершины отстоят от своих кривых до " + std::to_string(report.largestVertexGap) +
                                  " м — больше линейной точности Parasolid 1e-8 м; принимающая система может предложить лечение модели");
    }
    report.warnings.push_back("имена и цвета деталей в Parasolid XT пока не записываются");

    // Never leave behind a file the CADNext reader itself cannot decode.
    ParasolidXtTopology check;
    QString decodeError;
    if (!readParasolidXtFile(file, check, decodeError))
        return R::fail({ErrorCode::SerializationFailed, "записанный файл не читается обратно: " + decodeError.toStdString()});
    return R::ok(file.toStdString());
}

cadnext::Result<ParasolidXtWriteReport> writeParasolidXtProduct(kernel::OcctKernel& kernel,
                                                                const kernel::ProductStructure& product,
                                                                const std::string& path, ParasolidXtEncoding encoding) {
    using R = cadnext::Result<ParasolidXtWriteReport>;
    ParasolidXtWriteReport report;
    const QString file = QString::fromStdString(path);
    const auto bytes = encodeParasolidXtProduct(kernel, product, QFileInfo(file).completeBaseName().toStdString(), encoding, report);
    if (!bytes.isOk()) return R::fail(bytes.error());
    QSaveFile out(file);
    if (!out.open(QIODevice::WriteOnly))
        return R::fail({ErrorCode::SerializationFailed, "не удалось записать " + path});
    out.write(bytes.value().data(), qint64(bytes.value().size()));
    if (!out.commit()) return R::fail({ErrorCode::SerializationFailed, "не удалось записать " + path});
    return R::ok(std::move(report));
}

} // namespace cadnext::gui
