#include "cadnext/fea/Aeroelasticity.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

namespace {

using Complex = std::complex<double>;

struct Matrix2 {
    Complex a11, a12, a21, a22;
    Complex trace() const { return a11 + a22; }
    Complex determinant() const { return a11 * a22 - a12 * a21; }
};

// Both roots of λ² − (trace)λ + determinant = 0.
void eigenvalues(const Matrix2& m, Complex& first, Complex& second) {
    const Complex trace = m.trace(), determinant = m.determinant();
    const Complex root = std::sqrt(trace * trace - 4.0 * determinant);
    first = 0.5 * (trace + root);
    second = 0.5 * (trace - root);
}

// The aerodynamic forces on the section for harmonic motion of reduced frequency k at speed U, as
// the matrix that takes {h, α} to {L, M} (Theodorsen 1935; the forms of Fung §6.2 and Hodges &
// Pierce §5.4, with h positive down, α nose up, lift up and moment nose up).
Matrix2 aerodynamicForces(const TypicalSection& section, double reducedFrequency, double speedMps) {
    const double b = section.semichordM, a = section.elasticAxis, rho = section.airDensityKgM3;
    const double omega = reducedFrequency * speedMps / b;
    const Complex i(0.0, 1.0);
    const Complex C = theodorsen(reducedFrequency);
    Matrix2 forces;
    forces.a11 = -M_PI * rho * b * b * omega * omega + 2.0 * M_PI * rho * speedMps * b * C * i * omega;
    forces.a12 = M_PI * rho * b * b * (i * omega * speedMps + a * b * omega * omega)
                 + 2.0 * M_PI * rho * speedMps * b * C * (speedMps + i * omega * b * (0.5 - a));
    forces.a21 = -M_PI * rho * b * b * b * a * omega * omega + 2.0 * M_PI * rho * speedMps * b * b * (a + 0.5) * C * i * omega;
    forces.a22 = M_PI * rho * b * b * (-speedMps * b * (0.5 - a) * i * omega + b * b * (0.125 + a * a) * omega * omega)
                 + 2.0 * M_PI * rho * speedMps * b * b * (a + 0.5) * C * (speedMps + i * omega * b * (0.5 - a));
    return forces;
}

// The same, divided by ω²: for harmonic motion it depends on the reduced frequency alone, which is
// what the k-method needs.
Matrix2 aerodynamicShape(const TypicalSection& section, double reducedFrequency) {
    const double b = section.semichordM, a = section.elasticAxis, rho = section.airDensityKgM3;
    const double k = reducedFrequency;
    const Complex i(0.0, 1.0);
    const Complex C = theodorsen(k);
    Matrix2 shape;
    shape.a11 = M_PI * rho * b * b * (-1.0 + 2.0 * C * i / k);
    shape.a12 = M_PI * rho * b * b * b * (i / k + a) + 2.0 * M_PI * rho * b * b * b * C * (1.0 / k) * (1.0 / k + i * (0.5 - a));
    shape.a21 = -M_PI * rho * b * b * b * a + 2.0 * M_PI * rho * b * b * b * (a + 0.5) * C * i / k;
    shape.a22 = M_PI * rho * b * b * b * b * (-i * (0.5 - a) / k + (0.125 + a * a))
                + 2.0 * M_PI * rho * b * b * b * b * (a + 0.5) * C * (1.0 / k) * (1.0 / k + i * (0.5 - a));
    return shape;
}

bool validSection(const TypicalSection& section, std::string& why) {
    if (!(section.semichordM > 0.0)) return why = "не задана полухорда сечения", false;
    if (!(section.massKgPerM > 0.0)) return why = "не задана погонная масса", false;
    if (!(section.inertiaKgM > 0.0)) return why = "не задан погонный момент инерции", false;
    if (!(section.plungeStiffnessNPerM2 > 0.0) || !(section.pitchStiffnessNmPerRad > 0.0)) return why = "не заданы жёсткости", false;
    if (section.massKgPerM * section.inertiaKgM <= section.staticUnbalanceKgM * section.staticUnbalanceKgM) {
        return why = "матрица масс не положительно определена: статический дисбаланс слишком велик", false;
    }
    if (!(section.airDensityKgM3 > 0.0)) return why = "не задана плотность воздуха", false;
    return true;
}

} // namespace

std::complex<double> theodorsen(double reducedFrequency) {
    // At rest the wake is not shed and the aerofoil gets all of its quasi-steady lift.
    if (!(reducedFrequency > 1e-8)) return {1.0, 0.0};
    // The POSIX Bessel functions: Apple's standard library does not carry the C++17 ones.
    const double j0k = j0(reducedFrequency), j1k = j1(reducedFrequency);
    const double y0k = y0(reducedFrequency), y1k = y1(reducedFrequency);
    const std::complex<double> h0(j0k, -y0k), h1(j1k, -y1k);
    const std::complex<double> i(0.0, 1.0);
    return h1 / (h1 + i * h0);
}

double divergenceSpeedMps(const TypicalSection& section) {
    const double b = section.semichordM, a = section.elasticAxis, rho = section.airDensityKgM3;
    const double arm = a + 0.5; // the elastic axis aft of the quarter chord, in semichords
    if (!(arm > 0.0) || !(b > 0.0) || !(rho > 0.0)) return 0.0; // ahead of the aerodynamic centre: it cannot diverge
    return std::sqrt(section.pitchStiffnessNmPerRad / (2.0 * M_PI * rho * b * b * arm));
}

namespace {

// The sweep itself: two branches followed from speed to speed, each iterating its own reduced
// frequency until the aerodynamics and the eigenvalue agree, plus the static determinant alongside
// for divergence. `stiffness(k, U, matrix)` fills K + Q, `mass` is the (real, symmetric) mass matrix.
FlutterSolution sweepBranches(double massA, double massB, double massCross, double firstFrequency, double secondFrequency, double referenceSemichord,
                              const std::function<void(double, double, Complex*)>& stiffness, const std::function<void(double, Complex*)>& steady,
                              const FlutterSweep& sweep) {
    FlutterSolution solution;
    const double massDeterminant = massA * massB - massCross * massCross;
    const double b = referenceSemichord;
    double previousK[2] = {0.0, 0.0};
    double previousStatic = 0.0;
    bool hadStatic = false;
    bool crossed[2] = {false, false};
    double lastDamping[2] = {0.0, 0.0}, lastSpeed[2] = {0.0, 0.0}, lastFrequency[2] = {0.0, 0.0};
    for (int step = 0; step < sweep.speeds; ++step) {
        const double speed = sweep.lowSpeedMps + (sweep.highSpeedMps - sweep.lowSpeedMps) * step / (sweep.speeds - 1);
        if (steady) {
            Complex matrix[4];
            steady(speed, matrix);
            const double determinant = (matrix[0] * matrix[3] - matrix[1] * matrix[2]).real();
            if (hadStatic && previousStatic > 0.0 && determinant <= 0.0) {
                const double weight = previousStatic / (previousStatic - determinant);
                const double previousSpeed = sweep.lowSpeedMps + (sweep.highSpeedMps - sweep.lowSpeedMps) * (step - 1) / (sweep.speeds - 1);
                solution.divergenceFoundMps = previousSpeed + weight * (speed - previousSpeed);
            }
            previousStatic = determinant;
            hadStatic = true;
        }
        for (int branch = 0; branch < 2; ++branch) {
            const double start = branch == 0 ? std::min(firstFrequency, secondFrequency) : std::max(firstFrequency, secondFrequency);
            double k = previousK[branch] > 1e-6 ? previousK[branch] : std::max(start * b / speed, 1e-4);
            Complex p(0.0, 0.0);
            for (int iteration = 0; iteration < sweep.iterations; ++iteration) {
                Complex total[4];
                stiffness(k, speed, total);
                Matrix2 g;
                g.a11 = -(massB * total[0] - massCross * total[2]) / massDeterminant;
                g.a12 = -(massB * total[1] - massCross * total[3]) / massDeterminant;
                g.a21 = -(-massCross * total[0] + massA * total[2]) / massDeterminant;
                g.a22 = -(-massCross * total[1] + massA * total[3]) / massDeterminant;
                Complex first, second;
                eigenvalues(g, first, second);
                Complex chosen = first;
                const double firstMagnitude = std::sqrt(std::abs(first)), secondMagnitude = std::sqrt(std::abs(second));
                if ((branch == 0) == (secondMagnitude < firstMagnitude)) chosen = second;
                p = std::sqrt(chosen);
                if (p.imag() < 0.0) p = -p;
                const double updated = std::max(p.imag() * b / speed, 1e-6);
                const double change = std::fabs(updated - k);
                k = 0.5 * (k + updated);
                if (change < 1e-12 * std::max(k, 1e-6)) break;
            }
            previousK[branch] = k;
            FlutterPoint point;
            point.speedMps = speed;
            point.frequencyHz = p.imag() / (2.0 * M_PI);
            point.dampingRatio = std::abs(p) > 0.0 ? p.real() / std::abs(p) : 0.0;
            point.reducedFrequency = k;
            point.branch = branch;
            solution.branches.push_back(point);
            if (step > 0 && lastDamping[branch] < 0.0 && point.dampingRatio >= 0.0 && !crossed[branch]) {
                const double weight = -lastDamping[branch] / (point.dampingRatio - lastDamping[branch]);
                const double speedAtCrossing = lastSpeed[branch] + weight * (speed - lastSpeed[branch]);
                const double frequencyAtCrossing = lastFrequency[branch] + weight * (point.frequencyHz - lastFrequency[branch]);
                crossed[branch] = true;
                if (!solution.flutterFound || speedAtCrossing < solution.flutterSpeedMps) {
                    solution.flutterFound = true;
                    solution.flutterSpeedMps = speedAtCrossing;
                    solution.flutterFrequencyHz = frequencyAtCrossing;
                }
            }
            lastDamping[branch] = point.dampingRatio;
            lastSpeed[branch] = speed;
            lastFrequency[branch] = point.frequencyHz;
        }
    }
    if (!solution.flutterFound) {
        solution.warnings.push_back("в заданном диапазоне скоростей ни одна ветвь не пересекла ноль: флаттера здесь нет");
    }
    if (solution.divergenceFoundMps > 0.0 && solution.flutterFound && solution.divergenceFoundMps < solution.flutterSpeedMps) {
        solution.warnings.push_back("дивергенция наступает раньше флаттера: критичен статический случай");
    }
    return solution;
}

} // namespace

Result<FlutterSolution> solveFlutterGeneralized(const GeneralizedFlutterSystem& system, const FlutterSweep& sweep) {
    using R = Result<FlutterSolution>;
    if (!system.aerodynamics) return R::fail({ErrorCode::InvalidArgument, "не задана обобщённая аэродинамика"});
    if (!(system.frequencyRadS[0] > 0.0) || !(system.frequencyRadS[1] > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не заданы частоты мод"});
    if (!(system.referenceSemichordM > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не задана опорная полухорда"});
    if (!(sweep.highSpeedMps > sweep.lowSpeedMps) || sweep.speeds < 4) return R::fail({ErrorCode::InvalidArgument, "развёртка по скорости не задана"});
    const double damping = system.structuralDamping;
    auto stiffness = [&](double k, double speed, Complex* matrix) {
        system.aerodynamics(k, speed, matrix);
        matrix[0] += system.frequencyRadS[0] * system.frequencyRadS[0] * (1.0 + Complex(0.0, damping));
        matrix[3] += system.frequencyRadS[1] * system.frequencyRadS[1] * (1.0 + Complex(0.0, damping));
    };
    std::function<void(double, Complex*)> steady;
    if (system.steadyAerodynamics) {
        steady = [&](double speed, Complex* matrix) {
            system.steadyAerodynamics(speed, matrix);
            matrix[0] += system.frequencyRadS[0] * system.frequencyRadS[0];
            matrix[3] += system.frequencyRadS[1] * system.frequencyRadS[1];
        };
    }
    return R::ok(sweepBranches(1.0, 1.0, 0.0, system.frequencyRadS[0], system.frequencyRadS[1], system.referenceSemichordM, stiffness, steady, sweep));
}

Result<FlutterSolution> solveFlutter(const TypicalSection& section, const FlutterSweep& sweep) {
    using R = Result<FlutterSolution>;
    std::string why;
    if (!validSection(section, why)) return R::fail({ErrorCode::InvalidArgument, why});
    if (!(sweep.highSpeedMps > sweep.lowSpeedMps) || sweep.speeds < 4) return R::fail({ErrorCode::InvalidArgument, "развёртка по скорости не задана"});

    const double b = section.semichordM;
    const double m = section.massKgPerM, s = section.staticUnbalanceKgM, inertia = section.inertiaKgM;
    const double plungeFrequency = std::sqrt(section.plungeStiffnessNPerM2 / m);
    const double pitchFrequency = std::sqrt(section.pitchStiffnessNmPerRad / inertia);
    auto stiffness = [&](double k, double speed, Complex* matrix) {
        const Matrix2 forces = aerodynamicForces(section, k, speed);
        matrix[0] = section.plungeStiffnessNPerM2 * (1.0 + Complex(0.0, section.structuralDamping)) + forces.a11;
        matrix[1] = forces.a12;
        matrix[2] = -forces.a21;
        matrix[3] = section.pitchStiffnessNmPerRad * (1.0 + Complex(0.0, section.structuralDamping)) - forces.a22;
    };
    auto steady = [&](double speed, Complex* matrix) {
        const Matrix2 forces = aerodynamicForces(section, 1e-9, speed);
        matrix[0] = section.plungeStiffnessNPerM2 + forces.a11;
        matrix[1] = forces.a12;
        matrix[2] = -forces.a21;
        matrix[3] = section.pitchStiffnessNmPerRad - forces.a22;
    };
    FlutterSolution solution = sweepBranches(m, inertia, s, plungeFrequency, pitchFrequency, b, stiffness, steady, sweep);
    solution.divergenceSpeedMps = divergenceSpeedMps(section);
    return R::ok(std::move(solution));
}

Result<FlutterSolution> solveFlutterVG(const TypicalSection& section, const FlutterSweep& sweep) {
    using R = Result<FlutterSolution>;
    std::string why;
    if (!validSection(section, why)) return R::fail({ErrorCode::InvalidArgument, why});

    FlutterSolution solution;
    solution.divergenceSpeedMps = divergenceSpeedMps(section);
    const double b = section.semichordM;
    const double m = section.massKgPerM, s = section.staticUnbalanceKgM, inertia = section.inertiaKgM;

    // The classical sweep runs over the reduced frequency, not the speed: each k gives a speed.
    struct Sample {
        double speed = 0.0, damping = 0.0, frequency = 0.0;
    };
    std::vector<Sample> samples[2];
    const int steps = std::max(sweep.speeds, 40);
    for (int step = 0; step < steps; ++step) {
        // From a fast flutter (large k) down to the static limit.
        const double k = 2.0 * std::pow(1e-3 / 2.0, static_cast<double>(step) / (steps - 1));
        const Matrix2 shape = aerodynamicShape(section, k);
        // From (−ω²M + (1+ig)K + ω²B̂)q = 0, with B̂ the force matrix of the equations of motion:
        // (M − B̂) q = Z K q, Z = (1 + i g)/ω².
        Matrix2 left;
        left.a11 = m - shape.a11;
        left.a12 = s - shape.a12;
        left.a21 = s + shape.a21;
        left.a22 = inertia + shape.a22;
        // K is diagonal, so K⁻¹(M + Â) is formed directly.
        Matrix2 g;
        g.a11 = left.a11 / section.plungeStiffnessNPerM2;
        g.a12 = left.a12 / section.plungeStiffnessNPerM2;
        g.a21 = left.a21 / section.pitchStiffnessNmPerRad;
        g.a22 = left.a22 / section.pitchStiffnessNmPerRad;
        Complex first, second;
        eigenvalues(g, first, second);
        const Complex roots[2] = {first, second};
        for (int branch = 0; branch < 2; ++branch) {
            const Complex z = roots[branch];
            if (!(z.real() > 0.0)) continue;
            Sample sample;
            const double omega = 1.0 / std::sqrt(z.real());
            sample.frequency = omega / (2.0 * M_PI);
            sample.speed = omega * b / k;
            sample.damping = z.imag() / z.real() - section.structuralDamping;
            samples[branch].push_back(sample);
        }
    }
    for (int branch = 0; branch < 2; ++branch) {
        std::sort(samples[branch].begin(), samples[branch].end(), [](const Sample& a, const Sample& c) { return a.speed < c.speed; });
        for (std::size_t i = 0; i < samples[branch].size(); ++i) {
            FlutterPoint point;
            point.speedMps = samples[branch][i].speed;
            point.frequencyHz = samples[branch][i].frequency;
            point.dampingRatio = samples[branch][i].damping;
            point.branch = branch;
            solution.branches.push_back(point);
            if (i > 0 && samples[branch][i - 1].damping < 0.0 && samples[branch][i].damping >= 0.0) {
                const double weight = -samples[branch][i - 1].damping / (samples[branch][i].damping - samples[branch][i - 1].damping);
                const double speed = samples[branch][i - 1].speed + weight * (samples[branch][i].speed - samples[branch][i - 1].speed);
                const double frequency = samples[branch][i - 1].frequency + weight * (samples[branch][i].frequency - samples[branch][i - 1].frequency);
                if (!solution.flutterFound || speed < solution.flutterSpeedMps) {
                    solution.flutterFound = true;
                    solution.flutterSpeedMps = speed;
                    solution.flutterFrequencyHz = frequency;
                }
            }
        }
    }
    if (!solution.flutterFound) solution.warnings.push_back("ни одна ветвь не пересекла ноль: в этой развёртке флаттера нет");
    return R::ok(std::move(solution));
}

} // namespace cadnext::fea
