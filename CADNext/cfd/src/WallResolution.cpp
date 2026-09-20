#include "cadnext/cfd/WallResolution.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>

namespace cadnext::cfd {

namespace {

double quantile(const std::vector<double>& sorted, double fraction) {
    if (sorted.empty()) return 0.0;
    const auto index = static_cast<std::size_t>(fraction * static_cast<double>(sorted.size() - 1) + 0.5);
    return sorted[std::min(index, sorted.size() - 1)];
}

std::string round2(double value) {
    std::ostringstream text;
    text.precision(value < 10 ? 2 : 0);
    text << std::fixed << value;
    return text.str();
}

} // namespace

bool parseWallTreatment(const std::string& name, WallTreatment& out) {
    if (name == "resolved") { out = WallTreatment::Resolved; return true; }
    if (name == "functions") { out = WallTreatment::Functions; return true; }
    return false;
}

std::string wallTreatmentName(WallTreatment treatment) { return treatment == WallTreatment::Resolved ? "resolved" : "functions"; }

double reynoldsNumber(double speedMps, double lengthM, double densityKgM3, double viscosityPaS) {
    if (!(viscosityPaS > 0.0)) return 0.0;
    return densityKgM3 * speedMps * lengthM / viscosityPaS;
}

double flatPlateSkinFriction(double reynolds) {
    if (!(reynolds > 0.0)) return 0.0;
    return 0.026 * std::pow(reynolds, -1.0 / 7.0);
}

double boundaryLayerThicknessM(double reynolds, double lengthM) {
    if (!(reynolds > 0.0) || !(lengthM > 0.0)) return 0.0;
    return 0.37 * lengthM * std::pow(reynolds, -0.2);
}

double laminarBoundaryLayerThicknessM(double reynolds, double lengthM) {
    if (!(reynolds > 0.0) || !(lengthM > 0.0)) return 0.0;
    return 5.0 * lengthM / std::sqrt(reynolds);
}

double heightForYPlus(double yPlus, double speedMps, double lengthM, double densityKgM3, double viscosityPaS) {
    const double reynolds = reynoldsNumber(speedMps, lengthM, densityKgM3, viscosityPaS);
    const double friction = flatPlateSkinFriction(reynolds);
    if (!(friction > 0.0) || !(densityKgM3 > 0.0)) return 0.0;
    const double frictionVelocity = speedMps * std::sqrt(friction / 2.0);
    if (!(frictionVelocity > 0.0)) return 0.0;
    return yPlus * viscosityPaS / (densityKgM3 * frictionVelocity);
}

double yPlusForHeight(double heightM, double speedMps, double lengthM, double densityKgM3, double viscosityPaS) {
    const double unit = heightForYPlus(1.0, speedMps, lengthM, densityKgM3, viscosityPaS);
    return unit > 0.0 ? heightM / unit : 0.0;
}

WallLayerPlan planWallLayers(WallTreatment treatment, double speedMps, double lengthM, double densityKgM3, double viscosityPaS) {
    WallLayerPlan plan;
    plan.reynolds = reynoldsNumber(speedMps, lengthM, densityKgM3, viscosityPaS);
    plan.skinFriction = flatPlateSkinFriction(plan.reynolds);
    plan.frictionVelocityMps = speedMps * std::sqrt(plan.skinFriction / 2.0);
    plan.boundaryLayerM = boundaryLayerThicknessM(plan.reynolds, lengthM);
    plan.growth = treatment == WallTreatment::Resolved ? 1.2 : 1.3;
    plan.firstHeightM = heightForYPlus(treatment == WallTreatment::Resolved ? 1.0 : 50.0, speedMps, lengthM, densityKgM3, viscosityPaS);
    if (!(plan.firstHeightM > 0.0) || !(plan.boundaryLayerM > 0.0)) return plan;
    double height = plan.firstHeightM;
    while (plan.totalHeightM < plan.boundaryLayerM && plan.heightsM.size() < 60) {
        plan.heightsM.push_back(height);
        plan.totalHeightM += height;
        height *= plan.growth;
    }
    return plan;
}

WallResolution assessWallResolution(const Su2History& surface, WallTreatment treatment) {
    WallResolution out;
    const int column = surface.column("Y_Plus");
    if (column < 0) {
        out.problem = "SU2 не выдал y+ на стенке: пристеночное разрешение не проверено";
        return out;
    }
    std::vector<double> values;
    values.reserve(surface.rows.size());
    for (const auto& row : surface.rows) {
        if (row.size() <= static_cast<std::size_t>(column) || !std::isfinite(row[column])) continue;
        values.push_back(row[column]);
    }
    if (values.empty()) {
        out.problem = "в поверхностном поле нет значений y+";
        return out;
    }
    std::sort(values.begin(), values.end());
    const double count = static_cast<double>(values.size());
    out.measured = true;
    out.nodes = static_cast<int>(values.size());
    out.minimum = values.front();
    out.maximum = values.back();
    out.median = quantile(values, 0.5);
    out.p95 = quantile(values, 0.95);
    auto share = [&](double low, double high) {
        return static_cast<double>(std::count_if(values.begin(), values.end(), [&](double v) { return v >= low && v < high; })) / count;
    };
    out.shareBelow1 = share(0.0, 1.0);
    out.shareBuffer = share(5.0, 30.0);
    out.shareLog = share(30.0, 300.0);
    out.shareAbove300 = share(300.0, INFINITY);

    if (treatment == WallTreatment::Resolved) {
        out.badShare = share(2.0, INFINITY);
        out.valid = out.badShare <= 0.05;
        if (!out.valid) {
            out.problem = "пограничный слой не разрешён: y+ выше 2 у " + round2(100.0 * out.badShare) + " % узлов стенки (медиана " + round2(out.median)
                          + "); нужен первый слой под y+ ≈ 1 или режим пристеночных функций";
        }
    } else {
        out.badShare = out.shareBuffer + out.shareAbove300;
        out.valid = out.badShare <= 0.10;
        if (!out.valid) {
            out.problem = "пристеночные функции неприменимы: " + round2(100.0 * out.shareBuffer) + " % узлов в буферном слое 5 < y+ < 30 и "
                          + round2(100.0 * out.shareAbove300) + " % выше y+ = 300 (медиана " + round2(out.median)
                          + "); нужен первый слой в диапазоне y+ 30…300 или разрешение слоя";
        }
    }
    return out;
}

} // namespace cadnext::cfd
