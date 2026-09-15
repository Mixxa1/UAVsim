#include "cadnext/fea/StructuralJob.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/StructuralPresentation.hpp"

#include <algorithm>
#include <cmath>
#include <filesystem>

namespace cadnext::fea {

namespace {

using json::JsonValue;

Result<StructuralJob> invalid(const std::string& message) {
    return Result<StructuralJob>::fail({ErrorCode::InvalidArgument, "задание: " + message});
}

bool readVector(const JsonValue* value, Vec3& out) {
    if (value == nullptr || !value->isArray() || value->arrayItems.size() != 3) return false;
    for (int i = 0; i < 3; ++i) {
        if (value->arrayItems[i].type != JsonValue::Type::Number) return false;
        out[i] = value->arrayItems[i].numberValue;
    }
    return true;
}

JsonValue vector(const Vec3& v) {
    JsonValue array = JsonValue::makeArray();
    for (int i = 0; i < 3; ++i) array.arrayItems.push_back(JsonValue::makeNumber(v[i]));
    return array;
}

JsonValue strings(const std::vector<std::string>& items) {
    JsonValue array = JsonValue::makeArray();
    for (const auto& item : items) array.arrayItems.push_back(JsonValue::makeString(item));
    return array;
}

// Non-finite values (the infinite margin of an unloaded part) are left out rather than written
// as a number: the JSON writer would turn them into 0, which reads as "no margin at all".
void putMetric(JsonValue& metrics, const std::string& name, double value, const std::string& unit,
               std::optional<double> uncertainty = std::nullopt) {
    if (!std::isfinite(value)) return;
    JsonValue metric = JsonValue::makeObject();
    metric.set("value", JsonValue::makeNumber(value));
    metric.set("unit", JsonValue::makeString(unit));
    if (uncertainty && std::isfinite(*uncertainty)) metric.set("numericalUncertainty", JsonValue::makeNumber(*uncertainty));
    metrics.set(name, std::move(metric));
}

JsonValue convergenceJson(const ConvergenceEstimate& estimate) {
    static const char* names[] = {"monotonic", "oscillatory", "divergent", "converged"};
    JsonValue object = JsonValue::makeObject();
    object.set("behaviour", JsonValue::makeString(names[static_cast<int>(estimate.behaviour)]));
    object.set("observedOrder", JsonValue::makeNumber(estimate.observedOrder));
    object.set("orderLimitedToFormal", JsonValue::makeBool(estimate.orderLimitedToFormal));
    object.set("extrapolated", JsonValue::makeNumber(estimate.extrapolated));
    object.set("gciFineRelative", JsonValue::makeNumber(estimate.gciFineRelative));
    object.set("asymptoticRatio", JsonValue::makeNumber(estimate.asymptoticRatio));
    return object;
}

JsonValue loadCaseJson(const StructuralLoadCase& loadCase) {
    JsonValue object = JsonValue::makeObject();
    object.set("name", JsonValue::makeString(loadCase.name));
    JsonValue supports = JsonValue::makeArray();
    for (const auto& support : loadCase.supports) {
        JsonValue item = JsonValue::makeObject();
        item.set("face", JsonValue::makeString(support.face));
        JsonValue fixed = JsonValue::makeArray();
        static const char* axes[] = {"x", "y", "z"};
        for (int c = 0; c < 3; ++c)
            if (support.fixed[c]) fixed.arrayItems.push_back(JsonValue::makeString(axes[c]));
        item.set("fix", std::move(fixed));
        supports.arrayItems.push_back(std::move(item));
    }
    object.set("supports", std::move(supports));
    JsonValue forces = JsonValue::makeArray();
    for (const auto& force : loadCase.forces) {
        JsonValue item = JsonValue::makeObject();
        item.set("face", JsonValue::makeString(force.face));
        item.set("totalForceN", vector(force.totalForceN));
        forces.arrayItems.push_back(std::move(item));
    }
    object.set("forces", std::move(forces));
    JsonValue pressures = JsonValue::makeArray();
    for (const auto& pressure : loadCase.pressures) {
        JsonValue item = JsonValue::makeObject();
        item.set("face", JsonValue::makeString(pressure.face));
        item.set("pressurePa", JsonValue::makeNumber(pressure.pressurePa));
        pressures.arrayItems.push_back(std::move(item));
    }
    object.set("pressures", std::move(pressures));
    object.set("bodyAccelerationMps2", vector(loadCase.bodyAccelerationMps2));
    JsonValue exclusions = JsonValue::makeArray();
    for (const auto& exclusion : loadCase.stressExclusions) {
        JsonValue item = JsonValue::makeObject();
        item.set("face", JsonValue::makeString(exclusion.face));
        item.set("distanceM", JsonValue::makeNumber(exclusion.distanceM));
        exclusions.arrayItems.push_back(std::move(item));
    }
    object.set("stressExclusions", std::move(exclusions));
    return object;
}

// Triangles as a flat index list, and the runs of triangles lying on one CAD face.
void putTriangles(JsonValue& root, const std::vector<std::array<int, 3>>& triangleList, const std::vector<std::string>& triangleFace) {
    JsonValue triangles = JsonValue::makeArray();
    JsonValue faceRanges = JsonValue::makeArray();
    for (std::size_t t = 0; t < triangleList.size(); ++t) {
        for (int c = 0; c < 3; ++c) triangles.arrayItems.push_back(JsonValue::makeNumber(triangleList[t][c]));
        if (t == 0 || triangleFace[t] != triangleFace[t - 1]) {
            JsonValue range = JsonValue::makeObject();
            range.set("face", JsonValue::makeString(triangleFace[t]));
            range.set("first", JsonValue::makeNumber(static_cast<double>(t)));
            range.set("count", JsonValue::makeNumber(0));
            faceRanges.arrayItems.push_back(std::move(range));
        }
        auto& count = faceRanges.arrayItems.back().objectMembers.back().second;
        count.numberValue += 1.0;
    }
    root.set("triangles", std::move(triangles));
    root.set("faceRanges", std::move(faceRanges));
}

JsonValue bandJson(const ExcitationBand& band) {
    JsonValue item = JsonValue::makeObject();
    item.set("name", JsonValue::makeString(band.name));
    item.set("minimumHz", JsonValue::makeNumber(band.minimumHz));
    item.set("maximumHz", JsonValue::makeNumber(band.maximumHz));
    return item;
}

JsonValue modalJobJson(const ModalJobSettings& modal) {
    JsonValue object = JsonValue::makeObject();
    object.set("modeCount", JsonValue::makeNumber(modal.modeCount));
    JsonValue rotors = JsonValue::makeArray();
    for (const auto& rotor : modal.rotors) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(rotor.name));
        item.set("minimumRpm", JsonValue::makeNumber(rotor.minimumRpm));
        item.set("maximumRpm", JsonValue::makeNumber(rotor.maximumRpm));
        item.set("bladeCount", JsonValue::makeNumber(rotor.bladeCount));
        rotors.arrayItems.push_back(std::move(item));
    }
    object.set("rotors", std::move(rotors));
    JsonValue bands = JsonValue::makeArray();
    for (const auto& band : modal.bands) bands.arrayItems.push_back(bandJson(band));
    object.set("bands", std::move(bands));
    object.set("separationMargin", JsonValue::makeNumber(modal.separationMargin));
    JsonValue masses = JsonValue::makeArray();
    for (const auto& mass : modal.attachedMasses) {
        JsonValue item = JsonValue::makeObject();
        item.set("face", JsonValue::makeString(mass.faceGroup));
        item.set("massKg", JsonValue::makeNumber(mass.massKg));
        masses.arrayItems.push_back(std::move(item));
    }
    object.set("attachedMasses", std::move(masses));
    return object;
}

JsonValue materialJson(const IsotropicMaterial& source) {
    JsonValue material = JsonValue::makeObject();
    material.set("id", JsonValue::makeString(source.id));
    material.set("youngsModulusPa", JsonValue::makeNumber(source.youngsModulusPa));
    material.set("poissonRatio", JsonValue::makeNumber(source.poissonRatio));
    material.set("densityKgPerM3", JsonValue::makeNumber(source.densityKgPerM3));
    if (source.yieldStrengthPa) material.set("yieldStrengthPa", JsonValue::makeNumber(*source.yieldStrengthPa));
    material.set("ultimateStrengthPa", JsonValue::makeNumber(source.ultimateStrengthPa));
    material.set("isotropicApproximation", JsonValue::makeBool(source.isotropicApproximation));
    material.set("source", JsonValue::makeString(source.source));
    return material;
}

std::string solverVersionText(const std::string& mesher) {
    return "fea " + std::to_string(kStructuralSolverVersion) + " / " + mesher + " / materials "
           + std::to_string(kMaterialDatabaseVersion);
}

} // namespace

Result<StructuralJob> parseStructuralJob(const std::string& text, const std::string& baseDirectory) {
    JsonValue root;
    std::string error;
    if (!json::parseJson(text, root, error)) return invalid("не JSON: " + error);
    if (root.stringOr("schema", "") != kStructuralJobSchema) {
        return invalid(std::string("ожидалась схема ") + kStructuralJobSchema);
    }
    auto resolve = [&](const std::string& path) {
        if (path.empty()) return path;
        std::filesystem::path p(path);
        return (p.is_absolute() ? p : std::filesystem::path(baseDirectory) / p).lexically_normal().string();
    };

    StructuralJob job;
    const std::string analysis = root.stringOr("analysis", "static");
    if (analysis == "modal") job.analysis = StructuralAnalysis::Modal;
    else if (analysis != "static") return invalid("analysis: static или modal");
    const JsonValue* geometry = root.member("geometry");
    if (geometry == nullptr || !geometry->isObject()) return invalid("нет geometry");
    job.geometryFormat = geometry->stringOr("format", "");
    job.geometryPath = resolve(geometry->stringOr("path", ""));
    if (job.geometryFormat != "brep" && job.geometryFormat != "uavpart") return invalid("geometry.format: brep или uavpart");
    if (job.geometryPath.empty()) return invalid("нет geometry.path");

    if (const JsonValue* material = root.member("material"); material != nullptr && material->type == JsonValue::Type::String) {
        job.materialId = material->stringValue;
    }

    const JsonValue* mesh = root.member("mesh");
    if (mesh == nullptr || !mesh->isObject()) return invalid("нет mesh");
    job.settings.coarseElementSizeM = mesh->numberOr("coarseElementSizeM", 0.0);
    job.settings.refinementFactor = mesh->numberOr("refinementFactor", 0.0);
    job.settings.criteria.factorOfSafety = root.numberOr("factorOfSafety", job.settings.criteria.factorOfSafety);

    const JsonValue* loadCase = root.member("loadCase");
    if (loadCase == nullptr || !loadCase->isObject()) return invalid("нет loadCase");
    job.loadCase.name = loadCase->stringOr("name", "");
    if (const JsonValue* supports = loadCase->member("supports"); supports && supports->isArray()) {
        for (const auto& item : supports->arrayItems) {
            FaceSupport support;
            support.face = item.stringOr("face", "");
            support.fixed = {false, false, false};
            const JsonValue* fix = item.member("fix");
            if (support.face.empty() || fix == nullptr || !fix->isArray() || fix->arrayItems.empty()) {
                return invalid("опора без face или fix");
            }
            for (const auto& axis : fix->arrayItems) {
                if (axis.stringValue == "x") support.fixed[0] = true;
                else if (axis.stringValue == "y") support.fixed[1] = true;
                else if (axis.stringValue == "z") support.fixed[2] = true;
                else return invalid("fix: только x, y, z");
            }
            job.loadCase.supports.push_back(support);
        }
    }
    if (const JsonValue* forces = loadCase->member("forces"); forces && forces->isArray()) {
        for (const auto& item : forces->arrayItems) {
            FaceForce force;
            force.face = item.stringOr("face", "");
            if (force.face.empty() || !readVector(item.member("totalForceN"), force.totalForceN)) {
                return invalid("сила без face или totalForceN [x, y, z]");
            }
            job.loadCase.forces.push_back(force);
        }
    }
    if (const JsonValue* pressures = loadCase->member("pressures"); pressures && pressures->isArray()) {
        for (const auto& item : pressures->arrayItems) {
            FacePressure pressure;
            pressure.face = item.stringOr("face", "");
            const JsonValue* value = item.member("pressurePa");
            if (pressure.face.empty() || value == nullptr || value->type != JsonValue::Type::Number) {
                return invalid("давление без face или pressurePa");
            }
            pressure.pressurePa = value->numberValue;
            job.loadCase.pressures.push_back(pressure);
        }
    }
    if (const JsonValue* acceleration = loadCase->member("bodyAccelerationMps2")) {
        if (!readVector(acceleration, job.loadCase.bodyAccelerationMps2)) return invalid("bodyAccelerationMps2: [x, y, z]");
    }
    if (const JsonValue* exclusions = loadCase->member("stressExclusions"); exclusions && exclusions->isArray()) {
        for (const auto& item : exclusions->arrayItems) {
            StressExclusion exclusion;
            exclusion.face = item.stringOr("face", "");
            exclusion.distanceM = item.numberOr("distanceM", 0.0);
            if (exclusion.face.empty() || !(exclusion.distanceM > 0.0)) return invalid("зона исключения без face или distanceM > 0");
            job.loadCase.stressExclusions.push_back(exclusion);
        }
    }

    if (job.analysis == StructuralAnalysis::Modal) {
        const auto& lc = job.loadCase;
        if (!lc.forces.empty() || !lc.pressures.empty() || length(lc.bodyAccelerationMps2) > 0.0 || !lc.stressExclusions.empty()) {
            return invalid("модальный анализ не учитывает нагрузки и зоны исключения — уберите их из задания");
        }
        const JsonValue* modal = root.member("modal");
        if (modal == nullptr || !modal->isObject()) return invalid("нет modal");
        const JsonValue* modeCount = modal->member("modeCount");
        if (modeCount == nullptr || modeCount->type != JsonValue::Type::Number || modeCount->numberValue < 1.0
            || modeCount->numberValue != std::floor(modeCount->numberValue)) {
            return invalid("modal.modeCount: целое ≥ 1");
        }
        job.modal.modeCount = static_cast<int>(modeCount->numberValue);
        job.modal.separationMargin = modal->numberOr("separationMargin", 0.0);
        if (!(job.modal.separationMargin >= 0.0)) return invalid("modal.separationMargin ≥ 0");
        if (const JsonValue* rotors = modal->member("rotors"); rotors && rotors->isArray()) {
            for (const auto& item : rotors->arrayItems) {
                RotorExcitation rotor;
                rotor.name = item.stringOr("name", "");
                rotor.minimumRpm = item.numberOr("minimumRpm", -1.0);
                rotor.maximumRpm = item.numberOr("maximumRpm", -1.0);
                const double blades = item.numberOr("bladeCount", 0.0);
                if (rotor.name.empty() || !(rotor.minimumRpm > 0.0) || !(rotor.maximumRpm >= rotor.minimumRpm) || blades < 1.0
                    || blades != std::floor(blades)) {
                    return invalid("винт: name, 0 < minimumRpm ≤ maximumRpm, целое bladeCount ≥ 1");
                }
                rotor.bladeCount = static_cast<int>(blades);
                job.modal.rotors.push_back(rotor);
            }
        }
        if (const JsonValue* masses = modal->member("attachedMasses"); masses && masses->isArray()) {
            for (const auto& item : masses->arrayItems) {
                AttachedMass mass;
                mass.faceGroup = item.stringOr("face", "");
                mass.massKg = item.numberOr("massKg", -1.0);
                if (mass.faceGroup.empty() || !(mass.massKg > 0.0)) return invalid("присоединённая масса: face и massKg > 0");
                job.modal.attachedMasses.push_back(mass);
            }
        }
        if (const JsonValue* bands = modal->member("bands"); bands && bands->isArray()) {
            for (const auto& item : bands->arrayItems) {
                ExcitationBand band;
                band.name = item.stringOr("name", "");
                band.minimumHz = item.numberOr("minimumHz", -1.0);
                band.maximumHz = item.numberOr("maximumHz", -1.0);
                if (band.name.empty() || !(band.minimumHz >= 0.0) || !(band.maximumHz >= band.minimumHz)) {
                    return invalid("полоса: name, 0 ≤ minimumHz ≤ maximumHz");
                }
                job.modal.bands.push_back(band);
            }
        }
    }

    const JsonValue* output = root.member("output");
    if (output == nullptr || !output->isObject()) return invalid("нет output");
    job.resultPath = resolve(output->stringOr("result", ""));
    job.fieldPath = resolve(output->stringOr("field", ""));
    job.reportPath = resolve(output->stringOr("report", ""));
    if (job.resultPath.empty()) return invalid("нет output.result");
    return Result<StructuralJob>::ok(std::move(job));
}

std::string structuralResultJson(const StructuralStudyResult& result, const StructuralJob& job,
                                 const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kStructuralResultSchema));
    root.set("testType", JsonValue::makeString("structuralStatic"));
    const auto& assessment = result.assessment;
    const char* outcome = assessment.verdict == StrengthVerdict::Pass      ? "pass"
                          : assessment.verdict == StrengthVerdict::Warning ? "warning"
                                                                           : "fail";
    root.set("outcome", JsonValue::makeString(outcome));
    root.set("solverID", JsonValue::makeString(kStructuralSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    JsonValue metrics = JsonValue::makeObject();
    const auto& stress = result.stressConvergence;
    const auto& displacement = result.displacementConvergence;
    putMetric(metrics, "maxVonMisesPa", assessment.limitStressPa, "Pa",
              stress.isUsable() ? std::optional<double>(stress.uncertaintyAbsolute) : std::nullopt);
    putMetric(metrics, "maxDisplacementM", result.levels.back().maxDisplacementM, "m",
              displacement.isUsable() ? std::optional<double>(displacement.uncertaintyAbsolute) : std::nullopt);
    std::optional<double> marginBand;
    if (assessment.conservativeMargin) marginBand = assessment.governingMargin - *assessment.conservativeMargin;
    putMetric(metrics, "reserveFactor", assessment.reserveFactor, "1", marginBand);
    putMetric(metrics, "ultimateMargin", assessment.ultimateMargin, "1");
    if (assessment.yieldMargin) putMetric(metrics, "yieldMargin", *assessment.yieldMargin, "1");
    root.set("metrics", std::move(metrics));

    std::vector<std::string> warnings = result.warnings;
    std::vector<std::string> failureReasons;
    if (assessment.verdict == StrengthVerdict::Fail && !assessment.reasons.empty()) {
        failureReasons.push_back(assessment.reasons.front());
        warnings.insert(warnings.end(), assessment.reasons.begin() + 1, assessment.reasons.end());
    } else {
        warnings.insert(warnings.end(), assessment.reasons.begin(), assessment.reasons.end());
    }
    root.set("warnings", strings(warnings));
    root.set("failureReasons", strings(failureReasons));

    // Everything that defines the calculation: the Validation Engine fingerprints this object.
    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("factorOfSafety", JsonValue::makeNumber(job.settings.criteria.factorOfSafety));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    root.set("settings", std::move(settings));

    JsonValue critical = JsonValue::makeObject();
    critical.set("point", vector(result.criticalPoint));
    critical.set("face", JsonValue::makeString(result.criticalFace));
    root.set("criticalRegion", std::move(critical));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("dofs", JsonValue::makeNumber(level.dofs));
        item.set("maxVonMisesPa", JsonValue::makeNumber(level.maxVonMisesPa));
        item.set("maxDisplacementM", JsonValue::makeNumber(level.maxDisplacementM));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("stress", convergenceJson(stress));
    convergence.set("displacement", convergenceJson(displacement));
    root.set("convergence", std::move(convergence));

    root.set("material", materialJson(result.material));

    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

std::string structuralJobJson(const StructuralJob& job) {
    const bool modal = job.analysis == StructuralAnalysis::Modal;
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kStructuralJobSchema));
    root.set("analysis", JsonValue::makeString(modal ? "modal" : "static"));
    JsonValue geometry = JsonValue::makeObject();
    geometry.set("format", JsonValue::makeString(job.geometryFormat));
    geometry.set("path", JsonValue::makeString(job.geometryPath));
    root.set("geometry", std::move(geometry));
    if (job.materialId) root.set("material", JsonValue::makeString(*job.materialId));
    if (!modal) root.set("factorOfSafety", JsonValue::makeNumber(job.settings.criteria.factorOfSafety));
    JsonValue mesh = JsonValue::makeObject();
    mesh.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    mesh.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    root.set("mesh", std::move(mesh));
    root.set("loadCase", loadCaseJson(job.loadCase));
    if (modal) root.set("modal", modalJobJson(job.modal));
    JsonValue output = JsonValue::makeObject();
    output.set("result", JsonValue::makeString(job.resultPath));
    if (!job.fieldPath.empty()) output.set("field", JsonValue::makeString(job.fieldPath));
    if (!job.reportPath.empty()) output.set("report", JsonValue::makeString(job.reportPath));
    root.set("output", std::move(output));
    return root.serialize();
}

std::string structuralErrorJson(const std::string& message, const StructuralJob* job) {
    const bool modal = job != nullptr && job->analysis == StructuralAnalysis::Modal;
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(modal ? kModalResultSchema : kStructuralResultSchema));
    root.set("testType", JsonValue::makeString(modal ? "modalVibration" : "structuralStatic"));
    root.set("outcome", JsonValue::makeString("error"));
    root.set("solverID", JsonValue::makeString(modal ? kModalSolverID : kStructuralSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText("netgen")));
    root.set("metrics", JsonValue::makeObject());
    root.set("warnings", JsonValue::makeArray());
    root.set("failureReasons", strings({message}));
    JsonValue settings = JsonValue::makeObject();
    if (job != nullptr) settings.set("loadCase", loadCaseJson(job->loadCase));
    if (modal) settings.set("modal", modalJobJson(job->modal));
    root.set("settings", std::move(settings));
    return root.serialize();
}

std::string structuralFieldJson(const StructuralStudyResult& result) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kStructuralFieldSchema));
    root.set("lengthUnit", JsonValue::makeString("m"));
    root.set("stressUnit", JsonValue::makeString("Pa"));
    JsonValue nodes = JsonValue::makeArray();
    JsonValue displacement = JsonValue::makeArray();
    JsonValue vonMises = JsonValue::makeArray();
    for (std::size_t n = 0; n < result.field.nodes.size(); ++n) {
        for (int c = 0; c < 3; ++c) {
            nodes.arrayItems.push_back(JsonValue::makeNumber(result.field.nodes[n][c]));
            displacement.arrayItems.push_back(JsonValue::makeNumber(result.field.displacement[n][c]));
        }
        vonMises.arrayItems.push_back(JsonValue::makeNumber(result.field.vonMisesPa[n]));
    }
    root.set("nodes", std::move(nodes));
    root.set("displacement", std::move(displacement));
    root.set("vonMisesPa", std::move(vonMises));
    putTriangles(root, result.field.triangles, result.field.triangleFace);

    // What every viewer needs to draw this honestly (see StructuralPresentation.hpp).
    const auto allowable = presentation::allowableStress(result.material, result.factorOfSafety);
    root.set("allowableStressPa", JsonValue::makeNumber(allowable.stressPa));
    root.set("allowableBasis", JsonValue::makeString(allowable.basis == AllowableBasis::Yield ? "yield" : "ultimateOverFactorOfSafety"));
    root.set("factorOfSafety", JsonValue::makeNumber(result.factorOfSafety));
    root.set("criticalPoint", vector(result.criticalPoint));
    Vec3 low = result.field.nodes.empty() ? Vec3{} : result.field.nodes.front();
    Vec3 high = low;
    double maxDisplacement = 0.0;
    for (std::size_t n = 0; n < result.field.nodes.size(); ++n) {
        const Vec3& p = result.field.nodes[n];
        low = {std::min(low.x, p.x), std::min(low.y, p.y), std::min(low.z, p.z)};
        high = {std::max(high.x, p.x), std::max(high.y, p.y), std::max(high.z, p.z)};
        maxDisplacement = std::max(maxDisplacement, length(result.field.displacement[n]));
    }
    const double diagonal = length(high - low);
    root.set("boundingDiagonalM", JsonValue::makeNumber(diagonal));
    root.set("maxDisplacementM", JsonValue::makeNumber(maxDisplacement));
    JsonValue display = JsonValue::makeObject();
    display.set("quantity", JsonValue::makeString("utilization"));
    JsonValue stops = JsonValue::makeArray();
    for (const auto& stop : presentation::utilizationStops()) {
        JsonValue pair = JsonValue::makeArray();
        pair.arrayItems.push_back(JsonValue::makeNumber(stop.position));
        pair.arrayItems.push_back(JsonValue::makeString(stop.hex));
        stops.arrayItems.push_back(std::move(pair));
    }
    display.set("colorStops", std::move(stops));
    display.set("overflowColor", JsonValue::makeString(presentation::overflowColor().hex));
    display.set("deformationAutoScale", JsonValue::makeNumber(presentation::deformationAutoScale(maxDisplacement, diagonal)));
    root.set("presentation", std::move(display));
    return root.serialize();
}

std::vector<ExcitationBand> ModalJobSettings::allBands() const {
    std::vector<ExcitationBand> all;
    for (const auto& rotor : rotors) {
        const auto rotorBands = rotorExcitationBands(rotor);
        all.insert(all.end(), rotorBands.begin(), rotorBands.end());
    }
    all.insert(all.end(), bands.begin(), bands.end());
    return all;
}

ModalStudySettings modalStudySettings(const StructuralJob& job) {
    ModalStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.modeCount = job.modal.modeCount;
    settings.bands = job.modal.allBands();
    settings.separationMargin = job.modal.separationMargin;
    settings.attachedMasses = job.modal.attachedMasses;
    return settings;
}

std::string modalResultJson(const ModalStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kModalResultSchema));
    root.set("testType", JsonValue::makeString("modalVibration"));
    const bool warning = result.resonanceOverlap || result.bands.empty() || result.uncertaintyUnknown || !result.uncheckedBands.empty();
    root.set("outcome", JsonValue::makeString(warning ? "warning" : "pass"));
    root.set("solverID", JsonValue::makeString(kModalSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    JsonValue metrics = JsonValue::makeObject();
    if (!result.modes.empty()) {
        const auto& first = result.modes.front();
        putMetric(metrics, "firstFrequencyHz", first.frequencyHz, "Hz",
                  first.convergence.isUsable() ? std::optional<double>(first.convergence.uncertaintyAbsolute) : std::nullopt);
    }
    if (!result.resonance.empty()) {
        double smallest = result.resonance.front().separation;
        for (const auto& finding : result.resonance) smallest = std::min(smallest, finding.separation);
        putMetric(metrics, "minimumBandSeparation", smallest, "1");
    }
    root.set("metrics", std::move(metrics));
    root.set("warnings", strings(result.warnings));
    root.set("failureReasons", JsonValue::makeArray());

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("modal", modalJobJson(job.modal));
    root.set("settings", std::move(settings));

    root.set("boundary", JsonValue::makeString(result.constrained ? "supported" : "free"));
    root.set("totalMassKg", JsonValue::makeNumber(result.totalMassKg));
    root.set("attachedMassKg", JsonValue::makeNumber(result.attachedMassKg));
    JsonValue modes = JsonValue::makeArray();
    for (std::size_t i = 0; i < result.modes.size(); ++i) {
        const auto& mode = result.modes[i];
        JsonValue item = JsonValue::makeObject();
        item.set("mode", JsonValue::makeNumber(static_cast<double>(i + 1)));
        item.set("frequencyHz", JsonValue::makeNumber(mode.frequencyHz));
        if (mode.convergence.isUsable()) item.set("numericalUncertaintyHz", JsonValue::makeNumber(mode.convergence.uncertaintyAbsolute));
        item.set("resonanceUncertaintyHz", JsonValue::makeNumber(mode.resonanceUncertaintyHz));
        item.set("effectiveMassFraction", vector(mode.effectiveMassFraction));
        item.set("convergence", convergenceJson(mode.convergence));
        modes.arrayItems.push_back(std::move(item));
    }
    root.set("modes", std::move(modes));

    JsonValue bands = JsonValue::makeArray();
    for (const auto& band : result.bands) bands.arrayItems.push_back(bandJson(band));
    root.set("excitationBands", std::move(bands));
    root.set("separationMargin", JsonValue::makeNumber(result.separationMargin));
    JsonValue resonance = JsonValue::makeArray();
    for (const auto& finding : result.resonance) {
        JsonValue item = JsonValue::makeObject();
        item.set("mode", JsonValue::makeNumber(finding.modeIndex + 1));
        item.set("frequencyHz", JsonValue::makeNumber(finding.frequencyHz));
        item.set("nearestBand", JsonValue::makeString(finding.band));
        item.set("separation", JsonValue::makeNumber(finding.separation));
        item.set("overlaps", JsonValue::makeBool(finding.overlaps));
        resonance.arrayItems.push_back(std::move(item));
    }
    root.set("resonance", std::move(resonance));

    JsonValue study = JsonValue::makeArray();
    for (std::size_t level = 0; level < result.levelElements.size(); ++level) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(result.levelElementSizes[level]));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(result.levelElements[level])));
        JsonValue frequencies = JsonValue::makeArray();
        for (double f : result.levelFrequencies[level]) frequencies.arrayItems.push_back(JsonValue::makeNumber(f));
        item.set("frequenciesHz", std::move(frequencies));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    root.set("material", materialJson(result.material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

std::string modalFieldJson(const ModalStudyResult& result) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kModalFieldSchema));
    root.set("lengthUnit", JsonValue::makeString("m"));
    JsonValue nodes = JsonValue::makeArray();
    Vec3 low = result.field.nodes.empty() ? Vec3{} : result.field.nodes.front();
    Vec3 high = low;
    for (const auto& p : result.field.nodes) {
        for (int c = 0; c < 3; ++c) nodes.arrayItems.push_back(JsonValue::makeNumber(p[c]));
        low = {std::min(low.x, p.x), std::min(low.y, p.y), std::min(low.z, p.z)};
        high = {std::max(high.x, p.x), std::max(high.y, p.y), std::max(high.z, p.z)};
    }
    root.set("nodes", std::move(nodes));
    putTriangles(root, result.field.triangles, result.field.triangleFace);
    JsonValue modes = JsonValue::makeArray();
    for (std::size_t i = 0; i < result.field.shapes.size(); ++i) {
        JsonValue item = JsonValue::makeObject();
        item.set("mode", JsonValue::makeNumber(static_cast<double>(i + 1)));
        item.set("frequencyHz", JsonValue::makeNumber(result.modes[i].frequencyHz));
        JsonValue shape = JsonValue::makeArray();
        for (const auto& d : result.field.shapes[i])
            for (int c = 0; c < 3; ++c) shape.arrayItems.push_back(JsonValue::makeNumber(d[c]));
        item.set("shape", std::move(shape));
        modes.arrayItems.push_back(std::move(item));
    }
    root.set("modes", std::move(modes));
    const double diagonal = length(high - low);
    root.set("boundingDiagonalM", JsonValue::makeNumber(diagonal));
    // Mode shapes have no amplitude of their own: each is scaled to a largest displacement of 1
    // and drawn at the same fraction of the part size as a static deformation, colour = relative
    // amplitude. A viewer must say so, never print it as millimetres.
    JsonValue display = JsonValue::makeObject();
    display.set("quantity", JsonValue::makeString("relativeModalAmplitude"));
    display.set("shapeNormalization", JsonValue::makeString("maxDisplacementIsOne"));
    JsonValue stops = JsonValue::makeArray();
    for (const auto& stop : presentation::utilizationStops()) {
        JsonValue pair = JsonValue::makeArray();
        pair.arrayItems.push_back(JsonValue::makeNumber(stop.position));
        pair.arrayItems.push_back(JsonValue::makeString(stop.hex));
        stops.arrayItems.push_back(std::move(pair));
    }
    display.set("colorStops", std::move(stops));
    display.set("displayAmplitudeM", JsonValue::makeNumber(presentation::kDeformationDisplayFraction * diagonal));
    root.set("presentation", std::move(display));
    return root.serialize();
}

} // namespace cadnext::fea
