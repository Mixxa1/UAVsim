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

// Shoelace formula; positive result regardless of loop orientation.
double polygonArea(const std::vector<SketchPoint2D>& loop) {
    if (loop.size() < 3) {
        return 0.0;
    }
    double doubledArea = 0.0;
    for (size_t i = 0; i < loop.size(); ++i) {
        const SketchPoint2D& a = loop[i];
        const SketchPoint2D& b = loop[(i + 1) % loop.size()];
        doubledArea += a.u * b.v - b.u * a.v;
    }
    return std::fabs(doubledArea) * 0.5;
}

bool isFinitePoint(const SketchPoint2D& point) {
    return std::isfinite(point.u) && std::isfinite(point.v);
}

void detectRectangle(const SketchEntity& entity, std::vector<SketchProfile>& profiles) {
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
    profile.kind = SketchProfileKind::Rectangle;
    profile.outerLoop = {
        {rect.origin.u, rect.origin.v},
        {rect.origin.u + width, rect.origin.v},
        {rect.origin.u + width, rect.origin.v + height},
        {rect.origin.u, rect.origin.v + height},
    };
    profile.area = width * height;
    profiles.push_back(std::move(profile));
}

void detectCircle(const SketchEntity& entity, std::vector<SketchProfile>& profiles) {
    const SketchCircle& circle = entity.circle;
    if (!isFinitePoint(circle.center) || !std::isfinite(circle.radius) ||
        circle.radius <= 0.0) {
        return;
    }
    SketchProfile profile;
    profile.id = entity.id;
    profile.kind = SketchProfileKind::Circle;
    profile.outerLoop.reserve(kCircleApproximationSegments);
    for (int i = 0; i < kCircleApproximationSegments; ++i) {
        const double angle = 2.0 * M_PI * static_cast<double>(i) /
                             static_cast<double>(kCircleApproximationSegments);
        profile.outerLoop.push_back({circle.center.u + circle.radius * std::cos(angle),
                                     circle.center.v + circle.radius * std::sin(angle)});
    }
    profile.area = M_PI * circle.radius * circle.radius;
    profiles.push_back(std::move(profile));
}

// v1 closed-loop detection: the line entities, in entity order, must form
// one continuous chain whose last endpoint returns to the first.
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
    loop.push_back(lines.front()->line.start);
    SketchPoint2D cursor = lines.front()->line.end;
    for (size_t i = 1; i < lines.size(); ++i) {
        if (!samePoint(lines[i]->line.start, cursor)) {
            return; // chain broken — not a sequential loop
        }
        loop.push_back(lines[i]->line.start);
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

    SketchProfile profile;
    profile.id = sketch.id + "-loop";
    profile.kind = SketchProfileKind::ClosedLoop;
    profile.outerLoop = std::move(loop);
    profile.area = area;
    profiles.push_back(std::move(profile));
}

} // namespace

std::vector<SketchProfile> SketchProfileDetector::detect(const Sketch& sketch) const {
    std::vector<SketchProfile> profiles;
    for (const SketchEntity& entity : sketch.entities) {
        switch (entity.type) {
        case SketchEntityType::Rectangle:
            detectRectangle(entity, profiles);
            break;
        case SketchEntityType::Circle:
            detectCircle(entity, profiles);
            break;
        case SketchEntityType::Line:
            break; // handled as a chain below
        }
    }
    detectClosedLineLoop(sketch, profiles);
    return profiles;
}

} // namespace cadnext
