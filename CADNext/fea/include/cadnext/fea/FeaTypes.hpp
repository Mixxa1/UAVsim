#pragma once

#include <array>
#include <cmath>

// Small value types shared by the structural solver. SI throughout: metres, newtons,
// pascals, kilograms. The CAD model stores metres as well (see Units.hpp); only the UI
// converts to millimetres.

namespace cadnext::fea {

struct Vec3 {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;

    double& operator[](int i) { return i == 0 ? x : (i == 1 ? y : z); }
    double operator[](int i) const { return i == 0 ? x : (i == 1 ? y : z); }
};

inline Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 operator*(Vec3 a, double s) { return {a.x * s, a.y * s, a.z * s}; }
inline Vec3 operator*(double s, Vec3 a) { return a * s; }
inline Vec3& operator+=(Vec3& a, Vec3 b) { a = a + b; return a; }
inline double dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline double length(Vec3 a) { return std::sqrt(dot(a, a)); }

// Voigt order used everywhere: xx, yy, zz, yz, xz, xy. Strains carry engineering shear
// (γ = 2ε); stresses carry the tensor components.
using Voigt = std::array<double, 6>;

inline double vonMises(const Voigt& s) {
    const double dxy = s[0] - s[1];
    const double dyz = s[1] - s[2];
    const double dzx = s[2] - s[0];
    return std::sqrt(0.5 * (dxy * dxy + dyz * dyz + dzx * dzx)
                     + 3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]));
}

} // namespace cadnext::fea
