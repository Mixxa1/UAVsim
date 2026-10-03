#pragma once

#include "NativeKompasNurbsCurve.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <utility>
#include <vector>

namespace cadnext::gui::detail {

struct KompasUvCurve {
    enum Kind { Line, Arc, Hermite, Contour, Nurbs } kind = Line;
    std::size_t key = 0;
    std::vector<std::array<double, 2>> poles;
    std::array<double, 2> center{}, x{}, y{};
    double a = 0, b = 0, first = 0, last = 0;
    std::vector<KompasUvCurve> pieces;
    KompasNurbs2 nurbs;
};

inline std::array<double, 2> kompasUvPoint(const KompasUvCurve& c, double t) {
    if(c.kind==KompasUvCurve::Nurbs)return pointOnKompasNurbs2(c.nurbs,t);
    if (!c.pieces.empty()) {
        double at = 0;
        for (std::size_t i = 0; i < c.pieces.size(); ++i) {
            const auto& piece = c.pieces[i];
            const double end = c.kind == KompasUvCurve::Contour ? at + piece.last - piece.first : piece.last;
            if (t <= end || i + 1 == c.pieces.size())
                return kompasUvPoint(piece, c.kind == KompasUvCurve::Contour ? piece.first + t - at : t);
            at = end;
        }
    }
    std::array<double, 2> p{};
    if (c.kind == KompasUvCurve::Arc) {
        for (int k = 0; k < 2; ++k)
            p[k] = c.center[k] + c.a * c.x[k] * std::cos(t) + c.b * c.y[k] * std::sin(t);
        return p;
    }
    const double f = (t - c.first) / (c.last - c.first);
    for (int k = 0; k < 2; ++k) {
        if (c.kind == KompasUvCurve::Line) p[k] = (1 - f) * c.poles.at(0)[k] + f * c.poles.at(1)[k];
        else p[k] = (1-f)*(1-f)*(1-f)*c.poles.at(0)[k] + 3*(1-f)*(1-f)*f*c.poles.at(1)[k] +
                    3*(1-f)*f*f*c.poles.at(2)[k] + f*f*f*c.poles.at(3)[k];
    }
    return p;
}

inline std::array<double, 2> kompasUvDerivative(const KompasUvCurve& c, double t) {
    if(c.kind==KompasUvCurve::Nurbs)return derivativeOnKompasNurbs2(c.nurbs,t);
    if(!c.pieces.empty()) {
        double at=0;
        for(std::size_t i=0;i<c.pieces.size();++i) {
            const auto& piece=c.pieces[i];
            const double end=c.kind==KompasUvCurve::Contour ? at+piece.last-piece.first : piece.last;
            if(t<=end || i+1==c.pieces.size())
                return kompasUvDerivative(piece,c.kind==KompasUvCurve::Contour ? piece.first+t-at : t);
            at=end;
        }
    }
    std::array<double, 2> d{};
    const double span = c.last - c.first;
    const double f = (t - c.first) / span;
    for (int k = 0; k < 2; ++k) {
        if (c.kind == KompasUvCurve::Arc)
            d[k] = -c.a * c.x[k] * std::sin(t) + c.b * c.y[k] * std::cos(t);
        else if (c.kind == KompasUvCurve::Line)
            d[k] = (c.poles.at(1)[k] - c.poles.at(0)[k]) / span;
        else d[k] = 3 * ((1-f)*(1-f)*(c.poles.at(1)[k]-c.poles.at(0)[k]) +
                        2*(1-f)*f*(c.poles.at(2)[k]-c.poles.at(1)[k]) +
                        f*f*(c.poles.at(3)[k]-c.poles.at(2)[k])) / span;
    }
    return d;
}

// One native Hermite object stores only one tangent at each internal point.
// A tolerance-based join would replace the next polynomial's start tangent,
// so retain separate contour segments unless both stored tangents are equal.
inline bool canJoinKompasUvHermitePieces(const std::vector<KompasUvCurve>& pieces) {
    if (pieces.empty()) return false;
    for (const auto& piece : pieces)
        if (piece.kind != KompasUvCurve::Hermite || !piece.pieces.empty() ||
            piece.poles.size() != 4 || !(piece.last > piece.first)) return false;
    for (std::size_t i = 1; i < pieces.size(); ++i) {
        const auto& a = pieces[i-1];
        const auto& b = pieces[i];
        if (a.last != b.first || a.poles.back() != b.poles.front() ||
            kompasUvDerivative(a,a.last) != kompasUvDerivative(b,b.first)) return false;
    }
    return true;
}

// Reparameterize the entire spline boundary to [0,last]. A contour's piece
// domains are local; a multi-span Hermite object's domains are absolute.
// Native arcs use their angle and lines use their length, so neither supports
// this conversion through merely changing the serialized interval.
inline void normalizeKompasUvPolynomial(KompasUvCurve& c, double last=1, double targetFirst=0) {
    using C = KompasUvCurve;
    const double first=c.first, span=c.last-first;
    const auto polynomial=[](const C& p) {return p.kind==C::Hermite || p.kind==C::Contour || p.kind==C::Nurbs;};
    if (!polynomial(c) || !(span>0) || !std::isfinite(span) || !std::isfinite(first) ||
        !std::isfinite(targetFirst) || !(last>targetFirst) || !std::isfinite(last) ||
        (c.kind==C::Contour && targetFirst!=0))
        throw std::runtime_error("Unsupported C3D UV parameter normalization");
    const double targetSpan=last-targetFirst;
    if (!std::isfinite(targetSpan))
        throw std::runtime_error("Invalid C3D UV target parameter span");
    for (const auto& piece:c.pieces)
        if ((piece.kind!=C::Hermite && piece.kind!=C::Nurbs) || !piece.pieces.empty())
            throw std::runtime_error("Unsupported C3D UV segment normalization");
    for (auto& piece:c.pieces) {
        const double origin=c.kind==C::Contour ? 0 : first;
        if(piece.kind==C::Nurbs)
            for(auto& knot:piece.nurbs.knots)knot=targetFirst+(knot-origin)/span*targetSpan;
        piece.first=targetFirst+(piece.first-origin)/span*targetSpan;
        piece.last=targetFirst+(piece.last-origin)/span*targetSpan;
    }
    if(c.kind==C::Nurbs)
        for(auto& knot:c.nurbs.knots)knot=targetFirst+(knot-first)/span*targetSpan;
    c.first=targetFirst; c.last=last;
}

// An arc placed in a contour retains its angular law. The contour translates
// its zero-based parameter into the segment's original angular interval.
inline void contourizeKompasUvArc(KompasUvCurve& c, std::size_t& nextKey) {
    if(c.kind!=KompasUvCurve::Arc || !(c.last>c.first))
        throw std::runtime_error("Invalid C3D arc contour");
    KompasUvCurve contour;
    contour.kind=KompasUvCurve::Contour;
    contour.key=nextKey++;
    contour.last=c.last-c.first;
    contour.pieces.push_back(std::move(c));
    c=std::move(contour);
}

// C3D requires two contour-valued curves of an intersection to have the same
// segment partition. Split at the union of their breakpoints. Restricting a
// cubic by its exact endpoint values and derivatives, or a NURBS by rational
// knot insertion, preserves its law; conics retain their angular parameter.
// https://c3d.ascon.net/doc/math/class_mb_surface_intersection_curve.html
inline void harmonizeKompasUvContours(KompasUvCurve& a, KompasUvCurve& b, std::size_t& nextKey) {
    using C = KompasUvCurve;
    if (a.kind != C::Contour || b.kind != C::Contour) return;
    if (a.first != 0 || b.first != 0 || a.last != b.last || !(a.last > 0) || !std::isfinite(a.last))
        throw std::runtime_error("C3D contours have different parameter domains");
    std::vector<double> breaks{0, a.last};
    const auto collect = [&](const C& c) {
        if (c.pieces.empty() || c.pieces.size() > 8192)
            throw std::runtime_error("Empty or oversized C3D UV contour");
        double at = 0;
        for (const auto& p : c.pieces) {
            if (!p.pieces.empty() || p.kind == C::Contour || !(p.last > p.first) ||
                !std::isfinite(p.first) || !std::isfinite(p.last))
                throw std::runtime_error("Invalid C3D contour segment");
            if (p.kind == C::Line && std::fabs(std::hypot(p.poles.at(1)[0]-p.poles.at(0)[0],
                                                        p.poles.at(1)[1]-p.poles.at(0)[1]) -
                                            (p.last-p.first)) > 1e-12 * std::max(1.0, p.last-p.first))
                throw std::runtime_error("C3D line segment has a different native parameter length");
            at += p.last - p.first;
            if (at < c.last) breaks.push_back(at);
        }
        if (std::fabs(at - c.last) > 1e-12 * std::max(1.0, c.last))
            throw std::runtime_error("C3D contour length differs from its segments");
    };
    collect(a); collect(b);
    std::sort(breaks.begin(), breaks.end());
    breaks.erase(std::unique(breaks.begin(), breaks.end()), breaks.end());
    if (breaks.size() > 8193) throw std::runtime_error("C3D paired contours exceed 8192 segments");
    const auto split = [&](C& c) {
        std::vector<C> pieces;
        double at = 0;
        std::size_t i = 0;
        for (std::size_t j = 1; j < breaks.size(); ++j) {
            const double first = breaks[j-1], last = breaks[j];
            while (i + 1 < c.pieces.size() && first >= at + c.pieces[i].last - c.pieces[i].first) {
                at += c.pieces[i].last - c.pieces[i].first;
                ++i;
            }
            const auto& source = c.pieces[i];
            const double lo = source.first + first - at;
            const double hi = source.first + last - at;
            if (!(hi > lo)) throw std::runtime_error("C3D contour split loses parameter precision");
            C piece = source;
            piece.key = nextKey++;
            piece.first = lo; piece.last = hi;
            if(source.kind==C::Nurbs) {
                piece.nurbs=restrictKompasNurbs2(source.nurbs,lo,hi);
                for(auto& knot:piece.nurbs.knots)knot-=lo;
                piece.poles=piece.nurbs.poles;
                piece.first=0;piece.last=last-first;
            } else if (source.kind != C::Arc) {
                const auto p0 = kompasUvPoint(source, lo), p1 = kompasUvPoint(source, hi);
                if (source.kind == C::Line) piece.poles = {p0, p1};
                else {
                    const auto d0 = kompasUvDerivative(source, lo), d1 = kompasUvDerivative(source, hi);
                    piece.poles = {p0, {}, {}, p1};
                    for (int k = 0; k < 2; ++k) {
                        piece.poles[1][k] = p0[k] + (hi-lo)*d0[k]/3;
                        piece.poles[2][k] = p1[k] - (hi-lo)*d1[k]/3;
                    }
                }
                // Contour parameters are cumulative segment lengths. Giving
                // both polynomial segments the same local domain prevents
                // subtraction of their different origins from changing it.
                piece.first = 0; piece.last = last - first;
            }
            pieces.push_back(std::move(piece));
        }
        c.pieces = std::move(pieces);
    };
    split(a); split(b);
}

} // namespace cadnext::gui::detail
