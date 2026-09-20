#include "cadnext/gui/StructuralStudyPanel.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/Fire.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/RandomVibration.hpp"

#include <QCheckBox>
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
#include <QHeaderView>
#include <QTableWidget>
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
                                     applicationDirectory.filePath(QStringLiteral("../fea/occt/cadnext_structural")),
                                     QStringLiteral(CADNEXT_SOURCE_DIR "/build-netgen/fea/occt/cadnext_structural"),
                                     QStringLiteral(CADNEXT_SOURCE_DIR "/build-gui-occt/fea/occt/cadnext_structural"),
                                     QStringLiteral(CADNEXT_SOURCE_DIR "/build/fea/occt/cadnext_structural")}) {
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
    analysis_->addItem(tr("Вибрация (синус): вибростенд, дисбаланс винта"));
    analysis_->addItem(tr("Случайная вибрация (спектр PSD)"));
    analysis_->addItem(tr("Удар (импульс): катапульта, посадка, падение"));
    analysis_->addItem(tr("Климат (MIL-STD-810H): жара, солнце, холод"));
    analysis_->addItem(tr("Огонь (ISO 2685 / AC 20-135): огнестойкость"));
    analysis_->addItem(tr("Молния (SAE ARP5412): прямое воздействие"));
    analysis_->addItem(tr("ЭМС (MIL-STD-461G RS103): экранирование корпуса"));
    analysis_->addItem(tr("Обледенение (14 CFR 25 Прил. C): намерзание и обогрев"));
    analysis_->addItem(tr("Флаттер (25.629): изгиб + кручение против воздуха"));
    analysis_->addItem(tr("Удар птицы (25.571(e)): импульс птицы по грани"));
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
    auto* support = new QPushButton(tr("Опора / оснастка…"));
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
    forceButton_ = force;
    pressureButton_ = pressure;
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

    // Sine vibration: the supports are the fixture, the excitation is chosen here.
    vibrationGroup_ = new QWidget;
    auto* vibration = new QFormLayout(vibrationGroup_);
    vibrationForm_ = vibration;
    vibration->setContentsMargins(0, 0, 0, 0);
    vibration->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    vibrationKind_ = new QComboBox;
    vibrationKind_->addItem(tr("Вибростенд — ускорение оснастки"));
    vibrationKind_->addItem(tr("Сила на грани"));
    vibrationKind_->addItem(tr("Дисбаланс винта на грани"));
    vibration->addRow(tr("Возбуждение"), vibrationKind_);
    vibrationAxis_ = new QComboBox;
    vibrationAxis_->addItems({"X", "Y", "Z"});
    vibrationAxis_->setCurrentIndex(2);
    vibration->addRow(tr("Направление"), vibrationAxis_);
    vibrationAmplitude_ = new QDoubleSpinBox;
    vibrationAmplitude_->setRange(0.0, 1e6);
    vibrationAmplitude_->setDecimals(3);
    vibrationAmplitude_->setSpecialValueText(tr("не задано"));
    vibration->addRow(tr("Амплитуда"), vibrationAmplitude_);
    auto* faceRow = new QHBoxLayout;
    vibrationFaceLabel_ = new QLabel(tr("грань не задана"));
    auto* takeFace = new QPushButton(tr("Выбранная грань"));
    faceRow->addWidget(vibrationFaceLabel_, 1);
    faceRow->addWidget(takeFace);
    vibration->addRow(tr("Грань силы"), faceRow);
    damping_ = new QDoubleSpinBox;
    damping_->setRange(0.0, 50.0);
    damping_->setDecimals(2);
    damping_->setSuffix(tr(" %"));
    damping_->setSpecialValueText(tr("не задано"));
    damping_->setToolTip(tr("Доля критического демпфирования каждой моды. Умолчания нет: это свойство конструкции. "
                            "Ориентиры: монолитный металл 1–2 %, болтовая или клеёная сборка 2–5 %, композит 1–3 %. "
                            "Амплитуда на резонансе обратно пропорциональна ζ."));
    vibration->addRow(tr("Демпфирование ζ"), damping_);
    vibrationModes_ = new QSpinBox;
    vibrationModes_->setRange(0, 80);
    vibrationModes_->setSpecialValueText(tr("не задано"));
    vibrationModes_->setToolTip(tr("Моды для суперпозиции. Результат предупредит, если диапазон выше последней моды или моды несут < 90 % массы."));
    vibration->addRow(tr("Число мод"), vibrationModes_);
    auto* range = new QHBoxLayout;
    fromHz_ = new QDoubleSpinBox;
    toHz_ = new QDoubleSpinBox;
    for (QDoubleSpinBox* box : {fromHz_, toHz_}) {
        box->setRange(0.0, 1e6);
        box->setDecimals(1);
        box->setSuffix(tr(" Гц"));
        box->setSpecialValueText(tr("не задано"));
        range->addWidget(box);
    }
    vibration->addRow(tr("Частоты от–до"), range);
    auto* probeRow = new QHBoxLayout;
    probeFaceLabel_ = new QLabel(tr("нет (необязательно)"));
    auto* takeProbe = new QPushButton(tr("Выбранная грань"));
    probeRow->addWidget(probeFaceLabel_, 1);
    probeRow->addWidget(takeProbe);
    vibration->addRow(tr("Датчик"), probeRow);
    // Random vibration: the spectrum of the table's acceleration, point by point.
    psdBox_ = new QWidget;
    auto* psdLayout = new QVBoxLayout(psdBox_);
    psdLayout->setContentsMargins(0, 0, 0, 0);
    psdTable_ = new QTableWidget(0, 2);
    psdTable_->setHorizontalHeaderLabels({tr("Частота, Гц"), tr("PSD, g²/Гц")});
    psdTable_->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
    psdTable_->verticalHeader()->setVisible(false);
    psdTable_->setMinimumHeight(130);
    psdTable_->setToolTip(tr("Точки спектра по возрастанию частоты. Между точками — прямая в логарифмических осях (постоянный наклон в дБ/окт), "
                             "вне первой и последней точки спектр равен нулю."));
    auto* psdButtons = new QHBoxLayout;
    auto* addPoint = new QPushButton(tr("Точка +"));
    auto* removePoint = new QPushButton(tr("Точка −"));
    psdButtons->addWidget(addPoint);
    psdButtons->addWidget(removePoint);
    psdSummary_ = new QLabel;
    psdSummary_->setWordWrap(true);
    psdLayout->addWidget(psdTable_);
    psdLayout->addLayout(psdButtons);
    psdLayout->addWidget(psdSummary_);
    vibration->addRow(tr("Спектр"), psdBox_);
    connect(addPoint, &QPushButton::clicked, this, [this]() {
        const int row = psdTable_->rowCount();
        psdTable_->insertRow(row);
        const double previous = row > 0 && psdTable_->item(row - 1, 0) ? psdTable_->item(row - 1, 0)->text().toDouble() : 0.0;
        psdTable_->setItem(row, 0, new QTableWidgetItem(previous > 0 ? QString::number(previous * 2) : QString()));
        psdTable_->setItem(row, 1, new QTableWidgetItem(row > 0 && psdTable_->item(row - 1, 1) ? psdTable_->item(row - 1, 1)->text() : QString()));
    });
    connect(removePoint, &QPushButton::clicked, this, [this]() {
        const int row = psdTable_->currentRow() >= 0 ? psdTable_->currentRow() : psdTable_->rowCount() - 1;
        if (row >= 0) psdTable_->removeRow(row);
        refreshState();
    });
    connect(psdTable_, &QTableWidget::itemChanged, this, [this]() { refreshState(); });
    // Shock: a pulse of the fixture's acceleration.
    pulseBox_ = new QWidget;
    pulseForm_ = new QFormLayout(pulseBox_);
    pulseForm_->setContentsMargins(0, 0, 0, 0);
    pulseShape_ = new QComboBox;
    pulseShape_->addItems({tr("Полусинус"), tr("Пила с пиком в конце"), tr("Трапеция")});
    pulseForm_->addRow(tr("Форма"), pulseShape_);
    auto pulseNumber = [this](const QString& title, const QString& suffix, int decimals) {
        auto* box = new QDoubleSpinBox;
        box->setRange(0.0, 1e6);
        box->setDecimals(decimals);
        box->setSuffix(suffix);
        box->setSpecialValueText(tr("не задано"));
        pulseForm_->addRow(title, box);
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() { refreshState(); });
        return box;
    };
    pulsePeak_ = pulseNumber(tr("Пик ускорения"), tr(" g"), 2);
    pulseDuration_ = pulseNumber(tr("Длительность"), tr(" мс"), 3);
    pulseRise_ = pulseNumber(tr("Фронт"), tr(" мс"), 3);
    pulseFall_ = pulseNumber(tr("Спад"), tr(" мс"), 3);
    auto showTrapezoid = [this]() {
        const bool trapezoid = pulseShape_->currentIndex() == 2;
        pulseForm_->setRowVisible(pulseRise_, trapezoid);
        pulseForm_->setRowVisible(pulseFall_, trapezoid);
        if (runButton_ != nullptr) refreshState();
    };
    connect(pulseShape_, qOverload<int>(&QComboBox::currentIndexChanged), this, showTrapezoid);
    showTrapezoid();
    vibration->addRow(tr("Импульс"), pulseBox_);
    auto* vibrationNote = new QLabel(tr("Опоры — это оснастка: при вибростенде они движутся вместе с ним. Амплитуды — пиковые значения синуса, "
                                        "спектр — PSD ускорения. Усталость пока не оценивается, поэтому лучший вердикт — WARNING."));
    vibrationNote->setWordWrap(true);
    vibration->addRow(vibrationNote);
    layout->addWidget(vibrationGroup_);
    auto describeKind = [this]() {
        const int kind = vibrationKind_->currentIndex();
        vibrationAmplitude_->setSuffix(kind == 0 ? tr(" g") : (kind == 1 ? tr(" Н") : tr(" г·мм")));
        vibrationAmplitude_->setToolTip(kind == 2 ? tr("Остаточный дисбаланс U = m·e. По ISO 21940-11 для класса G: U = m·G/Ω. Сила U·Ω² растёт с квадратом частоты.")
                                                  : tr("Пиковое значение синуса, одинаковое во всём диапазоне."));
        // Also called while the panel is still being built, before the run button exists.
        if (runButton_ != nullptr) refreshState();
    };
    connect(vibrationKind_, qOverload<int>(&QComboBox::currentIndexChanged), this, describeKind);
    describeKind();
    connect(takeFace, &QPushButton::clicked, this, [this]() {
        const QString problem = setVibrationFaceFromSelection();
        if (!problem.isEmpty()) status_->setText(problem);
    });
    connect(takeProbe, &QPushButton::clicked, this, [this]() {
        const QString problem = setProbeFaceFromSelection();
        if (!problem.isEmpty()) status_->setText(problem);
    });
    for (QDoubleSpinBox* box : {vibrationAmplitude_, damping_, fromHz_, toHz_})
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() { refreshState(); });
    connect(vibrationModes_, qOverload<int>(&QSpinBox::valueChanged), this, [this]() { refreshState(); });
    connect(vibrationAxis_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() { refreshState(); });
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

    buildClimateGroup(layout);
    buildFireGroup(layout);
    buildLightningGroup(layout);
    buildEmcGroup(layout);
    buildIcingGroup(layout);
    buildFlutterGroup(layout);
    buildBirdGroup(layout);
    layout->addWidget(equipmentBox_); // shared by the climate, fire and lightning tests

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
    const bool random = analysis() == fea::StructuralAnalysis::Random;
    const bool shock = analysis() == fea::StructuralAnalysis::Shock;
    const bool climate = analysis() == fea::StructuralAnalysis::Climate;
    const bool fire = analysis() == fea::StructuralAnalysis::Fire;
    const bool lightning = analysis() == fea::StructuralAnalysis::Lightning;
    const bool emc = analysis() == fea::StructuralAnalysis::Emc;
    const bool icing = analysis() == fea::StructuralAnalysis::Icing;
    const bool flutter = analysis() == fea::StructuralAnalysis::Flutter;
    const bool bird = analysis() == fea::StructuralAnalysis::Bird;
    const bool harmonic = analysis() == fea::StructuralAnalysis::Harmonic || random || shock;
    loadButtons_->setVisible(!lightning && !emc && !icing);
    forceButton_->setVisible(!harmonic && !climate && !lightning && !emc && !icing && !flutter && !modal && !bird);
    pressureButton_->setVisible(!harmonic && !climate && !lightning && !emc && !icing && !flutter && !modal && !bird);
    accelerationRow_->setVisible(!modal && !harmonic && !climate && !lightning && !emc && !icing && !flutter && !bird);
    modalGroup_->setVisible(modal);
    vibrationGroup_->setVisible(harmonic);
    climateGroup_->setVisible(climate);
    fireGroup_->setVisible(fire);
    lightningGroup_->setVisible(lightning);
    emcGroup_->setVisible(emc);
    icingGroup_->setVisible(icing);
    flutterGroup_->setVisible(flutter);
    birdGroup_->setVisible(bird);
    equipmentBox_->setVisible(climate || fire || lightning);
    // The sine rows (kind, amplitude, force face, range) and the spectrum row share one form.
    // Rows of the form, in the order built: 0 kind, 1 axis, 2 amplitude, 3 force face, 4 ζ, 5 modes,
    // 6 range, 7 probe, 8 spectrum, 9 pulse, 10 note.
    const bool sine = analysis() == fea::StructuralAnalysis::Harmonic;
    vibrationForm_->setRowVisible(0, sine);
    vibrationForm_->setRowVisible(2, sine);
    vibrationForm_->setRowVisible(3, sine);
    vibrationForm_->setRowVisible(6, sine);
    vibrationForm_->setRowVisible(9, shock);
    vibrationForm_->setRowVisible(psdBox_, random);
    caseLabel_->setText(modal || harmonic || climate || fire || lightning || emc || icing || flutter || bird ? tr("Вариант")
                                                                                                              : tr("Нагрузочный случай"));
    loadCaseName_->setPlaceholderText(modal       ? tr("например, «лучи закреплены в центральной плите»")
                                      : harmonic  ? tr("например, «луч на вибростенде, 2 g, 5–500 Гц»")
                                      : climate   ? tr("например, «отсек авионики на стоянке, пустыня»")
                                      : fire      ? tr("например, «стенка отсека батареи, пожар батареи»")
                                      : lightning ? tr("например, «законцовка крыла, зона 1A, A+B+C»")
                                      : emc       ? tr("например, «корпус авионики, RS103, волна по +x»")
                                      : icing     ? tr("например, «консоль крыла, взлётное обледенение»")
                                      : flutter   ? tr("например, «консоль крыла, флаттер до 1.15 V_D»")
                                      : bird      ? tr("например, «носок крыла, птица 1 кг на крейсере»")
                                                  : tr("например, «+3.5 g, выход из пикирования»"));
    refreshItems();
    selectionChanged();
}

fea::StructuralAnalysis StructuralStudyPanel::analysis() const {
    switch (analysis_->currentIndex()) {
    case 1: return fea::StructuralAnalysis::Modal;
    case 2: return fea::StructuralAnalysis::Harmonic;
    case 3: return fea::StructuralAnalysis::Random;
    case 4: return fea::StructuralAnalysis::Shock;
    case 5: return fea::StructuralAnalysis::Climate;
    case 6: return fea::StructuralAnalysis::Fire;
    case 7: return fea::StructuralAnalysis::Lightning;
    case 8: return fea::StructuralAnalysis::Emc;
    case 9: return fea::StructuralAnalysis::Icing;
    case 10: return fea::StructuralAnalysis::Flutter;
    case 11: return fea::StructuralAnalysis::Bird;
    default: return fea::StructuralAnalysis::Static;
    }
}

void StructuralStudyPanel::setAnalysis(fea::StructuralAnalysis analysis) {
    analysis_->setCurrentIndex(analysis == fea::StructuralAnalysis::Modal      ? 1
                               : analysis == fea::StructuralAnalysis::Harmonic ? 2
                               : analysis == fea::StructuralAnalysis::Random   ? 3
                               : analysis == fea::StructuralAnalysis::Shock    ? 4
                               : analysis == fea::StructuralAnalysis::Climate  ? 5
                               : analysis == fea::StructuralAnalysis::Fire     ? 6
                               : analysis == fea::StructuralAnalysis::Lightning ? 7
                               : analysis == fea::StructuralAnalysis::Emc       ? 8
                               : analysis == fea::StructuralAnalysis::Icing     ? 9
                               : analysis == fea::StructuralAnalysis::Flutter   ? 10
                               : analysis == fea::StructuralAnalysis::Bird      ? 11
                                                                                : 0);
}

void StructuralStudyPanel::buildClimateGroup(QVBoxLayout* layout) {
    climateGroup_ = new QWidget;
    climateForm_ = new QFormLayout(climateGroup_);
    auto* form = climateForm_;
    form->setContentsMargins(0, 0, 0, 0);
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    climateCondition_ = new QComboBox;
    climateCondition_->addItems({tr("A1 жаркий сухой — солнце (505.7), воздух 32–49 °C"), tr("A1 жаркий сухой — в тени (501.7)"),
                                 tr("A1 жаркий сухой — хранение и перевозка (501.7), до 71 °C"), tr("A2 жаркий — солнце (505.7), воздух 30–44 °C"),
                                 tr("A2 жаркий — в тени (501.7)"), tr("A2 жаркий — хранение и перевозка (501.7), до 63 °C"),
                                 tr("C1 холодный — −32 °C (502.7)"), tr("C1 холодный — хранение, −33 °C"), tr("C2 очень холодный — −46 °C (502.7)"),
                                 tr("C2 очень холодный — хранение, −46 °C"), tr("C3 крайне холодный — −51 °C (502.7)"), tr("C3 крайне холодный — хранение, −51 °C")});
    climateCondition_->setToolTip(tr("Климатические категории MIL-STD-810H. Жара — суточный цикл стандарта, повторяемый до установившегося (3–7 суток, "
                                     "как в методе 505.7); холод — постоянная температура (нижнее значение диапазона, метод 502.7)."));
    form->addRow(tr("Условия"), climateCondition_);
    climateAirflow_ = new QComboBox;
    climateAirflow_->addItems({tr("Камера (испытание по стандарту)"), tr("Полёт")});
    form->addRow(tr("Обдув"), climateAirflow_);
    auto number = [&](const QString& title, double low, double high, int decimals, const QString& suffix, const QString& special) {
        auto* box = new QDoubleSpinBox;
        box->setRange(low, high);
        box->setDecimals(decimals);
        box->setSuffix(suffix);
        if (!special.isEmpty()) box->setSpecialValueText(special);
        form->addRow(title, box);
        // Values set while the panel is still being built change these before the run button exists.
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
        return box;
    };
    climateSpeed_ = number(tr("Скорость воздуха"), 0.0, 400.0, 2, tr(" м/с"), tr("не задано"));
    climateSpeed_->setToolTip(tr("Камера: метод 505.7 — 1.5–3.0 м/с (не ниже 0.25 м/с для укрытого изделия), методы 501.7/502.7 — не выше 1.7 м/с. "
                                 "Полёт: воздушная скорость. Умолчания нет: от неё зависит теплоотдача."));
    climateAltitude_ = number(tr("Высота полёта"), 0.0, 11000.0, 0, tr(" м"), QString());
    climateUp_ = new QComboBox;
    climateUp_->addItems({"+X", "−X", "+Y", "−Y", "+Z", "−Z"});
    climateUp_->setCurrentIndex(4);
    climateUp_->setToolTip(tr("Направление «вверх» в координатах детали: оттуда светят солнце и лампы камеры."));
    form->addRow(tr("Вверх (солнце)"), climateUp_);
    climateFlow_ = new QComboBox;
    climateFlow_->addItems({"X", "Y", "Z"});
    climateFlow_->setToolTip(tr("Вдоль какой оси дует воздух: по длине детали вдоль него считается теплоотдача пластины."));
    form->addRow(tr("Поток вдоль"), climateFlow_);
    climateAbsorptance_ = number(tr("Поглощение солнца α"), 0.0, 1.0, 2, QString(), tr("не задано"));
    climateAbsorptance_->setToolTip(tr("Поглощательная способность покрытия для солнечного излучения — из паспорта краски или покрытия. Умолчания нет."));
    climateEmissivity_ = number(tr("Излучение ε"), 0.0, 1.0, 2, QString(), tr("не задано"));
    climateEmissivity_->setToolTip(tr("Излучательная способность покрытия в ИК-диапазоне — из паспорта. Умолчания нет."));
    climateAssembly_ = number(tr("Температура сборки"), -60.0, 80.0, 1, tr(" °C"), QString());
    climateAssembly_->setValue(20.0);
    climateAssembly_->setToolTip(tr("Температура, при которой деталь собрана без напряжений. 20 °C — нормальная температура ISO 1; задайте свою, если сборка шла иначе."));
    climateStep_ = number(tr("Шаг по времени"), 0.0, 1800.0, 0, tr(" с"), tr("не задано"));
    climateStep_->setValue(300.0);
    climateStep_->setToolTip(tr("Должен делить 30 минут нацело. Ошибка шага измеряется: грубая сетка пересчитывается с половинным шагом, "
                                "и разница входит в погрешность результата."));
    climateOperating_ = new QCheckBox(tr("Оборудование работает (выделяет тепло)"));
    climateOperating_->setChecked(true);
    componentTable_ = new QTableWidget(0, 5);
    componentTable_->setHorizontalHeaderLabels({tr("Оборудование"), tr("Грань"), tr("Вт"), tr("мин, °C"), tr("макс, °C")});
    componentTable_->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
    componentTable_->verticalHeader()->setVisible(false);
    componentTable_->setMinimumHeight(110);
    componentTable_->setToolTip(tr("Блок на грани детали: его тепло входит через грань, грань закрыта от воздуха и солнца. Пределы — температура "
                                   "корпуса по паспорту; пустая ячейка — предела нет."));
    auto* componentButtons = new QHBoxLayout;
    auto* addComponent = new QPushButton(tr("Блок на выбранной грани…"));
    auto* removeComponent = new QPushButton(tr("Удалить блок"));
    componentButtons->addWidget(addComponent);
    componentButtons->addWidget(removeComponent);
    // Shared by the climate and the fire tests; laid out after both groups (buildFireGroup).
    equipmentBox_ = new QWidget;
    auto* componentLayout = new QVBoxLayout(equipmentBox_);
    componentLayout->setContentsMargins(0, 0, 0, 0);
    componentLayout->addWidget(new QLabel(tr("Оборудование на гранях")));
    componentLayout->addWidget(climateOperating_);
    componentLayout->addWidget(componentTable_);
    componentLayout->addLayout(componentButtons);
    climateMaterialMin_ = number(tr("Материал: мин."), -274.0, 1500.0, 1, tr(" °C"), tr("нет данных"));
    climateMaterialMax_ = number(tr("Материал: макс."), -274.0, 1500.0, 1, tr(" °C"), tr("нет данных"));
    climateMaterialMin_->setValue(-274.0);
    climateMaterialMax_->setValue(-274.0);
    climateMaterialMax_->setToolTip(tr("Допустимая температура материала по его паспорту. Без неё вердикт не выше WARNING: сравнивать не с чем."));
    auto* note = new QLabel(tr("Опоры необязательны: без них деталь расширяется свободно, с ними — закреплена жёстко (грани опор закрыты). "
                               "Естественная конвекция не учитывается — результат с запасом."));
    note->setWordWrap(true);
    form->addRow(note);
    layout->addWidget(climateGroup_);

    auto showRows = [this]() {
        const int condition = climateCondition_->currentIndex();
        const bool sun = condition == 0 || condition == 3;
        const bool flight = climateAirflow_->currentIndex() == 1;
        climateForm_->setRowVisible(climateAltitude_, flight);
        climateForm_->setRowVisible(climateAbsorptance_, sun);
        climateForm_->setRowVisible(climateUp_, sun);
        climateForm_->setRowVisible(climateStep_, condition < 6);
        if (runButton_ != nullptr) refreshState();
    };
    connect(climateCondition_, qOverload<int>(&QComboBox::currentIndexChanged), this, showRows);
    connect(climateAirflow_, qOverload<int>(&QComboBox::currentIndexChanged), this, showRows);
    connect(climateOperating_, &QCheckBox::toggled, this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
    connect(componentTable_, &QTableWidget::itemChanged, this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
    connect(addComponent, &QPushButton::clicked, this, [this]() {
        bool ok = false;
        const QString name = QInputDialog::getText(this, tr("Блок оборудования"), tr("Название (например, «полётный контроллер»)"), QLineEdit::Normal, QString(), &ok);
        if (!ok || name.trimmed().isEmpty()) return;
        const QString problem = addClimateComponentOnSelectedFace(name.trimmed(), 0.0, NAN, NAN);
        if (!problem.isEmpty()) status_->setText(problem);
    });
    connect(removeComponent, &QPushButton::clicked, this, [this]() {
        const int row = componentTable_->currentRow() >= 0 ? componentTable_->currentRow() : componentTable_->rowCount() - 1;
        if (row >= 0) componentTable_->removeRow(row);
        refreshState();
    });
    showRows();
}

void StructuralStudyPanel::setClimate(int condition, bool flight, double airSpeedMps, double altitudeM, int up, int flow, double absorptance, double emissivity,
                                      double assemblyC, double stepS, bool operating) {
    climateCondition_->setCurrentIndex(condition);
    climateAirflow_->setCurrentIndex(flight ? 1 : 0);
    climateSpeed_->setValue(airSpeedMps);
    climateAltitude_->setValue(altitudeM);
    climateUp_->setCurrentIndex(up);
    climateFlow_->setCurrentIndex(flow);
    climateAbsorptance_->setValue(absorptance);
    climateEmissivity_->setValue(emissivity);
    climateAssembly_->setValue(assemblyC);
    climateStep_->setValue(stepS);
    climateOperating_->setChecked(operating);
}

QString StructuralStudyPanel::addClimateComponentOnSelectedFace(const QString& name, double powerW, double minimumC, double maximumC) {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) return tr("Сначала выберите грань в окне модели.");
    if (!bodyId_.empty() && selected->first != bodyId_) return tr("Грань другого тела: вариант относится к одному телу.");
    bodyId_ = selected->first;
    reloadFaces();
    if (face(selected->second) == nullptr) return tr("Грань не найдена у тела — обновите выбор.");
    const QSignalBlocker block(componentTable_);
    const int row = componentTable_->rowCount();
    componentTable_->insertRow(row);
    componentTable_->setItem(row, 0, new QTableWidgetItem(name));
    auto* faceItem = new QTableWidgetItem(QString::fromStdString(faceIndexId(selected->second)));
    faceItem->setData(Qt::UserRole, QString::fromStdString(selected->second));
    faceItem->setFlags(faceItem->flags() & ~Qt::ItemIsEditable);
    componentTable_->setItem(row, 1, faceItem);
    componentTable_->setItem(row, 2, new QTableWidgetItem(QString::number(powerW, 'g', 6)));
    componentTable_->setItem(row, 3, new QTableWidgetItem(std::isfinite(minimumC) ? QString::number(minimumC, 'g', 6) : QString()));
    componentTable_->setItem(row, 4, new QTableWidgetItem(std::isfinite(maximumC) ? QString::number(maximumC, 'g', 6) : QString()));
    selectionChanged();
    return {};
}

void StructuralStudyPanel::setClimateMaterialLimits(double minimumC, double maximumC) {
    climateMaterialMin_->setValue(std::isfinite(minimumC) ? minimumC : climateMaterialMin_->minimum());
    climateMaterialMax_->setValue(std::isfinite(maximumC) ? maximumC : climateMaterialMax_->minimum());
}

Result<std::vector<fea::ClimateComponent>> StructuralStudyPanel::equipment() const {
    using R = Result<std::vector<fea::ClimateComponent>>;
    auto invalid = [](const QString& why) { return R::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    std::vector<fea::ClimateComponent> list;
    for (int row = 0; row < componentTable_->rowCount(); ++row) {
        auto text = [&](int column) { return componentTable_->item(row, column) ? componentTable_->item(row, column)->text().trimmed().replace(',', '.') : QString(); };
        fea::ClimateComponent component;
        component.name = text(0).toStdString();
        const QString faceId = componentTable_->item(row, 1) ? componentTable_->item(row, 1)->data(Qt::UserRole).toString() : QString();
        if (component.name.empty()) return invalid(tr("Оборудование, строка %1: нет названия.").arg(row + 1));
        if (face(faceId.toStdString()) == nullptr) return invalid(tr("Оборудование «%1»: грань больше не существует.").arg(text(0)));
        component.face = faceIndexId(faceId.toStdString());
        bool ok = false;
        component.powerW = text(2).isEmpty() ? 0.0 : text(2).toDouble(&ok);
        if ((!text(2).isEmpty() && !ok) || component.powerW < 0.0) return invalid(tr("Оборудование «%1»: мощность — число ≥ 0 Вт.").arg(text(0)));
        for (int column : {3, 4}) {
            if (text(column).isEmpty()) continue;
            const double celsius = text(column).toDouble(&ok);
            if (!ok) return invalid(tr("Оборудование «%1»: предел — число, °C.").arg(text(0)));
            (column == 3 ? component.minimumK : component.maximumK) = celsius + 273.15;
        }
        if (component.minimumK && component.maximumK && !(*component.minimumK < *component.maximumK)) return invalid(tr("Оборудование «%1»: мин. < макс.").arg(text(0)));
        list.push_back(component);
    }
    return R::ok(std::move(list));
}

Result<fea::StructuralJob> StructuralStudyPanel::buildClimateJob() const {
    auto invalid = [](const QString& why) { return Result<fea::StructuralJob>::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    if (bodyId_.empty()) return invalid(tr("Выберите любую грань детали: испытание относится к её телу."));
    reloadFaces();
    fea::StructuralJob job;
    job.analysis = fea::StructuralAnalysis::Climate;
    job.geometryFormat = "brep";
    job.geometryPath = "part.brep";
    job.materialId = material_->currentData().toString().toStdString();
    job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
    if (job.loadCase.name.empty()) job.loadCase.name = climateCondition_->currentText().toStdString();
    for (const auto& item : items_) {
        if (item.kind != ItemKind::Support && item.kind != ItemKind::Exclusion) continue;
        if (face(item.faceId) == nullptr) {
            return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте её.").arg(QString::fromStdString(faceIndexId(item.faceId))));
        }
        if (item.kind == ItemKind::Support) job.loadCase.supports.push_back({faceIndexId(item.faceId), item.fixed});
        else job.loadCase.stressExclusions.push_back({faceIndexId(item.faceId), item.distanceM});
    }
    auto& c = job.climate;
    const int condition = climateCondition_->currentIndex();
    c.environment = condition < 6 ? fea::ClimateEnvironment::Hot : fea::ClimateEnvironment::Cold;
    if (condition < 6) {
        c.hotCategory = condition < 3 ? fea::HotCategory::A1HotDry : fea::HotCategory::A2BasicHot;
        c.hotExposure = condition % 3 == 0 ? fea::HotExposure::Sun : condition % 3 == 1 ? fea::HotExposure::Shade : fea::HotExposure::Induced;
    } else {
        const int cold = condition - 6;
        c.coldCategory = cold < 2 ? fea::ColdCategory::C1BasicCold : cold < 4 ? fea::ColdCategory::C2Cold : fea::ColdCategory::C3SevereCold;
        c.coldExposure = cold % 2 == 0 ? fea::ColdExposure::Ambient : fea::ColdExposure::Induced;
    }
    const bool hot = c.environment == fea::ClimateEnvironment::Hot, sun = hot && c.hotExposure == fea::HotExposure::Sun;
    c.airflow = climateAirflow_->currentIndex() == 1 ? fea::ClimateAirflow::Flight : fea::ClimateAirflow::Chamber;
    c.altitudeM = climateAltitude_->value();
    static const fea::Vec3 axes[] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
    c.upDirection = axes[climateUp_->currentIndex()];
    c.flowDirection = axes[2 * climateFlow_->currentIndex()];
    c.emissivity = climateEmissivity_->value();
    c.solarAbsorptance = sun ? climateAbsorptance_->value() : 0.0;
    c.stressFreeK = climateAssembly_->value() + 273.15;
    c.operating = climateOperating_->isChecked();
    c.stepS = hot ? climateStep_->value() : 0.0;
    const auto components = equipment();
    if (!components.isOk()) return invalid(QString::fromStdString(components.error().message));
    c.components = components.value();
    if (climateMaterialMin_->value() > climateMaterialMin_->minimum()) c.materialMinimumK = climateMaterialMin_->value() + 273.15;
    if (climateMaterialMax_->value() > climateMaterialMax_->minimum()) c.materialMaximumK = climateMaterialMax_->value() + 273.15;
    if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
    if (!(climateSpeed_->value() > 0.0)) return invalid(tr("Не задана скорость воздуха — у неё нет умолчания (камера: 1.5–3.0 м/с при солнце, ≤ 1.7 м/с без него)."));
    c.airSpeedMps = climateSpeed_->value();
    if (!(c.emissivity > 0.0)) return invalid(tr("Не задана излучательная способность покрытия ε."));
    if (sun && !(c.solarAbsorptance > 0.0)) return invalid(tr("Не задана поглощательная способность покрытия для солнца α."));
    if (hot && !(c.stepS > 0.0)) return invalid(tr("Не задан шаг по времени."));
    if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
    job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
    job.settings.refinementFactor = refinement_->value();
    job.resultPath = "result.json";
    job.fieldPath = "field.json";
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::buildFireGroup(QVBoxLayout* layout) {
    fireGroup_ = new QWidget;
    fireForm_ = new QFormLayout(fireGroup_);
    auto* form = fireForm_;
    form->setContentsMargins(0, 0, 0, 0);
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    fireStandard_ = new QComboBox;
    fireStandard_->addItems({tr("ISO 2685: 1100 °C, 116 кВт/м²"), tr("FAA AC 20-135: 2000 °F, 9.3 BTU/(фут²·с)")});
    form->addRow(tr("Пламя"), fireStandard_);
    fireClass_ = new QComboBox;
    fireClass_->addItems({tr("Огнестойкий — 5 мин"), tr("Огненепроницаемый — 15 мин"), tr("Другая длительность")});
    fireClass_->setCurrentIndex(1);
    form->addRow(tr("Класс"), fireClass_);
    fireDuration_ = new QDoubleSpinBox;
    fireDuration_->setRange(0.0, 240.0);
    fireDuration_->setDecimals(1);
    fireDuration_->setSuffix(tr(" мин"));
    fireDuration_->setSpecialValueText(tr("не задано"));
    form->addRow(tr("Длительность"), fireDuration_);
    fireFaces_ = new QListWidget;
    fireFaces_->setMinimumHeight(60);
    auto* faceButtons = new QHBoxLayout;
    auto* addFace = new QPushButton(tr("Выбранная грань — под пламя"));
    auto* removeFace = new QPushButton(tr("Убрать"));
    faceButtons->addWidget(addFace);
    faceButtons->addWidget(removeFace);
    auto* faceBox = new QWidget;
    auto* faceLayout = new QVBoxLayout(faceBox);
    faceLayout->setContentsMargins(0, 0, 0, 0);
    faceLayout->addWidget(fireFaces_);
    faceLayout->addLayout(faceButtons);
    form->addRow(tr("Грани под пламенем"), faceBox);
    fireSurface_ = new QComboBox;
    fireSurface_->addItems({tr("Чистая, ε = 0.3 (EN 1999-1-2)"), tr("Окрашенная или закопчённая, ε = 0.7"), tr("Своя ε")});
    fireSurface_->setCurrentIndex(1);
    form->addRow(tr("Поверхность"), fireSurface_);
    fireEmissivity_ = new QDoubleSpinBox;
    fireEmissivity_->setRange(0.0, 1.0);
    fireEmissivity_->setDecimals(2);
    fireEmissivity_->setSpecialValueText(tr("не задано"));
    form->addRow(tr("ε"), fireEmissivity_);
    fireStep_ = new QDoubleSpinBox;
    fireStep_->setRange(0.0, 600.0);
    fireStep_->setDecimals(2);
    fireStep_->setSuffix(tr(" с"));
    fireStep_->setSpecialValueText(tr("не задано"));
    fireStep_->setValue(1.0);
    fireStep_->setToolTip(tr("Ошибка шага измеряется: грубая сетка пересчитывается с половинным шагом, разница входит в погрешность."));
    form->addRow(tr("Шаг по времени"), fireStep_);
    auto* note = new QLabel(tr("Силы, давления и перегрузка случая — нагрузки во время пожара. Материал нужен с данными при нагреве "
                               "(EN 1999-1-2: алюминий 6061-T6, 7075-T6). Горючесть материалов не моделируется — нет данных о пиролизе."));
    note->setWordWrap(true);
    form->addRow(note);
    layout->addWidget(fireGroup_);

    auto showRows = [this]() {
        fireForm_->setRowVisible(fireDuration_, fireClass_->currentIndex() == 2);
        fireForm_->setRowVisible(fireEmissivity_, fireSurface_->currentIndex() == 2);
        if (runButton_ != nullptr) refreshState();
    };
    connect(fireClass_, qOverload<int>(&QComboBox::currentIndexChanged), this, showRows);
    connect(fireSurface_, qOverload<int>(&QComboBox::currentIndexChanged), this, showRows);
    connect(fireStandard_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
    for (QDoubleSpinBox* box : {fireDuration_, fireEmissivity_, fireStep_})
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    connect(addFace, &QPushButton::clicked, this, [this]() {
        const QString problem = addFlameFaceFromSelection();
        if (!problem.isEmpty()) status_->setText(problem);
    });
    connect(removeFace, &QPushButton::clicked, this, [this]() {
        const int row = fireFaces_->currentRow() >= 0 ? fireFaces_->currentRow() : fireFaces_->count() - 1;
        if (row < 0) return;
        delete fireFaces_->takeItem(row);
        fireFaceIds_.erase(fireFaceIds_.begin() + row);
        refreshState();
    });
    showRows();
}

void StructuralStudyPanel::setFire(int standard, double durationS, int surface, double emissivity, double stepS, bool operating) {
    fireStandard_->setCurrentIndex(standard);
    fireClass_->setCurrentIndex(durationS == fea::kFireResistantS ? 0 : durationS == fea::kFireproofS ? 1 : 2);
    fireDuration_->setValue(durationS / 60.0);
    fireSurface_->setCurrentIndex(surface);
    fireEmissivity_->setValue(emissivity);
    fireStep_->setValue(stepS);
    climateOperating_->setChecked(operating);
}

QString StructuralStudyPanel::addFlameFaceFromSelection() {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) return tr("Сначала выберите грань в окне модели.");
    if (!bodyId_.empty() && selected->first != bodyId_) return tr("Грань другого тела: вариант относится к одному телу.");
    bodyId_ = selected->first;
    reloadFaces();
    if (face(selected->second) == nullptr) return tr("Грань не найдена у тела — обновите выбор.");
    if (std::find(fireFaceIds_.begin(), fireFaceIds_.end(), selected->second) != fireFaceIds_.end()) return tr("Эта грань уже под пламенем.");
    fireFaceIds_.push_back(selected->second);
    fireFaces_->addItem(QString::fromStdString(faceIndexId(selected->second)));
    selectionChanged();
    return {};
}

Result<fea::StructuralJob> StructuralStudyPanel::buildFireJob() const {
    auto invalid = [](const QString& why) { return Result<fea::StructuralJob>::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    if (bodyId_.empty()) return invalid(tr("Выберите грань детали под пламенем."));
    reloadFaces();
    fea::StructuralJob job;
    job.analysis = fea::StructuralAnalysis::Fire;
    job.geometryFormat = "brep";
    job.geometryPath = "part.brep";
    job.materialId = material_->currentData().toString().toStdString();
    job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
    if (job.loadCase.name.empty()) job.loadCase.name = tr("Огнестойкость").toStdString();
    for (const auto& item : items_) {
        if (face(item.faceId) == nullptr) {
            return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте её.").arg(QString::fromStdString(faceIndexId(item.faceId))));
        }
        const std::string faceIndex = faceIndexId(item.faceId);
        switch (item.kind) {
        case ItemKind::Support: job.loadCase.supports.push_back({faceIndex, item.fixed}); break;
        case ItemKind::Force: job.loadCase.forces.push_back({faceIndex, item.forceN}); break;
        case ItemKind::Pressure: job.loadCase.pressures.push_back({faceIndex, item.pressurePa}); break;
        case ItemKind::Exclusion: job.loadCase.stressExclusions.push_back({faceIndex, item.distanceM}); break;
        }
    }
    job.loadCase.bodyAccelerationMps2 = fea::Vec3{accelerationX_->value(), accelerationY_->value(), accelerationZ_->value()} * kStandardGravity;
    auto& f = job.fire;
    f.standard = fireStandard_->currentIndex() == 0 ? fea::FireStandard::Iso2685 : fea::FireStandard::Ac20135;
    f.durationS = fireClass_->currentIndex() == 0 ? fea::kFireResistantS : fireClass_->currentIndex() == 1 ? fea::kFireproofS : fireDuration_->value() * 60.0;
    for (const auto& id : fireFaceIds_) {
        if (face(id) == nullptr) return invalid(tr("Грань под пламенем больше не существует."));
        f.flameFaces.push_back(faceIndexId(id));
    }
    f.surfaceEmissivity = fireSurface_->currentIndex() == 0 ? 0.3 : fireSurface_->currentIndex() == 1 ? 0.7 : fireEmissivity_->value();
    f.stepS = fireStep_->value();
    f.operating = climateOperating_->isChecked();
    const auto components = equipment();
    if (!components.isOk()) return invalid(QString::fromStdString(components.error().message));
    f.components = components.value();
    const bool loaded = !job.loadCase.forces.empty() || !job.loadCase.pressures.empty() || fea::length(job.loadCase.bodyAccelerationMps2) > 0.0;
    if (f.flameFaces.empty()) return invalid(tr("Нет граней под пламенем: выберите грань → «Выбранная грань — под пламя»."));
    if (loaded && job.loadCase.supports.empty()) return invalid(tr("Нагрузки без опор: закрепите деталь."));
    if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
    if (!fea::hotMaterial(*job.materialId)) {
        return invalid(tr("Нет данных о материале при нагреве: огнестойкость считается для алюминия 6061-T6 и 7075-T6 (EN 1999-1-2)."));
    }
    if (!(f.durationS > 0.0)) return invalid(tr("Не задана длительность воздействия."));
    if (!(f.surfaceEmissivity > 0.0)) return invalid(tr("Не задана излучательная способность поверхности."));
    if (!(f.stepS > 0.0)) return invalid(tr("Не задан шаг по времени."));
    if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
    job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
    job.settings.refinementFactor = refinement_->value();
    job.resultPath = "result.json";
    job.fieldPath = "field.json";
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::buildLightningGroup(QVBoxLayout* layout) {
    lightningGroup_ = new QWidget;
    lightningForm_ = new QFormLayout(lightningGroup_);
    auto* form = lightningForm_;
    form->setContentsMargins(0, 0, 0, 0);
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

    const std::array<QString, 4> names{tr("A — 200 кА, первый удар"), tr("B — 2 кА, промежуточный"), tr("C — длительный ток, 200 Кл"),
                                       tr("D — 100 кА, повторный удар")};
    auto* componentBox = new QWidget;
    auto* componentLayout = new QVBoxLayout(componentBox);
    componentLayout->setContentsMargins(0, 0, 0, 0);
    for (std::size_t i = 0; i < lightningComponents_.size(); ++i) {
        lightningComponents_[i] = new QCheckBox(names[i]);
        lightningComponents_[i]->setChecked(i < 3); // A + B + C: the zone 1A sequence
        componentLayout->addWidget(lightningComponents_[i]);
    }
    form->addRow(tr("Составляющие"), componentBox);
    componentBox->setToolTip(tr("Составляющие тока по SAE ARP5412; прикладываются в порядке A, B, C, D, температура переносится между ними."));

    auto faceList = [&](QListWidget*& list, const QString& label, const QString& add, const QString& tip, std::vector<std::string>& ids) {
        list = new QListWidget;
        list->setMinimumHeight(48);
        auto* buttons = new QHBoxLayout;
        auto* addButton = new QPushButton(add);
        auto* removeButton = new QPushButton(tr("Убрать"));
        buttons->addWidget(addButton);
        buttons->addWidget(removeButton);
        auto* box = new QWidget;
        auto* boxLayout = new QVBoxLayout(box);
        boxLayout->setContentsMargins(0, 0, 0, 0);
        boxLayout->addWidget(list);
        boxLayout->addLayout(buttons);
        box->setToolTip(tip);
        form->addRow(label, box);
        QListWidget* captured = list;
        std::vector<std::string>* capturedIds = &ids;
        connect(removeButton, &QPushButton::clicked, this, [this, captured, capturedIds]() {
            const int row = captured->currentRow() >= 0 ? captured->currentRow() : captured->count() - 1;
            if (row < 0) return;
            delete captured->takeItem(row);
            capturedIds->erase(capturedIds->begin() + row);
            if (runButton_ != nullptr) refreshState();
        });
        return addButton;
    };
    auto* addAttachment = faceList(lightningAttachment_, tr("Привязка дуги"), tr("Выбранная грань — привязка"),
                                   tr("Грань, куда бьёт дуга. Размер корня дуги здесь — это площадь выбранных граней: чем крупнее грань, "
                                      "тем мягче результат. Результат сообщает эквивалентный радиус."),
                                   lightningAttachmentIds_);
    auto* addGround = faceList(lightningGround_, tr("Отвод тока"), tr("Выбранная грань — отвод"),
                               tr("Грани, которыми деталь соединена с конструкцией: через них ток уходит. Нулевой потенциал."), lightningGroundIds_);
    connect(addAttachment, &QPushButton::clicked, this, [this]() {
        const QString problem = addAttachmentFaceFromSelection();
        if (!problem.isEmpty()) status_->setText(problem);
    });
    connect(addGround, &QPushButton::clicked, this, [this]() {
        const QString problem = addGroundFaceFromSelection();
        if (!problem.isEmpty()) status_->setText(problem);
    });

    lightningPolarity_ = new QComboBox;
    lightningPolarity_->addItems({tr("Анод, 10 В·I (ONERA AL05-09)"), tr("Катод, 24 В·I — худший случай")});
    form->addRow(tr("Полярность привязки"), lightningPolarity_);
    lightningCurrent_ = new QDoubleSpinBox;
    lightningCurrent_->setRange(0.0, 1000.0);
    lightningCurrent_->setDecimals(0);
    lightningCurrent_->setSuffix(tr(" А"));
    lightningCurrent_->setSpecialValueText(tr("не задано"));
    lightningCurrent_->setValue(400.0);
    lightningCurrent_->setToolTip(tr("Ток составляющей C: стандарт допускает 200–800 А, заряд 200 Кл ± 20 % набирается длительностью."));
    form->addRow(tr("Ток составляющей C"), lightningCurrent_);
    lightningSurface_ = new QComboBox;
    lightningSurface_->addItems({tr("Чистая, ε = 0.3 (EN 1999-1-2)"), tr("Окрашенная или закопчённая, ε = 0.7"), tr("Своя ε")});
    form->addRow(tr("Поверхность"), lightningSurface_);
    lightningEmissivity_ = new QDoubleSpinBox;
    lightningEmissivity_->setRange(0.0, 1.0);
    lightningEmissivity_->setDecimals(2);
    lightningEmissivity_->setSpecialValueText(tr("не задано"));
    form->addRow(tr("ε"), lightningEmissivity_);
    lightningSteps_ = new QSpinBox;
    lightningSteps_->setRange(20, 20000);
    lightningSteps_->setValue(500);
    lightningSteps_->setToolTip(tr("Шагов на каждую составляющую. Ошибка шага измеряется: грубая сетка пересчитывается вдвое мельче."));
    form->addRow(tr("Шагов на составляющую"), lightningSteps_);

    auto* note = new QLabel(tr("Нужен материал с удельным сопротивлением и данными при нагреве (EN 1999-1-2: алюминий 6061-T6, 7075-T6). "
                               "Плазма дуги, плавление и унос металла не моделируются: расчёт останавливается в момент прожога. "
                               "Сопротивление берётся при 20 °C."));
    note->setWordWrap(true);
    form->addRow(note);
    layout->addWidget(lightningGroup_);

    auto showRows = [this]() {
        lightningForm_->setRowVisible(lightningEmissivity_, lightningSurface_->currentIndex() == 2);
        lightningForm_->setRowVisible(lightningCurrent_, lightningComponents_[2]->isChecked());
        if (runButton_ != nullptr) refreshState();
    };
    connect(lightningSurface_, qOverload<int>(&QComboBox::currentIndexChanged), this, showRows);
    connect(lightningPolarity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
    for (QCheckBox* box : lightningComponents_) connect(box, &QCheckBox::toggled, this, showRows);
    for (QDoubleSpinBox* box : {lightningCurrent_, lightningEmissivity_})
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    connect(lightningSteps_, qOverload<int>(&QSpinBox::valueChanged), this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
    showRows();
}

void StructuralStudyPanel::setLightning(const std::vector<fea::LightningComponent>& components, int polarity, double continuingCurrentA, int surface,
                                        double emissivity, int stepsPerComponent) {
    const std::array<fea::LightningComponent, 4> order{fea::LightningComponent::A, fea::LightningComponent::B, fea::LightningComponent::C,
                                                       fea::LightningComponent::D};
    for (std::size_t i = 0; i < order.size(); ++i)
        lightningComponents_[i]->setChecked(std::find(components.begin(), components.end(), order[i]) != components.end());
    lightningPolarity_->setCurrentIndex(polarity);
    lightningCurrent_->setValue(continuingCurrentA);
    lightningSurface_->setCurrentIndex(surface);
    lightningEmissivity_->setValue(emissivity);
    lightningSteps_->setValue(stepsPerComponent);
}

QString StructuralStudyPanel::addAttachmentFaceFromSelection() {
    return addLightningFace(lightningAttachment_, lightningAttachmentIds_, true);
}

QString StructuralStudyPanel::addGroundFaceFromSelection() {
    return addLightningFace(lightningGround_, lightningGroundIds_, false);
}

QString StructuralStudyPanel::addLightningFace(QListWidget* list, std::vector<std::string>& ids, bool attachment) {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) return tr("Сначала выберите грань в окне модели.");
    if (!bodyId_.empty() && selected->first != bodyId_) return tr("Грань другого тела: вариант относится к одному телу.");
    bodyId_ = selected->first;
    reloadFaces();
    if (face(selected->second) == nullptr) return tr("Грань не найдена у тела — обновите выбор.");
    if (std::find(ids.begin(), ids.end(), selected->second) != ids.end()) {
        return attachment ? tr("Эта грань уже привязка дуги.") : tr("Эта грань уже отводит ток.");
    }
    const auto& other = attachment ? lightningGroundIds_ : lightningAttachmentIds_;
    if (std::find(other.begin(), other.end(), selected->second) != other.end()) {
        return tr("Эта грань уже назначена другой ролью: ток не может входить и выходить через одну грань.");
    }
    ids.push_back(selected->second);
    list->addItem(QString::fromStdString(faceIndexId(selected->second)));
    selectionChanged();
    return {};
}

Result<fea::StructuralJob> StructuralStudyPanel::buildLightningJob() const {
    auto invalid = [](const QString& why) { return Result<fea::StructuralJob>::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    if (bodyId_.empty()) return invalid(tr("Выберите грань детали, куда бьёт дуга."));
    reloadFaces();
    fea::StructuralJob job;
    job.analysis = fea::StructuralAnalysis::Lightning;
    job.geometryFormat = "brep";
    job.geometryPath = "part.brep";
    job.materialId = material_->currentData().toString().toStdString();
    job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
    if (job.loadCase.name.empty()) job.loadCase.name = tr("Молния").toStdString();
    for (const auto& item : items_) {
        if (item.kind != ItemKind::Support) continue;
        if (face(item.faceId) == nullptr) {
            return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте её.").arg(QString::fromStdString(faceIndexId(item.faceId))));
        }
        job.loadCase.supports.push_back({faceIndexId(item.faceId), item.fixed});
    }
    auto& l = job.lightning;
    const std::array<fea::LightningComponent, 4> order{fea::LightningComponent::A, fea::LightningComponent::B, fea::LightningComponent::C,
                                                       fea::LightningComponent::D};
    for (std::size_t i = 0; i < order.size(); ++i)
        if (lightningComponents_[i]->isChecked()) l.components.push_back(order[i]);
    for (const auto& id : lightningAttachmentIds_) {
        if (face(id) == nullptr) return invalid(tr("Грань привязки дуги больше не существует."));
        l.attachmentFaces.push_back(faceIndexId(id));
    }
    for (const auto& id : lightningGroundIds_) {
        if (face(id) == nullptr) return invalid(tr("Грань отвода тока больше не существует."));
        l.groundFaces.push_back(faceIndexId(id));
    }
    l.polarity = lightningPolarity_->currentIndex() == 1 ? fea::ArcPolarity::Cathode : fea::ArcPolarity::Anode;
    l.continuingCurrentA = lightningCurrent_->value();
    l.surfaceEmissivity = lightningSurface_->currentIndex() == 0 ? 0.3 : lightningSurface_->currentIndex() == 1 ? 0.7 : lightningEmissivity_->value();
    l.stepsPerComponent = lightningSteps_->value();
    const auto components = equipment();
    if (!components.isOk()) return invalid(QString::fromStdString(components.error().message));
    l.equipment = components.value();
    if (l.components.empty()) return invalid(tr("Не выбрана ни одна составляющая тока."));
    if (l.attachmentFaces.empty()) return invalid(tr("Нет грани привязки дуги: выберите грань → «Выбранная грань — привязка»."));
    if (l.groundFaces.empty()) return invalid(tr("Нет граней отвода тока: ток должен куда-то уходить."));
    if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
    if (const auto material = fea::findMaterial(*job.materialId); material && !material->electricalResistivityOhmM) {
        return invalid(tr("Нет данных: удельное электрическое сопротивление материала. Прямое воздействие молнии считается для алюминия 6061-T6 и 7075-T6."));
    }
    if (!fea::hotMaterial(*job.materialId)) {
        return invalid(tr("Нет данных о материале при нагреве: прожог считается для алюминия 6061-T6 и 7075-T6 (EN 1999-1-2)."));
    }
    const bool hasC = std::find(l.components.begin(), l.components.end(), fea::LightningComponent::C) != l.components.end();
    if (hasC && !(l.continuingCurrentA >= 200.0 && l.continuingCurrentA <= 800.0)) {
        return invalid(tr("Ток составляющей C вне стандарта: SAE ARP5412 допускает 200–800 А."));
    }
    if (!(l.surfaceEmissivity > 0.0)) return invalid(tr("Не задана излучательная способность поверхности."));
    if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
    job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
    job.settings.refinementFactor = refinement_->value();
    job.resultPath = "result.json";
    job.fieldPath = "field.json";
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::buildEmcGroup(QVBoxLayout* layout) {
    emcGroup_ = new QWidget;
    emcForm_ = new QFormLayout(emcGroup_);
    auto* form = emcForm_;
    form->setContentsMargins(0, 0, 0, 0);
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

    emcIncidence_ = new QComboBox;
    emcIncidence_->addItems({"+X", "−X", "+Y", "−Y", "+Z", "−Z"});
    emcIncidence_->setToolTip(tr("Откуда приходит волна. Падение прямое; другое направление — другой расчёт."));
    form->addRow(tr("Приход волны"), emcIncidence_);
    emcPolarization_ = new QComboBox;
    emcPolarization_->addItems({"X", "Y", "Z"});
    emcPolarization_->setCurrentIndex(2);
    emcPolarization_->setToolTip(tr("Направление электрического поля волны; должно быть поперечным приходу."));
    form->addRow(tr("Поляризация"), emcPolarization_);

    emcLevel_ = new QComboBox;
    for (const auto& level : em::radiatedSusceptibilityLevels()) emcLevel_->addItem(QString::fromStdString(level.description), QString::fromStdString(level.id));
    emcLevel_->addItem(tr("Своё поле, В/м"), QString());
    emcLevel_->setCurrentIndex(0);
    form->addRow(tr("Уровень"), emcLevel_);
    emcField_ = new QDoubleSpinBox;
    emcField_->setRange(0.0, 10000.0);
    emcField_->setDecimals(1);
    emcField_->setSuffix(tr(" В/м"));
    emcField_->setSpecialValueText(tr("не задано"));
    emcField_->setToolTip(tr("Таблицы уровней RTCA DO-160G §20 в решателе нет — для неё задайте поле числом."));
    form->addRow(tr("Поле"), emcField_);

    emcLow_ = new QDoubleSpinBox;
    emcLow_->setRange(0.0, 40000.0);
    emcLow_->setDecimals(1);
    emcLow_->setSuffix(tr(" МГц"));
    emcLow_->setSpecialValueText(tr("не задано"));
    emcLow_->setValue(500.0);
    form->addRow(tr("Частота от"), emcLow_);
    emcHigh_ = new QDoubleSpinBox;
    emcHigh_->setRange(0.0, 40000.0);
    emcHigh_->setDecimals(1);
    emcHigh_->setSuffix(tr(" МГц"));
    emcHigh_->setSpecialValueText(tr("не задано"));
    emcHigh_->setValue(2000.0);
    emcHigh_->setToolTip(tr("Верхняя частота определяет и шаг сетки: на длину волны нужно хотя бы десять ячеек."));
    form->addRow(tr("до"), emcHigh_);
    emcPoints_ = new QSpinBox;
    emcPoints_->setRange(2, 200);
    emcPoints_->setValue(8);
    emcPoints_->setToolTip(tr("Сколько частот в развёртке. Спектр снимается за один прогон, так что цена почти не растёт."));
    form->addRow(tr("Частот в развёртке"), emcPoints_);

    emcTable_ = new QTableWidget(0, 5);
    emcTable_->setHorizontalHeaderLabels({tr("Оборудование"), tr("x, мм"), tr("y, мм"), tr("z, мм"), tr("стойкость, В/м")});
    emcTable_->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
    emcTable_->verticalHeader()->setVisible(false);
    emcTable_->setMinimumHeight(110);
    emcTable_->setToolTip(tr("Точки внутри корпуса, в координатах детали. Стойкость — из паспорта оборудования; "
                             "пустая ячейка означает, что сравнивать не с чем, и вердикт будет не выше WARNING."));
    auto* buttons = new QHBoxLayout;
    auto* addPoint = new QPushButton(tr("Точка от выбранной грани…"));
    auto* removePoint = new QPushButton(tr("Удалить точку"));
    buttons->addWidget(addPoint);
    buttons->addWidget(removePoint);
    auto* box = new QWidget;
    auto* boxLayout = new QVBoxLayout(box);
    boxLayout->setContentsMargins(0, 0, 0, 0);
    boxLayout->addWidget(emcTable_);
    boxLayout->addLayout(buttons);
    form->addRow(tr("Оборудование внутри"), box);

    auto* note = new QLabel(tr("Металл идеальный: сквозь стенки не проходит ничего, результат определяют отверстия, щели и стыки. "
                               "Корпус считается пустым и без потерь, поэтому на собственных частотах полости экранирование — "
                               "оценка снизу. Кабели не моделируются (это CS114/CS116)."));
    note->setWordWrap(true);
    form->addRow(note);
    layout->addWidget(emcGroup_);

    auto showRows = [this]() {
        emcForm_->setRowVisible(emcField_, emcLevel_->currentData().toString().isEmpty());
        if (runButton_ != nullptr) refreshState();
    };
    connect(emcLevel_, qOverload<int>(&QComboBox::currentIndexChanged), this, showRows);
    for (QComboBox* combo : {emcIncidence_, emcPolarization_})
        connect(combo, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    for (QDoubleSpinBox* spin : {emcField_, emcLow_, emcHigh_})
        connect(spin, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    connect(emcPoints_, qOverload<int>(&QSpinBox::valueChanged), this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
    connect(emcTable_, &QTableWidget::itemChanged, this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
    connect(addPoint, &QPushButton::clicked, this, [this]() {
        const QString problem = addEmcEquipmentOnSelectedFace(tr("оборудование"), 10.0, 0.0);
        if (!problem.isEmpty()) status_->setText(problem);
    });
    connect(removePoint, &QPushButton::clicked, this, [this]() {
        const int row = emcTable_->currentRow() >= 0 ? emcTable_->currentRow() : emcTable_->rowCount() - 1;
        if (row < 0) return;
        emcTable_->removeRow(row);
        refreshState();
    });
    showRows();
}

void StructuralStudyPanel::setEmc(int incidence, int polarization, int level, double fieldVm, double lowMHz, double highMHz, int points) {
    emcIncidence_->setCurrentIndex(incidence);
    emcPolarization_->setCurrentIndex(polarization);
    emcLevel_->setCurrentIndex(level);
    emcField_->setValue(fieldVm);
    emcLow_->setValue(lowMHz);
    emcHigh_->setValue(highMHz);
    emcPoints_->setValue(points);
}

QString StructuralStudyPanel::addEmcEquipmentOnSelectedFace(const QString& name, double offsetMm, double immunityVm) {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) return tr("Сначала выберите грань в окне модели.");
    if (!bodyId_.empty() && selected->first != bodyId_) return tr("Грань другого тела: вариант относится к одному телу.");
    bodyId_ = selected->first;
    reloadFaces();
    const auto* reference = face(selected->second);
    if (reference == nullptr) return tr("Грань не найдена у тела — обновите выбор.");
    // The normal points out of the solid, so from the inner face of a shell it points into the
    // cavity: one step along it lands the probe inside the box.
    const double offset = offsetMm / 1e3;
    const double x = reference->origin.x + reference->normal.x * offset;
    const double y = reference->origin.y + reference->normal.y * offset;
    const double z = reference->origin.z + reference->normal.z * offset;
    const QSignalBlocker block(emcTable_);
    const int row = emcTable_->rowCount();
    emcTable_->insertRow(row);
    emcTable_->setItem(row, 0, new QTableWidgetItem(name));
    emcTable_->setItem(row, 1, new QTableWidgetItem(QString::number(x * 1e3, 'f', 2)));
    emcTable_->setItem(row, 2, new QTableWidgetItem(QString::number(y * 1e3, 'f', 2)));
    emcTable_->setItem(row, 3, new QTableWidgetItem(QString::number(z * 1e3, 'f', 2)));
    emcTable_->setItem(row, 4, new QTableWidgetItem(immunityVm > 0.0 ? QString::number(immunityVm, 'g', 6) : QString()));
    selectionChanged();
    return {};
}

Result<std::vector<fea::EmcProbe>> StructuralStudyPanel::emcEquipment() const {
    using R = Result<std::vector<fea::EmcProbe>>;
    auto invalid = [](const QString& why) { return R::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    std::vector<fea::EmcProbe> list;
    for (int row = 0; row < emcTable_->rowCount(); ++row) {
        auto text = [&](int column) {
            return emcTable_->item(row, column) ? emcTable_->item(row, column)->text().trimmed().replace(',', '.') : QString();
        };
        fea::EmcProbe probe;
        probe.name = text(0).toStdString();
        if (probe.name.empty()) return invalid(tr("Оборудование, строка %1: нет названия.").arg(row + 1));
        double* coordinate[3] = {&probe.x, &probe.y, &probe.z};
        for (int axis = 0; axis < 3; ++axis) {
            bool ok = false;
            const double value = text(axis + 1).toDouble(&ok);
            if (!ok) return invalid(tr("Оборудование «%1»: координаты — числа в миллиметрах.").arg(text(0)));
            *coordinate[axis] = value / 1e3;
        }
        if (!text(4).isEmpty()) {
            bool ok = false;
            probe.immunityVm = text(4).toDouble(&ok);
            if (!ok || probe.immunityVm <= 0.0) return invalid(tr("Оборудование «%1»: стойкость — число больше нуля, В/м.").arg(text(0)));
        }
        list.push_back(std::move(probe));
    }
    return R::ok(std::move(list));
}

Result<fea::StructuralJob> StructuralStudyPanel::buildEmcJob() const {
    auto invalid = [](const QString& why) { return Result<fea::StructuralJob>::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    if (bodyId_.empty()) return invalid(tr("Выберите грань корпуса: расчёт относится к телу целиком."));
    reloadFaces();
    fea::StructuralJob job;
    job.analysis = fea::StructuralAnalysis::Emc;
    job.geometryFormat = "brep";
    job.geometryPath = "part.brep";
    job.materialId = material_->currentData().toString().toStdString();
    job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
    if (job.loadCase.name.empty()) job.loadCase.name = tr("Экранирование").toStdString();
    auto& e = job.emc;
    e.incidence = static_cast<em::Axis>(emcIncidence_->currentIndex() / 2);
    e.forward = emcIncidence_->currentIndex() % 2 == 0;
    e.polarization = static_cast<em::Axis>(emcPolarization_->currentIndex());
    e.levelId = emcLevel_->currentData().toString().toStdString();
    e.fieldVm = emcField_->value();
    e.lowHz = emcLow_->value() * 1e6;
    e.highHz = emcHigh_->value() * 1e6;
    e.points = emcPoints_->value();
    const auto equipment = emcEquipment();
    if (!equipment.isOk()) return invalid(QString::fromStdString(equipment.error().message));
    e.equipment = equipment.value();
    if (e.polarization == e.incidence) return invalid(tr("Поляризация вдоль прихода волны: она должна быть поперечной."));
    if (e.equipment.empty()) return invalid(tr("Нет оборудования внутри корпуса: добавьте хотя бы одну точку."));
    if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
    if (e.levelId.empty() && !(e.fieldVm > 0.0)) return invalid(tr("Не задано поле: выберите уровень стандарта или задайте В/м."));
    if (!(e.lowHz > 0.0) || !(e.highHz > e.lowHz)) return invalid(tr("Не задан диапазон частот."));
    if (!e.levelId.empty()) {
        const auto* level = em::radiatedLevel(e.levelId);
        if (level != nullptr && (e.lowHz < level->lowHz || e.highHz > level->highHz)) {
            return invalid(tr("Развёртка выходит за диапазон уровня стандарта (%1–%2 МГц).")
                               .arg(level->lowHz / 1e6, 0, 'g', 4)
                               .arg(level->highHz / 1e6, 0, 'g', 4));
        }
    }
    if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер ячейки сетки (можно «Предложить»)."));
    job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
    job.settings.refinementFactor = refinement_->value();
    job.resultPath = "result.json";
    job.fieldPath = "field.json";
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::buildIcingGroup(QVBoxLayout* layout) {
    icingGroup_ = new QWidget;
    icingForm_ = new QFormLayout(icingGroup_);
    auto* form = icingForm_;
    form->setContentsMargins(0, 0, 0, 0);
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

    auto axisBox = [](int current) {
        auto* box = new QComboBox;
        box->addItems({"X", "Y", "Z"});
        box->setCurrentIndex(current);
        return box;
    };
    icingFlowAxis_ = axisBox(0);
    form->addRow(tr("Поток вдоль"), icingFlowAxis_);
    icingSpanAxis_ = axisBox(1);
    icingSpanAxis_->setToolTip(tr("Ось размаха: сечения режутся поперёк неё."));
    form->addRow(tr("Размах вдоль"), icingSpanAxis_);
    auto number = [&](const QString& label, double low, double high, int decimals, const QString& suffix, const QString& special = QString()) {
        auto* box = new QDoubleSpinBox;
        box->setRange(low, high);
        box->setDecimals(decimals);
        box->setSuffix(suffix);
        if (!special.isEmpty()) box->setSpecialValueText(special);
        form->addRow(label, box);
        return box;
    };
    icingAngle_ = number(tr("Угол атаки"), -30.0, 30.0, 1, tr(" °"));
    icingCondition_ = new QComboBox;
    icingCondition_->addItem(tr("Взлётное обледенение (14 CFR 25 Прил. C): 0.35 г/м³, 20 мкм, −9 °C"));
    icingCondition_->addItem(tr("Своё условие"));
    icingCondition_->setToolTip(tr("Конверты непрерывного и перемежающегося максимума заданы в регламенте кривыми, "
                                   "и в решателе их нет: задайте числа."));
    form->addRow(tr("Условие"), icingCondition_);
    icingTemperature_ = number(tr("Температура"), -40.0, 0.0, 1, tr(" °C"));
    icingTemperature_->setValue(-9.0);
    icingWater_ = number(tr("Водность"), 0.0, 5.0, 2, tr(" г/м³"), tr("не задано"));
    icingWater_->setValue(0.35);
    icingDroplet_ = number(tr("Капли"), 0.0, 500.0, 1, tr(" мкм"), tr("не задано"));
    icingDroplet_->setValue(20.0);
    icingSpeed_ = number(tr("Скорость"), 0.0, 400.0, 1, tr(" м/с"), tr("не задана"));
    icingSpeed_->setValue(60.0);
    icingDuration_ = number(tr("В облаке"), 0.0, 600.0, 1, tr(" мин"), tr("не задано"));
    icingDuration_->setValue(10.0);
    icingLimit_ = number(tr("Допустимый лёд"), 0.0, 200.0, 2, tr(" мм"), tr("нет данных"));
    icingTarget_ = number(tr("Обогрев держит"), 0.0, 60.0, 1, tr(" °C"), tr("без обогрева"));
    icingBudget_ = number(tr("Бюджет обогрева"), 0.0, 100000.0, 0, tr(" Вт"), tr("нет данных"));

    icingStations_ = new QSpinBox;
    icingStations_->setRange(1, 40);
    icingStations_->setValue(3);
    icingStations_->setToolTip(tr("Сколько сечений по размаху. Между ними результат считается постоянным."));
    form->addRow(tr("Сечений"), icingStations_);
    icingPanels_ = new QSpinBox;
    icingPanels_->setRange(60, 4000);
    icingPanels_->setValue(240);
    form->addRow(tr("Панелей в сечении"), icingPanels_);
    icingTrajectories_ = new QSpinBox;
    icingTrajectories_->setRange(20, 4000);
    icingTrajectories_->setValue(201);
    icingTrajectories_->setToolTip(tr("Капель в веере. Местная эффективность захвата берётся между соседними траекториями."));
    form->addRow(tr("Траекторий"), icingTrajectories_);

    auto* note = new QLabel(tr("Лёд не меняет обтекание: толщина — это скорость первого мгновения, продлённая на всё время. "
                               "Стекающая вода не прослеживается вдоль поверхности, сечения плоские, шероховатость льда не моделируется. "
                               "Капли крупнее 50 мкм — это Приложение O, здесь их дробление не считается."));
    note->setWordWrap(true);
    form->addRow(note);
    layout->addWidget(icingGroup_);

    auto showRows = [this]() {
        const bool own = icingCondition_->currentIndex() == 1;
        icingForm_->setRowVisible(icingTemperature_, own);
        icingForm_->setRowVisible(icingWater_, own);
        icingForm_->setRowVisible(icingDroplet_, own);
        icingForm_->setRowVisible(icingBudget_, icingTarget_->value() > 0.0);
        if (runButton_ != nullptr) refreshState();
    };
    connect(icingCondition_, qOverload<int>(&QComboBox::currentIndexChanged), this, showRows);
    for (QComboBox* box : {icingFlowAxis_, icingSpanAxis_})
        connect(box, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    for (QDoubleSpinBox* box : {icingAngle_, icingTemperature_, icingWater_, icingDroplet_, icingSpeed_, icingDuration_, icingTarget_, icingBudget_, icingLimit_})
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this, showRows]() { showRows(); });
    for (QSpinBox* box : {icingStations_, icingPanels_, icingTrajectories_})
        connect(box, qOverload<int>(&QSpinBox::valueChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    showRows();
}

void StructuralStudyPanel::setIcing(int flowAxis, int spanAxis, double angleOfAttackDeg, int condition, double temperatureC, double lwcGm3,
                                    double dropletMicrons, double airspeedMps, double durationMin, double antiIceTargetC, double antiIceBudgetW,
                                    double maximumIceMm) {
    icingFlowAxis_->setCurrentIndex(flowAxis);
    icingSpanAxis_->setCurrentIndex(spanAxis);
    icingAngle_->setValue(angleOfAttackDeg);
    icingCondition_->setCurrentIndex(condition);
    icingTemperature_->setValue(temperatureC);
    icingWater_->setValue(lwcGm3);
    icingDroplet_->setValue(dropletMicrons);
    icingSpeed_->setValue(airspeedMps);
    icingDuration_->setValue(durationMin);
    icingTarget_->setValue(antiIceTargetC);
    icingBudget_->setValue(antiIceBudgetW);
    icingLimit_->setValue(maximumIceMm);
}

Result<fea::StructuralJob> StructuralStudyPanel::buildIcingJob() const {
    auto invalid = [](const QString& why) { return Result<fea::StructuralJob>::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    if (bodyId_.empty()) return invalid(tr("Выберите грань детали: расчёт относится к телу целиком."));
    reloadFaces();
    fea::StructuralJob job;
    job.analysis = fea::StructuralAnalysis::Icing;
    job.geometryFormat = "brep";
    job.geometryPath = "part.brep";
    job.materialId = material_->currentData().toString().toStdString();
    job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
    if (job.loadCase.name.empty()) job.loadCase.name = tr("Обледенение").toStdString();
    auto& i = job.icing;
    i.flowAxis = icingFlowAxis_->currentIndex();
    i.spanAxis = icingSpanAxis_->currentIndex();
    i.angleOfAttackRad = icingAngle_->value() * M_PI / 180.0;
    i.stations = icingStations_->value();
    i.panels = icingPanels_->value();
    i.trajectories = icingTrajectories_->value();
    i.refinementFactor = std::max(refinement_->value(), 1.2);
    i.surfaceElementSizeM = elementSize_->value() / 1e3;
    if (icingCondition_->currentIndex() == 0) {
        i.conditionId = "takeoffMaximum";
        i.condition = fea::takeoffMaximumIcing(icingSpeed_->value(), icingDuration_->value() * 60.0);
    } else {
        i.conditionId.clear();
        i.condition.temperatureK = icingTemperature_->value() + fea::kMeltingPointK;
        i.condition.lwcKgM3 = icingWater_->value() * 1e-3;
        i.condition.dropletDiameterM = icingDroplet_->value() * 1e-6;
        i.condition.airspeedMps = icingSpeed_->value();
        i.condition.durationS = icingDuration_->value() * 60.0;
        i.condition.source = tr("задано в панели").toStdString();
    }
    i.antiIceTargetK = icingTarget_->value() > 0.0 ? icingTarget_->value() + fea::kMeltingPointK : 0.0;
    i.antiIceBudgetW = icingBudget_->value();
    i.maximumIceThicknessM = icingLimit_->value() * 1e-3;
    if (i.flowAxis == i.spanAxis) return invalid(tr("Поток и размах вдоль одной оси: они должны различаться."));
    if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
    if (!(i.condition.airspeedMps > 0.0)) return invalid(tr("Не задана скорость полёта."));
    if (!(i.condition.durationS > 0.0)) return invalid(tr("Не задана длительность полёта в облаке."));
    if (!(i.condition.lwcKgM3 > 0.0)) return invalid(tr("Не задана водность облака."));
    if (!(i.condition.dropletDiameterM > 0.0)) return invalid(tr("Не задан размер капель."));
    if (i.condition.temperatureK >= fea::kMeltingPointK) return invalid(tr("Температура не ниже нуля: обледенения не будет."));
    if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер элемента поверхности (можно «Предложить»)."));
    job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
    job.settings.refinementFactor = refinement_->value();
    job.resultPath = "result.json";
    job.fieldPath = "field.json";
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::buildFlutterGroup(QVBoxLayout* layout) {
    flutterGroup_ = new QWidget;
    flutterForm_ = new QFormLayout(flutterGroup_);
    auto* form = flutterForm_;
    form->setContentsMargins(0, 0, 0, 0);
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

    auto axisBox = [](int current) {
        auto* box = new QComboBox;
        box->addItems({"X", "Y", "Z"});
        box->setCurrentIndex(current);
        return box;
    };
    flutterFlowAxis_ = axisBox(0);
    form->addRow(tr("Поток вдоль"), flutterFlowAxis_);
    flutterSpanAxis_ = axisBox(1);
    flutterSpanAxis_->setToolTip(tr("Ось размаха: моды читаются по полосам поперёк неё."));
    form->addRow(tr("Размах вдоль"), flutterSpanAxis_);
    flutterStations_ = new QSpinBox;
    flutterStations_->setRange(4, 100);
    flutterStations_->setValue(12);
    flutterStations_->setToolTip(tr("Полос по размаху: на каждой аэродинамика своя, но двумерная."));
    form->addRow(tr("Полос"), flutterStations_);
    auto number = [&](const QString& label, double low, double high, int decimals, const QString& suffix, const QString& special = QString()) {
        auto* box = new QDoubleSpinBox;
        box->setRange(low, high);
        box->setDecimals(decimals);
        box->setSuffix(suffix);
        if (!special.isEmpty()) box->setSpecialValueText(special);
        form->addRow(label, box);
        return box;
    };
    flutterDensity_ = number(tr("Плотность воздуха"), 0.0, 5.0, 4, tr(" кг/м³"), tr("не задана"));
    flutterDensity_->setValue(1.225);
    flutterDamping_ = number(tr("Конструкционное g"), 0.0, 0.5, 3, QString(), tr("нет"));
    flutterDive_ = number(tr("Скорость пикирования V_D"), 0.0, 1000.0, 1, tr(" м/с"), tr("нет данных"));
    flutterDive_->setToolTip(tr("25.629: аппарат должен быть свободен от флаттера до 1.15·V_D. Без неё вердикт не выше WARNING."));
    flutterLow_ = number(tr("Развёртка от"), 0.0, 2000.0, 1, tr(" м/с"), tr("не задана"));
    flutterLow_->setValue(10.0);
    flutterHigh_ = number(tr("до"), 0.0, 2000.0, 1, tr(" м/с"), tr("не задана"));
    flutterHigh_->setValue(300.0);

    auto* note = new QLabel(tr("Полосовая теория и две моды: ни стреловидности, ни удлинения, ни концевых эффектов, ни руля, ни груза на крыле. "
                               "Аэродинамика Теодорсена несжимаема — выше M ≈ 0.6 трансзвуковой провал она не видит. "
                               "Корень должен быть закреплён опорой."));
    note->setWordWrap(true);
    form->addRow(note);
    layout->addWidget(flutterGroup_);

    for (QComboBox* box : {flutterFlowAxis_, flutterSpanAxis_})
        connect(box, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    for (QDoubleSpinBox* box : {flutterDensity_, flutterDamping_, flutterDive_, flutterLow_, flutterHigh_})
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    connect(flutterStations_, qOverload<int>(&QSpinBox::valueChanged), this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
}

void StructuralStudyPanel::setFlutter(int flowAxis, int spanAxis, int stations, double airDensityKgM3, double structuralDamping, double diveSpeedMps,
                                      double lowSpeedMps, double highSpeedMps) {
    flutterFlowAxis_->setCurrentIndex(flowAxis);
    flutterSpanAxis_->setCurrentIndex(spanAxis);
    flutterStations_->setValue(stations);
    flutterDensity_->setValue(airDensityKgM3);
    flutterDamping_->setValue(structuralDamping);
    flutterDive_->setValue(diveSpeedMps);
    flutterLow_->setValue(lowSpeedMps);
    flutterHigh_->setValue(highSpeedMps);
}

Result<fea::StructuralJob> StructuralStudyPanel::buildFlutterJob() const {
    auto invalid = [](const QString& why) { return Result<fea::StructuralJob>::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    if (bodyId_.empty()) return invalid(tr("Выберите грань корня: флаттер считается для закреплённой поверхности."));
    reloadFaces();
    fea::StructuralJob job;
    job.analysis = fea::StructuralAnalysis::Flutter;
    job.geometryFormat = "brep";
    job.geometryPath = "part.brep";
    job.materialId = material_->currentData().toString().toStdString();
    job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
    if (job.loadCase.name.empty()) job.loadCase.name = tr("Флаттер").toStdString();
    for (const auto& item : items_) {
        if (item.kind != ItemKind::Support) continue;
        if (face(item.faceId) == nullptr) {
            return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте опору.").arg(QString::fromStdString(faceIndexId(item.faceId))));
        }
        job.loadCase.supports.push_back({faceIndexId(item.faceId), item.fixed});
    }
    auto& f = job.flutter;
    f.flowAxis = flutterFlowAxis_->currentIndex();
    f.spanAxis = flutterSpanAxis_->currentIndex();
    f.stations = flutterStations_->value();
    f.airDensityKgM3 = flutterDensity_->value();
    f.structuralDamping = flutterDamping_->value();
    f.diveSpeedMps = flutterDive_->value();
    f.lowSpeedMps = flutterLow_->value();
    f.highSpeedMps = flutterHigh_->value();
    f.speeds = 300;
    if (f.flowAxis == f.spanAxis) return invalid(tr("Поток и размах вдоль одной оси: они должны различаться."));
    if (job.loadCase.supports.empty()) return invalid(tr("Нет опор: флаттер считается с закреплённым корнем."));
    if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
    if (!(f.airDensityKgM3 > 0.0)) return invalid(tr("Не задана плотность воздуха."));
    if (!(f.highSpeedMps > f.lowSpeedMps)) return invalid(tr("Не задана развёртка по скорости."));
    if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
    job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
    job.settings.refinementFactor = refinement_->value();
    job.resultPath = "result.json";
    job.fieldPath = "field.json";
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::buildBirdGroup(QVBoxLayout* layout) {
    birdGroup_ = new QWidget;
    birdForm_ = new QFormLayout(birdGroup_);
    auto* form = birdForm_;
    form->setContentsMargins(0, 0, 0, 0);
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

    auto* faceRow = new QWidget;
    auto* faceLayout = new QHBoxLayout(faceRow);
    faceLayout->setContentsMargins(0, 0, 0, 0);
    birdFaceButton_ = new QPushButton(tr("Грань удара"));
    birdFaceButton_->setToolTip(tr("Птица бьёт в эту грань. Давление распределяется по ней целиком: грань заметно больше самой птицы "
                                   "занижает местное напряжение, и расчёт об этом скажет."));
    birdFaceLabel_ = new QLabel(tr("не задана"));
    faceLayout->addWidget(birdFaceButton_);
    faceLayout->addWidget(birdFaceLabel_, 1);
    form->addRow(tr("Куда попадает"), faceRow);
    connect(birdFaceButton_, &QPushButton::clicked, this, [this]() {
        const QString problem = setBirdFaceFromSelection();
        if (!problem.isEmpty() && status_ != nullptr) status_->setText(problem);
    });

    birdDirection_ = new QComboBox;
    birdDirection_->addItems({"+X", "−X", "+Y", "−Y", "+Z", "−Z"});
    birdDirection_->setCurrentIndex(1);
    birdDirection_->setToolTip(tr("Куда птица толкает деталь — внутрь неё, а не наружу."));
    form->addRow(tr("Направление удара"), birdDirection_);

    auto number = [&](const QString& label, double low, double high, int decimals, const QString& suffix, double value) {
        auto* box = new QDoubleSpinBox;
        box->setRange(low, high);
        box->setDecimals(decimals);
        box->setSuffix(suffix);
        box->setValue(value);
        form->addRow(label, box);
        return box;
    };
    birdMass_ = number(tr("Масса птицы"), 0.01, 10.0, 2, tr(" кг"), 1.81);
    birdMass_->setToolTip(tr("25.571(e): 1.81 кг (4 фунта) на планер, 3.63 кг (8 фунтов) на оперение."));
    birdSpeed_ = number(tr("Скорость встречи"), 0.0, 400.0, 1, tr(" м/с"), 0.0);
    birdSpeed_->setSpecialValueText(tr("не задана"));
    birdSpeed_->setToolTip(tr("Скорость аппарата относительно птицы — крейсерская по правилу."));
    birdObliquity_ = number(tr("Угол встречи"), 5.0, 90.0, 1, tr(" °"), 90.0);
    birdObliquity_->setToolTip(tr("90° — в лоб. Косой удар работает только нормальной составляющей скорости."));
    birdDamping_ = number(tr("Демпфирование ζ"), 0.1, 20.0, 1, tr(" %"), 2.0);
    birdModes_ = new QSpinBox;
    birdModes_->setRange(1, 200);
    birdModes_->setValue(20);
    birdModes_->setToolTip(tr("Ударный фронт птицы короче любой моды детали: неудержанные учитываются статической поправкой, "
                              "и расчёт покажет, насколько это его допущение."));
    form->addRow(tr("Мод"), birdModes_);
    layout->addWidget(birdGroup_);

    connect(birdDirection_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
    for (QDoubleSpinBox* box : {birdMass_, birdSpeed_, birdObliquity_, birdDamping_}) {
        connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this]() {
            if (runButton_ != nullptr) refreshState();
        });
    }
    connect(birdModes_, qOverload<int>(&QSpinBox::valueChanged), this, [this]() {
        if (runButton_ != nullptr) refreshState();
    });
}

void StructuralStudyPanel::setBird(int direction, double massKg, double speedMps, double obliquityDeg, double dampingRatio, int modes) {
    birdDirection_->setCurrentIndex(direction);
    birdMass_->setValue(massKg);
    birdSpeed_->setValue(speedMps);
    birdObliquity_->setValue(obliquityDeg);
    birdDamping_->setValue(dampingRatio * 100.0);
    birdModes_->setValue(modes);
}

QString StructuralStudyPanel::setBirdFaceFromSelection() {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) return tr("Сначала выберите грань в окне модели.");
    if (!bodyId_.empty() && selected->first != bodyId_) return tr("Грань другого тела: вариант относится к одному телу.");
    bodyId_ = selected->first;
    reloadFaces();
    if (face(selected->second) == nullptr) return tr("Грань не найдена у тела — обновите выбор.");
    birdFaceId_ = selected->second;
    birdFaceLabel_->setText(QString::fromStdString(faceIndexId(birdFaceId_)));
    refreshState();
    return {};
}

Result<fea::StructuralJob> StructuralStudyPanel::buildBirdJob() const {
    auto invalid = [](const QString& why) { return Result<fea::StructuralJob>::fail({ErrorCode::InvalidArgument, why.toStdString()}); };
    if (bodyId_.empty()) return invalid(tr("Выберите грань детали: удар птицы считается по выбранной грани."));
    reloadFaces();
    fea::StructuralJob job;
    job.analysis = fea::StructuralAnalysis::Bird;
    job.geometryFormat = "brep";
    job.geometryPath = "part.brep";
    job.materialId = material_->currentData().toString().toStdString();
    job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
    if (job.loadCase.name.empty()) job.loadCase.name = tr("Удар птицы").toStdString();
    for (const auto& item : items_) {
        if (item.kind == ItemKind::Support) {
            if (face(item.faceId) == nullptr) {
                return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте опору.").arg(QString::fromStdString(faceIndexId(item.faceId))));
            }
            job.loadCase.supports.push_back({faceIndexId(item.faceId), item.fixed});
        } else if (item.kind == ItemKind::Exclusion) {
            if (face(item.faceId) == nullptr) continue;
            job.loadCase.stressExclusions.push_back({faceIndexId(item.faceId), item.distanceM});
        }
    }
    auto& b = job.bird;
    b.modeCount = birdModes_->value();
    b.dampingRatio = birdDamping_->value() / 100.0;
    const int axis = birdDirection_->currentIndex() / 2;
    const double sign = birdDirection_->currentIndex() % 2 == 0 ? 1.0 : -1.0;
    b.direction = {axis == 0 ? sign : 0.0, axis == 1 ? sign : 0.0, axis == 2 ? sign : 0.0};
    b.bird.massKg = birdMass_->value();
    b.bird.speedMps = birdSpeed_->value();
    b.bird.obliquityRad = birdObliquity_->value() * M_PI / 180.0;
    if (birdFaceId_.empty()) return invalid(tr("Не задана грань удара."));
    if (face(birdFaceId_) == nullptr) return invalid(tr("Грань удара больше не существует — деталь изменилась, переназначьте её."));
    b.impactFace = faceIndexId(birdFaceId_);
    if (job.loadCase.supports.empty()) return invalid(tr("Нет опор: деталь должна быть на чём-то закреплена."));
    if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
    if (!(b.bird.speedMps > 0.0)) return invalid(tr("Не задана скорость встречи с птицей."));
    if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
    job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
    job.settings.refinementFactor = refinement_->value();
    job.resultPath = "result.json";
    job.fieldPath = "field.json";
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::setShock(int shape, int axis, double peakG, double durationMs, double riseMs, double fallMs, double dampingRatio,
                                    int modes) {
    pulseShape_->setCurrentIndex(shape);
    vibrationAxis_->setCurrentIndex(axis);
    pulsePeak_->setValue(peakG);
    pulseDuration_->setValue(durationMs);
    pulseRise_->setValue(riseMs);
    pulseFall_->setValue(fallMs);
    damping_->setValue(dampingRatio * 100.0);
    vibrationModes_->setValue(modes);
}

void StructuralStudyPanel::setRandomVibration(int axis, const std::vector<std::pair<double, double>>& psdG2PerHz, double dampingRatio, int modes) {
    vibrationAxis_->setCurrentIndex(axis);
    damping_->setValue(dampingRatio * 100.0);
    vibrationModes_->setValue(modes);
    const QSignalBlocker block(psdTable_);
    psdTable_->setRowCount(0);
    for (const auto& [hz, value] : psdG2PerHz) {
        const int row = psdTable_->rowCount();
        psdTable_->insertRow(row);
        psdTable_->setItem(row, 0, new QTableWidgetItem(QString::number(hz, 'g', 10)));
        psdTable_->setItem(row, 1, new QTableWidgetItem(QString::number(value, 'g', 10)));
    }
    refreshState();
}

void StructuralStudyPanel::setVibration(VibrationKind kind, int axis, double amplitude, double dampingRatio, int modes, double fromHz, double toHz) {
    vibrationKind_->setCurrentIndex(kind == VibrationKind::Base ? 0 : kind == VibrationKind::Force ? 1 : 2);
    vibrationAxis_->setCurrentIndex(axis);
    vibrationAmplitude_->setValue(amplitude);
    damping_->setValue(dampingRatio * 100.0);
    vibrationModes_->setValue(modes);
    fromHz_->setValue(fromHz);
    toHz_->setValue(toHz);
}

QString StructuralStudyPanel::setVibrationFaceFromSelection() {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) return tr("Сначала выберите грань в окне модели.");
    if (!bodyId_.empty() && selected->first != bodyId_) return tr("Грань другого тела: вариант относится к одному телу.");
    bodyId_ = selected->first;
    vibrationFace_ = selected->second;
    vibrationFaceLabel_->setText(QString::fromStdString(faceIndexId(vibrationFace_)));
    refreshState();
    return {};
}

QString StructuralStudyPanel::setProbeFaceFromSelection() {
    const auto selected = context_.selectedFace ? context_.selectedFace() : std::nullopt;
    if (!selected) return tr("Сначала выберите грань в окне модели.");
    if (!bodyId_.empty() && selected->first != bodyId_) return tr("Грань другого тела: вариант относится к одному телу.");
    bodyId_ = selected->first;
    probeFace_ = selected->second;
    probeFaceLabel_->setText(QString::fromStdString(faceIndexId(probeFace_)));
    refreshState();
    return {};
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
    const QString title = analysis() == fea::StructuralAnalysis::Modal      ? tr("Собственные частоты детали")
                          : analysis() == fea::StructuralAnalysis::Harmonic ? tr("Вибрация детали")
                          : analysis() == fea::StructuralAnalysis::Random   ? tr("Случайная вибрация детали")
                          : analysis() == fea::StructuralAnalysis::Shock    ? tr("Удар по детали")
                          : analysis() == fea::StructuralAnalysis::Climate  ? tr("Климат детали")
                          : analysis() == fea::StructuralAnalysis::Fire     ? tr("Огнестойкость детали")
                          : analysis() == fea::StructuralAnalysis::Lightning ? tr("Молния по детали")
                          : analysis() == fea::StructuralAnalysis::Emc       ? tr("Экранирование корпуса")
                          : analysis() == fea::StructuralAnalysis::Icing     ? tr("Обледенение детали")
                          : analysis() == fea::StructuralAnalysis::Flutter   ? tr("Флаттер детали")
                          : analysis() == fea::StructuralAnalysis::Bird      ? tr("Удар птицы")
                                                                             : tr("Прочность детали");
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
    const bool climate = analysis() == fea::StructuralAnalysis::Climate;
    const bool harmonic = analysis() == fea::StructuralAnalysis::Harmonic || analysis() == fea::StructuralAnalysis::Random
                          || analysis() == fea::StructuralAnalysis::Shock || climate;
    for (const auto& item : items_) {
        const bool unused = (modal && item.kind != ItemKind::Support)
                            || (harmonic && (item.kind == ItemKind::Force || item.kind == ItemKind::Pressure));
        if (unused) {
            auto* entry = new QListWidgetItem(describe(item) + (modal     ? tr(" — не используется в модальном расчёте")
                                                                : climate ? tr(" — не используется в климатическом расчёте")
                                                                          : tr(" — не используется в вибрационном расчёте")));
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
    if (analysis() == fea::StructuralAnalysis::Climate) return buildClimateJob();
    if (analysis() == fea::StructuralAnalysis::Fire) return buildFireJob();
    if (analysis() == fea::StructuralAnalysis::Lightning) return buildLightningJob();
    if (analysis() == fea::StructuralAnalysis::Emc) return buildEmcJob();
    if (analysis() == fea::StructuralAnalysis::Icing) return buildIcingJob();
    if (analysis() == fea::StructuralAnalysis::Flutter) return buildFlutterJob();
    if (analysis() == fea::StructuralAnalysis::Bird) return buildBirdJob();
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
        return Result<fea::StructuralJob>::ok(std::move(job));
    }
    if (analysis() == fea::StructuralAnalysis::Shock) {
        if (bodyId_.empty()) return invalid(tr("Выберите грань детали и закрепите её: опоры — это оснастка, через которую приходит удар."));
        reloadFaces();
        fea::StructuralJob job;
        job.analysis = fea::StructuralAnalysis::Shock;
        job.geometryFormat = "brep";
        job.geometryPath = "part.brep";
        job.materialId = material_->currentData().toString().toStdString();
        job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
        if (job.loadCase.name.empty()) job.loadCase.name = tr("Удар").toStdString();
        for (const auto& item : items_) {
            if (item.kind != ItemKind::Support && item.kind != ItemKind::Exclusion) continue;
            if (face(item.faceId) == nullptr) {
                return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте её.")
                                   .arg(QString::fromStdString(faceIndexId(item.faceId))));
            }
            if (item.kind == ItemKind::Support) job.loadCase.supports.push_back({faceIndexId(item.faceId), item.fixed});
            else job.loadCase.stressExclusions.push_back({faceIndexId(item.faceId), item.distanceM});
        }
        if (job.loadCase.supports.empty()) return invalid(tr("Нет опор: закрепите деталь на оснастке (грань → «Опора / оснастка»)."));
        auto& h = job.shock;
        h.direction = fea::Vec3{vibrationAxis_->currentIndex() == 0 ? 1.0 : 0.0, vibrationAxis_->currentIndex() == 1 ? 1.0 : 0.0,
                                vibrationAxis_->currentIndex() == 2 ? 1.0 : 0.0};
        h.pulse.shape = pulseShape_->currentIndex() == 0 ? fea::PulseShape::HalfSine
                        : pulseShape_->currentIndex() == 1 ? fea::PulseShape::TerminalPeakSawtooth
                                                            : fea::PulseShape::Trapezoid;
        if (!(pulsePeak_->value() > 0.0) || !(pulseDuration_->value() > 0.0)) return invalid(tr("Импульс: задайте пик ускорения и длительность."));
        h.pulse.peakMs2 = pulsePeak_->value() * kStandardGravity;
        h.pulse.durationS = pulseDuration_->value() / 1e3;
        if (h.pulse.shape == fea::PulseShape::Trapezoid) {
            h.pulse.riseS = pulseRise_->value() / 1e3;
            h.pulse.fallS = pulseFall_->value() / 1e3;
            if (!(h.pulse.riseS > 0.0 && h.pulse.fallS > 0.0 && h.pulse.riseS + h.pulse.fallS <= h.pulse.durationS)) {
                return invalid(tr("Трапеция: фронт и спад положительные и вместе не длиннее импульса."));
            }
        }
        if (!probeFace_.empty()) {
            if (face(probeFace_) == nullptr) return invalid(tr("Грань датчика больше не существует."));
            h.probeFace = faceIndexId(probeFace_);
        }
        if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
        if (!(damping_->value() > 0.0)) return invalid(tr("Не задано демпфирование ζ — у него нет умолчания."));
        if (vibrationModes_->value() < 1) return invalid(tr("Не задано число мод."));
        if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
        h.dampingRatio = damping_->value() / 100.0;
        h.modeCount = vibrationModes_->value();
        job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
        job.settings.refinementFactor = refinement_->value();
        job.resultPath = "result.json";
        job.fieldPath = "field.json";
        return Result<fea::StructuralJob>::ok(std::move(job));
    }
    if (analysis() == fea::StructuralAnalysis::Random) {
        if (bodyId_.empty()) return invalid(tr("Выберите грань детали и закрепите её: опоры — это оснастка вибростенда."));
        reloadFaces();
        fea::StructuralJob job;
        job.analysis = fea::StructuralAnalysis::Random;
        job.geometryFormat = "brep";
        job.geometryPath = "part.brep";
        job.materialId = material_->currentData().toString().toStdString();
        job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
        if (job.loadCase.name.empty()) job.loadCase.name = tr("Случайная вибрация").toStdString();
        for (const auto& item : items_) {
            if (item.kind != ItemKind::Support && item.kind != ItemKind::Exclusion) continue;
            if (face(item.faceId) == nullptr) {
                return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте её.")
                                   .arg(QString::fromStdString(faceIndexId(item.faceId))));
            }
            if (item.kind == ItemKind::Support) job.loadCase.supports.push_back({faceIndexId(item.faceId), item.fixed});
            else job.loadCase.stressExclusions.push_back({faceIndexId(item.faceId), item.distanceM});
        }
        if (job.loadCase.supports.empty()) return invalid(tr("Нет опор: закрепите деталь на оснастке (грань → «Опора / оснастка»)."));
        auto& r = job.random;
        r.direction = fea::Vec3{vibrationAxis_->currentIndex() == 0 ? 1.0 : 0.0, vibrationAxis_->currentIndex() == 1 ? 1.0 : 0.0,
                                vibrationAxis_->currentIndex() == 2 ? 1.0 : 0.0};
        for (int row = 0; row < psdTable_->rowCount(); ++row) {
            bool okF = false, okS = false;
            const double hz = psdTable_->item(row, 0) ? psdTable_->item(row, 0)->text().replace(',', '.').toDouble(&okF) : 0.0;
            const double g2 = psdTable_->item(row, 1) ? psdTable_->item(row, 1)->text().replace(',', '.').toDouble(&okS) : 0.0;
            if (!okF || !okS || !(hz > 0.0) || !(g2 > 0.0)) return invalid(tr("Спектр: строка %1 — нужны положительные частота и PSD.").arg(row + 1));
            if (!r.accelerationPsd.empty() && !(hz > r.accelerationPsd.back().frequencyHz)) return invalid(tr("Спектр: частоты должны возрастать."));
            r.accelerationPsd.push_back({hz, g2 * kStandardGravity * kStandardGravity});
        }
        if (r.accelerationPsd.size() < 2) return invalid(tr("Спектр: нужно не меньше двух точек (от и до)."));
        if (!probeFace_.empty()) {
            if (face(probeFace_) == nullptr) return invalid(tr("Грань датчика больше не существует."));
            r.probeFace = faceIndexId(probeFace_);
        }
        if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
        if (!(damping_->value() > 0.0)) return invalid(tr("Не задано демпфирование ζ — у него нет умолчания."));
        if (vibrationModes_->value() < 1) return invalid(tr("Не задано число мод."));
        if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
        r.dampingRatio = damping_->value() / 100.0;
        r.modeCount = vibrationModes_->value();
        job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
        job.settings.refinementFactor = refinement_->value();
        job.resultPath = "result.json";
        job.fieldPath = "field.json";
        return Result<fea::StructuralJob>::ok(std::move(job));
    }
    if (analysis() == fea::StructuralAnalysis::Harmonic) {
        if (bodyId_.empty()) return invalid(tr("Выберите грань детали и закрепите её: опоры — это оснастка вибростенда."));
        reloadFaces();
        fea::StructuralJob job;
        job.analysis = fea::StructuralAnalysis::Harmonic;
        job.geometryFormat = "brep";
        job.geometryPath = "part.brep";
        job.materialId = material_->currentData().toString().toStdString();
        job.loadCase.name = loadCaseName_->text().trimmed().toStdString();
        if (job.loadCase.name.empty()) job.loadCase.name = tr("Вибрация").toStdString();
        for (const auto& item : items_) {
            if (item.kind != ItemKind::Support && item.kind != ItemKind::Exclusion) continue;
            if (face(item.faceId) == nullptr) {
                return invalid(tr("Грань %1 больше не существует — деталь изменилась, переназначьте её.")
                                   .arg(QString::fromStdString(faceIndexId(item.faceId))));
            }
            if (item.kind == ItemKind::Support) job.loadCase.supports.push_back({faceIndexId(item.faceId), item.fixed});
            else job.loadCase.stressExclusions.push_back({faceIndexId(item.faceId), item.distanceM});
        }
        if (job.loadCase.supports.empty()) return invalid(tr("Нет опор: закрепите деталь на оснастке (грань → «Опора / оснастка»)."));
        auto& h = job.harmonic;
        const int kind = vibrationKind_->currentIndex();
        h.excitation.kind = kind == 0 ? fea::HarmonicExcitationKind::BaseAcceleration : fea::HarmonicExcitationKind::FaceForce;
        h.excitation.direction = fea::Vec3{vibrationAxis_->currentIndex() == 0 ? 1.0 : 0.0, vibrationAxis_->currentIndex() == 1 ? 1.0 : 0.0,
                                           vibrationAxis_->currentIndex() == 2 ? 1.0 : 0.0};
        if (!(vibrationAmplitude_->value() > 0.0)) return invalid(tr("Не задана амплитуда возбуждения."));
        if (kind == 0) h.excitation.amplitude = {{1.0, vibrationAmplitude_->value() * kStandardGravity}};
        else if (kind == 1) h.excitation.amplitude = {{1.0, vibrationAmplitude_->value()}};
        else h.excitation.imbalanceKgM = vibrationAmplitude_->value() * 1e-6; // g·mm → kg·m
        if (kind != 0) {
            if (vibrationFace_.empty() || face(vibrationFace_) == nullptr) return invalid(tr("Не задана грань силы (выберите грань → «Выбранная грань»)."));
            h.excitation.faceGroup = faceIndexId(vibrationFace_);
        }
        if (!probeFace_.empty()) {
            if (face(probeFace_) == nullptr) return invalid(tr("Грань датчика больше не существует."));
            h.probeFace = faceIndexId(probeFace_);
        }
        if (job.materialId->empty()) return invalid(tr("Не выбран материал."));
        if (!(damping_->value() > 0.0)) return invalid(tr("Не задано демпфирование ζ — у него нет умолчания."));
        if (vibrationModes_->value() < 1) return invalid(tr("Не задано число мод."));
        if (!(fromHz_->value() > 0.0) || !(toHz_->value() > fromHz_->value())) return invalid(tr("Задайте диапазон частот: 0 < от < до."));
        if (!(elementSize_->value() > 0.0)) return invalid(tr("Не задан размер грубой сетки (можно «Предложить»)."));
        h.dampingRatio = damping_->value() / 100.0;
        h.modeCount = vibrationModes_->value();
        h.minimumHz = fromHz_->value();
        h.maximumHz = toHz_->value();
        job.settings.coarseElementSizeM = elementSize_->value() / 1e3;
        job.settings.refinementFactor = refinement_->value();
        job.resultPath = "result.json";
        job.fieldPath = "field.json";
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
    return Result<fea::StructuralJob>::ok(std::move(job));
}

void StructuralStudyPanel::refreshState() {
    if (psdSummary_ != nullptr && psdTable_ != nullptr) {
        std::vector<fea::AmplitudePoint> points;
        bool valid = psdTable_->rowCount() >= 2;
        for (int row = 0; valid && row < psdTable_->rowCount(); ++row) {
            bool okF = false, okS = false;
            const double hz = psdTable_->item(row, 0) ? psdTable_->item(row, 0)->text().replace(',', '.').toDouble(&okF) : 0.0;
            const double g2 = psdTable_->item(row, 1) ? psdTable_->item(row, 1)->text().replace(',', '.').toDouble(&okS) : 0.0;
            valid = okF && okS && hz > 0.0 && g2 > 0.0 && (points.empty() || hz > points.back().frequencyHz);
            points.push_back({hz, g2});
        }
        psdSummary_->setText(valid ? tr("%1 g RMS в полосе %2–%3 Гц").arg(std::sqrt(fea::psdMeanSquare(points)), 0, 'f', 3)
                                         .arg(points.front().frequencyHz, 0, 'g', 4).arg(points.back().frequencyHz, 0, 'g', 4)
                                   : tr("Не меньше двух точек по возрастанию частоты."));
    }
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
