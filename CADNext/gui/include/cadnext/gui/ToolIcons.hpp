#pragma once

#include <QColor>
#include <QIcon>
#include <QPixmap>

namespace cadnext::gui {

// Toolbar glyphs, drawn rather than loaded: the Qt this builds against ships without the SVG
// plugin, and a drawn glyph takes its line colour from the palette, so it follows the light and
// the dark theme and stays sharp at any pixel ratio.
enum class ToolIcon {
    // Part window, main toolbar.
    AddBox,
    AddCylinder,
    AddSphere,
    AddPlane,
    Extrude,
    Revolve,
    CutExtrude,
    Chamfer,
    Fillet,
    Thread,
    SketchOnFace,
    WorkPlaneFromFace,
    NormalToFace,
    AttachmentPoint,
    Delete,
    FitSelection,
    FitView,
    ResetCamera,
    // Part window, sketch toolbar.
    SketchXY,
    SketchXZ,
    SketchYZ,
    CreateSketch,
    EnterSketch,
    ExitSketch,
    SelectTool,
    LineTool,
    RectangleTool,
    CircleTool,
    SnapGrid,
    ShowGrid,
    // Part window, tests toolbar.
    Aerodynamics,
    Structural,
    // Assembly window.
    NewDocument,
    OpenDocument,
    SaveDocument,
    InsertPart,
    Ground,
    Move,
    JointCoincident,
    JointParallel,
    JointPerpendicular,
    JointConcentric,
    JointDistance,
    JointAngle,
    JointRigid,
    Recompute,

    Count
};

// Side of a toolbar button's glyph, in device-independent pixels.
inline constexpr int kToolIconSize = 28;

QIcon toolIcon(ToolIcon icon);

// One glyph against a given line colour — what the icon paints, without the application palette
// (previews and tests).
QPixmap toolIconPixmap(ToolIcon icon, int side, qreal devicePixelRatio, const QColor& ink,
                       QIcon::Mode mode = QIcon::Normal);

} // namespace cadnext::gui
