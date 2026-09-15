#include "ViewerSnapshot.hpp"

#include "cadnext/viewer/OffscreenGL.hpp"
#include "cadnext/viewer/StructuralFieldScene.hpp"

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/SoOffscreenRenderer.h>
#include <Inventor/nodes/SoCamera.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoSeparator.h>

#include <QPainter>
#include <QPixmap>
#include <QWidget>

namespace cadnext::gui::detail {

QImage snapshotWithViewer(QWidget& window, SoQtExaminerViewer& viewer, SoNode* sceneGraph) {
    QPixmap pixmap = window.grab();
    const QWidget* area = viewer.getWidget();
    if (area == nullptr || sceneGraph == nullptr) return pixmap.toImage();
    const qreal ratio = pixmap.devicePixelRatio();
    const int width = static_cast<int>(area->width() * ratio);
    const int height = static_cast<int>(area->height() * ratio);
    viewer::installOffscreenGLContext();
    auto* root = new SoSeparator;
    root->ref();
    auto* headlight = new SoDirectionalLight;
    headlight->intensity = viewer::kStructuralHeadlightIntensity;
    if (SoCamera* camera = viewer.getCamera()) {
        SbVec3f direction;
        camera->orientation.getValue().multVec(SbVec3f(0, 0, -1), direction);
        headlight->direction = direction;
    }
    root->addChild(headlight);
    root->addChild(sceneGraph);
    SoOffscreenRenderer renderer(SbViewportRegion(static_cast<short>(width), static_cast<short>(height)));
    renderer.setBackgroundColor(viewer.getBackgroundColor());
    if (renderer.render(root)) {
        const unsigned char* buffer = renderer.getBuffer();
        const int components = renderer.getComponents();
        QImage frame(width, height, QImage::Format_RGB888);
        for (int y = 0; y < height; ++y) {
            const unsigned char* row = buffer + (height - 1 - y) * width * components;
            for (int x = 0; x < width; ++x) {
                frame.setPixel(x, y, qRgb(row[x * components], row[x * components + 1], row[x * components + 2]));
            }
        }
        frame.setDevicePixelRatio(ratio);
        QPainter painter(&pixmap);
        painter.drawImage(QRectF(QPointF(area->mapTo(&window, QPoint(0, 0))), QSizeF(area->size())), frame);
    }
    root->unref();
    return pixmap.toImage();
}

} // namespace cadnext::gui::detail
