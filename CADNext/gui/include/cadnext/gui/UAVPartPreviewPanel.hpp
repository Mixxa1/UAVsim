#pragma once

#include <QDialog>

#include "cadnext/bridge/UAVPartFormat.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

class SoQtExaminerViewer;

namespace cadnext::gui {

// Панель просмотра открытой детали .uavpart.
// Показывает 3D-превью тела (VisualMesh → ExactGeometry → BoundsBox → PNG),
// metadata, статус готовности и warnings. Позволяет добавить файл в
// библиотеку деталей или открыть для редактирования.
class UAVPartPreviewPanel : public QDialog {
    Q_OBJECT

public:
    enum class Action { None, OpenForEditing };

    // Priority-ordered preview modes (highest = best):
    //   MeshPreview      — real 3D mesh from VisualMesh section
    //   GeometryPreview  — triangulation built from ExactGeometry (BRep)
    //   BoundsPreview    — 3D box placeholder by bounding dimensions
    //   FileIconFallback — PNG file type icon (last resort)
    //   Unavailable      — nothing could be shown
    enum class PreviewState {
        MeshPreview,
        GeometryPreview,
        BoundsPreview,
        FileIconFallback,
        Unavailable
    };

    // prebuiltMesh: optional triangulation built from ExactGeometry by
    // MainWindow (which holds the kernel). Null when not available.
    explicit UAVPartPreviewPanel(const bridge::UAVPartReadResult& result,
                                  const QString& filePath,
                                  const kernel::TriangleMesh* prebuiltMesh = nullptr,
                                  QWidget* parent = nullptr);
    ~UAVPartPreviewPanel() override;

    Action requestedAction() const { return requestedAction_; }

private:
    Action requestedAction_ = Action::None;
    SoQtExaminerViewer* previewViewer_ = nullptr;
};

} // namespace cadnext::gui
