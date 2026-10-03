#pragma once

#include "cadnext/kernel/ExactBRepDescription.hpp"

#include <Geom_BSplineSurface.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <gp.hxx>

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace cadnext::gui::detail {

struct KompasSplineSurface {
    Handle(Geom_BSplineSurface) support;
    kernel::BSplineSurfaceDefinition grid;
    std::vector<double> uKnots, vKnots;
    bool closedU = false, closedV = false;
};

// ExactBRepDescription continues a periodic spline's knots and poles on both
// sides of one period. Recover the periodic grid before evaluating UV curves
// that can cross its seam. No closedness tolerance or spline fitting is used.
inline void restoreKompasSplinePeriod(kernel::BSplineSurfaceDefinition& b, int direction) {
    auto& knots = direction == 0 ? b.uKnots : b.vKnots;
    auto& mults = direction == 0 ? b.uMultiplicities : b.vMultiplicities;
    auto& periodic = direction == 0 ? b.uPeriodic : b.vPeriodic;
    if (periodic) return;
    const int n = direction == 0 ? b.uPoleCount : b.vPoleCount;
    const int degree = direction == 0 ? b.uDegree : b.vDegree;
    std::vector<double> flat;
    for (std::size_t i = 0; i < knots.size(); ++i)
        for (int j = 0; j < mults.at(i); ++j) flat.push_back(knots[i]);
    if (degree < 1 || n <= degree || flat.size() != std::size_t(n + degree + 1))
        throw std::runtime_error("Invalid unwrapped C3D periodic spline");
    const double low = flat.at(std::size_t(degree)), high = flat.at(std::size_t(n));
    const double period = high - low;
    std::vector<double> keptKnots;
    std::vector<int> keptMults;
    for (std::size_t i = 0; i < knots.size(); ++i)
        if (knots[i] >= low && knots[i] <= high) {
            keptKnots.push_back(knots[i]); keptMults.push_back(mults.at(i));
        }
    if (!(period > 0) || keptKnots.size() < 2 || keptKnots.front() != low || keptKnots.back() != high ||
        keptMults.front() != keptMults.back() || keptMults.front() > degree)
        throw std::runtime_error("Invalid C3D spline period knots");
    int kept = 0;
    for (std::size_t i = 0; i + 1 < keptMults.size(); ++i) kept += keptMults[i];
    if (n - kept != degree + 1 - keptMults.front() || kept < 2)
        throw std::runtime_error("Invalid C3D spline period pole count");
    for (std::size_t i = 0; i + std::size_t(kept) < flat.size(); ++i) {
        const double size = std::max({1.0, std::fabs(flat[i]), std::fabs(flat[i + kept]), period});
        if (std::fabs(flat[i + kept] - flat[i] - period) > 32 * std::numeric_limits<double>::epsilon() * size)
            throw std::runtime_error("C3D spline knots do not repeat with their period");
    }
    const auto at = [&](int u, int v) { return std::size_t(u * b.vPoleCount + v); };
    for (int i = 0; i < n - kept; ++i)
        for (int other = 0; other < (direction == 0 ? b.vPoleCount : b.uPoleCount); ++other) {
            const auto a = direction == 0 ? at(kept + i, other) : at(other, kept + i);
            const auto c = direction == 0 ? at(i, other) : at(other, i);
            const auto& p = b.poles.at(a); const auto& q = b.poles.at(c);
            if (p.x != q.x || p.y != q.y || p.z != q.z || b.weights.at(a) != b.weights.at(c))
                throw std::runtime_error("C3D periodic spline has different repeated poles or weights");
        }
    std::vector<Vector3> poles;
    std::vector<double> weights;
    for (int u = 0; u < b.uPoleCount; ++u)
        for (int v = 0; v < b.vPoleCount; ++v)
            if ((direction == 0 ? u : v) < kept) {
                poles.push_back(b.poles.at(at(u, v))); weights.push_back(b.weights.at(at(u, v)));
            }
    b.poles = std::move(poles); b.weights = std::move(weights);
    (direction == 0 ? b.uPoleCount : b.vPoleCount) = kept;
    knots = std::move(keptKnots); mults = std::move(keptMults); periodic = true;
}

inline KompasSplineSurface prepareKompasSplineSurface(const kernel::DescribedSurface& source) {
    auto b = source.bspline;
    if (source.uPeriodic) restoreKompasSplinePeriod(b, 0);
    if (source.vPeriodic) restoreKompasSplinePeriod(b, 1);
    TColgp_Array2OfPnt poles(1, b.uPoleCount, 1, b.vPoleCount);
    TColStd_Array2OfReal weights(1, b.uPoleCount, 1, b.vPoleCount);
    TColStd_Array1OfReal uk(1, int(b.uKnots.size())), vk(1, int(b.vKnots.size()));
    TColStd_Array1OfInteger um(1, int(b.uMultiplicities.size())), vm(1, int(b.vMultiplicities.size()));
    for (int u = 1; u <= b.uPoleCount; ++u) for (int v = 1; v <= b.vPoleCount; ++v) {
        const auto i = std::size_t((u - 1) * b.vPoleCount + v - 1); const auto& p = b.poles.at(i);
        poles.SetValue(u, v, {p.x, p.y, p.z}); weights.SetValue(u, v, b.weights.at(i));
    }
    for (int i = 1; i <= uk.Length(); ++i) { uk.SetValue(i,b.uKnots.at(i-1)); um.SetValue(i,b.uMultiplicities.at(i-1)); }
    for (int i = 1; i <= vk.Length(); ++i) { vk.SetValue(i,b.vKnots.at(i-1)); vm.SetValue(i,b.vMultiplicities.at(i-1)); }
    KompasSplineSurface result;
    result.support = new Geom_BSplineSurface(poles,weights,uk,vk,um,vm,b.uDegree,b.vDegree,b.uPeriodic,b.vPeriodic);
    result.closedU = b.uPeriodic; result.closedV = b.vPeriodic;
    const Handle(Geom_BSplineSurface) native = Handle(Geom_BSplineSurface)::DownCast(result.support->Copy());
    // C3D's closed grid meets at its first pole. Raising the seam's knot
    // multiplicity to the degree is exact knot insertion, including rational
    // surfaces; it permits the duplicate endpoint and clamped end knots below.
    if (result.closedU) native->InsertUKnot(native->UKnot(1), b.uDegree, gp::Resolution(), false);
    if (result.closedV) native->InsertVKnot(native->VKnot(1), b.vDegree, gp::Resolution(), false);
    auto& grid = result.grid;
    grid.uDegree = native->UDegree(); grid.vDegree = native->VDegree();
    grid.uPoleCount = native->NbUPoles() + int(result.closedU);
    grid.vPoleCount = native->NbVPoles() + int(result.closedV);
    for (int u = 0; u < grid.uPoleCount; ++u) for (int v = 0; v < grid.vPoleCount; ++v) {
        const auto p = native->Pole(1 + u % native->NbUPoles(), 1 + v % native->NbVPoles());
        grid.poles.push_back({p.X(),p.Y(),p.Z()});
        grid.weights.push_back(native->Weight(1 + u % native->NbUPoles(), 1 + v % native->NbVPoles()));
    }
    for (int direction = 0; direction < 2; ++direction) {
        const bool closed = direction == 0 ? result.closedU : result.closedV;
        const int count = direction == 0 ? native->NbUKnots() : native->NbVKnots();
        const int degree = direction == 0 ? grid.uDegree : grid.vDegree;
        auto& values = direction == 0 ? grid.uKnots : grid.vKnots;
        auto& mults = direction == 0 ? grid.uMultiplicities : grid.vMultiplicities;
        auto& flat = direction == 0 ? result.uKnots : result.vKnots;
        for (int i = 1; i <= count; ++i) {
            const double value = direction == 0 ? native->UKnot(i) : native->VKnot(i);
            const int m = closed && (i == 1 || i == count) ? degree + 1 :
                direction == 0 ? native->UMultiplicity(i) : native->VMultiplicity(i);
            values.push_back(value); mults.push_back(m);
            for (int j = 0; j < m; ++j) flat.push_back(value);
        }
        if (closed) {
            const double period = values.back() - values.front();
            int added = 0;
            for (std::size_t i = 1; i < values.size() && added < degree; ++i)
                for (int j = 0; j < mults[i] && added < degree; ++j, ++added) flat.push_back(values[i] + period);
            if (added != degree) throw std::runtime_error("Incomplete C3D periodic spline knot continuation");
        }
    }
    return result;
}

} // namespace cadnext::gui::detail
