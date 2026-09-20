#include "cadnext/fea/Icing.hpp"

#include "cadnext/fea/AirConvection.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

namespace {

using R = Result<ImpingementResult>;

// Is a point inside the closed section? The ray-crossing count, as everywhere else in this project.
bool inside(const SectionGeometry& section, double x, double y) {
    bool in = false;
    for (std::size_t i = 0, j = section.size() - 1; i < section.size(); j = i++) {
        const bool straddles = (section.y[i] > y) != (section.y[j] > y);
        if (!straddles) continue;
        const double crossing = section.x[i] + (y - section.y[i]) * (section.x[j] - section.x[i]) / (section.y[j] - section.y[i]);
        if (x < crossing) in = !in;
    }
    return in;
}

// Where along the surface the point nearest (x, y) sits, measured from the first point of the
// section, and how far away it is.
void nearestArc(const PanelFlowSolution& flow, double x, double y, double& arc, double& distance) {
    double best = 1e300, bestArc = 0.0, walked = 0.0;
    for (std::size_t i = 0; i < flow.length.size(); ++i) {
        const std::size_t next = (i + 1) % flow.section.size();
        const double ax = flow.section.x[i], ay = flow.section.y[i];
        const double bx = flow.section.x[next], by = flow.section.y[next];
        const double dx = bx - ax, dy = by - ay;
        const double lengthSquared = dx * dx + dy * dy;
        double t = lengthSquared > 0.0 ? ((x - ax) * dx + (y - ay) * dy) / lengthSquared : 0.0;
        t = std::clamp(t, 0.0, 1.0);
        const double px = ax + t * dx, py = ay + t * dy;
        const double d = std::hypot(x - px, y - py);
        if (d < best) best = d, bestArc = walked + t * flow.length[i];
        walked += flow.length[i];
    }
    arc = bestArc;
    distance = best;
}

} // namespace

IcingCondition takeoffMaximumIcing(double airspeedMps, double durationS) {
    IcingCondition condition;
    condition.temperatureK = kMeltingPointK - 9.0;
    condition.lwcKgM3 = 0.35e-3;
    condition.dropletDiameterM = 20e-6;
    condition.altitudeM = 0.0;
    condition.airspeedMps = airspeedMps;
    condition.durationS = durationS;
    condition.source = "14 CFR 25 Appendix C (c), takeoff maximum icing: 0.35 g/m³, 20 мкм, −9 °C, от земли до 1500 футов";
    return condition;
}

double dropletDragFactor(double reynolds) {
    if (!(reynolds > 0.0)) return 1.0;
    return 1.0 + 0.15 * std::pow(reynolds, 0.687); // Schiller & Naumann 1933
}

double inertiaParameter(double dropletDiameterM, double airspeedMps, double referenceLengthM, double airViscosityPasS) {
    if (!(referenceLengthM > 0.0) || !(airViscosityPasS > 0.0)) return 0.0;
    return kWaterDensityKgM3 * dropletDiameterM * dropletDiameterM * airspeedMps / (18.0 * airViscosityPasS * referenceLengthM);
}

double saturationVapourPressurePa(double temperatureK) {
    // Buck (1981), over water: e = 6.1121 exp[(18.678 − t/234.5) t/(257.14 + t)] hPa, t in °C.
    const double t = temperatureK - kMeltingPointK;
    return 100.0 * 6.1121 * std::exp((18.678 - t / 234.5) * t / (257.14 + t));
}

Result<ImpingementResult> solveImpingement(const PanelFlowSolution& flow, const IcingCondition& condition, const ImpingementSettings& settings) {
    if (flow.section.size() < 3) return R::fail({ErrorCode::InvalidArgument, "нет сечения"});
    if (!(condition.dropletDiameterM > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не задан диаметр капель"});
    if (!(condition.airspeedMps > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не задана скорость полёта"});
    if (settings.trajectories < 8) return R::fail({ErrorCode::InvalidArgument, "нужно не меньше восьми траекторий"});

    const auto [minimumX, maximumX] = std::minmax_element(flow.section.x.begin(), flow.section.x.end());
    const double chord = *maximumX - *minimumX;
    const double reference = settings.referenceLengthM > 0.0 ? settings.referenceLengthM : chord;
    if (!(reference > 0.0)) return R::fail({ErrorCode::InvalidArgument, "нулевой размер сечения"});

    const double pressure = standardPressurePa(condition.altitudeM);
    const AirProperties air = airProperties(condition.temperatureK, pressure);
    const double relaxation = kWaterDensityKgM3 * condition.dropletDiameterM * condition.dropletDiameterM / (18.0 * air.viscosityPaS);

    // The free stream's direction, and the line across it that the droplets are released on.
    const double ex = std::cos(flow.angleOfAttackRad), ey = std::sin(flow.angleOfAttackRad);
    const double nx = -ey, ny = ex;
    double centreX = 0.0, centreY = 0.0;
    for (std::size_t i = 0; i < flow.section.size(); ++i) centreX += flow.section.x[i], centreY += flow.section.y[i];
    centreX /= static_cast<double>(flow.section.size());
    centreY /= static_cast<double>(flow.section.size());
    double lowest = 1e300, highest = -1e300;
    for (std::size_t i = 0; i < flow.section.size(); ++i) {
        const double offset = (flow.section.x[i] - centreX) * nx + (flow.section.y[i] - centreY) * ny;
        lowest = std::min(lowest, offset), highest = std::max(highest, offset);
    }
    const double frontalHeight = highest - lowest;
    if (!(frontalHeight > 0.0)) return R::fail({ErrorCode::InvalidArgument, "сечение не имеет высоты поперёк потока"});

    ImpingementResult result;
    const double start = settings.startLengths * reference;
    const double step = settings.stepLengths * reference / condition.airspeedMps;
    const double limitTime = 4.0 * (start + 2.0 * reference) / condition.airspeedMps;
    const double margin = 0.05 * frontalHeight;

    struct Hit {
        double release = 0.0, arc = 0.0;
        bool landed = false;
    };
    std::vector<Hit> hits(static_cast<std::size_t>(settings.trajectories));
    double worstReynolds = 0.0;
    for (int t = 0; t < settings.trajectories; ++t) {
        const double fraction = static_cast<double>(t) / (settings.trajectories - 1);
        const double release = lowest - margin + fraction * (frontalHeight + 2.0 * margin);
        hits[static_cast<std::size_t>(t)].release = release;
        double x = centreX - ex * start + nx * release;
        double y = centreY - ey * start + ny * release;
        double vx = condition.airspeedMps * ex, vy = condition.airspeedMps * ey;
        double time = 0.0;
        double previousX = x, previousY = y;
        while (time < limitTime) {
            // Runge–Kutta of fourth order on ẋ = v, v̇ = (f/τ)(u(x) − v).
            auto acceleration = [&](double px, double py, double pvx, double pvy, double& ax, double& ay) {
                double u = 0.0, v = 0.0;
                flow.velocityAt(px, py, u, v);
                const double slip = std::hypot(u - pvx, v - pvy);
                const double reynolds = air.densityKgM3 * slip * condition.dropletDiameterM / air.viscosityPaS;
                worstReynolds = std::max(worstReynolds, reynolds);
                const double factor = dropletDragFactor(reynolds) / relaxation;
                ax = factor * (u - pvx);
                ay = factor * (v - pvy);
            };
            double a1x = 0.0, a1y = 0.0, a2x = 0.0, a2y = 0.0, a3x = 0.0, a3y = 0.0, a4x = 0.0, a4y = 0.0;
            acceleration(x, y, vx, vy, a1x, a1y);
            acceleration(x + 0.5 * step * vx, y + 0.5 * step * vy, vx + 0.5 * step * a1x, vy + 0.5 * step * a1y, a2x, a2y);
            acceleration(x + 0.5 * step * (vx + 0.5 * step * a1x), y + 0.5 * step * (vy + 0.5 * step * a1y), vx + 0.5 * step * a2x, vy + 0.5 * step * a2y,
                         a3x, a3y);
            acceleration(x + step * (vx + 0.5 * step * a2x), y + step * (vy + 0.5 * step * a2y), vx + step * a3x, vy + step * a3y, a4x, a4y);
            previousX = x, previousY = y;
            x += step * (vx + step * (a1x + a2x + a3x) / 6.0);
            y += step * (vy + step * (a1y + a2y + a3y) / 6.0);
            vx += step * (a1x + 2.0 * a2x + 2.0 * a3x + a4x) / 6.0;
            vy += step * (a1y + 2.0 * a2y + 2.0 * a3y + a4y) / 6.0;
            time += step;
            if (inside(flow.section, x, y)) {
                // Where it crossed, by halving the last step.
                double lowX = previousX, lowY = previousY, highX = x, highY = y;
                for (int k = 0; k < 40; ++k) {
                    const double midX = 0.5 * (lowX + highX), midY = 0.5 * (lowY + highY);
                    if (inside(flow.section, midX, midY)) highX = midX, highY = midY;
                    else lowX = midX, lowY = midY;
                }
                double arc = 0.0, distance = 0.0;
                nearestArc(flow, 0.5 * (lowX + highX), 0.5 * (lowY + highY), arc, distance);
                hits[static_cast<std::size_t>(t)].landed = true;
                hits[static_cast<std::size_t>(t)].arc = arc;
                ++result.impacts;
                break;
            }
            const double along = (x - centreX) * ex + (y - centreY) * ey;
            if (along > 2.0 * reference) break; // past the body
        }
    }

    // The band of the free stream that reaches the body, and the local efficiency between neighbours.
    double lowestRelease = 1e300, highestRelease = -1e300;
    for (const auto& hit : hits)
        if (hit.landed) lowestRelease = std::min(lowestRelease, hit.release), highestRelease = std::max(highestRelease, hit.release);
    if (result.impacts < 2) {
        result.warnings.push_back("ни одна капля или только одна попала в деталь: увеличьте число траекторий или проверьте размер капель");
        return R::ok(std::move(result));
    }
    result.capturedHeightM = highestRelease - lowestRelease;
    result.totalEfficiency = result.capturedHeightM / frontalHeight;
    result.waterKgPerSPerM = condition.lwcKgM3 * condition.airspeedMps * result.capturedHeightM;

    // The impingement zone is a contiguous stretch of surface, but the arc length it is measured in
    // starts wherever the section's first point happens to be — and on a leading edge the zone
    // straddles that origin. The arcs are therefore unwrapped along the fan of trajectories before
    // anything is interpolated between them. (Sorting them instead, which is what this did first,
    // put the two sides of the nose at opposite ends of the body and smeared the collection
    // efficiency over the whole section: ice to the trailing edge, and an impingement length of the
    // entire perimeter.)
    double perimeter = 0.0;
    for (double length : flow.length) perimeter += length;
    struct Local {
        double arc = 0.0, beta = 0.0;
    };
    std::vector<Local> locals;
    double previousArc = 0.0;
    bool started = false;
    std::vector<std::pair<double, double>> unwrapped; // release, arc
    for (const auto& hit : hits) {
        if (!hit.landed) continue;
        double arc = hit.arc;
        if (started) {
            while (arc - previousArc > 0.5 * perimeter) arc -= perimeter;
            while (previousArc - arc > 0.5 * perimeter) arc += perimeter;
        }
        unwrapped.emplace_back(hit.release, arc);
        previousArc = arc;
        started = true;
    }
    for (std::size_t i = 0; i + 1 < unwrapped.size(); ++i) {
        const double deltaRelease = std::fabs(unwrapped[i + 1].first - unwrapped[i].first);
        const double deltaArc = std::fabs(unwrapped[i + 1].second - unwrapped[i].second);
        if (!(deltaArc > 0.0)) continue;
        locals.push_back({0.5 * (unwrapped[i].second + unwrapped[i + 1].second), deltaRelease / deltaArc});
    }
    std::sort(locals.begin(), locals.end(), [](const Local& a, const Local& b) { return a.arc < b.arc; });
    if (locals.empty()) {
        result.warnings.push_back("попадания не дали ни одного отрезка поверхности: сетка панелей слишком груба");
        return R::ok(std::move(result));
    }
    result.lowerLimitArcM = locals.front().arc;
    result.upperLimitArcM = locals.back().arc;

    double walked = 0.0;
    for (std::size_t i = 0; i < flow.length.size(); ++i) {
        const double arc = walked + 0.5 * flow.length[i];
        walked += flow.length[i];
        result.arcLengthM.push_back(arc);
        double beta = 0.0;
        // The panel's own arc, brought into the window the trajectories were unwrapped into.
        double unwrappedArc = arc;
        while (unwrappedArc < locals.front().arc - 0.5 * perimeter) unwrappedArc += perimeter;
        while (unwrappedArc > locals.front().arc + 0.5 * perimeter) unwrappedArc -= perimeter;
        if (unwrappedArc >= locals.front().arc && unwrappedArc <= locals.back().arc) {
            const auto upper = std::lower_bound(locals.begin(), locals.end(), unwrappedArc, [](const Local& a, double value) { return a.arc < value; });
            if (upper == locals.begin()) {
                beta = locals.front().beta;
            } else if (upper == locals.end()) {
                beta = locals.back().beta;
            } else {
                const auto lower = upper - 1;
                const double span = upper->arc - lower->arc;
                const double weight = span > 0.0 ? (unwrappedArc - lower->arc) / span : 0.0;
                beta = lower->beta + weight * (upper->beta - lower->beta);
            }
        }
        result.betaPerPanel.push_back(beta);
        result.maximumBeta = std::max(result.maximumBeta, beta);
    }
    if (worstReynolds > 800.0) {
        result.warnings.push_back("число Рейнольдса капли доходит до " + std::to_string(static_cast<int>(worstReynolds))
                                  + ": формула сопротивления Шиллера–Наумана проверена до 800");
    }
    if (hits.front().landed || hits.back().landed) {
        result.warnings.push_back("захват доходит до края веера траекторий: полоса захвата может быть шире посчитанной");
    }
    if (result.maximumBeta > 1.0 + 1e-6) {
        result.warnings.push_back("местная эффективность захвата выше единицы: траекторий слишком мало для этой кривизны");
    }
    return R::ok(std::move(result));
}

MessingerResult solveMessinger(const MessingerInput& input) {
    MessingerResult result;
    const AirProperties air = airProperties(input.airTemperatureK, input.pressurePa);
    // What the air feels at a stopped surface: the static temperature plus the recovered part of the
    // local dynamic head.
    result.recoveryTemperatureK = input.airTemperatureK + input.recoveryFactor * input.localSpeedMps * input.localSpeedMps / (2.0 * kAirSpecificHeat);
    const double caught = input.impingingKgSm2 + input.runbackInKgSm2;

    // Evaporation by the Chilton–Colburn analogy: ṁ = h/(c_p Le^{2/3}) · (w_s(T_s) − w_∞), with the
    // humidity ratio w ≈ 0.622 p_v/p. Le = 0.86 for water vapour in air.
    const double lewis = 0.86;
    auto evaporation = [&](double surfaceK) {
        const double surfaceVapour = saturationVapourPressurePa(surfaceK);
        const double airVapour = input.relativeHumidity * saturationVapourPressurePa(input.airTemperatureK);
        const double ratio = 0.622 / std::max(input.pressurePa, 1.0);
        const double rate = input.heatTransferWm2K / (kAirSpecificHeat * std::pow(lewis, 2.0 / 3.0)) * ratio * (surfaceVapour - airVapour);
        return std::max(rate, 0.0);
    };

    // The balance, as a function of the surface temperature and the freezing fraction. Positive terms
    // warm the surface.
    auto balance = [&](double surfaceK, double freezing, MessingerResult& out) {
        const double evaporated = std::min(evaporation(surfaceK), caught);
        // What evaporates cannot also freeze: the fraction is of the water that is left, so that
        // caught = ice + evaporated + runback exactly, whatever the fraction.
        const double frozen = freezing * (caught - evaporated);
        out.convectiveWm2 = input.heatTransferWm2K * (result.recoveryTemperatureK - surfaceK);
        out.kineticWm2 = input.impingingKgSm2 * input.airspeedMps * input.airspeedMps / 2.0;
        out.sensibleWm2 = input.impingingKgSm2 * kWaterSpecificHeatJkgK * (input.airTemperatureK - surfaceK)
                          + input.runbackInKgSm2 * kWaterSpecificHeatJkgK * (kMeltingPointK - surfaceK);
        out.latentWm2 = frozen * kLatentHeatFusionJkg + frozen * kIceSpecificHeatJkgK * (kMeltingPointK - surfaceK);
        out.evaporativeWm2 = -evaporated * kLatentHeatVaporisationJkg;
        out.suppliedWm2 = input.surfaceHeatFluxWm2;
        out.evaporatedKgSm2 = evaporated;
        out.iceKgSm2 = frozen;
        out.runbackOutKgSm2 = caught - frozen - evaporated;
        return out.convectiveWm2 + out.kineticWm2 + out.sensibleWm2 + out.latentWm2 + out.evaporativeWm2 + out.suppliedWm2;
    };

    // First assume everything freezes and find the surface temperature that closes the balance.
    MessingerResult trial;
    auto rimeResidual = [&](double surfaceK) { return balance(surfaceK, 1.0, trial); };
    double low = input.airTemperatureK - 60.0, high = kMeltingPointK + 60.0;
    for (int i = 0; i < 200; ++i) {
        const double middle = 0.5 * (low + high);
        if (rimeResidual(middle) > 0.0) low = middle; // too cold: the balance still has heat to give
        else high = middle;
    }
    const double rimeSurface = 0.5 * (low + high);

    if (rimeSurface <= kMeltingPointK) {
        result.glaze = false;
        result.freezingFraction = 1.0;
        result.surfaceTemperatureK = rimeSurface;
        result.residualWm2 = balance(rimeSurface, 1.0, result);
        result.iceGrowthMps = result.iceKgSm2 / kRimeIceDensityKgM3;
        return result;
    }

    // Otherwise the surface sits at melting and only part of the water freezes.
    result.glaze = true;
    result.surfaceTemperatureK = kMeltingPointK;
    double lowFraction = 0.0, highFraction = 1.0;
    MessingerResult probe;
    auto glazeResidual = [&](double fraction) { return balance(kMeltingPointK, fraction, probe); };
    if (glazeResidual(0.0) > 0.0) {
        // Even with nothing freezing the surface has heat to spare: no ice at all, and the surface
        // runs above melting. Find that temperature for the record.
        result.freezingFraction = 0.0;
        double warmLow = kMeltingPointK, warmHigh = kMeltingPointK + 200.0;
        for (int i = 0; i < 200; ++i) {
            const double middle = 0.5 * (warmLow + warmHigh);
            if (balance(middle, 0.0, probe) > 0.0) warmLow = middle;
            else warmHigh = middle;
        }
        result.surfaceTemperatureK = 0.5 * (warmLow + warmHigh);
        result.residualWm2 = balance(result.surfaceTemperatureK, 0.0, result);
        result.glaze = false;
        result.iceGrowthMps = 0.0;
        return result;
    }
    for (int i = 0; i < 200; ++i) {
        const double middle = 0.5 * (lowFraction + highFraction);
        if (glazeResidual(middle) < 0.0) lowFraction = middle; // freezing releases heat: more of it
        else highFraction = middle;
    }
    result.freezingFraction = 0.5 * (lowFraction + highFraction);
    result.residualWm2 = balance(kMeltingPointK, result.freezingFraction, result);
    result.iceGrowthMps = result.iceKgSm2 / kIceDensityKgM3;
    return result;
}

double antiIceHeatFluxWm2(const MessingerInput& input, double targetK) {
    MessingerInput dry = input;
    dry.surfaceHeatFluxWm2 = 0.0;
    MessingerResult probe;
    // The balance with nothing freezing, at the target temperature: what is missing is the flux.
    const AirProperties air = airProperties(input.airTemperatureK, input.pressurePa);
    (void)air;
    const double recovery = input.airTemperatureK + input.recoveryFactor * input.localSpeedMps * input.localSpeedMps / (2.0 * kAirSpecificHeat);
    const double caught = input.impingingKgSm2 + input.runbackInKgSm2;
    const double lewis = 0.86;
    const double surfaceVapour = saturationVapourPressurePa(targetK);
    const double airVapour = input.relativeHumidity * saturationVapourPressurePa(input.airTemperatureK);
    const double evaporated =
        std::min(std::max(input.heatTransferWm2K / (kAirSpecificHeat * std::pow(lewis, 2.0 / 3.0)) * 0.622 / std::max(input.pressurePa, 1.0)
                              * (surfaceVapour - airVapour),
                          0.0),
                 caught);
    const double convective = input.heatTransferWm2K * (recovery - targetK);
    const double kinetic = input.impingingKgSm2 * input.airspeedMps * input.airspeedMps / 2.0;
    const double sensible = input.impingingKgSm2 * kWaterSpecificHeatJkgK * (input.airTemperatureK - targetK)
                            + input.runbackInKgSm2 * kWaterSpecificHeatJkgK * (kMeltingPointK - targetK);
    const double evaporative = -evaporated * kLatentHeatVaporisationJkg;
    return -(convective + kinetic + sensible + evaporative);
}

} // namespace cadnext::fea
