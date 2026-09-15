#include "cadnext/fea/TetElement.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace cadnext::fea {

namespace {

// Reference gradients of the volume coordinates L0..L3 with respect to (ξ, η, ζ).
constexpr std::array<Vec3, 4> kVolumeCoordinateGradients = {{
    {-1.0, -1.0, -1.0}, {1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0},
}};

struct JacobianResult {
    double determinant = 0.0;
    // Physical gradients of the shape functions.
    std::array<Vec3, 10> gradients{};
};

JacobianResult physicalGradients(const TetMesh& mesh, int element, const Vec3& xi) {
    const int count = mesh.nodesPerElement();
    double values[10];
    Vec3 reference[10];
    tetShapeFunctions(mesh.order, xi, values, reference);

    // J[i][j] = ∂x_j / ∂ξ_i
    double J[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
    const auto& nodes = mesh.elements[element];
    for (int n = 0; n < count; ++n) {
        const Vec3& x = mesh.nodes[nodes[n]];
        for (int i = 0; i < 3; ++i) {
            for (int j = 0; j < 3; ++j) {
                J[i][j] += reference[n][i] * x[j];
            }
        }
    }
    JacobianResult result;
    const double det = J[0][0] * (J[1][1] * J[2][2] - J[1][2] * J[2][1])
                       - J[0][1] * (J[1][0] * J[2][2] - J[1][2] * J[2][0])
                       + J[0][2] * (J[1][0] * J[2][1] - J[1][1] * J[2][0]);
    result.determinant = det;
    if (!(det > 0.0)) {
        return result;
    }
    const double inv[3][3] = {
        {(J[1][1] * J[2][2] - J[1][2] * J[2][1]) / det, (J[0][2] * J[2][1] - J[0][1] * J[2][2]) / det,
         (J[0][1] * J[1][2] - J[0][2] * J[1][1]) / det},
        {(J[1][2] * J[2][0] - J[1][0] * J[2][2]) / det, (J[0][0] * J[2][2] - J[0][2] * J[2][0]) / det,
         (J[0][2] * J[1][0] - J[0][0] * J[1][2]) / det},
        {(J[1][0] * J[2][1] - J[1][1] * J[2][0]) / det, (J[0][1] * J[2][0] - J[0][0] * J[2][1]) / det,
         (J[0][0] * J[1][1] - J[0][1] * J[1][0]) / det},
    };
    // ∂N/∂x_j = Σ_i (J⁻¹)[j][i] ∂N/∂ξ_i
    for (int n = 0; n < count; ++n) {
        for (int j = 0; j < 3; ++j) {
            result.gradients[n][j] = inv[j][0] * reference[n][0] + inv[j][1] * reference[n][1]
                                     + inv[j][2] * reference[n][2];
        }
    }
    return result;
}

// Strain-displacement rows for node gradient g: 6×3 block.
void bBlock(const Vec3& g, double block[6][3]) {
    block[0][0] = g.x; block[0][1] = 0.0; block[0][2] = 0.0;
    block[1][0] = 0.0; block[1][1] = g.y; block[1][2] = 0.0;
    block[2][0] = 0.0; block[2][1] = 0.0; block[2][2] = g.z;
    block[3][0] = 0.0; block[3][1] = g.z; block[3][2] = g.y;
    block[4][0] = g.z; block[4][1] = 0.0; block[4][2] = g.x;
    block[5][0] = g.y; block[5][1] = g.x; block[5][2] = 0.0;
}

} // namespace

const std::vector<QuadraturePoint>& tetQuadratureDegree2() {
    static const std::vector<QuadraturePoint> rule = [] {
        const double a = 0.5854101966249685;
        const double b = 0.1381966011250105;
        const double w = 1.0 / 24.0;
        // Point q has L_q = a: the ordering is what lets stresses be extrapolated to corner q.
        return std::vector<QuadraturePoint>{
            {{b, b, b}, w}, // L0 = a
            {{a, b, b}, w}, // L1 = a
            {{b, a, b}, w}, // L2 = a
            {{b, b, a}, w}, // L3 = a
        };
    }();
    return rule;
}

const std::vector<QuadraturePoint>& tetQuadratureDegree5() {
    static const std::vector<QuadraturePoint> rule = [] {
        std::vector<QuadraturePoint> points;
        auto vertexOrbit = [&](double a, double weight) {
            const double b = 1.0 - 3.0 * a;
            // (L1, L2, L3) with the remaining coordinate L0 implied.
            points.push_back({{a, a, a}, weight});
            points.push_back({{b, a, a}, weight});
            points.push_back({{a, b, a}, weight});
            points.push_back({{a, a, b}, weight});
        };
        vertexOrbit(0.0927352503108912, 0.01224884051939366);
        vertexOrbit(0.3108859192633006, 0.01878132095300264);
        const double p = 0.4544962958743506;
        const double q = 0.5 - p;
        const double w = 0.007091003462846911;
        // (p, p, q, q) over the six ways to choose which two of L0..L3 take p.
        points.push_back({{p, q, q}, w}); // L0 = p, L1 = p
        points.push_back({{q, p, q}, w}); // L0 = p, L2 = p
        points.push_back({{q, q, p}, w}); // L0 = p, L3 = p
        points.push_back({{p, p, q}, w}); // L1, L2
        points.push_back({{p, q, p}, w}); // L1, L3
        points.push_back({{q, p, p}, w}); // L2, L3
        return points;
    }();
    return rule;
}

bool tetIsCurved(const TetMesh& mesh, int element) {
    if (mesh.order != ElementOrder::Quadratic) return false;
    const auto& nodes = mesh.elements[element];
    for (int e = 0; e < 6; ++e) {
        const Vec3 a = mesh.nodes[nodes[kTetEdges[e][0]]];
        const Vec3 b = mesh.nodes[nodes[kTetEdges[e][1]]];
        const Vec3 m = mesh.nodes[nodes[4 + e]];
        if (length(m - (a + b) * 0.5) > 1e-10 * length(b - a)) return true;
    }
    return false;
}

void tetShapeFunctions(ElementOrder order, const Vec3& xi, double* values, Vec3* gradients) {
    const double L[4] = {1.0 - xi.x - xi.y - xi.z, xi.x, xi.y, xi.z};
    if (order == ElementOrder::Linear) {
        for (int n = 0; n < 4; ++n) {
            values[n] = L[n];
            gradients[n] = kVolumeCoordinateGradients[n];
        }
        return;
    }
    for (int n = 0; n < 4; ++n) {
        values[n] = L[n] * (2.0 * L[n] - 1.0);
        gradients[n] = kVolumeCoordinateGradients[n] * (4.0 * L[n] - 1.0);
    }
    for (int e = 0; e < 6; ++e) {
        const int a = kTetEdges[e][0];
        const int b = kTetEdges[e][1];
        values[4 + e] = 4.0 * L[a] * L[b];
        gradients[4 + e] = (kVolumeCoordinateGradients[b] * L[a] + kVolumeCoordinateGradients[a] * L[b]) * 4.0;
    }
}

std::array<std::array<double, 6>, 6> isotropicElasticity(double E, double nu) {
    const double lambda = E * nu / ((1.0 + nu) * (1.0 - 2.0 * nu));
    const double mu = E / (2.0 * (1.0 + nu));
    std::array<std::array<double, 6>, 6> D{};
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            D[i][j] = lambda + (i == j ? 2.0 * mu : 0.0);
        }
        D[3 + i][3 + i] = mu;
    }
    return D;
}

double tetMinimumJacobian(const TetMesh& mesh, int element) {
    static const Vec3 nodal[10] = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {0.5, 0, 0},
                                   {0.5, 0.5, 0}, {0, 0.5, 0}, {0, 0, 0.5}, {0.5, 0, 0.5}, {0, 0.5, 0.5}};
    double minimum = std::numeric_limits<double>::infinity();
    for (int n = 0; n < mesh.nodesPerElement(); ++n) {
        minimum = std::min(minimum, physicalGradients(mesh, element, nodal[n]).determinant);
    }
    for (const auto& point : tetQuadratureDegree5()) {
        minimum = std::min(minimum, physicalGradients(mesh, element, point.xi).determinant);
    }
    return minimum;
}

double tetVolume(const TetMesh& mesh, int element) {
    double volume = 0.0;
    for (const auto& point : tetQuadratureDegree5()) {
        volume += physicalGradients(mesh, element, point.xi).determinant * point.weight;
    }
    return volume;
}

ElementGeometryError tetStiffness(const TetMesh& mesh, int element,
                                  const std::array<std::array<double, 6>, 6>& D,
                                  std::vector<double>& K) {
    const int count = mesh.nodesPerElement();
    const int size = 3 * count;
    K.assign(static_cast<std::size_t>(size) * size, 0.0);
    ElementGeometryError status;
    status.minimumJacobian = std::numeric_limits<double>::infinity();

    const auto& rule = tetIsCurved(mesh, element) ? tetQuadratureDegree5() : tetQuadratureDegree2();
    for (const auto& point : rule) {
        const auto jacobian = physicalGradients(mesh, element, point.xi);
        status.minimumJacobian = std::min(status.minimumJacobian, jacobian.determinant);
        if (!(jacobian.determinant > 0.0)) {
            status.invalid = true;
            return status;
        }
        const double scale = jacobian.determinant * point.weight;
        // DB for every node, then accumulate Bᵀ(DB) block by block.
        double DB[10][6][3];
        for (int n = 0; n < count; ++n) {
            double B[6][3];
            bBlock(jacobian.gradients[n], B);
            for (int r = 0; r < 6; ++r) {
                for (int c = 0; c < 3; ++c) {
                    double sum = 0.0;
                    for (int k = 0; k < 6; ++k) {
                        sum += D[r][k] * B[k][c];
                    }
                    DB[n][r][c] = sum;
                }
            }
        }
        for (int m = 0; m < count; ++m) {
            double Bm[6][3];
            bBlock(jacobian.gradients[m], Bm);
            for (int n = 0; n < count; ++n) {
                for (int a = 0; a < 3; ++a) {
                    for (int b = 0; b < 3; ++b) {
                        double sum = 0.0;
                        for (int r = 0; r < 6; ++r) {
                            sum += Bm[r][a] * DB[n][r][b];
                        }
                        K[static_cast<std::size_t>(3 * m + a) * size + (3 * n + b)] += sum * scale;
                    }
                }
            }
        }
    }
    return status;
}

void tetMass(const TetMesh& mesh, int element, double density, std::vector<double>& mass) {
    const int count = mesh.nodesPerElement();
    const int size = 3 * count;
    mass.assign(static_cast<std::size_t>(size) * size, 0.0);
    for (const auto& point : tetQuadratureDegree5()) {
        const auto jacobian = physicalGradients(mesh, element, point.xi);
        double values[10];
        Vec3 unused[10];
        tetShapeFunctions(mesh.order, point.xi, values, unused);
        const double scale = density * jacobian.determinant * point.weight;
        for (int m = 0; m < count; ++m) {
            for (int n = 0; n < count; ++n) {
                const double term = values[m] * values[n] * scale;
                for (int c = 0; c < 3; ++c) {
                    mass[static_cast<std::size_t>(3 * m + c) * size + (3 * n + c)] += term;
                }
            }
        }
    }
}

void tetBodyForce(const TetMesh& mesh, int element, const Vec3& f, std::vector<double>& nodal) {
    const int count = mesh.nodesPerElement();
    nodal.assign(static_cast<std::size_t>(3 * count), 0.0);
    const auto& rule = tetIsCurved(mesh, element) ? tetQuadratureDegree5() : tetQuadratureDegree2();
    for (const auto& point : rule) {
        const auto jacobian = physicalGradients(mesh, element, point.xi);
        double values[10];
        Vec3 unused[10];
        tetShapeFunctions(mesh.order, point.xi, values, unused);
        const double scale = jacobian.determinant * point.weight;
        for (int n = 0; n < count; ++n) {
            nodal[3 * n] += values[n] * f.x * scale;
            nodal[3 * n + 1] += values[n] * f.y * scale;
            nodal[3 * n + 2] += values[n] * f.z * scale;
        }
    }
}

std::vector<Voigt> tetQuadratureStress(const TetMesh& mesh, int element,
                                       const std::array<std::array<double, 6>, 6>& D,
                                       const std::vector<Vec3>& u) {
    const int count = mesh.nodesPerElement();
    std::vector<Voigt> stresses;
    stresses.reserve(4);
    for (const auto& point : tetQuadratureDegree2()) {
        const auto jacobian = physicalGradients(mesh, element, point.xi);
        Voigt strain{};
        for (int n = 0; n < count; ++n) {
            const Vec3& g = jacobian.gradients[n];
            const Vec3& d = u[mesh.elements[element][n]];
            strain[0] += g.x * d.x;
            strain[1] += g.y * d.y;
            strain[2] += g.z * d.z;
            strain[3] += g.z * d.y + g.y * d.z;
            strain[4] += g.z * d.x + g.x * d.z;
            strain[5] += g.y * d.x + g.x * d.y;
        }
        Voigt stress{};
        for (int r = 0; r < 6; ++r) {
            for (int k = 0; k < 6; ++k) {
                stress[r] += D[r][k] * strain[k];
            }
        }
        stresses.push_back(stress);
    }
    return stresses;
}

const std::vector<TriangleQuadraturePoint>& triangleQuadratureDegree4() {
    static const std::vector<TriangleQuadraturePoint> rule = [] {
        const double a1 = 0.445948490915965, b1 = 0.108103018168070, w1 = 0.223381589678011 * 0.5;
        const double a2 = 0.091576213509771, b2 = 0.816847572980459, w2 = 0.109951743655322 * 0.5;
        return std::vector<TriangleQuadraturePoint>{
            {a1, a1, w1}, {b1, a1, w1}, {a1, b1, w1},
            {a2, a2, w2}, {b2, a2, w2}, {a2, b2, w2},
        };
    }();
    return rule;
}

void triangleShapeFunctions(ElementOrder order, double s, double t, double* N, double* dS, double* dT) {
    const double l0 = 1.0 - s - t;
    if (order == ElementOrder::Linear) {
        N[0] = l0; N[1] = s; N[2] = t;
        dS[0] = -1.0; dS[1] = 1.0; dS[2] = 0.0;
        dT[0] = -1.0; dT[1] = 0.0; dT[2] = 1.0;
        return;
    }
    N[0] = l0 * (2.0 * l0 - 1.0);
    N[1] = s * (2.0 * s - 1.0);
    N[2] = t * (2.0 * t - 1.0);
    N[3] = 4.0 * l0 * s;
    N[4] = 4.0 * s * t;
    N[5] = 4.0 * t * l0;
    dS[0] = -(4.0 * l0 - 1.0); dT[0] = -(4.0 * l0 - 1.0);
    dS[1] = 4.0 * s - 1.0;     dT[1] = 0.0;
    dS[2] = 0.0;               dT[2] = 4.0 * t - 1.0;
    dS[3] = 4.0 * (l0 - s);    dT[3] = -4.0 * s;
    dS[4] = 4.0 * t;           dT[4] = 4.0 * s;
    dS[5] = -4.0 * t;          dT[5] = 4.0 * (l0 - t);
}

} // namespace cadnext::fea
