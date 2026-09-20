#include "cadnext/fea/Lightning.hpp"

#include "cadnext/fea/LinearStatic.hpp" // faceGroupArea
#include "cadnext/fea/TetElement.hpp"
#include "cadnext/fea/Thermal.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

double CurrentWaveform::at(double timeS) const {
    if (timeS < 0.0) return 0.0;
    if (amplitudeA > 0.0) return amplitudeA * (std::exp(-alphaPerS * timeS) - std::exp(-betaPerS * timeS));
    return timeS <= steadyDurationS ? steadyA : 0.0;
}

double CurrentWaveform::durationS() const {
    if (amplitudeA > 0.0) return 10.0 / alphaPerS; // e^{−10} of the slow term is left
    return steadyDurationS;
}

double CurrentWaveform::peakA() const {
    if (amplitudeA <= 0.0) return steadyA;
    const double t = std::log(betaPerS / alphaPerS) / (betaPerS - alphaPerS);
    return at(t);
}

double CurrentWaveform::actionIntegralA2s() const {
    if (amplitudeA <= 0.0) return steadyA * steadyA * steadyDurationS;
    return amplitudeA * amplitudeA * (1.0 / (2.0 * alphaPerS) + 1.0 / (2.0 * betaPerS) - 2.0 / (alphaPerS + betaPerS));
}

double CurrentWaveform::chargeC() const {
    if (amplitudeA <= 0.0) return steadyA * steadyDurationS;
    return amplitudeA * (1.0 / alphaPerS - 1.0 / betaPerS);
}

CurrentWaveform lightningComponent(LightningComponent component) {
    CurrentWaveform w;
    switch (component) {
    case LightningComponent::A:
        w = {218810.0, 11354.0, 647265.0, 0.0, 0.0, "SAE ARP5412 component A: 200 kA ± 10 %, ∫i² dt = 2·10⁶ A² s ± 20 %"};
        break;
    case LightningComponent::B:
        w = {11300.0, 700.0, 2000.0, 0.0, 0.0, "SAE ARP5412 component B: 2 kA average over 5 ms, 10 C ± 10 %"};
        break;
    case LightningComponent::C:
        // The standard leaves the current to the test (200–800 A); 400 A for half a second is its 200 C.
        w = {0.0, 0.0, 0.0, 400.0, 0.5, "SAE ARP5412 component C: 200 C ± 20 % at 200–800 A (here 400 A for 0.5 s)"};
        break;
    case LightningComponent::D:
        w = {109405.0, 22708.0, 1294530.0, 0.0, 0.0, "SAE ARP5412 component D: 100 kA ± 10 %, ∫i² dt = 0.25·10⁶ A² s"};
        break;
    }
    return w;
}

double arcHeatFluxWm2(double currentA, double arcRootRadiusM, ArcPolarity polarity) {
    if (!(arcRootRadiusM > 0.0)) return 0.0;
    const double density = currentA / (M_PI * arcRootRadiusM * arcRootRadiusM);
    return (polarity == ArcPolarity::Anode ? kAnodeVoltsPerCurrent : kCathodeVoltsPerCurrent) * density;
}

Result<CurrentSpread> solveCurrentSpread(const TetMesh& mesh, double resistivityOhmM, const std::vector<std::string>& injectionFaces,
                                         const std::vector<std::string>& groundFaces, double currentA) {
    auto fail = [](ErrorCode code, const std::string& message) { return Result<CurrentSpread>::fail({code, message}); };
    if (!(resistivityOhmM > 0.0)) return fail(ErrorCode::InvalidArgument, "нет данных: удельное электрическое сопротивление материала");
    if (injectionFaces.empty() || groundFaces.empty()) return fail(ErrorCode::InvalidArgument, "нужны грани ввода тока и грани отвода (нулевой потенциал)");
    if (!(currentA > 0.0)) return fail(ErrorCode::InvalidArgument, "ток должен быть положительным");
    double area = 0.0;
    for (const auto& face : injectionFaces) area += faceGroupArea(mesh, face);
    if (!(area > 0.0)) return fail(ErrorCode::NotFound, "нулевая площадь ввода тока");

    // The same steady problem as heat conduction: potential for temperature, conductivity for k, the
    // injected current density for a heat flux, the grounded faces for fixed temperature.
    ThermalProblem problem;
    problem.mesh = &mesh;
    problem.material.conductivityWmK = 1.0 / resistivityOhmM;
    for (const auto& face : groundFaces) problem.fixed.push_back({face, 1.0}); // 1 V, subtracted below: the solver needs T > 0
    for (const auto& face : injectionFaces) problem.fluxes.push_back({face, currentA / area});
    const auto solved = solveSteadyThermal(problem);
    if (!solved.isOk()) return fail(solved.error().code, solved.error().message);

    CurrentSpread spread;
    spread.potentialV.resize(mesh.nodes.size());
    for (std::size_t n = 0; n < mesh.nodes.size(); ++n) spread.potentialV[n] = solved.value().temperatureK[n] - 1.0;
    spread.balanceRelative = solved.value().balanceRelative;

    // Joule heat of every element, σ|∇φ|², from the potential's gradient at the element's quadrature points.
    const double sigma = 1.0 / resistivityOhmM;
    spread.jouleWm3.assign(mesh.elements.size(), 0.0);
    for (std::size_t e = 0; e < mesh.elements.size(); ++e) spread.jouleWm3[e] = sigma * tetMeanSquareGradient(mesh, static_cast<int>(e), spread.potentialV);
    // Resistance between the injection and the ground: the mean potential of the injection faces over the
    // current (the ground is at zero).
    double weighted = 0.0, total = 0.0;
    for (const auto& face : injectionFaces) {
        const auto found = mesh.faceGroups.find(face);
        if (found == mesh.faceGroups.end()) continue;
        const int faceNodeCount = mesh.order == ElementOrder::Quadratic ? 6 : 3;
        for (const auto& boundary : found->second) {
            const auto nodes = mesh.faceNodes(boundary);
            for (const auto& q : triangleQuadratureDegree4()) {
                double N[6], dS[6], dT[6];
                triangleShapeFunctions(mesh.order, q.s, q.t, N, dS, dT);
                Vec3 xs, xt;
                double value = 0.0;
                for (int n = 0; n < faceNodeCount; ++n) {
                    xs += mesh.nodes[nodes[n]] * dS[n];
                    xt += mesh.nodes[nodes[n]] * dT[n];
                    value += N[n] * spread.potentialV[nodes[n]];
                }
                const double dA = length(cross(xs, xt)) * q.weight;
                weighted += value * dA;
                total += dA;
            }
        }
    }
    spread.resistanceOhm = total > 0.0 ? (weighted / total) / currentA : 0.0;
    return Result<CurrentSpread>::ok(std::move(spread));
}

} // namespace cadnext::fea
