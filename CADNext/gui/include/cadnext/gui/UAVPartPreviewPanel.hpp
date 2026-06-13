#pragma once

#include <QDialog>

#include "cadnext/bridge/UAVPartFormat.hpp"

class SoQtExaminerViewer;

namespace cadnext::gui {

// Панель просмотра открытой детали .uavpart.
// Показывает имя, материал, массу (кг), габариты (мм), центр масс,
// точки крепления, статус готовности к тестированию на БЛА и 3D-превью.
// Позволяет добавить файл в локальную библиотеку деталей или открыть
// для редактирования (если в файле есть ExactGeometry).
class UAVPartPreviewPanel : public QDialog {
    Q_OBJECT

public:
    enum class Action {
        None,
        OpenForEditing
    };

    explicit UAVPartPreviewPanel(const bridge::UAVPartReadResult& result,
                                  const QString& filePath,
                                  QWidget* parent = nullptr);
    ~UAVPartPreviewPanel() override;

    Action requestedAction() const { return requestedAction_; }

private:
    Action requestedAction_ = Action::None;
    SoQtExaminerViewer* previewViewer_ = nullptr;
};

} // namespace cadnext::gui
