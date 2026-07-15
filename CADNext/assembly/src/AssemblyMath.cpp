#include "cadnext/assembly/AssemblyMath.hpp"

#include <cmath>

namespace cadnext::assembly {

Vector3 add(const Vector3& a, const Vector3& b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

Vector3 subtract(const Vector3& a, const Vector3& b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

Vector3 scale(const Vector3& v, double factor) {
    return {v.x * factor, v.y * factor, v.z * factor};
}

double dot(const Vector3& a, const Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vector3 cross(const Vector3& a, const Vector3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

double length(const Vector3& v) {
    return std::sqrt(dot(v, v));
}

Vector3 normalizedOr(const Vector3& v, const Vector3& fallback) {
    const double len = length(v);
    if (!std::isfinite(len) || len <= 1.0e-12) {
        return fallback;
    }
    return {v.x / len, v.y / len, v.z / len};
}

Vector3 stablePerpendicular(const Vector3& axis) {
    const Vector3 unit = normalizedOr(axis, {0.0, 0.0, 1.0});
    const double ax = std::fabs(unit.x);
    const double ay = std::fabs(unit.y);
    const double az = std::fabs(unit.z);
    Vector3 seed{1.0, 0.0, 0.0};
    if (ay <= ax && ay <= az) {
        seed = {0.0, 1.0, 0.0};
    } else if (az <= ax && az <= ay) {
        seed = {0.0, 0.0, 1.0};
    }
    const Vector3 projected = subtract(seed, scale(unit, dot(seed, unit)));
    return normalizedOr(projected, {1.0, 0.0, 0.0});
}

Quaternion Quaternion::identity() {
    return {};
}

Quaternion Quaternion::fromAxisAngle(const Vector3& axis, double angleRadians) {
    const Vector3 unit = normalizedOr(axis, {0.0, 0.0, 1.0});
    const double half = angleRadians * 0.5;
    const double s = std::sin(half);
    Quaternion q;
    q.x = unit.x * s;
    q.y = unit.y * s;
    q.z = unit.z * s;
    q.w = std::cos(half);
    return q.normalized();
}

Quaternion Quaternion::rotationBetween(const Vector3& from, const Vector3& to) {
    const Vector3 f = normalizedOr(from, {0.0, 0.0, 1.0});
    const Vector3 t = normalizedOr(to, {0.0, 0.0, 1.0});
    const double cosine = dot(f, t);
    if (cosine >= 1.0 - 1.0e-12) {
        return identity();
    }
    if (cosine <= -1.0 + 1.0e-12) {
        // Antiparallel: rotate half a turn around any perpendicular.
        const Vector3 axis = stablePerpendicular(f);
        return fromAxisAngle(axis, M_PI);
    }
    const Vector3 axis = cross(f, t);
    Quaternion q;
    q.x = axis.x;
    q.y = axis.y;
    q.z = axis.z;
    q.w = 1.0 + cosine;
    return q.normalized();
}

double Quaternion::norm() const {
    return std::sqrt(x * x + y * y + z * z + w * w);
}

Quaternion Quaternion::normalized() const {
    const double n = norm();
    if (!std::isfinite(n) || n <= 1.0e-15) {
        return identity();
    }
    return {x / n, y / n, z / n, w / n};
}

Quaternion Quaternion::conjugate() const {
    return {-x, -y, -z, w};
}

Quaternion Quaternion::multiply(const Quaternion& rhs) const {
    Quaternion q;
    q.w = w * rhs.w - x * rhs.x - y * rhs.y - z * rhs.z;
    q.x = w * rhs.x + x * rhs.w + y * rhs.z - z * rhs.y;
    q.y = w * rhs.y - x * rhs.z + y * rhs.w + z * rhs.x;
    q.z = w * rhs.z + x * rhs.y - y * rhs.x + z * rhs.w;
    return q;
}

Vector3 Quaternion::rotate(const Vector3& v) const {
    // v' = v + 2*q_vec × (q_vec × v + w*v)
    const Vector3 qv{x, y, z};
    const Vector3 t = scale(cross(qv, add(cross(qv, v), scale(v, w))), 2.0);
    return add(v, t);
}

Placement Placement::identity() {
    return {};
}

Placement Placement::compose(const Placement& child) const {
    Placement result;
    result.rotation = rotation.multiply(child.rotation).normalized();
    result.translation = add(translation, rotation.rotate(child.translation));
    return result;
}

Placement Placement::inverse() const {
    Placement result;
    result.rotation = rotation.conjugate();
    result.translation = scale(result.rotation.rotate(translation), -1.0);
    return result;
}

Vector3 Placement::apply(const Vector3& point) const {
    return add(rotation.rotate(point), translation);
}

Vector3 Placement::applyDirection(const Vector3& direction) const {
    return rotation.rotate(direction);
}

Frame Frame::identity() {
    return {};
}

Frame Frame::fromOriginZX(const Vector3& origin, const Vector3& zAxis,
                          const Vector3& xHint) {
    Frame frame;
    frame.origin = origin;
    frame.zAxis = normalizedOr(zAxis, {0.0, 0.0, 1.0});
    const Vector3 projected =
        subtract(xHint, scale(frame.zAxis, dot(xHint, frame.zAxis)));
    frame.xAxis = normalizedOr(projected, stablePerpendicular(frame.zAxis));
    frame.yAxis = normalizedOr(cross(frame.zAxis, frame.xAxis), {0.0, 1.0, 0.0});
    // Re-derive X so the triad is exactly orthonormal right-handed even
    // for slightly skewed inputs.
    frame.xAxis = normalizedOr(cross(frame.yAxis, frame.zAxis), frame.xAxis);
    return frame;
}

Placement Frame::toPlacement() const {
    // Rotation matrix columns are the frame axes; Shepperd's method picks
    // the numerically largest quaternion component first.
    const double m00 = xAxis.x, m01 = yAxis.x, m02 = zAxis.x;
    const double m10 = xAxis.y, m11 = yAxis.y, m12 = zAxis.y;
    const double m20 = xAxis.z, m21 = yAxis.z, m22 = zAxis.z;
    const double trace = m00 + m11 + m22;

    Quaternion q;
    if (trace > 0.0) {
        const double s = std::sqrt(trace + 1.0) * 2.0;
        q.w = 0.25 * s;
        q.x = (m21 - m12) / s;
        q.y = (m02 - m20) / s;
        q.z = (m10 - m01) / s;
    } else if (m00 > m11 && m00 > m22) {
        const double s = std::sqrt(1.0 + m00 - m11 - m22) * 2.0;
        q.w = (m21 - m12) / s;
        q.x = 0.25 * s;
        q.y = (m01 + m10) / s;
        q.z = (m02 + m20) / s;
    } else if (m11 > m22) {
        const double s = std::sqrt(1.0 + m11 - m00 - m22) * 2.0;
        q.w = (m02 - m20) / s;
        q.x = (m01 + m10) / s;
        q.y = 0.25 * s;
        q.z = (m12 + m21) / s;
    } else {
        const double s = std::sqrt(1.0 + m22 - m00 - m11) * 2.0;
        q.w = (m10 - m01) / s;
        q.x = (m02 + m20) / s;
        q.y = (m12 + m21) / s;
        q.z = 0.25 * s;
    }

    Placement placement;
    placement.rotation = q.normalized();
    placement.translation = origin;
    return placement;
}

Frame Frame::transformedBy(const Placement& placement) const {
    Frame frame;
    frame.origin = placement.apply(origin);
    frame.xAxis = placement.applyDirection(xAxis);
    frame.yAxis = placement.applyDirection(yAxis);
    frame.zAxis = placement.applyDirection(zAxis);
    return frame;
}

bool nearlyEqual(double a, double b, double tolerance) {
    return std::fabs(a - b) <= tolerance;
}

bool nearlyEqual(const Vector3& a, const Vector3& b, double tolerance) {
    return nearlyEqual(a.x, b.x, tolerance) && nearlyEqual(a.y, b.y, tolerance) &&
           nearlyEqual(a.z, b.z, tolerance);
}

} // namespace cadnext::assembly
