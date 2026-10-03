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

// Reads planar model-space geometry from ASCII or binary DXF into an exact CADNext sketch.
// Rejects unsupported entities instead of silently dropping them. Binary DXF is read in both
// forms: two-byte group codes (AutoCAD R13 and later) and one-byte codes (before R13; 255
// announces a two-byte code). The old form is read from Autodesk's description of it: there is
// no file of it among the samples.
bool readDxfSketch(const QString& path, DxfSketchData& data, QString& error);

// One group of a DXF: its code and value. ASCII values keep their spaces (only the line end goes):
// text split across groups (an ACIS body's lines) joins as written.
struct DxfGroup {
    int code = 0;
    QByteArray value;
};

// Every group of an ASCII or binary DXF, in order.
bool readDxfGroups(const QString& path, std::vector<DxfGroup>& groups, QString& error);
// The same of a DXF held in memory.
bool decodeDxfGroups(QByteArray bytes, std::vector<DxfGroup>& groups, QString& error);

// An ASCII DXF's groups as a binary DXF: the 22-byte sentinel, then each group as a 16-bit code and
// a value of the code's type (a zero-terminated string, a double, an integer of 1, 2, 4 or 8 bytes).
// `binary` is cleared on failure.
bool encodeBinaryDxf(const QByteArray& ascii, QByteArray& binary, QString& error);

// Writes exact planar sketch coordinates as ASCII or binary DXF in millimeters.
bool writeDxfSketch(const QString& path, const Sketch& sketch, QString& error,
                    bool binary = false);

} // namespace cadnext::gui
