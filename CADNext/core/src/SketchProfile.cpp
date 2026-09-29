#include "cadnext/SketchProfile.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
#include <tuple>

namespace cadnext {

namespace {

constexpr double kPointTolerance = 1.0e-6;
constexpr double kMinArea = 1.0e-9;
constexpr int kCircleApproximationSegments = 32;

// FNV-1a over the sorted source entity ids: the polygon profile id is a
// pure function of its member lines, stable across runs and platforms.
std::string fnv1aHex(const std::vector<std::string>& parts) {
    std::uint64_t hash = 1469598103934665603ull;
    for (const std::string& part : parts) {
        for (const char c : part) {
            hash ^= static_cast<std::uint64_t>(static_cast<unsigned char>(c));
            hash *= 1099511628211ull;
        }
        hash ^= static_cast<std::uint64_t>('\n');
        hash *= 1099511628211ull;
    }
    char buffer[20];
    std::snprintf(buffer, sizeof(buffer), "%016llx",
                  static_cast<unsigned long long>(hash));
    return buffer;
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
    profile.id = "profile-" + entity.id;
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
    profile.id = "profile-" + entity.id;
    profile.sketchId = sketch.id;
    profile.kind = SketchProfileKind::Circle;
    profile.sourceEntityId = entity.id;
    profile.circleCenter = circle.center;
    profile.circleRadius = circle.radius;
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

// ARC entities and bulged LWPOLYLINE segments can define a complete circle.
// Grouping by exact centre/radius avoids substituting a merely nearby circle
// for the source curves. Each arc's covered angular intervals must tile the
// whole turn without overlaps or gaps.
void detectArcCircles(const Sketch& sketch, std::vector<SketchProfile>& profiles) {
    using CircleKey = std::tuple<double, double, double>;
    std::map<CircleKey, std::vector<const SketchEntity*>> circles;
    for (const auto& entity : sketch.entities) {
        if (entity.type != SketchEntityType::Arc || entity.id.empty()) continue;
        const SketchArc& arc = entity.arc;
        if (!isFinitePoint(arc.center) || !std::isfinite(arc.radius) ||
            arc.radius <= 0.0 || !std::isfinite(arc.startAngleDegrees) ||
            !std::isfinite(arc.sweepDegrees) || arc.sweepDegrees <= 0.0 ||
            arc.sweepDegrees >= 360.0) continue;
        circles[{arc.center.u, arc.center.v, arc.radius}].push_back(&entity);
    }
    for (const auto& [key, entities] : circles) {
        if (entities.size() < 2) continue;
        std::vector<std::pair<double, double>> intervals;
        std::vector<std::string> ids;
        for (const auto* entity : entities) {
            const auto& arc = entity->arc;
            double start = std::fmod(arc.startAngleDegrees, 360.0);
            if (start < 0.0) start += 360.0;
            const double end = start + arc.sweepDegrees;
            if (end <= 360.0) {
                intervals.emplace_back(start, end);
            } else {
                intervals.emplace_back(start, 360.0);
                intervals.emplace_back(0.0, end - 360.0);
            }
            ids.push_back(entity->id);
        }
        std::sort(intervals.begin(), intervals.end());
        double covered = 0.0;
        bool complete = true;
        for (const auto& [start, end] : intervals) {
            if (std::fabs(start - covered) > 1.0e-12 || end <= start) {
                complete = false;
                break;
            }
            covered = end;
        }
        if (!complete || std::fabs(covered - 360.0) > 1.0e-12) continue;
        std::sort(ids.begin(), ids.end());
        SketchProfile profile;
        profile.id = "profile-arcs-" + fnv1aHex(ids);
        profile.sketchId = sketch.id;
        profile.kind = SketchProfileKind::Circle;
        profile.sourceEntityIds = std::move(ids);
        profile.circleCenter = {std::get<0>(key), std::get<1>(key)};
        profile.circleRadius = std::get<2>(key);
        for (int i = 0; i < kCircleApproximationSegments; ++i) {
            const double angle = 360.0 * i / kCircleApproximationSegments;
            profile.outerLoop.push_back(sketchArcPoint(
                {profile.circleCenter, profile.circleRadius, 0.0, 90.0}, angle));
        }
        profile.area = M_PI * profile.circleRadius * profile.circleRadius;
        profile.isClosed = true;
        profile.isValid = true;
        profiles.push_back(std::move(profile));
    }
}

// v2 closed-loop detection: graph-based, order-independent. Line
// endpoints are clustered into vertices with kSketchEndpointTolerance;
// every connected component whose vertices all have degree 2 is walked as
// one simple loop. Open chains and branching components yield nothing;
// closed but self-intersecting loops are reported as invalid so the GUI
// can explain why they cannot be extruded. Multiple separate loops in one
// sketch all become profiles.
void detectLineLoops(const Sketch& sketch, std::vector<SketchProfile>& profiles) {
    struct Edge {
        size_t nodeA = 0;
        size_t nodeB = 0;
        const SketchEntity* entity = nullptr;
    };

    // Endpoint clustering: a point joins the first existing vertex within
    // tolerance, otherwise it becomes a new vertex.
    std::vector<SketchPoint2D> nodes;
    const auto nodeFor = [&nodes](const SketchPoint2D& point) -> size_t {
        for (size_t i = 0; i < nodes.size(); ++i) {
            if (std::hypot(nodes[i].u - point.u, nodes[i].v - point.v) <=
                kSketchEndpointTolerance) {
                return i;
            }
        }
        nodes.push_back(point);
        return nodes.size() - 1;
    };

    std::vector<Edge> edges;
    for (const SketchEntity& entity : sketch.entities) {
        if (entity.type != SketchEntityType::Line) {
            continue;
        }
        if (!isFinitePoint(entity.line.start) || !isFinitePoint(entity.line.end)) {
            continue;
        }
        const size_t a = nodeFor(entity.line.start);
        const size_t b = nodeFor(entity.line.end);
        if (a == b) {
            continue; // degenerate (zero-length) line
        }
        edges.push_back({a, b, &entity});
    }
    if (edges.size() < 3) {
        return;
    }

    std::vector<std::vector<size_t>> adjacency(nodes.size());
    for (size_t e = 0; e < edges.size(); ++e) {
        adjacency[edges[e].nodeA].push_back(e);
        adjacency[edges[e].nodeB].push_back(e);
    }

    std::vector<bool> edgeUsed(edges.size(), false);
    for (size_t startEdge = 0; startEdge < edges.size(); ++startEdge) {
        if (edgeUsed[startEdge]) {
            continue;
        }

        // Walk the component as a degree-2 chain. Any vertex with a
        // different degree means open chain or branching — not a simple
        // loop; its edges are marked used so they are not retried.
        const size_t startNode = edges[startEdge].nodeA;
        std::vector<size_t> loopNodes;
        std::vector<const SketchEntity*> loopEntities;
        std::vector<size_t> walkedEdges;
        size_t currentNode = startNode;
        size_t currentEdge = startEdge;
        bool isLoop = true;
        while (true) {
            if (adjacency[currentNode].size() != 2) {
                isLoop = false;
                break;
            }
            loopNodes.push_back(currentNode);
            loopEntities.push_back(edges[currentEdge].entity);
            walkedEdges.push_back(currentEdge);
            edgeUsed[currentEdge] = true;

            const Edge& edge = edges[currentEdge];
            const size_t nextNode = edge.nodeA == currentNode ? edge.nodeB : edge.nodeA;
            if (nextNode == startNode) {
                break; // closed
            }
            if (adjacency[nextNode].size() != 2) {
                isLoop = false;
                break;
            }
            const size_t next0 = adjacency[nextNode][0];
            const size_t next1 = adjacency[nextNode][1];
            const size_t nextEdge = next0 == currentEdge ? next1 : next0;
            if (edgeUsed[nextEdge]) {
                isLoop = false; // already consumed — malformed component
                break;
            }
            currentNode = nextNode;
            currentEdge = nextEdge;
        }
        if (!isLoop || loopNodes.size() < 3) {
            continue;
        }

        std::vector<SketchPoint2D> loop;
        loop.reserve(loopNodes.size());
        for (const size_t node : loopNodes) {
            loop.push_back(nodes[node]);
        }
        const double area = polygonArea(loop);
        const bool selfIntersecting = polygonIsSelfIntersecting(loop);
        if (area < kMinArea && !selfIntersecting) {
            continue;
        }

        SketchProfile profile;
        profile.sketchId = sketch.id;
        profile.kind = SketchProfileKind::Polygon;
        profile.outerLoop = std::move(loop);
        for (const SketchEntity* entity : loopEntities) {
            profile.sourceEntityIds.push_back(entity->id);
        }
        std::vector<std::string> sortedIds = profile.sourceEntityIds;
        std::sort(sortedIds.begin(), sortedIds.end());
        profile.id = "profile-poly-" + fnv1aHex(sortedIds);
        profile.area = area;
        profile.isClosed = true;
        if (selfIntersecting) {
            profile.isValid = false;
            profile.invalidReason = SketchProfileInvalidReason::SelfIntersecting;
        } else {
            profile.isValid = true;
        }
        profiles.push_back(std::move(profile));
    }
}

// Walk connected line/arc chains without replacing their circular edges by
// segments. The sampled outerLoop is used only for picking and preview; the
// ordered segments are passed to the exact BRep kernel.
void detectMixedLoops(const Sketch& sketch, std::vector<SketchProfile>& profiles) {
    // OCCT must connect the original analytic curve endpoints without moving
    // them. Keep this tighter than the display-oriented line snap tolerance.
    constexpr double kExactCurveEndpointTolerance = 1.0e-9;
    struct Edge {
        size_t a = 0;
        size_t b = 0;
        const SketchEntity* entity = nullptr;
    };
    std::vector<SketchPoint2D> nodes;
    const auto nodeFor = [&nodes](const SketchPoint2D& point) {
        for (size_t i = 0; i < nodes.size(); ++i)
            if (std::hypot(nodes[i].u - point.u, nodes[i].v - point.v) <=
                kExactCurveEndpointTolerance) return i;
        nodes.push_back(point);
        return nodes.size() - 1;
    };
    std::vector<Edge> edges;
    for (const auto& entity : sketch.entities) {
        SketchPoint2D start, end;
        if (entity.type == SketchEntityType::Line) {
            start = entity.line.start;
            end = entity.line.end;
        } else if (entity.type == SketchEntityType::Arc) {
            if (!isFinitePoint(entity.arc.center) ||
                !std::isfinite(entity.arc.radius) || entity.arc.radius <= 0.0 ||
                !std::isfinite(entity.arc.startAngleDegrees) ||
                !std::isfinite(entity.arc.sweepDegrees) ||
                entity.arc.sweepDegrees <= 0.0 || entity.arc.sweepDegrees >= 360.0)
                continue;
            start = sketchArcStart(entity.arc);
            end = sketchArcEnd(entity.arc);
        } else {
            continue;
        }
        if (!isFinitePoint(start) || !isFinitePoint(end)) continue;
        const size_t a = nodeFor(start), b = nodeFor(end);
        if (a != b) edges.push_back({a, b, &entity});
    }
    if (edges.size() < 2) return;
    std::vector<std::vector<size_t>> adjacency(nodes.size());
    for (size_t i = 0; i < edges.size(); ++i) {
        adjacency[edges[i].a].push_back(i);
        adjacency[edges[i].b].push_back(i);
    }
    std::vector<bool> used(edges.size(), false);
    for (size_t first = 0; first < edges.size(); ++first) {
        if (used[first]) continue;
        const size_t startNode = edges[first].a;
        size_t node = startNode, edgeIndex = first;
        std::vector<SketchProfile::Segment> segments;
        std::vector<std::string> ids;
        bool hasArc = false, closed = false;
        for (size_t step = 0; step < edges.size(); ++step) {
            if (adjacency[node].size() != 2 || used[edgeIndex]) break;
            const Edge& edge = edges[edgeIndex];
            const bool forward = edge.a == node;
            const SketchEntity& entity = *edge.entity;
            SketchProfile::Segment segment;
            if (entity.type == SketchEntityType::Line) {
                segment.start = forward ? entity.line.start : entity.line.end;
                segment.end = forward ? entity.line.end : entity.line.start;
            } else {
                hasArc = true;
                segment.isArc = true;
                segment.start = forward ? sketchArcStart(entity.arc) : sketchArcEnd(entity.arc);
                segment.end = forward ? sketchArcEnd(entity.arc) : sketchArcStart(entity.arc);
                segment.middle = sketchArcPoint(
                    entity.arc, entity.arc.startAngleDegrees +
                                    entity.arc.sweepDegrees * 0.5);
                segment.center = entity.arc.center;
                segment.radius = entity.arc.radius;
                segment.signedSweepRadians =
                    (forward ? 1.0 : -1.0) * entity.arc.sweepDegrees * M_PI / 180.0;
            }
            segments.push_back(segment);
            ids.push_back(entity.id);
            used[edgeIndex] = true;
            const size_t nextNode = forward ? edge.b : edge.a;
            if (nextNode == startNode) {
                closed = true;
                break;
            }
            if (adjacency[nextNode].size() != 2) break;
            const size_t next0 = adjacency[nextNode][0];
            const size_t next1 = adjacency[nextNode][1];
            edgeIndex = next0 == edgeIndex ? next1 : next0;
            node = nextNode;
        }
        if (!closed || !hasArc) continue;
        SketchProfile profile;
        profile.kind = SketchProfileKind::Curved;
        profile.sketchId = sketch.id;
        profile.segments = std::move(segments);
        profile.sourceEntityIds = std::move(ids);
        auto sortedIds = profile.sourceEntityIds;
        std::sort(sortedIds.begin(), sortedIds.end());
        bool alreadyCircle = false;
        for (const auto& existing : profiles) {
            if (existing.kind != SketchProfileKind::Circle ||
                existing.sourceEntityIds.size() != sortedIds.size()) continue;
            auto circleIds = existing.sourceEntityIds;
            std::sort(circleIds.begin(), circleIds.end());
            if (circleIds == sortedIds) {
                alreadyCircle = true;
                break;
            }
        }
        if (alreadyCircle) continue;
        profile.id = "profile-curved-" + fnv1aHex(sortedIds);
        double doubledArea = 0.0;
        for (const auto& segment : profile.segments) {
            doubledArea += segment.start.u * segment.end.v -
                           segment.end.u * segment.start.v;
            if (segment.isArc) {
                doubledArea += segment.radius * segment.radius *
                    (segment.signedSweepRadians - std::sin(segment.signedSweepRadians));
            }
            const int count = segment.isArc
                ? std::max(2, int(std::ceil(std::fabs(segment.signedSweepRadians) /
                                            (M_PI / 16.0)))) : 1;
            if (!segment.isArc) {
                profile.outerLoop.push_back(segment.start);
            } else {
                const double startAngle = std::atan2(
                    segment.start.v - segment.center.v,
                    segment.start.u - segment.center.u);
                for (int i = 0; i < count; ++i) {
                    const double fraction = double(i) / double(count);
                    const double angle = startAngle + segment.signedSweepRadians * fraction;
                    profile.outerLoop.push_back({
                        segment.center.u + segment.radius * std::cos(angle),
                        segment.center.v + segment.radius * std::sin(angle)});
                }
            }
        }
        profile.area = std::fabs(doubledArea) * 0.5;
        profile.isClosed = true;
        profile.isValid = profile.area >= kMinArea &&
                          !polygonIsSelfIntersecting(profile.outerLoop);
        if (!profile.isValid) profile.invalidReason = SketchProfileInvalidReason::SelfIntersecting;
        if (profile.outerLoop.size() >= 3) profiles.push_back(std::move(profile));
    }
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
            break; // handled as loops below
        case SketchEntityType::Arc:
            break; // Curved profile construction is not implemented yet.
        }
    }
    detectArcCircles(sketch, profiles);
    detectLineLoops(sketch, profiles);
    detectMixedLoops(sketch, profiles);
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
