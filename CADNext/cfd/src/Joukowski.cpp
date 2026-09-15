#include "cadnext/cfd/Joukowski.hpp"

#include <cmath>
#include <complex>

namespace cadnext::cfd {

namespace {

using Complex = std::complex<double>;

Complex center(const JoukowskiAirfoil& airfoil) {
    return {-airfoil.thicknessParameter, airfoil.camberParameter};
}

Complex map(Complex zeta) {
    return zeta + 1.0 / zeta;
}

} // namespace

double JoukowskiAirfoil::radius() const {
    return std::abs(Complex(1.0, 0.0) - center(*this));
}

double JoukowskiAirfoil::beta() const {
    return std::atan2(camberParameter, 1.0 + thicknessParameter);
}

double JoukowskiAirfoil::unscaledLeadingEdge() const {
    // The leading edge is the leftmost point of the image of the circle; found by sampling densely and
    // refining around the minimum (it is not at a fixed angle once the airfoil is cambered).
    const Complex c0 = center(*this);
    const double R = radius();
    double bestTheta = M_PI;
    double best = map(c0 + R * std::polar(1.0, bestTheta)).real();
    for (int i = 0; i < 20000; ++i) {
        const double theta = 2.0 * M_PI * i / 20000.0;
        const double x = map(c0 + R * std::polar(1.0, theta)).real();
        if (x < best) {
            best = x;
            bestTheta = theta;
        }
    }
    double step = 2.0 * M_PI / 20000.0;
    for (int i = 0; i < 60; ++i) {
        for (double candidate : {bestTheta - step, bestTheta + step}) {
            const double x = map(c0 + R * std::polar(1.0, candidate)).real();
            if (x < best) {
                best = x;
                bestTheta = candidate;
            }
        }
        step *= 0.5;
    }
    return best;
}

double JoukowskiAirfoil::unscaledChord() const {
    return 2.0 - unscaledLeadingEdge(); // trailing edge at z = 2 (ζ = 1)
}

double JoukowskiAirfoil::exactLiftCoefficient(double alpha) const {
    return 8.0 * M_PI * radius() * std::sin(alpha + beta()) / unscaledChord();
}

Su2Mesh JoukowskiAirfoil::oMesh(int circumferential, int radial, double farfieldChords) const {
    const Complex c0 = center(*this);
    const double R = radius();
    const double chord = unscaledChord();
    const double leadingEdge = unscaledLeadingEdge();
    const double thetaTrailingEdge = std::arg(Complex(1.0, 0.0) - c0);
    const double outer = farfieldChords * chord;

    Su2Mesh mesh;
    mesh.dimension = 2;
    auto index = [&](int j, int k) { return (k * circumferential) + (j % circumferential); };
    for (int k = 0; k <= radial; ++k) {
        const double rho = R * std::pow(outer / R, static_cast<double>(k) / radial);
        for (int j = 0; j < circumferential; ++j) {
            const double theta = thetaTrailingEdge + 2.0 * M_PI * j / circumferential;
            const Complex z = map(c0 + rho * std::polar(1.0, theta));
            mesh.points.push_back({(z.real() - leadingEdge) / chord, z.imag() / chord, 0.0});
        }
    }
    // Counter-clockwise quads: increasing θ runs counter-clockwise along the wall, increasing ρ outward.
    for (int k = 0; k < radial; ++k) {
        for (int j = 0; j < circumferential; ++j) {
            mesh.elements.push_back({Su2ElementType::Quadrilateral, {index(j, k), index(j, k + 1), index(j + 1, k + 1), index(j + 1, k)}});
        }
    }
    std::vector<Su2Element> wall, farfield;
    for (int j = 0; j < circumferential; ++j) {
        wall.push_back({Su2ElementType::Line, {index(j, 0), index(j + 1, 0)}});
        farfield.push_back({Su2ElementType::Line, {index(j, radial), index(j + 1, radial)}});
    }
    mesh.markers = {{"airfoil", std::move(wall)}, {"farfield", std::move(farfield)}};
    return mesh;
}

} // namespace cadnext::cfd
