#include "cadnext/fea/PanelFlow.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

namespace {

using R = Result<PanelFlowSolution>;

R fail(ErrorCode code, const std::string& message) {
    return R::fail({code, message});
}

// The velocity a panel of unit source strength induces at a point, in the panel's own frame: ξ along
// the panel from its start, η to the left of it. r1 and r2 are the distances to the panel's ends.
void sourceInfluence(double xi, double eta, double length, double& u, double& v) {
    const double r1Squared = xi * xi + eta * eta;
    const double r2Squared = (xi - length) * (xi - length) + eta * eta;
    const double theta1 = std::atan2(eta, xi);
    const double theta2 = std::atan2(eta, xi - length);
    u = std::log(r1Squared / r2Squared) / (4.0 * M_PI);
    v = (theta2 - theta1) / (2.0 * M_PI);
}

// Solves a dense system by Gaussian elimination with partial pivoting. The matrix is (n × n) row
// major and is destroyed.
bool solveDense(std::vector<double>& a, std::vector<double>& b, int n) {
    for (int column = 0; column < n; ++column) {
        int pivot = column;
        for (int row = column + 1; row < n; ++row)
            if (std::fabs(a[row * n + column]) > std::fabs(a[pivot * n + column])) pivot = row;
        if (std::fabs(a[pivot * n + column]) < 1e-14) return false;
        if (pivot != column) {
            for (int k = 0; k < n; ++k) std::swap(a[column * n + k], a[pivot * n + k]);
            std::swap(b[column], b[pivot]);
        }
        const double diagonal = a[column * n + column];
        for (int row = column + 1; row < n; ++row) {
            const double factor = a[row * n + column] / diagonal;
            if (factor == 0.0) continue;
            for (int k = column; k < n; ++k) a[row * n + k] -= factor * a[column * n + k];
            b[row] -= factor * b[column];
        }
    }
    for (int row = n - 1; row >= 0; --row) {
        double sum = b[row];
        for (int k = row + 1; k < n; ++k) sum -= a[row * n + k] * b[k];
        b[row] = sum / a[row * n + row];
    }
    return true;
}

} // namespace

double SectionGeometry::signedArea() const {
    double twice = 0.0;
    for (std::size_t i = 0; i < x.size(); ++i) {
        const std::size_t j = (i + 1) % x.size();
        twice += x[i] * y[j] - x[j] * y[i];
    }
    return 0.5 * twice;
}

void SectionGeometry::makeClockwise() {
    if (signedArea() > 0.0) {
        std::reverse(x.begin(), x.end());
        std::reverse(y.begin(), y.end());
    }
}

SectionGeometry circleSection(double radius, int count) {
    SectionGeometry section;
    for (int i = 0; i < count; ++i) {
        const double angle = 2.0 * M_PI * i / count;
        section.x.push_back(radius * std::cos(angle));
        section.y.push_back(radius * std::sin(angle));
    }
    return section;
}

void PanelFlowSolution::velocityAt(double x, double y, double& u, double& v) const {
    u = freeStreamMps * std::cos(angleOfAttackRad);
    v = freeStreamMps * std::sin(angleOfAttackRad);
    for (std::size_t j = 0; j < sourceStrength.size(); ++j) {
        const double tx = tangentX[j], ty = tangentY[j];
        const double dx = x - section.x[j], dy = y - section.y[j];
        const double xi = dx * tx + dy * ty;
        const double eta = -dx * ty + dy * tx;
        double localU = 0.0, localV = 0.0;
        sourceInfluence(xi, eta, length[j], localU, localV);
        // The source's own strength, and the vortex, which is that same field turned a quarter turn.
        const double totalU = sourceStrength[j] * localU + vortexStrength * (-localV);
        const double totalV = sourceStrength[j] * localV + vortexStrength * localU;
        u += totalU * tx - totalV * ty;
        v += totalU * ty + totalV * tx;
    }
}

Result<PanelFlowSolution> solvePanelFlow(const SectionGeometry& section, double freeStreamMps, double angleOfAttackRad, bool kutta) {
    if (!section.closed()) return fail(ErrorCode::InvalidArgument, "сечение: нужен замкнутый контур хотя бы из трёх точек");
    if (!(freeStreamMps > 0.0)) return fail(ErrorCode::InvalidArgument, "скорость набегающего потока должна быть положительной");

    PanelFlowSolution solution;
    solution.section = section;
    // Counter-clockwise, so that the outward normal of a panel is its tangent turned a quarter turn
    // clockwise; a section handed over the other way round is simply reversed.
    if (solution.section.signedArea() < 0.0) {
        std::reverse(solution.section.x.begin(), solution.section.x.end());
        std::reverse(solution.section.y.begin(), solution.section.y.end());
    }
    solution.freeStreamMps = freeStreamMps;
    solution.angleOfAttackRad = angleOfAttackRad;

    const int n = static_cast<int>(solution.section.size());
    for (int i = 0; i < n; ++i) {
        const int next = (i + 1) % n;
        const double dx = solution.section.x[next] - solution.section.x[i];
        const double dy = solution.section.y[next] - solution.section.y[i];
        const double l = std::hypot(dx, dy);
        if (!(l > 0.0)) return fail(ErrorCode::InvalidArgument, "сечение: две точки контура совпали");
        solution.length.push_back(l);
        solution.tangentX.push_back(dx / l);
        solution.tangentY.push_back(dy / l);
        solution.normalX.push_back(dy / l);
        solution.normalY.push_back(-dx / l);
        solution.controlX.push_back(0.5 * (solution.section.x[i] + solution.section.x[next]));
        solution.controlY.push_back(0.5 * (solution.section.y[i] + solution.section.y[next]));
    }

    const double streamU = freeStreamMps * std::cos(angleOfAttackRad);
    const double streamV = freeStreamMps * std::sin(angleOfAttackRad);
    const int unknowns = kutta ? n + 1 : n;
    std::vector<double> matrix(static_cast<std::size_t>(unknowns) * unknowns, 0.0), rhs(unknowns, 0.0);

    // Influence of every panel at every control point, once, in both roles.
    std::vector<double> sourceNormal(static_cast<std::size_t>(n) * n, 0.0), sourceTangent(static_cast<std::size_t>(n) * n, 0.0);
    std::vector<double> vortexNormal(static_cast<std::size_t>(n) * n, 0.0), vortexTangent(static_cast<std::size_t>(n) * n, 0.0);
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            double localU = 0.0, localV = 0.0;
            if (i == j) {
                // On its own panel, approached from outside: the source pushes half its strength out
                // and induces nothing along itself; the vortex does the opposite.
                localU = 0.0, localV = -0.5;
            } else {
                const double dx = solution.controlX[i] - solution.section.x[j];
                const double dy = solution.controlY[i] - solution.section.y[j];
                const double xi = dx * solution.tangentX[j] + dy * solution.tangentY[j];
                const double eta = -dx * solution.tangentY[j] + dy * solution.tangentX[j];
                sourceInfluence(xi, eta, solution.length[j], localU, localV);
            }
            // Back to the global frame, for the source and for the vortex (the same field turned).
            const double su = localU * solution.tangentX[j] - localV * solution.tangentY[j];
            const double sv = localU * solution.tangentY[j] + localV * solution.tangentX[j];
            const double vu = -localV * solution.tangentX[j] - localU * solution.tangentY[j];
            const double vv = -localV * solution.tangentY[j] + localU * solution.tangentX[j];
            sourceNormal[i * n + j] = su * solution.normalX[i] + sv * solution.normalY[i];
            sourceTangent[i * n + j] = su * solution.tangentX[i] + sv * solution.tangentY[i];
            vortexNormal[i * n + j] = vu * solution.normalX[i] + vv * solution.normalY[i];
            vortexTangent[i * n + j] = vu * solution.tangentX[i] + vv * solution.tangentY[i];
        }
    }

    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) matrix[static_cast<std::size_t>(i) * unknowns + j] = sourceNormal[i * n + j];
        if (kutta) {
            double sum = 0.0;
            for (int j = 0; j < n; ++j) sum += vortexNormal[i * n + j];
            matrix[static_cast<std::size_t>(i) * unknowns + n] = sum;
        }
        rhs[i] = -(streamU * solution.normalX[i] + streamV * solution.normalY[i]);
    }
    if (kutta) {
        // The flow leaves the trailing edge smoothly: the speed along the first and the last panel is
        // the same, and they point in opposite directions along the surface.
        const int first = 0, last = n - 1;
        for (int j = 0; j < n; ++j) {
            matrix[static_cast<std::size_t>(n) * unknowns + j] = sourceTangent[first * n + j] + sourceTangent[last * n + j];
        }
        double sum = 0.0;
        for (int j = 0; j < n; ++j) sum += vortexTangent[first * n + j] + vortexTangent[last * n + j];
        matrix[static_cast<std::size_t>(n) * unknowns + n] = sum;
        rhs[n] = -((streamU * solution.tangentX[first] + streamV * solution.tangentY[first])
                   + (streamU * solution.tangentX[last] + streamV * solution.tangentY[last]));
    }

    if (!solveDense(matrix, rhs, unknowns)) return fail(ErrorCode::InvalidArgument, "система панелей вырождена: проверьте контур");
    solution.sourceStrength.assign(rhs.begin(), rhs.begin() + n);
    solution.vortexStrength = kutta ? rhs[n] : 0.0;

    double perimeter = 0.0;
    for (int i = 0; i < n; ++i) {
        double speed = streamU * solution.tangentX[i] + streamV * solution.tangentY[i];
        for (int j = 0; j < n; ++j) speed += solution.sourceStrength[j] * sourceTangent[i * n + j] + solution.vortexStrength * vortexTangent[i * n + j];
        solution.surfaceSpeedMps.push_back(speed);
        solution.pressureCoefficient.push_back(1.0 - speed * speed / (freeStreamMps * freeStreamMps));
        perimeter += solution.length[i];
    }
    // Γ = ∮ V·dl, which for this discretisation is the vortex strength over the whole perimeter. The
    // sign follows the order of the points: counter-clockwise here, so a positive Γ turns that way
    // and lifts the section downwards — hence the minus in the lift below.
    solution.circulation = solution.vortexStrength * perimeter;
    const auto [minimumX, maximumX] = std::minmax_element(solution.section.x.begin(), solution.section.x.end());
    const double chord = *maximumX - *minimumX;
    solution.liftCoefficient = chord > 0.0 ? -2.0 * solution.circulation / (freeStreamMps * chord) : 0.0;
    return R::ok(std::move(solution));
}

} // namespace cadnext::fea
