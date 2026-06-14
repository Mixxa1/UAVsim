#include "cadnext/gui/FilePreviewAssets.hpp"

#include <QFileInfo>
#include <QPixmap>

namespace cadnext::gui {

CADFilePreviewKind cadFilePreviewKind(const QString& filePath) {
    const QString ext = QFileInfo(filePath).suffix().toLower();
    if (ext == QStringLiteral("uavpart")) {
        return CADFilePreviewKind::uavpart;
    }
    if (ext == QStringLiteral("cadnext")) {
        return CADFilePreviewKind::cadnext;
    }
    return CADFilePreviewKind::unknown;
}

QPixmap cadFilePreviewPixmap(CADFilePreviewKind kind, int maxSize) {
    QString resourcePath;
    switch (kind) {
    case CADFilePreviewKind::uavpart:
        resourcePath = QStringLiteral(":/cadnext/uavpart_file_preview.png");
        break;
    case CADFilePreviewKind::cadnext:
        resourcePath = QStringLiteral(":/cadnext/cadnext_file_preview.png");
        break;
    default:
        return QPixmap();
    }
    const QPixmap pixmap(resourcePath);
    if (pixmap.isNull() || maxSize <= 0) {
        return pixmap;
    }
    return pixmap.scaled(maxSize, maxSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
}

} // namespace cadnext::gui
