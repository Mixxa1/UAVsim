#include "cadnext/em/Fdtd.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <thread>

namespace cadnext::em {

namespace {

using R = Result<FdtdResult>;

R fail(ErrorCode code, const std::string& message) {
    return R::fail({code, message});
}

// Runs `body(from, to)` over [0, count) on as many threads as the machine has, one contiguous
// block each. FDTD updates read neighbours of the previous half-step only, so blocks are
// independent; below the threshold the threads cost more than they save.
void parallelFor(int count, const std::function<void(int, int)>& body) {
    const int workers = count < 24 ? 1 : static_cast<int>(std::min<unsigned>(std::max(1u, std::thread::hardware_concurrency()), 8u));
    if (workers <= 1) {
        body(0, count);
        return;
    }
    std::vector<std::thread> pool;
    pool.reserve(static_cast<std::size_t>(workers));
    const int block = (count + workers - 1) / workers;
    for (int w = 0; w < workers; ++w) {
        const int from = w * block, to = std::min(count, from + block);
        if (from >= to) break;
        pool.emplace_back([&body, from, to]() { body(from, to); });
    }
    for (auto& thread : pool) thread.join();
}

// One axis of the convolutional PML (Roden & Gedney 2000; the grading and the α term follow
// Taflove & Hagness 3rd ed., §7.9). The coefficients live on the integer lattice (used when a
// derivative lands on an electric-field node) and on the half lattice (magnetic nodes).
struct PmlAxis {
    int n = 0, cells = 0;
    std::vector<double> bE, cE, invKappaE, bH, cH, invKappaH;

    // Compressed index into the two PML slabs, −1 in the interior.
    int slab(int i) const {
        if (cells <= 0) return -1;
        if (i <= cells) return i;
        if (i >= n - cells) return cells + 1 + (i - (n - cells));
        return -1;
    }
    int slabSize() const { return cells <= 0 ? 0 : 2 * (cells + 1); }
};

PmlAxis makePmlAxis(int n, int cells, double cellM, double stepS, double order, double kappaMax, double alphaMax, double reflection) {
    PmlAxis axis;
    axis.n = n;
    axis.cells = cells;
    const int size = n + 1;
    axis.bE.assign(size, 1.0);
    axis.cE.assign(size, 0.0);
    axis.invKappaE.assign(size, 1.0);
    axis.bH.assign(size, 1.0);
    axis.cH.assign(size, 0.0);
    axis.invKappaH.assign(size, 1.0);
    if (cells <= 0) return axis;

    const double sigmaMax = -(order + 1.0) * std::log(reflection) / (2.0 * kFreeSpaceImpedance * cellM * cells);
    auto coefficients = [&](double depth, double& b, double& c, double& invKappa) {
        if (depth <= 0.0) {
            b = 1.0, c = 0.0, invKappa = 1.0;
            return;
        }
        const double graded = std::pow(depth, order);
        const double sigma = sigmaMax * graded;
        const double kappa = 1.0 + (kappaMax - 1.0) * graded;
        const double alpha = alphaMax * (1.0 - depth);
        b = std::exp(-(sigma / kappa + alpha) * stepS / kVacuumPermittivity);
        c = sigma / (kappa * (sigma + kappa * alpha)) * (b - 1.0);
        invKappa = 1.0 / kappa;
    };
    auto depthOf = [&](double position) {
        if (position <= cells) return (cells - position) / cells;
        if (position >= n - cells) return (position - (n - cells)) / cells;
        return 0.0;
    };
    for (int i = 0; i < size; ++i) {
        coefficients(depthOf(i), axis.bE[i], axis.cE[i], axis.invKappaE[i]);
        coefficients(depthOf(i + 0.5), axis.bH[i], axis.cH[i], axis.invKappaH[i]);
    }
    return axis;
}

// A memory term of the PML: full size along the two axes it does not grade, two slabs along the
// third. Laid out so the innermost index is the slab, as the update loops walk it last.
struct PsiField {
    int a = 0, b = 0, slabs = 0; // the two full axes and the slab count
    std::vector<double> value;

    void resize(int fullA, int fullB, int slabSize) {
        a = fullA, b = fullB, slabs = slabSize;
        value.assign(static_cast<std::size_t>(fullA) * fullB * std::max(slabSize, 0), 0.0);
    }
    double& at(int p, int q, int s) {
        return value[(static_cast<std::size_t>(p) * b + static_cast<std::size_t>(q)) * slabs + static_cast<std::size_t>(s)];
    }
};

} // namespace

void YeeGrid::nearestNode(double x, double y, double z, int& i, int& j, int& k) const {
    auto clampTo = [](double value, int high) { return std::max(0, std::min(high, static_cast<int>(std::lround(value)))); };
    i = clampTo((x - originX) / cellM, nx);
    j = clampTo((y - originY) / cellM, ny);
    k = clampTo((z - originZ) / cellM, nz);
}

void PecEdges::clear(const YeeGrid& grid) {
    x.assign(grid.nodes(), 0);
    y.assign(grid.nodes(), 0);
    z.assign(grid.nodes(), 0);
}

double GaussianDerivative::operator()(double t) const {
    if (!(tauS > 0.0)) return 0.0;
    const double u = (t - delayS) / tauS;
    // Peak amplitude 1: d/dt exp(−u²) normalised by its own extremum at u = ±1/√2.
    return -u * std::exp(0.5 - u * u) * std::sqrt(2.0);
}

GaussianDerivative ricker(double lowHz, double highHz) {
    GaussianDerivative pulse;
    // The differentiated Gaussian's spectrum peaks at f = 1/(2π τ) and is within 3 dB of its peak
    // from about 0.4 f to 2 f; τ is chosen so the band of interest sits inside that.
    const double centre = std::sqrt(std::max(lowHz, 1.0) * std::max(highHz, 1.0));
    pulse.tauS = 1.0 / (2.0 * M_PI * centre);
    pulse.delayS = 5.0 * pulse.tauS;
    return pulse;
}

double numericalWavenumber(double frequencyHz, double cellM, double stepS) {
    const double argument = (cellM / (kSpeedOfLightMps * stepS)) * std::sin(M_PI * frequencyHz * stepS);
    if (argument >= 1.0) return std::numeric_limits<double>::quiet_NaN(); // beyond the grid's cutoff
    return 2.0 / cellM * std::asin(argument);
}

Result<FdtdResult> solveFdtd(const FdtdProblem& problem, const std::function<bool(int)>& progress) {
    const YeeGrid& grid = problem.grid;
    if (!(grid.cellM > 0.0) || grid.nx < 4 || grid.ny < 4 || grid.nz < 4) return fail(ErrorCode::InvalidArgument, "сетка FDTD не задана");
    if (problem.steps <= 0) return fail(ErrorCode::InvalidArgument, "не задано число шагов по времени");
    if (!(problem.courantFactor > 0.0 && problem.courantFactor <= 1.0)) return fail(ErrorCode::InvalidArgument, "число Куранта вне (0, 1]");
    if (problem.pmlCells < 0 || 2 * problem.pmlCells + 2 >= std::min({grid.nx, grid.ny, grid.nz})) {
        return fail(ErrorCode::InvalidArgument, "слой CPML не помещается в сетку");
    }
    if (problem.plane && problem.plane->propagation == problem.plane->polarization) {
        return fail(ErrorCode::InvalidArgument, "плоская волна: поляризация должна быть поперечной");
    }
    if (problem.plane && !problem.plane->waveform) return fail(ErrorCode::InvalidArgument, "плоская волна без формы сигнала");
    if (problem.point && !problem.point->waveform) return fail(ErrorCode::InvalidArgument, "источник без формы сигнала");

    const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
    const std::size_t count = grid.nodes();
    const double step = grid.courantStepS(problem.courantFactor);
    const double ce = step / (kVacuumPermittivity * grid.cellM);
    const double ch = step / (kVacuumPermeability * grid.cellM);

    std::vector<double> ex(count, 0.0), ey(count, 0.0), ez(count, 0.0);
    std::vector<double> hx(count, 0.0), hy(count, 0.0), hz(count, 0.0);
    PecEdges pec = problem.pec;
    if (pec.x.size() != count) pec.x.assign(count, 0);
    if (pec.y.size() != count) pec.y.assign(count, 0);
    if (pec.z.size() != count) pec.z.assign(count, 0);

    auto axisOf = [&](int n) {
        return makePmlAxis(n, problem.pmlCells, grid.cellM, step, problem.pmlOrder, problem.pmlKappaMax, problem.pmlAlphaMax, problem.pmlReflection);
    };
    const PmlAxis px = axisOf(nx), py = axisOf(ny), pz = axisOf(nz);

    // Twelve memory terms: each field component is corrected along the two axes it curls about.
    PsiField exy, exz, eyz, eyx, ezx, ezy, hxy, hxz, hyz, hyx, hzx, hzy;
    exy.resize(nx + 1, nz + 1, py.slabSize());
    exz.resize(nx + 1, ny + 1, pz.slabSize());
    eyz.resize(nx + 1, ny + 1, pz.slabSize());
    eyx.resize(ny + 1, nz + 1, px.slabSize());
    ezx.resize(ny + 1, nz + 1, px.slabSize());
    ezy.resize(nx + 1, nz + 1, py.slabSize());
    hxy.resize(nx + 1, nz + 1, py.slabSize());
    hxz.resize(nx + 1, ny + 1, pz.slabSize());
    hyz.resize(nx + 1, ny + 1, pz.slabSize());
    hyx.resize(ny + 1, nz + 1, px.slabSize());
    hzx.resize(ny + 1, nz + 1, px.slabSize());
    hzy.resize(nx + 1, nz + 1, py.slabSize());

    // The incident wave lives on its own one-dimensional grid with the same cell and step, so it
    // travels with the grid's numerical velocity, not the textbook one. It is long enough that its
    // far end never answers within the run.
    const Axis propagation = problem.plane ? problem.plane->propagation : Axis::X;
    const int along = propagation == Axis::X ? nx : propagation == Axis::Y ? ny : nz;
    const int lineLength = problem.plane ? along + problem.steps + 8 : 0;
    std::vector<double> lineE(static_cast<std::size_t>(std::max(lineLength, 0)) + 1, 0.0);
    std::vector<double> lineH(static_cast<std::size_t>(std::max(lineLength, 0)) + 1, 0.0);
    const bool forward = problem.plane ? problem.plane->forward : true;
    const Axis polarization = problem.plane ? problem.plane->polarization : Axis::Z;
    // ĥ = û × ê: the magnetic direction of a wave going along û with its electric field along ê.
    auto crossAxis = [](Axis u, Axis e) {
        const int a = static_cast<int>(u), b = static_cast<int>(e);
        return static_cast<Axis>(3 - a - b);
    };
    const Axis magnetic = problem.plane ? crossAxis(propagation, polarization) : Axis::Y;
    // The sign this pair of components carries in the curl: with (c, a, b) cyclic, the electric
    // component c is driven by +∂H_b/∂a and by −∂H_a/∂b, and its partner obeys the same sign. The
    // one-dimensional line is given that sign too, so it is the same scheme as the grid it feeds —
    // give the two updates opposite signs and the pair stops being a wave equation and grows
    // without bound, which is what the first run of this file did.
    const int cyclic = problem.plane ? ((static_cast<int>(polarization) - static_cast<int>(propagation) + 3) % 3 == 1 ? 1 : -1) : 1;
    const double pairSign = -cyclic;

    FdtdResult result;
    result.stepS = step;
    result.steps = problem.steps;
    result.pmlReflectionR0 = problem.pmlReflection;
    result.probes.resize(problem.probes.size());
    const std::size_t frequencies = problem.frequenciesHz.size();
    for (auto& probe : result.probes) probe.spectrum.assign(frequencies, {});
    if (problem.plane) result.incidentSpectrum.assign(frequencies, {});

    std::vector<std::array<int, 3>> probeNodes(problem.probes.size());
    for (std::size_t p = 0; p < problem.probes.size(); ++p) {
        int i = 0, j = 0, k = 0;
        grid.nearestNode(problem.probes[p][0], problem.probes[p][1], problem.probes[p][2], i, j, k);
        probeNodes[p] = {std::min(i, nx - 1), std::min(j, ny - 1), std::min(k, nz - 1)};
    }
    int pointI = 0, pointJ = 0, pointK = 0;
    if (problem.point) grid.nearestNode(problem.point->x, problem.point->y, problem.point->z, pointI, pointJ, pointK);


    auto idx = [&](int i, int j, int k) { return grid.index(i, j, k); };

    // The line runs in its own direction of travel: for a wave going backwards through the grid the
    // plane indices are mirrored, so that the line's forward end is the grid's far side.
    auto lineOfPlane = [&](int plane) { return forward ? plane : along - plane; };

    // The incident wave lives inside a box (the total-field / scattered-field surface of Umashankar
    // and Taflove): every update that reaches across the surface has the incident part of its
    // neighbour put in or taken out, so inside the box the field is total and outside it is purely
    // scattered — the absorbing layer never sees the incident wave at all. With a wave at normal
    // incidence only four kinds of correction exist: the pair that carries the wave (E_c and H_m) on
    // the two faces the wave crosses, and the two components along the direction of travel on the
    // four faces it grazes.
    const int extent[3] = {nx, ny, nz};
    const int axisP = static_cast<int>(propagation), axisC = static_cast<int>(polarization), axisM = static_cast<int>(magnetic);
    int lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    {
        const int margin = std::max(problem.plane ? problem.plane->marginCells : 0, 2);
        for (int a = 0; a < 3; ++a) {
            lo[a] = problem.pmlCells + margin;
            hi[a] = extent[a] - problem.pmlCells - margin;
        }
    }
    if (problem.plane && (hi[0] - lo[0] < 2 || hi[1] - lo[1] < 2 || hi[2] - lo[2] < 2)) {
        return fail(ErrorCode::InvalidArgument, "поверхность полного поля не помещается между слоями CPML");
    }
    auto component = [&](int axis, bool electric) -> std::vector<double>& {
        if (electric) return axis == 0 ? ex : axis == 1 ? ey : ez;
        return axis == 0 ? hx : axis == 1 ? hy : hz;
    };
    auto blockedOf = [&](int axis) -> const std::vector<std::uint8_t>& { return axis == 0 ? pec.x : axis == 1 ? pec.y : pec.z; };
    // Adds `value(indexAlongP)` to one component over one face of the box. `fixedAxis` is the axis
    // the face cuts, `fixedIndex` the node index on it; the other two run over the box.
    auto correctFace = [&](int componentAxis, bool electric, int fixedAxis, int fixedIndex, const std::function<double(int)>& value) {
        if (fixedIndex < 0 || fixedIndex > extent[fixedAxis]) return;
        auto& field = component(componentAxis, electric);
        const auto& blocked = blockedOf(componentAxis);
        // A component is at half positions along its own axis when electric, along the other two when
        // magnetic; a half position spans [lo, hi) of the box, an integer one [lo, hi].
        auto range = [&](int axis, int& from, int& to) {
            const bool half = electric ? axis == componentAxis : axis != componentAxis;
            from = lo[axis];
            to = half ? hi[axis] - 1 : hi[axis];
        };
        int first = 0, second = 0, firstTo = 0, secondTo = 0;
        const int a = fixedAxis == 0 ? 1 : 0, b = fixedAxis == 2 ? 1 : 2;
        range(a, first, firstTo);
        range(b, second, secondTo);
        int index[3] = {0, 0, 0};
        index[fixedAxis] = fixedIndex;
        for (int u = first; u <= firstTo; ++u) {
            index[a] = u;
            for (int v = second; v <= secondTo; ++v) {
                index[b] = v;
                const std::size_t node = idx(index[0], index[1], index[2]);
                if (blocked[node]) continue;
                field[node] += value(index[axisP]);
            }
        }
    };
    for (int n = 0; n < problem.steps; ++n) {
        // --- magnetic field
        parallelFor(nx + 1, [&](int from, int to) {
            for (int i = from; i < to; ++i) {
                for (int j = 0; j < ny; ++j) {
                    for (int k = 0; k < nz; ++k) {
                        const std::size_t c = idx(i, j, k);
                        const double dEzdy = (ez[idx(i, j + 1, k)] - ez[c]) / grid.cellM;
                        const double dEydz = (ey[idx(i, j, k + 1)] - ey[c]) / grid.cellM;
                        hx[c] -= ch * grid.cellM * (py.invKappaH[j] * dEzdy - pz.invKappaH[k] * dEydz);
                    }
                }
                if (i < nx) {
                    for (int j = 0; j <= ny; ++j) {
                        for (int k = 0; k < nz; ++k) {
                            const std::size_t c = idx(i, j, k);
                            const double dExdz = (ex[idx(i, j, k + 1)] - ex[c]) / grid.cellM;
                            const double dEzdx = (ez[idx(i + 1, j, k)] - ez[c]) / grid.cellM;
                            hy[c] -= ch * grid.cellM * (pz.invKappaH[k] * dExdz - px.invKappaH[i] * dEzdx);
                        }
                    }
                    for (int j = 0; j < ny; ++j) {
                        for (int k = 0; k <= nz; ++k) {
                            const std::size_t c = idx(i, j, k);
                            const double dEydx = (ey[idx(i + 1, j, k)] - ey[c]) / grid.cellM;
                            const double dExdy = (ex[idx(i, j + 1, k)] - ex[c]) / grid.cellM;
                            hz[c] -= ch * grid.cellM * (px.invKappaH[i] * dEydx - py.invKappaH[j] * dExdy);
                        }
                    }
                }
            }
        });
        // --- the memory terms of the magnetic field, inside the layers only
        if (problem.pmlCells > 0) {
            for (int i = 0; i <= nx; ++i)
                for (int j = 0; j < ny; ++j) {
                    const int sy = py.slab(j);
                    for (int k = 0; k < nz; ++k) {
                        const std::size_t c = idx(i, j, k);
                        if (sy >= 0) {
                            double& psi = hxy.at(i, k, sy);
                            psi = py.bH[j] * psi + py.cH[j] * (ez[idx(i, j + 1, k)] - ez[c]) / grid.cellM;
                            hx[c] -= ch * grid.cellM * psi;
                        }
                        const int sz = pz.slab(k);
                        if (sz >= 0) {
                            double& psi = hxz.at(i, j, sz);
                            psi = pz.bH[k] * psi + pz.cH[k] * (ey[idx(i, j, k + 1)] - ey[c]) / grid.cellM;
                            hx[c] += ch * grid.cellM * psi;
                        }
                    }
                }
            for (int i = 0; i < nx; ++i) {
                const int sx = px.slab(i);
                for (int j = 0; j <= ny; ++j)
                    for (int k = 0; k < nz; ++k) {
                        const std::size_t c = idx(i, j, k);
                        const int sz = pz.slab(k);
                        if (sz >= 0) {
                            double& psi = hyz.at(i, j, sz);
                            psi = pz.bH[k] * psi + pz.cH[k] * (ex[idx(i, j, k + 1)] - ex[c]) / grid.cellM;
                            hy[c] -= ch * grid.cellM * psi;
                        }
                        if (sx >= 0) {
                            double& psi = hyx.at(j, k, sx);
                            psi = px.bH[i] * psi + px.cH[i] * (ez[idx(i + 1, j, k)] - ez[c]) / grid.cellM;
                            hy[c] += ch * grid.cellM * psi;
                        }
                    }
                for (int j = 0; j < ny; ++j) {
                    const int sy = py.slab(j);
                    for (int k = 0; k <= nz; ++k) {
                        const std::size_t c = idx(i, j, k);
                        if (sx >= 0) {
                            double& psi = hzx.at(j, k, sx);
                            psi = px.bH[i] * psi + px.cH[i] * (ey[idx(i + 1, j, k)] - ey[c]) / grid.cellM;
                            hz[c] -= ch * grid.cellM * psi;
                        }
                        if (sy >= 0) {
                            double& psi = hzy.at(i, k, sy);
                            psi = py.bH[j] * psi + py.cH[j] * (ex[idx(i, j + 1, k)] - ex[c]) / grid.cellM;
                            hz[c] += ch * grid.cellM * psi;
                        }
                    }
                }
            }
        }
        // --- the incident line, and the magnetic nodes that straddle the surface
        if (problem.plane) {
            for (int p = 0; p < lineLength; ++p) lineH[p] += pairSign * ch * (lineE[p + 1] - lineE[p]);
            auto incidentE = [&](int planeAlongP) { return lineE[lineOfPlane(planeAlongP)]; };
            // The magnetic partner just outside the faces the wave crosses.
            correctFace(axisM, false, axisP, lo[axisP] - 1, [&](int) { return -ch * pairSign * incidentE(lo[axisP]); });
            correctFace(axisM, false, axisP, hi[axisP], [&](int) { return ch * pairSign * incidentE(hi[axisP]); });
            // The magnetic component along the direction of travel, on the faces the wave grazes.
            correctFace(axisP, false, axisM, lo[axisM] - 1, [&](int along) { return ch * pairSign * incidentE(along); });
            correctFace(axisP, false, axisM, hi[axisM], [&](int along) { return -ch * pairSign * incidentE(along); });
        }

        // --- electric field
        const double timeE = (n + 1.0) * step;
        parallelFor(nx + 1, [&](int from, int to) {
            for (int i = from; i < to; ++i) {
                if (i < nx) {
                    for (int j = 1; j < ny; ++j)
                        for (int k = 1; k < nz; ++k) {
                            const std::size_t c = idx(i, j, k);
                            if (pec.x[c]) {
                                ex[c] = 0.0;
                                continue;
                            }
                            const double dHzdy = (hz[c] - hz[idx(i, j - 1, k)]) / grid.cellM;
                            const double dHydz = (hy[c] - hy[idx(i, j, k - 1)]) / grid.cellM;
                            ex[c] += ce * grid.cellM * (py.invKappaE[j] * dHzdy - pz.invKappaE[k] * dHydz);
                        }
                }
                if (i >= 1 && i < nx) {
                    for (int j = 0; j < ny; ++j)
                        for (int k = 1; k < nz; ++k) {
                            const std::size_t c = idx(i, j, k);
                            if (pec.y[c]) {
                                ey[c] = 0.0;
                                continue;
                            }
                            const double dHxdz = (hx[c] - hx[idx(i, j, k - 1)]) / grid.cellM;
                            const double dHzdx = (hz[c] - hz[idx(i - 1, j, k)]) / grid.cellM;
                            ey[c] += ce * grid.cellM * (pz.invKappaE[k] * dHxdz - px.invKappaE[i] * dHzdx);
                        }
                    for (int j = 1; j < ny; ++j)
                        for (int k = 0; k < nz; ++k) {
                            const std::size_t c = idx(i, j, k);
                            if (pec.z[c]) {
                                ez[c] = 0.0;
                                continue;
                            }
                            const double dHydx = (hy[c] - hy[idx(i - 1, j, k)]) / grid.cellM;
                            const double dHxdy = (hx[c] - hx[idx(i, j - 1, k)]) / grid.cellM;
                            ez[c] += ce * grid.cellM * (px.invKappaE[i] * dHydx - py.invKappaE[j] * dHxdy);
                        }
                }
            }
        });
        // --- the memory terms of the electric field
        if (problem.pmlCells > 0) {
            for (int i = 0; i < nx; ++i)
                for (int j = 1; j < ny; ++j) {
                    const int sy = py.slab(j);
                    for (int k = 1; k < nz; ++k) {
                        const std::size_t c = idx(i, j, k);
                        if (sy >= 0) {
                            double& psi = exy.at(i, k, sy);
                            psi = py.bE[j] * psi + py.cE[j] * (hz[c] - hz[idx(i, j - 1, k)]) / grid.cellM;
                            if (!pec.x[c]) ex[c] += ce * grid.cellM * psi;
                        }
                        const int sz = pz.slab(k);
                        if (sz >= 0) {
                            double& psi = exz.at(i, j, sz);
                            psi = pz.bE[k] * psi + pz.cE[k] * (hy[c] - hy[idx(i, j, k - 1)]) / grid.cellM;
                            if (!pec.x[c]) ex[c] -= ce * grid.cellM * psi;
                        }
                    }
                }
            for (int i = 1; i < nx; ++i) {
                const int sx = px.slab(i);
                for (int j = 0; j < ny; ++j)
                    for (int k = 1; k < nz; ++k) {
                        const std::size_t c = idx(i, j, k);
                        const int sz = pz.slab(k);
                        if (sz >= 0) {
                            double& psi = eyz.at(i, j, sz);
                            psi = pz.bE[k] * psi + pz.cE[k] * (hx[c] - hx[idx(i, j, k - 1)]) / grid.cellM;
                            if (!pec.y[c]) ey[c] += ce * grid.cellM * psi;
                        }
                        if (sx >= 0) {
                            double& psi = eyx.at(j, k, sx);
                            psi = px.bE[i] * psi + px.cE[i] * (hz[c] - hz[idx(i - 1, j, k)]) / grid.cellM;
                            if (!pec.y[c]) ey[c] -= ce * grid.cellM * psi;
                        }
                    }
                for (int j = 1; j < ny; ++j) {
                    const int sy = py.slab(j);
                    for (int k = 0; k < nz; ++k) {
                        const std::size_t c = idx(i, j, k);
                        if (sx >= 0) {
                            double& psi = ezx.at(j, k, sx);
                            psi = px.bE[i] * psi + px.cE[i] * (hy[c] - hy[idx(i - 1, j, k)]) / grid.cellM;
                            if (!pec.z[c]) ez[c] += ce * grid.cellM * psi;
                        }
                        if (sy >= 0) {
                            double& psi = ezy.at(i, k, sy);
                            psi = py.bE[j] * psi + py.cE[j] * (hx[c] - hx[idx(i, j - 1, k)]) / grid.cellM;
                            if (!pec.z[c]) ez[c] -= ce * grid.cellM * psi;
                        }
                    }
                }
            }
        }
        // --- the electric nodes that straddle the surface, then the line's own step
        if (problem.plane) {
            // The line's magnetic field is the incident component itself when the wave travels along
            // the axis; mirrored for a wave that travels backwards, its sign flips with it.
            const double lineHSign = forward ? 1.0 : -1.0;
            auto incidentH = [&](int halfAlongP) { return lineHSign * lineH[forward ? halfAlongP : along - halfAlongP - 1]; };
            correctFace(axisC, true, axisP, lo[axisP], [&](int) { return -ce * pairSign * incidentH(lo[axisP] - 1); });
            correctFace(axisC, true, axisP, hi[axisP], [&](int) { return ce * pairSign * incidentH(hi[axisP]); });
            correctFace(axisP, true, axisC, lo[axisC], [&](int along) { return ce * pairSign * incidentH(along); });
            correctFace(axisP, true, axisC, hi[axisC], [&](int along) { return -ce * pairSign * incidentH(along); });
            for (int p = 1; p <= lineLength; ++p) lineE[p] += pairSign * ce * (lineH[p] - lineH[p - 1]);
            lineE[0] = problem.plane->waveform(timeE); // the injector: the line only ever runs forward
        }
        if (problem.point) {
            const std::size_t c = idx(pointI, pointJ, pointK);
            const double value = problem.point->waveform(timeE);
            if (problem.point->polarization == Axis::X && !pec.x[c]) ex[c] += value;
            if (problem.point->polarization == Axis::Y && !pec.y[c]) ey[c] += value;
            if (problem.point->polarization == Axis::Z && !pec.z[c]) ez[c] += value;
        }

        // --- what is watched
        const double incidentAtSource = problem.plane ? lineE[lineOfPlane(lo[axisP])] : 0.0;
        if (problem.plane) {
            result.incidentVm.push_back(incidentAtSource);
            for (std::size_t f = 0; f < frequencies; ++f) {
                const double phase = -2.0 * M_PI * problem.frequenciesHz[f] * timeE;
                result.incidentSpectrum[f] += incidentAtSource * std::complex<double>(std::cos(phase), std::sin(phase)) * step;
            }
        }
        for (std::size_t p = 0; p < probeNodes.size(); ++p) {
            const auto& node = probeNodes[p];
            const std::size_t c = idx(node[0], node[1], node[2]);
            const std::array<double, 3> value{ex[c], ey[c], ez[c]};
            if (problem.recordHistory) {
                result.probes[p].exVm.push_back(value[0]);
                result.probes[p].eyVm.push_back(value[1]);
                result.probes[p].ezVm.push_back(value[2]);
            }
            for (std::size_t f = 0; f < frequencies; ++f) {
                const double phase = -2.0 * M_PI * problem.frequenciesHz[f] * timeE;
                const std::complex<double> kernel(std::cos(phase), std::sin(phase));
                for (int axis = 0; axis < 3; ++axis) result.probes[p].spectrum[f][axis] += value[axis] * kernel * step;
            }
        }
        if (progress && !progress(n)) break;
    }
    return R::ok(std::move(result));
}

} // namespace cadnext::em
