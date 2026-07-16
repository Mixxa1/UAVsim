#pragma once

#include "cadnext/Vector3.hpp"

namespace cadnext::assembly {

// Vector helpers shared by the assembly solvers. Core Vector3 is a bare
// data struct; all math stays here so the core model keeps no behavior.
Vector3 add(const Vector3& a, const Vector3& b);
Vector3 subtract(const Vector3& a, const Vector3& b);
Vector3 scale(const Vector3& v, double factor);
double dot(const Vector3& a, const Vector3& b);
Vector3 cross(const Vector3& a, const Vector3& b);
double length(const Vector3& v);
// Zero-length input returns the fallback unchanged.
Vector3 normalizedOr(const Vector3& v, const Vector3& fallback);
// Deterministic unit vector perpendicular to `axis` (stable X for circle
// and cylinder frames: project the world axis least aligned with `axis`).
Vector3 stablePerpendicular(const Vector3& axis);

// Unit quaternion. The assembly core works in translation+quaternion —
// never Euler angles (core Transform stays UI/legacy-only per the
// assembly design).
struct Quaternion {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
    double w = 1.0;

    static Quaternion identity();
    static Quaternion fromAxisAngle(const Vector3& axis, double angleRadians);
    // Shortest-arc rotation mapping unit vector `from` onto unit vector
    // `to`; handles the antiparallel case with a stable perpendicular.
    static Quaternion rotationBetween(const Vector3& from, const Vector3& to);

    Quaternion normalized() const;
    // Inverse for unit quaternions.
    Quaternion conjugate() const;
    // Hamilton product: (this * rhs) applies rhs first, then this.
    Quaternion multiply(const Quaternion& rhs) const;
    Vector3 rotate(const Vector3& v) const;
    double norm() const;
};

// Rigid placement: rotation then translation (p' = R*p + t).
struct Placement {
    Vector3 translation;
    Quaternion rotation;

    static Placement identity();

    // this ∘ child: applies child first, then this.
    Placement compose(const Placement& child) const;
    Placement inverse() const;
    Vector3 apply(const Vector3& point) const;
    Vector3 applyDirection(const Vector3& direction) const;
};

// Orthonormal right-handed frame (local coordinate system a geometry
// reference resolves to): origin + X/Y/Z axes.
struct Frame {
    Vector3 origin;
    Vector3 xAxis{1.0, 0.0, 0.0};
    Vector3 yAxis{0.0, 1.0, 0.0};
    Vector3 zAxis{0.0, 0.0, 1.0};

    static Frame identity();
    // Builds an orthonormal frame from origin, primary Z axis and an X
    // hint (re-orthogonalized against Z; Y completes the right-handed
    // triad). Degenerate hints fall back to a stable perpendicular.
    static Frame fromOriginZX(const Vector3& origin, const Vector3& zAxis,
                              const Vector3& xHint);

    // Rotation quaternion of the axes (Shepperd's method) + origin.
    Placement toPlacement() const;
    Frame transformedBy(const Placement& placement) const;
};

// Euler display conversions following the core Transform convention:
// degrees, applied about world X, then Y, then Z (R = Rz·Ry·Rx). The
// assembly core itself is quaternion-only — these exist for UI fields.
Vector3 eulerXYZDegreesFromQuaternion(const Quaternion& rotation);
Quaternion quaternionFromEulerXYZDegrees(double xDeg, double yDeg, double zDeg);

bool nearlyEqual(double a, double b, double tolerance);
bool nearlyEqual(const Vector3& a, const Vector3& b, double tolerance);

} // namespace cadnext::assembly
