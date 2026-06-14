#pragma once

#include <QString>

class QPixmap;

namespace cadnext::gui {

enum class CADFilePreviewKind {
    cadnext,
    uavpart,
    unknown
};

// Returns the preview kind for the given file path based on its extension.
CADFilePreviewKind cadFilePreviewKind(const QString& filePath);

// Returns the fallback preview pixmap for the given kind.
// Returns a null pixmap for CADFilePreviewKind::unknown.
QPixmap cadFilePreviewPixmap(CADFilePreviewKind kind, int maxSize = 200);

} // namespace cadnext::gui
