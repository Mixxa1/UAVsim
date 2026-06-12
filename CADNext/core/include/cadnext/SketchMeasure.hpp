#pragma once

#include "cadnext/Sketch.hpp"

namespace cadnext {

// Sketch dimension measurements (model units). The GUI formats these with
// formatMillimeters() for the live drawing readout and the property panel.
double sketchLineLength(const SketchLine& line);
double sketchLineLength(const SketchPoint2D& start, const SketchPoint2D& end);

double sketchRectangleWidth(const SketchRectangle& rectangle);
double sketchRectangleHeight(const SketchRectangle& rectangle);

double sketchCircleRadius(const SketchCircle& circle);
double sketchCircleDiameter(const SketchCircle& circle);

} // namespace cadnext
