#include "cadnext/SketchProfile.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>

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
        }
    }
    detectLineLoops(sketch, profiles);
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
