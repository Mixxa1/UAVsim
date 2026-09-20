#include "cadnext/fea/IcingStudy.hpp"

#include "cadnext/fea/AirConvection.hpp"
#include "cadnext/fea/SolidMesher.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<IcingStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<IcingStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

StrengthVerdict worse(StrengthVerdict a, StrengthVerdict b) {
    return static_cast<int>(a) > static_cast<int>(b) ? a : b;
}

struct Segment {
    double ax = 0.0, ay = 0.0, bx = 0.0, by = 0.0;
};

// The outline a plane cuts out of a triangulated surface, as one closed loop: the longest one, when
// the plane happens to cut the part in several places.
bool sliceSection(const TetMesh& mesh, int spanAxis, int flowAxis, int otherAxis, double station, SectionGeometry& section) {
    std::vector<Segment> segments;
    auto coordinate = [](const Vec3& point, int axis) { return axis == 0 ? point.x : axis == 1 ? point.y : point.z; };
    for (const auto& [name, faces] : mesh.faceGroups) {
        (void)name;
        for (const auto& face : faces) {
            const auto nodes = mesh.faceNodes(face);
            const Vec3 p[3] = {mesh.nodes[nodes[0]], mesh.nodes[nodes[1]], mesh.nodes[nodes[2]]};
            double crossX[3], crossY[3];
            int found = 0;
            for (int edge = 0; edge < 3; ++edge) {
                const Vec3& a = p[edge];
                const Vec3& b = p[(edge + 1) % 3];
                const double sa = coordinate(a, spanAxis) - station, sb = coordinate(b, spanAxis) - station;
                if ((sa > 0.0) == (sb > 0.0)) continue;
                const double t = sa / (sa - sb);
                if (found < 3) {
                    crossX[found] = coordinate(a, flowAxis) + t * (coordinate(b, flowAxis) - coordinate(a, flowAxis));
                    crossY[found] = coordinate(a, otherAxis) + t * (coordinate(b, otherAxis) - coordinate(a, otherAxis));
                    ++found;
                }
            }
            if (found == 2) segments.push_back({crossX[0], crossY[0], crossX[1], crossY[1]});
        }
    }
    if (segments.size() < 3) return false;

    // Chain the segments end to end. Points that are within a whisker of each other are the same
    // point: the triangles share their edges exactly, so the whisker only has to beat round-off.
    double extent = 0.0;
    for (const auto& s : segments) extent = std::max({extent, std::fabs(s.ax), std::fabs(s.bx), std::fabs(s.ay), std::fabs(s.by)});
    const double tolerance = std::max(extent, 1.0) * 1e-9;
    auto key = [&](double x, double y) {
        return std::make_pair(static_cast<long long>(std::llround(x / tolerance)), static_cast<long long>(std::llround(y / tolerance)));
    };
    std::map<std::pair<long long, long long>, std::vector<std::size_t>> ends;
    for (std::size_t i = 0; i < segments.size(); ++i) {
        ends[key(segments[i].ax, segments[i].ay)].push_back(i);
        ends[key(segments[i].bx, segments[i].by)].push_back(i);
    }
    std::vector<bool> used(segments.size(), false);
    SectionGeometry best;
    double bestLength = 0.0;
    for (std::size_t seed = 0; seed < segments.size(); ++seed) {
        if (used[seed]) continue;
        SectionGeometry loop;
        double length = 0.0;
        std::size_t current = seed;
        double x = segments[seed].ax, y = segments[seed].ay;
        while (true) {
            used[current] = true;
            const double nextX = std::fabs(segments[current].ax - x) < tolerance && std::fabs(segments[current].ay - y) < tolerance ? segments[current].bx
                                                                                                                                  : segments[current].ax;
            const double nextY = std::fabs(segments[current].ax - x) < tolerance && std::fabs(segments[current].ay - y) < tolerance ? segments[current].by
                                                                                                                                  : segments[current].ay;
            loop.x.push_back(x);
            loop.y.push_back(y);
            length += std::hypot(nextX - x, nextY - y);
            x = nextX, y = nextY;
            const auto found = ends.find(key(x, y));
            std::size_t next = segments.size();
            if (found != ends.end())
                for (std::size_t candidate : found->second)
                    if (!used[candidate]) next = candidate;
            if (next == segments.size()) break;
            current = next;
        }
        if (loop.x.size() >= 3 && length > bestLength) bestLength = length, best = loop;
    }
    if (best.x.size() < 3) return false;
    section = best;
    return true;
}

// The local film coefficient of a flat plate at a running length from the stagnation point
// (Incropera et al., 6th ed., eqs. 7.23 laminar and 7.36 turbulent), with the transition at 5·10⁵.
double localFilmCoefficient(const AirProperties& air, double edgeSpeedMps, double runningLengthM) {
    if (!(runningLengthM > 0.0) || !(edgeSpeedMps > 0.0)) return 0.0;
    const double reynolds = air.densityKgM3 * edgeSpeedMps * runningLengthM / air.viscosityPaS;
    const double prandtl = air.prandtl;
    const double nusselt = reynolds <= 5e5 ? 0.332 * std::sqrt(reynolds) * std::cbrt(prandtl) : 0.0296 * std::pow(reynolds, 0.8) * std::cbrt(prandtl);
    return nusselt * air.conductivityWmK / runningLengthM;
}

// At the stagnation point of a cylinder: Nu_D = 1.14 Re_D^½ Pr^0.4 (Frössling 1940, as given in
// Incropera et al. §7.4). A leading edge is a cylinder of its own radius, and this is the value the
// flat plate's runaway is capped by.
double stagnationFilmCoefficient(const AirProperties& air, double speedMps, double radiusM) {
    if (!(radiusM > 0.0) || !(speedMps > 0.0)) return 0.0;
    const double diameter = 2.0 * radiusM;
    const double reynolds = air.densityKgM3 * speedMps * diameter / air.viscosityPaS;
    return 1.14 * std::sqrt(reynolds) * std::pow(air.prandtl, 0.4) * air.conductivityWmK / diameter;
}

// The radius of the circle through three points: what the leading edge's curvature is, measured
// rather than assumed.
double circleRadius(double ax, double ay, double bx, double by, double cx, double cy) {
    const double a = std::hypot(bx - ax, by - ay), b = std::hypot(cx - bx, cy - by), c = std::hypot(ax - cx, ay - cy);
    const double area = std::fabs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2.0;
    if (!(area > 0.0)) return 0.0;
    return a * b * c / (4.0 * area);
}

} // namespace

Result<IcingStudyResult> runIcingStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                       const std::string& loadCaseName, const IcingStudySettings& settings, const StructuralStudyProgress& progress) {
    const IcingCondition& condition = settings.condition;
    if (!(condition.airspeedMps > 0.0)) return failure(ErrorCode::InvalidArgument, "не задана скорость полёта");
    if (!(condition.dropletDiameterM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан диаметр капель");
    if (!(condition.lwcKgM3 > 0.0)) return failure(ErrorCode::InvalidArgument, "не задана водность облака");
    if (!(condition.durationS > 0.0)) return failure(ErrorCode::InvalidArgument, "не задана длительность полёта в облаке");
    if (condition.temperatureK >= kMeltingPointK) return failure(ErrorCode::InvalidArgument, "температура воздуха не ниже нуля: обледенения не будет");
    if (settings.flowAxis == settings.spanAxis) return failure(ErrorCode::InvalidArgument, "ось потока и ось размаха должны различаться");
    if (settings.stations < 1) return failure(ErrorCode::InvalidArgument, "нужно хотя бы одно сечение");
    if (settings.panels < 60 || settings.trajectories < 20) return failure(ErrorCode::InvalidArgument, "слишком грубо: нужно от 60 панелей и 20 траекторий");
    if (!(settings.refinementFactor >= 1.2)) return failure(ErrorCode::InvalidArgument, "измельчение должно быть не меньше 1.2");

    IcingStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.condition = condition;

    SolidMeshingSettings meshing;
    meshing.maximumElementSizeM = settings.surfaceElementSizeM;
    meshing.order = ElementOrder::Linear;
    if (!(meshing.maximumElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер элемента поверхности");
    const auto meshed = meshSolid(kernel, shape, meshing);
    if (!meshed.isOk()) return failure(meshed.error().code, meshed.error().message);
    const TetMesh& mesh = meshed.value().mesh;
    result.mesherVersion = meshed.value().mesherVersion;

    const int otherAxis = 3 - settings.flowAxis - settings.spanAxis;
    auto coordinate = [](const Vec3& point, int axis) { return axis == 0 ? point.x : axis == 1 ? point.y : point.z; };
    double spanLow = 1e300, spanHigh = -1e300;
    for (const auto& node : mesh.nodes) {
        spanLow = std::min(spanLow, coordinate(node, settings.spanAxis));
        spanHigh = std::max(spanHigh, coordinate(node, settings.spanAxis));
    }
    result.spanM = spanHigh - spanLow;
    if (!(result.spanM > 0.0)) return failure(ErrorCode::InvalidArgument, "деталь не имеет размаха вдоль заданной оси");

    const double pressure = standardPressurePa(condition.altitudeM);
    const AirProperties air = airProperties(condition.temperatureK, pressure);

    // One level of refinement: every station, with this many panels and droplets.
    struct Level {
        std::vector<IcingStationResult> stations;
        double thickness = 0.0, efficiency = 0.0, mass = 0.0, power = 0.0;
        std::vector<std::string> warnings;
    };
    auto runLevel = [&](int panels, int trajectories) -> Result<Level> {
        Level level;
        for (int s = 0; s < settings.stations; ++s) {
            const double fraction = (s + 0.5) / settings.stations;
            const double station = spanLow + fraction * result.spanM;
            SectionGeometry raw;
            if (!sliceSection(mesh, settings.spanAxis, settings.flowAxis, otherAxis, station, raw)) {
                return Result<Level>::fail({ErrorCode::NotFound, "сечение на " + format(station, 4) + " м не замкнулось: деталь там не сплошная?"});
            }
            // Resample the outline to the level's panel count, evenly along its length.
            double perimeter = 0.0;
            std::vector<double> walk{0.0};
            for (std::size_t i = 0; i < raw.x.size(); ++i) {
                const std::size_t next = (i + 1) % raw.x.size();
                perimeter += std::hypot(raw.x[next] - raw.x[i], raw.y[next] - raw.y[i]);
                walk.push_back(perimeter);
            }
            SectionGeometry section;
            for (int p = 0; p < panels; ++p) {
                const double target = perimeter * p / panels;
                const std::size_t index = static_cast<std::size_t>(std::lower_bound(walk.begin(), walk.end(), target) - walk.begin());
                const std::size_t i = index == 0 ? 0 : index - 1;
                const std::size_t next = (i + 1) % raw.x.size();
                const double span = walk[i + 1] - walk[i];
                const double weight = span > 0.0 ? (target - walk[i]) / span : 0.0;
                section.x.push_back(raw.x[i] + weight * (raw.x[next] - raw.x[i]));
                section.y.push_back(raw.y[i] + weight * (raw.y[next] - raw.y[i]));
            }
            const auto flow = solvePanelFlow(section, condition.airspeedMps, settings.angleOfAttackRad, false);
            if (!flow.isOk()) return Result<Level>::fail(flow.error());

            ImpingementSettings impingement;
            impingement.trajectories = trajectories;
            const auto [minimumX, maximumX] = std::minmax_element(section.x.begin(), section.x.end());
            const double chord = *maximumX - *minimumX;
            impingement.referenceLengthM = chord;
            const auto caught = solveImpingement(flow.value(), condition, impingement);
            if (!caught.isOk()) return Result<Level>::fail(caught.error());

            IcingStationResult record;
            record.spanPositionM = station;
            record.chordM = chord;
            record.collectionEfficiency = caught.value().totalEfficiency;
            record.maximumBeta = caught.value().maximumBeta;
            record.waterKgPerSPerM = caught.value().waterKgPerSPerM;
            record.arcLengthM = caught.value().arcLengthM;
            record.betaPerPanel = caught.value().betaPerPanel;
            for (const auto& warning : caught.value().warnings) level.warnings.push_back("сечение " + format(station, 3) + " м: " + warning);

            // The stagnation point is where the flow stops; running length is measured from it.
            std::size_t stagnation = 0;
            double slowest = 1e300;
            for (std::size_t i = 0; i < flow.value().surfaceSpeedMps.size(); ++i) {
                if (std::fabs(flow.value().surfaceSpeedMps[i]) < slowest) slowest = std::fabs(flow.value().surfaceSpeedMps[i]), stagnation = i;
            }
            double stagnationArc = 0.0;
            for (std::size_t i = 0; i < stagnation; ++i) stagnationArc += flow.value().length[i];
            // The leading edge's own radius, from the control points a couple of per cent of the
            // chord either side of the stagnation point, and the film coefficient that goes with it.
            const std::size_t count = flow.value().controlX.size();
            std::size_t offset = 1;
            while (offset + 1 < count / 4) {
                const std::size_t back = (stagnation + count - offset) % count;
                if (std::hypot(flow.value().controlX[back] - flow.value().controlX[stagnation],
                               flow.value().controlY[back] - flow.value().controlY[stagnation])
                    >= 0.02 * chord) {
                    break;
                }
                ++offset;
            }
            const std::size_t back = (stagnation + count - offset) % count, forward = (stagnation + offset) % count;
            record.leadingEdgeRadiusM = circleRadius(flow.value().controlX[back], flow.value().controlY[back], flow.value().controlX[stagnation],
                                                     flow.value().controlY[stagnation], flow.value().controlX[forward], flow.value().controlY[forward]);
            record.stagnationFilmWm2K = stagnationFilmCoefficient(air, condition.airspeedMps, record.leadingEdgeRadiusM);

            double worstThickness = 0.0, worstGrowth = 0.0, mass = 0.0, power = 0.0, impinged = 0.0;
            for (std::size_t i = 0; i < flow.value().length.size(); ++i) {
                const double beta = i < record.betaPerPanel.size() ? record.betaPerPanel[i] : 0.0;
                const double running = std::max(std::fabs(record.arcLengthM[i] - stagnationArc), 1e-4 * chord);
                const double edge = std::fabs(flow.value().surfaceSpeedMps[i]);
                double film = localFilmCoefficient(air, std::max(edge, 0.05 * condition.airspeedMps), running);
                if (record.stagnationFilmWm2K > 0.0) film = std::min(film, record.stagnationFilmWm2K);
                record.heatTransferWm2K.push_back(film);
                record.panelXM.push_back(flow.value().controlX[i]);
                record.panelYM.push_back(flow.value().controlY[i]);
                MessingerInput input;
                input.airTemperatureK = condition.temperatureK;
                input.pressurePa = pressure;
                input.airspeedMps = condition.airspeedMps;
                input.localSpeedMps = edge;
                input.heatTransferWm2K = film;
                input.impingingKgSm2 = beta * condition.lwcKgM3 * condition.airspeedMps;
                input.relativeHumidity = condition.relativeHumidity;
                const auto balance = solveMessinger(input);
                const double thickness = balance.iceGrowthMps * condition.durationS;
                record.iceThicknessM.push_back(thickness);
                mass += balance.iceKgSm2 * condition.durationS * flow.value().length[i];
                if (beta > 0.0) {
                    impinged += flow.value().length[i];
                    if (settings.antiIceTargetK > 0.0) power += antiIceHeatFluxWm2(input, settings.antiIceTargetK) * flow.value().length[i];
                }
                if (thickness > worstThickness) {
                    worstThickness = thickness;
                    worstGrowth = balance.iceGrowthMps;
                    record.freezingFractionAtStagnation = balance.freezingFraction;
                    record.surfaceTemperatureK = balance.surfaceTemperatureK;
                    record.glaze = balance.glaze;
                    record.evaporatedKgSm2 = balance.evaporatedKgSm2;
                    record.impingingKgSm2 = input.impingingKgSm2;
                }
            }
            record.maximumIceThicknessM = worstThickness;
            record.maximumGrowthMps = worstGrowth;
            record.iceMassKgPerM = mass;
            record.impingementLengthM = impinged;
            record.antiIcePowerWPerM = power;
            level.stations.push_back(std::move(record));
        }
        // Along the span: each station stands for its own slice of it.
        const double slice = result.spanM / settings.stations;
        for (const auto& station : level.stations) {
            level.thickness = std::max(level.thickness, station.maximumIceThicknessM);
            level.efficiency = std::max(level.efficiency, station.collectionEfficiency);
            level.mass += station.iceMassKgPerM * slice;
            level.power += station.antiIcePowerWPerM * slice;
        }
        return Result<Level>::ok(std::move(level));
    };

    std::vector<Level> levels;
    for (int level = 0; level < 3; ++level) {
        if (progress) progress(level, "solve");
        const double factor = std::pow(settings.refinementFactor, level);
        const int panels = static_cast<int>(std::lround(settings.panels * factor));
        const int trajectories = static_cast<int>(std::lround(settings.trajectories * factor));
        const auto ran = runLevel(panels, trajectories);
        if (!ran.isOk()) return failure(ran.error().code, ran.error().message);
        IcingLevel record;
        record.panels = panels;
        record.trajectories = trajectories;
        record.maximumIceThicknessM = ran.value().thickness;
        record.collectionEfficiency = ran.value().efficiency;
        result.levels.push_back(record);
        levels.push_back(ran.value());
    }
    const Level& finest = levels.back();
    result.stations = finest.stations;
    result.maximumIceThicknessM = finest.thickness;
    result.collectionEfficiency = finest.efficiency;
    result.iceMassKg = finest.mass;
    result.antiIcePowerW = finest.power;
    for (const auto& warning : finest.warnings) result.warnings.push_back(warning);

    const double r21 = settings.refinementFactor, r32 = settings.refinementFactor;
    result.thicknessConvergence = estimateConvergence(result.levels[2].maximumIceThicknessM, result.levels[1].maximumIceThicknessM,
                                                      result.levels[0].maximumIceThicknessM, r21, r32, 1.25, 1.0);
    result.thicknessUncertaintyM = result.thicknessConvergence.isUsable()
                                       ? result.thicknessConvergence.uncertaintyAbsolute
                                       : std::max({result.levels[0].maximumIceThicknessM, result.levels[1].maximumIceThicknessM,
                                                   result.levels[2].maximumIceThicknessM})
                                             - std::min({result.levels[0].maximumIceThicknessM, result.levels[1].maximumIceThicknessM,
                                                         result.levels[2].maximumIceThicknessM});

    double chord = 0.0;
    for (const auto& station : result.stations) chord = std::max(chord, station.chordM);
    result.inertiaParameter = inertiaParameter(condition.dropletDiameterM, condition.airspeedMps, chord, air.viscosityPaS);

    // The band the flat-plate film leaves: the same calculation with the coefficient halved and
    // doubled, which is the spread between a smooth laminar surface and a rough iced one.
    {
        double low = 0.0, high = 0.0;
        for (double factor : {0.5, 2.0}) {
            double worst = 0.0;
            for (const auto& station : result.stations) {
                for (std::size_t i = 0; i < station.betaPerPanel.size() && i < station.heatTransferWm2K.size(); ++i) {
                    MessingerInput input;
                    input.airTemperatureK = condition.temperatureK;
                    input.pressurePa = pressure;
                    input.airspeedMps = condition.airspeedMps;
                    input.localSpeedMps = condition.airspeedMps;
                    input.heatTransferWm2K = station.heatTransferWm2K[i] * factor;
                    input.impingingKgSm2 = station.betaPerPanel[i] * condition.lwcKgM3 * condition.airspeedMps;
                    input.relativeHumidity = condition.relativeHumidity;
                    worst = std::max(worst, solveMessinger(input).iceGrowthMps * condition.durationS);
                }
            }
            (factor < 1.0 ? low : high) = worst;
        }
        result.heatTransferBandLow = low;
        result.heatTransferBandHigh = high;
    }

    auto report = [&](StrengthVerdict verdict, const std::string& reason) {
        result.verdict = worse(result.verdict, verdict);
        (verdict == StrengthVerdict::Fail ? result.failureReasons : result.reasons).push_back(reason);
    };
    result.verdict = StrengthVerdict::Pass;
    if (settings.maximumIceThicknessM > 0.0) {
        if (result.maximumIceThicknessM > settings.maximumIceThicknessM) {
            report(StrengthVerdict::Fail, "лёд " + format(result.maximumIceThicknessM * 1e3, 2) + " мм за " + format(condition.durationS / 60.0, 1)
                                              + " мин против предела " + format(settings.maximumIceThicknessM * 1e3, 2) + " мм");
        } else if (result.maximumIceThicknessM + result.thicknessUncertaintyM > settings.maximumIceThicknessM) {
            report(StrengthVerdict::Warning, "лёд " + format(result.maximumIceThicknessM * 1e3, 2) + " мм, но в пределах погрешности сетки достаёт до "
                                                 + format(settings.maximumIceThicknessM * 1e3, 2) + " мм");
        }
    } else {
        report(StrengthVerdict::Warning, "нет данных: допустимая толщина льда не задана, сравнивать не с чем");
    }
    if (settings.antiIceTargetK > 0.0 && settings.antiIceBudgetW > 0.0 && result.antiIcePowerW > settings.antiIceBudgetW) {
        report(StrengthVerdict::Fail, "обогрев требует " + format(result.antiIcePowerW, 0) + " Вт против бюджета " + format(settings.antiIceBudgetW, 0) + " Вт");
    }
    if (settings.antiIceTargetK > 0.0 && settings.antiIceBudgetW <= 0.0) {
        report(StrengthVerdict::Warning, "нет данных: бюджет мощности обогрева не задан (нужно " + format(result.antiIcePowerW, 0) + " Вт)");
    }
    if (result.heatTransferBandHigh > 0.0 && result.heatTransferBandHigh / std::max(result.maximumIceThicknessM, 1e-12) > 1.2) {
        report(StrengthVerdict::Warning, "теплоотдача взята как у плоской пластины: при её изменении вдвое толщина льда лежит между "
                                             + format(result.heatTransferBandLow * 1e3, 2) + " и " + format(result.heatTransferBandHigh * 1e3, 2) + " мм");
    }
    result.warnings.push_back("лёд не меняет обтекание: толщина это скорость первого мгновения, продлённая на всё время — для наледи в режиме "
                              "мокрого роста это оценка, а не форма");
    result.warnings.push_back("стекающая вода не прослеживается вдоль поверхности: доля намерзания посчитана, а куда уходит остальное — нет");
    result.warnings.push_back("сечения плоские: ни стреловидности, ни перетекания вдоль размаха, ни концевых эффектов");
    result.warnings.push_back("пограничный слой взят как у плоской пластины, шероховатость льда не моделируется");
    if (condition.dropletDiameterM > 50e-6) {
        result.warnings.push_back("капли крупнее 50 мкм — это Приложение O: дробление и разбрызгивание здесь не моделируются");
    }

    // The part's surface, carrying the ice of the nearest station.
    std::unordered_map<int, int> fieldIndex;
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(mesh.nodes[meshNode]);
        result.field.displacement.push_back({});
        result.field.vonMisesPa.push_back(0.0);
        // The station nearest this node, and within it the panel nearest the node's position across
        // the flow: the thickness there is what this node carries.
        const Vec3& point = mesh.nodes[meshNode];
        double thickness = 0.0, bestStation = 1e300;
        const IcingStationResult* chosen = nullptr;
        for (const auto& station : result.stations) {
            const double distance = std::fabs(coordinate(point, settings.spanAxis) - station.spanPositionM);
            if (distance < bestStation) bestStation = distance, chosen = &station;
        }
        if (chosen != nullptr && !chosen->iceThicknessM.empty()) {
            // The panels are not carried here with their coordinates, only with their arc length, so
            // a node takes the ice of the panel whose place along the section is nearest its own:
            // the ice of a leading edge ends up on the leading edge, which is what the picture is for.
            const double nodeFlow = coordinate(point, settings.flowAxis);
            double bestDistance = 1e300;
            for (std::size_t i = 0; i < chosen->iceThicknessM.size() && i < chosen->arcLengthM.size(); ++i) {
                const double along = chosen->chordM * chosen->arcLengthM[i] / std::max(chosen->arcLengthM.back(), 1e-12);
                const double distance = std::fabs(nodeFlow - along);
                if (distance < bestDistance) bestDistance = distance, thickness = chosen->iceThicknessM[i];
            }
        }
        result.fieldIceM.push_back(thickness);
        fieldIndex.emplace(meshNode, index);
        return index;
    };
    for (const auto& [name, faces] : mesh.faceGroups) {
        for (const auto& face : faces) {
            const auto nodes = mesh.faceNodes(face);
            std::vector<int> f;
            for (int node : nodes) f.push_back(fieldNode(node));
            if (f.size() >= 3) {
                result.field.triangles.push_back({f[0], f[1], f[2]});
                result.field.triangleFace.push_back(name);
            }
        }
    }
    return Result<IcingStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
