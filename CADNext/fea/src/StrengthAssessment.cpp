#include "cadnext/fea/StrengthAssessment.hpp"

#include <algorithm>
#include <limits>

namespace cadnext::fea {

namespace {

struct Margins {
    std::optional<double> yield;
    double ultimate = 0.0;
    double governing = 0.0;
};

Margins marginsAt(const IsotropicMaterial& material, double stress, double factorOfSafety) {
    Margins m;
    if (!(stress > 0.0)) {
        const double infinite = std::numeric_limits<double>::infinity();
        if (material.yieldStrengthPa) m.yield = infinite;
        m.ultimate = infinite;
        m.governing = infinite;
        return m;
    }
    if (material.yieldStrengthPa) {
        m.yield = *material.yieldStrengthPa / stress - 1.0;
    }
    m.ultimate = material.ultimateStrengthPa / (factorOfSafety * stress) - 1.0;
    m.governing = m.yield ? std::min(*m.yield, m.ultimate) : m.ultimate;
    return m;
}

} // namespace

StrengthAssessment assessStrength(const IsotropicMaterial& material, double limitStressPa,
                                  const std::optional<ConvergenceEstimate>& convergence,
                                  const StrengthCriteria& criteria) {
    StrengthAssessment result;
    result.limitStressPa = limitStressPa;
    const auto nominal = marginsAt(material, limitStressPa, criteria.factorOfSafety);
    result.yieldMargin = nominal.yield;
    result.ultimateMargin = nominal.ultimate;
    result.governingMargin = nominal.governing;
    result.reserveFactor = nominal.governing + 1.0;

    bool warning = false;
    if (convergence) {
        if (convergence->isUsable()) {
            result.limitStressUncertaintyPa = convergence->uncertaintyAbsolute;
            result.conservativeMargin =
                marginsAt(material, limitStressPa + convergence->uncertaintyAbsolute, criteria.factorOfSafety).governing;
        } else {
            warning = true;
            result.reasons.push_back(
                convergence->behaviour == ConvergenceBehaviour::Divergent
                    ? "напряжение не сходится при измельчении сетки — вероятна особенность (острый угол, точечная опора)"
                    : "сходимость по сетке немонотонна — погрешность оценена только разбросом");
        }
    } else {
        warning = true;
        result.reasons.push_back("погрешность сетки не оценена (нет исследования сходимости)");
    }

    if (nominal.governing < 0.0) {
        result.verdict = StrengthVerdict::Fail;
        result.reasons.insert(result.reasons.begin(),
                              nominal.yield && *nominal.yield == nominal.governing
                                  ? "текучесть при эксплуатационной нагрузке"
                                  : "разрушение при расчётной нагрузке (×" + std::to_string(criteria.factorOfSafety).substr(0, 3) + ")");
        return result;
    }
    if (result.conservativeMargin && *result.conservativeMargin < 0.0) {
        warning = true;
        result.reasons.push_back("запас положителен, но полоса погрешности сетки заходит ниже нуля");
    }
    if (material.isotropicApproximation) {
        warning = true;
        result.reasons.push_back("анизотропный материал посчитан как изотропный: межслойное разрушение не моделируется");
    }
    result.verdict = warning ? StrengthVerdict::Warning : StrengthVerdict::Pass;
    return result;
}

const char* verdictName(StrengthVerdict verdict) {
    switch (verdict) {
    case StrengthVerdict::Pass: return "PASS";
    case StrengthVerdict::Warning: return "WARNING";
    case StrengthVerdict::Fail: return "FAIL";
    }
    return "?";
}

} // namespace cadnext::fea
