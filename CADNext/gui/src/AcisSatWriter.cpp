#include "cadnext/gui/AcisSatWriter.hpp"

#include "cadnext/gui/NativeAcisSat.hpp"
#include "cadnext/kernel/ExactBRepDescription.hpp"

#include <QDateTime>
#include <QLocale>
#include <QSaveFile>

#include <algorithm>
#include <charconv>
#include <cmath>
#include <stdexcept>

#ifdef CADNEXT_WITH_OCCT
#include <Geom_BSplineCurve.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Standard_Failure.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array2OfReal.hxx>
#endif

namespace cadnext::gui {
namespace {

using cadnext::ErrorCode;
using namespace cadnext::kernel;
constexpr double kPi = 3.14159265358979323846;

QByteArray number(double value) {
    if (!std::isfinite(value)) throw std::runtime_error("non-finite ACIS coordinate");
    char buffer[64];
    const auto result = std::to_chars(buffer, buffer + sizeof buffer, value);
    return QByteArray(buffer, result.ptr - buffer);
}
QByteArray ptr(int index) { return "$" + QByteArray::number(index); }
QByteArray vector(const Vector3& v, double scale = 1.0) {
    return number(v.x * scale) + " " + number(v.y * scale) + " " + number(v.z * scale);
}
Vector3 cross(const Vector3& a, const Vector3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double dot(const Vector3& a, const Vector3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vector3 difference(const Vector3& a, const Vector3& b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }

// SAT text and encrypted DXF payload stay ASCII. UTF-16 code units use the DXF Unicode escape;
// this also keeps control characters out of SAT records and DXF lines.
QByteArray nameText(const std::string& name) {
    QByteArray text;
    for (QChar c : QString::fromStdString(name)) {
        const ushort u = c.unicode();
        if (u >= 32 && u < 127 && !QByteArray("\\{}$#@").contains(char(u))) text.append(char(u));
        else text += "\\U+" + QByteArray::number(u, 16).rightJustified(4, '0');
    }
    return text;
}

struct Records {
    std::vector<QByteArray> data;
    int add() { data.emplace_back(); return int(data.size()) - 1; }
    void set(int id, const QByteArray& kind, const QByteArray& fields, int attribute = -1) {
        const QByteArray header=kind=="cadnext_name-st-attrib"?" -1 ":" -1 $-1 ";
        data[std::size_t(id)] = "-" + QByteArray::number(id) + " " + kind + " " + ptr(attribute) + header + fields + " #\n";
    }
};

#ifdef CADNEXT_WITH_OCCT
gp_Pnt point(const Vector3& p) { return {p.x, p.y, p.z}; }

Handle(Geom_BSplineCurve) splineOf(const DescribedCurve& c) {
    const auto& d = c.bspline;
    TColgp_Array1OfPnt poles(1, int(d.poles.size()));
    TColStd_Array1OfReal weights(1, poles.Length()), knots(1, int(d.knots.size()));
    TColStd_Array1OfInteger mult(1, knots.Length());
    for (int i = 1; i <= poles.Length(); ++i) {
        poles.SetValue(i, point(d.poles[std::size_t(i-1)]));
        weights.SetValue(i, d.weights[std::size_t(i-1)]);
    }
    for (int i = 1; i <= knots.Length(); ++i) {
        knots.SetValue(i, d.knots[std::size_t(i-1)]);
        mult.SetValue(i, d.multiplicities[std::size_t(i-1)]);
    }
    Handle(Geom_BSplineCurve) spline = new Geom_BSplineCurve(poles, weights, knots, mult, d.degree, false);
    // XT's unwrapped periodic splines have exterior knots; SAT requires clamped end knots.
    spline->Segment(spline->FirstParameter(), spline->LastParameter());
    return spline;
}

QByteArray bs3(const Handle(Geom_BSplineCurve)& spline) {
    QByteArray out = "full nurbs " + QByteArray::number(spline->Degree()) +
                     (spline->IsClosed() ? " closed " : " open ") + QByteArray::number(spline->NbKnots());
    for (int k = 1; k <= spline->NbKnots(); ++k)
        out += " " + number(spline->Knot(k)) + " " + QByteArray::number(spline->Multiplicity(k) -
                                                                 (k == 1 || k == spline->NbKnots() ? 1 : 0));
    for (int p = 1; p <= spline->NbPoles(); ++p) {
        const gp_Pnt v = spline->Pole(p);
        out += " " + vector({v.X(), v.Y(), v.Z()}, 1000.0) + " " + number(spline->Weight(p));
    }
    return out;
}

QByteArray bs2(const BSplineCurveDefinition& d) {
    QByteArray out = "nurbs " + QByteArray::number(d.degree) + " open " + QByteArray::number(d.knots.size());
    for (std::size_t k = 0; k < d.knots.size(); ++k)
        out += " " + number(d.knots[k]) + " " + QByteArray::number(d.multiplicities[k] -
                                                    (k == 0 || k + 1 == d.knots.size() ? 1 : 0));
    for (std::size_t p = 0; p < d.poles.size(); ++p)
        out += " " + number(d.poles[p].x) + " " + number(d.poles[p].y) + " " + number(d.weights[p]);
    return out;
}

int subtypeCount(const QByteArray& record) {
    int count = 0;
    for (qsizetype at = record.indexOf('{'); at >= 0; at = record.indexOf('{', at + 1)) {
        qsizetype next = at + 1;
        while (next < record.size() && record[next] == ' ') ++next;
        if (record.mid(next, 3) != "ref") ++count;
    }
    return count;
}

Handle(Geom_BSplineSurface) splineOf(const DescribedSurface& s) {
    const auto& d = s.bspline;
    TColgp_Array2OfPnt poles(1, d.uPoleCount, 1, d.vPoleCount);
    TColStd_Array2OfReal weights(1, d.uPoleCount, 1, d.vPoleCount);
    for (int u = 1; u <= d.uPoleCount; ++u) for (int v = 1; v <= d.vPoleCount; ++v) {
        const std::size_t i = std::size_t((u-1)*d.vPoleCount+v-1);
        poles.SetValue(u, v, point(d.poles[i])); weights.SetValue(u, v, d.weights[i]);
    }
    TColStd_Array1OfReal uKnots(1, int(d.uKnots.size())), vKnots(1, int(d.vKnots.size()));
    TColStd_Array1OfInteger uMult(1, uKnots.Length()), vMult(1, vKnots.Length());
    for (int k = 1; k <= uKnots.Length(); ++k) { uKnots.SetValue(k, d.uKnots[std::size_t(k-1)]); uMult.SetValue(k, d.uMultiplicities[std::size_t(k-1)]); }
    for (int k = 1; k <= vKnots.Length(); ++k) { vKnots.SetValue(k, d.vKnots[std::size_t(k-1)]); vMult.SetValue(k, d.vMultiplicities[std::size_t(k-1)]); }
    Handle(Geom_BSplineSurface) surface = new Geom_BSplineSurface(poles, weights, uKnots, vKnots, uMult, vMult, d.uDegree, d.vDegree);
    double u0, u1, v0, v1; surface->Bounds(u0, u1, v0, v1);
    surface->Segment(u0, u1, v0, v1);
    return surface;
}

void writeCurve(Records& records, int id, const DescribedCurve& c) {
    if (c.kind == DescribedCurve::Kind::Line) {
        records.set(id, "straight-curve", vector(c.origin, 1000.0) + " " + vector(c.direction) + " I I");
    } else if (c.kind == DescribedCurve::Kind::Circle || c.kind == DescribedCurve::Kind::Ellipse) {
        const double radius = c.kind == DescribedCurve::Kind::Circle ? c.radius : c.majorRadius;
        records.set(id, "ellipse-curve", vector(c.origin, 1000.0) + " " + vector(c.direction) + " " + vector(c.xAxis, radius*1000.0) +
                                        " " + number(c.kind == DescribedCurve::Kind::Circle ? 1.0 : c.minorRadius/c.majorRadius) + " I I");
    } else {
        const auto spline = splineOf(c);
        records.set(id, "intcurve-curve", "forward { exactcur " + bs3(spline) +
                    " 0 null_surface null_surface nullbs nullbs I I 0 0 0 F " + number(spline->LastParameter()) +
                    " F " + number(spline->FirstParameter()) + " } I I");
    }
}

void writeSurface(Records& records, int id, const DescribedSurface& s) {
    const QByteArray frame = vector(s.origin, 1000.0) + " " + vector(s.axis);
    using K = DescribedSurface::Kind;
    if (s.kind == K::Plane) records.set(id, "plane-surface", frame + " " + vector(s.xAxis) + " forward_v I I I I");
    else if (s.kind == K::Cylinder || s.kind == K::Cone)
        records.set(id, "cone-surface", frame + " " + vector(s.xAxis, s.radius*1000.0) + " 1 I I " +
                    number(s.kind == K::Cylinder ? 0.0 : s.sinHalfAngle) + " " + number(s.kind == K::Cylinder ? 1.0 : s.cosHalfAngle) +
                    " 1 forward I I I I");
    else if (s.kind == K::Sphere)
        records.set(id, "sphere-surface", vector(s.origin, 1000.0) + " " + number(s.radius*1000.0) + " " + vector(s.xAxis) +
                    " " + vector(s.axis) + " forward_v I I I I");
    else if (s.kind == K::Torus)
        records.set(id, "torus-surface", frame + " " + number(s.majorRadius*1000.0) + " " + number(s.minorRadius*1000.0) +
                    " " + vector(s.xAxis) + " forward_v I I I I");
    else if (s.kind == K::Swept) {
        Records temporary;
        const int curve = temporary.add();
        writeCurve(temporary, curve, s.section);
        const QByteArray record = temporary.data.front();
        const auto fields=record.trimmed().split(' ');
        QByteArray kind = fields[1];
        kind.chop(6); // "-curve"
        const QByteArray section=fields.mid(5,fields.size()-6).join(' ');
        records.set(id, "spline-surface", "forward { sumsur " + kind + " " + section +
                    " straight 0 0 0 " + vector(s.axis) + " I I 0 0 0 none I I I I OPEN OPEN NON_SINGULAR NON_SINGULAR 0 0 0 0 0 0 } I I I I");
    }
    else {
        const auto surface = splineOf(s);
        QByteArray data = "forward { exactsur full nurbs " + QByteArray::number(surface->UDegree()) + " " +
                         QByteArray::number(surface->VDegree()) + (surface->IsUClosed() ? " closed " : " open ") +
                         (surface->IsVClosed() ? "closed" : "open") + " none none " + QByteArray::number(surface->NbUKnots()) +
                         " " + QByteArray::number(surface->NbVKnots());
        for (int k = 1; k <= surface->NbUKnots(); ++k)
            data += " " + number(surface->UKnot(k)) + " " + QByteArray::number(surface->UMultiplicity(k) - (k == 1 || k == surface->NbUKnots() ? 1 : 0));
        for (int k = 1; k <= surface->NbVKnots(); ++k)
            data += " " + number(surface->VKnot(k)) + " " + QByteArray::number(surface->VMultiplicity(k) - (k == 1 || k == surface->NbVKnots() ? 1 : 0));
        for (int v = 1; v <= surface->NbVPoles(); ++v) for (int u = 1; u <= surface->NbUPoles(); ++u) {
            const gp_Pnt p = surface->Pole(u, v);
            data += " " + vector({p.X(), p.Y(), p.Z()}, 1000.0) + " " + number(surface->Weight(u, v));
        }
        double u0,u1,v0,v1;surface->Bounds(u0,u1,v0,v1);
        data += " 0 0 0 0 0 0 0 F "+number(u1)+" F "+number(u0)+" F "+number(v1)+" F "+number(v0)+" } I I I I";
        records.set(id, "spline-surface", data);
    }
}

void writeBody(Records& records, ExactBRepDescription d, const std::string& name) {
    // ACIS keeps a vertex on a ring, whereas XT has no vertex there.
    for (auto& e : d.edges) if (e.start < 0) {
        const auto& c = d.curves[std::size_t(e.curve)];
        Vector3 p;
        if (c.kind == DescribedCurve::Kind::BSpline) {
            const gp_Pnt q = splineOf(c)->StartPoint(); p = {q.X(), q.Y(), q.Z()};
        } else {
            const double rx = c.kind == DescribedCurve::Kind::Circle ? c.radius : c.majorRadius;
            const double ry = c.kind == DescribedCurve::Kind::Circle ? c.radius : c.minorRadius;
            const Vector3 y = cross(c.direction, c.xAxis);
            const double cosine = std::cos(e.firstParameter), sine = std::sin(e.firstParameter);
            p = {c.origin.x + rx*cosine*c.xAxis.x + ry*sine*y.x,
                 c.origin.y + rx*cosine*c.xAxis.y + ry*sine*y.y,
                 c.origin.z + rx*cosine*c.xAxis.z + ry*sine*y.z};
        }
        e.start = e.end = int(d.vertices.size()); d.vertices.push_back(p);
    }
    const int body = records.add(), attribute = records.add();
    const auto allocate = [&](std::size_t n) { std::vector<int> ids; for (std::size_t i=0; i<n; ++i) ids.push_back(records.add()); return ids; };
    const auto vertices = allocate(d.vertices.size()), points = allocate(d.vertices.size());
    const auto curves = allocate(d.curves.size()), edges = allocate(d.edges.size());
    const auto surfaces = allocate(d.surfaces.size()), faces = allocate(d.faces.size());
    for (std::size_t c = 0; c < d.curves.size(); ++c) writeCurve(records, curves[c], d.curves[c]);
    for (std::size_t s = 0; s < d.surfaces.size(); ++s) writeSurface(records, surfaces[s], d.surfaces[s]);
    // SAT numbers subtype definitions in physical record order, including nested definitions.
    // A pcurve refers to its earlier exact surface instead of duplicating its control grid.
    std::vector<int> surfaceRefs(d.surfaces.size(), -1);
    int definitions = 0;
    for (int record = 0; record < faces.front(); ++record) {
        if (record >= surfaces.front() && record <= surfaces.back() &&
            d.surfaces[std::size_t(record - surfaces.front())].kind == DescribedSurface::Kind::BSpline)
            surfaceRefs[std::size_t(record - surfaces.front())] = definitions;
        definitions += subtypeCount(records.data[std::size_t(record)]);
    }
    std::vector<std::vector<int>> edgeUses(d.edges.size());
    std::vector<int> vertexEdges(d.vertices.size(), -1);
    for (std::size_t f=0; f<d.faces.size(); ++f) {
        const auto& face = d.faces[f];
        const auto loops = allocate(face.loops.size());
        records.set(faces[f], "face", "$-1 " + ptr(loops.front()) + " $-1 $-1 " + ptr(surfaces[std::size_t(face.surface)]) +
                     (face.reversed ? " reversed single" : " forward single"));
        for (std::size_t l=0; l<loops.size(); ++l) {
            const auto& loop = face.loops[l]; const auto coedges = allocate(loop.size());
            records.set(loops[l], "loop", ptr(l+1<loops.size() ? loops[l+1] : -1) + " " + ptr(coedges.front()) + " " + ptr(faces[f]));
            for (std::size_t c=0; c<loop.size(); ++c) {
                const auto& use = loop[c];
                int pcurve = -1;
                if (use.pcurve) {
                    pcurve = records.add();
                    const auto& surface = d.surfaces[std::size_t(face.surface)];
                    auto boundary = *use.pcurve;
                    for (auto& uv : boundary.poles) {
                        if (surface.kind == DescribedSurface::Kind::Plane) uv.x *= 1000;
                        if (surface.kind == DescribedSurface::Kind::Plane || surface.kind == DescribedSurface::Kind::Cylinder ||
                            surface.kind == DescribedSurface::Kind::Cone) uv.y *= 1000;
                    }
                    QByteArray on;
                    if (surface.kind == DescribedSurface::Kind::BSpline)
                        on = "spline forward { ref " + QByteArray::number(surfaceRefs[std::size_t(face.surface)]) + " } I I I I";
                    else {
                        const auto fields = records.data[std::size_t(surfaces[std::size_t(face.surface)])].trimmed().split(' ');
                        QByteArray kind = fields[1]; kind.chop(8); // -surface
                        on = kind + ' ' + fields.mid(5, fields.size() - 6).join(' ');
                    }
                    const double tolerance = d.edges[std::size_t(use.edge)].tolerance * 1000;
                    records.set(pcurve, "pcurve", "forward { exppc " + bs2(boundary) + " " + number(tolerance) + " " + on + " } 0 0 1");
                }
                records.set(coedges[c], "coedge", ptr(coedges[(c+1)%loop.size()]) + " " + ptr(coedges[(c+loop.size()-1)%loop.size()]) +
                    " $-1 " + ptr(edges[std::size_t(use.edge)]) + (use.forward ? " forward " : " reversed ") + ptr(loops[l]) + " " + ptr(pcurve));
                edgeUses[std::size_t(use.edge)].push_back(coedges[c]);
            }
        }
    }
    const auto lumps = allocate(d.lumps.size());
    records.set(body, "body", ptr(lumps.front()) + " $-1 $-1", attribute);
    const QByteArray label = nameText(name);
    records.set(attribute, "cadnext_name-st-attrib", "$-1 $-1 " + ptr(body) + " @" + QByteArray::number(label.size()) + " " + label);
    for (std::size_t l=0; l<d.lumps.size(); ++l) {
        const auto shells = allocate(d.lumps[l].shells.size());
        records.set(lumps[l], "lump", ptr(l+1<lumps.size() ? lumps[l+1] : -1) + " " + ptr(shells.front()) + " " + ptr(body));
        for (std::size_t s=0; s<shells.size(); ++s) {
            const auto& list = d.lumps[l].shells[s];
            records.set(shells[s], "shell", ptr(s+1<shells.size() ? shells[s+1] : -1) + " $-1 " + ptr(faces[std::size_t(list.front())]) + " $-1 " + ptr(lumps[l]));
            for (std::size_t f=0; f<list.size(); ++f) {
                const int id = faces[std::size_t(list[f])];
                const auto fields = records.data[std::size_t(id)].split(' ');
                const int loop = fields[6].mid(1).toInt();
                const auto& face = d.faces[std::size_t(list[f])];
                records.set(id, "face", ptr(f+1<list.size() ? faces[std::size_t(list[f+1])] : -1) + " " + ptr(loop) + " " + ptr(shells[s]) +
                    " $-1 " + ptr(surfaces[std::size_t(face.surface)]) + (face.reversed ? " reversed single" : " forward single"));
            }
        }
    }
    for (std::size_t i=0; i<d.edges.size(); ++i) {
        const auto& e = d.edges[i]; const auto& c = d.curves[std::size_t(e.curve)];
        const auto& uses = edgeUses[i];
        if (uses.size() != 2) throw std::runtime_error("ACIS edge does not have two coedges");
        for (int u=0; u<2; ++u) {
            auto fields = records.data[std::size_t(uses[u])].split(' ');
            fields[7] = ptr(uses[1-u]); records.data[std::size_t(uses[u])] = fields.join(' ');
        }
        double first=0.0, last=0.0;
        if (c.kind == DescribedCurve::Kind::BSpline) {
            const auto spline = splineOf(c); first=spline->FirstParameter(); last=spline->LastParameter();
        } else if (c.kind == DescribedCurve::Kind::Line) {
            first = dot(difference(d.vertices[std::size_t(e.start)], c.origin), c.direction)*1000.0;
            last = dot(difference(d.vertices[std::size_t(e.end)], c.origin), c.direction)*1000.0;
        } else {
            const auto parameter = [&](int v) {
                const Vector3 delta = difference(d.vertices[std::size_t(v)], c.origin), y = cross(c.direction, c.xAxis);
                return std::atan2(dot(delta, y)/(c.kind == DescribedCurve::Kind::Circle ? c.radius : c.minorRadius),
                                  dot(delta, c.xAxis)/(c.kind == DescribedCurve::Kind::Circle ? c.radius : c.majorRadius));
            };
            first=parameter(e.start); last=parameter(e.end); if (last <= first) last += 2*kPi;
            if (e.lastParameter > e.firstParameter) { first = e.firstParameter; last = e.lastParameter; }
        }
        records.set(edges[i], "edge", ptr(vertices[std::size_t(e.start)]) + " " + number(first) + " " + ptr(vertices[std::size_t(e.end)]) +
            " " + number(last) + " " + ptr(uses.front()) + " " + ptr(curves[std::size_t(e.curve)]) + " forward @7 unknown");
        vertexEdges[std::size_t(e.start)] = vertexEdges[std::size_t(e.end)] = edges[i];
    }
    for (std::size_t v=0; v<d.vertices.size(); ++v) {
        records.set(vertices[v], "vertex", ptr(vertexEdges[v]) + " " + ptr(points[v]));
        records.set(points[v], "point", vector(d.vertices[v], 1000.0));
    }
}
#endif

cadnext::Result<AcisSatWriteReport> save(const QString& path, const QByteArray& bytes, const AcisSatWriteReport& report) {
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit())
        return cadnext::Result<AcisSatWriteReport>::fail({ErrorCode::SerializationFailed, file.errorString().toStdString()});
    return cadnext::Result<AcisSatWriteReport>::ok(report);
}

QByteArray encryptedSat(const QByteArray& sat) {
    QByteArray groups;
    for (const auto& line : sat.split('\n')) {
        if (line.isEmpty()) continue;
        QByteArray encrypted;
        for (char ch : line) {
            const unsigned char v = static_cast<unsigned char>(ch);
            const unsigned char e = v <= 32 ? v : static_cast<unsigned char>(159-v);
            if (e == '^') encrypted += "^ ";
            else if (e < 32) { encrypted += '^'; encrypted += char(e+64); }
            else encrypted += char(e);
        }
        for (qsizetype at=0; at<encrypted.size();) {
            // Autodesk specifies lines shorter than 255 characters. Keep each caret escape whole.
            qsizetype count=std::min<qsizetype>(254, encrypted.size()-at);
            if (at+count<encrypted.size() && encrypted[at+count-1]=='^') --count;
            groups += (at==0 ? "1\n" : "3\n") + encrypted.mid(at, count) + "\n";
            at += count;
        }
    }
    return groups;
}

} // namespace

cadnext::Result<QByteArray> encodeAcisSat(kernel::OcctKernel& kernel,
                                         const std::vector<kernel::NamedExchangeBody>& bodies,
                                         AcisSatWriteReport& report) {
    using R = cadnext::Result<QByteArray>;
    report = {};
    if (bodies.empty()) return R::fail({ErrorCode::InvalidArgument, "No bodies for ACIS export"});
#ifndef CADNEXT_WITH_OCCT
    return R::fail({ErrorCode::KernelUnavailable, "ACIS export requires OCCT"});
#else
    try {
        Records records;
        for (const auto& body : bodies) {
            const auto placed = kernel.placeExchangeBody(body.body);
            if (!placed.isOk()) return R::fail(placed.error());
            const auto description = describeExactBRep(kernel, placed.value());
            if (!description.isOk()) return R::fail({description.error().code, body.name + ": " + description.error().message});
            report.largestVertexGap = std::max(report.largestVertexGap, description.value().largestVertexGap);
            for (const auto& edge : description.value().edges)
                report.largestBoundaryTolerance = std::max(report.largestBoundaryTolerance, edge.tolerance);
            writeBody(records, description.value(), body.name);
            report.bodies += int(description.value().lumps.size());
        }
        const QByteArray date = QLocale::c().toString(QDateTime::currentDateTimeUtc(),"ddd MMM dd hh:mm:ss yyyy").toLatin1();
        QByteArray bytes = "700 " + QByteArray::number(records.data.size()) + " " + QByteArray::number(bodies.size()) + " 0\n";
        bytes += "7 CADNext 8 ACIS 7.0 " + QByteArray::number(date.size()) + " " + date + "\n1 " +
            number(std::max({1e-6, report.largestVertexGap * 1010.0, report.largestBoundaryTolerance * 1000.0})) + " 1e-10\n";
        for (const auto& record : records.data) bytes += record;
        bytes += "End-of-ACIS-data\n";
        // Read before publishing, into another kernel so verification does not add bodies to the
        // document's registry. A syntactically readable file must also reconstruct valid solids.
        kernel::OcctKernel verification;
        AcisSatResult restored; QString error;
        if (!readAcisSat(bytes, verification, restored, error) || int(restored.solids.size()) != report.bodies)
            return R::fail({ErrorCode::SerializationFailed, "ACIS export readback: " + error.toStdString()});
        return R::ok(bytes);
    } catch (const Standard_Failure& failure) {
        return R::fail({ErrorCode::SerializationFailed, std::string("ACIS export: ") + failure.GetMessageString()});
    } catch (const std::exception& failure) {
        return R::fail({ErrorCode::SerializationFailed, std::string("ACIS export: ") + failure.what()});
    }
#endif
}

cadnext::Result<AcisSatWriteReport> writeAcisSat(kernel::OcctKernel& kernel,
                                                const std::vector<kernel::NamedExchangeBody>& bodies,
                                                const QString& path) {
    AcisSatWriteReport report;
    const auto bytes = encodeAcisSat(kernel, bodies, report);
    if (!bytes.isOk()) return cadnext::Result<AcisSatWriteReport>::fail(bytes.error());
    return save(path, bytes.value(), report);
}

cadnext::Result<AcisSatWriteReport> writeDxfSolids(kernel::OcctKernel& kernel,
                                                  const std::vector<kernel::NamedExchangeBody>& bodies,
                                                  const QString& path) {
    using R = cadnext::Result<AcisSatWriteReport>;
    if (bodies.empty()) return R::fail({ErrorCode::InvalidArgument, "No bodies for DXF export"});
    QByteArray bytes = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1018\n9\n$INSUNITS\n70\n4\n"
                       "9\n$MEASUREMENT\n70\n1\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n";
    AcisSatWriteReport report;
    int handle = 0x100;
    for (const auto& body : bodies) {
        AcisSatWriteReport part;
        const auto sat = encodeAcisSat(kernel, {body}, part);
        if (!sat.isOk()) return R::fail(sat.error());
        bytes += "0\n3DSOLID\n5\n" + QByteArray::number(handle++, 16).toUpper() +
                 "\n100\nAcDbEntity\n8\n0\n100\nAcDbModelerGeometry\n70\n1\n";
        bytes += encryptedSat(sat.value());
        bytes += "100\nAcDb3dSolid\n";
        report.bodies += part.bodies;
        report.largestVertexGap = std::max(report.largestVertexGap, part.largestVertexGap);
        report.largestBoundaryTolerance = std::max(report.largestBoundaryTolerance, part.largestBoundaryTolerance);
    }
    bytes += "0\nENDSEC\n0\nEOF\n";
    // Match the native reader's bound before publishing an unreadable document.
    if (bytes.size() > 256ll * 1024 * 1024)
        return R::fail({ErrorCode::SerializationFailed, "DXF export exceeds the reader's 256 MiB limit"});
    return save(path, bytes, report);
}

} // namespace cadnext::gui
