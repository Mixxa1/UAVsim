#include "cadnext/gui/NativeKompasWriter.hpp"
#include "cadnext/gui/NativeKompasCatalog.hpp"
#include "cadnext/gui/NativeKompasDocument.hpp"
#include "cadnext/gui/NativeKompasModel.hpp"
#include "cadnext/gui/NativeKompasProperties.hpp"
#include "cadnext/gui/NativeKompasService.hpp"
#include "cadnext/gui/NativeKompasTextStyles.hpp"
#include "cadnext/gui/NativeKompasMesh.hpp"
#include "cadnext/gui/NativeKompasPreview.hpp"
#include "cadnext/gui/NativeKompasAssembly.hpp"
#include "cadnext/gui/NativeKompasStorage.hpp"
#include "NativeKompasUvCurve.hpp"
#include "NativeKompasSplineSurface.hpp"

#include "cadnext/kernel/ExactBRepDescription.hpp"

#include <QDateTime>
#include <QObject>

#include <Geom_BSplineCurve.hxx>
#include <Geom_BSplineSurface.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <Standard_Failure.hxx>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <functional>
#include <limits>
#include <map>
#include <optional>
#include <set>
#include <stdexcept>
#include <tuple>

namespace cadnext::gui {
namespace {

using cadnext::Vector3;
using kernel::ExactBRepDescription;
constexpr double kMillimetres = 1000.0;
constexpr double kMetres = 0.001;
constexpr quint64 kMaxRecordBytes = 64ull * 1024 * 1024;
constexpr quint64 kMaxTotalBytes = 512ull * 1024 * 1024;

double nativeMillimetres(double value) {
    const double nearest = value * kMillimetres;
    if (nearest * kMetres == value || !std::isfinite(nearest)) return nearest;
    // A source pole read in metres can lie at a rounding boundary. Choose
    // an adjacent millimetre value that decodes to that same double, when
    // possible, rather than adding a rounding step at every native save.
    double low = nearest, high = nearest;
    for (int step = 0; step < 2; ++step) {
        low = std::nextafter(low, -std::numeric_limits<double>::infinity());
        high = std::nextafter(high, std::numeric_limits<double>::infinity());
        if (low * kMetres == value) return low;
        if (high * kMetres == value) return high;
    }
    return nearest;
}

Vector3 subtract(Vector3 a, Vector3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vector3 cross(Vector3 a, Vector3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double dot(Vector3 a, Vector3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double length(Vector3 a) { return std::sqrt(dot(a, a)); }
Vector3 add(Vector3 a, Vector3 b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
Vector3 scale(Vector3 a, double s) { return {a.x*s,a.y*s,a.z*s}; }
constexpr double kTurn = 6.283185307179586476925286766559;

using UvCurve = detail::KompasUvCurve;

class BodyRecord {
public:
    BodyRecord(const ExactBRepDescription& geometry, quint32& nextId, bool planarOnly,
               quint32 mainName = 0)
        : g_(geometry), uses_(geometry.edges.size()),
          vertexTolerances_(geometry.vertices.size(), 0.0), nextId_(nextId), planarOnly_(planarOnly),
          mainName_(mainName) {}

    QByteArray encode(quint32 number) {
        validate();
        byte(1); integer(number); integer(0xffffffff);
        object(0x6239, 0, [&] {
            count(g_.faces.size());
            for (std::size_t i = 0; i < g_.faces.size(); ++i) face(i);
        });
        return std::move(bytes_);
    }

    QByteArray ownership(quint32 number, std::map<quint16, quint16>& registry) {
        for (const auto& [key, id] : ids_) registry.emplace(id, key.first);
        constexpr std::array<quint16, 3> mathClasses{0x0b04, 0x4313, 0x666e};
        constexpr std::array<quint16, 3> proxyClasses{0x7c69, 0x1408, 0x110f};
        KompasTopologyTables tables;
        for (std::size_t kind = 0; kind < 3; ++kind) {
            for (const auto& [key, id] : ids_) {
                if (key.first != mathClasses[kind]) continue;
                if (nextId_ > 65535) throw std::runtime_error("C3D topology proxy number overflow");
                const quint32 name = quint32(key.second + 1);
                KompasTopologyProxy proxy;
                proxy.id = quint16(nextId_++);
                proxy.name.words = mainName_ ? std::vector<quint32>{mainName_, name} : std::vector<quint32>{name};
                proxy.bodyNumber = number;
                proxy.mathId = id;
                if (kind == 2) proxy.faceStyle = KompasFaceStyle{};
                if (mainName_) {
                    if (tables.groups[kind].empty()) tables.groups[kind].push_back({mainName_, {}});
                    tables.groups[kind].front().proxies.push_back(std::move(proxy));
                } else tables.groups[kind].push_back({name, {std::move(proxy)}});
            }
        }
        QByteArray bytes;
        QString error;
        if (!encodeKompasTopologyTables(tables, registry, bytes, error))
            throw std::runtime_error(error.toStdString());
        for (std::size_t kind = 0; kind < 3; ++kind)
            for (const auto& group : tables.groups[kind])
                for (const auto& proxy : group.proxies) registry.emplace(proxy.id, proxyClasses[kind]);
        return bytes;
    }

    // The body record's shell: a numbered object (02 80, its class, 01 and its id) as in every body record
    // of KOMPAS's own parts, unnumbered when `shellId` is 0.
    QByteArray referencedShell(quint32 number, quint16 shellId = 0) const {
        QByteArray bytes;
        const auto integer = [&](quint64 value, int width) {
            for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
        };
        integer(1, 1); integer(number, 4); integer(0xffffffff, 4);
        integer(2, 1); integer(shellId ? 0x80 : 0, 1); integer(0x6239, 2);
        if (shellId) { integer(1, 1); integer(shellId, 2); }
        integer(g_.faces.size(), 8);
        for (std::size_t face = 0; face < g_.faces.size(); ++face) {
            integer(1, 1); integer(ids_.at({0x666e, face}), 2);
        }
        return bytes;
    }

private:
    struct Use {
        std::size_t face;
        bool forward;
        std::optional<kernel::BSplineCurveDefinition> pcurve;
        std::optional<kernel::AnalyticPcurveDefinition> analyticPcurve;
        UvCurve uv;
    };
    ExactBRepDescription g_;
    std::vector<std::vector<Use>> uses_;
    std::vector<double> vertexTolerances_;
    std::map<std::pair<quint16, std::size_t>, quint16> ids_;
    std::map<int,detail::KompasSplineSurface> splineSupports_;
    mutable std::map<int,Handle(Geom_BSplineCurve)> spatialSplines_;
    quint32& nextId_;
    bool planarOnly_ = false;
    quint32 mainName_ = 0;
    std::size_t nextUv_ = 0;
    std::size_t nextLoop_ = 0;
    QByteArray bytes_;

    void validate() {
        if (planarOnly_ && (g_.lumps.size() != 1 || g_.lumps.front().shells.size() != 1))
            throw std::runtime_error("C3D writing currently requires one connected shell per body");
        if (planarOnly_ && g_.largestVertexGap > 1e-12)
            throw std::runtime_error("C3D planar writing does not yet preserve tolerant boundaries");
        std::size_t loops = 0;
        for (std::size_t i = 0; i < g_.faces.size(); ++i) {
            const auto& f = g_.faces[i];
            const auto& s = g_.surfaces.at(std::size_t(f.surface));
            if (planarOnly_ && s.kind != kernel::DescribedSurface::Kind::Plane)
                throw std::runtime_error("C3D writing currently supports planar surfaces only");
            if (s.kind == kernel::DescribedSurface::Kind::Swept)
                throw std::runtime_error("C3D swept surface serialization is not yet implemented");
            loops += f.loops.size();
            for (const auto& loop : f.loops) {
                if (loop.empty() || (planarOnly_ && loop.size() < 3)) throw std::runtime_error("Empty or unsupported C3D loop");
                for (const auto& use : loop) {
                    const auto& e = g_.edges.at(std::size_t(use.edge));
                    if (planarOnly_ && (e.start < 0 || e.end < 0 || e.start == e.end ||
                        g_.curves.at(std::size_t(e.curve)).kind != kernel::DescribedCurve::Kind::Line))
                        throw std::runtime_error("C3D writing currently supports nondegenerate straight edges only");
                    uses_.at(std::size_t(use.edge)).push_back({i, use.forward, use.pcurve, use.analyticPcurve, {}});
                    for (int v : {e.start, e.end}) {
                        if (v < 0) continue;
                        vertexTolerances_.at(std::size_t(v)) = std::max(vertexTolerances_.at(std::size_t(v)), e.tolerance);
                        if (planarOnly_ && std::fabs(dot(subtract(g_.vertices.at(std::size_t(v)), s.origin), s.axis)) > 1e-12)
                            throw std::runtime_error("C3D planar endpoint is off its support");
                    }
                    // A UV curve may carry a different tolerant boundary from its
                    // 3D line. Reject it unless this first subset preserves it exactly.
                    if (planarOnly_ && use.pcurve) {
                        const auto& p = *use.pcurve;
                        if (p.degree != 1 || p.poles.size() != 2)
                            throw std::runtime_error("C3D writing does not yet support this UV curve");
                        const Vector3 y = cross(s.axis, s.xAxis);
                        for (int side = 0; side < 2; ++side) {
                            const auto& uv = p.poles[std::size_t(side)];
                            const Vector3 point{s.origin.x + uv.x * s.xAxis.x + uv.y * y.x,
                                                s.origin.y + uv.x * s.xAxis.y + uv.y * y.y,
                                                s.origin.z + uv.x * s.xAxis.z + uv.y * y.z};
                            if (length(subtract(point, g_.vertices.at(std::size_t(side == 0 ? e.start : e.end)))) > 1e-12)
                                throw std::runtime_error("C3D writing does not yet preserve this tolerant UV boundary");
                        }
                    }
                }
            }
        }
        for (const auto& uses : uses_)
            if (uses.size() != 2 || uses[0].face == uses[1].face)
                throw std::runtime_error("C3D writing requires exactly two different faces at every edge");
        for (std::size_t i = 0; i < g_.edges.size(); ++i) {
            auto& edge = g_.edges[i];
            const bool implicitVertex=edge.start<0 && edge.end<0;
            if (edge.start < 0 || edge.end < 0) {
                if (edge.start != -1 || edge.end != -1)
                    throw std::runtime_error("C3D ring has only one missing vertex");
                const auto range = curveRange(i);
                edge.start = edge.end = int(g_.vertices.size());
                g_.vertices.push_back(curvePoint(i, range.first));
                vertexTolerances_.push_back(edge.tolerance);
            }
            for (auto& use : uses_[i]) {
                try { use.uv = prepareUv(i, use); }
                catch(const std::exception& error) {
                    throw std::runtime_error("C3D edge " + std::to_string(i+1) + ", face " +
                        std::to_string(use.face+1) + ": " + error.what());
                }
            }
            if (!planarOnly_) {
                auto& firstUv=uses_[i][0].uv;
                auto& secondUv=uses_[i][1].uv;
                if(firstUv.kind==UvCurve::Contour && secondUv.kind==UvCurve::Arc)
                    detail::contourizeKompasUvArc(secondUv,nextUv_);
                else if(secondUv.kind==UvCurve::Contour && firstUv.kind==UvCurve::Arc)
                    detail::contourizeKompasUvArc(firstUv,nextUv_);
                // Spatial B-spline conversion can change the 3D curve's native
                // parameter. The intersection itself uses its two UV curves;
                // normalize their complete domains together, without fitting.
                // A contour has an implicit zero origin, whereas a Hermite
                // spline can retain the source's nonzero parameter origin.
                // Keep matching spline domains unchanged. Otherwise both
                // boundaries permit the same affine conversion without fitting.
                const auto polynomial=[](const UvCurve& c) {
                    return c.kind!=UvCurve::Arc && std::all_of(c.pieces.begin(),c.pieces.end(),
                        [](const UvCurve& p) {return p.kind==UvCurve::Hermite || p.kind==UvCurve::Nurbs;});
                };
                const double domainTolerance=1e-12*std::max({1.,std::fabs(firstUv.first),std::fabs(firstUv.last)});
                if (polynomial(firstUv) && polynomial(secondUv) &&
                    firstUv.kind!=UvCurve::Contour && secondUv.kind!=UvCurve::Contour &&
                    std::fabs(firstUv.first-secondUv.first)<=domainTolerance &&
                    std::fabs(firstUv.last-secondUv.last)<=domainTolerance &&
                    (firstUv.first!=secondUv.first || firstUv.last!=secondUv.last))
                    detail::normalizeKompasUvPolynomial(secondUv,firstUv.last,firstUv.first);
                const bool sameDomain=firstUv.first==secondUv.first && firstUv.last==secondUv.last;
                if(polynomial(firstUv) && polynomial(secondUv) &&
                   (!sameDomain || firstUv.kind==UvCurve::Contour || secondUv.kind==UvCurve::Contour))
                    for(auto& use:uses_[i]) normalizeUv(use.uv);
                else if(polynomial(firstUv) && secondUv.kind==UvCurve::Contour)
                    detail::normalizeKompasUvPolynomial(firstUv,secondUv.last);
                else if(polynomial(secondUv) && firstUv.kind==UvCurve::Contour)
                    detail::normalizeKompasUvPolynomial(secondUv,firstUv.last);
                const auto& a=uses_[i][0].uv; const auto& b=uses_[i][1].uv;
                const double tolerance=1e-12*std::max({1.0,std::fabs(a.first),std::fabs(a.last)});
                if (std::fabs(a.first-b.first)>tolerance || std::fabs(a.last-b.last)>tolerance)
                    throw std::runtime_error("C3D intersection UV curves have different parameter domains");
                detail::harmonizeKompasUvContours(uses_[i][0].uv, uses_[i][1].uv, nextUv_);
                if(implicitVertex)
                    g_.vertices.at(std::size_t(edge.start))=supportPoint(uses_[i][0].face,uvPoint(a,a.first));
                const double slack=std::max(1e-12,edge.tolerance);
                for(const auto& use:uses_[i]) {
                    const auto first=supportPoint(use.face,uvPoint(use.uv,use.uv.first));
                    const auto last=supportPoint(use.face,uvPoint(use.uv,use.uv.last));
                    if(length(subtract(first,g_.vertices.at(std::size_t(edge.start))))>slack ||
                       length(subtract(last,g_.vertices.at(std::size_t(edge.end))))>slack)
                        throw std::runtime_error("C3D UV boundary does not meet its edge vertices within their tolerance");
                }
                for(int sample=0;sample<=32;++sample) {
                    // Keep the stored endpoints exactly: the arithmetic
                    // interpolation can overshoot by one ulp at the last
                    // sample of an asymmetric parameter interval.
                    const double t=sample==0 ? a.first : sample==32 ? a.last :
                        a.first+(a.last-a.first)*sample/32;
                    const auto first=supportPoint(uses_[i][0].face,uvPoint(a,t));
                    const auto second=supportPoint(uses_[i][1].face,uvPoint(b,t));
                    const double gap=length(subtract(first,second));
                    if(gap>slack) {
                        // Each OCCT face boundary is within the edge's declared
                        // tolerance of its shared 3D representative. Two such
                        // boundaries can be farther apart than either one is
                        // from that representative. Verify both against it;
                        // store their measured separation in native vertices.
                        const auto range=curveRange(i);
                        const auto source=curvePoint(i,range.first+(range.second-range.first)*sample/32);
                        double sourceGap=std::max(length(subtract(first,source)),length(subtract(second,source)));
                        // Converting an analytic hyperbola/parabola to an
                        // exact rational spline preserves its locus, but can
                        // change its parameter law. The 3D representative is
                        // not transmitted here; each retained UV boundary must
                        // lie on its locus within the source's same tolerance.
                        if (sourceGap>slack && g_.curves[edge.curve].kind==kernel::DescribedCurve::Kind::BSpline) {
                            const auto& curve=spatialSpline(edge.curve);
                            const auto distance=[&](const Vector3& point) {
                                const GeomAPI_ProjectPointOnCurve projection(
                                    gp_Pnt(point.x,point.y,point.z),curve,range.first,range.second);
                                const gp_Pnt p(point.x,point.y,point.z);
                                const double ends=std::min(p.Distance(curve->Value(range.first)),
                                                           p.Distance(curve->Value(range.second)));
                                return projection.NbPoints() ? std::min(ends,projection.LowerDistance()) : ends;
                            };
                            sourceGap=std::max(distance(first),distance(second));
                        }
                        if(gap>2*slack)
                            throw std::runtime_error("C3D edge " + std::to_string(i+1) +
                                ": paired UV curves do not preserve a common parameter law (separation " +
                                QString::number(gap,'g',17).toStdString() + " m, source precision " +
                                QString::number(slack,'g',17).toStdString() + " m)");
                        if(sourceGap>slack)
                            throw std::runtime_error("C3D edge " + std::to_string(i+1) +
                                ": UV boundary differs from its source edge (gap " + QString::number(sourceGap,'g',17).toStdString() +
                                " m, tolerance " + QString::number(slack,'g',17).toStdString() + " m)");
                        for(const int v:{edge.start,edge.end})
                            vertexTolerances_.at(std::size_t(v))=std::max(vertexTolerances_.at(std::size_t(v)),gap);
                    }
                }
            }
        }
        const quint64 nodes = 1 + g_.faces.size() + g_.surfaces.size() + loops +
                              4 * g_.edges.size() + g_.vertices.size();
        if (nodes + nextId_ - 1 > 65535) throw std::runtime_error("C3D bodies exceed 65535 numbered objects");
    }

    static void normalizeUv(UvCurve& c) {
        detail::normalizeKompasUvPolynomial(c);
    }
    static std::array<double,2> uvPoint(const UvCurve& c,double t) {
        return detail::kompasUvPoint(c,t);
    }
    const detail::KompasSplineSurface& splineSurface(int index) {
        auto found=splineSupports_.find(index);
        if(found==splineSupports_.end())
            found=splineSupports_.emplace(index,detail::prepareKompasSplineSurface(g_.surfaces.at(std::size_t(index)))).first;
        return found->second;
    }
    Vector3 supportPoint(std::size_t face,const std::array<double,2>& uv) {
        const int index=g_.faces.at(face).surface;const auto& s=g_.surfaces.at(std::size_t(index));
        using S=kernel::DescribedSurface::Kind;
        if(s.kind==S::BSpline) {
            const auto p=splineSurface(index).support->Value(uv[0],uv[1]);return {p.X(),p.Y(),p.Z()};
        }
        const auto y=cross(s.axis,s.xAxis);
        if(s.kind==S::Plane)return add(s.origin,add(scale(s.xAxis,uv[0]/kMillimetres),scale(y,uv[1]/kMillimetres)));
        const auto radial=add(scale(s.xAxis,std::cos(uv[0])),scale(y,std::sin(uv[0])));
        if(s.kind==S::Cylinder)return add(s.origin,add(scale(radial,s.radius),scale(s.axis,uv[1]/kMillimetres)));
        if(s.kind==S::Cone) {const double v=uv[1]/kMillimetres;return add(s.origin,add(scale(radial,s.radius+v*s.sinHalfAngle/s.cosHalfAngle),scale(s.axis,v)));}
        if(s.kind==S::Sphere)return add(s.origin,add(scale(radial,s.radius*std::cos(uv[1])),scale(s.axis,s.radius*std::sin(uv[1]))));
        if(s.kind==S::Torus)return add(s.origin,add(scale(radial,s.majorRadius+s.minorRadius*std::cos(uv[1])),scale(s.axis,s.minorRadius*std::sin(uv[1]))));
        throw std::runtime_error("Unsupported C3D UV support");
    }

    std::pair<double, double> curveRange(std::size_t edge) const {
        const auto& e = g_.edges.at(edge);
        if (e.lastParameter > e.firstParameter) return {e.firstParameter, e.lastParameter};
        const auto& c = g_.curves.at(std::size_t(e.curve));
        if (c.kind == kernel::DescribedCurve::Kind::Circle || c.kind == kernel::DescribedCurve::Kind::Ellipse) {
            if (e.start == e.end) return {0, kTurn};
            const Vector3 y = cross(c.direction, c.xAxis);
            const double a = c.kind == kernel::DescribedCurve::Kind::Circle ? c.radius : c.majorRadius;
            const double b = c.kind == kernel::DescribedCurve::Kind::Circle ? c.radius : c.minorRadius;
            const auto angle = [&](int v) { const auto p = subtract(g_.vertices.at(std::size_t(v)), c.origin);
                return std::atan2(dot(p,y)/b, dot(p,c.xAxis)/a); };
            const double first = angle(e.start); double last = angle(e.end);
            while (last <= first) last += kTurn;
            return {first, last};
        }
        throw std::runtime_error("C3D edge has no finite parameter interval");
    }
    Vector3 curvePoint(std::size_t edge, double t) const {
        const auto& c = g_.curves.at(std::size_t(g_.edges.at(edge).curve));
        if(c.kind==kernel::DescribedCurve::Kind::Line)return add(c.origin,scale(c.direction,t));
        const auto y = cross(c.direction, c.xAxis);
        if (c.kind == kernel::DescribedCurve::Kind::Circle || c.kind == kernel::DescribedCurve::Kind::Ellipse) {
            const double a = c.kind == kernel::DescribedCurve::Kind::Circle ? c.radius : c.majorRadius;
            const double b = c.kind == kernel::DescribedCurve::Kind::Circle ? c.radius : c.minorRadius;
            return add(c.origin, add(scale(c.xAxis,a*std::cos(t)), scale(y,b*std::sin(t))));
        }
        if (c.kind == kernel::DescribedCurve::Kind::BSpline) {
            const auto point=spatialSpline(g_.edges.at(edge).curve)->Value(t);
            return {point.X(),point.Y(),point.Z()};
        }
        throw std::runtime_error("C3D implicit ring vertex is not yet supported for this curve");
    }
    const Handle(Geom_BSplineCurve)& spatialSpline(int index) const {
        auto found=spatialSplines_.find(index);
        if(found==spatialSplines_.end()) {
            const auto& b = g_.curves.at(std::size_t(index)).bspline;
            TColgp_Array1OfPnt poles(1, int(b.poles.size()));
            TColStd_Array1OfReal weights(1, int(b.weights.size())), knots(1, int(b.knots.size()));
            TColStd_Array1OfInteger mults(1, int(b.multiplicities.size()));
            for (int i=1;i<=poles.Length();++i) {
                const auto& p=b.poles[std::size_t(i-1)]; poles.SetValue(i,{p.x,p.y,p.z});
                weights.SetValue(i,b.weights[std::size_t(i-1)]);
            }
            for (int i=1;i<=knots.Length();++i) {
                knots.SetValue(i,b.knots[std::size_t(i-1)]); mults.SetValue(i,b.multiplicities[std::size_t(i-1)]);
            }
            found=spatialSplines_.emplace(index,new Geom_BSplineCurve(poles,weights,knots,mults,b.degree,false)).first;
        }
        return found->second;
    }
    std::array<double, 2> uvScale(const kernel::DescribedSurface& s) const {
        using K = kernel::DescribedSurface::Kind;
        if (s.kind == K::Plane) return {kMillimetres, kMillimetres};
        if (s.kind == K::Cylinder) return {1, kMillimetres};
        if (s.kind == K::Cone) return {1, kMillimetres*s.cosHalfAngle};
        return {1, 1};
    }
    UvCurve prepareUv(std::size_t edge, const Use& use) {
        const auto& e = g_.edges.at(edge);
        const auto& s = g_.surfaces.at(std::size_t(g_.faces.at(use.face).surface));
        const auto& c = g_.curves.at(std::size_t(e.curve));
        const Vector3 y = cross(s.axis, s.xAxis);
        UvCurve out; out.key = nextUv_++;
        if(use.analyticPcurve) {
            if(planarOnly_ || use.pcurve || s.kind!=kernel::DescribedSurface::Kind::Plane)
                throw std::runtime_error("Unsupported analytic C3D UV support");
            const auto& p=*use.analyticPcurve;
            if(!std::isfinite(p.first) || !std::isfinite(p.last) || !(p.last>p.first) ||
               !std::isfinite(p.a) || !(p.a>0) || !std::isfinite(p.b) || p.b<0)
                throw std::runtime_error("Invalid analytic C3D UV domain");
            // In cbt_Specific, the analytic supports define the intersection;
            // its UV splines locate the branch. A hyperbola's cosh/sinh law is
            // not rational in this parameter. Cubic Hermite helpers retain
            // that law with an analytic fourth-derivative error bound, rather
            // than projecting a differently parametrized rational 3D curve.
            // A parabola has a quadratic law and needs no approximation.
            const bool hyperbola=p.kind==kernel::AnalyticPcurveDefinition::Kind::Hyperbola;
            double intervals=1;
            if(hyperbola) {
                const double extent=std::max(std::fabs(p.first),std::fabs(p.last));
                const double fourth=std::hypot(p.a*std::cosh(extent),p.b*std::sinh(extent));
                const double bound=std::min(1e-13,std::max(1e-12,e.tolerance)*1e-3);
                intervals=std::ceil((p.last-p.first)*std::pow(fourth/(384*bound),.25));
            }
            if(!std::isfinite(intervals) || intervals>8192)
                throw std::runtime_error("Analytic C3D UV law exceeds the supported helper precision/size");
            const int count=std::max(1,int(intervals));
            const auto value=[&](double t,bool derivative) {
                const double x=hyperbola ? p.a*(derivative ? std::sinh(t) : std::cosh(t)) :
                    (derivative ? t/(2*p.a) : t*t/(4*p.a));
                const double y=hyperbola ? p.b*(derivative ? std::cosh(t) : std::sinh(t)) :
                    (derivative ? 1. : t);
                return std::array<double,2>{
                    kMillimetres*((derivative ? 0 : p.origin.x)+x*p.xAxis.x+y*p.yAxis.x),
                    kMillimetres*((derivative ? 0 : p.origin.y)+x*p.xAxis.y+y*p.yAxis.y)};
            };
            out.kind=UvCurve::Nurbs;out.first=p.first;out.last=p.last;
            out.nurbs.order=4;
            for(int i=0;i<count;++i) {
                UvCurve piece;piece.kind=UvCurve::Hermite;piece.key=nextUv_++;
                piece.first=p.first+(p.last-p.first)*i/count;
                piece.last=p.first+(p.last-p.first)*(i+1)/count;
                const auto a=value(piece.first,false),b=value(piece.last,false);
                const auto da=value(piece.first,true),db=value(piece.last,true);
                piece.poles={a,{}, {},b};
                for(int k=0;k<2;++k) {
                    piece.poles[1][k]=a[k]+(piece.last-piece.first)*da[k]/3;
                    piece.poles[2][k]=b[k]-(piece.last-piece.first)*db[k]/3;
                }
                // Concatenate exact polynomial pieces as one NURBS helper.
                // This also lets the reader lift the planar boundary exactly,
                // instead of approximating a composite curve in 3D again.
                if(i==0)out.nurbs.poles.push_back(piece.poles[0]);
                for(int k=1;k<4;++k)out.nurbs.poles.push_back(piece.poles[k]);
                for(int repeat=0;repeat<(i==0?4:3);++repeat)
                    out.nurbs.knots.push_back(piece.first);
            }
            for(int repeat=0;repeat<4;++repeat)out.nurbs.knots.push_back(p.last);
            out.nurbs.weights.assign(out.nurbs.poles.size(),1);
            detail::validateKompasNurbs2(out.nurbs);out.poles=out.nurbs.poles;
            return out;
        }
        const auto linear = [&](std::array<double,2> first, std::array<double,2> last) {
            out.poles = {first,last}; out.last = std::hypot(last[0]-first[0], last[1]-first[1]);
            if (!(out.last > 0)) throw std::runtime_error("Zero-length UV boundary");
            if (!planarOnly_) {
                // Hermite interpolation keeps a straight segment exact while
                // giving both supports the edge's common parameter domain.
                out.kind=UvCurve::Hermite;
                std::tie(out.first,out.last)=curveRange(edge);
                out.poles={first,{}, {},last};
                for(int k=0;k<2;++k) {
                    out.poles[1][k]=first[k]+(last[k]-first[k])/3;
                    out.poles[2][k]=first[k]+2*(last[k]-first[k])/3;
                }
            }
        };
        auto pcurve = use.pcurve;
        // Projection onto a plane is affine, so projecting every control point
        // preserves a spatial NURBS exactly, including its knots and weights.
        if (!pcurve && s.kind == kernel::DescribedSurface::Kind::Plane &&
            c.kind == kernel::DescribedCurve::Kind::BSpline) {
            pcurve = c.bspline;
            pcurve->periodic = false; // the source definition is already unwrapped
            for (auto& pole : pcurve->poles) {
                const auto offset = subtract(pole,s.origin);
                if (std::fabs(dot(offset,s.axis)) > std::max(1e-12,e.tolerance))
                    throw std::runtime_error("C3D spline is off its plane");
                pole = {dot(offset,s.xAxis),dot(offset,y),0};
            }
        }
        if (pcurve) {
            const auto& p = *pcurve;
            const auto factors = uvScale(s);
            if ((planarOnly_ || s.kind != kernel::DescribedSurface::Kind::BSpline) &&
                p.degree == 1 && p.poles.size() == 2 && p.weights.size()==2 && p.weights[0]==p.weights[1]) {
                linear({p.poles[0].x*factors[0], p.poles[0].y*factors[1]},
                       {p.poles[1].x*factors[0], p.poles[1].y*factors[1]});
                if (!planarOnly_) {
                    if (p.periodic || p.knots.size()!=2 || p.multiplicities!=std::vector<int>{2,2} ||
                        !std::isfinite(p.knots[0]) || !std::isfinite(p.knots[1]) || !(p.knots[1]>p.knots[0]))
                        throw std::runtime_error("Invalid C3D linear UV parameter domain");
                    out.first=p.knots.front();out.last=p.knots.back();
                }
                return out;
            }
            // Keep linear boundaries of spline supports degree one too.
            // Raising their degree to a cubic helper alters the continuity
            // reported to OCCT's integration although the locus is straight.
            if (p.degree < 1 || p.degree > 25 || p.poles.size() < 2 || p.knots.size() < 2 ||
                p.knots.size() != p.multiplicities.size() || p.weights.size() != p.poles.size() || p.periodic)
                throw std::runtime_error("Invalid or unsupported C3D UV spline definition");
            out.kind=UvCurve::Nurbs;out.nurbs.order=quint64(p.degree+1);
            for(const auto& pole:p.poles)
                out.nurbs.poles.push_back({pole.x*factors[0],pole.y*factors[1]});
            out.nurbs.weights=p.weights;
            for(std::size_t i=0;i<p.knots.size();++i) {
                if(p.multiplicities[i]<1 || p.multiplicities[i]>p.degree+1)
                    throw std::runtime_error("Invalid C3D UV knot multiplicity");
                for(int j=0;j<p.multiplicities[i];++j)out.nurbs.knots.push_back(p.knots[i]);
            }
            detail::validateKompasNurbs2(out.nurbs);
            out.poles=out.nurbs.poles;
            out.first=out.nurbs.knots[std::size_t(p.degree)];
            out.last=out.nurbs.knots[out.nurbs.poles.size()];
            return out;
        }
        using S = kernel::DescribedSurface::Kind;
        using C = kernel::DescribedCurve::Kind;
        if (s.kind == S::Plane) {
            if (c.kind == C::Line) { linear(uv(use.face,e.start),uv(use.face,e.end)); return out; }
            if (c.kind != C::Circle && c.kind != C::Ellipse)
                throw std::runtime_error("C3D nonconic boundary needs an exact source UV spline");
            if (std::fabs(dot(subtract(c.origin,s.origin),s.axis))>1e-12 ||
                std::fabs(std::fabs(dot(c.direction,s.axis))-1)>1e-12)
                throw std::runtime_error("C3D conic is off its plane");
            const auto center=subtract(c.origin,s.origin), cy=cross(c.direction,c.xAxis);
            out.kind=UvCurve::Arc;
            out.center={dot(center,s.xAxis)*kMillimetres,dot(center,y)*kMillimetres};
            out.x={dot(c.xAxis,s.xAxis),dot(c.xAxis,y)};
            out.y={dot(cy,s.xAxis),dot(cy,y)};
            out.a=(c.kind==C::Circle?c.radius:c.majorRadius)*kMillimetres;
            out.b=(c.kind==C::Circle?c.radius:c.minorRadius)*kMillimetres;
            std::tie(out.first,out.last)=curveRange(edge); return out;
        }
        if (c.kind != C::Circle) throw std::runtime_error("C3D curved boundary needs an exact source UV curve");
        const auto range=curveRange(edge); const auto point=subtract(curvePoint(edge,range.first),s.origin);
        const auto center=subtract(c.origin,s.origin);
        const double z=dot(center,s.axis);
        const double radial=length(subtract(center,scale(s.axis,z)));
        if (radial<=1e-12 && std::fabs(std::fabs(dot(c.direction,s.axis))-1)<=1e-12) {
            const double u=std::atan2(dot(point,y),dot(point,s.xAxis));
            const double sweep=(dot(c.direction,s.axis)>0?1:-1)*(range.second-range.first);
            double v=0, radius=0;
            if (s.kind==S::Cylinder) v=z*kMillimetres,radius=s.radius;
            else if (s.kind==S::Cone) v=z*kMillimetres,radius=s.radius+z*s.sinHalfAngle/s.cosHalfAngle;
            else if (s.kind==S::Sphere) { v=std::asin(std::clamp(z/s.radius,-1.0,1.0)); radius=s.radius*std::cos(v); }
            else if (s.kind==S::Torus) { v=std::atan2(z,c.radius-s.majorRadius); radius=s.majorRadius+s.minorRadius*std::cos(v);
                if (std::fabs(z-s.minorRadius*std::sin(v))>1e-12) throw std::runtime_error("C3D parallel is off its torus"); }
            else throw std::runtime_error("C3D spline boundary needs an exact source UV curve");
            if (std::fabs(radius-c.radius)>1e-12) throw std::runtime_error("C3D parallel is off its support");
            linear({u,v},{u+sweep,v}); return out;
        }
        if (s.kind==S::Torus && std::fabs(z)<=1e-12 && std::fabs(radial-s.majorRadius)<=1e-12 &&
            std::fabs(c.radius-s.minorRadius)<=1e-12) {
            const auto radialDirection=scale(center,1/radial);
            const auto expectedNormal=cross(radialDirection,s.axis);
            if (std::fabs(std::fabs(dot(expectedNormal,c.direction))-1)>1e-12)
                throw std::runtime_error("C3D torus meridian has a different support");
            const double u=std::atan2(dot(center,y),dot(center,s.xAxis));
            const double v=std::atan2(dot(point,s.axis),dot(point,radialDirection)-s.majorRadius);
            const double sweep=(dot(expectedNormal,c.direction)>0?1:-1)*(range.second-range.first);
            linear({u,v},{u,v+sweep}); return out;
        }
        throw std::runtime_error("C3D boundary needs an exact source UV curve");
    }

    void byte(quint8 v) { bytes_.append(char(v)); }
    void word(quint16 v) { byte(quint8(v & 0xff)); byte(quint8(v >> 8)); }
    void integer(quint32 v) { word(quint16(v & 0xffff)); word(quint16(v >> 16)); }
    void count(quint64 v) { integer(quint32(v)); integer(quint32(v >> 32)); }
    void real(double v) {
        if (!std::isfinite(v)) throw std::runtime_error("Non-finite C3D value");
        quint64 bits;
        std::memcpy(&bits, &v, sizeof(bits));
        count(bits);
    }
    void point(Vector3 v) { real(nativeMillimetres(v.x)); real(nativeMillimetres(v.y)); real(nativeMillimetres(v.z)); }
    void direction(Vector3 v) { real(v.x); real(v.y); real(v.z); }
    void emptyBox() { for (int i=0;i<3;++i) real(1e300); for (int i=0;i<3;++i) real(-1e300); }

    template <typename F> void object(quint16 cls, std::size_t key, F&& body) {
        const auto found = ids_.find({cls, key});
        if (found != ids_.end()) { byte(1); word(found->second); return; }
        if (nextId_ > 65535) throw std::runtime_error("C3D object number overflow");
        const quint16 id = quint16(nextId_++);
        ids_.emplace(std::pair{cls, key}, id);
        byte(2); byte(0x80); word(cls); byte(1); word(id);
        body();
        if (quint64(bytes_.size()) > kMaxRecordBytes)
            throw std::runtime_error("C3D body record exceeds 64 MiB");
    }

    void topology(quint32 name) {
        byte(mainName_ ? 2 : 1);
        if (mainName_) integer(mainName_);
        integer(name);
        byte(0); byte(0); byte(0);
        count(0); // attributes
    }
    std::array<double, 2> uv(std::size_t face, int vertex) const {
        const auto& s = g_.surfaces.at(std::size_t(g_.faces.at(face).surface));
        const auto d = subtract(g_.vertices.at(std::size_t(vertex)), s.origin);
        return {dot(d, s.xAxis) * kMillimetres, dot(d, cross(s.axis, s.xAxis)) * kMillimetres};
    }
    void uvBounds(std::size_t face) {
        std::array<double, 2> low{INFINITY, INFINITY}, high{-INFINITY, -INFINITY};
        const auto point = [&](const std::array<double,2>& p) {
            for (int k=0;k<2;++k) { low[k]=std::min(low[k],p[k]); high[k]=std::max(high[k],p[k]); }
        };
        const std::function<void(const UvCurve&)> curve = [&](const UvCurve& c) {
            for (const auto& p:c.poles) point(p);
            if (c.kind==UvCurve::Arc) {
                const double u=std::hypot(c.a*c.x[0],c.b*c.y[0]),v=std::hypot(c.a*c.x[1],c.b*c.y[1]);
                point({c.center[0]-u,c.center[1]-v}); point({c.center[0]+u,c.center[1]+v});
            }
            for (const auto& piece:c.pieces) curve(piece);
        };
        for (const auto& uses:uses_) for (const auto& use:uses) if (use.face==face) curve(use.uv);
        real(low[0]); real(high[0]); real(low[1]); real(high[1]);
    }
    void surface(std::size_t face) {
        const auto& s = g_.surfaces.at(std::size_t(g_.faces.at(face).surface));
        using K = kernel::DescribedSurface::Kind;
        quint16 cls=0;
        switch(s.kind) {
        case K::Plane: cls=0x601e; break;
        case K::Cylinder: cls=0x145d; break;
        case K::Cone: cls=0x1848; break;
        case K::Sphere: cls=0x622e; break;
        case K::Torus: cls=0x5d66; break;
        case K::BSpline: cls=0x6e36; break;
        default: throw std::runtime_error("Unsupported C3D surface");
        }
        object(cls, face, [&] {
            emptyBox();
            if (s.kind==K::BSpline) {
                const auto& native=splineSurface(g_.faces.at(face).surface);
                const auto& b=native.grid;
                byte(native.closedU); byte(native.closedV); count(quint64(b.vPoleCount)); count(quint64(b.uPoleCount));
                for(int v=0;v<b.vPoleCount;++v) for(int u=0;u<b.uPoleCount;++u) point(b.poles.at(std::size_t(u*b.vPoleCount+v)));
                count(quint64(b.uDegree+1)); count(quint64(b.vDegree+1));
                for(int v=0;v<b.vPoleCount;++v) for(int u=0;u<b.uPoleCount;++u) real(b.weights.at(std::size_t(u*b.vPoleCount+v)));
                const auto knots=[&](const auto& values) {
                    count(values.size()); for(double value:values) real(value);
                };
                knots(native.uKnots); knots(native.vKnots);
                bytes_ += "BBBB"; uvBounds(face); return;
            }
            point(s.origin);
            direction(s.xAxis); direction(cross(s.axis, s.xAxis)); direction(s.axis);
            if (s.kind==K::Cylinder) { real(nativeMillimetres(s.radius)); real(1); }
            else if (s.kind==K::Cone) { real(nativeMillimetres(s.radius)); real(std::atan2(s.sinHalfAngle,s.cosHalfAngle)); real(1); }
            else if (s.kind==K::Sphere) real(nativeMillimetres(s.radius));
            else if (s.kind==K::Torus) { real(nativeMillimetres(s.majorRadius)); real(nativeMillimetres(s.minorRadius)); }
            if (s.kind==K::Sphere) { real(0); real(kTurn); real(-kTurn/4); real(kTurn/4); }
            else uvBounds(face);
        });
    }
    void uvCurve(const UvCurve& c) {
        const quint16 cls=c.kind==UvCurve::Line?0x0847:c.kind==UvCurve::Arc?0x106a:
            c.kind==UvCurve::Hermite?0x1e16:c.kind==UvCurve::Nurbs?0x7505:0x0c74;
        object(cls,c.key,[&] {
            const auto p=[&](const std::array<double,2>& v) { real(v[0]); real(v[1]); };
            if(c.kind==UvCurve::Line) { p(c.poles.at(0)); p(c.poles.at(1)); }
            else if(c.kind==UvCurve::Arc) {
                p(c.center); p(c.x); p(c.y); real(c.a); real(c.b); real(c.first); real(c.last);
                integer(1); byte(std::fabs(c.a-c.b)<=1e-12*std::max(c.a,c.b)); byte(std::fabs(c.last-c.first-kTurn)<=1e-12);
            } else if(c.kind==UvCurve::Nurbs) {
                QByteArray data;QString error;
                if(!detail::encodeKompasNurbs2Data(c.nurbs,data,error))
                    throw std::runtime_error(error.toStdString());
                bytes_+=data;
            } else if(c.kind==UvCurve::Hermite) {
                const auto tangent=[&](const UvCurve& arc,int side) {
                    for(int j=0;j<2;++j) real(3*(arc.poles[side==0?1:3][j]-arc.poles[side==0?0:2][j])/(arc.last-arc.first));
                };
                const auto n=c.pieces.empty()?std::size_t(1):c.pieces.size();
                count(n);
                if(c.pieces.empty()) {p(c.poles.at(0));p(c.poles.at(3));}
                else {p(c.pieces.front().poles.at(0));for(const auto& arc:c.pieces)p(arc.poles.at(3));}
                real(-1); real(1e300); real(1e300); real(-1e300); real(-1e300); byte(0);
                count(n); real(c.first);
                if(c.pieces.empty()) {real(c.last);tangent(c,0);tangent(c,1);}
                else {
                    for(const auto& arc:c.pieces)real(arc.last);
                    tangent(c.pieces.front(),0);for(const auto& arc:c.pieces)tangent(arc,1);
                }
            } else {
                // Empty rectangle, parameter length, metric length not cached.
                real(1e300); real(1e300); real(-1e300); real(-1e300); real(c.last); real(-1);
                byte(0); count(c.pieces.size());
                for(const auto& piece:c.pieces) uvCurve(piece);
            }
        });
    }
    void intersection(std::size_t edge) {
        const auto& e = g_.edges.at(edge);
        object(0x776d, edge, [&] {
            for (std::size_t side = 0; side < 2; ++side) {
                byte(0); word(0x4665); // native curve-on-surface value
                surface(uses_.at(edge).at(side).face); uvCurve(uses_.at(edge).at(side).uv);
            }
            byte(0);
            // Native cbt_Specific uses the UV splines to identify the branch;
            // the two surfaces still define the intersection. Their helper
            // law and source precision were checked together above.
            byte(g_.curves.at(std::size_t(e.curve)).kind==kernel::DescribedCurve::Kind::BSpline ? 1 : 0);
            // Native uncached intersection fields: unset scalar, empty spatial
            // cube and unset metric length. These are not a parameter interval.
            real(-1e300); emptyBox(); real(-1);
            byte(0); // no cached approximation of the exact intersection
            byte(1); // intersection runs with the edge
        });
    }
    void vertex(int id) {
        object(0x0b04, std::size_t(id), [&] {
            topology(quint32(id + 1)); point(g_.vertices.at(std::size_t(id)));
            real(vertexTolerances_.at(std::size_t(id)) * kMillimetres);
        });
    }
    void edge(std::size_t id) {
        const auto& e = g_.edges.at(id);
        object(0x4313, id, [&] {
            topology(quint32(id + 1)); intersection(id); vertex(e.start); vertex(e.end);
        });
    }
    void face(std::size_t id) {
        const auto& f = g_.faces.at(id);
        object(0x666e, id, [&] {
            topology(quint32(id + 1)); byte(0); surface(id); byte(f.reversed ? 0 : 1);
            count(f.loops.size());
            for (const auto& loop : f.loops) {
                const std::size_t key = nextLoop_++;
                object(0x7d68, key, [&] {
                    count(loop.size());
                    for (const auto& use : loop) {
                        edge(std::size_t(use.edge)); byte(use.forward ? 1 : 0);
                    }
                    // MbRect uses minX,minY,maxX,maxY; surface parameter bounds
                    // use a different order. Leave the loop's rectangle uncached.
                    real(1e300);real(1e300);real(-1e300);real(-1e300);
                });
            }
            emptyBox();
        });
    }
};

} // namespace

bool encodeRecords(kernel::OcctKernel& kernel,
                                  const std::vector<kernel::ShapeHandle>& bodies,
                                  std::vector<QByteArray>& records, QString& error, bool planarOnly,
                                  quint32* lastObjectId = nullptr,
                                  KompasBodyOwnership* ownership = nullptr,
                                  quint32 firstObjectId = 1) {
    records.clear(); error.clear();
    if(lastObjectId)*lastObjectId=0;
    if(ownership)*ownership={};
    if (bodies.empty() || bodies.size() > 4096) {
        error = QObject::tr("Для записи C3D требуется от 1 до 4096 тел.");
        return false;
    }
    if (!firstObjectId || firstObjectId > 65535) {
        error = QObject::tr("Начальный номер объекта C3D должен быть от 1 до 65535.");
        return false;
    }
    std::vector<QByteArray> staged;
    KompasBodyOwnership stagedOwnership;
    quint64 total = 0;
    quint32 nextId = firstObjectId;
    try {
        for (std::size_t i = 0; i < bodies.size(); ++i) {
            const auto description = kernel::describeExactBRep(
                kernel, bodies[i], kernel::ConeParameterization::SourceFrame);
            if (!description.isOk()) throw std::runtime_error(description.error().message);
            BodyRecord body(description.value(), nextId, planarOnly);
            QByteArray record = body.encode(quint32(i + 1));
            total += quint64(record.size());
            if (ownership) {
                auto table = body.ownership(quint32(i + 1), stagedOwnership.registry);
                total += quint64(table.size());
                stagedOwnership.records.push_back(std::move(table));
            }
            if (total > kMaxTotalBytes) throw std::runtime_error("C3D body records exceed 512 MiB");
            staged.push_back(std::move(record));
        }
    } catch (const Standard_Failure& failure) {
        error = QObject::tr("Запись геометрии C3D: %1").arg(QString::fromUtf8(failure.GetMessageString()));
        return false;
    } catch (const std::exception& failure) {
        error = QObject::tr("Запись геометрии C3D: %1").arg(QString::fromUtf8(failure.what()));
        return false;
    }
    records = std::move(staged);
    if(lastObjectId)*lastObjectId=nextId-1;
    if(ownership)*ownership=std::move(stagedOwnership);
    return true;
}

bool encodeKompasPlanarBodyRecords(kernel::OcctKernel& kernel,
                                  const std::vector<kernel::ShapeHandle>& bodies,
                                  std::vector<QByteArray>& records, QString& error) {
    return encodeRecords(kernel,bodies,records,error,true);
}
bool encodeKompasBodyRecords(kernel::OcctKernel& kernel,
                            const std::vector<kernel::ShapeHandle>& bodies,
                            std::vector<QByteArray>& records, QString& error,quint32* lastObjectId,
                            KompasBodyOwnership* ownership,quint32 firstObjectId) {
    return encodeRecords(kernel,bodies,records,error,false,lastObjectId,ownership,firstObjectId);
}

bool encodeKompasApplicationBodyRecords(
    kernel::OcctKernel& kernel, const std::vector<kernel::ShapeHandle>& bodies,
    const std::vector<KompasBodyApplicationState>& states,
    std::vector<QByteArray>& records, QString& error, quint32* lastObjectId,
    std::vector<QByteArray>* applicationLinks, quint32 firstObjectId) {
    records.clear(); error.clear();
    if (lastObjectId) *lastObjectId = 0;
    if (applicationLinks == &records) {
        error = QObject::tr("Записи тел и служебные связи КОМПАС требуют разных выходных контейнеров.");
        return false;
    }
    if (applicationLinks) applicationLinks->clear();
    if (states.size() != bodies.size()) {
        error = QObject::tr("Каждому телу КОМПАС требуется отдельная служебная запись.");
        return false;
    }
    std::set<quint32> names;
    for (const auto& state : states) {
        if (!names.insert(state.nativeName).second) {
            error = QObject::tr("Нативные имена тел КОМПАС должны быть уникальными.");
            return false;
        }
    }
    std::vector<QByteArray> staged;
    std::vector<QByteArray> stagedLinks;
    KompasBodyOwnership ownership;
    quint32 lastId = 0;
    if (!encodeKompasBodyRecords(kernel, bodies, staged, error, &lastId, &ownership, firstObjectId)) return false;
    std::map<quint16, quint16> mathRegistry;
    for (const auto& [id, cls] : ownership.registry)
        if (cls != 0x7c69 && cls != 0x1408 && cls != 0x110f) mathRegistry.emplace(id, cls);
    quint64 total = 0;
    for (std::size_t i = 0; i < staged.size(); ++i) {
        KompasBodyApplication application;
        application.state = states[i];
        qsizetype size = 0;
        if (!decodeKompasTopologyTables(ownership.records[i], 0, mathRegistry,
                                       application.topology, size, error)) return false;
        if (size != ownership.records[i].size()) {
            error = QObject::tr("Лишние данные в таблицах топологии тела КОМПАС.");
            return false;
        }
        QByteArray suffix;
        if (!encodeKompasBodyApplication(application, mathRegistry, suffix, error)) return false;
        if (applicationLinks) {
            QByteArray link;
            if (!encodeKompasBodyApplicationLink(states[i].nativeName, link, error)) return false;
            stagedLinks.push_back(std::move(link));
        }
        if (quint64(staged[i].size()) + quint64(suffix.size()) > kMaxRecordBytes) {
            error = QObject::tr("Запись тела КОМПАС превышает 64 МиБ.");
            return false;
        }
        staged[i] += suffix;
        total += quint64(staged[i].size());
        if (total > kMaxTotalBytes) {
            error = QObject::tr("Записи тел КОМПАС превышают 512 МиБ.");
            return false;
        }
    }
    records = std::move(staged);
    if (lastObjectId) *lastObjectId = lastId;
    if (applicationLinks) *applicationLinks = std::move(stagedLinks);
    return true;
}

bool encodeKompasImportedBodyOperation(
    kernel::OcctKernel& kernel, kernel::ShapeHandle shape,
    const KompasImportedOperationPrefix& prefix,
    const KompasImportedOperationSuffix& suffix,
    const KompasBodyApplicationState& state,
    KompasImportedBodyOperation& operation, QString& error) {
    operation = {}; error.clear();
    if (prefix.bodyNumber != suffix.bodyNumber || prefix.applicationName != state.nativeName) {
        error = QObject::tr("Операция и тело КОМПАС имеют разные служебные имена или номера.");
        return false;
    }
    if (prefix.placement != KompasImportedOperationPrefix{}.placement) {
        error = QObject::tr("Преобразование геометрии в систему координат операции КОМПАС пока не поддержано.");
        return false;
    }
    QByteArray before, after;
    if (!encodeKompasImportedOperationPrefix(prefix, before, error) ||
        !encodeKompasImportedOperationSuffix(suffix, after, error)) return false;
    KompasImportedBodyOperation staged;
    quint32 nextId = quint32(prefix.objectId) + 1;
    try {
        const auto description = kernel::describeExactBRep(
            kernel, shape, kernel::ConeParameterization::SourceFrame);
        if (!description.isOk()) throw std::runtime_error(description.error().message);
        BodyRecord body(description.value(), nextId, false, prefix.mainName);
        const auto geometry = body.encode(prefix.bodyNumber);
        staged.registry.emplace(prefix.objectId, 0x2801);
        const auto tables = body.ownership(prefix.bodyNumber, staged.registry);
        std::map<quint16, quint16> mathRegistry;
        for (const auto& [id, cls] : staged.registry)
            if (cls != 0x7c69 && cls != 0x1408 && cls != 0x110f) mathRegistry.emplace(id, cls);
        KompasBodyApplication application;
        application.state = state;
        qsizetype consumed = 0;
        if (!decodeKompasTopologyTables(tables, 0, mathRegistry, application.topology, consumed, error)) return false;
        if (consumed != tables.size()) throw std::runtime_error("Unexpected topology table extent");
        QByteArray bodyState;
        if (!encodeKompasBodyApplication(application, mathRegistry, bodyState, error) ||
            !encodeKompasBodyApplicationLink(state.nativeName, staged.applicationLink, error)) return false;
        staged.operation = before + geometry.mid(9) + after;
        if (nextId > 65535) throw std::runtime_error("C3D object registry exceeds 16 bits");
        staged.shellId = quint16(nextId++);
        staged.registry.emplace(staged.shellId, 0x6239);
        staged.body = body.referencedShell(prefix.bodyNumber, staged.shellId) + bodyState;
        if (quint64(staged.operation.size()) > kMaxRecordBytes || quint64(staged.body.size()) > kMaxRecordBytes)
            throw std::runtime_error("C3D operation or body record exceeds 64 MiB");
        staged.lastObjectId = nextId - 1;
    } catch (const Standard_Failure& failure) {
        error = QObject::tr("Запись операции C3D: %1").arg(QString::fromUtf8(failure.GetMessageString()));
        return false;
    } catch (const std::exception& failure) {
        error = QObject::tr("Запись операции C3D: %1").arg(QString::fromUtf8(failure.what()));
        return false;
    }
    operation = std::move(staged);
    return true;
}

bool writeKompasNativeDocument(
    kernel::OcctKernel& kernel,
    const std::vector<KompasNativeWriteBody>& bodies,
    const QString& path, QString& error,
    const KompasNativeWriteOptions& options) {
    error.clear();
    if (bodies.empty() || bodies.size() > 4096) {
        error = QObject::tr("Для документа КОМПАС требуется от 1 до 4096 тел.");
        return false;
    }
    if (options.title.size() > 65536 || options.title.contains(QChar(u'\0')) ||
        options.color > 0xffffff || !std::isfinite(options.nativeDensity) ||
        options.nativeDensity <= 0) {
        error = QObject::tr("Недопустимые свойства документа КОМПАС.");
        return false;
    }
    for (const auto field : options.material) {
        if (field > 100) {
            error = QObject::tr("Параметры материала КОМПАС должны быть от 0 до 100.");
            return false;
        }
    }

    std::vector<quint32> bodyNumbers;
    std::set<quint32> usedBodyNumbers;
    for (const auto& body : bodies) {
        if (body.bodyNumber && !usedBodyNumbers.insert(body.bodyNumber).second) {
            error = QObject::tr("Номера тел КОМПАС должны быть положительными и различными.");
            return false;
        }
    }
    std::vector<kernel::ShapeHandle> placedBodies;
    placedBodies.reserve(bodies.size());
    bodyNumbers.reserve(bodies.size());
    quint32 nextBodyNumber = 1;
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        quint32 number = bodies[i].bodyNumber;
        if (!number) {
            while (usedBodyNumbers.count(nextBodyNumber)) ++nextBodyNumber;
            number = nextBodyNumber++;
            usedBodyNumbers.insert(number);
        }
        const QString name = bodies[i].name.isEmpty()
            ? QStringLiteral("Body %1").arg(number) : bodies[i].name;
        if (name.size() > 65536 || name.contains(QChar(u'\0'))) {
            error = QObject::tr("Недопустимое имя тела КОМПАС.");
            return false;
        }
        bodyNumbers.push_back(number);
        const auto placed = kernel.placeExchangeBody({bodies[i].shape, bodies[i].placement});
        if (!placed.isOk()) {
            error = QObject::tr("Размещение тела КОМПАС: %1")
                        .arg(QString::fromStdString(placed.error().message));
            return false;
        }
        placedBodies.push_back(placed.value());
    }

    // The seven default datum controllers form the stable frame referenced by
    // every authored imported operation. Their IDs precede operation IDs.
    std::map<quint16, quint16> registry;
    QByteArray datumBytes;
    const auto addDatum = [&](KompasDatum datum, quint16 classId) {
        QByteArray encoded;
        if (!encodeKompasDatum(datum, registry, encoded, error)) return false;
        datumBytes += encoded;
        registry.emplace(datum.objectId, classId);
        return true;
    };
    // KOMPAS's own default datums (Плоскость XY... Начало координат, v1..v7, their colours), ids 35..41.
    for (const KompasDatum& datum : kompasDefaultDatums(9, 35, 93))
        if (!addDatum(datum, datum.kind == KompasDatum::Plane ? 0x507a : datum.kind == KompasDatum::Axis ? 0x2c70 : 0x4170)) return false;

    struct OperationParts {
        QByteArray operation;
        QByteArray body;
        QByteArray applicationLink;
        quint32 bodyNumber = 0;
        quint32 nativeName = 0;
        quint16 shellId = 0;
    };
    std::vector<OperationParts> operations;
    operations.reserve(bodies.size());
    quint32 nextObjectId = 42;
    quint32 lastObjectId = 41;
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        if (nextObjectId > 65535) {
            error = QObject::tr("Реестр объектов КОМПАС превышает 16-битный диапазон.");
            return false;
        }
        const quint32 bodyNumber = bodyNumbers[i];
        const quint32 nativeName = 100 + quint32(i);
        KompasImportedOperationPrefix prefix;
        prefix.objectId = quint16(nextObjectId);
        prefix.mainName = 1003 + quint32(i);
        prefix.title = bodies[i].name.isEmpty()
            ? QStringLiteral("Body %1").arg(bodyNumber) : bodies[i].name;
        prefix.variableName = QStringLiteral("Body%1").arg(bodyNumber);
        prefix.applicationName = nativeName;
        prefix.bodyNumber = bodyNumber;
        prefix.frameName = 99;
        prefix.color = options.color;
        prefix.material = options.material;
        KompasImportedOperationSuffix suffix;
        suffix.bodyNumber = bodyNumber;
        KompasOperationAttribute color;
        color.color = options.color;
        KompasOperationAttribute visible;
        visible.kind = KompasOperationAttribute::Boolean;
        visible.boolean = true;
        suffix.attributes = {color, visible};
        KompasBodyApplicationState state;
        state.nativeName = nativeName;
        KompasImportedBodyOperation operation;
        if (!encodeKompasImportedBodyOperation(kernel, placedBodies[i], prefix, suffix,
                                               state, operation, error)) return false;
        for (const auto [id, classId] : operation.registry) {
            if (!registry.emplace(id, classId).second) {
                error = QObject::tr("Конфликт реестра объектов КОМПАС.");
                return false;
            }
        }
        if (!operation.lastObjectId || operation.lastObjectId < nextObjectId) {
            error = QObject::tr("Операция КОМПАС не выдала корректный диапазон объектов.");
            return false;
        }
        nextObjectId = operation.lastObjectId + 1;
        lastObjectId = operation.lastObjectId;
        operations.push_back({std::move(operation.operation), std::move(operation.body),
                              std::move(operation.applicationLink), bodyNumber, nativeName, operation.shellId});
    }

    // Use the union of kernel bounds in millimetres for all three native
    // model boxes. Empty or invalid geometry fails before any file is touched.
    std::array<double, 6> bounds{};
    bool haveBounds = false;
    for (const auto body : placedBodies) {
        const auto result = kernel.boundingBox(body);
        if (!result.isOk()) {
            error = QObject::tr("Габариты тела КОМПАС: %1")
                        .arg(QString::fromStdString(result.error().message));
            return false;
        }
        const auto& min = result.value().min;
        const auto& max = result.value().max;
        const std::array<double, 6> box{min.x * 1000, min.y * 1000, min.z * 1000,
                                        max.x * 1000, max.y * 1000, max.z * 1000};
        if (!std::all_of(box.begin(), box.end(), [](double value) { return std::isfinite(value); })) {
            error = QObject::tr("Тело КОМПАС имеет недопустимые габариты.");
            return false;
        }
        if (!haveBounds) { bounds = box; haveBounds = true; }
        else {
            for (int axis = 0; axis < 3; ++axis) {
                bounds[axis] = std::min(bounds[axis], box[axis]);
                bounds[axis + 3] = std::max(bounds[axis + 3], box[axis + 3]);
            }
        }
    }

    KompasModelHeader modelHeader;
    modelHeader.controllerCount = 7 + operations.size();
    for (auto& box : modelHeader.boxes) box = bounds;
    QByteArray modelHeaderBytes;
    if (!encodeKompasModelHeader(modelHeader, modelHeaderBytes, error)) return false;
    KompasModelFooter modelFooter;
    modelFooter.originId = 41;
    modelFooter.nativeCounters = {modelHeader.controllerCount,
                                  quint64(operations.size()),
                                  quint64(registry.size()), 0};
    modelFooter.nextMainName = 1003 + quint32(operations.size());
    QByteArray modelFooterBytes;
    if (!encodeKompasModelFooter(modelFooter, registry, modelFooterBytes, error)) return false;
    QByteArray modelRecord = modelHeaderBytes + datumBytes;
    for (const auto& operation : operations) modelRecord += operation.operation;
    modelRecord += modelFooterBytes;

    KompasModelProperties modelProperties;
    modelProperties.name = options.title;
    modelProperties.color = options.color;
    modelProperties.material = options.material;
    modelProperties.materialName = options.materialName;
    modelProperties.nativeDensity = options.nativeDensity;
    QByteArray modelPropertyBytes;
    if (!encodeKompasModelProperties(modelProperties, modelPropertyBytes, error)) return false;
    KompasDeferredMassProperties mass;
    mass.nativeDensity = options.nativeDensity / 1000.0;
    QByteArray massBytes;
    if (!encodeKompasDeferredMassProperties(mass, massBytes, error)) return false;

    std::vector<QByteArray> bodyPropertyBytes;
    bodyPropertyBytes.reserve(bodies.size());
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        const auto& body = bodies[i];
        KompasBodyProperties properties;
        properties.properties = modelProperties;
        properties.properties.name = body.name.isEmpty()
            ? QStringLiteral("Body %1").arg(bodyNumbers[i]) : body.name;
        properties.massCache = mass;
        QByteArray encoded;
        if (!encodeKompasBodyProperties(properties, encoded, error)) return false;
        bodyPropertyBytes.push_back(std::move(encoded));
    }

    // The standard property set of a KOMPAS 17.1 part (NativeKompasService.hpp): the
    // ids MetaInfo's values refer to (5 the name, 9 the material, 14 the object type...).
    const KompasPropertyDefinitions definitions = kompasStandardPropertyDefinitions();
    const KompasPropertyTuning tuning = kompasStandardPropertyTuning();
    if (!validateKompasPropertyReferences(definitions, tuning, error)) return false;
    QByteArray definitionBytes, tuningBytes;
    if (!encodeKompasPropertyDefinitions(definitions, definitionBytes, error) ||
        !encodeKompasPropertyTuning(tuning, tuningBytes, error)) return false;

    KompasDocumentSettings settings;
    settings.title = options.title;
    settings.assembly = false; // Several bodies still belong to one part.
    settings.styles.reserve(KompasDocumentSettings::styleCount);
    for (std::size_t i = 0; i < KompasDocumentSettings::styleCount; ++i) {
        KompasDocumentStyle style;
        style.name = QStringLiteral("CADNext style %1").arg(i);
        style.color = options.color;
        style.material = options.material;
        settings.styles.push_back(std::move(style));
    }
    QByteArray settingsBytes;
    if (!encodeKompasDocumentSettings(settings, settingsBytes, error)) return false;

    // Records whose content does not depend on the model (NativeKompasService.hpp).
    QByteArray versionBytes, set100Bytes, set500Bytes, set700Bytes, model180Bytes, model210Bytes,
        document205Bytes, document230Bytes, document260Bytes, document280Bytes, document290Bytes,
        passwordBytes, layerBytes;
    const auto service = [&](KompasServiceRecord kind, QByteArray& bytes) {
        return encodeKompasServiceRecord(kind, 0x11001011, bytes, error);
    };
    if (!service(KompasServiceRecord::ApplicationVersion, versionBytes) ||
        !service(KompasServiceRecord::ModelSet100, set100Bytes) ||
        !service(KompasServiceRecord::ModelSet500, set500Bytes) ||
        !service(KompasServiceRecord::ModelSet700, set700Bytes) ||
        !service(KompasServiceRecord::Model180, model180Bytes) ||
        !service(KompasServiceRecord::Model210, model210Bytes) ||
        !service(KompasServiceRecord::Document205, document205Bytes) ||
        !service(KompasServiceRecord::Document230, document230Bytes) ||
        !service(KompasServiceRecord::Document260, document260Bytes) ||
        !service(KompasServiceRecord::Document280, document280Bytes) ||
        !service(KompasServiceRecord::Document290, document290Bytes) ||
        !service(KompasServiceRecord::Passwords, passwordBytes) ||
        !encodeKompasLayers({KompasLayer{}}, layerBytes, error)) return false;
    QByteArray document114Bytes, model109Bytes, viewBytes, userSettingBytes, dateBytes, authorBytes;
    if (!service(KompasServiceRecord::Document114, document114Bytes) || !service(KompasServiceRecord::Model109, model109Bytes) ||
        !service(KompasServiceRecord::View, viewBytes) || !service(KompasServiceRecord::UserSettings, userSettingBytes)) return false;
    {
        // Created and modified now, as the FileInfo member says.
        const QDateTime now = QDateTime::currentDateTime();
        if (!encodeKompasDocumentDates({now, now}, dateBytes, error)) return false;
        if (options.author && !encodeKompasDocumentAuthors({{*options.author, options.organization}}, authorBytes, error)) return false;
    }
    // Each body's display mesh, triangulated with KOMPAS's step for the whole model's box.
    std::vector<QByteArray> meshBytes;
    std::vector<KompasMesh> meshes;
    {
        const double diagonal = std::sqrt((bounds[3] - bounds[0]) * (bounds[3] - bounds[0]) + (bounds[4] - bounds[1]) * (bounds[4] - bounds[1]) +
                                          (bounds[5] - bounds[2]) * (bounds[5] - bounds[2]));
        const auto step = kompasMeshStep(diagonal);
        for (std::size_t i = 0; i < placedBodies.size(); ++i) {
            KompasMesh mesh;
            QByteArray encoded;
            if (!kompasBodyMesh(kernel, placedBodies[i], 1003 + quint32(i), step, options.color, options.material, mesh, error) ||
                !encodeKompasMesh(mesh, encoded, error)) return false;
            meshBytes.push_back(std::move(encoded));
            meshes.push_back(std::move(mesh));
        }
    }
    // KOMPAS 17.1's default text styles.
    QByteArray textStyleBytes;
    if (!encodeKompasTextStyles(kompasDefaultTextStyles(), textStyleBytes, error)) return false;
    // The four standard representations, keyed by the clock as KOMPAS keys them; and the designation.
    QByteArray representationBytes, designationBytes;
    if (!encodeKompasRepresentations(kompasStandardRepresentations(double(QDateTime::currentMSecsSinceEpoch())), representationBytes, error) ||
        !encodeKompasDesignationRecord(options.designation.value_or(QString()), designationBytes, error)) return false;
    // The model's counters: #110 names the first body's shell, #201 the last object id; #202 a further
    // counter whose meaning the samples do not show — the next free id, so that it names nothing of ours.
    // KOMPAS keeps the next free object id where it says "last" (the catalog's, #201): in every sample it is
    // one past the largest id defined.
    KompasModelCounters counters;
    counters.firstBodyShell = operations.front().shellId;
    counters.lastObjectId = lastObjectId + 1;
    counters.layoutCounter = lastObjectId + 1;
    KompasModelCounterRecords counterBytes;
    if (!encodeKompasModelCounters(counters, counterBytes, error)) return false;

    // The catalog in the order KOMPAS 17.1 writes its parts (the same in all 21
    // of the samples); every record has one owner, and the physical records
    // follow the catalog's order.
    std::vector<QByteArray> pool;
    const auto stream = [&](std::optional<quint16> numericName, const QString& textName, QByteArray bytes) {
        KompasCatalogEntry entry;
        entry.numericName = numericName;
        entry.textName = textName;
        entry.recordIndex = pool.size();
        pool.push_back(std::move(bytes));
        return entry;
    };
    const auto numeric = [&](quint16 name, QByteArray bytes) { return stream(name, {}, std::move(bytes)); };
    const auto text = [&](const QString& name, QByteArray bytes) { return stream(std::nullopt, name, std::move(bytes)); };
    const auto directory = [](std::optional<quint16> numericName, const QString& textName,
                              std::vector<KompasCatalogEntry> children) {
        KompasCatalogEntry entry;
        entry.directory = true;
        entry.numericName = numericName;
        entry.textName = textName;
        entry.children = std::move(children);
        return entry;
    };
    std::vector<KompasCatalogEntry> bodyEntries, bodyPropertyEntries, linkEntries, meshEntries;
    for (std::size_t i = 0; i < operations.size(); ++i) {
        const QString number = QString::number(operations[i].bodyNumber);
        bodyEntries.push_back(text(number, operations[i].body));
        bodyPropertyEntries.push_back(text(number, bodyPropertyBytes[i]));
        linkEntries.push_back(text(number, operations[i].applicationLink));
        meshEntries.push_back(directory(std::nullopt, number, {text(QStringLiteral("Triangle"), std::move(meshBytes[i]))}));
    }
    KompasCatalog catalog;
    catalog.lastObjectId = lastObjectId + 1; // the next free id, as KOMPAS keeps it
    catalog.entries.push_back(numeric(114, std::move(document114Bytes)));
    catalog.entries.push_back(numeric(113, std::move(versionBytes)));
    {
        std::vector<KompasCatalogEntry> info{text(QStringLiteral("_DI_D"), std::move(dateBytes))};
        if (!authorBytes.isEmpty()) info.push_back(text(QStringLiteral("_DI_C"), std::move(authorBytes)));
        info.push_back(directory(std::nullopt, QStringLiteral("_SA_DN"), {text(QStringLiteral("_RR_FN"), std::move(representationBytes))}));
        info.push_back(directory(std::nullopt, QStringLiteral("_PW_DN"), {text(QStringLiteral("_PW_FN"), std::move(passwordBytes))}));
        catalog.entries.push_back(directory(std::nullopt, QStringLiteral("_KD_I"), std::move(info)));
    }
    catalog.entries.push_back(directory(std::nullopt, QStringLiteral("_DUS_D"), {text(QStringLiteral("_DUS_F"), std::move(userSettingBytes))}));
    catalog.entries.push_back(numeric(100, std::move(settingsBytes)));
    catalog.entries.push_back(numeric(250, std::move(textStyleBytes)));
    catalog.entries.push_back(numeric(260, std::move(document260Bytes)));
    catalog.entries.push_back(numeric(140, std::move(viewBytes)));
    catalog.entries.push_back(numeric(270, std::move(layerBytes)));
    catalog.entries.push_back(numeric(204, std::move(designationBytes)));
    catalog.entries.push_back(directory(170, {}, {
        directory(155, {}, {numeric(100, std::move(set100Bytes)), numeric(500, std::move(set500Bytes)),
                            numeric(700, std::move(set700Bytes))}),
        directory(240, {}, {numeric(100, std::move(massBytes))}),
        numeric(109, std::move(model109Bytes)),
        text(QStringLiteral("LayoutInstances"), std::move(counterBytes.layoutInstances)),
        numeric(130, std::move(modelRecord)),
        numeric(180, std::move(model180Bytes)),
        numeric(210, std::move(model210Bytes)),
        numeric(110, std::move(counterBytes.firstBodyShell)),
        directory(300, {}, std::move(bodyEntries)),
        directory(301, {}, std::move(bodyPropertyEntries)),
        directory(302, {}, std::move(linkEntries)),
        directory(157, {}, {directory(303, {}, std::move(meshEntries))}),
        directory(200, {}, {numeric(201, std::move(counterBytes.lastObjectId))}),
        numeric(202, std::move(counterBytes.layout)),
        numeric(100, std::move(modelPropertyBytes))}));
    catalog.entries.push_back(directory(230, {}, {numeric(230, std::move(document230Bytes))}));
    catalog.entries.push_back(directory(std::nullopt, QStringLiteral("_ADDPROP_D"),
        {text(QStringLiteral("_ADDPROP_F"), std::move(definitionBytes))}));
    catalog.entries.push_back(directory(std::nullopt, QStringLiteral("_ADDPROP_TUNING_D"),
        {text(QStringLiteral("_ADDPROP_TUNING_F"), std::move(tuningBytes))}));
    catalog.entries.push_back(numeric(205, std::move(document205Bytes)));
    catalog.entries.push_back(numeric(280, std::move(document280Bytes)));
    catalog.entries.push_back(numeric(290, std::move(document290Bytes)));
    std::vector<quint32> linkedBodies;
    for (const auto& operation : operations) linkedBodies.push_back(operation.bodyNumber);
    QByteArray metaLinkBytes;
    if (!encodeKompasMetaInfoLinks(linkedBodies, metaLinkBytes, error)) return false;
    catalog.entries.push_back(text(QStringLiteral("MetoInfoLinks"), std::move(metaLinkBytes)));
    std::vector<QByteArray> records;
    records.reserve(pool.size());
    const std::function<void(KompasCatalogEntry&)> place = [&](KompasCatalogEntry& entry) {
        if (!entry.directory) {
            records.push_back(std::move(pool[entry.recordIndex]));
            entry.recordIndex = records.size() - 1;
        }
        for (auto& child : entry.children) place(child);
    };
    for (auto& entry : catalog.entries) place(entry);
    if (records.size() != pool.size()) {
        error = QObject::tr("Каталог документа КОМПАС не владеет всеми записями.");
        return false;
    }
    KompasStoragePrefix prefix;
    if (!prepareKompasStorageRecords(records, prefix, error)) return false;
    QByteArray catalogBytes;
    if (!encodeKompasCatalog(catalog, prefix, catalogBytes, error)) return false;
    KompasStorageImage image;
    if (!finishKompasStorage(prefix, catalogBytes, image, error)) return false;

    // MetaInfo as KOMPAS 17.1 writes it: the standard descriptions, the document's
    // values, its embodiment and one component per body, in the order of the
    // /MetoInfoLinks above. The mass is not calculated (the mass caches are
    // deferred), which KOMPAS writes as 0.
    KompasMetaInfo meta;
    meta.designation = options.designation;
    meta.name = options.title;
    meta.material = options.materialName;
    meta.author = options.author;
    meta.organization = options.organization;
    for (std::size_t i = 0; i < bodies.size(); ++i)
        meta.bodies.push_back({bodies[i].name.isEmpty() ? QStringLiteral("Body %1").arg(bodyNumbers[i]) : bodies[i].name, 0.0,
                               options.materialName});
    QByteArray metaInfo;
    if (!encodeKompasMetaInfo(meta, metaInfo, error)) return false;
    KompasFileInfo fileInfo;
    fileInfo.createdAt = QDateTime::currentDateTime().toString(QStringLiteral("M/d/yyyy H:mm:ss"));
    fileInfo.modifiedAt = fileInfo.createdAt;
    QByteArray fileInfoBytes;
    if (!encodeKompasFileInfo(fileInfo, fileInfoBytes, error)) return false;
    // The preview: the meshes in the default view, signed as KOMPAS signs it.
    KompasPreview preview;
    preview.image = renderKompasPreview(meshes, options.color);
    preview.designation = options.designation.value_or(QString());
    preview.name = options.title;
    preview.author = options.author.value_or(QString());
    QByteArray previewBytes;
    if (!encodeKompasPreview(preview, previewBytes, error)) return false;
    const std::vector<KompasStorageArchiveMember> extras{
        {QByteArrayLiteral("FileInfo"), std::move(fileInfoBytes)},
        {QByteArrayLiteral("Preview"), std::move(previewBytes)},
        {QByteArrayLiteral("MetaInfo"), std::move(metaInfo)}};
    return writeKompasStorageArchive(path, image, extras, error);
}

} // namespace cadnext::gui
