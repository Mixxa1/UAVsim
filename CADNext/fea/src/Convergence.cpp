#include "cadnext/fea/Convergence.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace cadnext::fea {

ConvergenceEstimate estimateConvergence(double fine, double medium, double coarse, double r, double safetyFactor) {
    return estimateConvergence(fine, medium, coarse, r, r, safetyFactor);
}

ConvergenceEstimate estimateConvergence(double fine, double medium, double coarse, double r21, double r32,
                                        double safetyFactor) {
    return estimateConvergence(fine, medium, coarse, r21, r32, safetyFactor,
                               std::numeric_limits<double>::infinity());
}

ConvergenceEstimate estimateConvergence(double fine, double medium, double coarse, double r21, double r32,
                                        double safetyFactor, double formalOrder) {
    if (!(r21 > 1.0) || !(r32 > 1.0)) {
        throw std::invalid_argument("estimateConvergence: refinement ratios must exceed 1");
    }
    ConvergenceEstimate estimate;
    estimate.fine = fine;
    const double e21 = medium - fine;
    const double e32 = coarse - medium;
    const double scale = std::max({std::fabs(fine), std::fabs(medium), std::fabs(coarse), 1e-300});

    if (std::fabs(e21) <= 1e-12 * scale) {
        estimate.behaviour = ConvergenceBehaviour::Converged;
        estimate.extrapolated = fine;
        return estimate;
    }
    auto divergent = [&] {
        // The change grew (or appeared from nothing) as the mesh got finer.
        estimate.behaviour = ConvergenceBehaviour::Divergent;
        estimate.extrapolated = fine;
        estimate.uncertaintyAbsolute = std::fabs(e21);
        estimate.gciFineRelative = std::fabs(e21 / fine);
        return estimate;
    };
    if (std::fabs(e32) <= 1e-12 * scale) {
        return divergent();
    }
    if (e32 / e21 < 0.0) {
        estimate.behaviour = ConvergenceBehaviour::Oscillatory;
        estimate.extrapolated = fine;
        const double spread = std::max({fine, medium, coarse}) - std::min({fine, medium, coarse});
        estimate.uncertaintyAbsolute = 0.5 * spread;
        estimate.gciFineRelative = estimate.uncertaintyAbsolute / std::fabs(fine);
        return estimate;
    }

    const double ratio = std::fabs(e32 / e21);
    double p = std::log(ratio) / std::log(r21);
    if (std::fabs(r21 - r32) > 1e-12) {
        // s = +1 here (monotonic), q(p) = ln((r21^p − 1)/(r32^p − 1)).
        for (int iteration = 0; iteration < 200; ++iteration) {
            const double denominator = std::pow(r32, p) - 1.0;
            const double numerator = std::pow(r21, p) - 1.0;
            if (!(denominator > 0.0) || !(numerator > 0.0)) break;
            const double next = std::fabs(std::log(ratio) + std::log(numerator / denominator)) / std::log(r21);
            if (std::fabs(next - p) < 1e-12) {
                p = next;
                break;
            }
            p = next;
        }
    }
    if (!(p > 0.0) || !std::isfinite(p)) {
        return divergent();
    }

    estimate.behaviour = ConvergenceBehaviour::Monotonic;
    estimate.observedOrder = p;
    if (p > formalOrder) {
        p = formalOrder;
        estimate.orderLimitedToFormal = true;
    }
    const double r21p = std::pow(r21, p);
    estimate.extrapolated = (r21p * fine - medium) / (r21p - 1.0);
    const double ea21 = std::fabs(e21 / fine);
    const double ea32 = std::fabs(e32 / medium);
    estimate.gciFineRelative = safetyFactor * ea21 / (r21p - 1.0);
    estimate.uncertaintyAbsolute = estimate.gciFineRelative * std::fabs(fine);
    const double gciCoarse = safetyFactor * ea32 / (std::pow(r32, p) - 1.0);
    estimate.asymptoticRatio = gciCoarse / (r21p * estimate.gciFineRelative);
    return estimate;
}

double representativeCellSize(double volume, std::size_t elementCount) {
    return std::cbrt(volume / static_cast<double>(std::max<std::size_t>(elementCount, 1)));
}

std::string ConvergenceEstimate::describe() const {
    std::ostringstream text;
    switch (behaviour) {
    case ConvergenceBehaviour::Monotonic:
        text << "monotonic, p=" << observedOrder << (orderLimitedToFormal ? " (limited to formal order)" : "")
             << ", extrapolated=" << extrapolated
             << ", GCI=" << gciFineRelative * 100.0 << "%, asymptotic ratio=" << asymptoticRatio;
        break;
    case ConvergenceBehaviour::Oscillatory:
        text << "oscillatory, ±" << uncertaintyAbsolute;
        break;
    case ConvergenceBehaviour::Divergent:
        text << "divergent (singularity?), last change " << uncertaintyAbsolute;
        break;
    case ConvergenceBehaviour::Converged:
        text << "converged to round-off";
        break;
    }
    return text.str();
}

} // namespace cadnext::fea
