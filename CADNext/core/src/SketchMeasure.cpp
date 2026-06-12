#include "cadnext/SketchMeasure.hpp"

#include <cmath>

namespace cadnext {

double sketchLineLength(const SketchLine& line) {
    return sketchLineLength(line.start, line.end);
}

double sketchLineLength(const SketchPoint2D& start, const SketchPoint2D& end) {
    return std::hypot(end.u - start.u, end.v - start.v);
}

double sketchRectangleWidth(const SketchRectangle& rectangle) {
    return std::fabs(rectangle.width);
}

double sketchRectangleHeight(const SketchRectangle& rectangle) {
    return std::fabs(rectangle.height);
}

double sketchCircleRadius(const SketchCircle& circle) {
    return std::fabs(circle.radius);
}

double sketchCircleDiameter(const SketchCircle& circle) {
    return 2.0 * sketchCircleRadius(circle);
}

} // namespace cadnext
