#include "cadnext/fea/FlutterStudy.hpp"

#include "cadnext/fea/AirConvection.hpp"
#include "cadnext/fea/LinearStatic.hpp" // DisplacementConstraint
#include "cadnext/fea/Modal.hpp"
#include "cadnext/fea/SolidMesher.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<FlutterStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<FlutterStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

StrengthVerdict worse(StrengthVerdict a, StrengthVerdict b) {
    return static_cast<int>(a) > static_cast<int>(b) ? a : b;
}

double axisOf(const Vec3& point, int axis) {
    return axis == 0 ? point.x : axis == 1 ? point.y : point.z;
}

// One strip's worth of a mode: the plunge and the twist that best describe how its section moves.
// The fit is a least squares of the section's nodes against a rigid motion about the centroid, in
// the plane of the flow and the direction across it.
struct SectionMotion {
    double plunge = 0.0, twist = 0.0, residual = 0.0;
};

SectionMotion fitSection(const std::vector<Vec3>& positions, const std::vector<Vec3>& displacements, int flowAxis, int liftAxis, double centroidFlow) {
    // w(x) ≈ plunge + twist·(x − x_c): a straight line through the section's vertical displacement.
    double sumX = 0.0, sumXX = 0.0, sumW = 0.0, sumXW = 0.0;
    const double count = static_cast<double>(positions.size());
    for (std::size_t i = 0; i < positions.size(); ++i) {
        const double x = axisOf(positions[i], flowAxis) - centroidFlow;
        const double w = axisOf(displacements[i], liftAxis);
        sumX += x, sumXX += x * x, sumW += w, sumXW += x * w;
    }
    SectionMotion motion;
    const double determinant = count * sumXX - sumX * sumX;
    if (std::fabs(determinant) < 1e-30) return motion;
    motion.plunge = (sumXX * sumW - sumX * sumXW) / determinant;
    const double slope = (count * sumXW - sumX * sumW) / determinant;
    // A positive twist is nose up: the leading edge rises, so the slope of w against x is negative.
    motion.twist = -slope;
    double residual = 0.0, scale = 0.0;
    for (std::size_t i = 0; i < positions.size(); ++i) {
        const double x = axisOf(positions[i], flowAxis) - centroidFlow;
        const double w = axisOf(displacements[i], liftAxis);
        const double fitted = motion.plunge + slope * x;
        residual += (w - fitted) * (w - fitted);
        scale += w * w;
    }
    motion.residual = scale > 0.0 ? std::sqrt(residual / scale) : 0.0;
    return motion;
}

} // namespace

Result<FlutterStudyResult> runFlutterStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                           const std::string& loadCaseName, const FlutterStudySettings& settings,
                                           const StructuralStudyProgress& progress) {
    if (!(settings.coarseElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер грубой сетки");
    if (!(settings.refinementFactor >= 1.3)) return failure(ErrorCode::InvalidArgument, "измельчение должно быть не меньше 1.3");
    if (settings.flowAxis == settings.spanAxis) return failure(ErrorCode::InvalidArgument, "ось потока и ось размаха должны различаться");
    if (settings.stations < 4) return failure(ErrorCode::InvalidArgument, "нужно не меньше четырёх полос по размаху");
    if (!(settings.airDensityKgM3 > 0.0)) return failure(ErrorCode::InvalidArgument, "не задана плотность воздуха");
    if (!(settings.highSpeedMps > settings.lowSpeedMps) || settings.speeds < 10) return failure(ErrorCode::InvalidArgument, "развёртка по скорости не задана");

    FlutterStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    const int liftAxis = 3 - settings.flowAxis - settings.spanAxis;

    struct Level {
        double bending = 0.0, torsion = 0.0, speed = 0.0, frequency = 0.0, divergence = 0.0;
        std::size_t elements = 0;
        double elementSize = 0.0;
        std::vector<FlutterStrip> strips;
        std::vector<FlutterPoint> branches;
        int bendingMode = -1, torsionMode = -1;
        double referenceSemichord = 0.0, span = 0.0;
        bool found = false;
        std::vector<std::string> warnings;
    };

    auto runLevel = [&](double elementSize, Level& level, TetMesh* keepMesh, std::vector<Vec3>* keepBending,
                        std::vector<Vec3>* keepTorsion) -> Result<int> {
        SolidMeshingSettings meshing;
        meshing.maximumElementSizeM = elementSize;
        const auto meshed = meshSolid(kernel, shape, meshing);
        if (!meshed.isOk()) return Result<int>::fail(meshed.error());
        const TetMesh& mesh = meshed.value().mesh;
        result.mesherVersion = meshed.value().mesherVersion;
        level.elements = mesh.elements.size();
        level.elementSize = elementSize;

        ModalProblem problem;
        problem.mesh = &mesh;
        problem.material = material;
        problem.modeCount = 6;
        for (const auto& support : settings.supports) {
            if (mesh.faceGroups.count(support.face) == 0) return Result<int>::fail({ErrorCode::NotFound, "нет грани " + support.face + " (опора)"});
            DisplacementConstraint constraint;
            constraint.nodes = mesh.nodesOnGroup(support.face);
            for (int axis = 0; axis < 3; ++axis)
                if (support.fixed[axis]) constraint.value[axis] = 0.0;
            problem.constraints.push_back(std::move(constraint));
        }
        if (problem.constraints.empty()) return Result<int>::fail({ErrorCode::InvalidArgument, "нет опор: флаттер консоли считается с закреплённым корнем"});
        // A thin plate's modes come in close pairs and the subspace needs room to separate them.
        ModalSettings modalSettings;
        modalSettings.maximumIterations = 1000;
        const auto modal = solveModal(problem, modalSettings);
        if (!modal.isOk()) return Result<int>::fail(modal.error());

        // Where the part is, along the span and across the flow.
        double spanLow = 1e300, spanHigh = -1e300;
        for (const auto& node : mesh.nodes) {
            spanLow = std::min(spanLow, axisOf(node, settings.spanAxis));
            spanHigh = std::max(spanHigh, axisOf(node, settings.spanAxis));
        }
        level.span = spanHigh - spanLow;
        if (!(level.span > 0.0)) return Result<int>::fail({ErrorCode::InvalidArgument, "деталь не имеет размаха вдоль заданной оси"});

        // Every mode, read along the span as plunge and twist.
        const int modeCount = static_cast<int>(modal.value().modes.size());
        std::vector<std::vector<SectionMotion>> motions(modeCount);
        std::vector<FlutterStrip> strips(settings.stations);
        const double width = level.span / settings.stations;
        for (int s = 0; s < settings.stations; ++s) {
            const double centre = spanLow + (s + 0.5) * width;
            std::vector<int> nodes;
            for (std::size_t n = 0; n < mesh.nodes.size(); ++n) {
                if (std::fabs(axisOf(mesh.nodes[n], settings.spanAxis) - centre) <= 0.5 * width) nodes.push_back(static_cast<int>(n));
            }
            if (nodes.size() < 4) return Result<int>::fail({ErrorCode::NotFound, "в полосе на " + format(centre, 3) + " м слишком мало узлов"});
            std::vector<Vec3> positions;
            double low = 1e300, high = -1e300, centroid = 0.0;
            for (int n : nodes) {
                positions.push_back(mesh.nodes[n]);
                const double x = axisOf(mesh.nodes[n], settings.flowAxis);
                low = std::min(low, x), high = std::max(high, x);
                centroid += x;
            }
            centroid /= static_cast<double>(nodes.size());
            FlutterStrip& strip = strips[static_cast<std::size_t>(s)];
            strip.spanPositionM = centre;
            strip.chordM = high - low;
            strip.semichordM = 0.5 * strip.chordM;
            strip.widthM = width;
            // The reference point of the fit is the section's centroid; `a` says where that sits.
            strip.elasticAxis = strip.semichordM > 0.0 ? (centroid - 0.5 * (low + high)) / strip.semichordM : 0.0;
            for (int mode = 0; mode < modeCount; ++mode) {
                std::vector<Vec3> displacements;
                for (int n : nodes) displacements.push_back(modal.value().modes[static_cast<std::size_t>(mode)].shape[static_cast<std::size_t>(n)]);
                motions[static_cast<std::size_t>(mode)].push_back(fitSection(positions, displacements, settings.flowAxis, liftAxis, centroid));
            }
        }

        // Which mode is bending and which is torsion: the one whose motion is mostly plunge, and the
        // one whose motion is mostly twist, weighted by the strips' semichords so that both are
        // lengths and can be compared.
        int bending = -1, torsion = -1;
        double bendingScore = 0.0, torsionScore = 0.0;
        for (int mode = 0; mode < modeCount; ++mode) {
            double plunge = 0.0, twist = 0.0;
            for (int s = 0; s < settings.stations; ++s) {
                const auto& motion = motions[static_cast<std::size_t>(mode)][static_cast<std::size_t>(s)];
                plunge += motion.plunge * motion.plunge * strips[static_cast<std::size_t>(s)].widthM;
                twist += std::pow(motion.twist * strips[static_cast<std::size_t>(s)].semichordM, 2.0) * strips[static_cast<std::size_t>(s)].widthM;
            }
            const double share = plunge + twist > 0.0 ? twist / (plunge + twist) : 0.0;
            if (share < 0.5 && (bending < 0 || plunge > bendingScore)) bending = mode, bendingScore = plunge;
            if (share >= 0.5 && (torsion < 0 || twist > torsionScore)) torsion = mode, torsionScore = twist;
            if (bending >= 0 && torsion >= 0) break;
        }
        if (bending < 0 || torsion < 0) {
            return Result<int>::fail({ErrorCode::NotFound, "среди первых мод нет пары изгиб + кручение: деталь не ведёт себя как несущая поверхность"});
        }
        level.bendingMode = bending, level.torsionMode = torsion;
        level.bending = modal.value().modes[static_cast<std::size_t>(bending)].frequencyHz;
        level.torsion = modal.value().modes[static_cast<std::size_t>(torsion)].frequencyHz;
        double reference = 0.0;
        for (int s = 0; s < settings.stations; ++s) {
            FlutterStrip& strip = strips[static_cast<std::size_t>(s)];
            strip.plunge[0] = motions[static_cast<std::size_t>(bending)][static_cast<std::size_t>(s)].plunge;
            strip.twist[0] = motions[static_cast<std::size_t>(bending)][static_cast<std::size_t>(s)].twist;
            strip.plunge[1] = motions[static_cast<std::size_t>(torsion)][static_cast<std::size_t>(s)].plunge;
            strip.twist[1] = motions[static_cast<std::size_t>(torsion)][static_cast<std::size_t>(s)].twist;
            reference += strip.semichordM * strip.widthM;
        }
        level.referenceSemichord = level.span > 0.0 ? reference / level.span : 0.0;
        level.strips = strips;

        // The generalized aerodynamics: every strip's Theodorsen forces, integrated against the two
        // modes. Q_ij = ∫ [h_i, α_i] · B · [h_j, α_j]ᵀ dy, in the convention of Aeroelasticity.hpp.
        const double rho = settings.airDensityKgM3;
        auto generalized = [strips, rho, stations = settings.stations](double k, double speed, std::complex<double>* matrix) {
            for (int i = 0; i < 4; ++i) matrix[i] = 0.0;
            for (int s = 0; s < stations; ++s) {
                const FlutterStrip& strip = strips[static_cast<std::size_t>(s)];
                if (!(strip.semichordM > 0.0)) continue;
                TypicalSection section;
                section.semichordM = strip.semichordM;
                section.elasticAxis = strip.elasticAxis;
                section.airDensityKgM3 = rho;
                // The strip's own reduced frequency: the same ω, its own semichord.
                const double localK = speed > 0.0 ? k * strip.semichordM / strip.semichordM : k;
                const std::complex<double> C = theodorsen(localK);
                const double b = strip.semichordM, a = strip.elasticAxis;
                const double omega = localK * speed / b;
                const std::complex<double> im(0.0, 1.0);
                const std::complex<double> lh = -M_PI * rho * b * b * omega * omega + 2.0 * M_PI * rho * speed * b * C * im * omega;
                const std::complex<double> la = M_PI * rho * b * b * (im * omega * speed + a * b * omega * omega)
                                                + 2.0 * M_PI * rho * speed * b * C * (speed + im * omega * b * (0.5 - a));
                const std::complex<double> mh = -M_PI * rho * b * b * b * a * omega * omega + 2.0 * M_PI * rho * speed * b * b * (a + 0.5) * C * im * omega;
                const std::complex<double> ma = M_PI * rho * b * b * (-speed * b * (0.5 - a) * im * omega + b * b * (0.125 + a * a) * omega * omega)
                                                + 2.0 * M_PI * rho * speed * b * b * (a + 0.5) * C * (speed + im * omega * b * (0.5 - a));
                for (int i = 0; i < 2; ++i) {
                    for (int j = 0; j < 2; ++j) {
                        const std::complex<double> force = lh * strip.plunge[j] + la * strip.twist[j];
                        const std::complex<double> moment = mh * strip.plunge[j] + ma * strip.twist[j];
                        matrix[i * 2 + j] += (strip.plunge[i] * force - strip.twist[i] * moment) * strip.widthM;
                    }
                }
            }
        };

        GeneralizedFlutterSystem system;
        system.frequencyRadS[0] = 2.0 * M_PI * level.bending;
        system.frequencyRadS[1] = 2.0 * M_PI * level.torsion;
        system.structuralDamping = settings.structuralDamping;
        system.referenceSemichordM = level.referenceSemichord;
        system.aerodynamics = generalized;
        system.steadyAerodynamics = [generalized](double speed, std::complex<double>* matrix) { generalized(1e-9, speed, matrix); };
        FlutterSweep sweep;
        sweep.lowSpeedMps = settings.lowSpeedMps;
        sweep.highSpeedMps = settings.highSpeedMps;
        sweep.speeds = settings.speeds;
        const auto solved = solveFlutterGeneralized(system, sweep);
        if (!solved.isOk()) return Result<int>::fail(solved.error());
        level.found = solved.value().flutterFound;
        level.speed = solved.value().flutterSpeedMps;
        level.frequency = solved.value().flutterFrequencyHz;
        level.divergence = solved.value().divergenceFoundMps;
        level.branches = solved.value().branches;
        level.warnings = solved.value().warnings;
        if (keepMesh != nullptr) {
            *keepMesh = mesh;
            keepBending->assign(modal.value().modes[static_cast<std::size_t>(bending)].shape.begin(),
                                modal.value().modes[static_cast<std::size_t>(bending)].shape.end());
            keepTorsion->assign(modal.value().modes[static_cast<std::size_t>(torsion)].shape.begin(),
                                modal.value().modes[static_cast<std::size_t>(torsion)].shape.end());
        }
        return Result<int>::ok(0);
    };

    std::vector<Level> levels;
    TetMesh finestMesh;
    std::vector<Vec3> bendingShape, torsionShape;
    for (int level = 0; level < 3; ++level) {
        if (progress) progress(level, "solve");
        const double size = settings.coarseElementSizeM / std::pow(settings.refinementFactor, level);
        Level record;
        const auto ran = runLevel(size, record, level == 2 ? &finestMesh : nullptr, level == 2 ? &bendingShape : nullptr,
                                  level == 2 ? &torsionShape : nullptr);
        if (!ran.isOk()) return failure(ran.error().code, ran.error().message);
        levels.push_back(std::move(record));
    }
    const Level& finest = levels.back();
    result.bendingHz = finest.bending;
    result.torsionHz = finest.torsion;
    result.bendingMode = finest.bendingMode;
    result.torsionMode = finest.torsionMode;
    result.flutterFound = finest.found;
    result.flutterSpeedMps = finest.speed;
    result.flutterFrequencyHz = finest.frequency;
    result.divergenceSpeedMps = finest.divergence;
    result.strips = finest.strips;
    result.branches = finest.branches;
    result.spanM = finest.span;
    result.referenceSemichordM = finest.referenceSemichord;
    for (const auto& warning : finest.warnings) result.warnings.push_back(warning);
    for (const auto& level : levels) {
        FlutterLevel record;
        record.maximumElementSizeM = level.elementSize;
        record.elements = level.elements;
        record.bendingHz = level.bending;
        record.torsionHz = level.torsion;
        record.flutterSpeedMps = level.speed;
        record.flutterFrequencyHz = level.frequency;
        result.levels.push_back(record);
    }
    const double r21 = std::cbrt(static_cast<double>(levels[2].elements) / static_cast<double>(levels[1].elements));
    const double r32 = std::cbrt(static_cast<double>(levels[1].elements) / static_cast<double>(levels[0].elements));
    result.speedConvergence = estimateConvergence(levels[2].speed, levels[1].speed, levels[0].speed, r21, r32, 1.25, 2.0);
    result.flutterUncertaintyMps = result.speedConvergence.isUsable()
                                       ? result.speedConvergence.uncertaintyAbsolute
                                       : std::max({levels[0].speed, levels[1].speed, levels[2].speed})
                                             - std::min({levels[0].speed, levels[1].speed, levels[2].speed});

    auto report = [&](StrengthVerdict verdict, const std::string& reason) {
        result.verdict = worse(result.verdict, verdict);
        (verdict == StrengthVerdict::Fail ? result.failureReasons : result.reasons).push_back(reason);
    };
    result.verdict = StrengthVerdict::Pass;
    result.requiredSpeedMps = settings.diveSpeedMps > 0.0 ? settings.marginFactor * settings.diveSpeedMps : 0.0;
    if (result.requiredSpeedMps > 0.0) {
        const double lowest = result.flutterFound ? result.flutterSpeedMps - result.flutterUncertaintyMps : settings.highSpeedMps;
        const double limiting = result.divergenceSpeedMps > 0.0 && (!result.flutterFound || result.divergenceSpeedMps < result.flutterSpeedMps)
                                    ? result.divergenceSpeedMps
                                    : result.flutterSpeedMps;
        result.marginFraction = result.flutterFound || result.divergenceSpeedMps > 0.0 ? limiting / result.requiredSpeedMps - 1.0 : 0.0;
        if ((result.flutterFound && result.flutterSpeedMps < result.requiredSpeedMps)
            || (result.divergenceSpeedMps > 0.0 && result.divergenceSpeedMps < result.requiredSpeedMps)) {
            report(StrengthVerdict::Fail, "неустойчивость на " + format(limiting, 1) + " м/с против требуемых " + format(result.requiredSpeedMps, 1)
                                              + " м/с (1.15·V_D)");
        } else if (result.flutterFound && lowest < result.requiredSpeedMps) {
            report(StrengthVerdict::Warning, "флаттер на " + format(result.flutterSpeedMps, 1) + " м/с, но в пределах погрешности сетки ("
                                                 + format(result.flutterUncertaintyMps, 1) + " м/с) достаёт до требуемых "
                                                 + format(result.requiredSpeedMps, 1) + " м/с");
        }
    } else {
        report(StrengthVerdict::Warning, "нет данных: скорость пикирования V_D не задана, сравнивать не с чем");
    }
    if (!result.flutterFound && result.divergenceSpeedMps <= 0.0) {
        report(StrengthVerdict::Warning, "в развёртке до " + format(settings.highSpeedMps, 0) + " м/с неустойчивости нет: это не значит, что её нет вообще");
    }
    const double speedOfSound = std::sqrt(1.4 * kAirGasConstant * 288.15);
    result.machAtFlutter = result.flutterFound ? result.flutterSpeedMps / speedOfSound : 0.0;
    if (result.machAtFlutter > 0.6) {
        report(StrengthVerdict::Warning, "флаттер приходится на M = " + format(result.machAtFlutter, 2)
                                             + ": аэродинамика Теодорсена несжимаема, трансзвуковой провал она не видит");
    }
    if (result.torsionHz > 0.0 && result.bendingHz / result.torsionHz > 0.9) {
        result.warnings.push_back("частоты изгиба и кручения сошлись ближе 10 %: пара очень чувствительна, шаг сетки здесь решает");
    }
    result.warnings.push_back("полосовая теория: ни стреловидности, ни удлинения, ни концевых эффектов");
    result.warnings.push_back("только две моды: руль, груз или третья мода рядом по частоте в модель не входят");
    result.warnings.push_back("аэродинамика несжимаемая: выше M ≈ 0.6 метод не о том");

    // The surface, carrying the two mode shapes.
    std::unordered_map<int, int> fieldIndex;
    double bendingScale = 0.0, torsionScale = 0.0;
    for (const auto& value : bendingShape) bendingScale = std::max(bendingScale, length(value));
    for (const auto& value : torsionShape) torsionScale = std::max(torsionScale, length(value));
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(finestMesh.nodes[meshNode]);
        // The shape a viewer draws is the torsion mode: it is the one that couples with the bending
        // to flutter, and seeing it twisted is the point of the picture. It is scaled to a hundredth
        // of the span so that the deformation slider has something sensible to multiply.
        const Vec3 shape = torsionShape[static_cast<std::size_t>(meshNode)];
        const double scale = torsionScale > 0.0 ? 0.01 * result.spanM / torsionScale : 0.0;
        result.field.displacement.push_back({shape.x * scale, shape.y * scale, shape.z * scale});
        result.field.vonMisesPa.push_back(0.0);
        result.fieldBending.push_back(bendingScale > 0.0 ? length(bendingShape[static_cast<std::size_t>(meshNode)]) / bendingScale : 0.0);
        result.fieldTorsion.push_back(torsionScale > 0.0 ? length(torsionShape[static_cast<std::size_t>(meshNode)]) / torsionScale : 0.0);
        fieldIndex.emplace(meshNode, index);
        return index;
    };
    for (const auto& [name, faces] : finestMesh.faceGroups) {
        for (const auto& face : faces) {
            const auto nodes = finestMesh.faceNodes(face);
            std::vector<int> f;
            for (int node : nodes) f.push_back(fieldNode(node));
            if (f.size() == 6) {
                result.field.triangles.push_back({f[0], f[3], f[5]});
                result.field.triangles.push_back({f[3], f[1], f[4]});
                result.field.triangles.push_back({f[5], f[4], f[2]});
                result.field.triangles.push_back({f[3], f[4], f[5]});
                for (int k = 0; k < 4; ++k) result.field.triangleFace.push_back(name);
            } else if (f.size() >= 3) {
                result.field.triangles.push_back({f[0], f[1], f[2]});
                result.field.triangleFace.push_back(name);
            }
        }
    }
    return Result<FlutterStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
