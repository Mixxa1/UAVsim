#include "cadnext/fea/Modal.hpp"

#include "SystemAssembly.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <sstream>

namespace cadnext::fea {

namespace {

Result<ModalSolution> failure(ErrorCode code, const std::string& message) {
    return Result<ModalSolution>::fail({code, message});
}

// Eigen-decomposition of a dense symmetric n×n matrix (cyclic Jacobi), row-major. Eigenvectors are
// the columns of `vectors`.
void symmetricEigen(int n, std::vector<double> a, std::vector<double>& values, std::vector<double>& vectors) {
    vectors.assign(static_cast<std::size_t>(n) * n, 0.0);
    for (int i = 0; i < n; ++i) vectors[i * n + i] = 1.0;
    auto A = [&](int i, int j) -> double& { return a[static_cast<std::size_t>(i) * n + j]; };
    auto V = [&](int i, int j) -> double& { return vectors[static_cast<std::size_t>(i) * n + j]; };
    double scale = 0.0;
    for (double value : a) scale = std::max(scale, std::fabs(value));
    for (int sweep = 0; sweep < 100; ++sweep) {
        double off = 0.0;
        for (int p = 0; p < n; ++p)
            for (int q = p + 1; q < n; ++q) off += A(p, q) * A(p, q);
        if (off <= 1e-30 * scale * scale) break;
        for (int p = 0; p < n; ++p) {
            for (int q = p + 1; q < n; ++q) {
                if (std::fabs(A(p, q)) <= 1e-300) continue;
                const double theta = (A(q, q) - A(p, p)) / (2.0 * A(p, q));
                const double t = (theta >= 0 ? 1.0 : -1.0) / (std::fabs(theta) + std::sqrt(theta * theta + 1.0));
                const double c = 1.0 / std::sqrt(t * t + 1.0);
                const double s = t * c;
                for (int k = 0; k < n; ++k) {
                    const double akp = A(k, p), akq = A(k, q);
                    A(k, p) = c * akp - s * akq;
                    A(k, q) = s * akp + c * akq;
                }
                for (int k = 0; k < n; ++k) {
                    const double apk = A(p, k), aqk = A(q, k);
                    A(p, k) = c * apk - s * aqk;
                    A(q, k) = s * apk + c * aqk;
                }
                for (int k = 0; k < n; ++k) {
                    const double vkp = V(k, p), vkq = V(k, q);
                    V(k, p) = c * vkp - s * vkq;
                    V(k, q) = s * vkp + c * vkq;
                }
            }
        }
    }
    values.resize(n);
    for (int i = 0; i < n; ++i) values[i] = A(i, i);
}

// Generalised dense problem K q = μ M q (M symmetric positive definite), q M-orthonormal,
// ascending μ. Cholesky M = L Lᵀ, then the standard problem L⁻¹ K L⁻ᵀ.
[[maybe_unused]] bool generalizedEigen(int n, const std::vector<double>& K, const std::vector<double>& M, std::vector<double>& values,
                      std::vector<double>& vectors) {
    std::vector<double> L(static_cast<std::size_t>(n) * n, 0.0);
    for (int j = 0; j < n; ++j) {
        double diagonal = M[j * n + j];
        for (int k = 0; k < j; ++k) diagonal -= L[j * n + k] * L[j * n + k];
        if (!(diagonal > 0.0)) return false;
        L[j * n + j] = std::sqrt(diagonal);
        for (int i = j + 1; i < n; ++i) {
            double sum = M[i * n + j];
            for (int k = 0; k < j; ++k) sum -= L[i * n + k] * L[j * n + k];
            L[i * n + j] = sum / L[j * n + j];
        }
    }
    // C = L⁻¹ K L⁻ᵀ: solve column by column.
    std::vector<double> Y(static_cast<std::size_t>(n) * n); // Y = L⁻¹ K
    for (int column = 0; column < n; ++column) {
        for (int i = 0; i < n; ++i) {
            double sum = K[i * n + column];
            for (int k = 0; k < i; ++k) sum -= L[i * n + k] * Y[k * n + column];
            Y[i * n + column] = sum / L[i * n + i];
        }
    }
    std::vector<double> C(static_cast<std::size_t>(n) * n); // C = Y L⁻ᵀ, i.e. L Cᵀ = Yᵀ row-wise
    for (int row = 0; row < n; ++row) {
        for (int i = 0; i < n; ++i) {
            double sum = Y[row * n + i];
            for (int k = 0; k < i; ++k) sum -= L[i * n + k] * C[row * n + k];
            C[row * n + i] = sum / L[i * n + i];
        }
    }
    for (int i = 0; i < n; ++i)
        for (int j = i + 1; j < n; ++j) C[i * n + j] = C[j * n + i] = 0.5 * (C[i * n + j] + C[j * n + i]);
    std::vector<double> standardValues, standardVectors;
    symmetricEigen(n, C, standardValues, standardVectors);
    std::vector<int> order(n);
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](int a, int b) { return standardValues[a] < standardValues[b]; });
    values.resize(n);
    vectors.assign(static_cast<std::size_t>(n) * n, 0.0);
    for (int out = 0; out < n; ++out) {
        const int source = order[out];
        values[out] = standardValues[source];
        // q = L⁻ᵀ v (back substitution with Lᵀ).
        for (int i = n - 1; i >= 0; --i) {
            double sum = standardVectors[i * n + source];
            for (int k = i + 1; k < n; ++k) sum -= L[k * n + i] * vectors[k * n + out];
            vectors[i * n + out] = sum / L[i * n + i];
        }
    }
    return true;
}

} // namespace

Result<ModalSolution> solveModal(const ModalProblem& problem, const ModalSettings& settings) {
    using namespace detail;
    if (problem.mesh == nullptr || problem.mesh->elements.empty()) return failure(ErrorCode::InvalidArgument, "пустая сетка");
    if (!problem.material.isValid()) return failure(ErrorCode::InvalidArgument, "некорректный материал: " + problem.material.id);
    if (problem.modeCount < 1) return failure(ErrorCode::InvalidArgument, "не задано число мод");
    const TetMesh& mesh = *problem.mesh;
    if (const auto message = checkElementNodes(mesh)) return failure(ErrorCode::InvalidArgument, *message);
    for (const auto& constraint : problem.constraints) {
        for (const auto& value : constraint.value) {
            if (value && *value != 0.0) {
                return failure(ErrorCode::InvalidArgument, "в модальном анализе закрепление — нулевое перемещение, не нагрузка");
            }
        }
    }
    DofMap map;
    if (const auto message = buildDofMap(mesh, problem.constraints, map)) return failure(ErrorCode::InvalidArgument, *message);
    if (const auto invalid = firstInvalidElement(mesh)) {
        std::ostringstream message;
        message << "вырожденный, вывернутый или сложенный элемент " << invalid->first << " (min det J = " << invalid->second << ")";
        return failure(ErrorCode::ShapeInvalid, message.str());
    }
    const int n = map.freeCount;
    if (n == 0) return failure(ErrorCode::InvalidArgument, "все степени свободы закреплены");

    ModalSolution solution;
    solution.totalDofs = 3 * static_cast<int>(mesh.nodes.size());
    solution.freeDofs = n;
    solution.constrained = !freeRigidBodyMotion(mesh, map).has_value();

    SymmetricCsc K = reducedSparsity(mesh, map);
    SymmetricCsc M = K;
    const auto D = isotropicElasticity(problem.material.youngsModulusPa, problem.material.poissonRatio);
    assembleStiffness(mesh, D, map, K, nullptr);
    assembleMass(mesh, problem.material.densityKgPerM3, map, M);
    for (const auto& attached : problem.attachedMasses) {
        if (!(attached.massKg > 0.0)) return failure(ErrorCode::InvalidArgument, "присоединённая масса должна быть положительной");
        std::vector<double> weights(mesh.nodes.size(), 0.0);
        if (!addFaceNodeWeights(mesh, attached.faceGroup, weights)) {
            return failure(ErrorCode::NotFound, "нет группы граней для присоединённой массы: " + attached.faceGroup);
        }
        const double area = std::accumulate(weights.begin(), weights.end(), 0.0);
        if (!(area > 0.0)) return failure(ErrorCode::InvalidArgument, "грань присоединённой массы нулевой площади: " + attached.faceGroup);
        for (std::size_t node = 0; node < weights.size(); ++node) {
            if (weights[node] == 0.0) continue;
            const double nodal = attached.massKg * weights[node] / area;
            for (int c = 0; c < 3; ++c) {
                const int free = map.reduced[3 * node + c];
                if (free >= 0) M.at(free, free) += nodal;
            }
        }
        solution.attachedMassKg += attached.massKg;
    }

    // Total mass from the full (unreduced) mass: Σ over DOFs of (M r_x)_x.
    {
        std::vector<double> local;
        for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
            tetMass(mesh, e, problem.material.densityKgPerM3, local);
            const int size = 3 * mesh.nodesPerElement();
            for (int a = 0; a < size; a += 3)
                for (int b = 0; b < size; b += 3) solution.totalMassKg += local[static_cast<std::size_t>(a) * size + b];
        }
    }

    // A constrained structure factors K itself; a free one needs a shift below zero so that its
    // rigid-body modes (ω = 0) do not make the matrix singular. The shift is tiny against the
    // stiffness scale — far enough from zero to factor, close enough not to slow convergence.
    double shift = 0.0;
    if (!solution.constrained) {
        double ratio = 0.0;
        for (int i = 0; i < n; ++i) ratio += K.at(i, i) / M.at(i, i);
        shift = -1e-8 * ratio / n;
    }
    SymmetricCsc A = K;
    for (std::size_t k = 0; k < A.values.size(); ++k) A.values[k] = K.values[k] - shift * M.values[k];
    SparseCholesky cholesky;
    if (!cholesky.factor(A)) {
        return failure(ErrorCode::KernelOperationFailed, "K − σM не положительно определена: закрепления или материал");
    }

    const int p = std::min(problem.modeCount, n);
    const int q = std::min(std::max(2 * p, p + 8), n);

    // Starting block (Bathe): the mass diagonal, unit vectors at the DOFs with the smallest K/M
    // ratio (where low modes live), and one pseudo-random vector with a fixed seed so a mode
    // orthogonal to all of those cannot be missed and the run stays reproducible.
    std::vector<double> X(static_cast<std::size_t>(n) * q, 0.0);
    std::vector<int> byRatio(n);
    std::iota(byRatio.begin(), byRatio.end(), 0);
    std::sort(byRatio.begin(), byRatio.end(), [&](int a, int b) { return K.at(a, a) / M.at(a, a) < K.at(b, b) / M.at(b, b); });
    for (int i = 0; i < n; ++i) X[i] = M.at(i, i);
    for (int column = 1; column < q - 1; ++column) X[static_cast<std::size_t>(column) * n + byRatio[column - 1]] = 1.0;
    std::uint64_t seed = 0x9E3779B97F4A7C15ull;
    for (int i = 0; i < n && q > 1; ++i) {
        seed = seed * 6364136223846793005ull + 1442695040888963407ull;
        X[static_cast<std::size_t>(q - 1) * n + i] = static_cast<double>(seed >> 11) / static_cast<double>(1ull << 53) - 0.5;
    }

    auto nextRandom = [&seed]() {
        seed = seed * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<double>(seed >> 11) / static_cast<double>(1ull << 53) - 0.5;
    };
    std::vector<double> Y(static_cast<std::size_t>(n) * q), Xbar;
    std::vector<double> U(static_cast<std::size_t>(n) * q), MU(static_cast<std::size_t>(n) * q), AU(static_cast<std::size_t>(n) * q);
    std::vector<double> Kq(static_cast<std::size_t>(q) * q), mu, V, previous, v(n), Mv(n);
    int iteration = 0;
    bool converged = false;
    for (; iteration < settings.maximumIterations && !converged; ++iteration) {
        for (int column = 0; column < q; ++column) M.multiply(&X[static_cast<std::size_t>(column) * n], &Y[static_cast<std::size_t>(column) * n]);
        cholesky.solveColumns(Y, Xbar, q);

        // M-orthonormalise the block (modified Gram–Schmidt, two passes). Projecting a raw block
        // instead builds a Gram matrix whose columns differ in scale by many orders of magnitude,
        // and its Cholesky fails on round-off — the first run of the tests did exactly that.
        for (int j = 0; j < q; ++j) {
            std::copy_n(&Xbar[static_cast<std::size_t>(j) * n], n, v.begin());
            for (int attempt = 0; attempt < 3; ++attempt) {
                M.multiply(v, Mv);
                const double initial = std::sqrt(std::max(std::inner_product(v.begin(), v.end(), Mv.begin(), 0.0), 0.0));
                for (int pass = 0; pass < 2; ++pass) {
                    for (int k = 0; k < j; ++k) {
                        const double* mu_k = &MU[static_cast<std::size_t>(k) * n];
                        const double* u_k = &U[static_cast<std::size_t>(k) * n];
                        double projection = 0.0;
                        for (int r = 0; r < n; ++r) projection += mu_k[r] * v[r];
                        for (int r = 0; r < n; ++r) v[r] -= projection * u_k[r];
                    }
                }
                M.multiply(v, Mv);
                const double norm = std::sqrt(std::max(std::inner_product(v.begin(), v.end(), Mv.begin(), 0.0), 0.0));
                if (norm > 1e-10 * initial && norm > 0.0) {
                    for (int r = 0; r < n; ++r) {
                        U[static_cast<std::size_t>(j) * n + r] = v[r] / norm;
                        MU[static_cast<std::size_t>(j) * n + r] = Mv[r] / norm;
                    }
                    break;
                }
                // Dependent on the earlier vectors: continue with a fresh reproducible direction.
                for (int r = 0; r < n; ++r) v[r] = nextRandom();
                if (attempt == 2) {
                    return failure(ErrorCode::KernelOperationFailed, "не удалось построить независимое подпространство");
                }
            }
        }
        // Rayleigh–Ritz on K − σM in the M-orthonormal basis. (Projecting the inverse operator was
        // tried and measured worse on the lowest modes: residual 1.2e-7 against 2.2e-8.)
        for (int column = 0; column < q; ++column) A.multiply(&U[static_cast<std::size_t>(column) * n], &AU[static_cast<std::size_t>(column) * n]);
        for (int i = 0; i < q; ++i) {
            for (int j = i; j < q; ++j) {
                const double* ui = &U[static_cast<std::size_t>(i) * n];
                const double* auj = &AU[static_cast<std::size_t>(j) * n];
                double k = 0.0;
                for (int r = 0; r < n; ++r) k += ui[r] * auj[r];
                Kq[i * q + j] = k;
                Kq[j * q + i] = k;
            }
        }
        symmetricEigen(q, Kq, mu, V);
        std::vector<int> order(q);
        std::iota(order.begin(), order.end(), 0);
        std::sort(order.begin(), order.end(), [&](int a, int b) { return mu[a] < mu[b]; });
        std::vector<double> sorted(q);
        for (int i = 0; i < q; ++i) sorted[i] = mu[order[i]];
        for (int column = 0; column < q; ++column) {
            double* target = &X[static_cast<std::size_t>(column) * n];
            std::fill(target, target + n, 0.0);
            for (int j = 0; j < q; ++j) {
                const double coefficient = V[j * q + order[column]];
                const double* source = &U[static_cast<std::size_t>(j) * n];
                for (int r = 0; r < n; ++r) target[r] += coefficient * source[r];
            }
        }
        mu = sorted;
        if (!previous.empty()) {
            converged = true;
            // A relative change alone cannot be met below round-off: a dense eigen-solver knows the
            // small eigenvalues of a block only to about ε·λ_max. That floor is added.
            const double floor = 1e3 * std::numeric_limits<double>::epsilon() * std::fabs(mu[q - 1]);
            for (int i = 0; i < p; ++i) {
                if (std::fabs(mu[i] - previous[i]) > settings.tolerance * std::fabs(mu[i]) + floor) {
                    converged = false;
                    break;
                }
            }
            // Eigenvalues converge at the square of the rate of the vectors: stopping on them alone
            // left mode shapes with residuals of 1e-5 (measured). The shapes must have converged too.
            for (int i = 0; converged && i < p; ++i) {
                const double* phi = &X[static_cast<std::size_t>(i) * n];
                A.multiply(phi, v.data());
                M.multiply(phi, Mv.data());
                double residual = 0.0, reference = 0.0;
                for (int r = 0; r < n; ++r) {
                    const double diff = v[r] - mu[i] * Mv[r];
                    residual += diff * diff;
                    reference += (mu[i] * Mv[r]) * (mu[i] * Mv[r]);
                }
                // Attainable accuracy of a backward-stable solve is about ε·κ, κ = λ_max/λ_i of the block.
                const double attainable = 1e3 * std::numeric_limits<double>::epsilon() * std::fabs(mu[q - 1] / mu[i]);
                if (std::sqrt(residual / std::max(reference, 1e-300)) > std::max(settings.residualTolerance, attainable)) {
                    converged = false;
                }
            }
        }
        previous = mu;
    }
    solution.iterations = iteration;
    if (!converged) {
        return failure(ErrorCode::KernelOperationFailed,
                       "собственные значения не сошлись за " + std::to_string(settings.maximumIterations) + " итераций");
    }

    // Unit translations over the free DOFs, and M r for the participations.
    std::array<std::vector<double>, 3> Mr;
    for (int d = 0; d < 3; ++d) {
        std::vector<double> r(n, 0.0);
        for (int g = 0; g < solution.totalDofs; ++g) {
            if (map.reduced[g] >= 0 && g % 3 == d) r[map.reduced[g]] = 1.0;
        }
        M.multiply(r, Mr[d]);
        solution.freeMassKg[d] = std::inner_product(r.begin(), r.end(), Mr[d].begin(), 0.0);
    }

    std::vector<double> phi(n), Kphi(n), Mphi(n);
    for (int i = 0; i < p; ++i) {
        std::copy_n(&X[static_cast<std::size_t>(i) * n], n, phi.begin());
        NaturalMode mode;
        mode.eigenvalue = mu[i] + shift;
        mode.frequencyHz = std::sqrt(std::max(mode.eigenvalue, 0.0)) / (2.0 * M_PI);
        K.multiply(phi, Kphi);
        M.multiply(phi, Mphi);
        double residual = 0.0, reference = 0.0;
        for (int r = 0; r < n; ++r) {
            const double diff = Kphi[r] - mode.eigenvalue * Mphi[r];
            residual += diff * diff;
            reference += (mode.eigenvalue * Mphi[r]) * (mode.eigenvalue * Mphi[r]);
        }
        // Rigid-body modes have λ ≈ 0: measure them against the stiffness scale instead.
        if (reference <= 0.0 || std::fabs(mode.eigenvalue) < std::fabs(shift)) {
            reference = 0.0;
            for (double value : Kphi) reference += value * value;
            double mass = 0.0;
            for (double value : Mphi) mass += value * value;
            reference = std::max(reference, std::fabs(shift) * std::fabs(shift) * mass);
        }
        mode.residual = reference > 0.0 ? std::sqrt(residual / reference) : std::sqrt(residual);
        for (int d = 0; d < 3; ++d) {
            mode.participation[d] = std::inner_product(phi.begin(), phi.end(), Mr[d].begin(), 0.0);
            mode.effectiveMassKg[d] = mode.participation[d] * mode.participation[d];
        }
        mode.shape.assign(mesh.nodes.size(), Vec3{});
        for (int g = 0; g < solution.totalDofs; ++g) {
            if (map.reduced[g] >= 0) mode.shape[g / 3][g % 3] = phi[map.reduced[g]];
        }
        solution.modes.push_back(std::move(mode));
    }
    return Result<ModalSolution>::ok(std::move(solution));
}

} // namespace cadnext::fea
