#include "cadnext/DocumentSerializer.hpp"

#include <cassert>
#include <cmath>
#include <string>

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1e-9;
}

} // namespace

int main() {
    cadnext::Document document;
    document.setName("Sketch Serialization Sample");

    cadnext::Sketch sketch;
    sketch.id = "sketch-1";
    sketch.name = "Sketch XY 1";
    sketch.plane = cadnext::SketchPlane::XZ;

    cadnext::SketchEntity line;
    line.id = "line-1";
    line.name = "Line 1";
    line.type = cadnext::SketchEntityType::Line;
    line.line.start = {0.25, -0.5};
    line.line.end = {1.75, 2.5};
    sketch.entities.push_back(line);

    cadnext::SketchEntity rect;
    rect.id = "rect-1";
    rect.name = "Rectangle 1";
    rect.type = cadnext::SketchEntityType::Rectangle;
    rect.rectangle.origin = {-1.0, -2.0};
    rect.rectangle.width = 3.5;
    rect.rectangle.height = 0.6;
    sketch.entities.push_back(rect);

    cadnext::SketchEntity circle;
    circle.id = "circle-1";
    circle.name = "Circle 1";
    circle.type = cadnext::SketchEntityType::Circle;
    circle.circle.center = {0.5, 0.5};
    circle.circle.radius = 0.25;
    sketch.entities.push_back(circle);

    document.addSketch(sketch);

    // Round trip.
    const std::string json = cadnext::DocumentSerializer::toJson(document);
    assert(json.find("\"sketches\"") != std::string::npos);

    const auto loaded = cadnext::DocumentSerializer::fromJson(json);
    assert(loaded.isOk());
    assert(loaded.value().sketches().size() == 1);

    const cadnext::Sketch& restored = loaded.value().sketches().front();
    assert(restored.id == "sketch-1");
    assert(restored.name == "Sketch XY 1");
    assert(restored.plane == cadnext::SketchPlane::XZ);
    assert(restored.entities.size() == 3);

    const cadnext::SketchEntity& restoredLine = restored.entities[0];
    assert(restoredLine.id == "line-1");
    assert(restoredLine.type == cadnext::SketchEntityType::Line);
    assert(nearlyEqual(restoredLine.line.start.u, 0.25));
    assert(nearlyEqual(restoredLine.line.start.v, -0.5));
    assert(nearlyEqual(restoredLine.line.end.u, 1.75));
    assert(nearlyEqual(restoredLine.line.end.v, 2.5));

    const cadnext::SketchEntity& restoredRect = restored.entities[1];
    assert(restoredRect.type == cadnext::SketchEntityType::Rectangle);
    assert(nearlyEqual(restoredRect.rectangle.origin.u, -1.0));
    assert(nearlyEqual(restoredRect.rectangle.origin.v, -2.0));
    assert(nearlyEqual(restoredRect.rectangle.width, 3.5));
    assert(nearlyEqual(restoredRect.rectangle.height, 0.6));

    const cadnext::SketchEntity& restoredCircle = restored.entities[2];
    assert(restoredCircle.type == cadnext::SketchEntityType::Circle);
    assert(nearlyEqual(restoredCircle.circle.center.u, 0.5));
    assert(nearlyEqual(restoredCircle.circle.center.v, 0.5));
    assert(nearlyEqual(restoredCircle.circle.radius, 0.25));

    // Backward compatibility: documents without "sketches" still load.
    const auto legacy = cadnext::DocumentSerializer::fromJson(
        "{\"format\": \"cadnext\", \"version\": 1, \"document\": "
        "{\"id\": \"document\", \"name\": \"Old\", \"unitSystem\": \"Metric\", "
        "\"objects\": [], \"features\": []}}");
    assert(legacy.isOk());
    assert(legacy.value().sketches().empty());

    // Malformed sketch entries are skipped, not fatal.
    const auto partial = cadnext::DocumentSerializer::fromJson(
        "{\"format\": \"cadnext\", \"version\": 1, \"document\": "
        "{\"id\": \"document\", \"name\": \"Partial\", \"sketches\": ["
        "{\"name\": \"no id — skipped\"},"
        "{\"id\": \"sketch-ok\", \"name\": \"OK\", \"plane\": \"YZ\", \"entities\": ["
        "{\"name\": \"no id — skipped\", \"type\": \"Line\"},"
        "{\"id\": \"line-x\", \"type\": \"Line\"},"
        "{\"id\": \"line-good\", \"type\": \"Line\", \"line\": "
        "{\"start\": {\"u\": 0, \"v\": 0}, \"end\": {\"u\": 1, \"v\": 1}}}"
        "]}]}}");
    assert(partial.isOk());
    assert(partial.value().sketches().size() == 1);
    assert(partial.value().sketches().front().plane == cadnext::SketchPlane::YZ);
    // "line-x" has no geometry block and is skipped; only line-good remains.
    assert(partial.value().sketches().front().entities.size() == 1);
    assert(partial.value().sketches().front().entities.front().id == "line-good");

    return 0;
}
