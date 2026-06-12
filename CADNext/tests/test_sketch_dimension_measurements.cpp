#include "cadnext/SketchMeasure.hpp"
#include "cadnext/Units.hpp"

#include <cassert>
#include <cmath>

int main() {
    // Line length: classic 3-4-5 triangle.
    cadnext::SketchLine line;
    line.start = {0.001, 0.002};
    line.end = {0.004, 0.006};
    assert(std::fabs(cadnext::sketchLineLength(line) - 0.005) < 1.0e-12);
    assert(std::fabs(cadnext::sketchLineLength(line.start, line.end) - 0.005) < 1.0e-12);
    assert(cadnext::formatMillimeters(cadnext::sketchLineLength(line)) == "5.000 мм");

    // Degenerate line measures zero.
    assert(cadnext::sketchLineLength(line.start, line.start) == 0.0);

    // Rectangle width/height (normalized to absolute values).
    cadnext::SketchRectangle rectangle;
    rectangle.origin = {-0.015, 0.0};
    rectangle.width = 0.03;
    rectangle.height = 0.012;
    assert(std::fabs(cadnext::sketchRectangleWidth(rectangle) - 0.03) < 1.0e-12);
    assert(std::fabs(cadnext::sketchRectangleHeight(rectangle) - 0.012) < 1.0e-12);
    assert(cadnext::formatMillimeters(cadnext::sketchRectangleWidth(rectangle)) ==
           "30.000 мм");
    assert(cadnext::formatMillimeters(cadnext::sketchRectangleHeight(rectangle)) ==
           "12.000 мм");
    rectangle.width = -0.03;
    assert(std::fabs(cadnext::sketchRectangleWidth(rectangle) - 0.03) < 1.0e-12);

    // Circle radius/diameter.
    cadnext::SketchCircle circle;
    circle.center = {0.1, -0.2};
    circle.radius = 0.008;
    assert(std::fabs(cadnext::sketchCircleRadius(circle) - 0.008) < 1.0e-12);
    assert(std::fabs(cadnext::sketchCircleDiameter(circle) - 0.016) < 1.0e-12);
    assert(cadnext::formatMillimeters(cadnext::sketchCircleRadius(circle)) == "8.000 мм");
    assert(cadnext::formatMillimeters(cadnext::sketchCircleDiameter(circle)) == "16.000 мм");

    return 0;
}
