#include "cadnext/fea/Pyrolysis.hpp"

#include "cadnext/fea/Thermal.hpp" // kStefanBoltzmann

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

namespace cadnext::fea {

double PiecewiseLinear::at(double temperatureK) const {
    const double low = slope[0] * temperatureK + intercept[0];
    const double high = slope[1] * temperatureK + intercept[1];
    if (temperatureK <= boundaryK - kPropertyBlendK) return low;
    if (temperatureK >= boundaryK + kPropertyBlendK) return high;
    const double w = (temperatureK - (boundaryK - kPropertyBlendK)) / (2.0 * kPropertyBlendK);
    return low * (1.0 - w) + high * w;
}

namespace {

Result<PyrolysisSolution> failure(ErrorCode code, const std::string& message) {
    return Result<PyrolysisSolution>::fail({code, message});
}

// One finite volume: the masses of every condensed species (kg/m²) and the temperature.
struct Cell {
    std::vector<double> mass; // per species; inert layers keep one entry that never changes
    double temperature = 0.0;
    bool inert = false;
    double density = 0.0;         // of the condensed matter, for the cell's thickness
    double fixedThickness = 0.0;  // inert layers
    double specificHeat = 0.0;    // inert layers
    const std::function<double(double)>* conductivity = nullptr; // inert layers
    double total() const {
        double sum = 0.0;
        for (double m : mass) sum += m;
        return sum;
    }
    double thickness() const { return inert ? fixedThickness : total() / density; }
};

// A first-order chain m₀ → y₀ m₁ → y₁ m₂ … at a constant temperature over the step (Bateman): exact, so
// the Arrhenius stiffness never limits the time step.
void advanceSpecies(std::vector<double>& mass, const std::vector<PyrolysisReaction>& reactions, double temperatureK, double dt,
                    std::vector<double>& heatPerArea, double* heatSensitivity = nullptr) {
    const std::size_t species = mass.size();
    std::vector<double> k(species, 0.0);
    for (std::size_t r = 0; r < reactions.size(); ++r) {
        k[r] = reactions[r].preExponentialPerS * std::exp(-reactions[r].activationEnergyJPerMol / (kGasConstant * temperatureK));
    }
    // Rates that coincide would divide by zero in the Bateman coefficients; nudge them apart by a
    // relative 1e-9, far below any physical resolution.
    for (std::size_t r = 1; r < species; ++r)
        for (std::size_t i = 0; i < r; ++i)
            if (std::fabs(k[r] - k[i]) <= 1e-12 * std::max(k[r], k[i])) k[r] = k[i] * (1.0 + 1e-9) + 1e-30;

    std::vector<std::vector<double>> c(species); // c[r][i]: coefficient of e^{−k_i t} in species r
    const std::vector<double> before = mass;
    for (std::size_t r = 0; r < species; ++r) {
        c[r].assign(r + 1, 0.0);
        double sum = 0.0;
        for (std::size_t i = 0; i < r; ++i) {
            const double feed = reactions[r - 1].solidYield * k[r - 1];
            c[r][i] = feed * c[r - 1][i] / (k[r] - k[i]);
            sum += c[r][i];
        }
        c[r][r] = before[r] - sum;
        double value = 0.0;
        for (std::size_t i = 0; i <= r; ++i) value += c[r][i] * std::exp(-k[i] * dt);
        mass[r] = std::max(0.0, value);
    }
    // The heat each reaction absorbed: its own consumption times its heat of reaction.
    heatPerArea.assign(reactions.size(), 0.0);
    for (std::size_t r = 0; r < reactions.size(); ++r) {
        // What left species r by reacting: its drop plus what it received from r−1.
        double received = 0.0;
        if (r > 0) {
            double consumedPrevious = before[r - 1] - mass[r - 1];
            received = reactions[r - 1].solidYield * consumedPrevious;
        }
        const double consumed = std::max(0.0, before[r] + received - mass[r]);
        heatPerArea[r] = consumed * reactions[r].heatOfReactionJPerKg;
        // How much that heat grows with temperature: d(rate)/dT = rate·E/(R T²). Put on the diagonal it
        // keeps the step's iteration from swinging between "hot, so it reacts" and "reacting, so it cools".
        if (heatSensitivity) *heatSensitivity += heatPerArea[r] * reactions[r].activationEnergyJPerMol / (kGasConstant * temperatureK * temperatureK);
    }
}

} // namespace

std::optional<PyrolysisMaterial> pyrolysisMaterial(const std::string& id) {
    if (id == "macfp_pmma_umd") {
        // MaCFP Condensed Phase Material Database (IAFSS working group, MIT licence),
        // PMMA/Material_Properties/2021/MaCFP_PMMA_UMD.json — the set the working group identified in 2023
        // as the one closest to the mean of all submitted models. Calibrated by UMD with ThermaKin from
        // their own TGA, DSC and CAPA measurements of MaCFP-PMMA.
        PyrolysisMaterial m;
        m.id = id;
        m.source = "MaCFP matl-db, MaCFP_PMMA_UMD.json (UMD, ThermaKin calibration; TGA/DSC/CAPA)";
        m.densityKgM3 = 1210.0;
        m.absorptionPerM = 2870.0;
        m.emissivity = 0.96;
        m.specificHeatJkgK = {395.0, {8.33, 3.07}, {-1390.0, 851.0}};
        m.conductivityWmK = {395.0, {0.0, -0.00042}, {0.16, 0.34}};
        m.reactions = {{4.95e16, 164000.0, 0.98, 5000.0}, {1.35e11, 164000.0, 0.002, 817000.0}};
        return m;
    }
    return std::nullopt;
}

Result<PyrolysisSolution> solvePyrolysis(const PyrolysisProblem& problem, const PyrolysisSettings& settings) {
    const auto& material = problem.material;
    if (material.reactions.empty()) return failure(ErrorCode::InvalidArgument, "нет данных: кинетика разложения материала");
    if (!(material.densityKgM3 > 0.0 && material.emissivity > 0.0 && material.absorptionPerM > 0.0)) {
        return failure(ErrorCode::InvalidArgument, "нет данных: плотность, излучательная способность или поглощение материала");
    }
    if (!(problem.thicknessM > 0.0) || problem.cells < 2) return failure(ErrorCode::InvalidArgument, "толщина > 0 и не меньше двух ячеек");
    if (!(settings.stepS > 0.0 && settings.endS > 0.0)) return failure(ErrorCode::InvalidArgument, "шаг и длительность должны быть положительными");
    if (!problem.incidentFluxWm2) return failure(ErrorCode::InvalidArgument, "не задан падающий поток");

    const std::size_t species = material.reactions.size() + 1;
    std::vector<Cell> cells;
    const double dx0 = problem.thicknessM / problem.cells;
    for (int j = 0; j < problem.cells; ++j) {
        Cell cell;
        cell.mass.assign(species, 0.0);
        cell.mass[0] = material.densityKgM3 * dx0;
        cell.temperature = problem.initialK;
        cell.density = material.densityKgM3;
        cells.push_back(std::move(cell));
    }
    const int sampleCells = problem.cells;
    for (const auto& layer : problem.backing) {
        if (!(layer.thicknessM > 0.0 && layer.densityKgM3 > 0.0 && layer.specificHeatJkgK > 0.0) || !layer.conductivityWmK || layer.cells < 1) {
            return failure(ErrorCode::InvalidArgument, "подложка: толщина, плотность, теплоёмкость, теплопроводность и число ячеек");
        }
        for (int j = 0; j < layer.cells; ++j) {
            Cell cell;
            cell.inert = true;
            cell.mass.assign(1, layer.densityKgM3 * layer.thicknessM / layer.cells);
            cell.temperature = problem.initialK;
            cell.fixedThickness = layer.thicknessM / layer.cells;
            cell.specificHeat = layer.specificHeatJkgK;
            cell.conductivity = &layer.conductivityWmK;
            cells.push_back(std::move(cell));
        }
    }

    const double initialMass = material.densityKgM3 * problem.thicknessM;
    PyrolysisSolution solution;
    auto conductivityOf = [&](const Cell& cell) { return cell.inert ? (*cell.conductivity)(cell.temperature) : material.conductivityWmK.at(cell.temperature); };
    auto specificHeatOf = [&](const Cell& cell) { return cell.inert ? cell.specificHeat : material.specificHeatJkgK.at(cell.temperature); };
    auto sampleMass = [&]() {
        double sum = 0.0;
        for (int j = 0; j < sampleCells; ++j) sum += cells[j].total();
        return sum;
    };
    // The rate recorded with a sample is the mean over the interval since the previous one — what a load
    // cell's mass signal gives, and what makes the recorded history integrate to the mass actually lost.
    double lastRecordedMass = 0.0, lastRecordedTime = 0.0;
    auto record = [&](double time) {
        const double now = sampleMass();
        const double interval = time - lastRecordedTime;
        solution.timeS.push_back(time);
        solution.massLossRateGm2s.push_back(interval > 0.0 ? (lastRecordedMass - now) / interval * 1000.0 : 0.0);
        lastRecordedMass = now;
        lastRecordedTime = time;
        int first = 0;
        while (first < sampleCells && cells[first].total() <= 1e-6 * material.densityKgM3 * dx0) ++first;
        solution.surfaceK.push_back(cells[std::min(first, static_cast<int>(cells.size()) - 1)].temperature);
        solution.backOfSampleK.push_back(cells[sampleCells - 1].temperature);
        solution.remainingMassFraction.push_back(sampleMass() / initialMass);
        double thickness = 0.0;
        for (int j = 0; j < sampleCells; ++j) thickness += cells[j].thickness();
        solution.thicknessM.push_back(thickness);
    };
    lastRecordedMass = sampleMass();
    record(0.0);

    const int steps = static_cast<int>(std::ceil(settings.endS / settings.stepS - 1e-9));
    const std::size_t n = cells.size();
    std::vector<double> a(n), b(n), c(n), d(n), previous(n), heat;
    std::vector<std::vector<double>> massBefore(n);
    for (int step = 1; step <= steps; ++step) {
        const double time = step * settings.stepS, dt = settings.stepS;
        const double flux = problem.incidentFluxWm2(time);
        if (!(flux >= 0.0)) return failure(ErrorCode::InvalidArgument, "падающий поток не может быть отрицательным");
        for (std::size_t j = 0; j < n; ++j) {
            previous[j] = cells[j].temperature;
            massBefore[j] = cells[j].mass;
        }
        const double massBeforeStep = sampleMass();
        // Where the surface is for this step, decided from the state at its start: if the iteration were
        // allowed to move it, a cell on the edge of being gone would flip in and out and never converge.
        std::size_t first = 0;
        while (first + 1 < static_cast<std::size_t>(sampleCells) && cells[first].total() <= 1e-6 * material.densityKgM3 * dx0) ++first;
        bool converged = false;
        double worstChange = 0.0;
        std::size_t worstCell = 0;
        for (int iteration = 0; iteration < settings.maximumIterations && !converged; ++iteration) {
            // Species and their heat at the current temperatures (from the state at the step's start).
            std::vector<double> reactionHeat(n, 0.0), reactionSlope(n, 0.0);
            for (std::size_t j = 0; j < n; ++j) {
                if (cells[j].inert) continue;
                cells[j].mass = massBefore[j];
                double sensitivity = 0.0;
                advanceSpecies(cells[j].mass, material.reactions, cells[j].temperature, dt, heat, &sensitivity);
                for (double q : heat) reactionHeat[j] += q;
                reactionSlope[j] = sensitivity;
            }
            // How deep each live cell sits below the receding surface.
            std::vector<double> depth(n, 0.0), absorbed(n, 0.0);
            double x = 0.0;
            for (std::size_t j = first; j < n; ++j) {
                depth[j] = x;
                x += cells[j].thickness();
            }
            const double entering = material.emissivity * flux;
            for (std::size_t j = first; j < n; ++j) {
                if (cells[j].inert) break;
                const double top = std::exp(-material.absorptionPerM * depth[j]);
                const double bottom = std::exp(-material.absorptionPerM * (depth[j] + cells[j].thickness()));
                absorbed[j] = entering * (top - bottom);
            }
            // Tridiagonal system of the implicit step.
            std::fill(a.begin(), a.end(), 0.0);
            std::fill(b.begin(), b.end(), 0.0);
            std::fill(c.begin(), c.end(), 0.0);
            std::fill(d.begin(), d.end(), 0.0);
            auto conductance = [&](std::size_t j) { // between j and j+1
                const double left = cells[j].thickness() / 2.0 / std::max(conductivityOf(cells[j]), 1e-12);
                const double right = cells[j + 1].thickness() / 2.0 / std::max(conductivityOf(cells[j + 1]), 1e-12);
                const double resistance = left + right;
                return resistance > 0.0 ? 1.0 / resistance : 0.0;
            };
            for (std::size_t j = first; j < n; ++j) {
                const double capacity = std::max(cells[j].total(), 1e-12) * specificHeatOf(cells[j]) / dt;
                b[j] = capacity + reactionSlope[j] / dt;
                d[j] = capacity * previous[j] + absorbed[j] + (reactionSlope[j] * cells[j].temperature - reactionHeat[j]) / dt;
                if (j > first) {
                    const double g = conductance(j - 1);
                    a[j] = -g;
                    b[j] += g;
                }
                if (j + 1 < n) {
                    const double g = conductance(j);
                    c[j] = -g;
                    b[j] += g;
                }
            }
            // Surface: re-radiation (linearised at the iterate) and convection.
            {
                const double Ts = cells[first].temperature;
                const double emission = material.emissivity * kStefanBoltzmann;
                const double slope = 4.0 * emission * Ts * Ts * Ts;
                b[first] += slope + problem.convectionWm2K;
                d[first] += slope * Ts - emission * (std::pow(Ts, 4) - std::pow(problem.wallK, 4)) + problem.convectionWm2K * problem.gasK;
            }
            // Thomas algorithm over the live cells.
            for (std::size_t j = first + 1; j < n; ++j) {
                const double factor = a[j] / b[j - 1];
                b[j] -= factor * c[j - 1];
                d[j] -= factor * d[j - 1];
            }
            double change = 0.0, size = 0.0;
            worstCell = first;
            for (std::size_t j = n; j-- > first;) {
                const double value = (d[j] - (j + 1 < n ? c[j] * cells[j + 1].temperature : 0.0)) / b[j];
                if (std::fabs(value - cells[j].temperature) > change) change = std::fabs(value - cells[j].temperature), worstCell = j;
                size = std::max(size, std::fabs(value));
                cells[j].temperature = value;
            }
            worstChange = change;
            for (std::size_t j = 0; j < first; ++j) cells[j].temperature = cells[first].temperature;
            converged = change <= settings.tolerance * size;
        }
        if (!converged) {
            char detail[192];
            std::snprintf(detail, sizeof(detail), "итерации шага не сошлись на t = %.3f с: ячейка %zu, изменение %.3g K, её температура %.1f K", time,
                          worstCell, worstChange, cells[worstCell].temperature);
            return failure(ErrorCode::KernelOperationFailed, detail);
        }
        (void)massBeforeStep;
        if (step % std::max(1, settings.saveEvery) == 0 || step == steps) record(time);
    }
    return Result<PyrolysisSolution>::ok(std::move(solution));
}

} // namespace cadnext::fea
