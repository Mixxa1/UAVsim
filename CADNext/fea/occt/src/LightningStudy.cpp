#include "cadnext/fea/LightningStudy.hpp"

#include "cadnext/fea/LinearStatic.hpp" // faceGroupArea
#include "cadnext/fea/SolidMesher.hpp"
#include "cadnext/fea/Thermal.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <set>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<LightningStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<LightningStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

std::string celsius(double kelvin) {
    return format(kelvin - 273.15, 1) + " °C";
}

struct Setup {
    const TetMesh* mesh = nullptr;
    std::vector<std::string> attachment, ground, cooled;
    std::vector<std::vector<int>> equipmentNodes;
    double attachmentAreaM2 = 0.0;
};

struct Run {
    double peakK = 0.0;
    int peakNode = -1;
    double burnThroughTimeS = -1.0;
    std::vector<double> equipmentMaxK, equipmentMaxTimeS;
    LightningSeries series;
    std::vector<double> finalField;
};

double faceMaximum(const std::vector<double>& T, const std::vector<int>& nodes) {
    double value = -std::numeric_limits<double>::infinity();
    for (int n : nodes) value = std::max(value, T[n]);
    return value;
}

StrengthVerdict worse(StrengthVerdict a, StrengthVerdict b) {
    return static_cast<int>(a) > static_cast<int>(b) ? a : b;
}

double bandOf(const ConvergenceEstimate& estimate, double fine, double medium, double coarse) {
    return estimate.isUsable() ? estimate.uncertaintyAbsolute : std::max({fine, medium, coarse}) - std::min({fine, medium, coarse});
}

// One strike on one mesh: the components in order, each with its own step, the field carried across.
Result<Run> strike(const Setup& setup, const HotMaterial& hot, const LightningStudySettings& settings, const std::vector<CurrentWaveform>& waveforms,
                   const std::vector<double>& jouleAtOneAmp, double voltsPerAmp, int stepsPerComponent) {
    using R = Result<Run>;
    Run run;
    const std::size_t equipment = setup.equipmentNodes.size();
    run.equipmentMaxK.assign(equipment, kLaboratoryK);
    run.equipmentMaxTimeS.assign(equipment, 0.0);
    run.series.equipmentMaximumK.assign(equipment, {kLaboratoryK});
    run.series.timeS = {0.0};
    run.series.currentA = {0.0};
    run.series.partMaximumK = {kLaboratoryK};
    run.peakK = kLaboratoryK;
    std::vector<double> field(setup.mesh->nodes.size(), kLaboratoryK);
    double clock = 0.0;
    for (const auto& waveform : waveforms) {
        ThermalProblem problem;
        problem.mesh = setup.mesh;
        problem.material.densityKgM3 = hot.densityKgM3;
        problem.material.conductivityOf = hot.conductivityWmK;
        problem.material.specificHeatOf = hot.specificHeatJkgK;
        problem.volumetricHeatPerElementWm3 = jouleAtOneAmp; // scaled by i² in time
        for (const auto& face : setup.attachment) problem.fluxes.push_back({face, voltsPerAmp / setup.attachmentAreaM2}); // scaled by i
        for (const auto& face : setup.cooled) {
            problem.convection.push_back({face, kUnexposedConvectionWm2K, kLaboratoryK});
            problem.radiation.push_back({face, settings.surfaceEmissivity, kLaboratoryK});
        }
        TransientSettings transient;
        transient.stepS = waveform.durationS() / stepsPerComponent;
        transient.endS = waveform.durationS();
        transient.initialFieldK = field;
        transient.schedule.fluxScale = [&](double t) { return waveform.at(t); };
        transient.schedule.volumetricScale = [&](double t) { return waveform.at(t) * waveform.at(t); };
        const double start = clock;
        const double step = transient.stepS;
        double previousHottest = *std::max_element(field.begin(), field.end());
        std::vector<double> previousField = field;
        bool holed = false;
        const auto solved = solveTransientThermal(problem, transient, std::numeric_limits<int>::max(), [&](double t, const std::vector<double>& computed) {
            // Past the loss of strength the metal melts and the arc blows it away, which is not modelled:
            // the run stops at the crossing, cut back to the instant of it.
            const double hottest = *std::max_element(computed.begin(), computed.end());
            const bool crosses = hot.noStrengthK && hottest >= *hot.noStrengthK;
            std::vector<double> blended;
            const std::vector<double>* T = &computed;
            double time = start + t;
            if (crosses) {
                const double w = (*hot.noStrengthK - previousHottest) / (hottest - previousHottest);
                blended.resize(computed.size());
                for (std::size_t n = 0; n < computed.size(); ++n) blended[n] = previousField[n] + w * (computed[n] - previousField[n]);
                T = &blended;
                time = start + t - step + w * step;
            }
            const double top = *std::max_element(T->begin(), T->end());
            run.series.timeS.push_back(time);
            run.series.currentA.push_back(waveform.at(time - start));
            run.series.partMaximumK.push_back(top);
            for (std::size_t e = 0; e < equipment; ++e) {
                const double value = faceMaximum(*T, setup.equipmentNodes[e]);
                run.series.equipmentMaximumK[e].push_back(value);
                if (value > run.equipmentMaxK[e]) run.equipmentMaxK[e] = value, run.equipmentMaxTimeS[e] = time;
            }
            if (top > run.peakK) run.peakK = top, run.peakNode = static_cast<int>(std::max_element(T->begin(), T->end()) - T->begin());
            field = *T;
            if (crosses) {
                run.burnThroughTimeS = time;
                holed = true;
                return false;
            }
            previousHottest = hottest;
            previousField = computed;
            return true;
        });
        if (!solved.isOk()) return R::fail(solved.error());
        clock += waveform.durationS();
        if (holed) break;
    }
    run.finalField = field;
    return R::ok(std::move(run));
}

} // namespace

Result<LightningStudyResult> runLightningStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                               const std::string& loadCaseName, const LightningStudySettings& settings,
                                               const StructuralStudyProgress& progress) {
    if (!(settings.coarseElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер элемента грубой сетки");
    if (!(settings.refinementFactor >= 1.3)) {
        return failure(ErrorCode::InvalidArgument, "коэффициент измельчения должен быть не меньше 1.3 (Celik et al. 2008), иначе разница сеток тонет в шуме");
    }
    if (settings.components.empty()) return failure(ErrorCode::InvalidArgument, "не заданы компоненты тока (A, B, C, D по ARP5412)");
    if (settings.attachmentFaces.empty()) return failure(ErrorCode::InvalidArgument, "не заданы грани привязки дуги");
    if (settings.groundFaces.empty()) return failure(ErrorCode::InvalidArgument, "не заданы грани отвода тока (металлизация)");
    if (!(settings.surfaceEmissivity > 0.0 && settings.surfaceEmissivity <= 1.0)) {
        return failure(ErrorCode::InvalidArgument, "не задана излучательная способность поверхности (EN 1999-1-2: 0.3 чистая, 0.7 окрашенная)");
    }
    if (settings.stepsPerComponent < 20) return failure(ErrorCode::InvalidArgument, "шагов на компоненту должно быть не меньше 20");
    if (!material.electricalResistivityOhmM) {
        return failure(ErrorCode::InvalidArgument, "нет данных: удельное электрическое сопротивление материала «" + material.displayName + "»");
    }
    const auto hot = hotMaterial(material.id);
    if (!hot) {
        return failure(ErrorCode::InvalidArgument, "нет данных: свойства материала «" + material.displayName + "» при нагреве (EN 1999-1-2: алюминий 6061-T6, 7075-T6)");
    }
    if (settings.continuingCurrentA < 200.0 || settings.continuingCurrentA > 800.0) {
        return failure(ErrorCode::InvalidArgument, "ток компоненты C по ARP5412: от 200 до 800 А");
    }

    LightningStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.hotMaterialSource = hot->source;
    result.noStrengthK = hot->noStrengthK;
    result.arcVoltsPerAmp = settings.polarity == ArcPolarity::Anode ? kAnodeVoltsPerCurrent : kCathodeVoltsPerCurrent;
    for (auto component : settings.components) {
        auto waveform = lightningComponent(component);
        if (component == LightningComponent::C) {
            waveform.steadyA = settings.continuingCurrentA;
            waveform.steadyDurationS = 200.0 / settings.continuingCurrentA; // the standard's 200 C at this current
        }
        result.totalChargeC += waveform.chargeC();
        result.totalActionIntegralA2s += waveform.actionIntegralA2s();
        result.peakCurrentA = std::max(result.peakCurrentA, waveform.peakA());
        result.waveforms.push_back(std::move(waveform));
    }
    result.arcEnergyJ = result.arcVoltsPerAmp * result.totalChargeC;

    std::vector<Run> runs;
    double timeErrorK = 0.0;
    TetMesh finestMesh;
    for (int level = 0; level < 3; ++level) {
        const double size = settings.coarseElementSizeM / std::pow(settings.refinementFactor, level);
        if (progress) progress(level, "mesh");
        SolidMeshingSettings meshing;
        meshing.maximumElementSizeM = size;
        auto meshed = meshSolid(kernel, shape, meshing);
        if (!meshed.isOk()) return failure(meshed.error().code, meshed.error().message);
        SolidMesh solid = meshed.value();
        result.mesherVersion = solid.mesherVersion;
        TetMesh& mesh = solid.mesh;
        auto requireFace = [&](const std::string& face) { return mesh.faceGroups.count(face) > 0; };

        Setup setup;
        setup.mesh = &mesh;
        std::set<std::string> attachment(settings.attachmentFaces.begin(), settings.attachmentFaces.end());
        std::set<std::string> ground(settings.groundFaces.begin(), settings.groundFaces.end()), covered;
        for (const auto& face : attachment) {
            if (!requireFace(face)) return failure(ErrorCode::NotFound, "нет грани " + face + " (привязка дуги)");
            if (ground.count(face)) return failure(ErrorCode::InvalidArgument, "грань " + face + " одновременно привязка дуги и отвод тока");
            setup.attachmentAreaM2 += faceGroupArea(mesh, face);
        }
        for (const auto& face : ground)
            if (!requireFace(face)) return failure(ErrorCode::NotFound, "нет грани " + face + " (отвод тока)");
        for (const auto& component : settings.equipment) {
            if (!requireFace(component.face)) return failure(ErrorCode::NotFound, "нет грани " + component.face + " (оборудование " + component.name + ")");
            covered.insert(component.face);
            setup.equipmentNodes.push_back(mesh.nodesOnGroup(component.face));
        }
        setup.attachment.assign(attachment.begin(), attachment.end());
        setup.ground.assign(ground.begin(), ground.end());
        for (const auto& [name, faces] : mesh.faceGroups)
            if (!attachment.count(name) && !covered.count(name)) setup.cooled.push_back(name);
        if (!(setup.attachmentAreaM2 > 0.0)) return failure(ErrorCode::InvalidArgument, "нулевая площадь привязки дуги");

        if (progress) progress(level, "solve");
        // The spread is linear in the current: solve it once at one ampere and scale in time.
        const auto spread = solveCurrentSpread(mesh, *material.electricalResistivityOhmM, setup.attachment, setup.ground, 1.0);
        if (!spread.isOk()) return failure(spread.error().code, spread.error().message);
        auto run = strike(setup, *hot, settings, result.waveforms, spread.value().jouleWm3, result.arcVoltsPerAmp, settings.stepsPerComponent);
        if (!run.isOk()) return failure(run.error().code, run.error().message);
        if (level == 0) {
            auto half = strike(setup, *hot, settings, result.waveforms, spread.value().jouleWm3, result.arcVoltsPerAmp, 2 * settings.stepsPerComponent);
            if (!half.isOk()) return failure(half.error().code, half.error().message);
            timeErrorK = std::fabs(run.value().peakK - half.value().peakK) / 3.0;
            for (std::size_t e = 0; e < run.value().equipmentMaxK.size(); ++e) {
                timeErrorK = std::max(timeErrorK, std::fabs(run.value().equipmentMaxK[e] - half.value().equipmentMaxK[e]) / 3.0);
            }
        }
        LightningLevel record;
        record.maximumElementSizeM = size;
        record.elements = mesh.elements.size();
        record.peakK = run.value().peakK;
        record.burnThroughTimeS = run.value().burnThroughTimeS;
        record.resistanceOhm = spread.value().resistanceOhm;
        if (level > 0 && record.elements <= result.levels.back().elements) {
            return failure(ErrorCode::KernelOperationFailed, "сетка не измельчилась между уровнями — деталь уже упирается в размер своих граней, увеличьте начальный размер");
        }
        result.levels.push_back(record);
        if (level == 2) {
            result.attachmentAreaM2 = setup.attachmentAreaM2;
            result.arcRootRadiusM = std::sqrt(setup.attachmentAreaM2 / M_PI);
            result.resistanceOhm = spread.value().resistanceOhm;
            result.jouleEnergyJ = spread.value().resistanceOhm * result.totalActionIntegralA2s;
            double peakDensity = 0.0;
            for (double joule : spread.value().jouleWm3) {
                peakDensity = std::max(peakDensity, std::sqrt(joule / *material.electricalResistivityOhmM));
            }
            result.peakCurrentDensityAm2 = peakDensity * result.peakCurrentA;
            result.fieldPotentialV = spread.value().potentialV;
            finestMesh = std::move(mesh);
        }
        runs.push_back(std::move(run.value()));
    }

    const auto& coarse = result.levels[0];
    const auto& medium = result.levels[1];
    const auto& fine = result.levels[2];
    const double r21 = std::cbrt(static_cast<double>(fine.elements) / static_cast<double>(medium.elements));
    const double r32 = std::cbrt(static_cast<double>(medium.elements) / static_cast<double>(coarse.elements));
    result.peakConvergence = estimateConvergence(fine.peakK, medium.peakK, coarse.peakK, r21, r32, 1.25, kTet10DisplacementOrder);
    result.timeStepErrorK = timeErrorK;
    result.peakK = fine.peakK;
    result.peakUncertaintyK = bandOf(result.peakConvergence, fine.peakK, medium.peakK, coarse.peakK) + timeErrorK;
    const Run& finest = runs[2];
    if (finest.peakNode >= 0) result.hottestPoint = finestMesh.nodes[finest.peakNode];
    result.burnedThrough = finest.burnThroughTimeS >= 0.0;
    result.burnThroughTimeS = finest.burnThroughTimeS;
    if (coarse.burnThroughTimeS >= 0.0 && medium.burnThroughTimeS >= 0.0 && fine.burnThroughTimeS >= 0.0) {
        result.burnThroughConvergence = estimateConvergence(fine.burnThroughTimeS, medium.burnThroughTimeS, coarse.burnThroughTimeS, r21, r32, 1.25,
                                                            kTet10DisplacementOrder);
        result.burnThroughUncertaintyS = bandOf(result.burnThroughConvergence, fine.burnThroughTimeS, medium.burnThroughTimeS, coarse.burnThroughTimeS);
    }
    result.series = finest.series;

    // --- Verdict.
    StrengthVerdict verdict = StrengthVerdict::Pass;
    auto report = [&](StrengthVerdict v, const std::string& text) {
        verdict = worse(verdict, v);
        if (v == StrengthVerdict::Fail) result.failureReasons.push_back(text);
        else if (v == StrengthVerdict::Warning) result.reasons.push_back(text);
    };
    if (result.burnedThrough) {
        report(StrengthVerdict::Fail, "прожог: через " + format(result.burnThroughTimeS * 1e3, 2) + " ± " + format(result.burnThroughUncertaintyS * 1e3, 2)
                                          + " мс металл дошёл до " + celsius(*hot->noStrengthK) + ", где прочность по EN 1999-1-2 равна нулю");
    } else if (hot->noStrengthK) {
        if (result.peakK + result.peakUncertaintyK >= *hot->noStrengthK) {
            report(StrengthVerdict::Warning, "максимум " + celsius(result.peakK) + " в пределах погрешности от " + celsius(*hot->noStrengthK));
        }
    } else {
        report(StrengthVerdict::Warning, "нет данных: температура потери прочности материала «" + material.displayName + "»");
    }
    for (std::size_t e = 0; e < settings.equipment.size(); ++e) {
        const auto& component = settings.equipment[e];
        ClimateComponentResult out;
        out.name = component.name;
        out.face = component.face;
        out.maximumK = finest.equipmentMaxK[e];
        out.maximumTimeS = finest.equipmentMaxTimeS[e];
        out.minimumK = kLaboratoryK;
        out.maximumConvergence = estimateConvergence(runs[2].equipmentMaxK[e], runs[1].equipmentMaxK[e], runs[0].equipmentMaxK[e], r21, r32, 1.25,
                                                     kTet10DisplacementOrder);
        out.uncertaintyK = bandOf(out.maximumConvergence, runs[2].equipmentMaxK[e], runs[1].equipmentMaxK[e], runs[0].equipmentMaxK[e]) + timeErrorK;
        if (component.maximumK) out.checks.push_back(checkTemperature(out.maximumK, out.uncertaintyK, *component.maximumK, true));
        for (const auto& check : out.checks) {
            out.verdict = worse(out.verdict, check.verdict);
            if (check.verdict != StrengthVerdict::Pass) {
                report(check.verdict, component.name + ": максимум " + celsius(check.valueK) + " ± " + format(check.uncertaintyK, 2) + " K против предела "
                                          + celsius(check.limitK));
            }
        }
        if (out.checks.empty()) {
            out.verdict = StrengthVerdict::Warning;
            report(StrengthVerdict::Warning, "нет предела температуры у оборудования «" + component.name + "» — задайте по его паспорту");
        }
        result.equipment.push_back(std::move(out));
    }
    if (result.peakK > hot->dataValidUpToK) {
        report(StrengthVerdict::Warning, "максимум " + celsius(result.peakK) + " выше 500 °C — свойства EN 1999-1-2 там экстраполированы");
    }
    result.verdict = verdict;
    for (const auto& waveform : result.waveforms) result.warnings.push_back(waveform.source);
    result.warnings.push_back("тепло дуги " + format(result.arcVoltsPerAmp, 0) + " В·I на площади привязки (эквивалентный радиус "
                              + format(result.arcRootRadiusM * 1e3, 1) + " мм); плазма дуги не моделируется");
    result.warnings.push_back("энергия дуги " + format(result.arcEnergyJ, 0) + " Дж против джоулевой " + format(result.jouleEnergyJ, 1)
                              + " Дж (сопротивление " + format(result.resistanceOhm * 1e6, 2) + " мкОм)");
    result.warnings.push_back("сопротивление взято при 20 °C: с нагревом оно растёт, джоулев нагрев здесь занижен");
    if (result.burnedThrough) result.warnings.push_back("расчёт остановлен в момент прожога: плавление и унос металла дугой не моделируются");
    if (result.arcRootRadiusM > 0.01) {
        result.warnings.push_back("эквивалентный радиус привязки больше 10 мм — по измерениям корни дуг компонент A и D не превышают ~5 мм");
    }

    // --- Surface field.
    std::unordered_map<int, int> fieldIndex;
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(finestMesh.nodes[meshNode]);
        result.field.displacement.push_back({});
        result.field.vonMisesPa.push_back(0.0);
        result.fieldTemperatureK.push_back(finest.finalField.empty() ? kLaboratoryK : finest.finalField[meshNode]);
        fieldIndex.emplace(meshNode, index);
        return index;
    };
    std::vector<double> potential;
    for (const auto& [name, faces] : finestMesh.faceGroups) {
        for (const auto& face : faces) {
            const auto n = finestMesh.faceNodes(face);
            std::vector<int> f;
            for (int node : n) f.push_back(fieldNode(node));
            if (f.size() == 6) {
                result.field.triangles.push_back({f[0], f[3], f[5]});
                result.field.triangles.push_back({f[3], f[1], f[4]});
                result.field.triangles.push_back({f[5], f[4], f[2]});
                result.field.triangles.push_back({f[3], f[4], f[5]});
                for (int k = 0; k < 4; ++k) result.field.triangleFace.push_back(name);
            } else {
                result.field.triangles.push_back({f[0], f[1], f[2]});
                result.field.triangleFace.push_back(name);
            }
        }
    }
    potential.resize(result.field.nodes.size(), 0.0);
    for (const auto& [meshNode, index] : fieldIndex) potential[index] = result.fieldPotentialV.empty() ? 0.0 : result.fieldPotentialV[meshNode];
    result.fieldPotentialV = std::move(potential);
    return Result<LightningStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
