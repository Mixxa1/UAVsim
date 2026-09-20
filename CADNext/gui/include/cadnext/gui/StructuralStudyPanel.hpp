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

class QCheckBox;
class QComboBox;
class QDoubleSpinBox;
class QLabel;
class QLineEdit;
class QListWidget;
class QPushButton;
class QSpinBox;
class QFormLayout;
class QTableWidget;
class QVBoxLayout;

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

// Where cadnext_structural is: $CADNEXT_STRUCTURAL_TOOL, next to the application, or in one of the
// repository's Netgen build trees. Empty when the solver was not built.
QString structuralToolPath();

// «Прочность и частоты детали»: supports and loads placed on faces picked in the viewport, the
// material, the mesh study settings, and a run of cadnext_structural in its own process with
// progress and cancel. Three analyses share the supports and the mesh:
//   static    — loads and accelerations, strength verdict;
//   modal     — natural modes against rotor and explicit excitation bands; loads in the list stay
//               there for the static case but are marked unused and are not written to the job;
//   harmonic  — sine vibration on the fixture (the supports): a shaker, a force or a rotor
//               imbalance on a face, swept over a frequency range; exclusion zones are used, loads
//               are not;
//   climate   — MIL-STD-810H heat, sun and cold: the part in the standard's air with its own
//               equipment on faces; supports are optional (without them the part expands freely);
//   fire      — ISO 2685 / AC 20-135 flame on chosen faces for 5 or 15 minutes: integrity, strength
//               when hot under the load case's loads, the equipment's function;
//   lightning — SAE ARP5412 components on an attachment face, the current leaving through the faces
//               bonded to the structure: burn-through and what the equipment behind it sees;
//   emc       — MIL-STD-461G RS103: the standard's field arrives as a plane wave and the question is
//               how much of it reaches points inside the enclosure;
//   icing     — a cloud of supercooled droplets: where they land, how thick the ice gets, and what
//               it would take to keep the surface clear;
//   flutter   — the part's own bending and torsion modes against unsteady air: at what speed the
//               air stops damping them, against the margin the regulation asks for;
//   bird      — 14 CFR 25.571(e): a bird of a given mass at a given speed into a chosen face, its
//               pressure history through the part's own modes, and what stress it raises.
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
    // Sine vibration. Excitation kinds: base acceleration (amplitude in g), a force on a face (N),
    // a rotor imbalance on a face (g·mm). The face is the one selected when it is set.
    enum class VibrationKind { Base, Force, Imbalance };
    void setVibration(VibrationKind kind, int axis, double amplitude, double dampingRatio, int modes, double fromHz, double toHz);
    QString setVibrationFaceFromSelection(); // empty on success
    QString setProbeFaceFromSelection();
    // Random vibration: base acceleration PSD as (Hz, g²/Hz) points, ζ, mode count, direction axis.
    void setRandomVibration(int axis, const std::vector<std::pair<double, double>>& psdG2PerHz, double dampingRatio, int modes);
    // Shock: pulse shape (0 half-sine, 1 terminal-peak sawtooth, 2 trapezoid), peak in g, times in ms.
    void setShock(int shape, int axis, double peakG, double durationMs, double riseMs, double fallMs, double dampingRatio, int modes);
    // Climate. `condition` is the row of the condition list (0–5 hot: A1 sun, shade, storage, A2 sun,
    // shade, storage; 6–11 cold: C1, C1 storage, C2, C2 storage, C3, C3 storage); `up` 0–5 = +X −X +Y −Y
    // +Z −Z, `flow` 0–2 = X Y Z. Temperatures in °C as the panel shows them; NaN leaves a limit unset.
    void setClimate(int condition, bool flight, double airSpeedMps, double altitudeM, int up, int flow, double absorptance, double emissivity,
                    double assemblyC, double stepS, bool operating);
    QString addClimateComponentOnSelectedFace(const QString& name, double powerW, double minimumC, double maximumC); // empty on success
    void setClimateMaterialLimits(double minimumC, double maximumC);
    // Fire: standard 0 ISO 2685, 1 AC 20-135; surface 0 clean (ε 0.3), 1 painted (0.7), 2 its own ε.
    void setFire(int standard, double durationS, int surface, double emissivity, double stepS, bool operating);
    QString addFlameFaceFromSelection(); // empty on success
    // Lightning: the components to apply in order, polarity 0 anode / 1 cathode, the continuing
    // current of component C (200–800 A), surface as for fire, steps per component.
    void setLightning(const std::vector<fea::LightningComponent>& components, int polarity, double continuingCurrentA, int surface, double emissivity,
                      int stepsPerComponent);
    QString addAttachmentFaceFromSelection(); // the arc root; empty on success
    QString addGroundFaceFromSelection();     // bonded to the structure
    // EMC: incidence 0–5 = +X −X +Y −Y +Z −Z, polarization 0–2 = X Y Z, level is the row of the
    // level list (the last row is "a field of my own"), the sweep in megahertz.
    void setEmc(int incidence, int polarization, int level, double fieldVm, double lowMHz, double highMHz, int points);
    // A point `offsetMm` along the selected face's normal, which for the inner face of an enclosure
    // is into its cavity. Empty on success.
    QString addEmcEquipmentOnSelectedFace(const QString& name, double offsetMm, double immunityVm);
    // Flutter: axes 0–2 = X Y Z; the dive speed and the sweep in metres a second.
    void setFlutter(int flowAxis, int spanAxis, int stations, double airDensityKgM3, double structuralDamping, double diveSpeedMps, double lowSpeedMps,
                    double highSpeedMps);
    // Bird strike: direction 0–5 = +X −X +Y −Y +Z −Z (where the bird pushes), the mass in kilograms
    // (1.81 = the 4 lb of 25.571(e)), the speed in metres a second, the angle of the meeting in
    // degrees (90 = head-on). The struck face is the one selected when it is set.
    void setBird(int direction, double massKg, double speedMps, double obliquityDeg, double dampingRatio, int modes);
    QString setBirdFaceFromSelection(); // empty on success
    // Icing: flow and span axes 0–2 = X Y Z, the condition 0 = the regulation's takeoff maximum,
    // 1 = the numbers below it; temperatures in °C, water in g/m³, droplets in µm, time in minutes.
    void setIcing(int flowAxis, int spanAxis, double angleOfAttackDeg, int condition, double temperatureC, double lwcGm3, double dropletMicrons,
                  double airspeedMps, double durationMin, double antiIceTargetC, double antiIceBudgetW, double maximumIceMm);

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
    void buildClimateGroup(QVBoxLayout* layout);
    void buildFireGroup(QVBoxLayout* layout);
    void buildLightningGroup(QVBoxLayout* layout);
    void buildEmcGroup(QVBoxLayout* layout);
    void buildIcingGroup(QVBoxLayout* layout);
    void buildFlutterGroup(QVBoxLayout* layout);
    void buildBirdGroup(QVBoxLayout* layout);
    Result<fea::StructuralJob> buildClimateJob() const;
    Result<fea::StructuralJob> buildFireJob() const;
    Result<fea::StructuralJob> buildLightningJob() const;
    Result<fea::StructuralJob> buildEmcJob() const;
    Result<fea::StructuralJob> buildIcingJob() const;
    Result<fea::StructuralJob> buildBirdJob() const;
    Result<fea::StructuralJob> buildFlutterJob() const;
    Result<std::vector<fea::EmcProbe>> emcEquipment() const;
    QString addLightningFace(QListWidget* list, std::vector<std::string>& ids, bool attachment);
    // The equipment table (climate, fire and lightning): its components, or why they are not usable.
    Result<std::vector<fea::ClimateComponent>> equipment() const;
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
    QWidget* vibrationGroup_ = nullptr;
    QFormLayout* vibrationForm_ = nullptr;
    QTableWidget* psdTable_ = nullptr;
    QWidget* psdBox_ = nullptr;
    QLabel* psdSummary_ = nullptr;
    QWidget* pulseBox_ = nullptr;
    QComboBox* pulseShape_ = nullptr;
    QDoubleSpinBox *pulsePeak_ = nullptr, *pulseDuration_ = nullptr, *pulseRise_ = nullptr, *pulseFall_ = nullptr;
    QFormLayout* pulseForm_ = nullptr;
    QWidget* forceButton_ = nullptr;
    QWidget* pressureButton_ = nullptr;
    QSpinBox* vibrationModes_ = nullptr;
    QDoubleSpinBox* damping_ = nullptr;
    QComboBox* vibrationKind_ = nullptr;
    QComboBox* vibrationAxis_ = nullptr;
    QDoubleSpinBox* vibrationAmplitude_ = nullptr;
    QDoubleSpinBox* fromHz_ = nullptr;
    QDoubleSpinBox* toHz_ = nullptr;
    QLabel* vibrationFaceLabel_ = nullptr;
    QLabel* probeFaceLabel_ = nullptr;
    std::string vibrationFace_, probeFace_;
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
    QWidget* climateGroup_ = nullptr;
    QFormLayout* climateForm_ = nullptr;
    QComboBox* climateCondition_ = nullptr;
    QComboBox* climateAirflow_ = nullptr;
    QDoubleSpinBox *climateSpeed_ = nullptr, *climateAltitude_ = nullptr, *climateAbsorptance_ = nullptr, *climateEmissivity_ = nullptr;
    QDoubleSpinBox *climateAssembly_ = nullptr, *climateStep_ = nullptr, *climateMaterialMin_ = nullptr, *climateMaterialMax_ = nullptr;
    QComboBox *climateUp_ = nullptr, *climateFlow_ = nullptr;
    QCheckBox* climateOperating_ = nullptr;
    QTableWidget* componentTable_ = nullptr;
    QWidget* equipmentBox_ = nullptr;
    QWidget* fireGroup_ = nullptr;
    QFormLayout* fireForm_ = nullptr;
    QComboBox *fireStandard_ = nullptr, *fireClass_ = nullptr, *fireSurface_ = nullptr;
    QDoubleSpinBox *fireDuration_ = nullptr, *fireEmissivity_ = nullptr, *fireStep_ = nullptr;
    QListWidget* fireFaces_ = nullptr;
    std::vector<std::string> fireFaceIds_;

    QWidget* lightningGroup_ = nullptr;
    QFormLayout* lightningForm_ = nullptr;
    std::array<QCheckBox*, 4> lightningComponents_{}; // A, B, C, D
    QComboBox *lightningPolarity_ = nullptr, *lightningSurface_ = nullptr;
    QDoubleSpinBox *lightningCurrent_ = nullptr, *lightningEmissivity_ = nullptr;
    QSpinBox* lightningSteps_ = nullptr;
    QListWidget *lightningAttachment_ = nullptr, *lightningGround_ = nullptr;
    std::vector<std::string> lightningAttachmentIds_, lightningGroundIds_;

    QWidget* emcGroup_ = nullptr;
    QFormLayout* emcForm_ = nullptr;
    QComboBox *emcIncidence_ = nullptr, *emcPolarization_ = nullptr, *emcLevel_ = nullptr;
    QDoubleSpinBox *emcField_ = nullptr, *emcLow_ = nullptr, *emcHigh_ = nullptr;
    QSpinBox* emcPoints_ = nullptr;
    QTableWidget* emcTable_ = nullptr;

    QWidget* icingGroup_ = nullptr;
    QFormLayout* icingForm_ = nullptr;
    QComboBox *icingFlowAxis_ = nullptr, *icingSpanAxis_ = nullptr, *icingCondition_ = nullptr;
    QDoubleSpinBox *icingAngle_ = nullptr, *icingTemperature_ = nullptr, *icingWater_ = nullptr, *icingDroplet_ = nullptr;
    QDoubleSpinBox *icingSpeed_ = nullptr, *icingDuration_ = nullptr, *icingTarget_ = nullptr, *icingBudget_ = nullptr, *icingLimit_ = nullptr;
    QSpinBox *icingStations_ = nullptr, *icingPanels_ = nullptr, *icingTrajectories_ = nullptr;

    QWidget* flutterGroup_ = nullptr;
    QFormLayout* flutterForm_ = nullptr;
    QComboBox *flutterFlowAxis_ = nullptr, *flutterSpanAxis_ = nullptr;
    QSpinBox* flutterStations_ = nullptr;
    QDoubleSpinBox *flutterDensity_ = nullptr, *flutterDamping_ = nullptr, *flutterDive_ = nullptr, *flutterLow_ = nullptr, *flutterHigh_ = nullptr;
    QWidget* birdGroup_ = nullptr;
    QFormLayout* birdForm_ = nullptr;
    QComboBox* birdDirection_ = nullptr;
    QDoubleSpinBox *birdMass_ = nullptr, *birdSpeed_ = nullptr, *birdObliquity_ = nullptr, *birdDamping_ = nullptr;
    QSpinBox* birdModes_ = nullptr;
    QPushButton* birdFaceButton_ = nullptr;
    QLabel* birdFaceLabel_ = nullptr;
    std::string birdFaceId_;

    QPushButton* runButton_ = nullptr;
    QPushButton* cancelButton_ = nullptr;
    QLabel* status_ = nullptr;
};

} // namespace cadnext::gui
