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

JsonValue attachedMassesJson(const std::vector<AttachedMass>& attached) {
    JsonValue masses = JsonValue::makeArray();
    for (const auto& mass : attached) {
        JsonValue item = JsonValue::makeObject();
        item.set("face", JsonValue::makeString(mass.faceGroup));
        item.set("massKg", JsonValue::makeNumber(mass.massKg));
        masses.arrayItems.push_back(std::move(item));
    }
    return masses;
}

JsonValue harmonicJobJson(const HarmonicJobSettings& harmonic) {
    JsonValue object = JsonValue::makeObject();
    object.set("modeCount", JsonValue::makeNumber(harmonic.modeCount));
    object.set("dampingRatio", JsonValue::makeNumber(harmonic.dampingRatio));
    JsonValue excitation = JsonValue::makeObject();
    const bool base = harmonic.excitation.kind == HarmonicExcitationKind::BaseAcceleration;
    excitation.set("kind", JsonValue::makeString(base ? "base" : "force"));
    excitation.set("direction", vector(harmonic.excitation.direction));
    if (!base) excitation.set("face", JsonValue::makeString(harmonic.excitation.faceGroup));
    if (harmonic.excitation.imbalanceKgM > 0.0) {
        excitation.set("imbalanceKgM", JsonValue::makeNumber(harmonic.excitation.imbalanceKgM));
    } else {
        JsonValue amplitude = JsonValue::makeArray();
        for (const auto& point : harmonic.excitation.amplitude) {
            JsonValue pair = JsonValue::makeArray();
            pair.arrayItems.push_back(JsonValue::makeNumber(point.frequencyHz));
            pair.arrayItems.push_back(JsonValue::makeNumber(point.amplitude));
            amplitude.arrayItems.push_back(std::move(pair));
        }
        excitation.set("amplitude", std::move(amplitude));
    }
    object.set("excitation", std::move(excitation));
    JsonValue range = JsonValue::makeArray();
    range.arrayItems.push_back(JsonValue::makeNumber(harmonic.minimumHz));
    range.arrayItems.push_back(JsonValue::makeNumber(harmonic.maximumHz));
    object.set("frequencyRangeHz", std::move(range));
    object.set("sweepPoints", JsonValue::makeNumber(harmonic.sweepPoints));
    object.set("attachedMasses", attachedMassesJson(harmonic.attachedMasses));
    if (!harmonic.probeFace.empty()) object.set("probeFace", JsonValue::makeString(harmonic.probeFace));
    return object;
}

JsonValue randomJobJson(const RandomJobSettings& random) {
    JsonValue object = JsonValue::makeObject();
    object.set("modeCount", JsonValue::makeNumber(random.modeCount));
    object.set("dampingRatio", JsonValue::makeNumber(random.dampingRatio));
    object.set("direction", vector(random.direction));
    JsonValue psd = JsonValue::makeArray();
    for (const auto& point : random.accelerationPsd) {
        JsonValue pair = JsonValue::makeArray();
        pair.arrayItems.push_back(JsonValue::makeNumber(point.frequencyHz));
        pair.arrayItems.push_back(JsonValue::makeNumber(point.amplitude));
        psd.arrayItems.push_back(std::move(pair));
    }
    object.set("accelerationPsd", std::move(psd));
    object.set("attachedMasses", attachedMassesJson(random.attachedMasses));
    if (!random.probeFace.empty()) object.set("probeFace", JsonValue::makeString(random.probeFace));
    return object;
}

const char* pulseShapeName(PulseShape shape) {
    switch (shape) {
    case PulseShape::HalfSine: return "halfSine";
    case PulseShape::TerminalPeakSawtooth: return "sawtooth";
    case PulseShape::Trapezoid: return "trapezoid";
    case PulseShape::TimeHistory: return "history";
    }
    return "halfSine";
}

JsonValue birdJobJson(const BirdJobSettings& settings) {
    JsonValue object = JsonValue::makeObject();
    object.set("modeCount", JsonValue::makeNumber(settings.modeCount));
    object.set("dampingRatio", JsonValue::makeNumber(settings.dampingRatio));
    object.set("impactFace", JsonValue::makeString(settings.impactFace));
    object.set("direction", vector(settings.direction));
    JsonValue bird = JsonValue::makeObject();
    bird.set("massKg", JsonValue::makeNumber(settings.bird.massKg));
    bird.set("speedMps", JsonValue::makeNumber(settings.bird.speedMps));
    bird.set("obliquityDeg", JsonValue::makeNumber(settings.bird.obliquityRad * 180.0 / M_PI));
    bird.set("densityKgM3", JsonValue::makeNumber(settings.bird.densityKgM3));
    bird.set("lengthToDiameter", JsonValue::makeNumber(settings.bird.lengthToDiameter));
    bird.set("shockSpeedMps", JsonValue::makeNumber(settings.bird.shockSpeedMps));
    bird.set("shockSlope", JsonValue::makeNumber(settings.bird.shockSlope));
    object.set("bird", std::move(bird));
    object.set("attachedMasses", attachedMassesJson(settings.attachedMasses));
    return object;
}

JsonValue shockJobJson(const ShockJobSettings& shock) {
    JsonValue object = JsonValue::makeObject();
    object.set("modeCount", JsonValue::makeNumber(shock.modeCount));
    object.set("dampingRatio", JsonValue::makeNumber(shock.dampingRatio));
    object.set("direction", vector(shock.direction));
    JsonValue pulse = JsonValue::makeObject();
    pulse.set("shape", JsonValue::makeString(pulseShapeName(shock.pulse.shape)));
    if (shock.pulse.shape == PulseShape::TimeHistory) {
        JsonValue history = JsonValue::makeArray();
        for (const auto& [t, a] : shock.pulse.history) {
            JsonValue pair = JsonValue::makeArray();
            pair.arrayItems.push_back(JsonValue::makeNumber(t));
            pair.arrayItems.push_back(JsonValue::makeNumber(a));
            history.arrayItems.push_back(std::move(pair));
        }
        pulse.set("history", std::move(history));
    } else {
        pulse.set("peakMps2", JsonValue::makeNumber(shock.pulse.peakMs2));
        pulse.set("durationS", JsonValue::makeNumber(shock.pulse.durationS));
        if (shock.pulse.shape == PulseShape::Trapezoid) {
            pulse.set("riseS", JsonValue::makeNumber(shock.pulse.riseS));
            pulse.set("fallS", JsonValue::makeNumber(shock.pulse.fallS));
        }
    }
    object.set("pulse", std::move(pulse));
    object.set("attachedMasses", attachedMassesJson(shock.attachedMasses));
    if (!shock.probeFace.empty()) object.set("probeFace", JsonValue::makeString(shock.probeFace));
    return object;
}

const char* categoryName(const ClimateJobSettings& c) {
    if (c.environment == ClimateEnvironment::Hot) return c.hotCategory == HotCategory::A1HotDry ? "A1" : "A2";
    switch (c.coldCategory) {
    case ColdCategory::C1BasicCold: return "C1";
    case ColdCategory::C2Cold: return "C2";
    case ColdCategory::C3SevereCold: return "C3";
    }
    return "C2";
}

const char* exposureName(const ClimateJobSettings& c) {
    if (c.environment == ClimateEnvironment::Hot) return c.hotExposure == HotExposure::Sun ? "sun" : c.hotExposure == HotExposure::Shade ? "shade" : "induced";
    return c.coldExposure == ColdExposure::Ambient ? "ambient" : "induced";
}

JsonValue climateJobJson(const ClimateJobSettings& c) {
    JsonValue object = JsonValue::makeObject();
    const bool hot = c.environment == ClimateEnvironment::Hot;
    object.set("environment", JsonValue::makeString(hot ? "hot" : "cold"));
    object.set("category", JsonValue::makeString(categoryName(c)));
    object.set("exposure", JsonValue::makeString(exposureName(c)));
    object.set("airflow", JsonValue::makeString(c.airflow == ClimateAirflow::Flight ? "flight" : "chamber"));
    object.set("airSpeedMps", JsonValue::makeNumber(c.airSpeedMps));
    if (c.airflow == ClimateAirflow::Flight) object.set("altitudeM", JsonValue::makeNumber(c.altitudeM));
    object.set("upDirection", vector(c.upDirection));
    object.set("flowDirection", vector(c.flowDirection));
    if (c.solarAbsorptance > 0.0) object.set("solarAbsorptance", JsonValue::makeNumber(c.solarAbsorptance));
    object.set("emissivity", JsonValue::makeNumber(c.emissivity));
    object.set("stressFreeK", JsonValue::makeNumber(c.stressFreeK));
    object.set("operating", JsonValue::makeBool(c.operating));
    JsonValue components = JsonValue::makeArray();
    for (const auto& component : c.components) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(component.name));
        item.set("face", JsonValue::makeString(component.face));
        item.set("powerW", JsonValue::makeNumber(component.powerW));
        if (component.minimumK) item.set("minimumK", JsonValue::makeNumber(*component.minimumK));
        if (component.maximumK) item.set("maximumK", JsonValue::makeNumber(*component.maximumK));
        components.arrayItems.push_back(std::move(item));
    }
    object.set("components", std::move(components));
    if (c.materialMinimumK) object.set("materialMinimumK", JsonValue::makeNumber(*c.materialMinimumK));
    if (c.materialMaximumK) object.set("materialMaximumK", JsonValue::makeNumber(*c.materialMaximumK));
    object.set("convectionBand", JsonValue::makeNumber(c.convectionBand));
    if (hot) object.set("stepS", JsonValue::makeNumber(c.stepS));
    return object;
}

JsonValue componentsJson(const std::vector<ClimateComponent>& list) {
    JsonValue components = JsonValue::makeArray();
    for (const auto& component : list) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(component.name));
        item.set("face", JsonValue::makeString(component.face));
        item.set("powerW", JsonValue::makeNumber(component.powerW));
        if (component.minimumK) item.set("minimumK", JsonValue::makeNumber(*component.minimumK));
        if (component.maximumK) item.set("maximumK", JsonValue::makeNumber(*component.maximumK));
        components.arrayItems.push_back(std::move(item));
    }
    return components;
}

JsonValue fireJobJson(const FireJobSettings& f) {
    JsonValue object = JsonValue::makeObject();
    object.set("standard", JsonValue::makeString(f.standard == FireStandard::Iso2685 ? "iso2685" : "ac20135"));
    object.set("durationS", JsonValue::makeNumber(f.durationS));
    object.set("flameFaces", strings(f.flameFaces));
    object.set("surfaceEmissivity", JsonValue::makeNumber(f.surfaceEmissivity));
    object.set("stepS", JsonValue::makeNumber(f.stepS));
    object.set("operating", JsonValue::makeBool(f.operating));
    object.set("components", componentsJson(f.components));
    return object;
}

// Components of a climate or fire block: name, face, W ≥ 0, limits in kelvin.
std::optional<std::string> readComponents(const JsonValue* list, std::vector<ClimateComponent>& out) {
    if (list == nullptr || !list->isArray()) return std::nullopt;
    for (const auto& item : list->arrayItems) {
        ClimateComponent component;
        component.name = item.stringOr("name", "");
        component.face = item.stringOr("face", "");
        component.powerW = item.numberOr("powerW", 0.0);
        if (component.name.empty() || component.face.empty() || !(component.powerW >= 0.0)) return std::string("компонент: name, face и powerW ≥ 0");
        if (const JsonValue* v = item.member("minimumK")) {
            if (v->type != JsonValue::Type::Number || !(v->numberValue > 0.0)) return std::string("компонент: minimumK в кельвинах");
            component.minimumK = v->numberValue;
        }
        if (const JsonValue* v = item.member("maximumK")) {
            if (v->type != JsonValue::Type::Number || !(v->numberValue > 0.0)) return std::string("компонент: maximumK в кельвинах");
            component.maximumK = v->numberValue;
        }
        if (component.minimumK && component.maximumK && !(*component.minimumK < *component.maximumK)) return std::string("компонент: minimumK < maximumK");
        out.push_back(component);
    }
    return std::nullopt;
}

const char* lightningComponentName(LightningComponent component) {
    switch (component) {
    case LightningComponent::A: return "A";
    case LightningComponent::B: return "B";
    case LightningComponent::C: return "C";
    case LightningComponent::D: return "D";
    }
    return "A";
}

JsonValue lightningJobJson(const LightningJobSettings& l) {
    JsonValue object = JsonValue::makeObject();
    JsonValue components = JsonValue::makeArray();
    for (auto component : l.components) components.arrayItems.push_back(JsonValue::makeString(lightningComponentName(component)));
    object.set("components", std::move(components));
    object.set("attachmentFaces", strings(l.attachmentFaces));
    object.set("groundFaces", strings(l.groundFaces));
    object.set("polarity", JsonValue::makeString(l.polarity == ArcPolarity::Anode ? "anode" : "cathode"));
    object.set("continuingCurrentA", JsonValue::makeNumber(l.continuingCurrentA));
    object.set("surfaceEmissivity", JsonValue::makeNumber(l.surfaceEmissivity));
    object.set("stepsPerComponent", JsonValue::makeNumber(l.stepsPerComponent));
    object.set("equipment", componentsJson(l.equipment));
    return object;
}

const char* axisName(em::Axis axis) {
    return axis == em::Axis::X ? "x" : axis == em::Axis::Y ? "y" : "z";
}

bool readAxis(const std::string& text, em::Axis& axis) {
    if (text == "x") axis = em::Axis::X;
    else if (text == "y") axis = em::Axis::Y;
    else if (text == "z") axis = em::Axis::Z;
    else return false;
    return true;
}

JsonValue emcJobJson(const EmcJobSettings& e) {
    JsonValue object = JsonValue::makeObject();
    object.set("incidence", JsonValue::makeString(std::string(e.forward ? "+" : "-") + axisName(e.incidence)));
    object.set("polarization", JsonValue::makeString(axisName(e.polarization)));
    if (!e.levelId.empty()) object.set("level", JsonValue::makeString(e.levelId));
    else object.set("fieldVm", JsonValue::makeNumber(e.fieldVm));
    object.set("lowHz", JsonValue::makeNumber(e.lowHz));
    object.set("highHz", JsonValue::makeNumber(e.highHz));
    object.set("points", JsonValue::makeNumber(e.points));
    object.set("surfaceElementSizeM", JsonValue::makeNumber(e.surfaceElementSizeM));
    object.set("pmlCells", JsonValue::makeNumber(e.pmlCells));
    object.set("marginCells", JsonValue::makeNumber(e.marginCells));
    JsonValue equipment = JsonValue::makeArray();
    for (const auto& probe : e.equipment) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(probe.name));
        item.set("x", JsonValue::makeNumber(probe.x));
        item.set("y", JsonValue::makeNumber(probe.y));
        item.set("z", JsonValue::makeNumber(probe.z));
        item.set("immunityVm", JsonValue::makeNumber(probe.immunityVm));
        equipment.arrayItems.push_back(std::move(item));
    }
    object.set("equipment", std::move(equipment));
    return object;
}

const char* axisLetter(int axis) {
    return axis == 0 ? "x" : axis == 1 ? "y" : "z";
}

bool readAxisIndex(const std::string& text, int& axis) {
    if (text == "x") axis = 0;
    else if (text == "y") axis = 1;
    else if (text == "z") axis = 2;
    else return false;
    return true;
}

JsonValue icingJobJson(const IcingJobSettings& i) {
    JsonValue object = JsonValue::makeObject();
    object.set("flowAxis", JsonValue::makeString(axisLetter(i.flowAxis)));
    object.set("spanAxis", JsonValue::makeString(axisLetter(i.spanAxis)));
    object.set("angleOfAttackDeg", JsonValue::makeNumber(i.angleOfAttackRad * 180.0 / M_PI));
    object.set("stations", JsonValue::makeNumber(i.stations));
    object.set("panels", JsonValue::makeNumber(i.panels));
    object.set("trajectories", JsonValue::makeNumber(i.trajectories));
    object.set("refinementFactor", JsonValue::makeNumber(i.refinementFactor));
    object.set("surfaceElementSizeM", JsonValue::makeNumber(i.surfaceElementSizeM));
    if (!i.conditionId.empty()) {
        object.set("condition", JsonValue::makeString(i.conditionId));
        JsonValue cloud = JsonValue::makeObject();
        cloud.set("airspeedMps", JsonValue::makeNumber(i.condition.airspeedMps));
        cloud.set("durationS", JsonValue::makeNumber(i.condition.durationS));
        object.set("flight", std::move(cloud));
    } else {
        JsonValue cloud = JsonValue::makeObject();
        cloud.set("temperatureC", JsonValue::makeNumber(i.condition.temperatureK - kMeltingPointK));
        cloud.set("lwcGm3", JsonValue::makeNumber(i.condition.lwcKgM3 * 1e3));
        cloud.set("dropletMicrons", JsonValue::makeNumber(i.condition.dropletDiameterM * 1e6));
        cloud.set("altitudeM", JsonValue::makeNumber(i.condition.altitudeM));
        cloud.set("airspeedMps", JsonValue::makeNumber(i.condition.airspeedMps));
        cloud.set("durationS", JsonValue::makeNumber(i.condition.durationS));
        object.set("condition", std::move(cloud));
    }
    object.set("antiIceTargetC", JsonValue::makeNumber(i.antiIceTargetK > 0.0 ? i.antiIceTargetK - kMeltingPointK : 0.0));
    object.set("antiIceBudgetW", JsonValue::makeNumber(i.antiIceBudgetW));
    object.set("maximumIceThicknessMm", JsonValue::makeNumber(i.maximumIceThicknessM * 1e3));
    return object;
}

JsonValue flutterJobJson(const FlutterJobSettings& f) {
    JsonValue object = JsonValue::makeObject();
    object.set("flowAxis", JsonValue::makeString(axisLetter(f.flowAxis)));
    object.set("spanAxis", JsonValue::makeString(axisLetter(f.spanAxis)));
    object.set("stations", JsonValue::makeNumber(f.stations));
    object.set("airDensityKgM3", JsonValue::makeNumber(f.airDensityKgM3));
    object.set("structuralDamping", JsonValue::makeNumber(f.structuralDamping));
    object.set("diveSpeedMps", JsonValue::makeNumber(f.diveSpeedMps));
    object.set("marginFactor", JsonValue::makeNumber(f.marginFactor));
    object.set("lowSpeedMps", JsonValue::makeNumber(f.lowSpeedMps));
    object.set("highSpeedMps", JsonValue::makeNumber(f.highSpeedMps));
    object.set("speeds", JsonValue::makeNumber(f.speeds));
    return object;
}

JsonValue numbers(const std::vector<double>& values) {
    JsonValue array = JsonValue::makeArray();
    for (double value : values) array.arrayItems.push_back(JsonValue::makeNumber(value));
    return array;
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
    else if (analysis == "harmonic") job.analysis = StructuralAnalysis::Harmonic;
    else if (analysis == "random") job.analysis = StructuralAnalysis::Random;
    else if (analysis == "shock") job.analysis = StructuralAnalysis::Shock;
    else if (analysis == "bird") job.analysis = StructuralAnalysis::Bird;
    else if (analysis == "climate") job.analysis = StructuralAnalysis::Climate;
    else if (analysis == "fire") job.analysis = StructuralAnalysis::Fire;
    else if (analysis == "lightning") job.analysis = StructuralAnalysis::Lightning;
    else if (analysis == "emc") job.analysis = StructuralAnalysis::Emc;
    else if (analysis == "icing") job.analysis = StructuralAnalysis::Icing;
    else if (analysis == "flutter") job.analysis = StructuralAnalysis::Flutter;
    else if (analysis != "static") return invalid("analysis: static, modal, harmonic, random, shock, climate, fire, lightning, emc, icing, flutter или bird");
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

    if (job.analysis == StructuralAnalysis::Harmonic) {
        const auto& lc = job.loadCase;
        if (!lc.forces.empty() || !lc.pressures.empty() || length(lc.bodyAccelerationMps2) > 0.0) {
            return invalid("вибрационное испытание задаёт возбуждение в блоке harmonic — статические нагрузки уберите из задания");
        }
        const JsonValue* harmonic = root.member("harmonic");
        if (harmonic == nullptr || !harmonic->isObject()) return invalid("нет harmonic");
        auto& h = job.harmonic;
        const double modeCount = harmonic->numberOr("modeCount", 0.0);
        if (modeCount < 1.0 || modeCount != std::floor(modeCount)) return invalid("harmonic.modeCount: целое ≥ 1");
        h.modeCount = static_cast<int>(modeCount);
        h.dampingRatio = harmonic->numberOr("dampingRatio", -1.0);
        if (!(h.dampingRatio > 0.0 && h.dampingRatio < 1.0)) return invalid("harmonic.dampingRatio: доля критического, 0 < ζ < 1 (умолчания нет)");
        const JsonValue* range = harmonic->member("frequencyRangeHz");
        if (range == nullptr || !range->isArray() || range->arrayItems.size() != 2 || range->arrayItems[0].type != JsonValue::Type::Number
            || range->arrayItems[1].type != JsonValue::Type::Number) {
            return invalid("harmonic.frequencyRangeHz: [от, до]");
        }
        h.minimumHz = range->arrayItems[0].numberValue;
        h.maximumHz = range->arrayItems[1].numberValue;
        if (!(h.minimumHz > 0.0 && h.maximumHz > h.minimumHz)) return invalid("harmonic.frequencyRangeHz: 0 < от < до");
        const double points = harmonic->numberOr("sweepPoints", 200.0);
        if (points < 2.0 || points != std::floor(points)) return invalid("harmonic.sweepPoints: целое ≥ 2");
        h.sweepPoints = static_cast<int>(points);
        h.probeFace = harmonic->stringOr("probeFace", "");
        if (const JsonValue* masses = harmonic->member("attachedMasses"); masses && masses->isArray()) {
            for (const auto& item : masses->arrayItems) {
                AttachedMass mass;
                mass.faceGroup = item.stringOr("face", "");
                mass.massKg = item.numberOr("massKg", -1.0);
                if (mass.faceGroup.empty() || !(mass.massKg > 0.0)) return invalid("присоединённая масса: face и massKg > 0");
                h.attachedMasses.push_back(mass);
            }
        }
        const JsonValue* excitation = harmonic->member("excitation");
        if (excitation == nullptr || !excitation->isObject()) return invalid("нет harmonic.excitation");
        const std::string kind = excitation->stringOr("kind", "");
        if (kind == "base") h.excitation.kind = HarmonicExcitationKind::BaseAcceleration;
        else if (kind == "force") h.excitation.kind = HarmonicExcitationKind::FaceForce;
        else return invalid("harmonic.excitation.kind: base или force");
        if (!readVector(excitation->member("direction"), h.excitation.direction) || !(length(h.excitation.direction) > 0.0)) {
            return invalid("harmonic.excitation.direction: ненулевой [x, y, z]");
        }
        if (h.excitation.kind == HarmonicExcitationKind::FaceForce) {
            h.excitation.faceGroup = excitation->stringOr("face", "");
            if (h.excitation.faceGroup.empty()) return invalid("сила: нужна грань face");
            h.excitation.imbalanceKgM = excitation->numberOr("imbalanceKgM", 0.0);
            if (excitation->member("imbalanceKgM") && !(h.excitation.imbalanceKgM > 0.0)) return invalid("imbalanceKgM > 0");
        }
        const JsonValue* amplitude = excitation->member("amplitude");
        if (h.excitation.imbalanceKgM > 0.0) {
            if (amplitude) return invalid("дисбаланс и амплитуда силы — взаимоисключающие");
        } else {
            if (amplitude == nullptr || !amplitude->isArray() || amplitude->arrayItems.empty()) {
                return invalid("harmonic.excitation.amplitude: [[Гц, значение], …]");
            }
            for (const auto& pair : amplitude->arrayItems) {
                if (!pair.isArray() || pair.arrayItems.size() != 2 || pair.arrayItems[0].type != JsonValue::Type::Number
                    || pair.arrayItems[1].type != JsonValue::Type::Number || !(pair.arrayItems[0].numberValue > 0.0)
                    || !(pair.arrayItems[1].numberValue > 0.0)) {
                    return invalid("harmonic.excitation.amplitude: положительные пары [Гц, значение]");
                }
                if (!h.excitation.amplitude.empty() && !(pair.arrayItems[0].numberValue > h.excitation.amplitude.back().frequencyHz)) {
                    return invalid("harmonic.excitation.amplitude: частоты должны возрастать");
                }
                h.excitation.amplitude.push_back({pair.arrayItems[0].numberValue, pair.arrayItems[1].numberValue});
            }
        }
    }

    if (job.analysis == StructuralAnalysis::Random) {
        const auto& lc = job.loadCase;
        if (!lc.forces.empty() || !lc.pressures.empty() || length(lc.bodyAccelerationMps2) > 0.0) {
            return invalid("вибрационное испытание задаёт возбуждение в блоке random — статические нагрузки уберите из задания");
        }
        const JsonValue* random = root.member("random");
        if (random == nullptr || !random->isObject()) return invalid("нет random");
        auto& r = job.random;
        const double modeCount = random->numberOr("modeCount", 0.0);
        if (modeCount < 1.0 || modeCount != std::floor(modeCount)) return invalid("random.modeCount: целое ≥ 1");
        r.modeCount = static_cast<int>(modeCount);
        r.dampingRatio = random->numberOr("dampingRatio", -1.0);
        if (!(r.dampingRatio > 0.0 && r.dampingRatio < 1.0)) return invalid("random.dampingRatio: доля критического, 0 < ζ < 1 (умолчания нет)");
        if (!readVector(random->member("direction"), r.direction) || !(length(r.direction) > 0.0)) return invalid("random.direction: ненулевой [x, y, z]");
        r.probeFace = random->stringOr("probeFace", "");
        const JsonValue* psd = random->member("accelerationPsd");
        if (psd == nullptr || !psd->isArray() || psd->arrayItems.size() < 2) return invalid("random.accelerationPsd: не меньше двух пар [Гц, (м/с²)²/Гц]");
        for (const auto& pair : psd->arrayItems) {
            if (!pair.isArray() || pair.arrayItems.size() != 2 || pair.arrayItems[0].type != JsonValue::Type::Number
                || pair.arrayItems[1].type != JsonValue::Type::Number || !(pair.arrayItems[0].numberValue > 0.0) || !(pair.arrayItems[1].numberValue > 0.0)) {
                return invalid("random.accelerationPsd: положительные пары [Гц, (м/с²)²/Гц]");
            }
            if (!r.accelerationPsd.empty() && !(pair.arrayItems[0].numberValue > r.accelerationPsd.back().frequencyHz)) {
                return invalid("random.accelerationPsd: частоты должны возрастать");
            }
            r.accelerationPsd.push_back({pair.arrayItems[0].numberValue, pair.arrayItems[1].numberValue});
        }
        if (const JsonValue* masses = random->member("attachedMasses"); masses && masses->isArray()) {
            for (const auto& item : masses->arrayItems) {
                AttachedMass mass;
                mass.faceGroup = item.stringOr("face", "");
                mass.massKg = item.numberOr("massKg", -1.0);
                if (mass.faceGroup.empty() || !(mass.massKg > 0.0)) return invalid("присоединённая масса: face и massKg > 0");
                r.attachedMasses.push_back(mass);
            }
        }
    }

    if (job.analysis == StructuralAnalysis::Shock) {
        const auto& lc = job.loadCase;
        if (!lc.forces.empty() || !lc.pressures.empty() || length(lc.bodyAccelerationMps2) > 0.0) {
            return invalid("испытание на удар задаёт импульс в блоке shock — статические нагрузки уберите из задания");
        }
        const JsonValue* shock = root.member("shock");
        if (shock == nullptr || !shock->isObject()) return invalid("нет shock");
        auto& h = job.shock;
        const double modeCount = shock->numberOr("modeCount", 0.0);
        if (modeCount < 1.0 || modeCount != std::floor(modeCount)) return invalid("shock.modeCount: целое ≥ 1");
        h.modeCount = static_cast<int>(modeCount);
        h.dampingRatio = shock->numberOr("dampingRatio", -1.0);
        if (!(h.dampingRatio > 0.0 && h.dampingRatio < 1.0)) return invalid("shock.dampingRatio: доля критического, 0 < ζ < 1 (умолчания нет)");
        if (!readVector(shock->member("direction"), h.direction) || !(length(h.direction) > 0.0)) return invalid("shock.direction: ненулевой [x, y, z]");
        h.probeFace = shock->stringOr("probeFace", "");
        const JsonValue* pulse = shock->member("pulse");
        if (pulse == nullptr || !pulse->isObject()) return invalid("нет shock.pulse");
        const std::string shape = pulse->stringOr("shape", "");
        if (shape == "halfSine") h.pulse.shape = PulseShape::HalfSine;
        else if (shape == "sawtooth") h.pulse.shape = PulseShape::TerminalPeakSawtooth;
        else if (shape == "trapezoid") h.pulse.shape = PulseShape::Trapezoid;
        else if (shape == "history") h.pulse.shape = PulseShape::TimeHistory;
        else return invalid("shock.pulse.shape: halfSine, sawtooth, trapezoid или history");
        if (h.pulse.shape == PulseShape::TimeHistory) {
            const JsonValue* history = pulse->member("history");
            if (history == nullptr || !history->isArray() || history->arrayItems.size() < 2) return invalid("shock.pulse.history: не меньше двух пар [с, м/с²]");
            for (const auto& pair : history->arrayItems) {
                if (!pair.isArray() || pair.arrayItems.size() != 2 || pair.arrayItems[0].type != JsonValue::Type::Number
                    || pair.arrayItems[1].type != JsonValue::Type::Number || pair.arrayItems[0].numberValue < 0.0) {
                    return invalid("shock.pulse.history: пары [с ≥ 0, м/с²]");
                }
                if (!h.pulse.history.empty() && !(pair.arrayItems[0].numberValue > h.pulse.history.back().first)) return invalid("shock.pulse.history: время должно возрастать");
                h.pulse.history.emplace_back(pair.arrayItems[0].numberValue, pair.arrayItems[1].numberValue);
            }
        } else {
            h.pulse.peakMs2 = pulse->numberOr("peakMps2", 0.0);
            h.pulse.durationS = pulse->numberOr("durationS", 0.0);
            if (!(h.pulse.peakMs2 > 0.0 && h.pulse.durationS > 0.0)) return invalid("shock.pulse: peakMps2 > 0 и durationS > 0");
            if (h.pulse.shape == PulseShape::Trapezoid) {
                h.pulse.riseS = pulse->numberOr("riseS", 0.0);
                h.pulse.fallS = pulse->numberOr("fallS", 0.0);
                if (!(h.pulse.riseS > 0.0 && h.pulse.fallS > 0.0 && h.pulse.riseS + h.pulse.fallS <= h.pulse.durationS)) {
                    return invalid("трапеция: riseS > 0, fallS > 0 и вместе не длиннее durationS");
                }
            }
        }
        if (const JsonValue* masses = shock->member("attachedMasses"); masses && masses->isArray()) {
            for (const auto& item : masses->arrayItems) {
                AttachedMass mass;
                mass.faceGroup = item.stringOr("face", "");
                mass.massKg = item.numberOr("massKg", -1.0);
                if (mass.faceGroup.empty() || !(mass.massKg > 0.0)) return invalid("присоединённая масса: face и massKg > 0");
                h.attachedMasses.push_back(mass);
            }
        }
    }

    if (job.analysis == StructuralAnalysis::Bird) {
        const auto& lc = job.loadCase;
        if (!lc.forces.empty() || !lc.pressures.empty() || length(lc.bodyAccelerationMps2) > 0.0) {
            return invalid("удар птицы задаёт нагрузку сам — статические нагрузки уберите из задания");
        }
        const JsonValue* node = root.member("bird");
        if (node == nullptr || !node->isObject()) return invalid("нет bird");
        auto& b = job.bird;
        const double modeCount = node->numberOr("modeCount", 0.0);
        if (modeCount < 1.0 || modeCount != std::floor(modeCount)) return invalid("bird.modeCount: целое ≥ 1");
        b.modeCount = static_cast<int>(modeCount);
        b.dampingRatio = node->numberOr("dampingRatio", -1.0);
        if (!(b.dampingRatio > 0.0 && b.dampingRatio < 1.0)) return invalid("bird.dampingRatio: доля критического, 0 < ζ < 1 (умолчания нет)");
        b.impactFace = node->stringOr("impactFace", "");
        if (b.impactFace.empty()) return invalid("bird.impactFace: грань, в которую попадает птица (умолчания нет)");
        if (!readVector(node->member("direction"), b.direction) || !(length(b.direction) > 0.0)) return invalid("bird.direction: ненулевой [x, y, z]");
        const JsonValue* bird = node->member("bird");
        if (bird == nullptr || !bird->isObject()) return invalid("нет bird.bird — масса и скорость птицы");
        b.bird.massKg = bird->numberOr("massKg", 1.81);
        if (!(b.bird.massKg > 0.0)) return invalid("bird.bird.massKg: масса птицы > 0 (1.81 кг = 4 фунта по 25.571(e), 3.63 кг для оперения)");
        b.bird.speedMps = bird->numberOr("speedMps", 0.0);
        if (!(b.bird.speedMps > 0.0)) return invalid("bird.bird.speedMps: скорость встречи > 0 (умолчания нет)");
        const double obliquityDeg = bird->numberOr("obliquityDeg", 90.0);
        if (!(obliquityDeg > 0.0) || obliquityDeg > 90.0) return invalid("bird.bird.obliquityDeg: от 0 (скользящий) до 90 (в лоб)");
        b.bird.obliquityRad = obliquityDeg * M_PI / 180.0;
        b.bird.densityKgM3 = bird->numberOr("densityKgM3", 950.0);
        if (!(b.bird.densityKgM3 > 0.0)) return invalid("bird.bird.densityKgM3: плотность тела птицы > 0");
        b.bird.lengthToDiameter = bird->numberOr("lengthToDiameter", 2.0);
        if (!(b.bird.lengthToDiameter > 0.0)) return invalid("bird.bird.lengthToDiameter: удлинение тела > 0");
        b.bird.shockSpeedMps = bird->numberOr("shockSpeedMps", 1480.0);
        if (!(b.bird.shockSpeedMps > 0.0)) return invalid("bird.bird.shockSpeedMps: скорость звука в теле птицы > 0");
        b.bird.shockSlope = bird->numberOr("shockSlope", 2.0);
        if (!(b.bird.shockSlope >= 0.0)) return invalid("bird.bird.shockSlope: наклон ударной адиабаты ≥ 0");
        if (const JsonValue* masses = node->member("attachedMasses"); masses && masses->isArray()) {
            for (const auto& item : masses->arrayItems) {
                AttachedMass mass;
                mass.faceGroup = item.stringOr("face", "");
                mass.massKg = item.numberOr("massKg", -1.0);
                if (mass.faceGroup.empty() || !(mass.massKg > 0.0)) return invalid("присоединённая масса: face и massKg > 0");
                b.attachedMasses.push_back(mass);
            }
        }
    }

    if (job.analysis == StructuralAnalysis::Climate) {
        const auto& lc = job.loadCase;
        if (!lc.forces.empty() || !lc.pressures.empty() || length(lc.bodyAccelerationMps2) > 0.0) {
            return invalid("климатическое испытание нагружает деталь температурой — статические нагрузки уберите из задания");
        }
        const JsonValue* climate = root.member("climate");
        if (climate == nullptr || !climate->isObject()) return invalid("нет climate");
        auto& c = job.climate;
        const std::string environment = climate->stringOr("environment", "");
        if (environment == "hot") c.environment = ClimateEnvironment::Hot;
        else if (environment == "cold") c.environment = ClimateEnvironment::Cold;
        else return invalid("climate.environment: hot или cold");
        const bool hot = c.environment == ClimateEnvironment::Hot;
        const std::string category = climate->stringOr("category", "");
        if (hot && category == "A1") c.hotCategory = HotCategory::A1HotDry;
        else if (hot && category == "A2") c.hotCategory = HotCategory::A2BasicHot;
        else if (!hot && category == "C1") c.coldCategory = ColdCategory::C1BasicCold;
        else if (!hot && category == "C2") c.coldCategory = ColdCategory::C2Cold;
        else if (!hot && category == "C3") c.coldCategory = ColdCategory::C3SevereCold;
        else return invalid(hot ? "climate.category для жары: A1 или A2" : "climate.category для холода: C1, C2 или C3");
        const std::string exposure = climate->stringOr("exposure", "");
        if (hot && exposure == "sun") c.hotExposure = HotExposure::Sun;
        else if (hot && exposure == "shade") c.hotExposure = HotExposure::Shade;
        else if (hot && exposure == "induced") c.hotExposure = HotExposure::Induced;
        else if (!hot && exposure == "ambient") c.coldExposure = ColdExposure::Ambient;
        else if (!hot && exposure == "induced") c.coldExposure = ColdExposure::Induced;
        else return invalid(hot ? "climate.exposure для жары: sun, shade или induced" : "climate.exposure для холода: ambient или induced");
        const std::string airflow = climate->stringOr("airflow", "chamber");
        if (airflow == "chamber") c.airflow = ClimateAirflow::Chamber;
        else if (airflow == "flight") c.airflow = ClimateAirflow::Flight;
        else return invalid("climate.airflow: chamber или flight");
        c.airSpeedMps = climate->numberOr("airSpeedMps", 0.0);
        if (!(c.airSpeedMps > 0.0)) return invalid("climate.airSpeedMps > 0 (умолчания нет)");
        c.altitudeM = climate->numberOr("altitudeM", 0.0);
        if (c.airflow == ClimateAirflow::Flight && !(c.altitudeM >= 0.0 && c.altitudeM <= 11000.0)) return invalid("climate.altitudeM: 0…11000");
        if (climate->member("upDirection") && (!readVector(climate->member("upDirection"), c.upDirection) || !(length(c.upDirection) > 0.0))) {
            return invalid("climate.upDirection: ненулевой [x, y, z]");
        }
        if (climate->member("flowDirection") && (!readVector(climate->member("flowDirection"), c.flowDirection) || !(length(c.flowDirection) > 0.0))) {
            return invalid("climate.flowDirection: ненулевой [x, y, z]");
        }
        c.emissivity = climate->numberOr("emissivity", 0.0);
        if (!(c.emissivity > 0.0 && c.emissivity <= 1.0)) return invalid("climate.emissivity: 0 < ε ≤ 1 — свойство покрытия, умолчания нет");
        c.solarAbsorptance = climate->numberOr("solarAbsorptance", 0.0);
        if (hot && c.hotExposure == HotExposure::Sun && !(c.solarAbsorptance > 0.0 && c.solarAbsorptance <= 1.0)) {
            return invalid("climate.solarAbsorptance: 0 < α ≤ 1 — свойство покрытия, умолчания нет");
        }
        c.stressFreeK = climate->numberOr("stressFreeK", 0.0);
        if (!(c.stressFreeK > 0.0)) return invalid("climate.stressFreeK: температура сборки в кельвинах (умолчания нет)");
        if (const JsonValue* operating = climate->member("operating"); operating && operating->type == JsonValue::Type::Bool) c.operating = operating->boolValue;
        if (const JsonValue* components = climate->member("components"); components && components->isArray()) {
            for (const auto& item : components->arrayItems) {
                ClimateComponent component;
                component.name = item.stringOr("name", "");
                component.face = item.stringOr("face", "");
                component.powerW = item.numberOr("powerW", 0.0);
                if (component.name.empty() || component.face.empty() || !(component.powerW >= 0.0)) return invalid("компонент: name, face и powerW ≥ 0");
                if (const JsonValue* v = item.member("minimumK")) {
                    if (v->type != JsonValue::Type::Number || !(v->numberValue > 0.0)) return invalid("компонент: minimumK в кельвинах");
                    component.minimumK = v->numberValue;
                }
                if (const JsonValue* v = item.member("maximumK")) {
                    if (v->type != JsonValue::Type::Number || !(v->numberValue > 0.0)) return invalid("компонент: maximumK в кельвинах");
                    component.maximumK = v->numberValue;
                }
                if (component.minimumK && component.maximumK && !(*component.minimumK < *component.maximumK)) return invalid("компонент: minimumK < maximumK");
                c.components.push_back(component);
            }
        }
        if (const JsonValue* v = climate->member("materialMinimumK")) {
            if (v->type != JsonValue::Type::Number || !(v->numberValue > 0.0)) return invalid("climate.materialMinimumK в кельвинах");
            c.materialMinimumK = v->numberValue;
        }
        if (const JsonValue* v = climate->member("materialMaximumK")) {
            if (v->type != JsonValue::Type::Number || !(v->numberValue > 0.0)) return invalid("climate.materialMaximumK в кельвинах");
            c.materialMaximumK = v->numberValue;
        }
        c.convectionBand = climate->numberOr("convectionBand", 0.25);
        if (!(c.convectionBand >= 0.0 && c.convectionBand < 1.0)) return invalid("climate.convectionBand: 0…1");
        c.stepS = climate->numberOr("stepS", 0.0);
        if (hot && !(c.stepS > 0.0)) return invalid("climate.stepS: шаг по времени, с (умолчания нет)");
    }

    if (job.analysis == StructuralAnalysis::Fire) {
        const JsonValue* fire = root.member("fire");
        if (fire == nullptr || !fire->isObject()) return invalid("нет fire");
        auto& f = job.fire;
        const std::string standard = fire->stringOr("standard", "");
        if (standard == "iso2685") f.standard = FireStandard::Iso2685;
        else if (standard == "ac20135") f.standard = FireStandard::Ac20135;
        else return invalid("fire.standard: iso2685 или ac20135");
        f.durationS = fire->numberOr("durationS", 0.0);
        if (!(f.durationS > 0.0)) return invalid("fire.durationS > 0 (300 — огнестойкий, 900 — огненепроницаемый; умолчания нет)");
        if (const JsonValue* faces = fire->member("flameFaces"); faces && faces->isArray()) {
            for (const auto& face : faces->arrayItems) {
                if (face.type != JsonValue::Type::String || face.stringValue.empty()) return invalid("fire.flameFaces: имена граней");
                f.flameFaces.push_back(face.stringValue);
            }
        }
        if (f.flameFaces.empty()) return invalid("fire.flameFaces: не задано ни одной грани под пламенем");
        f.surfaceEmissivity = fire->numberOr("surfaceEmissivity", 0.0);
        if (!(f.surfaceEmissivity > 0.0 && f.surfaceEmissivity <= 1.0)) return invalid("fire.surfaceEmissivity: 0 < ε ≤ 1 (EN 1999-1-2: 0.3 чистая, 0.7 окрашенная)");
        f.stepS = fire->numberOr("stepS", 0.0);
        if (!(f.stepS > 0.0)) return invalid("fire.stepS: шаг по времени, с (умолчания нет)");
        if (const JsonValue* operating = fire->member("operating"); operating && operating->type == JsonValue::Type::Bool) f.operating = operating->boolValue;
        if (const auto message = readComponents(fire->member("components"), f.components)) return invalid(*message);
    }

    if (job.analysis == StructuralAnalysis::Lightning) {
        const JsonValue* lightning = root.member("lightning");
        if (lightning == nullptr || !lightning->isObject()) return invalid("нет lightning");
        auto& l = job.lightning;
        if (const JsonValue* components = lightning->member("components"); components && components->isArray()) {
            for (const auto& item : components->arrayItems) {
                if (item.stringValue == "A") l.components.push_back(LightningComponent::A);
                else if (item.stringValue == "B") l.components.push_back(LightningComponent::B);
                else if (item.stringValue == "C") l.components.push_back(LightningComponent::C);
                else if (item.stringValue == "D") l.components.push_back(LightningComponent::D);
                else return invalid("lightning.components: A, B, C или D");
            }
        }
        if (l.components.empty()) return invalid("lightning.components: не задано ни одной компоненты тока");
        auto faces = [&](const char* key, std::vector<std::string>& out) -> bool {
            const JsonValue* list = lightning->member(key);
            if (list == nullptr || !list->isArray()) return false;
            for (const auto& item : list->arrayItems) {
                if (item.type != JsonValue::Type::String || item.stringValue.empty()) return false;
                out.push_back(item.stringValue);
            }
            return !out.empty();
        };
        if (!faces("attachmentFaces", l.attachmentFaces)) return invalid("lightning.attachmentFaces: имена граней привязки дуги");
        if (!faces("groundFaces", l.groundFaces)) return invalid("lightning.groundFaces: имена граней отвода тока");
        const std::string polarity = lightning->stringOr("polarity", "anode");
        if (polarity == "anode") l.polarity = ArcPolarity::Anode;
        else if (polarity == "cathode") l.polarity = ArcPolarity::Cathode;
        else return invalid("lightning.polarity: anode или cathode");
        l.continuingCurrentA = lightning->numberOr("continuingCurrentA", 400.0);
        if (l.continuingCurrentA < 200.0 || l.continuingCurrentA > 800.0) return invalid("lightning.continuingCurrentA: 200…800 А (ARP5412, компонента C)");
        l.surfaceEmissivity = lightning->numberOr("surfaceEmissivity", 0.0);
        if (!(l.surfaceEmissivity > 0.0 && l.surfaceEmissivity <= 1.0)) return invalid("lightning.surfaceEmissivity: 0 < ε ≤ 1 (EN 1999-1-2: 0.3 чистая, 0.7 окрашенная)");
        const double steps = lightning->numberOr("stepsPerComponent", 500.0);
        if (steps < 20.0 || steps != std::floor(steps)) return invalid("lightning.stepsPerComponent: целое ≥ 20");
        l.stepsPerComponent = static_cast<int>(steps);
        if (const auto message = readComponents(lightning->member("equipment"), l.equipment)) return invalid(*message);
    }

    if (job.analysis == StructuralAnalysis::Emc) {
        const JsonValue* emc = root.member("emc");
        if (emc == nullptr || !emc->isObject()) return invalid("нет emc");
        auto& e = job.emc;
        const std::string incidence = emc->stringOr("incidence", "");
        if (incidence.size() != 2 || (incidence[0] != '+' && incidence[0] != '-') || !readAxis(incidence.substr(1), e.incidence)) {
            return invalid("emc.incidence: +x, -x, +y, -y, +z или -z");
        }
        e.forward = incidence[0] == '+';
        if (!readAxis(emc->stringOr("polarization", ""), e.polarization)) return invalid("emc.polarization: x, y или z");
        if (e.polarization == e.incidence) return invalid("emc.polarization: должна быть поперечной к направлению прихода волны");
        e.levelId = emc->stringOr("level", "");
        e.fieldVm = emc->numberOr("fieldVm", 0.0);
        if (e.levelId.empty() && !(e.fieldVm > 0.0)) return invalid("emc: нужен level из таблиц стандарта или fieldVm в вольтах на метр");
        if (!e.levelId.empty() && em::radiatedLevel(e.levelId) == nullptr) return invalid("emc.level: нет данных об уровне «" + e.levelId + "»");
        e.lowHz = emc->numberOr("lowHz", 0.0);
        e.highHz = emc->numberOr("highHz", 0.0);
        if (!(e.lowHz > 0.0) || !(e.highHz > e.lowHz)) return invalid("emc.lowHz / emc.highHz: развёртка по частоте");
        const double points = emc->numberOr("points", 0.0);
        if (points < 2.0 || points != std::floor(points)) return invalid("emc.points: целое ≥ 2");
        e.points = static_cast<int>(points);
        e.surfaceElementSizeM = emc->numberOr("surfaceElementSizeM", 0.0);
        e.pmlCells = static_cast<int>(emc->numberOr("pmlCells", 8.0));
        e.marginCells = static_cast<int>(emc->numberOr("marginCells", 4.0));
        if (e.pmlCells < 4 || e.marginCells < 2) return invalid("emc.pmlCells ≥ 4 и emc.marginCells ≥ 2");
        const JsonValue* equipment = emc->member("equipment");
        if (equipment == nullptr || !equipment->isArray() || equipment->arrayItems.empty()) {
            return invalid("emc.equipment: хотя бы одна точка оборудования внутри корпуса");
        }
        for (const auto& item : equipment->arrayItems) {
            EmcProbe probe;
            probe.name = item.stringOr("name", "");
            const JsonValue* x = item.member("x");
            const JsonValue* y = item.member("y");
            const JsonValue* z = item.member("z");
            if (probe.name.empty() || x == nullptr || y == nullptr || z == nullptr) return invalid("emc.equipment: нужны name и координаты x, y, z");
            probe.x = x->numberValue, probe.y = y->numberValue, probe.z = z->numberValue;
            probe.immunityVm = item.numberOr("immunityVm", 0.0);
            e.equipment.push_back(std::move(probe));
        }
    }

    if (job.analysis == StructuralAnalysis::Icing) {
        const JsonValue* icing = root.member("icing");
        if (icing == nullptr || !icing->isObject()) return invalid("нет icing");
        auto& i = job.icing;
        if (!readAxisIndex(icing->stringOr("flowAxis", "x"), i.flowAxis)) return invalid("icing.flowAxis: x, y или z");
        if (!readAxisIndex(icing->stringOr("spanAxis", "y"), i.spanAxis)) return invalid("icing.spanAxis: x, y или z");
        if (i.flowAxis == i.spanAxis) return invalid("icing: ось потока и ось размаха должны различаться");
        i.angleOfAttackRad = icing->numberOr("angleOfAttackDeg", 0.0) * M_PI / 180.0;
        i.stations = static_cast<int>(icing->numberOr("stations", 3.0));
        i.panels = static_cast<int>(icing->numberOr("panels", 240.0));
        i.trajectories = static_cast<int>(icing->numberOr("trajectories", 200.0));
        i.refinementFactor = icing->numberOr("refinementFactor", 1.5);
        i.surfaceElementSizeM = icing->numberOr("surfaceElementSizeM", 0.0);
        if (i.stations < 1) return invalid("icing.stations: хотя бы одно сечение");
        if (i.panels < 60 || i.trajectories < 20) return invalid("icing: от 60 панелей и 20 траекторий");
        if (!(i.refinementFactor >= 1.2)) return invalid("icing.refinementFactor: не меньше 1.2");
        if (!(i.surfaceElementSizeM > 0.0)) return invalid("icing.surfaceElementSizeM: размер элемента поверхности");
        const JsonValue* condition = icing->member("condition");
        if (condition == nullptr) return invalid("нет icing.condition");
        if (condition->type == JsonValue::Type::String) {
            if (condition->stringValue != "takeoffMaximum") {
                return invalid("нет данных: условие «" + condition->stringValue + "» (конверты Приложения C заданы кривыми, задайте числа)");
            }
            const JsonValue* flight = icing->member("flight");
            if (flight == nullptr || !flight->isObject()) return invalid("нет icing.flight: скорость и длительность");
            i.conditionId = condition->stringValue;
            i.condition = takeoffMaximumIcing(flight->numberOr("airspeedMps", 0.0), flight->numberOr("durationS", 0.0));
        } else if (condition->isObject()) {
            i.condition.temperatureK = condition->numberOr("temperatureC", 1.0) + kMeltingPointK;
            i.condition.lwcKgM3 = condition->numberOr("lwcGm3", 0.0) * 1e-3;
            i.condition.dropletDiameterM = condition->numberOr("dropletMicrons", 0.0) * 1e-6;
            i.condition.altitudeM = condition->numberOr("altitudeM", 0.0);
            i.condition.airspeedMps = condition->numberOr("airspeedMps", 0.0);
            i.condition.durationS = condition->numberOr("durationS", 0.0);
            i.condition.source = "задано в задании";
        } else {
            return invalid("icing.condition: имя условия или числа");
        }
        if (i.condition.temperatureK >= kMeltingPointK) return invalid("icing.condition.temperatureC: должна быть ниже нуля");
        if (!(i.condition.lwcKgM3 > 0.0)) return invalid("icing.condition.lwcGm3: водность облака");
        if (!(i.condition.dropletDiameterM > 0.0)) return invalid("icing.condition.dropletMicrons: размер капель");
        if (!(i.condition.airspeedMps > 0.0)) return invalid("icing.condition.airspeedMps: скорость полёта");
        if (!(i.condition.durationS > 0.0)) return invalid("icing.condition.durationS: длительность в облаке");
        const double target = icing->numberOr("antiIceTargetC", 0.0);
        i.antiIceTargetK = target != 0.0 ? target + kMeltingPointK : 0.0;
        i.antiIceBudgetW = icing->numberOr("antiIceBudgetW", 0.0);
        i.maximumIceThicknessM = icing->numberOr("maximumIceThicknessMm", 0.0) * 1e-3;
    }

    if (job.analysis == StructuralAnalysis::Flutter) {
        const JsonValue* flutter = root.member("flutter");
        if (flutter == nullptr || !flutter->isObject()) return invalid("нет flutter");
        auto& f = job.flutter;
        if (!readAxisIndex(flutter->stringOr("flowAxis", "x"), f.flowAxis)) return invalid("flutter.flowAxis: x, y или z");
        if (!readAxisIndex(flutter->stringOr("spanAxis", "y"), f.spanAxis)) return invalid("flutter.spanAxis: x, y или z");
        if (f.flowAxis == f.spanAxis) return invalid("flutter: ось потока и ось размаха должны различаться");
        f.stations = static_cast<int>(flutter->numberOr("stations", 12.0));
        if (f.stations < 4) return invalid("flutter.stations: не меньше четырёх полос");
        f.airDensityKgM3 = flutter->numberOr("airDensityKgM3", 1.225);
        if (!(f.airDensityKgM3 > 0.0)) return invalid("flutter.airDensityKgM3: плотность воздуха");
        f.structuralDamping = flutter->numberOr("structuralDamping", 0.0);
        if (f.structuralDamping < 0.0) return invalid("flutter.structuralDamping: не отрицательное");
        f.diveSpeedMps = flutter->numberOr("diveSpeedMps", 0.0);
        f.marginFactor = flutter->numberOr("marginFactor", 1.15);
        if (!(f.marginFactor >= 1.0)) return invalid("flutter.marginFactor: не меньше единицы (регламент требует 1.15)");
        f.lowSpeedMps = flutter->numberOr("lowSpeedMps", 5.0);
        f.highSpeedMps = flutter->numberOr("highSpeedMps", 300.0);
        f.speeds = static_cast<int>(flutter->numberOr("speeds", 300.0));
        if (!(f.highSpeedMps > f.lowSpeedMps) || f.speeds < 10) return invalid("flutter: развёртка по скорости");
        if (job.loadCase.supports.empty()) return invalid("flutter: нужен закреплённый корень (опора в нагрузочном случае)");
    }

    const JsonValue* output = root.member("output");
    if (output == nullptr || !output->isObject()) return invalid("нет output");
    job.resultPath = resolve(output->stringOr("result", ""));
    job.fieldPath = resolve(output->stringOr("field", ""));
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
    const bool harmonic = job.analysis == StructuralAnalysis::Harmonic;
    const bool random = job.analysis == StructuralAnalysis::Random;
    const bool shock = job.analysis == StructuralAnalysis::Shock;
    const bool climate = job.analysis == StructuralAnalysis::Climate;
    const bool fire = job.analysis == StructuralAnalysis::Fire;
    const bool lightning = job.analysis == StructuralAnalysis::Lightning;
    const bool emc = job.analysis == StructuralAnalysis::Emc;
    const bool icing = job.analysis == StructuralAnalysis::Icing;
    const bool flutter = job.analysis == StructuralAnalysis::Flutter;
    const bool bird = job.analysis == StructuralAnalysis::Bird;
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kStructuralJobSchema));
    root.set("analysis", JsonValue::makeString(modal       ? "modal"
                                               : harmonic  ? "harmonic"
                                               : random    ? "random"
                                               : shock     ? "shock"
                                               : climate   ? "climate"
                                               : fire      ? "fire"
                                               : lightning ? "lightning"
                                               : emc       ? "emc"
                                               : icing     ? "icing"
                                               : flutter   ? "flutter"
                                               : bird      ? "bird"
                                                           : "static"));
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
    if (harmonic) root.set("harmonic", harmonicJobJson(job.harmonic));
    if (random) root.set("random", randomJobJson(job.random));
    if (shock) root.set("shock", shockJobJson(job.shock));
    if (climate) root.set("climate", climateJobJson(job.climate));
    if (fire) root.set("fire", fireJobJson(job.fire));
    if (lightning) root.set("lightning", lightningJobJson(job.lightning));
    if (emc) root.set("emc", emcJobJson(job.emc));
    if (icing) root.set("icing", icingJobJson(job.icing));
    if (bird) root.set("bird", birdJobJson(job.bird));
    if (flutter) root.set("flutter", flutterJobJson(job.flutter));
    JsonValue output = JsonValue::makeObject();
    output.set("result", JsonValue::makeString(job.resultPath));
    if (!job.fieldPath.empty()) output.set("field", JsonValue::makeString(job.fieldPath));
    root.set("output", std::move(output));
    return root.serialize();
}

std::string structuralErrorJson(const std::string& message, const StructuralJob* job) {
    const bool modal = job != nullptr && job->analysis == StructuralAnalysis::Modal;
    const bool harmonic = job != nullptr && job->analysis == StructuralAnalysis::Harmonic;
    const bool random = job != nullptr && job->analysis == StructuralAnalysis::Random;
    const bool shock = job != nullptr && job->analysis == StructuralAnalysis::Shock;
    const bool climate = job != nullptr && job->analysis == StructuralAnalysis::Climate;
    const bool fire = job != nullptr && job->analysis == StructuralAnalysis::Fire;
    const bool lightning = job != nullptr && job->analysis == StructuralAnalysis::Lightning;
    const bool emc = job != nullptr && job->analysis == StructuralAnalysis::Emc;
    const bool icing = job != nullptr && job->analysis == StructuralAnalysis::Icing;
    const bool flutter = job != nullptr && job->analysis == StructuralAnalysis::Flutter;
    const bool bird = job != nullptr && job->analysis == StructuralAnalysis::Bird;
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(modal       ? kModalResultSchema
                                             : harmonic  ? kHarmonicResultSchema
                                             : random    ? kRandomResultSchema
                                             : shock     ? kShockResultSchema
                                             : climate   ? kClimateResultSchema
                                             : fire      ? kFireResultSchema
                                             : lightning ? kLightningResultSchema
                                             : emc       ? kEmcResultSchema
                                             : icing     ? kIcingResultSchema
                                             : flutter   ? kFlutterResultSchema
                                             : bird      ? kBirdResultSchema
                                                         : kStructuralResultSchema));
    root.set("testType", JsonValue::makeString(modal || harmonic || random ? "modalVibration"
                                               : shock                     ? "mechanicalShock"
                                               : climate                   ? "climatic"
                                               : fire                      ? "fireResistance"
                                               : lightning                 ? "lightningDirect"
                                               : emc                       ? "radiatedSusceptibility"
                                               : icing                     ? "icing"
                                               : flutter                   ? "flutter"
                                               : bird                      ? "birdStrike"
                                                                           : "structuralStatic"));
    root.set("outcome", JsonValue::makeString("error"));
    root.set("solverID", JsonValue::makeString(modal       ? kModalSolverID
                                               : harmonic  ? kHarmonicSolverID
                                               : random    ? kRandomSolverID
                                               : shock     ? kShockSolverID
                                               : climate   ? kClimateSolverID
                                               : fire      ? kFireSolverID
                                               : lightning ? kLightningSolverID
                                               : emc       ? kEmcSolverID
                                               : icing     ? kIcingSolverID
                                               : flutter   ? kFlutterSolverID
                                               : bird      ? kBirdStrikeSolverID
                                                           : kStructuralSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText("netgen")));
    root.set("metrics", JsonValue::makeObject());
    root.set("warnings", JsonValue::makeArray());
    root.set("failureReasons", strings({message}));
    JsonValue settings = JsonValue::makeObject();
    if (job != nullptr) settings.set("loadCase", loadCaseJson(job->loadCase));
    if (modal) settings.set("modal", modalJobJson(job->modal));
    if (harmonic) settings.set("harmonic", harmonicJobJson(job->harmonic));
    if (random) settings.set("random", randomJobJson(job->random));
    if (shock) settings.set("shock", shockJobJson(job->shock));
    if (climate) settings.set("climate", climateJobJson(job->climate));
    if (fire) settings.set("fire", fireJobJson(job->fire));
    if (lightning) settings.set("lightning", lightningJobJson(job->lightning));
    if (emc) settings.set("emc", emcJobJson(job->emc));
    if (icing) settings.set("icing", icingJobJson(job->icing));
    if (flutter) settings.set("flutter", flutterJobJson(job->flutter));
    if (bird) settings.set("bird", birdJobJson(job->bird));
    root.set("settings", std::move(settings));
    return root.serialize();
}

namespace {

JsonValue surfaceFieldJson(const StructuralSurfaceField& field, const IsotropicMaterial& material, double factorOfSafety,
                           const Vec3& criticalPoint);

} // namespace

std::string structuralFieldJson(const StructuralStudyResult& result) {
    return surfaceFieldJson(result.field, result.material, result.factorOfSafety, result.criticalPoint).serialize();
}

std::string shockFieldJson(const ShockStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, result.factorOfSafety, result.criticalPoint);
    JsonValue shock = JsonValue::makeObject();
    shock.set("timeS", JsonValue::makeNumber(result.finest.timeS[result.finest.worstSample]));
    shock.set("stress", JsonValue::makeString("vonMisesAtWorstInstant"));
    shock.set("displacement", JsonValue::makeString("atWorstInstant"));
    root.set("shock", std::move(shock));
    return root.serialize();
}

std::string randomFieldJson(const RandomStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, result.factorOfSafety, result.criticalPoint);
    JsonValue vibration = JsonValue::makeObject();
    vibration.set("stress", JsonValue::makeString("threeSigmaRmsVonMises"));
    vibration.set("displacement", JsonValue::makeString("none"));
    root.set("vibration", std::move(vibration));
    return root.serialize();
}

std::string harmonicFieldJson(const HarmonicStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, result.factorOfSafety, result.criticalPoint);
    // The colours are the utilisation of the stress AMPLITUDE at one frequency, peak over the cycle,
    // and the shape is one instant of the motion — a viewer must say so.
    JsonValue vibration = JsonValue::makeObject();
    vibration.set("frequencyHz", JsonValue::makeNumber(result.samples[result.worstSample].frequencyHz));
    vibration.set("stress", JsonValue::makeString("peakVonMisesOverCycle"));
    vibration.set("displacement", JsonValue::makeString("instantOfLargestMotion"));
    root.set("vibration", std::move(vibration));
    return root.serialize();
}

namespace {

JsonValue surfaceFieldJson(const StructuralSurfaceField& field, const IsotropicMaterial& material, double factorOfSafety,
                           const Vec3& criticalPoint) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kStructuralFieldSchema));
    root.set("lengthUnit", JsonValue::makeString("m"));
    root.set("stressUnit", JsonValue::makeString("Pa"));
    JsonValue nodes = JsonValue::makeArray();
    JsonValue displacement = JsonValue::makeArray();
    JsonValue vonMises = JsonValue::makeArray();
    for (std::size_t n = 0; n < field.nodes.size(); ++n) {
        for (int c = 0; c < 3; ++c) {
            nodes.arrayItems.push_back(JsonValue::makeNumber(field.nodes[n][c]));
            displacement.arrayItems.push_back(JsonValue::makeNumber(field.displacement[n][c]));
        }
        vonMises.arrayItems.push_back(JsonValue::makeNumber(field.vonMisesPa[n]));
    }
    root.set("nodes", std::move(nodes));
    root.set("displacement", std::move(displacement));
    root.set("vonMisesPa", std::move(vonMises));
    putTriangles(root, field.triangles, field.triangleFace);

    // What every viewer needs to draw this honestly (see StructuralPresentation.hpp).
    const auto allowable = presentation::allowableStress(material, factorOfSafety);
    root.set("allowableStressPa", JsonValue::makeNumber(allowable.stressPa));
    root.set("allowableBasis", JsonValue::makeString(allowable.basis == AllowableBasis::Yield ? "yield" : "ultimateOverFactorOfSafety"));
    root.set("factorOfSafety", JsonValue::makeNumber(factorOfSafety));
    root.set("criticalPoint", vector(criticalPoint));
    Vec3 low = field.nodes.empty() ? Vec3{} : field.nodes.front();
    Vec3 high = low;
    double maxDisplacement = 0.0;
    for (std::size_t n = 0; n < field.nodes.size(); ++n) {
        const Vec3& p = field.nodes[n];
        low = {std::min(low.x, p.x), std::min(low.y, p.y), std::min(low.z, p.z)};
        high = {std::max(high.x, p.x), std::max(high.y, p.y), std::max(high.z, p.z)};
        maxDisplacement = std::max(maxDisplacement, length(field.displacement[n]));
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
    return root;
}

} // namespace

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

namespace cadnext::fea {

HarmonicStudySettings harmonicStudySettings(const StructuralJob& job) {
    HarmonicStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.criteria = job.settings.criteria;
    settings.modeCount = job.harmonic.modeCount;
    settings.dampingRatio = job.harmonic.dampingRatio;
    settings.minimumHz = job.harmonic.minimumHz;
    settings.maximumHz = job.harmonic.maximumHz;
    settings.sweepPoints = job.harmonic.sweepPoints;
    settings.excitation = job.harmonic.excitation;
    settings.attachedMasses = job.harmonic.attachedMasses;
    settings.probeFace = job.harmonic.probeFace;
    settings.stressExclusions = job.loadCase.stressExclusions;
    return settings;
}

std::string harmonicResultJson(const HarmonicStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kHarmonicResultSchema));
    root.set("testType", JsonValue::makeString("modalVibration"));
    const auto& assessment = result.assessment;
    const char* outcome = assessment.verdict == StrengthVerdict::Pass      ? "pass"
                          : assessment.verdict == StrengthVerdict::Warning ? "warning"
                                                                           : "fail";
    root.set("outcome", JsonValue::makeString(outcome));
    root.set("solverID", JsonValue::makeString(kHarmonicSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    const auto& worst = result.samples[result.worstSample];
    JsonValue metrics = JsonValue::makeObject();
    const auto& stress = result.stressConvergence;
    putMetric(metrics, "peakDynamicStressPa", assessment.limitStressPa, "Pa",
              stress.isUsable() ? std::optional<double>(stress.uncertaintyAbsolute) : std::nullopt);
    putMetric(metrics, "peakStressFrequencyHz", worst.frequencyHz, "Hz");
    std::optional<double> marginBand;
    if (assessment.conservativeMargin) marginBand = assessment.governingMargin - *assessment.conservativeMargin;
    putMetric(metrics, "reserveFactor", assessment.reserveFactor, "1", marginBand);
    putMetric(metrics, "ultimateMargin", assessment.ultimateMargin, "1");
    if (assessment.yieldMargin) putMetric(metrics, "yieldMargin", *assessment.yieldMargin, "1");
    double displacement = 0.0, probeAcceleration = 0.0;
    for (const auto& sample : result.samples) {
        displacement = std::max(displacement, sample.maxDisplacementM);
        probeAcceleration = std::max(probeAcceleration, sample.probeAccelerationMs2);
    }
    putMetric(metrics, "peakDisplacementM", displacement, "m");
    if (!job.harmonic.probeFace.empty()) putMetric(metrics, "peakProbeAccelerationMps2", probeAcceleration, "m/s2");
    putMetric(metrics, "effectiveMassFraction", result.effectiveMassFraction, "1"); // NaN (force) is left out
    if (!result.modeFrequenciesHz.empty()) putMetric(metrics, "firstFrequencyHz", result.modeFrequenciesHz.front(), "Hz");
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

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("factorOfSafety", JsonValue::makeNumber(job.settings.criteria.factorOfSafety));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("harmonic", harmonicJobJson(job.harmonic));
    root.set("settings", std::move(settings));

    JsonValue critical = JsonValue::makeObject();
    critical.set("point", vector(result.criticalPoint));
    critical.set("face", JsonValue::makeString(result.criticalFace));
    critical.set("frequencyHz", JsonValue::makeNumber(worst.frequencyHz));
    root.set("criticalRegion", std::move(critical));

    // The response of the finest mesh over the sweep, column by column.
    JsonValue response = JsonValue::makeObject();
    std::vector<double> f, a, s, d, pd, pa;
    for (const auto& sample : result.samples) {
        f.push_back(sample.frequencyHz);
        a.push_back(sample.excitation);
        s.push_back(sample.maxVonMisesPa);
        d.push_back(sample.maxDisplacementM);
        pd.push_back(sample.probeDisplacementM);
        pa.push_back(sample.probeAccelerationMs2);
    }
    response.set("frequencyHz", numbers(f));
    response.set("excitation", numbers(a));
    response.set("excitationUnit", JsonValue::makeString(job.harmonic.excitation.kind == HarmonicExcitationKind::BaseAcceleration ? "m/s2" : "N"));
    response.set("maxVonMisesPa", numbers(s));
    response.set("maxDisplacementM", numbers(d));
    if (!job.harmonic.probeFace.empty()) {
        response.set("probeDisplacementM", numbers(pd));
        response.set("probeAccelerationMps2", numbers(pa));
    }
    root.set("response", std::move(response));
    root.set("modeFrequenciesHz", numbers(result.modeFrequenciesHz));
    root.set("dampingRatio", JsonValue::makeNumber(result.dampingRatio));
    root.set("totalMassKg", JsonValue::makeNumber(result.totalMassKg));
    root.set("attachedMassKg", JsonValue::makeNumber(result.attachedMassKg));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("peakDynamicStressPa", JsonValue::makeNumber(level.peakVonMisesPa));
        item.set("peakFrequencyHz", JsonValue::makeNumber(level.peakFrequencyHz));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("stress", convergenceJson(stress));
    root.set("convergence", std::move(convergence));
    root.set("material", materialJson(result.material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

} // namespace cadnext::fea

namespace cadnext::fea {

RandomStudySettings randomStudySettings(const StructuralJob& job) {
    RandomStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.criteria = job.settings.criteria;
    settings.modeCount = job.random.modeCount;
    settings.dampingRatio = job.random.dampingRatio;
    settings.direction = job.random.direction;
    settings.accelerationPsd = job.random.accelerationPsd;
    settings.attachedMasses = job.random.attachedMasses;
    settings.probeFace = job.random.probeFace;
    settings.stressExclusions = job.loadCase.stressExclusions;
    return settings;
}

std::string randomResultJson(const RandomStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kRandomResultSchema));
    root.set("testType", JsonValue::makeString("modalVibration"));
    const auto& assessment = result.assessment;
    const char* outcome = assessment.verdict == StrengthVerdict::Pass      ? "pass"
                          : assessment.verdict == StrengthVerdict::Warning ? "warning"
                                                                           : "fail";
    root.set("outcome", JsonValue::makeString(outcome));
    root.set("solverID", JsonValue::makeString(kRandomSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    const auto& finest = result.finest;
    const auto& stress = result.stressConvergence;
    JsonValue metrics = JsonValue::makeObject();
    putMetric(metrics, "rmsVonMisesPa", result.levels.back().maxRmsVonMisesPa, "Pa",
              stress.isUsable() ? std::optional<double>(stress.uncertaintyAbsolute) : std::nullopt);
    putMetric(metrics, "threeSigmaStressPa", assessment.limitStressPa, "Pa",
              stress.isUsable() ? std::optional<double>(3.0 * stress.uncertaintyAbsolute) : std::nullopt);
    std::optional<double> marginBand;
    if (assessment.conservativeMargin) marginBand = assessment.governingMargin - *assessment.conservativeMargin;
    putMetric(metrics, "reserveFactor", assessment.reserveFactor, "1", marginBand);
    putMetric(metrics, "ultimateMargin", assessment.ultimateMargin, "1");
    if (assessment.yieldMargin) putMetric(metrics, "yieldMargin", *assessment.yieldMargin, "1");
    putMetric(metrics, "inputRmsAccelerationMps2", finest.inputRmsMs2, "m/s2");
    putMetric(metrics, "rmsDisplacementM", finest.maxRmsDisplacementM, "m");
    if (!job.random.probeFace.empty()) putMetric(metrics, "probeRmsAccelerationMps2", finest.probeRmsAccelerationMs2, "m/s2");
    putMetric(metrics, "stressApparentFrequencyHz", finest.criticalApparentFrequencyHz, "Hz");
    putMetric(metrics, "effectiveMassFraction", finest.effectiveMassFraction, "1");
    if (!result.modeFrequenciesHz.empty()) putMetric(metrics, "firstFrequencyHz", result.modeFrequenciesHz.front(), "Hz");
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

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("factorOfSafety", JsonValue::makeNumber(job.settings.criteria.factorOfSafety));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("random", randomJobJson(job.random));
    root.set("settings", std::move(settings));

    JsonValue critical = JsonValue::makeObject();
    critical.set("point", vector(result.criticalPoint));
    critical.set("face", JsonValue::makeString(result.criticalFace));
    root.set("criticalRegion", std::move(critical));

    // Spectra on the finest mesh's integration grid.
    JsonValue spectra = JsonValue::makeObject();
    spectra.set("frequencyHz", numbers(finest.frequencyHz));
    spectra.set("inputPsd", numbers(finest.inputPsd));
    spectra.set("criticalStressPsd", numbers(finest.criticalStressPsd));
    if (!job.random.probeFace.empty()) spectra.set("probeAccelerationPsd", numbers(finest.probeAccelerationPsd));
    root.set("spectra", std::move(spectra));
    root.set("modeFrequenciesHz", numbers(result.modeFrequenciesHz));
    root.set("dampingRatio", JsonValue::makeNumber(result.dampingRatio));
    root.set("totalMassKg", JsonValue::makeNumber(result.totalMassKg));
    root.set("attachedMassKg", JsonValue::makeNumber(result.attachedMassKg));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("rmsVonMisesPa", JsonValue::makeNumber(level.maxRmsVonMisesPa));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("stress", convergenceJson(stress));
    root.set("convergence", std::move(convergence));
    root.set("material", materialJson(result.material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

} // namespace cadnext::fea

namespace cadnext::fea {

ShockStudySettings shockStudySettings(const StructuralJob& job) {
    ShockStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.criteria = job.settings.criteria;
    settings.modeCount = job.shock.modeCount;
    settings.dampingRatio = job.shock.dampingRatio;
    settings.direction = job.shock.direction;
    settings.pulse = job.shock.pulse;
    settings.attachedMasses = job.shock.attachedMasses;
    settings.probeFace = job.shock.probeFace;
    settings.stressExclusions = job.loadCase.stressExclusions;
    return settings;
}

std::string shockResultJson(const ShockStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kShockResultSchema));
    root.set("testType", JsonValue::makeString("mechanicalShock"));
    const auto& assessment = result.assessment;
    const char* outcome = assessment.verdict == StrengthVerdict::Pass      ? "pass"
                          : assessment.verdict == StrengthVerdict::Warning ? "warning"
                                                                           : "fail";
    root.set("outcome", JsonValue::makeString(outcome));
    root.set("solverID", JsonValue::makeString(kShockSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    const auto& finest = result.finest;
    const auto& stress = result.stressConvergence;
    JsonValue metrics = JsonValue::makeObject();
    putMetric(metrics, "peakStressPa", assessment.limitStressPa, "Pa",
              stress.isUsable() ? std::optional<double>(stress.uncertaintyAbsolute) : std::nullopt);
    putMetric(metrics, "peakTimeS", finest.timeS[finest.worstSample], "s");
    std::optional<double> marginBand;
    if (assessment.conservativeMargin) marginBand = assessment.governingMargin - *assessment.conservativeMargin;
    putMetric(metrics, "reserveFactor", assessment.reserveFactor, "1", marginBand);
    putMetric(metrics, "ultimateMargin", assessment.ultimateMargin, "1");
    if (assessment.yieldMargin) putMetric(metrics, "yieldMargin", *assessment.yieldMargin, "1");
    if (!job.shock.probeFace.empty()) {
        double acceleration = 0.0, displacement = 0.0;
        for (double v : finest.probeAccelerationMs2) acceleration = std::max(acceleration, std::fabs(v));
        for (double v : finest.probeDisplacementM) displacement = std::max(displacement, std::fabs(v));
        putMetric(metrics, "peakProbeAccelerationMps2", acceleration, "m/s2");
        putMetric(metrics, "peakProbeDisplacementM", displacement, "m");
    }
    double input = 0.0;
    for (double v : finest.baseAccelerationMs2) input = std::max(input, std::fabs(v));
    putMetric(metrics, "peakInputAccelerationMps2", input, "m/s2");
    putMetric(metrics, "effectiveMassFraction", finest.effectiveMassFraction, "1");
    if (!result.modeFrequenciesHz.empty()) putMetric(metrics, "firstFrequencyHz", result.modeFrequenciesHz.front(), "Hz");
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

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("factorOfSafety", JsonValue::makeNumber(job.settings.criteria.factorOfSafety));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("shock", shockJobJson(job.shock));
    root.set("settings", std::move(settings));

    JsonValue critical = JsonValue::makeObject();
    critical.set("point", vector(result.criticalPoint));
    critical.set("face", JsonValue::makeString(result.criticalFace));
    critical.set("timeS", JsonValue::makeNumber(finest.timeS[finest.worstSample]));
    root.set("criticalRegion", std::move(critical));

    // Time histories, at most 4000 points: every k-th sample, and within each run of k the largest
    // stress kept at its own instant, so the peak survives the thinning.
    JsonValue history = JsonValue::makeObject();
    {
        const std::size_t n = finest.timeS.size();
        const std::size_t stride = std::max<std::size_t>(1, (n + 3999) / 4000);
        std::vector<double> t, a, s, pa, pd;
        for (std::size_t i0 = 0; i0 < n; i0 += stride) {
            std::size_t pick = i0;
            for (std::size_t i = i0; i < std::min(n, i0 + stride); ++i)
                if (finest.maxVonMisesPa[i] > finest.maxVonMisesPa[pick]) pick = i;
            t.push_back(finest.timeS[pick]);
            a.push_back(finest.baseAccelerationMs2[pick]);
            s.push_back(finest.maxVonMisesPa[pick]);
            if (!finest.probeAccelerationMs2.empty()) {
                pa.push_back(finest.probeAccelerationMs2[pick]);
                pd.push_back(finest.probeDisplacementM[pick]);
            }
        }
        history.set("timeS", numbers(t));
        history.set("baseAccelerationMps2", numbers(a));
        history.set("maxVonMisesPa", numbers(s));
        if (!job.shock.probeFace.empty()) {
            history.set("probeAccelerationMps2", numbers(pa));
            history.set("probeDisplacementM", numbers(pd));
        }
    }
    root.set("history", std::move(history));
    JsonValue srs = JsonValue::makeObject();
    srs.set("frequencyHz", numbers(result.srsFrequencyHz));
    srs.set("accelerationMps2", numbers(result.srsAccelerationMps2));
    srs.set("dampingRatio", JsonValue::makeNumber(0.05));
    root.set("inputSrs", std::move(srs));
    root.set("modeFrequenciesHz", numbers(result.modeFrequenciesHz));
    root.set("dampingRatio", JsonValue::makeNumber(result.dampingRatio));
    root.set("totalMassKg", JsonValue::makeNumber(result.totalMassKg));
    root.set("attachedMassKg", JsonValue::makeNumber(result.attachedMassKg));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("peakStressPa", JsonValue::makeNumber(level.peakVonMisesPa));
        item.set("peakTimeS", JsonValue::makeNumber(level.peakTimeS));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("stress", convergenceJson(stress));
    root.set("convergence", std::move(convergence));
    root.set("material", materialJson(result.material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

BirdStrikeStudySettings birdStrikeStudySettings(const StructuralJob& job) {
    BirdStrikeStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.criteria = job.settings.criteria;
    settings.modeCount = job.bird.modeCount;
    settings.dampingRatio = job.bird.dampingRatio;
    settings.impactFace = job.bird.impactFace;
    settings.direction = job.bird.direction;
    settings.bird = job.bird.bird;
    settings.attachedMasses = job.bird.attachedMasses;
    settings.stressExclusions = job.loadCase.stressExclusions;
    return settings;
}

std::string birdFieldJson(const BirdStrikeStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, result.factorOfSafety, result.criticalPoint);
    JsonValue bird = JsonValue::makeObject();
    bird.set("timeS", JsonValue::makeNumber(result.finest.timeS[result.finest.worstSample]));
    bird.set("stress", JsonValue::makeString("vonMisesAtWorstInstant"));
    bird.set("displacement", JsonValue::makeString("atWorstInstant"));
    root.set("bird", std::move(bird));
    return root.serialize();
}

std::string birdResultJson(const BirdStrikeStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kBirdResultSchema));
    root.set("testType", JsonValue::makeString("birdStrike"));
    const auto& assessment = result.assessment;
    const char* outcome = assessment.verdict == StrengthVerdict::Pass      ? "pass"
                          : assessment.verdict == StrengthVerdict::Warning ? "warning"
                                                                           : "fail";
    root.set("outcome", JsonValue::makeString(outcome));
    root.set("solverID", JsonValue::makeString(kBirdStrikeSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    const auto& finest = result.finest;
    const auto& impact = result.impact;
    const auto& stress = result.stressConvergence;
    JsonValue metrics = JsonValue::makeObject();
    putMetric(metrics, "peakStressPa", assessment.limitStressPa, "Pa",
              stress.isUsable() ? std::optional<double>(stress.uncertaintyAbsolute) : std::nullopt);
    putMetric(metrics, "peakTimeS", finest.timeS[finest.worstSample], "s");
    std::optional<double> marginBand;
    if (assessment.conservativeMargin) marginBand = assessment.governingMargin - *assessment.conservativeMargin;
    putMetric(metrics, "reserveFactor", assessment.reserveFactor, "1", marginBand);
    putMetric(metrics, "ultimateMargin", assessment.ultimateMargin, "1");
    if (assessment.yieldMargin) putMetric(metrics, "yieldMargin", *assessment.yieldMargin, "1");
    putMetric(metrics, "normalSpeedMps", impact.normalSpeedMps, "m/s");
    putMetric(metrics, "impulseNs", impact.normalMomentumNs, "N*s");
    putMetric(metrics, "energyJ", impact.energyJ, "J");
    putMetric(metrics, "peakForceN", finest.peakForceN, "N");
    putMetric(metrics, "hugoniotPressurePa", impact.hugoniotPressurePa, "Pa");
    putMetric(metrics, "steadyPressurePa", impact.steadyPressurePa, "Pa");
    putMetric(metrics, "impactDurationS", impact.totalDurationS, "s");
    putMetric(metrics, "shockDurationS", impact.shockDurationS, "s");
    putMetric(metrics, "shockImpulseFraction", result.shockImpulseFraction, "1");
    putMetric(metrics, "birdAreaM2", impact.areaM2, "m2");
    putMetric(metrics, "impactFaceAreaM2", result.impactFaceAreaM2, "m2");
    putMetric(metrics, "patchRatio", result.patchRatio, "1");
    putMetric(metrics, "highestModeHz", result.highestModeHz, "Hz");
    if (!result.modeFrequenciesHz.empty()) putMetric(metrics, "firstFrequencyHz", result.modeFrequenciesHz.front(), "Hz");
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

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("factorOfSafety", JsonValue::makeNumber(job.settings.criteria.factorOfSafety));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("bird", birdJobJson(job.bird));
    root.set("settings", std::move(settings));

    JsonValue critical = JsonValue::makeObject();
    critical.set("point", vector(result.criticalPoint));
    critical.set("face", JsonValue::makeString(result.criticalFace));
    critical.set("timeS", JsonValue::makeNumber(finest.timeS[finest.worstSample]));
    root.set("criticalRegion", std::move(critical));

    // The bird's own load, phase by phase: what pressure acts and for how long.
    JsonValue load = JsonValue::makeObject();
    load.set("diameterM", JsonValue::makeNumber(impact.diameterM));
    load.set("lengthM", JsonValue::makeNumber(impact.lengthM));
    load.set("areaM2", JsonValue::makeNumber(impact.areaM2));
    load.set("normalSpeedMps", JsonValue::makeNumber(impact.normalSpeedMps));
    load.set("hugoniotPressurePa", JsonValue::makeNumber(impact.hugoniotPressurePa));
    load.set("steadyPressurePa", JsonValue::makeNumber(impact.steadyPressurePa));
    load.set("shockDurationS", JsonValue::makeNumber(impact.shockDurationS));
    load.set("decayDurationS", JsonValue::makeNumber(impact.decayDurationS));
    load.set("steadyDurationS", JsonValue::makeNumber(impact.steadyDurationS));
    load.set("totalDurationS", JsonValue::makeNumber(impact.totalDurationS));
    load.set("geometricDurationS", JsonValue::makeNumber(impact.geometricDurationS));
    load.set("normalMomentumNs", JsonValue::makeNumber(impact.normalMomentumNs));
    load.set("deliveredImpulseNs", JsonValue::makeNumber(finest.impulseNs));
    root.set("load", std::move(load));

    // Time histories, thinned as the shock result's are: the peak stress survives the thinning.
    JsonValue history = JsonValue::makeObject();
    {
        const std::size_t n = finest.timeS.size();
        const std::size_t stride = std::max<std::size_t>(1, (n + 3999) / 4000);
        std::vector<double> t, f, s;
        for (std::size_t i0 = 0; i0 < n; i0 += stride) {
            std::size_t pick = i0;
            for (std::size_t i = i0; i < std::min(n, i0 + stride); ++i)
                if (finest.maxVonMisesPa[i] > finest.maxVonMisesPa[pick]) pick = i;
            t.push_back(finest.timeS[pick]);
            f.push_back(finest.forceN[pick]);
            s.push_back(finest.maxVonMisesPa[pick]);
        }
        history.set("timeS", numbers(t));
        history.set("forceN", numbers(f));
        history.set("maxVonMisesPa", numbers(s));
    }
    root.set("history", std::move(history));
    root.set("modeFrequenciesHz", numbers(result.modeFrequenciesHz));
    root.set("dampingRatio", JsonValue::makeNumber(result.dampingRatio));
    root.set("totalMassKg", JsonValue::makeNumber(result.totalMassKg));
    root.set("attachedMassKg", JsonValue::makeNumber(result.attachedMassKg));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("peakStressPa", JsonValue::makeNumber(level.peakVonMisesPa));
        item.set("peakTimeS", JsonValue::makeNumber(level.peakTimeS));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("stress", convergenceJson(stress));
    root.set("convergence", std::move(convergence));
    root.set("material", materialJson(result.material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

} // namespace cadnext::fea

namespace cadnext::fea {

namespace {

const char* verdictOutcome(StrengthVerdict verdict) {
    return verdict == StrengthVerdict::Pass ? "pass" : verdict == StrengthVerdict::Warning ? "warning" : "fail";
}

JsonValue temperatureCheckJson(const TemperatureCheck& check) {
    JsonValue item = JsonValue::makeObject();
    item.set("limit", JsonValue::makeString(check.upper ? "maximum" : "minimum"));
    item.set("valueK", JsonValue::makeNumber(check.valueK));
    item.set("uncertaintyK", JsonValue::makeNumber(check.uncertaintyK));
    item.set("limitK", JsonValue::makeNumber(check.limitK));
    item.set("outcome", JsonValue::makeString(verdictOutcome(check.verdict)));
    return item;
}

} // namespace

ClimateStudySettings climateStudySettings(const StructuralJob& job) {
    ClimateStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.criteria = job.settings.criteria;
    const auto& c = job.climate;
    settings.environment = c.environment;
    settings.hotCategory = c.hotCategory;
    settings.hotExposure = c.hotExposure;
    settings.coldCategory = c.coldCategory;
    settings.coldExposure = c.coldExposure;
    settings.airflow = c.airflow;
    settings.airSpeedMps = c.airSpeedMps;
    settings.altitudeM = c.altitudeM;
    settings.upDirection = c.upDirection;
    settings.flowDirection = c.flowDirection;
    settings.solarAbsorptance = c.solarAbsorptance;
    settings.emissivity = c.emissivity;
    settings.stressFreeK = c.stressFreeK;
    settings.operating = c.operating;
    settings.components = c.components;
    settings.materialMinimumK = c.materialMinimumK;
    settings.materialMaximumK = c.materialMaximumK;
    settings.convectionBand = c.convectionBand;
    settings.stepS = c.stepS;
    settings.stressExclusions = job.loadCase.stressExclusions;
    return settings;
}

std::string climateResultJson(const ClimateStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kClimateResultSchema));
    root.set("testType", JsonValue::makeString("climatic"));
    root.set("outcome", JsonValue::makeString(verdictOutcome(result.verdict)));
    root.set("solverID", JsonValue::makeString(kClimateSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    const auto& assessment = result.assessment;
    JsonValue metrics = JsonValue::makeObject();
    putMetric(metrics, "peakTemperatureK", result.peakK, "K", result.peakUncertaintyK);
    putMetric(metrics, "lowTemperatureK", result.lowK, "K", result.lowUncertaintyK);
    const auto& stress = result.stressConvergence;
    putMetric(metrics, "peakThermalStressPa", result.peakStressPa, "Pa",
              stress.isUsable() ? std::optional<double>(stress.uncertaintyAbsolute) : std::nullopt);
    std::optional<double> marginBand;
    if (assessment.conservativeMargin) marginBand = assessment.governingMargin - *assessment.conservativeMargin;
    putMetric(metrics, "reserveFactor", assessment.reserveFactor, "1", marginBand); // infinite (no stress) is left out
    putMetric(metrics, "ultimateMargin", assessment.ultimateMargin, "1");
    if (assessment.yieldMargin) putMetric(metrics, "yieldMargin", *assessment.yieldMargin, "1");
    putMetric(metrics, "convectionCoefficientWm2K", result.convectionWm2K, "W/(m2 K)");
    if (result.transient) putMetric(metrics, "cycles", result.cycles, "1");
    root.set("metrics", std::move(metrics));
    std::vector<std::string> warnings = result.reasons;
    warnings.insert(warnings.end(), result.warnings.begin(), result.warnings.end());
    root.set("warnings", strings(warnings));
    root.set("failureReasons", strings(result.failureReasons));

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("factorOfSafety", JsonValue::makeNumber(job.settings.criteria.factorOfSafety));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("climate", climateJobJson(job.climate));
    root.set("settings", std::move(settings));

    JsonValue environment = JsonValue::makeObject();
    environment.set("source", JsonValue::makeString(result.conditionSource));
    environment.set("airPeakK", JsonValue::makeNumber(result.airPeakK));
    environment.set("airLowK", JsonValue::makeNumber(result.airLowK));
    environment.set("irradiancePeakWm2", JsonValue::makeNumber(result.irradiancePeakWm2));
    environment.set("pressurePa", JsonValue::makeNumber(result.pressurePa));
    root.set("environment", std::move(environment));

    JsonValue heat = JsonValue::makeObject();
    heat.set("characteristicLengthM", JsonValue::makeNumber(result.characteristicLengthM));
    heat.set("convectionWm2K", JsonValue::makeNumber(result.convectionWm2K));
    heat.set("convectionLowWm2K", JsonValue::makeNumber(result.convectionLowWm2K));
    heat.set("convectionHighWm2K", JsonValue::makeNumber(result.convectionHighWm2K));
    heat.set("reynolds", JsonValue::makeNumber(result.reynolds));
    heat.set("laminar", JsonValue::makeBool(result.laminar));
    heat.set("recoveryRiseK", JsonValue::makeNumber(result.recoveryRiseK));
    heat.set("naturalConvectionWm2K", JsonValue::makeNumber(result.naturalConvectionWm2K));
    heat.set("sunlitProjectedAreaM2", JsonValue::makeNumber(result.sunlitProjectedAreaM2));
    heat.set("shadedAreaM2", JsonValue::makeNumber(result.shadedAreaM2));
    heat.set("absorbedSolarPeakW", JsonValue::makeNumber(result.absorbedSolarPeakW));
    heat.set("exposedAreaM2", JsonValue::makeNumber(result.exposedAreaM2));
    heat.set("coveredAreaM2", JsonValue::makeNumber(result.coveredAreaM2));
    root.set("heatExchange", std::move(heat));

    JsonValue time = JsonValue::makeObject();
    time.set("transient", JsonValue::makeBool(result.transient));
    time.set("stepS", JsonValue::makeNumber(result.stepS));
    time.set("cycles", JsonValue::makeNumber(result.cycles));
    time.set("lastCycleChangeK", JsonValue::makeNumber(result.lastCycleChangeK));
    time.set("periodic", JsonValue::makeBool(result.periodic));
    time.set("timeStepErrorK", JsonValue::makeNumber(result.timeStepErrorK));
    root.set("time", std::move(time));

    JsonValue temperature = JsonValue::makeObject();
    temperature.set("peakK", JsonValue::makeNumber(result.peakK));
    temperature.set("peakTimeS", JsonValue::makeNumber(result.peakTimeS));
    temperature.set("peakUncertaintyK", JsonValue::makeNumber(result.peakUncertaintyK));
    temperature.set("peakOtherEdgeK", JsonValue::makeNumber(result.peakOtherEdgeK));
    temperature.set("hottestPoint", vector(result.hottestPoint));
    temperature.set("lowK", JsonValue::makeNumber(result.lowK));
    temperature.set("lowTimeS", JsonValue::makeNumber(result.lowTimeS));
    temperature.set("lowUncertaintyK", JsonValue::makeNumber(result.lowUncertaintyK));
    JsonValue materialChecks = JsonValue::makeArray();
    for (const auto& check : result.materialChecks) materialChecks.arrayItems.push_back(temperatureCheckJson(check));
    temperature.set("materialChecks", std::move(materialChecks));
    root.set("temperature", std::move(temperature));

    JsonValue components = JsonValue::makeArray();
    for (const auto& component : result.components) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(component.name));
        item.set("face", JsonValue::makeString(component.face));
        item.set("powerW", JsonValue::makeNumber(component.powerW));
        item.set("maximumK", JsonValue::makeNumber(component.maximumK));
        item.set("maximumTimeS", JsonValue::makeNumber(component.maximumTimeS));
        item.set("minimumK", JsonValue::makeNumber(component.minimumK));
        item.set("uncertaintyK", JsonValue::makeNumber(component.uncertaintyK));
        item.set("outcome", JsonValue::makeString(verdictOutcome(component.verdict)));
        JsonValue checks = JsonValue::makeArray();
        for (const auto& check : component.checks) checks.arrayItems.push_back(temperatureCheckJson(check));
        item.set("checks", std::move(checks));
        item.set("convergence", convergenceJson(component.maximumConvergence));
        components.arrayItems.push_back(std::move(item));
    }
    root.set("components", std::move(components));

    JsonValue critical = JsonValue::makeObject();
    critical.set("point", vector(result.criticalPoint));
    critical.set("face", JsonValue::makeString(result.criticalFace));
    critical.set("timeS", JsonValue::makeNumber(result.peakStressTimeS));
    critical.set("otherEdgeStressPa", JsonValue::makeNumber(result.peakStressOtherEdgePa));
    root.set("criticalRegion", std::move(critical));

    // The last day on the finest mesh (hot); empty for a cold soak.
    JsonValue series = JsonValue::makeObject();
    series.set("timeS", numbers(result.series.timeS));
    series.set("airK", numbers(result.series.airK));
    series.set("irradianceWm2", numbers(result.series.irradianceWm2));
    series.set("partMaximumK", numbers(result.series.partMaximumK));
    series.set("partMinimumK", numbers(result.series.partMinimumK));
    JsonValue componentSeries = JsonValue::makeArray();
    for (std::size_t c = 0; c < result.series.componentMaximumK.size(); ++c) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(c < result.components.size() ? result.components[c].name : ""));
        item.set("maximumK", numbers(result.series.componentMaximumK[c]));
        componentSeries.arrayItems.push_back(std::move(item));
    }
    series.set("components", std::move(componentSeries));
    root.set("series", std::move(series));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("peakK", JsonValue::makeNumber(level.peakK));
        item.set("lowK", JsonValue::makeNumber(level.lowK));
        item.set("peakStressPa", JsonValue::makeNumber(level.peakStressPa));
        item.set("cycles", JsonValue::makeNumber(level.cycles));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("peakTemperature", convergenceJson(result.peakConvergence));
    convergence.set("lowTemperature", convergenceJson(result.lowConvergence));
    convergence.set("stress", convergenceJson(stress));
    root.set("convergence", std::move(convergence));
    JsonValue material = materialJson(result.material);
    if (result.material.thermalExpansionPerK) material.set("thermalExpansionPerK", JsonValue::makeNumber(*result.material.thermalExpansionPerK));
    if (result.material.thermalConductivityWmK) material.set("thermalConductivityWmK", JsonValue::makeNumber(*result.material.thermalConductivityWmK));
    if (result.material.specificHeatJkgK) material.set("specificHeatJkgK", JsonValue::makeNumber(*result.material.specificHeatJkgK));
    material.set("thermalSource", JsonValue::makeString(result.material.thermalSource));
    root.set("material", std::move(material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

std::string climateFieldJson(const ClimateStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, result.factorOfSafety, result.criticalPoint);
    JsonValue climate = JsonValue::makeObject();
    climate.set("temperatureK", numbers(result.fieldTemperatureK));
    climate.set("temperatureTimeS", JsonValue::makeNumber(result.peakTimeS));
    climate.set("stressTimeS", JsonValue::makeNumber(result.peakStressTimeS));
    climate.set("stress", JsonValue::makeString("vonMisesAtWorstInstant"));
    climate.set("displacement", JsonValue::makeString("atWorstInstant"));
    climate.set("transient", JsonValue::makeBool(result.transient));
    root.set("climate", std::move(climate));
    return root.serialize();
}

} // namespace cadnext::fea

namespace cadnext::fea {

FireStudySettings fireStudySettings(const StructuralJob& job) {
    FireStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.standard = job.fire.standard;
    settings.durationS = job.fire.durationS;
    settings.flameFaces = job.fire.flameFaces;
    settings.surfaceEmissivity = job.fire.surfaceEmissivity;
    settings.stepS = job.fire.stepS;
    settings.operating = job.fire.operating;
    settings.components = job.fire.components;
    settings.forces = job.loadCase.forces;
    settings.pressures = job.loadCase.pressures;
    settings.bodyAccelerationMps2 = job.loadCase.bodyAccelerationMps2;
    settings.stressExclusions = job.loadCase.stressExclusions;
    return settings;
}

namespace {

// At most `limit` points of a history: every k-th, the largest of each run of k kept at its own instant.
void thinned(const std::vector<double>& time, const std::vector<std::vector<double>*>& columns, std::size_t limit, std::vector<double>& outTime,
             std::vector<std::vector<double>>& outColumns, const std::vector<double>& lead) {
    const std::size_t n = time.size();
    const std::size_t stride = std::max<std::size_t>(1, (n + limit - 1) / limit);
    outColumns.assign(columns.size(), {});
    for (std::size_t i0 = 0; i0 < n; i0 += stride) {
        std::size_t pick = i0;
        for (std::size_t i = i0; i < std::min(n, i0 + stride); ++i)
            if (lead[i] > lead[pick]) pick = i;
        if (i0 + stride >= n) pick = n - 1; // the last instant is always there
        outTime.push_back(time[pick]);
        for (std::size_t c = 0; c < columns.size(); ++c) outColumns[c].push_back((*columns[c])[pick]);
    }
}

} // namespace

std::string fireResultJson(const FireStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kFireResultSchema));
    root.set("testType", JsonValue::makeString("fireResistance"));
    root.set("outcome", JsonValue::makeString(verdictOutcome(result.verdict)));
    root.set("solverID", JsonValue::makeString(kFireSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));
    JsonValue metrics = JsonValue::makeObject();
    putMetric(metrics, "peakTemperatureK", result.peakK, "K", result.peakUncertaintyK);
    if (result.integrityLost) putMetric(metrics, "integrityLossTimeS", result.failureTimeS, "s", result.failureUncertaintyS);
    if (result.strengthData) putMetric(metrics, "hotUtilization", result.utilization, "1", result.utilizationUncertainty);
    putMetric(metrics, "requiredDurationS", result.durationS, "s");
    root.set("metrics", std::move(metrics));
    std::vector<std::string> warnings = result.reasons;
    warnings.insert(warnings.end(), result.warnings.begin(), result.warnings.end());
    root.set("warnings", strings(warnings));
    root.set("failureReasons", strings(result.failureReasons));

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("fire", fireJobJson(job.fire));
    root.set("settings", std::move(settings));

    JsonValue flame = JsonValue::makeObject();
    flame.set("source", JsonValue::makeString(result.flame.source));
    flame.set("temperatureK", JsonValue::makeNumber(result.flame.temperatureK));
    flame.set("calibrationFluxWm2", JsonValue::makeNumber(result.flame.calibrationFluxWm2));
    flame.set("convectionWm2K", JsonValue::makeNumber(result.flameConvectionWm2K));
    flame.set("emissivity", JsonValue::makeNumber(result.flameEmissivity));
    flame.set("governingModel", JsonValue::makeString(result.governingModel == FlameModel::Radiative ? "radiative" : "convective"));
    JsonValue models = JsonValue::makeArray();
    for (const auto& model : result.finestModels) {
        JsonValue item = JsonValue::makeObject();
        item.set("model", JsonValue::makeString(model.model == FlameModel::Radiative ? "radiative" : "convective"));
        item.set("peakK", JsonValue::makeNumber(model.peakK));
        item.set("integrityLossTimeS", JsonValue::makeNumber(model.failureTimeS));
        item.set("hotUtilization", JsonValue::makeNumber(model.utilization));
        models.arrayItems.push_back(std::move(item));
    }
    flame.set("models", std::move(models));
    root.set("flame", std::move(flame));

    JsonValue integrity = JsonValue::makeObject();
    integrity.set("lost", JsonValue::makeBool(result.integrityLost));
    integrity.set("timeS", JsonValue::makeNumber(result.failureTimeS));
    integrity.set("uncertaintyS", JsonValue::makeNumber(result.failureUncertaintyS));
    if (result.noStrengthK) integrity.set("noStrengthK", JsonValue::makeNumber(*result.noStrengthK));
    integrity.set("requiredDurationS", JsonValue::makeNumber(result.durationS));
    root.set("integrity", std::move(integrity));
    JsonValue temperature = JsonValue::makeObject();
    temperature.set("peakK", JsonValue::makeNumber(result.peakK));
    temperature.set("uncertaintyK", JsonValue::makeNumber(result.peakUncertaintyK));
    temperature.set("hottestPoint", vector(result.hottestPoint));
    temperature.set("dataValidUpToK", JsonValue::makeNumber(result.dataValidUpToK));
    root.set("temperature", std::move(temperature));
    JsonValue strength = JsonValue::makeObject();
    strength.set("assessed", JsonValue::makeBool(result.strengthData));
    strength.set("utilization", JsonValue::makeNumber(result.utilization));
    strength.set("uncertainty", JsonValue::makeNumber(result.utilizationUncertainty));
    strength.set("timeS", JsonValue::makeNumber(result.utilizationTimeS));
    root.set("strength", std::move(strength));

    JsonValue components = JsonValue::makeArray();
    for (const auto& component : result.components) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(component.name));
        item.set("face", JsonValue::makeString(component.face));
        item.set("powerW", JsonValue::makeNumber(component.powerW));
        item.set("maximumK", JsonValue::makeNumber(component.maximumK));
        item.set("maximumTimeS", JsonValue::makeNumber(component.maximumTimeS));
        item.set("minimumK", JsonValue::makeNumber(component.minimumK));
        item.set("uncertaintyK", JsonValue::makeNumber(component.uncertaintyK));
        item.set("outcome", JsonValue::makeString(verdictOutcome(component.verdict)));
        JsonValue checks = JsonValue::makeArray();
        for (const auto& check : component.checks) checks.arrayItems.push_back(temperatureCheckJson(check));
        item.set("checks", std::move(checks));
        components.arrayItems.push_back(std::move(item));
    }
    root.set("components", std::move(components));
    JsonValue critical = JsonValue::makeObject();
    critical.set("point", vector(result.criticalPoint));
    critical.set("face", JsonValue::makeString(result.criticalFace));
    critical.set("timeS", JsonValue::makeNumber(result.utilizationTimeS));
    root.set("criticalRegion", std::move(critical));

    // Histories of the governing model on the finest mesh, at most 2000 points (the hottest kept).
    JsonValue series = JsonValue::makeObject();
    {
        auto& s = result.series;
        std::vector<std::vector<double>*> columns;
        auto partMax = s.partMaximumK, partMin = s.partMinimumK;
        auto componentMax = s.componentMaximumK;
        columns.push_back(&partMax);
        columns.push_back(&partMin);
        for (auto& c : componentMax) columns.push_back(&c);
        std::vector<double> time;
        std::vector<std::vector<double>> out;
        thinned(s.timeS, columns, 2000, time, out, s.partMaximumK);
        series.set("timeS", numbers(time));
        series.set("partMaximumK", numbers(out[0]));
        series.set("partMinimumK", numbers(out[1]));
        JsonValue componentSeries = JsonValue::makeArray();
        for (std::size_t c = 0; c < componentMax.size(); ++c) {
            JsonValue item = JsonValue::makeObject();
            item.set("name", JsonValue::makeString(c < result.components.size() ? result.components[c].name : ""));
            item.set("maximumK", numbers(out[2 + c]));
            componentSeries.arrayItems.push_back(std::move(item));
        }
        series.set("components", std::move(componentSeries));
        series.set("sampleTimeS", numbers(s.sampleTimeS));
        series.set("utilization", numbers(s.utilization));
    }
    root.set("series", std::move(series));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("peakK", JsonValue::makeNumber(level.peakK));
        item.set("integrityLossTimeS", JsonValue::makeNumber(level.failureTimeS));
        item.set("hotUtilization", JsonValue::makeNumber(level.utilization));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("peakTemperature", convergenceJson(result.peakConvergence));
    convergence.set("integrityLossTime", convergenceJson(result.failureConvergence));
    convergence.set("hotUtilization", convergenceJson(result.utilizationConvergence));
    root.set("convergence", std::move(convergence));
    JsonValue material = materialJson(result.material);
    material.set("hotSource", JsonValue::makeString(result.hotMaterialSource));
    root.set("material", std::move(material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

std::string fireFieldJson(const FireStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, 1.0, result.criticalPoint);
    JsonValue fire = JsonValue::makeObject();
    fire.set("temperatureK", numbers(result.fieldTemperatureK));
    if (result.strengthData) fire.set("utilization", numbers(result.fieldUtilization));
    fire.set("temperatureTimeS", JsonValue::makeNumber(result.integrityLost ? result.failureTimeS : result.durationS));
    fire.set("stressTimeS", JsonValue::makeNumber(result.utilizationTimeS));
    fire.set("utilizationBasis", JsonValue::makeString("vonMises / (k0.2(theta) f0.2), EN 1999-1-2, gamma_M,fi = 1.0"));
    root.set("fire", std::move(fire));
    return root.serialize();
}

} // namespace cadnext::fea

namespace cadnext::fea {

LightningStudySettings lightningStudySettings(const StructuralJob& job) {
    LightningStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.components = job.lightning.components;
    settings.attachmentFaces = job.lightning.attachmentFaces;
    settings.groundFaces = job.lightning.groundFaces;
    settings.polarity = job.lightning.polarity;
    settings.continuingCurrentA = job.lightning.continuingCurrentA;
    settings.surfaceEmissivity = job.lightning.surfaceEmissivity;
    settings.stepsPerComponent = job.lightning.stepsPerComponent;
    settings.equipment = job.lightning.equipment;
    return settings;
}

std::string lightningResultJson(const LightningStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kLightningResultSchema));
    root.set("testType", JsonValue::makeString("lightningDirect"));
    root.set("outcome", JsonValue::makeString(verdictOutcome(result.verdict)));
    root.set("solverID", JsonValue::makeString(kLightningSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));
    JsonValue metrics = JsonValue::makeObject();
    putMetric(metrics, "peakTemperatureK", result.peakK, "K", result.peakUncertaintyK);
    if (result.burnedThrough) putMetric(metrics, "burnThroughTimeS", result.burnThroughTimeS, "s", result.burnThroughUncertaintyS);
    putMetric(metrics, "resistanceOhm", result.resistanceOhm, "Ohm");
    putMetric(metrics, "arcEnergyJ", result.arcEnergyJ, "J");
    putMetric(metrics, "jouleEnergyJ", result.jouleEnergyJ, "J");
    putMetric(metrics, "peakCurrentDensityAm2", result.peakCurrentDensityAm2, "A/m2");
    root.set("metrics", std::move(metrics));
    std::vector<std::string> warnings = result.reasons;
    warnings.insert(warnings.end(), result.warnings.begin(), result.warnings.end());
    root.set("warnings", strings(warnings));
    root.set("failureReasons", strings(result.failureReasons));

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("lightning", lightningJobJson(job.lightning));
    root.set("settings", std::move(settings));

    JsonValue environment = JsonValue::makeObject();
    JsonValue waveforms = JsonValue::makeArray();
    for (const auto& waveform : result.waveforms) {
        JsonValue item = JsonValue::makeObject();
        item.set("source", JsonValue::makeString(waveform.source));
        item.set("peakA", JsonValue::makeNumber(waveform.peakA()));
        item.set("actionIntegralA2s", JsonValue::makeNumber(waveform.actionIntegralA2s()));
        item.set("chargeC", JsonValue::makeNumber(waveform.chargeC()));
        item.set("durationS", JsonValue::makeNumber(waveform.durationS()));
        waveforms.arrayItems.push_back(std::move(item));
    }
    environment.set("waveforms", std::move(waveforms));
    environment.set("peakCurrentA", JsonValue::makeNumber(result.peakCurrentA));
    environment.set("totalChargeC", JsonValue::makeNumber(result.totalChargeC));
    environment.set("totalActionIntegralA2s", JsonValue::makeNumber(result.totalActionIntegralA2s));
    environment.set("arcVoltsPerAmp", JsonValue::makeNumber(result.arcVoltsPerAmp));
    environment.set("attachmentAreaM2", JsonValue::makeNumber(result.attachmentAreaM2));
    environment.set("arcRootRadiusM", JsonValue::makeNumber(result.arcRootRadiusM));
    root.set("strike", std::move(environment));

    JsonValue integrity = JsonValue::makeObject();
    integrity.set("burnedThrough", JsonValue::makeBool(result.burnedThrough));
    integrity.set("timeS", JsonValue::makeNumber(result.burnThroughTimeS));
    integrity.set("uncertaintyS", JsonValue::makeNumber(result.burnThroughUncertaintyS));
    if (result.noStrengthK) integrity.set("noStrengthK", JsonValue::makeNumber(*result.noStrengthK));
    integrity.set("peakK", JsonValue::makeNumber(result.peakK));
    integrity.set("peakUncertaintyK", JsonValue::makeNumber(result.peakUncertaintyK));
    integrity.set("hottestPoint", vector(result.hottestPoint));
    root.set("integrity", std::move(integrity));

    JsonValue equipment = JsonValue::makeArray();
    for (const auto& component : result.equipment) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(component.name));
        item.set("face", JsonValue::makeString(component.face));
        item.set("maximumK", JsonValue::makeNumber(component.maximumK));
        item.set("maximumTimeS", JsonValue::makeNumber(component.maximumTimeS));
        item.set("uncertaintyK", JsonValue::makeNumber(component.uncertaintyK));
        item.set("outcome", JsonValue::makeString(verdictOutcome(component.verdict)));
        JsonValue checks = JsonValue::makeArray();
        for (const auto& check : component.checks) checks.arrayItems.push_back(temperatureCheckJson(check));
        item.set("checks", std::move(checks));
        equipment.arrayItems.push_back(std::move(item));
    }
    root.set("equipment", std::move(equipment));

    JsonValue series = JsonValue::makeObject();
    series.set("timeS", numbers(result.series.timeS));
    series.set("currentA", numbers(result.series.currentA));
    series.set("partMaximumK", numbers(result.series.partMaximumK));
    JsonValue equipmentSeries = JsonValue::makeArray();
    for (std::size_t e = 0; e < result.series.equipmentMaximumK.size(); ++e) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(e < result.equipment.size() ? result.equipment[e].name : ""));
        item.set("maximumK", numbers(result.series.equipmentMaximumK[e]));
        equipmentSeries.arrayItems.push_back(std::move(item));
    }
    series.set("equipment", std::move(equipmentSeries));
    root.set("series", std::move(series));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("peakK", JsonValue::makeNumber(level.peakK));
        item.set("burnThroughTimeS", JsonValue::makeNumber(level.burnThroughTimeS));
        item.set("resistanceOhm", JsonValue::makeNumber(level.resistanceOhm));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("peakTemperature", convergenceJson(result.peakConvergence));
    convergence.set("burnThroughTime", convergenceJson(result.burnThroughConvergence));
    root.set("convergence", std::move(convergence));
    JsonValue material = materialJson(result.material);
    material.set("hotSource", JsonValue::makeString(result.hotMaterialSource));
    if (result.material.electricalResistivityOhmM) {
        material.set("electricalResistivityOhmM", JsonValue::makeNumber(*result.material.electricalResistivityOhmM));
        material.set("electricalSource", JsonValue::makeString(result.material.electricalSource));
    }
    root.set("material", std::move(material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

EmcStudySettings emcStudySettings(const StructuralJob& job) {
    EmcStudySettings settings;
    settings.coarseCellM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.surfaceElementSizeM = job.emc.surfaceElementSizeM;
    settings.incidence = job.emc.incidence;
    settings.forward = job.emc.forward;
    settings.polarization = job.emc.polarization;
    settings.levelId = job.emc.levelId;
    settings.fieldVm = job.emc.fieldVm;
    settings.lowHz = job.emc.lowHz;
    settings.highHz = job.emc.highHz;
    settings.points = job.emc.points;
    settings.probes = job.emc.equipment;
    settings.pmlCells = job.emc.pmlCells;
    settings.marginCells = job.emc.marginCells;
    return settings;
}

std::string emcResultJson(const EmcStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kEmcResultSchema));
    root.set("testType", JsonValue::makeString("radiatedSusceptibility"));
    root.set("outcome", JsonValue::makeString(verdictOutcome(result.verdict)));
    root.set("solverID", JsonValue::makeString(kEmcSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    double worstField = 0.0;
    for (const auto& probe : result.probes) worstField = std::max(worstField, probe.fieldVm);
    JsonValue metrics = JsonValue::makeObject();
    putMetric(metrics, "shieldingEffectivenessDb", result.worstShieldingDb, "dB", result.shieldingUncertaintyDb);
    putMetric(metrics, "interiorFieldVm", worstField, "V/m");
    putMetric(metrics, "worstFrequencyHz", result.worstFrequencyHz, "Hz");
    putMetric(metrics, "cellsPerWavelength", result.cellsPerWavelength, "1");
    root.set("metrics", std::move(metrics));
    std::vector<std::string> warnings = result.reasons;
    warnings.insert(warnings.end(), result.warnings.begin(), result.warnings.end());
    root.set("warnings", strings(warnings));
    root.set("failureReasons", strings(result.failureReasons));

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("emc", emcJobJson(job.emc));
    root.set("settings", std::move(settings));

    JsonValue environment = JsonValue::makeObject();
    environment.set("level", JsonValue::makeString(job.emc.levelId));
    environment.set("description", JsonValue::makeString(result.levelDescription));
    environment.set("fieldVm", JsonValue::makeNumber(result.fieldVm));
    environment.set("lowHz", JsonValue::makeNumber(result.lowHz));
    environment.set("highHz", JsonValue::makeNumber(result.highHz));
    environment.set("frequenciesHz", numbers(result.frequenciesHz));
    environment.set("resonancesHz", numbers(result.resonancesHz));
    environment.set("stepS", JsonValue::makeNumber(result.stepS));
    environment.set("steps", JsonValue::makeNumber(result.steps));
    environment.set("numericalFloorDb", JsonValue::makeNumber(result.numericalFloorDb));
    environment.set("cellsPerWavelength", JsonValue::makeNumber(result.cellsPerWavelength));
    environment.set("voxelVolumeRatio", JsonValue::makeNumber(result.wallCells));
    root.set("environment", std::move(environment));

    JsonValue equipment = JsonValue::makeArray();
    for (const auto& probe : result.probes) {
        JsonValue item = JsonValue::makeObject();
        item.set("name", JsonValue::makeString(probe.name));
        item.set("shieldingDb", numbers(probe.shieldingDb));
        item.set("worstShieldingDb", JsonValue::makeNumber(probe.worstShieldingDb));
        item.set("worstFrequencyHz", JsonValue::makeNumber(probe.worstFrequencyHz));
        item.set("uncertaintyDb", JsonValue::makeNumber(probe.uncertaintyDb));
        item.set("fieldVm", JsonValue::makeNumber(probe.fieldVm));
        item.set("immunityVm", JsonValue::makeNumber(probe.immunityVm));
        item.set("outcome", JsonValue::makeString(probe.outcome));
        equipment.arrayItems.push_back(std::move(item));
    }
    root.set("equipment", std::move(equipment));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("cellM", JsonValue::makeNumber(level.cellM));
        item.set("metalCells", JsonValue::makeNumber(static_cast<double>(level.cells)));
        item.set("grid", JsonValue::makeString(std::to_string(level.nx) + " × " + std::to_string(level.ny) + " × " + std::to_string(level.nz)));
        item.set("worstShieldingDb", JsonValue::makeNumber(level.worstShieldingDb));
        item.set("worstFrequencyHz", JsonValue::makeNumber(level.worstFrequencyHz));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("shielding", convergenceJson(result.shieldingConvergence));
    root.set("convergence", std::move(convergence));
    root.set("material", materialJson(result.material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

IcingStudySettings icingStudySettings(const StructuralJob& job) {
    IcingStudySettings settings;
    settings.flowAxis = job.icing.flowAxis;
    settings.spanAxis = job.icing.spanAxis;
    settings.angleOfAttackRad = job.icing.angleOfAttackRad;
    settings.stations = job.icing.stations;
    settings.panels = job.icing.panels;
    settings.trajectories = job.icing.trajectories;
    settings.refinementFactor = job.icing.refinementFactor;
    settings.condition = job.icing.condition;
    settings.surfaceElementSizeM = job.icing.surfaceElementSizeM;
    settings.antiIceTargetK = job.icing.antiIceTargetK;
    settings.antiIceBudgetW = job.icing.antiIceBudgetW;
    settings.maximumIceThicknessM = job.icing.maximumIceThicknessM;
    return settings;
}

std::string icingResultJson(const IcingStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kIcingResultSchema));
    root.set("testType", JsonValue::makeString("icing"));
    root.set("outcome", JsonValue::makeString(verdictOutcome(result.verdict)));
    root.set("solverID", JsonValue::makeString(kIcingSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    JsonValue metrics = JsonValue::makeObject();
    putMetric(metrics, "iceThicknessM", result.maximumIceThicknessM, "m", result.thicknessUncertaintyM);
    putMetric(metrics, "iceMassKg", result.iceMassKg, "kg");
    putMetric(metrics, "collectionEfficiency", result.collectionEfficiency, "1");
    putMetric(metrics, "inertiaParameter", result.inertiaParameter, "1");
    if (job.icing.antiIceTargetK > 0.0) putMetric(metrics, "antiIcePowerW", result.antiIcePowerW, "W");
    root.set("metrics", std::move(metrics));
    std::vector<std::string> warnings = result.reasons;
    warnings.insert(warnings.end(), result.warnings.begin(), result.warnings.end());
    root.set("warnings", strings(warnings));
    root.set("failureReasons", strings(result.failureReasons));

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("icing", icingJobJson(job.icing));
    root.set("settings", std::move(settings));

    JsonValue cloud = JsonValue::makeObject();
    cloud.set("source", JsonValue::makeString(result.condition.source));
    cloud.set("temperatureK", JsonValue::makeNumber(result.condition.temperatureK));
    cloud.set("lwcKgM3", JsonValue::makeNumber(result.condition.lwcKgM3));
    cloud.set("dropletDiameterM", JsonValue::makeNumber(result.condition.dropletDiameterM));
    cloud.set("airspeedMps", JsonValue::makeNumber(result.condition.airspeedMps));
    cloud.set("durationS", JsonValue::makeNumber(result.condition.durationS));
    cloud.set("altitudeM", JsonValue::makeNumber(result.condition.altitudeM));
    cloud.set("spanM", JsonValue::makeNumber(result.spanM));
    cloud.set("inertiaParameter", JsonValue::makeNumber(result.inertiaParameter));
    cloud.set("heatTransferBandLowM", JsonValue::makeNumber(result.heatTransferBandLow));
    cloud.set("heatTransferBandHighM", JsonValue::makeNumber(result.heatTransferBandHigh));
    root.set("cloud", std::move(cloud));

    JsonValue stations = JsonValue::makeArray();
    for (const auto& station : result.stations) {
        JsonValue item = JsonValue::makeObject();
        item.set("spanPositionM", JsonValue::makeNumber(station.spanPositionM));
        item.set("chordM", JsonValue::makeNumber(station.chordM));
        item.set("collectionEfficiency", JsonValue::makeNumber(station.collectionEfficiency));
        item.set("maximumBeta", JsonValue::makeNumber(station.maximumBeta));
        item.set("iceThicknessM", JsonValue::makeNumber(station.maximumIceThicknessM));
        item.set("iceMassKgPerM", JsonValue::makeNumber(station.iceMassKgPerM));
        item.set("impingementLengthM", JsonValue::makeNumber(station.impingementLengthM));
        item.set("freezingFraction", JsonValue::makeNumber(station.freezingFractionAtStagnation));
        item.set("surfaceTemperatureK", JsonValue::makeNumber(station.surfaceTemperatureK));
        item.set("glaze", JsonValue::makeBool(station.glaze));
        item.set("leadingEdgeRadiusM", JsonValue::makeNumber(station.leadingEdgeRadiusM));
        item.set("stagnationFilmWm2K", JsonValue::makeNumber(station.stagnationFilmWm2K));
        item.set("antiIcePowerWPerM", JsonValue::makeNumber(station.antiIcePowerWPerM));
        item.set("arcLengthM", numbers(station.arcLengthM));
        item.set("beta", numbers(station.betaPerPanel));
        item.set("iceM", numbers(station.iceThicknessM));
        item.set("panelXM", numbers(station.panelXM));
        item.set("panelYM", numbers(station.panelYM));
        stations.arrayItems.push_back(std::move(item));
    }
    root.set("stations", std::move(stations));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("panels", JsonValue::makeNumber(level.panels));
        item.set("trajectories", JsonValue::makeNumber(level.trajectories));
        item.set("iceThicknessM", JsonValue::makeNumber(level.maximumIceThicknessM));
        item.set("collectionEfficiency", JsonValue::makeNumber(level.collectionEfficiency));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("iceThickness", convergenceJson(result.thicknessConvergence));
    root.set("convergence", std::move(convergence));
    root.set("material", materialJson(result.material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

FlutterStudySettings flutterStudySettings(const StructuralJob& job) {
    FlutterStudySettings settings;
    settings.coarseElementSizeM = job.settings.coarseElementSizeM;
    settings.refinementFactor = job.settings.refinementFactor;
    settings.flowAxis = job.flutter.flowAxis;
    settings.spanAxis = job.flutter.spanAxis;
    settings.stations = job.flutter.stations;
    settings.airDensityKgM3 = job.flutter.airDensityKgM3;
    settings.structuralDamping = job.flutter.structuralDamping;
    settings.diveSpeedMps = job.flutter.diveSpeedMps;
    settings.marginFactor = job.flutter.marginFactor;
    settings.lowSpeedMps = job.flutter.lowSpeedMps;
    settings.highSpeedMps = job.flutter.highSpeedMps;
    settings.speeds = job.flutter.speeds;
    settings.supports = job.loadCase.supports;
    return settings;
}

std::string flutterResultJson(const FlutterStudyResult& result, const StructuralJob& job, const std::string& fieldReference) {
    JsonValue root = JsonValue::makeObject();
    root.set("schema", JsonValue::makeString(kFlutterResultSchema));
    root.set("testType", JsonValue::makeString("flutter"));
    root.set("outcome", JsonValue::makeString(verdictOutcome(result.verdict)));
    root.set("solverID", JsonValue::makeString(kFlutterSolverID));
    root.set("solverVersion", JsonValue::makeString(solverVersionText(result.mesherVersion)));

    JsonValue metrics = JsonValue::makeObject();
    if (result.flutterFound) putMetric(metrics, "flutterSpeedMps", result.flutterSpeedMps, "m/s", result.flutterUncertaintyMps);
    if (result.flutterFound) putMetric(metrics, "flutterFrequencyHz", result.flutterFrequencyHz, "Hz");
    if (result.divergenceSpeedMps > 0.0) putMetric(metrics, "divergenceSpeedMps", result.divergenceSpeedMps, "m/s");
    putMetric(metrics, "bendingFrequencyHz", result.bendingHz, "Hz");
    putMetric(metrics, "torsionFrequencyHz", result.torsionHz, "Hz");
    if (result.requiredSpeedMps > 0.0) putMetric(metrics, "requiredSpeedMps", result.requiredSpeedMps, "m/s");
    if (result.requiredSpeedMps > 0.0) putMetric(metrics, "marginFraction", result.marginFraction, "1");
    root.set("metrics", std::move(metrics));
    std::vector<std::string> warnings = result.reasons;
    warnings.insert(warnings.end(), result.warnings.begin(), result.warnings.end());
    root.set("warnings", strings(warnings));
    root.set("failureReasons", strings(result.failureReasons));

    JsonValue settings = JsonValue::makeObject();
    settings.set("material", JsonValue::makeString(result.material.id));
    settings.set("materialDatabaseVersion", JsonValue::makeNumber(kMaterialDatabaseVersion));
    settings.set("coarseElementSizeM", JsonValue::makeNumber(job.settings.coarseElementSizeM));
    settings.set("refinementFactor", JsonValue::makeNumber(job.settings.refinementFactor));
    settings.set("mesher", JsonValue::makeString(result.mesherVersion));
    settings.set("loadCase", loadCaseJson(job.loadCase));
    settings.set("flutter", flutterJobJson(job.flutter));
    root.set("settings", std::move(settings));

    JsonValue surface = JsonValue::makeObject();
    surface.set("spanM", JsonValue::makeNumber(result.spanM));
    surface.set("referenceSemichordM", JsonValue::makeNumber(result.referenceSemichordM));
    surface.set("bendingMode", JsonValue::makeNumber(result.bendingMode));
    surface.set("torsionMode", JsonValue::makeNumber(result.torsionMode));
    surface.set("machAtFlutter", JsonValue::makeNumber(result.machAtFlutter));
    surface.set("flutterFound", JsonValue::makeBool(result.flutterFound));
    JsonValue strips = JsonValue::makeArray();
    for (const auto& strip : result.strips) {
        JsonValue item = JsonValue::makeObject();
        item.set("spanPositionM", JsonValue::makeNumber(strip.spanPositionM));
        item.set("chordM", JsonValue::makeNumber(strip.chordM));
        item.set("elasticAxis", JsonValue::makeNumber(strip.elasticAxis));
        item.set("bendingPlunge", JsonValue::makeNumber(strip.plunge[0]));
        item.set("bendingTwist", JsonValue::makeNumber(strip.twist[0]));
        item.set("torsionPlunge", JsonValue::makeNumber(strip.plunge[1]));
        item.set("torsionTwist", JsonValue::makeNumber(strip.twist[1]));
        strips.arrayItems.push_back(std::move(item));
    }
    surface.set("strips", std::move(strips));
    root.set("surface", std::move(surface));

    JsonValue series = JsonValue::makeObject();
    std::vector<double> speeds, dampingFirst, dampingSecond, frequencyFirst, frequencySecond;
    for (const auto& point : result.branches) {
        if (point.branch == 0) {
            speeds.push_back(point.speedMps);
            dampingFirst.push_back(point.dampingRatio);
            frequencyFirst.push_back(point.frequencyHz);
        } else {
            dampingSecond.push_back(point.dampingRatio);
            frequencySecond.push_back(point.frequencyHz);
        }
    }
    series.set("speedMps", numbers(speeds));
    series.set("dampingFirst", numbers(dampingFirst));
    series.set("dampingSecond", numbers(dampingSecond));
    series.set("frequencyFirst", numbers(frequencyFirst));
    series.set("frequencySecond", numbers(frequencySecond));
    root.set("series", std::move(series));

    JsonValue study = JsonValue::makeArray();
    for (const auto& level : result.levels) {
        JsonValue item = JsonValue::makeObject();
        item.set("maximumElementSizeM", JsonValue::makeNumber(level.maximumElementSizeM));
        item.set("elements", JsonValue::makeNumber(static_cast<double>(level.elements)));
        item.set("bendingHz", JsonValue::makeNumber(level.bendingHz));
        item.set("torsionHz", JsonValue::makeNumber(level.torsionHz));
        item.set("flutterSpeedMps", JsonValue::makeNumber(level.flutterSpeedMps));
        item.set("flutterFrequencyHz", JsonValue::makeNumber(level.flutterFrequencyHz));
        study.arrayItems.push_back(std::move(item));
    }
    root.set("meshStudy", std::move(study));
    JsonValue convergence = JsonValue::makeObject();
    convergence.set("flutterSpeed", convergenceJson(result.speedConvergence));
    root.set("convergence", std::move(convergence));
    root.set("material", materialJson(result.material));
    root.set("fieldRef", JsonValue::makeString(fieldReference));
    return root.serialize();
}

std::string flutterFieldJson(const FlutterStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, 1.0, {});
    JsonValue flutter = JsonValue::makeObject();
    flutter.set("bending", numbers(result.fieldBending));
    flutter.set("torsion", numbers(result.fieldTorsion));
    flutter.set("bendingHz", JsonValue::makeNumber(result.bendingHz));
    flutter.set("torsionHz", JsonValue::makeNumber(result.torsionHz));
    root.set("flutter", std::move(flutter));
    return root.serialize();
}

std::string icingFieldJson(const IcingStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, 1.0, {});
    JsonValue icing = JsonValue::makeObject();
    icing.set("iceThicknessM", numbers(result.fieldIceM));
    icing.set("durationS", JsonValue::makeNumber(result.condition.durationS));
    root.set("icing", std::move(icing));
    return root.serialize();
}

std::string emcFieldJson(const EmcStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, 1.0, {});
    JsonValue emc = JsonValue::makeObject();
    emc.set("fieldVm", numbers(result.fieldEVm));
    emc.set("frequencyHz", JsonValue::makeNumber(result.worstFrequencyHz));
    emc.set("incidentVm", JsonValue::makeNumber(result.fieldVm));
    root.set("emc", std::move(emc));
    return root.serialize();
}

std::string lightningFieldJson(const LightningStudyResult& result) {
    JsonValue root = surfaceFieldJson(result.field, result.material, 1.0, result.hottestPoint);
    JsonValue lightning = JsonValue::makeObject();
    lightning.set("temperatureK", numbers(result.fieldTemperatureK));
    lightning.set("potentialV", numbers(result.fieldPotentialV));
    lightning.set("timeS", JsonValue::makeNumber(result.burnedThrough ? result.burnThroughTimeS : 0.0));
    lightning.set("potentialBasis", JsonValue::makeString("one ampere through the part; the field scales with the current"));
    root.set("lightning", std::move(lightning));
    return root.serialize();
}

} // namespace cadnext::fea
