#pragma once

#include "cadnext/Sketch.hpp"

#include <QByteArray>
#include <QString>

#include <vector>

namespace cadnext::gui {

struct DxfSketchData {
    std::vector<SketchEntity> entities;
    int drawingUnits = 0;
    bool assumedMillimeters = false;
};

// Reads planar model-space geometry from ASCII or modern binary DXF into an exact CADNext
// sketch. Rejects unsupported entities instead of silently dropping them.
bool readDxfSketch(const QString& path, DxfSketchData& data, QString& error);

// One group of a DXF: its code and value. ASCII values keep their spaces (only the line end goes):
// text split across groups (an ACIS body's lines) joins as written.
struct DxfGroup {
    int code = 0;
    QByteArray value;
};

// Every group of an ASCII or binary DXF, in order.
bool readDxfGroups(const QString& path, std::vector<DxfGroup>& groups, QString& error);

// Writes exact planar sketch coordinates as ASCII or binary DXF in millimeters.
bool writeDxfSketch(const QString& path, const Sketch& sketch, QString& error,
                    bool binary = false);

} // namespace cadnext::gui
