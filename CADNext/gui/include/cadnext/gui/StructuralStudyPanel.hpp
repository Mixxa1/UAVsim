#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/StructuralJob.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"

#include <QProcess>
#include <QWidget>

#include <array>
#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

class QComboBox;
class QDoubleSpinBox;
class QLabel;
class QLineEdit;
class QListWidget;
class QPushButton;
class QSpinBox;

namespace cadnext::gui {

// What the panel needs from the document, and nothing else — it never reaches into MainWindow.
struct StructuralPartContext {
    // Body and face currently selected in the viewport, if the selection is a face.
    std::function<std::optional<std::pair<std::string, std::string>>()> selectedFace;
    std::function<std::vector<kernel::FaceReference>(const std::string& bodyId)> bodyFaces;
    std::function<QString(const std::string& bodyId)> bodyName;
    std::function<std::optional<std::string>(const std::string& bodyId)> bodyMaterialId;
    std::function<Result<std::vector<std::uint8_t>>(const std::string& bodyId)> exportBody;
    // Selects a face in the viewport (clicking a load in the list shows where it acts).
    std::function<void(const std::string& bodyId, const std::string& faceId)> selectFace;
};

// Where cadnext_structural is: $CADNEXT_STRUCTURAL_TOOL, next to the application, or in the build
// tree (fea/occt). Empty when the solver was not built (it needs CADNEXT_WITH_NETGEN=ON).
QString structuralToolPath();

// «Прочность и частоты детали»: supports and loads placed on faces picked in the viewport, the
// material, the mesh study settings, and a run of cadnext_structural in its own process with
// progress and cancel. Two analyses share the supports and the mesh:
//   static — loads and accelerations, strength verdict;
//   modal  — natural modes against rotor and explicit excitation bands; loads in the list stay
//            there for the static case but are marked unused and are not written to the job.
// The result opens in the window its schema calls for (AnalysisResultWindow).
class StructuralStudyPanel : public QWidget {
    Q_OBJECT

public:
    enum class ItemKind { Support, Force, Pressure, Exclusion };

    // One entry of the load case, bound to a face by its full kernel face id.
    struct Item {
        ItemKind kind = ItemKind::Support;
        std::string faceId;
        std::array<bool, 3> fixed{true, true, true};
        fea::Vec3 forceN;
        double pressurePa = 0.0;
        double distanceM = 0.0;
    };

    explicit StructuralStudyPanel(StructuralPartContext context, QWidget* parent = nullptr);
    ~StructuralStudyPanel() override;

    // Called by the owner when the viewport selection changes.
    void selectionChanged();

    // Programmatic editing — the buttons call these, and so does the integration test.
    QString addItemOnSelectedFace(const Item& item); // empty on success, else why not
    void setMaterialId(const std::string& materialId);
    void setMeshSettings(double coarseElementSizeM, double refinementFactor);
    void setLoadCaseName(const QString& name);
    void setBodyAccelerationG(const fea::Vec3& g);
    void setAnalysis(fea::StructuralAnalysis analysis);
    fea::StructuralAnalysis analysis() const;
    void setModeCount(int modes);
    void addRotor(const fea::RotorExcitation& rotor);
    void addBand(const fea::ExcitationBand& band);
    void setSeparationMargin(double fraction);

    // The job the current panel describes, with relative file names; empty result and a reason
    // when it is not runnable yet (no body, no support, no element size…).
    Result<fea::StructuralJob> buildJob() const;

    // Starts the study. Emits finished() with the result file path (empty when it failed).
    QString run();
    bool isRunning() const;
    void cancel();

    const std::vector<Item>& items() const { return items_; }
    const std::string& bodyId() const { return bodyId_; }
    QString lastResultPath() const { return lastResultPath_; }

signals:
    void finished(const QString& resultPath, const QString& message);

private:
    void buildInterface();
    void refreshItems();
    void refreshState();
    void addSupport();
    void addForce();
    void addPressure();
    void addExclusion();
    void addRotorDialog();
    void addBandDialog();
    void refreshExcitation();
    void applyAnalysis();
    void removeSelected();
    void suggestElementSize();
    void onProcessOutput();
    void onProcessFinished(int exitCode, QProcess::ExitStatus status);
    QString describe(const Item& item) const;
    // Faces of the panel's body, reloaded from the document whenever they are needed: the part
    // may have been edited since the loads were placed.
    void reloadFaces() const;
    const kernel::FaceReference* face(const std::string& faceId) const;

    StructuralPartContext context_;
    std::string bodyId_;
    std::vector<Item> items_;
    std::vector<fea::RotorExcitation> rotors_;
    std::vector<fea::ExcitationBand> bands_;
    mutable std::vector<kernel::FaceReference> faces_;
    QProcess* process_ = nullptr;
    QString workDirectory_;
    QString lastResultPath_;

    QComboBox* analysis_ = nullptr;
    QLabel* caseLabel_ = nullptr;
    QWidget* loadButtons_ = nullptr;
    QWidget* accelerationRow_ = nullptr;
    QWidget* modalGroup_ = nullptr;
    QSpinBox* modeCount_ = nullptr;
    QListWidget* excitationList_ = nullptr;
    QDoubleSpinBox* margin_ = nullptr;
    QLabel* partLabel_ = nullptr;
    QLabel* selectionLabel_ = nullptr;
    QLineEdit* loadCaseName_ = nullptr;
    QComboBox* material_ = nullptr;
    QListWidget* itemList_ = nullptr;
    QDoubleSpinBox* accelerationX_ = nullptr;
    QDoubleSpinBox* accelerationY_ = nullptr;
    QDoubleSpinBox* accelerationZ_ = nullptr;
    QDoubleSpinBox* elementSize_ = nullptr;
    QDoubleSpinBox* refinement_ = nullptr;
    QPushButton* runButton_ = nullptr;
    QPushButton* cancelButton_ = nullptr;
    QLabel* status_ = nullptr;
};

} // namespace cadnext::gui
