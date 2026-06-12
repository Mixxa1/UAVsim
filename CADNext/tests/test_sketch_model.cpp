#include "cadnext/Command.hpp"
#include "cadnext/CommandStack.hpp"
#include "cadnext/Document.hpp"

#include <cassert>

int main() {
    cadnext::Document document;

    // Create a sketch on the XY plane.
    cadnext::Sketch sketch;
    sketch.id = "sketch-1";
    sketch.name = "Sketch XY 1";
    sketch.plane = cadnext::SketchPlane::XY;
    document.addSketch(sketch);

    assert(document.sketches().size() == 1);
    assert(document.sketchById("sketch-1").isOk());
    assert(!document.sketchById("missing").isOk());

    cadnext::Sketch* mutableSketch = document.mutableSketchById("sketch-1");
    assert(mutableSketch != nullptr);

    // Line.
    cadnext::SketchEntity line;
    line.id = "line-1";
    line.name = "Line 1";
    line.type = cadnext::SketchEntityType::Line;
    line.line.start = {0.0, 0.0};
    line.line.end = {1.0, 0.0};
    mutableSketch->entities.push_back(line);

    // Rectangle.
    cadnext::SketchEntity rect;
    rect.id = "rect-1";
    rect.name = "Rectangle 1";
    rect.type = cadnext::SketchEntityType::Rectangle;
    rect.rectangle.origin = {0.0, 0.0};
    rect.rectangle.width = 1.0;
    rect.rectangle.height = 0.6;
    mutableSketch->entities.push_back(rect);

    // Circle.
    cadnext::SketchEntity circle;
    circle.id = "circle-1";
    circle.name = "Circle 1";
    circle.type = cadnext::SketchEntityType::Circle;
    circle.circle.center = {0.5, 0.5};
    circle.circle.radius = 0.25;
    mutableSketch->entities.push_back(circle);

    assert(mutableSketch->entities.size() == 3);
    assert(cadnext::findSketchEntity(*mutableSketch, "rect-1") != nullptr);
    assert(cadnext::findSketchEntity(*mutableSketch, "missing") == nullptr);

    // Rename entity (direct).
    cadnext::findSketchEntity(*mutableSketch, "line-1")->name = "Edge A";
    assert(document.sketchById("sketch-1").value().entities.front().name == "Edge A");

    // Remove entity.
    assert(cadnext::removeSketchEntity(*mutableSketch, "circle-1"));
    assert(!cadnext::removeSketchEntity(*mutableSketch, "circle-1"));
    assert(mutableSketch->entities.size() == 2);

    // Command-stack integration: add + rename sketch entity commands.
    cadnext::CommandStack stack;

    cadnext::SketchEntity commandCircle;
    commandCircle.id = "circle-2";
    commandCircle.name = "Circle 2";
    commandCircle.type = cadnext::SketchEntityType::Circle;
    commandCircle.circle.center = {2.0, 2.0};
    commandCircle.circle.radius = 0.4;

    stack.push(std::make_unique<cadnext::AddSketchEntityCommand>("sketch-1", commandCircle),
               document);
    assert(cadnext::findSketchEntity(*mutableSketch, "circle-2") != nullptr);
    stack.undo(document);
    assert(cadnext::findSketchEntity(*mutableSketch, "circle-2") == nullptr);
    stack.redo(document);
    assert(cadnext::findSketchEntity(*mutableSketch, "circle-2") != nullptr);

    stack.push(std::make_unique<cadnext::RenameSketchEntityCommand>("sketch-1", "circle-2",
                                                                    "Circle 2", "Bore"),
               document);
    assert(cadnext::findSketchEntity(*mutableSketch, "circle-2")->name == "Bore");
    stack.undo(document);
    assert(cadnext::findSketchEntity(*mutableSketch, "circle-2")->name == "Circle 2");

    // Commands survive a deleted sketch as no-ops.
    assert(document.removeSketch("sketch-1"));
    assert(!document.removeSketch("sketch-1"));
    stack.undo(document);
    stack.redo(document);
    assert(document.sketches().empty());

    return 0;
}
