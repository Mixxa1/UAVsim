#include "cadnext/gui/StructuralStudyPanel.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/Material.hpp"

#include <QComboBox>
#include <QCoreApplication>
#include <QDateTime>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QDoubleSpinBox>
#include <QFile>
#include <QFileInfo>
#include <QFormLayout>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QInputDialog>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMenu>
#include <QPushButton>
#include <QSpinBox>
#include <QStandardPaths>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>
#include <limits>

namespace cadnext::gui {

namespace {

constexpr double kStandardGravity = 9.80665;

// "face-12-9a1c…-…" → "face-12": the solver groups boundary triangles by the kernel's face index.
std::string faceIndexId(const std::string& faceId) {
    const auto second = faceId.find('-', 5);
    return second == std::string::npos ? faceId : faceId.substr(0, second);
}

QString kindName(kernel::FaceKind kind) {
    switch (kind) {
    case kernel::FaceKind::Planar: return QObject::tr("плоская");
    case kernel::FaceKind::Cylindrical: return QObject::tr("цилиндрическая");
    case kernel::FaceKind::Conical: return QObject::tr("коническая");
    case kernel::FaceKind::Spherical: return QObject::tr("сферическая");
    case kernel::FaceKind::Other: return QObject::tr("криволинейная");
    }
    return {};
}

} // namespace

QString structuralToolPath() {
    const QByteArray fromEnvironment = qgetenv("CADNEXT_STRUCTURAL_TOOL");
    if (!fromEnvironment.isEmpty() && QFileInfo(QString::fromLocal8Bit(fromEnvironment)).isExecutable()) {
        // Absolute: the process is started from the run's own folder, where a relative path means nothing.
        return QFileInfo(QString::fromLocal8Bit(fromEnvironment)).absoluteFilePath();
    }
    const QDir applicationDirectory(QCoreApplication::applicationDirPath());
    for (const QString& candidate : {applicationDirectory.filePath(QStringLiteral("cadnext_structural")),
                                     applicationDirectory.filePath(QStringLiteral("../fea/occt/cadnext_structural"))}) {
        if (QFileInfo(candidate).isExecutable()) return QFileInfo(candidate).canonicalFilePath();
    }
    return {};
}

StructuralStudyPanel::StructuralStudyPanel(StructuralPartContext context, QWidget* parent)
    : QWidget(parent), context_(std::move(context)) {
    buildInterface();
    selectionChanged();
}

StructuralStudyPanel::~StructuralStudyPanel() {
    if (process_ != nullptr && process_->state() != QProcess::NotRunning) {
        process_->kill();
        process_->waitForFinished(2000);
    }
}

void StructuralStudyPanel::buildInterface() {
    auto* layout = new QVBoxLayout(this);
    partLabel_ = new QLabel;
    partLabel_->setWordWrap(true);
    QFont bold = partLabel_->font();
    bold.setBold(true);
    partLabel_->setFont(bold);
    selectionLabel_ = new QLabel;
    selectionLabel_->setWordWrap(true);
    layout->addWidget(partLabel_);
    layout->addWidget(selectionLabel_);

    auto* form = new QFormLayout;
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow); // macOS style keeps fields narrow otherwise
    analysis_ = new QComboBox;
    analysis_->addItem(tr("Прочность (статика)"));
    analysis_->addItem(tr("Собственные частоты и резонанс"));
    form->addRow(tr("Расчёт"), analysis_);
    loadCaseName_ = new QLineEdit;
    loadCaseName_->setPlaceholderText(tr("например, «+3.5 g, выход из пикирования»"));
    caseLabel_ = new QLabel(tr("Нагрузочный случай"));
    form->addRow(caseLabel_, loadCaseName_);
    material_ = new QComboBox;
    // No preselected material: a strength verdict computed for a material nobody chose is the
    // quietest wrong answer this panel could give.
    material_->addItem(tr("— выберите материал —"), QString());
    for (const auto& material : fea::materialLibrary()) {
        material_->addItem(QString::fromStdString(material.displayName), QString::fromStdString(material.id));
    }
    form->addRow(tr("Материал"), material_);
    layout->addLayout(form);

    auto* buttons = new QGridLayout;
    buttons->setContentsMargins(0, 0, 0, 0);
    auto* support = new QPushButton(tr("Опора…"));
    auto* supportMenu = new QMenu(support);
    supportMenu->addAction(tr("Жёсткая заделка (X, Y, Z)"), this, [this]() {
        addItemOnSelectedFace({ItemKind::Support, {}, {true, true, true}});
    });
    for (int axis = 0; axis < 3; ++axis) {
        static const char* names[] = {"X", "Y", "Z"};
        supportMenu->addAction(tr("Только по %1 (опора симметрии / скольжения)").arg(names[axis]), this, [this, axis]() {
            Item item;
            item.fixed = {axis == 0, axis == 1, axis == 2};
            addItemOnSelectedFace(item);
        });
    }
    support->setMenu(supportMenu);
    auto* force = new QPushButton(tr("Сила…"));
    auto* pressure = new QPushButton(tr("Давление…"));
    auto* exclusion = new QPushButton(tr("Зона исключения…"));
    auto* remove = new QPushButton(tr("Удалить"));
    auto* supportRow = new QHBoxLayout;
    supportRow->addWidget(support);
    layout->addLayout(supportRow);
    loadButtons_ = new QWidget;
    loadButtons_->setLayout(buttons);
    buttons->addWidget(force, 0, 0);
    buttons->addWidget(pressure, 0, 1);
    buttons->addWidget(exclusion, 1, 0, 1, 2);
    layout->addWidget(loadButtons_);
    connect(force, &QPushButton::clicked, this, [this]() { addForce(); });
    connect(pressure, &QPushButton::clicked, this, [this]() { addPressure(); });
    connect(exclusion, &QPushButton::clicked, this, [this]() { addExclusion(); });

    itemList_ = new QListWidget;
    itemList_->setMinimumHeight(120);
    itemList_->setWordWrap(true);
    layout->addWidget(itemList_);
    layout->addWidget(remove);
    connect(remove, &QPushButton::clicked, this, [this]() { removeSelected(); });
    connect(itemList_, &QListWidget::currentRowChanged, this, [this](int row) {
        if (row >= 0 && row < static_cast<int>(items_.size()) && context_.selectFace) {
            context_.selectFace(bodyId_, items_[row].faceId);
        }
    });

    auto* acceleration = new QHBoxLayout;
    for (QDoubleSpinBox** box : {&accelerationX_, &accelerationY_, &accelerationZ_}) {
        *box = new QDoubleSpinBox;
        (*box)->setRange(-100.0, 100.0);
        (*box)->setDecimals(2);
        (*box)->setSingleStep(0.5);
        acceleration->addWidget(*box);
    }
    accelerationRow_ = new QWidget;
    auto* accelerationOnly = new QFormLayout(accelerationRow_);
    accelerationOnly->setContentsMargins(0, 0, 0, 0);
    accelerationOnly->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    accelerationOnly->addRow(tr("Перегрузка X, Y, Z, g"), acceleration);
    layout->addWidget(accelerationRow_);

    // Modal analysis: how many modes, and what excites them.
    modalGroup_ = new QWidget;
    auto* modalLayout = new QVBoxLayout(modalGroup_);
    modalLayout->setContentsMargins(0, 0, 0, 0);
    auto* modalForm = new QFormLayout;
    modalForm->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    modeCount_ = new QSpinBox;
    modeCount_->setRange(0, 60);
    modeCount_->setSpecialValueText(tr("не задано"));
    modeCount_->setToolTip(tr("Сколько упругих мод считать. Без умолчания: если полоса возбуждения выше последней рассчитанной моды, "
                              "результат скажет об этом (WARNING) — моды выше не проверены."));
    modalForm->addRow(tr("Число мод"), modeCount_);
    margin_ = new QDoubleSpinBox;
    margin_->setRange(0.0, 50.0);
    margin_->setDecimals(1);
    margin_->setSuffix(tr(" %"));
    margin_->setToolTip(tr("Расширяет каждую полосу на ± эту долю. По умолчанию 0: единого нормативного запаса для БПЛА нет, "
                           "фактическая отстройка каждой моды показывается всегда."));
    modalForm->addRow(tr("Запас по частоте"), margin_);
    modalLayout->addLayout(modalForm);
    auto* excitationButtons = new QHBoxLayout;
    auto* rotor = new QPushButton(tr("Винт…"));
    rotor->setToolTip(tr("Диапазон оборотов и число лопастей → полосы 1P (дисбаланс) и NP (проход лопастей)"));
    auto* band = new QPushButton(tr("Полоса…"));
    band->setToolTip(tr("Явная полоса: 2P, порядки двигателя, частоты ШИМ/электрические и т. п."));
    auto* removeExcitation = new QPushButton(tr("Удалить"));
    excitationButtons->addWidget(rotor);
    excitationButtons->addWidget(band);
    excitationButtons->addWidget(removeExcitation);
    modalLayout->addWidget(new QLabel(tr("Возбуждение")));
    modalLayout->addLayout(excitationButtons);
    excitationList_ = new QListWidget;
    excitationList_->setMinimumHeight(70);
    excitationList_->setWordWrap(true);
    modalLayout->addWidget(excitationList_);
    layout->addWidget(modalGroup_);
    connect(rotor, &QPushButton::clicked, this, [this]() { addRotorDialog(); });
    connect(band, &QPushButton::clicked, this, [this]() { addBandDialog(); });
    connect(removeExcitation, &QPushButton::clicked, this, [this]() {
        int row = excitationList_->currentRow();
        if (row < 0) return;
        if (row < static_cast<int>(rotors_.size())) {
            rotors_.erase(rotors_.begin() + row);
        } else if (row - static_cast<int>(rotors_.size()) < static_cast<int>(bands_.size())) {
            bands_.erase(bands_.begin() + (row - static_cast<int>(rotors_.size())));
        }
        refreshExcitation();
    });
    connect(modeCount_, qOverload<int>(&QSpinBox::valueChanged), this, [this]() { refreshState(); });
    connect(analysis_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() { applyAnalysis(); });

    auto* accelerationForm = new QFormLayout;
    accelerationForm->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

    auto* sizeRow = new QHBoxLayout;
    elementSize_ = new QDoubleSpinBox;
    elementSize_->setRange(0.0, 10000.0);
    elementSize_->setDecimals(2);
    elementSize_->setSuffix(tr(" мм"));
    elementSize_->setSpecialValueText(tr("не задан"));
    auto* suggest = new QPushButton(tr("Предложить"));
    suggest->setToolTip(tr("1/10 габарита детали — только отправная точка: достаточна ли сетка, покажет сходимость по трём уровням"));
    sizeRow->addWidget(elementSize_, 1);
    sizeRow->addWidget(suggest);
    accelerationForm->addRow(tr("Грубая сетка, h"), sizeRow);
    refinement_ = new QDoubleSpinBox;
    refinement_->setRange(1.3, 3.0);
    refinement_->setDecimals(2);
    refinement_->setSingleStep(0.1);
    refinement_->setValue(1.6);
    refinement_->setToolTip(tr("Уменьшение h между тремя уровнями. Не меньше 1.3 (Celik et al., 2008): иначе разница сеток тонет в шуме. 1.6 даёт примерно вчетверо больше элементов на уровень."));
    accelerationForm->addRow(tr("Измельчение"), refinement_);
    layout->addLayout(accelerationForm);
    connect(suggest, &QPushButton::clicked, this, [this]() { suggestElementSize(); });

    auto* runRow = new QHBoxLayout;
    runButton_ = new QPushButton(tr("Рассчитать"));
    cancelButton_ = new QPushButton(tr("Отменить"));
    cancelButton_->setEnabled(false);
    runRow->addWidget(runButton_, 1);
    runRow->addWidget(cancelButton_);
    layout->addLayout(runRow);
    status_ = new QLabel;
    status_->setWordWrap(true);
    layout->addWidget(status_);
    layout->addStretch(1);
    connect(material_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() { refreshState(); });
    connect(runButton_, &QPushButton::clicked, this, [this]() {
        const QString problem = run();
        if (!problem.isEmpty()) status_->setText(problem);
    });
    connect(cancelButton_, &QPushButton::clicked, this, [this]() { cancel(); });
    for (QDoubleSpinBox* box : {elementSize_, refinement_}) {
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() { refreshState(); });
    }
    applyAnalysis();
}

void StructuralStudyPanel::applyAnalysis() {
    const bool modal = analysis() == fea::StructuralAnalysis::Modal;
    loadButtons_->setVisible(!modal);
    accelerationRow_->setVisible(!modal);
    modalGroup_->setVisible(modal);
    caseLabel_->setText(modal ? tr("Вариант") : tr("Нагрузочный случай"));
    loadCaseName_->setPlaceholderText(modal ? tr("например, «лучи закреплены в центральной плите»")
                                            : tr("например, «+3.5 g, выход из пикирования»"));
    refreshItems();
    selectionChanged();
}

fea::StructuralAnalysis StructuralStudyPanel::analysis() const {
    return analysis_->currentIndex() == 1 ? fea::StructuralAnalysis::Modal : fea::StructuralAnalysis::Static;
}

void StructuralStudyPanel::setAnalysis(fea::StructuralAnalysis analysis) {
    analysis_->setCurrentIndex(analysis == fea::StructuralAnalysis::Modal ? 1 : 0);
}

void StructuralStudyPanel::setModeCount(int modes) {
    modeCount_->setValue(modes);
}

void StructuralStudyPanel::addRotor(const fea::RotorExcitation& rotor) {
    rotors_.push_back(rotor);
    refreshExcitation();
}

void StructuralStudyPanel::addBand(const fea::ExcitationBand& band) {
    bands_.push_back(band);
    refreshExcitation();
}

void StructuralStudyPanel::setSeparationMargin(double fraction) {
    margin_->setValue(fraction * 100.0);
}

void StructuralStudyPanel::refreshExcitation() {
    excitationList_->clear();
    for (const auto& rotor : rotors_) {
        excitationList_->addItem(tr("%1: %2–%3 об/мин, %4 лоп. → 1P %5–%6 Гц, %4P %7–%8 Гц")
                                     .arg(QString::fromStdString(rotor.name))
                                     .arg(rotor.minimumRpm, 0, 'f', 0).arg(rotor.maximumRpm, 0, 'f', 0).arg(rotor.bladeCount)
                                     .arg(rotor.minimumRpm / 60, 0, 'f', 1).arg(rotor.maximumRpm / 60, 0, 'f', 1)
                                     .arg(rotor.minimumRpm * rotor.bladeCount / 60, 0, 'f', 1)
                                     .arg(rotor.maximumRpm * rotor.bladeCount / 60, 0, 'f', 1));
    }
    for (const auto& band : bands_) {
        excitationList_->addItem(tr("%1: %2–%3 Гц").arg(QString::fromStdString(band.name)).arg(band.minimumHz, 0, 'f', 1).arg(band.maximumHz, 0, 'f', 1));
    }
    refreshState();
}

void StructuralStudyPanel::addRotorDialog() {
    QDialog dialog(this);
    dialog.setWindowTitle(tr("Винт"));
    auto* form = new QFormLayout(&dialog);
    auto* name = new QLineEdit(tr("винт"));
    auto* minimum = new QDoubleSpinBox;
    auto* maximum = new QDoubleSpinBox;
    for (QDoubleSpinBox* box : {minimum, maximum}) {
        box->setRange(0.0, 200000.0);
        box->setDecimals(0);
        box->setSuffix(tr(" об/мин"));
    }
    auto* blades = new QSpinBox;
    blades->setRange(1, 12);
    blades->setValue(2);
    auto* note = new QLabel(tr("Диапазон оборотов от малого газа до максимума — из стенда силовой установки."));
    note->setWordWrap(true);
    form->addRow(note);
    form->addRow(tr("Название"), name);
    form->addRow(tr("Обороты от"), minimum);
    form->addRow(tr("до"), maximum);
    form->addRow(tr("Лопастей"), blades);
    auto* box = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    form->addRow(box);
    connect(box, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    connect(box, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    if (dialog.exec() != QDialog::Accepted) return;
    if (!(minimum->value() > 0.0) || maximum->value() < minimum->value() || name->text().trimmed().isEmpty()) {
        status_->setText(tr("Винт не добавлен: нужно название и 0 < обороты от ≤ до."));
        return;
    }
    addRotor({name->text().trimmed().toStdString(), minimum->value(), maximum->value(), blades->value()});
}

void StructuralStudyPanel::addBandDialog() {
    QDialog dialog(this);
    dialog.setWindowTitle(tr("Полоса возбуждения"));
    auto* form = new QFormLayout(&dialog);
    auto* name = new QLineEdit;
    auto* minimum = new QDoubleSpinBox;
    auto* maximum = new QDoubleSpinBox;
    for (QDoubleSpinBox* box : {minimum, maximum}) {
        box->setRange(0.0, 1e6);
        box->setDecimals(1);
        box->setSuffix(tr(" Гц"));
    }
    form->addRow(tr("Название"), name);
    form->addRow(tr("От"), minimum);
    form->addRow(tr("До"), maximum);
    auto* box = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    form->addRow(box);
    connect(box, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    connect(box, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    if (dialog.exec() != QDialog::Accepted) return;
    if (maximum->value() < minimum->value() || name->text().trimmed().isEmpty()) {
        status_->setText(tr("Полоса не добавлена: нужно название и от ≤ до."));
        return;
    }
    addBand({name->text().trimmed().toStdString(), minimum->value(), maximum->value()});
}

void StructuralStudyPanel::reloadFaces() const {
    faces_ = (!bodyId_.empty() && context_.bodyFaces) ? context_.bodyFaces(bodyId_) : std::vector<kernel::FaceReference>{};
}

const kernel::FaceReference* StructuralStudyPanel::face(const std::string& faceId) const {
    for (const auto& reference : faces_) {
        if (reference.faceId == faceId) return &reference;
    }
    return nullptr;
}

void StructuralStudyPanel::selectionChanged() {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) {
        selectionLabel_->setText(bodyId_.empty() ? tr("Выберите грань детали в окне модели, затем назначьте ей опору или нагрузку.")
                                                 : tr("Выберите грань, чтобы добавить опору или нагрузку."));
    } else {
        const std::string previousBody = bodyId_;
        if (bodyId_.empty()) bodyId_ = selected->first;
        reloadFaces();
        const kernel::FaceReference* reference = selected->first == bodyId_ ? face(selected->second) : nullptr;
        if (selected->first != bodyId_) {
            selectionLabel_->setText(tr("Выбрана грань другого тела — нагрузки этого случая относятся к одному телу."));
        } else if (reference != nullptr) {
            selectionLabel_->setText(tr("Выбрана грань %1: %2, %3 мм²")
                                         .arg(QString::fromStdString(faceIndexId(reference->faceId)), kindName(reference->kind))
                                         .arg(reference->area * 1e6, 0, 'f', 1));
        }
        if (previousBody.empty() && !bodyId_.empty() && context_.bodyMaterialId) {
            if (const auto materialId = context_.bodyMaterialId(bodyId_)) setMaterialId(*materialId);
        }
    }
    const QString title = analysis() == fea::StructuralAnalysis::Modal ? tr("Собственные частоты детали") : tr("Прочность детали");
    partLabel_->setText(bodyId_.empty() ? title
                                        : tr("%1: %2").arg(title, context_.bodyName ? context_.bodyName(bodyId_)
                                                                                    : QString::fromStdString(bodyId_)));
    refreshState();
}

QString StructuralStudyPanel::addItemOnSelectedFace(const Item& prototype) {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) return tr("Сначала выберите грань в окне модели.");
    if (!bodyId_.empty() && selected->first != bodyId_) {
        return tr("Грань другого тела: один нагрузочный случай — одно тело.");
    }
    bodyId_ = selected->first;
    reloadFaces();
    if (face(selected->second) == nullptr) return tr("Грань не найдена у тела — обновите выбор.");
    Item item = prototype;
    item.faceId = selected->second;
    items_.push_back(item);
    refreshItems();
    selectionChanged();
    return {};
}

void StructuralStudyPanel::addForce() {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) {
        status_->setText(tr("Сначала выберите грань в окне модели."));
        return;
    }
    QDialog dialog(this);
    dialog.setWindowTitle(tr("Сила на грань"));
    auto* form = new QFormLayout(&dialog);
    auto* note = new QLabel(tr("Равнодействующая, распределённая по площади грани (не болтовая и не контактная нагрузка)."));
    note->setWordWrap(true);
    form->addRow(note);
    std::array<QDoubleSpinBox*, 3> components{};
    static const char* names[] = {"Fx, Н", "Fy, Н", "Fz, Н"};
    for (int c = 0; c < 3; ++c) {
        components[c] = new QDoubleSpinBox;
        components[c]->setRange(-1e7, 1e7);
        components[c]->setDecimals(2);
        form->addRow(QString::fromUtf8(names[c]), components[c]);
    }
    reloadFaces();
    if (const kernel::FaceReference* reference = face(selected->second);
        reference != nullptr && reference->kind == kernel::FaceKind::Planar) {
        auto* normalRow = new QHBoxLayout;
        auto* magnitude = new QDoubleSpinBox;
        magnitude->setRange(0.0, 1e7);
        magnitude->setSuffix(tr(" Н"));
        auto* inward = new QPushButton(tr("по нормали внутрь"));
        normalRow->addWidget(magnitude, 1);
        normalRow->addWidget(inward);
        form->addRow(tr("Модуль"), normalRow);
        const Vector3 n = reference->normal;
        connect(inward, &QPushButton::clicked, &dialog, [components, magnitude, n]() {
            const double m = magnitude->value();
            components[0]->setValue(-n.x * m);
            components[1]->setValue(-n.y * m);
            components[2]->setValue(-n.z * m);
        });
    }
    auto* box = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    form->addRow(box);
    connect(box, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    connect(box, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    if (dialog.exec() != QDialog::Accepted) return;
    Item item;
    item.kind = ItemKind::Force;
    item.forceN = {components[0]->value(), components[1]->value(), components[2]->value()};
    if (fea::length(item.forceN) == 0.0) {
        status_->setText(tr("Нулевая сила не добавлена."));
        return;
    }
    status_->setText(addItemOnSelectedFace(item));
}

void StructuralStudyPanel::addPressure() {
    bool ok = false;
    const double kilopascals = QInputDialog::getDouble(
        this, tr("Давление на грань"),
        tr("Давление, кПа (положительное давит внутрь детали, отрицательное тянет наружу)"), 100.0, -1e6, 1e6, 3, &ok);
    if (!ok || kilopascals == 0.0) return;
    Item item;
    item.kind = ItemKind::Pressure;
    item.pressurePa = kilopascals * 1e3;
    status_->setText(addItemOnSelectedFace(item));
}

void StructuralStudyPanel::addExclusion() {
    bool ok = false;
    const double millimetres = QInputDialog::getDouble(
        this, tr("Зона исключения"),
        tr("Не учитывать напряжения ближе, мм, к выбранной грани. Для особенностей идеализированной опоры; "
           "записывается в результат, максимум «вне зоны» не выдаётся за максимум детали."),
        5.0, 0.01, 1e5, 2, &ok);
    if (!ok) return;
    Item item;
    item.kind = ItemKind::Exclusion;
    item.distanceM = millimetres / 1e3;
    status_->setText(addItemOnSelectedFace(item));
}

void StructuralStudyPanel::removeSelected() {
    const int row = itemList_->currentRow();
    if (row < 0 || row >= static_cast<int>(items_.size())) return;
    items_.erase(items_.begin() + row);
    if (items_.empty() && analysis() == fea::StructuralAnalysis::Static) bodyId_.clear();
    refreshItems();
    selectionChanged();
}

void StructuralStudyPanel::suggestElementSize() {
    reloadFaces();
    double low[3] = {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(),
                     std::numeric_limits<double>::infinity()};
    double high[3] = {-low[0], -low[1], -low[2]};
    for (const auto& reference : faces_) {
        for (const auto& vertex : reference.previewMesh.vertices) {
            const double p[3] = {vertex.x, vertex.y, vertex.z};
            for (int c = 0; c < 3; ++c) {
                low[c] = std::min(low[c], p[c]);
                high[c] = std::max(high[c], p[c]);
            }
        }
    }
    if (!std::isfinite(low[0])) {
        status_->setText(tr("Нет геометрии тела, предложить размер нельзя."));
        return;
    }
    const double diagonal = std::sqrt((high[0] - low[0]) * (high[0] - low[0]) + (high[1] - low[1]) * (high[1] - low[1])
                                      + (high[2] - low[2]) * (high[2] - low[2]));
    elementSize_->setValue(diagonal / 10.0 * 1e3);
    status_->setText(tr("Предложено 1/10 габарита (%1 мм). Хватает ли — покажет сходимость.").arg(diagonal / 10.0 * 1e3, 0, 'f', 2));
}

void StructuralStudyPanel::setMaterialId(const std::string& materialId) {
    const auto material = fea::findMaterial(materialId);
    if (!material) return;
    const int index = material_->findData(QString::fromStdString(material->id));
    if (index >= 0) material_->setCurrentIndex(index);
}

void StructuralStudyPanel::setMeshSettings(double coarseElementSizeM, double refinementFactor) {
    elementSize_->setValue(coarseElementSizeM * 1e3);
    refinement_->setValue(refinementFactor);
}

void StructuralStudyPanel::setLoadCaseName(const QString& name) {
    loadCaseName_->setText(name);
}

void StructuralStudyPanel::setBodyAccelerationG(const fea::Vec3& g) {
    accelerationX_->setValue(g.x);
    accelerationY_->setValue(g.y);
    accelerationZ_->setValue(g.z);
}

QString StructuralStudyPanel::describe(const Item& item) const {
    const kernel::FaceReference* reference = face(item.faceId);
    const QString where = QString::fromStdString(faceIndexId(item.faceId))
                          + (reference ? QString(" (%1)").arg(kindName(reference->kind)) : tr(" — грань исчезла"));
    switch (item.kind) {
    case ItemKind::Support: {
        if (item.fixed[0] && item.fixed[1] && item.fixed[2]) return tr("Заделка · %1").arg(where);
        QString axes;
        static const char* names[] = {"X", "Y", "Z"};
        for (int c = 0; c < 3; ++c)
            if (item.fixed[c]) axes += names[c];
        return tr("Опора по %1 · %2").arg(axes, where);
    }
    case ItemKind::Force:
        return tr("Сила [%1, %2, %3] Н · %4").arg(item.forceN.x, 0, 'f', 1).arg(item.forceN.y, 0, 'f', 1).arg(item.forceN.z, 0, 'f', 1).arg(where);
    case ItemKind::Pressure:
        return tr("Давление %1 кПа · %2").arg(item.pressurePa / 1e3, 0, 'f', 2).arg(where);
    case ItemKind::Exclusion:
        return tr("Исключить ближе %1 мм · %2").arg(item.distanceM * 1e3, 0, 'f', 2).arg(where);
    }
    return {};
}

void StructuralStudyPanel::refreshItems() {
    reloadFaces();
    itemList_->clear();
    const bool modal = analysis() == fea::StructuralAnalysis::Modal;
    for (const auto& item : items_) {
        if (modal && item.kind != ItemKind::Support) {
            auto* entry = new QListWidgetItem(describe(item) + tr(" — не используется в модальном расчёте"));
            entry->setForeground(palette().color(QPalette::Disabled, QPalette::Text));
            itemList_->addItem(entry);
        } else {
            itemList_->addItem(describe(item));
        }
    }
    refreshState();
}

Result<fea::StructuralJob> StructuralStudyPanel::buildJob() const {
    auto invalid = [](const QString& why) { return Result<fea::StructuralJob>::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    if (analysis() == fea::StructuralAnalysis::Modal) {
        if (bodyId_.empty()) return invalid(tr("Выберите любую грань детали: частоты считаются для её тела."));
        reloadFaces();
        fea::StructuralJob job;
        job.analysis = fea::StructuralAnalysis::Modal;
        job.geometryFormat = "brep";
        job.geometryPath = "part.brep";
        job.materialId = material_->currentData().toString().toStdString();
        job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
        if (job.loadCase.name.empty()) job.loadCase.name = tr("Собственные частоты").toStdString();
        // Supports only; no support at all is a free part, as an airframe in flight.
        for (const auto& item : items_) {
            if (item.kind != ItemKind::Support) continue;
            if (face(item.faceId) == nullptr) {
                return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте опору.")
                                   .arg(QString::fromStdString(faceIndexId(item.faceId))));
            }
            job.loadCase.supports.push_back({faceIndexId(item.faceId), item.fixed});
        }
        if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
        if (modeCount_->value() < 1) return invalid(tr("Не задано число мод."));
        if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
        job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
        job.settings.refinementFactor = refinement_->value();
        job.modal.modeCount = modeCount_->value();
        job.modal.rotors = rotors_;
        job.modal.bands = bands_;
        job.modal.separationMargin = margin_->value() / 100.0;
        job.resultPath = "result.json";
        job.fieldPath = "field.json";
        job.reportPath = "report.html";
        return Result<fea::StructuralJob>::ok(std::move(job));
    }
    if (bodyId_.empty() || items_.empty()) return invalid(tr("Нет опор и нагрузок: выберите грань и назначьте её."));
    reloadFaces();
    fea::StructuralJob job;
    job.geometryFormat = "brep";
    job.geometryPath = "part.brep";
    job.materialId = material_->currentData().toString().toStdString();
    job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
    if (job.loadCase.name.empty()) job.loadCase.name = tr("Нагрузочный случай").toStdString();
    bool hasLoad = false;
    for (const auto& item : items_) {
        if (face(item.faceId) == nullptr) {
            return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте нагрузку.")
                               .arg(QString::fromStdString(faceIndexId(item.faceId))));
        }
        const std::string faceIndex = faceIndexId(item.faceId);
        switch (item.kind) {
        case ItemKind::Support: job.loadCase.supports.push_back({faceIndex, item.fixed}); break;
        case ItemKind::Force: job.loadCase.forces.push_back({faceIndex, item.forceN}); hasLoad = true; break;
        case ItemKind::Pressure: job.loadCase.pressures.push_back({faceIndex, item.pressurePa}); hasLoad = true; break;
        case ItemKind::Exclusion: job.loadCase.stressExclusions.push_back({faceIndex, item.distanceM}); break;
        }
    }
    job.loadCase.bodyAccelerationMps2 = fea::Vec3{accelerationX_->value(), accelerationY_->value(), accelerationZ_->value()} * kStandardGravity;
    if (fea::length(job.loadCase.bodyAccelerationMps2) > 0.0) hasLoad = true;
    if (job.loadCase.supports.empty()) return invalid(tr("Нет опор: деталь нужно закрепить хотя бы на одной грани."));
    if (!hasLoad) return invalid(tr("Нет нагрузок: добавьте силу, давление или перегрузку."));
    // Settings after the load case itself: what is missing from the problem is reported first.
    if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
    if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
    job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
    job.settings.refinementFactor = refinement_->value();
    job.resultPath = "result.json";
    job.fieldPath = "field.json";
    job.reportPath = "report.html";
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::refreshState() {
    const bool running = isRunning();
    const auto job = buildJob();
    const bool toolAvailable = !structuralToolPath().isEmpty();
    runButton_->setEnabled(!running && job.isOk() && toolAvailable);
    cancelButton_->setEnabled(running);
    if (running) return;
    if (!toolAvailable) {
        status_->setText(tr("Расчётный модуль cadnext_structural не найден (сборка с CADNEXT_WITH_NETGEN=ON)."));
    } else if (!job.isOk()) {
        runButton_->setToolTip(QString::fromStdString(job.error().message));
    } else {
        runButton_->setToolTip({});
    }
}

bool StructuralStudyPanel::isRunning() const {
    return process_ != nullptr && process_->state() != QProcess::NotRunning;
}

QString StructuralStudyPanel::run() {
    if (isRunning()) return tr("Расчёт уже идёт.");
    const QString tool = structuralToolPath();
    if (tool.isEmpty()) return tr("Расчётный модуль cadnext_structural не найден.");
    const auto job = buildJob();
    if (!job.isOk()) return QString::fromStdString(job.error().message);
    if (!context_.exportBody) return tr("Нет доступа к геометрии тела.");
    const auto brep = context_.exportBody(bodyId_);
    if (!brep.isOk()) return tr("Не удалось выгрузить BRep тела: %1").arg(QString::fromStdString(brep.error().message));

    // Each run gets its own folder: part, job and results stay together and a result window can be
    // reopened later from them.
    const QString base = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation) + QStringLiteral("/structural");
    workDirectory_ = base + "/" + QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss-zzz"));
    if (!QDir().mkpath(workDirectory_)) return tr("Не удалось создать папку расчёта %1").arg(workDirectory_);
    QFile part(workDirectory_ + "/part.brep");
    if (!part.open(QIODevice::WriteOnly)) return tr("Не удалось записать деталь.");
    part.write(reinterpret_cast<const char*>(brep.value().data()), static_cast<qint64>(brep.value().size()));
    part.close();
    QFile jobFile(workDirectory_ + "/job.json");
    if (!jobFile.open(QIODevice::WriteOnly)) return tr("Не удалось записать задание.");
    jobFile.write(QByteArray::fromStdString(fea::structuralJobJson(job.value())));
    jobFile.close();

    delete process_;
    process_ = new QProcess(this);
    process_->setWorkingDirectory(workDirectory_);
    connect(process_, &QProcess::readyReadStandardOutput, this, [this]() { onProcessOutput(); });
    connect(process_, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) { onProcessFinished(code, status); });
    process_->start(tool, {workDirectory_ + "/job.json"});
    if (!process_->waitForStarted(5000)) return tr("Расчётный модуль не запустился: %1").arg(process_->errorString());
    status_->setText(tr("Запуск…"));
    refreshState();
    return {};
}

void StructuralStudyPanel::cancel() {
    if (!isRunning()) return;
    process_->kill();
    status_->setText(tr("Расчёт отменён."));
}

void StructuralStudyPanel::onProcessOutput() {
    while (process_->canReadLine()) {
        const QString line = QString::fromUtf8(process_->readLine()).trimmed();
        const QStringList parts = line.split(' ');
        if (parts.size() == 3 && parts[0] == QStringLiteral("progress")) {
            const int level = parts[1].toInt() + 1;
            status_->setText(parts[2] == QStringLiteral("mesh") ? tr("Сетка %1 из 3: строится…").arg(level)
                                                               : tr("Сетка %1 из 3: решение…").arg(level));
        }
    }
}

void StructuralStudyPanel::onProcessFinished(int exitCode, QProcess::ExitStatus status) {
    const QString resultPath = workDirectory_ + "/result.json";
    QString message;
    QString openPath;
    if (status == QProcess::CrashExit) {
        message = status_->text() == tr("Расчёт отменён.") ? tr("Расчёт отменён.")
                                                            : tr("Расчётный модуль аварийно завершился: %1")
                                                                  .arg(QString::fromUtf8(process_->readAllStandardError()).trimmed());
    } else if (exitCode == 0) {
        openPath = resultPath;
        lastResultPath_ = resultPath;
        message = tr("Готово.");
    } else {
        QFile file(resultPath);
        QString reason = QString::fromUtf8(process_->readAllStandardError()).trimmed();
        if (file.open(QIODevice::ReadOnly)) {
            fea::json::JsonValue result;
            std::string error;
            if (fea::json::parseJson(file.readAll().toStdString(), result, error)) {
                if (const auto* reasons = result.member("failureReasons"); reasons && !reasons->arrayItems.empty()) {
                    reason = QString::fromStdString(reasons->arrayItems.front().stringValue);
                }
            }
        }
        message = tr("Расчёт не выполнен: %1").arg(reason);
    }
    status_->setText(message);
    refreshState();
    emit finished(openPath, message);
}

} // namespace cadnext::gui
