#include "cadnext/SketchProfile.hpp"

#include <cmath>

namespace cadnext {

namespace {

constexpr double kPointTolerance = 1.0e-6;
constexpr double kMinArea = 1.0e-9;
constexpr int kCircleApproximationSegments = 32;

bool samePoint(const SketchPoint2D& a, const SketchPoint2D& b) {
    return std::fabs(a.u - b.u) <= kPointTolerance && std::fabs(a.v - b.v) <= kPointTolerance;
}

double signedDoubledArea(const std::vector<SketchPoint2D>& loop) {
    double doubled = 0.0;
    for (size_t i = 0; i < loop.size(); ++i) {
        const SketchPoint2D& a = loop[i];
        const SketchPoint2D& b = loop[(i + 1) % loop.size()];
        doubled += a.u * b.v - b.u * a.v;
    }
    return doubled;
}

// Shoelace formula; positive result regardless of loop orientation.
double polygonArea(const std::vector<SketchPoint2D>& loop) {
    if (loop.size() < 3) {
        return 0.0;
    }
    return std::fabs(signedDoubledArea(loop)) * 0.5;
}

bool isFinitePoint(const SketchPoint2D& point) {
    return std::isfinite(point.u) && std::isfinite(point.v);
}

double crossZ(const SketchPoint2D& origin, const SketchPoint2D& a, const SketchPoint2D& b) {
    return (a.u - origin.u) * (b.v - origin.v) - (a.v - origin.v) * (b.u - origin.u);
}

// Proper segment intersection (shared endpoints of adjacent edges are
// excluded by the caller via index adjacency, not geometry).
bool segmentsIntersect(const SketchPoint2D& a1, const SketchPoint2D& a2,
                       const SketchPoint2D& b1, const SketchPoint2D& b2) {
    const double d1 = crossZ(b1, b2, a1);
    const double d2 = crossZ(b1, b2, a2);
    const double d3 = crossZ(a1, a2, b1);
    const double d4 = crossZ(a1, a2, b2);
    if (((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0)) &&
        ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0))) {
        return true;
    }
    return false;
}

bool pointInTriangle(const SketchPoint2D& p, const SketchPoint2D& a, const SketchPoint2D& b,
                     const SketchPoint2D& c) {
    const double d1 = crossZ(a, b, p);
    const double d2 = crossZ(b, c, p);
    const double d3 = crossZ(c, a, p);
    const bool hasNegative = (d1 < -kPointTolerance) || (d2 < -kPointTolerance) ||
                             (d3 < -kPointTolerance);
    const bool hasPositive = (d1 > kPointTolerance) || (d2 > kPointTolerance) ||
                             (d3 > kPointTolerance);
    return !(hasNegative && hasPositive);
}

void detectRectangle(const Sketch& sketch, const SketchEntity& entity,
                     std::vector<SketchProfile>& profiles) {
    const SketchRectangle& rect = entity.rectangle;
    if (!isFinitePoint(rect.origin) || !std::isfinite(rect.width) ||
        !std::isfinite(rect.height)) {
        return;
    }
    const double width = std::fabs(rect.width);
    const double height = std::fabs(rect.height);
    if (width * height < kMinArea) {
        return;
    }
    SketchProfile profile;
    profile.id = entity.id;
    profile.sketchId = sketch.id;
    profile.kind = SketchProfileKind::Rectangle;
    profile.sourceEntityId = entity.id;
    profile.outerLoop = {
        {rect.origin.u, rect.origin.v},
        {rect.origin.u + width, rect.origin.v},
        {rect.origin.u + width, rect.origin.v + height},
        {rect.origin.u, rect.origin.v + height},
    };
    profile.area = width * height;
    profile.isClosed = true;
    profile.isValid = true;
    profiles.push_back(std::move(profile));
}

void detectCircle(const Sketch& sketch, const SketchEntity& entity,
                  std::vector<SketchProfile>& profiles) {
    const SketchCircle& circle = entity.circle;
    if (!isFinitePoint(circle.center) || !std::isfinite(circle.radius) ||
        circle.radius <= 0.0) {
        return;
    }
    SketchProfile profile;
    profile.id = entity.id;
    profile.sketchId = sketch.id;
    profile.kind = SketchProfileKind::Circle;
    profile.sourceEntityId = entity.id;
    profile.outerLoop.reserve(kCircleApproximationSegments);
    for (int i = 0; i < kCircleApproximationSegments; ++i) {
        const double angle = 2.0 * M_PI * static_cast<double>(i) /
                             static_cast<double>(kCircleApproximationSegments);
        profile.outerLoop.push_back({circle.center.u + circle.radius * std::cos(angle),
                                     circle.center.v + circle.radius * std::sin(angle)});
    }
    profile.area = M_PI * circle.radius * circle.radius;
    profile.isClosed = true;
    profile.isValid = true;
    profiles.push_back(std::move(profile));
}

// v1 closed-loop detection: the line entities, in entity order, must form
// one continuous chain whose last endpoint returns to the first. Open
// chains and self-intersecting loops yield nothing — they cannot be
// extruded.
void detectClosedLineLoop(const Sketch& sketch, std::vector<SketchProfile>& profiles) {
    std::vector<const SketchEntity*> lines;
    for (const SketchEntity& entity : sketch.entities) {
        if (entity.type == SketchEntityType::Line) {
            lines.push_back(&entity);
        }
    }
    if (lines.size() < 3) {
        return;
    }

    std::vector<SketchPoint2D> loop;
    std::vector<std::string> entityIds;
    loop.push_back(lines.front()->line.start);
    entityIds.push_back(lines.front()->id);
    SketchPoint2D cursor = lines.front()->line.end;
    for (size_t i = 1; i < lines.size(); ++i) {
        if (!samePoint(lines[i]->line.start, cursor)) {
            return; // chain broken — not a sequential loop
        }
        loop.push_back(lines[i]->line.start);
        entityIds.push_back(lines[i]->id);
        cursor = lines[i]->line.end;
    }
    if (!samePoint(cursor, lines.front()->line.start)) {
        return; // chain does not close
    }
    for (const SketchPoint2D& point : loop) {
        if (!isFinitePoint(point)) {
            return;
        }
    }

    const double area = polygonArea(loop);
    if (area < kMinArea) {
        return;
    }
    if (polygonIsSelfIntersecting(loop)) {
        return; // invalid in v1 — cannot be extruded
    }

    SketchProfile profile;
    profile.id = sketch.id + "-loop";
    profile.sketchId = sketch.id;
    profile.kind = SketchProfileKind::Polygon;
    profile.outerLoop = std::move(loop);
    profile.sourceEntityIds = std::move(entityIds);
    profile.area = area;
    profile.isClosed = true;
    profile.isValid = true;
    profiles.push_back(std::move(profile));
}

} // namespace

std::vector<SketchProfile> SketchProfileDetector::detect(const Sketch& sketch) const {
    std::vector<SketchProfile> profiles;
    for (const SketchEntity& entity : sketch.entities) {
        switch (entity.type) {
        case SketchEntityType::Rectangle:
            detectRectangle(sketch, entity, profiles);
            break;
        case SketchEntityType::Circle:
            detectCircle(sketch, entity, profiles);
            break;
        case SketchEntityType::Line:
            break; // handled as a chain below
        }
    }
    detectClosedLineLoop(sketch, profiles);
    return profiles;
}

bool polygonIsSelfIntersecting(const std::vector<SketchPoint2D>& loop) {
    const size_t n = loop.size();
    if (n < 4) {
        return false; // triangles cannot self-intersect
    }
    for (size_t i = 0; i < n; ++i) {
        const SketchPoint2D& a1 = loop[i];
        const SketchPoint2D& a2 = loop[(i + 1) % n];
        for (size_t j = i + 1; j < n; ++j) {
            // Skip adjacent edges (they share an endpoint by construction).
            if (j == i || (j + 1) % n == i || (i + 1) % n == j) {
                continue;
            }
            const SketchPoint2D& b1 = loop[j];
            const SketchPoint2D& b2 = loop[(j + 1) % n];
            if (segmentsIntersect(a1, a2, b1, b2)) {
                return true;
            }
        }
    }
    return false;
}

std::vector<unsigned int> triangulatePolygon(const std::vector<SketchPoint2D>& loop) {
    std::vector<unsigned int> triangles;
    const size_t n = loop.size();
    if (n < 3 || polygonArea(loop) < kMinArea || polygonIsSelfIntersecting(loop)) {
        return triangles;
    }

    // Work on a CCW index list so "convex corner" always means positive
    // cross product.
    std::vector<unsigned int> indices(n);
    for (size_t i = 0; i < n; ++i) {
        indices[i] = static_cast<unsigned int>(i);
    }
    if (signedDoubledArea(loop) < 0.0) {
        for (size_t i = 0; i < n; ++i) {
            indices[i] = static_cast<unsigned int>(n - 1 - i);
        }
    }

    triangles.reserve((n - 2) * 3);
    size_t guard = 0;
    const size_t maxIterations = n * n + 16;
    while (indices.size() > 3 && guard++ < maxIterations) {
        bool clipped = false;
        for (size_t i = 0; i < indices.size(); ++i) {
            const size_t prev = (i + indices.size() - 1) % indices.size();
            const size_t next = (i + 1) % indices.size();
            const SketchPoint2D& a = loop[indices[prev]];
            const SketchPoint2D& b = loop[indices[i]];
            const SketchPoint2D& c = loop[indices[next]];
            if (crossZ(a, b, c) <= kPointTolerance) {
                continue; // reflex or collinear corner — not an ear
            }
            bool containsOther = false;
            for (size_t j = 0; j < indices.size(); ++j) {
                if (j == prev || j == i || j == next) {
                    continue;
                }
                if (pointInTriangle(loop[indices[j]], a, b, c)) {
                    containsOther = true;
                    break;
                }
            }
            if (containsOther) {
                continue;
            }
            triangles.push_back(indices[prev]);
            triangles.push_back(indices[i]);
            triangles.push_back(indices[next]);
            indices.erase(indices.begin() + static_cast<long>(i));
            clipped = true;
            break;
        }
        if (!clipped) {
            return {}; // no ear found — degenerate input
        }
    }
    if (indices.size() == 3) {
        triangles.push_back(indices[0]);
        triangles.push_back(indices[1]);
        triangles.push_back(indices[2]);
    }
    return triangles;
}

bool polygonContainsPoint(const std::vector<SketchPoint2D>& loop, const SketchPoint2D& point) {
    const size_t n = loop.size();
    if (n < 3) {
        return false;
    }
    bool inside = false;
    for (size_t i = 0, j = n - 1; i < n; j = i++) {
        const SketchPoint2D& a = loop[i];
        const SketchPoint2D& b = loop[j];
        // Boundary tolerance: points on an edge count as inside.
        const double edgeCross = crossZ(a, b, point);
        const double minU = std::fmin(a.u, b.u) - kPointTolerance;
        const double maxU = std::fmax(a.u, b.u) + kPointTolerance;
        const double minV = std::fmin(a.v, b.v) - kPointTolerance;
        const double maxV = std::fmax(a.v, b.v) + kPointTolerance;
        if (std::fabs(edgeCross) <= kPointTolerance && point.u >= minU && point.u <= maxU &&
            point.v >= minV && point.v <= maxV) {
            return true;
        }
        if ((a.v > point.v) != (b.v > point.v)) {
            const double intersectU = a.u + (b.u - a.u) * (point.v - a.v) / (b.v - a.v);
            if (point.u < intersectU) {
                inside = !inside;
            }
        }
    }
    return inside;
}

} // namespace cadnext
