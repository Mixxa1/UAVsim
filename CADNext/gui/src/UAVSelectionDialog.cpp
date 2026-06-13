#include "cadnext/gui/UAVSelectionDialog.hpp"
#include "cadnext/gui/UAVMountEditorDialog.hpp"

#include <QButtonGroup>
#include <QFormLayout>
#include <QFrame>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QMessageBox>
#include <QPushButton>
#include <QScrollArea>
#include <QSizePolicy>
#include <QVBoxLayout>

namespace cadnext::gui {

namespace {

QFrame* makeSepH() {
    auto* f = new QFrame;
    f->setFrameShape(QFrame::HLine);
    f->setFrameShadow(QFrame::Sunken);
    return f;
}

QFrame* makeSepV() {
    auto* f = new QFrame;
    f->setFrameShape(QFrame::VLine);
    f->setFrameShadow(QFrame::Sunken);
    return f;
}

QColor statusColor(PayloadUAVCompatibilityStatus s) {
    switch (s) {
    case PayloadUAVCompatibilityStatus::compatible:   return QColor(0x00, 0x7a, 0x00);
    case PayloadUAVCompatibilityStatus::limited:      return QColor(0xa0, 0x60, 0x00);
    case PayloadUAVCompatibilityStatus::incompatible: return Qt::red;
    case PayloadUAVCompatibilityStatus::unknown:      return Qt::gray;
    }
    return Qt::gray;
}

} // namespace

UAVSelectionDialog::UAVSelectionDialog(const UAVPartPreflightData& partData,
                                       const QString& partDisplayName,
                                       QWidget* parent)
    : QDialog(parent)
    , partData_(partData)
{
    setWindowTitle(tr("Выбор БЛА для проверки детали"));
    setMinimumSize(960, 640);

    // Pre-compute compatibility results for all catalog entries.
    const auto& cat = UAVCatalogPreviewProvider::catalog();
    results_.reserve(cat.size());
    for (const auto& item : cat) {
        results_.push_back(
            UAVPayloadCompatibilityChecker::checkCompatibility(partData_, item));
    }

    auto* root = new QVBoxLayout(this);
    root->setSpacing(8);
    root->setContentsMargins(12, 12, 12, 12);

    // ── Header ──────────────────────────────────────────────────────────────
    {
        auto* titleLabel = new QLabel(
            QStringLiteral("<b>%1</b>").arg(
                tr("Выбор БЛА для проверки детали: %1")
                    .arg(partDisplayName.toHtmlEscaped())));
        root->addWidget(titleLabel);

        const QString brief = tr("Масса детали: %1 кг   Точек крепления: %2")
            .arg(partData_.massKg, 0, 'f', 3)
            .arg(static_cast<int>(partData_.enabledAttachmentRoles.size()));
        auto* briefLabel = new QLabel(brief);
        briefLabel->setEnabled(false);
        root->addWidget(briefLabel);

        // Part-level warnings
        for (const auto& w : partData_.preflightWarnings) {
            auto* wl = new QLabel(QStringLiteral("⚠ ") + QString::fromStdString(w));
            wl->setWordWrap(true);
            QPalette pal = wl->palette();
            pal.setColor(QPalette::WindowText, QColor(0xa0, 0x60, 0x00));
            wl->setPalette(pal);
            root->addWidget(wl);
        }
    }

    root->addWidget(makeSepH());

    // ── Content row ──────────────────────────────────────────────────────────
    auto* contentRow = new QHBoxLayout;
    contentRow->setSpacing(10);

    // ── Left panel: filters + list ───────────────────────────────────────────
    {
        auto* leftPanel = new QVBoxLayout;
        leftPanel->setSpacing(6);

        // Filter buttons
        auto* filterRow = new QHBoxLayout;
        filterRow->setSpacing(3);
        filterRow->setContentsMargins(0, 0, 0, 0);

        auto* filterGroup = new QButtonGroup(this);
        filterGroup->setExclusive(true);

        struct FBtn { QString label; FilterMode mode; };
        for (const FBtn& fb : {
                FBtn{tr("Все"),                     FilterMode::all},
                FBtn{tr("Совместимые"),              FilterMode::compatible},
                FBtn{tr("Огр. совместимые"),         FilterMode::limited},
                FBtn{tr("Несовместимые"),            FilterMode::incompatible}
            })
        {
            auto* btn = new QPushButton(fb.label);
            btn->setCheckable(true);
            btn->setChecked(fb.mode == FilterMode::all);
            filterGroup->addButton(btn);
            filterRow->addWidget(btn);

            const FilterMode mode = fb.mode;
            connect(btn, &QPushButton::toggled, this, [this, mode](bool checked) {
                if (checked) {
                    filter_ = mode;
                    rebuildList();
                }
            });
        }
        leftPanel->addLayout(filterRow);

        uavList_ = new QListWidget;
        uavList_->setMinimumWidth(310);
        uavList_->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Expanding);
        leftPanel->addWidget(uavList_);

        connect(uavList_, &QListWidget::currentRowChanged, this,
                [this](int row) {
                    if (row < 0) return;
                    const int idx = uavList_->item(row)->data(Qt::UserRole).toInt();
                    onUAVSelected(idx);
                });

        contentRow->addLayout(leftPanel, 0);
    }

    contentRow->addWidget(makeSepV());

    // ── Right panel: UAV card + compatibility ─────────────────────────────────
    {
        auto* rightPanel = new QVBoxLayout;
        rightPanel->setSpacing(8);

        // ── UAV card group ───────────────────────────────────────────────────
        cardBox_ = new QGroupBox(tr("Аппарат"));
        auto* cardForm = new QFormLayout(cardBox_);
        cardForm->setSpacing(4);
        cardForm->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

        cardTitle_     = new QLabel(tr("—"));
        cardCountry_   = new QLabel(tr("—"));
        cardType_      = new QLabel(tr("—"));
        cardMassClass_ = new QLabel(tr("—"));
        cardMass_      = new QLabel(tr("—"));
        cardPayload_   = new QLabel(tr("—"));
        cardMTOW_      = new QLabel(tr("—"));
        cardMounts_    = new QLabel(tr("—"));
        cardStatus_    = new QLabel(tr("—"));

        {
            QFont f = cardTitle_->font();
            f.setBold(true);
            cardTitle_->setFont(f);
        }
        {
            QFont f = cardStatus_->font();
            f.setBold(true);
            cardStatus_->setFont(f);
        }

        cardForm->addRow(tr("Название:"),          cardTitle_);
        cardForm->addRow(tr("Страна:"),             cardCountry_);
        cardForm->addRow(tr("Тип:"),                cardType_);
        cardForm->addRow(tr("Класс:"),              cardMassClass_);
        cardForm->addRow(tr("Масса аппарата:"),     cardMass_);
        cardForm->addRow(tr("Макс. нагрузка:"),     cardPayload_);
        cardForm->addRow(tr("MTOW:"),               cardMTOW_);
        cardForm->addRow(tr("Точки крепления:"),    cardMounts_);
        cardForm->addRow(tr("Статус:"),             cardStatus_);

        rightPanel->addWidget(cardBox_);

        // ── Compatibility group ──────────────────────────────────────────────
        compBox_ = new QGroupBox(tr("Совместимость"));
        auto* compLayout = new QVBoxLayout(compBox_);
        compLayout->setSpacing(6);

        auto* compForm = new QFormLayout;
        compForm->setSpacing(4);
        compForm->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

        compPayloadMass_ = new QLabel(tr("—"));
        compMaxPayload_  = new QLabel(tr("—"));
        compTotalMass_   = new QLabel(tr("—"));
        compMTOW_        = new QLabel(tr("—"));
        compBounds_      = new QLabel(tr("—"));

        compForm->addRow(tr("Масса детали:"),          compPayloadMass_);
        compForm->addRow(tr("Макс. нагрузка БЛА:"),   compMaxPayload_);
        compForm->addRow(tr("Итоговая масса:"),        compTotalMass_);
        compForm->addRow(tr("Макс. взлётная масса:"),  compMTOW_);
        compForm->addRow(tr("Габариты детали:"),       compBounds_);
        compLayout->addLayout(compForm);

        compStatusLabel_ = new QLabel;
        compStatusLabel_->setWordWrap(true);
        {
            QFont f = compStatusLabel_->font();
            f.setBold(true);
            compStatusLabel_->setFont(f);
        }
        compLayout->addWidget(compStatusLabel_);

        compIssues_ = new QLabel;
        compIssues_->setWordWrap(true);
        compIssues_->setVisible(false);
        compLayout->addWidget(compIssues_);

        compWarnings_ = new QLabel;
        compWarnings_->setWordWrap(true);
        compWarnings_->setVisible(false);
        compLayout->addWidget(compWarnings_);

        rightPanel->addWidget(compBox_);
        rightPanel->addStretch();

        contentRow->addLayout(rightPanel, 1);
    }

    root->addLayout(contentRow, 1);

    root->addWidget(makeSepH());

    // ── Bottom buttons ────────────────────────────────────────────────────────
    {
        auto* btnRow = new QHBoxLayout;
        btnRow->setSpacing(8);

        auto* backBtn  = new QPushButton(tr("Назад"));
        continueBtn_   = new QPushButton(tr("Продолжить"));
        auto* closeBtn = new QPushButton(tr("Закрыть"));

        continueBtn_->setEnabled(false);
        continueBtn_->setToolTip(
            tr("Выберите совместимый аппарат для продолжения"));
        closeBtn->setDefault(true);

        btnRow->addWidget(backBtn);
        btnRow->addStretch();
        btnRow->addWidget(continueBtn_);
        btnRow->addWidget(closeBtn);
        root->addLayout(btnRow);

        connect(backBtn,  &QPushButton::clicked, this, &QDialog::reject);
        connect(closeBtn, &QPushButton::clicked, this, &QDialog::reject);
        connect(continueBtn_, &QPushButton::clicked, this, [this]() {
            if (currentUAVIndex_ < 0) return;
            const auto& cat = UAVCatalogPreviewProvider::catalog();
            const auto& selectedUAV = cat[static_cast<std::size_t>(currentUAVIndex_)];
            const auto& result      = results_[static_cast<std::size_t>(currentUAVIndex_)];
            UAVMountEditorDialog dlg(partData_, selectedUAV, result, this);
            dlg.exec();
        });
    }

    // Populate list for the first time.
    rebuildList();
}

void UAVSelectionDialog::rebuildList()
{
    const int prevIdx = currentUAVIndex_;
    uavList_->blockSignals(true);
    uavList_->clear();
    uavList_->blockSignals(false);

    const auto& cat = UAVCatalogPreviewProvider::catalog();
    int selectRow = -1;

    for (int i = 0; i < static_cast<int>(cat.size()); ++i) {
        const auto& res = results_[i];

        bool show = false;
        switch (filter_) {
        case FilterMode::all:          show = true;  break;
        case FilterMode::compatible:   show = res.status == PayloadUAVCompatibilityStatus::compatible;   break;
        case FilterMode::limited:      show = res.status == PayloadUAVCompatibilityStatus::limited;      break;
        case FilterMode::incompatible: show = res.status == PayloadUAVCompatibilityStatus::incompatible; break;
        }
        if (!show) continue;

        const QString label = QStringLiteral("%1  —  %2")
            .arg(QString::fromStdString(cat[i].name))
            .arg(QString::fromStdString(
                UAVPayloadCompatibilityChecker::statusText(res.status)));

        auto* item = new QListWidgetItem(label);
        item->setData(Qt::UserRole, i);
        item->setForeground(statusColor(res.status));
        uavList_->addItem(item);

        if (i == prevIdx) selectRow = uavList_->count() - 1;
    }

    // Restore selection if the previously selected item is still visible.
    if (selectRow >= 0) {
        uavList_->setCurrentRow(selectRow);
    } else {
        currentUAVIndex_ = -1;
        // Clear right panel
        cardStatus_->setText(tr("—"));
        compStatusLabel_->setText(QString{});
        compIssues_->setVisible(false);
        compWarnings_->setVisible(false);
        continueBtn_->setEnabled(false);
    }
}

void UAVSelectionDialog::onUAVSelected(int catalogIdx)
{
    currentUAVIndex_ = catalogIdx;

    const auto& cat = UAVCatalogPreviewProvider::catalog();
    if (catalogIdx < 0 || catalogIdx >= static_cast<int>(cat.size())) return;

    const auto& uav    = cat[catalogIdx];
    const auto& result = results_[catalogIdx];

    // ── UAV card ─────────────────────────────────────────────────────────────
    cardTitle_->setText(QString::fromStdString(uav.name));
    cardCountry_->setText(QString::fromStdString(uav.country));
    cardType_->setText(QString::fromStdString(
        UAVPayloadCompatibilityChecker::vehicleTypeText(uav.vehicleType)));
    cardMassClass_->setText(QString::fromStdString(
        UAVPayloadCompatibilityChecker::massCategoryText(uav.massCategory)));
    cardMass_->setText(QStringLiteral("%1 кг").arg(uav.emptyMassKg, 0, 'f', 3));

    cardPayload_->setText(uav.maxPayloadMassKg > 0.0
        ? QStringLiteral("%1 кг").arg(uav.maxPayloadMassKg, 0, 'f', 3)
        : tr("—"));
    cardMTOW_->setText(uav.maxTakeoffMassKg > 0.0
        ? QStringLiteral("%1 кг").arg(uav.maxTakeoffMassKg, 0, 'f', 3)
        : tr("—"));

    int mountCount = 0;
    for (const auto& mp : uav.mountPoints) {
        if (mp.isEnabled) ++mountCount;
    }
    cardMounts_->setText(mountCount > 0 ? QString::number(mountCount) : tr("нет"));

    const QString statusStr = QString::fromStdString(
        UAVPayloadCompatibilityChecker::statusText(result.status));
    cardStatus_->setText(statusStr);
    applyStatusColor(cardStatus_, result.status);

    // ── Compatibility panel ───────────────────────────────────────────────────
    compPayloadMass_->setText(
        QStringLiteral("%1 кг").arg(result.payloadMassKg, 0, 'f', 3));
    compMaxPayload_->setText(result.maxPayloadMassKg > 0.0
        ? QStringLiteral("%1 кг").arg(result.maxPayloadMassKg, 0, 'f', 3)
        : tr("—"));
    compTotalMass_->setText(
        QStringLiteral("%1 кг").arg(result.totalMassKg, 0, 'f', 3));
    compMTOW_->setText(result.maxTakeoffMassKg > 0.0
        ? QStringLiteral("%1 кг").arg(result.maxTakeoffMassKg, 0, 'f', 3)
        : tr("—"));

    if (partData_.boundsValid) {
        compBounds_->setText(
            QStringLiteral("%1 × %2 × %3 мм")
                .arg(partData_.boundingWidth  * 1000.0, 0, 'f', 1)
                .arg(partData_.boundingDepth  * 1000.0, 0, 'f', 1)
                .arg(partData_.boundingHeight * 1000.0, 0, 'f', 1));
    } else {
        compBounds_->setText(tr("—"));
    }

    compStatusLabel_->setText(tr("Статус: ") + statusStr);
    applyStatusColor(compStatusLabel_, result.status);

    // Errors
    if (!result.errors.empty()) {
        QStringList lines;
        for (const auto& e : result.errors)
            lines << QStringLiteral("✗ ") + QString::fromStdString(e);
        compIssues_->setText(lines.join('\n'));
        QPalette p = compIssues_->palette();
        p.setColor(QPalette::WindowText, Qt::red);
        compIssues_->setPalette(p);
        compIssues_->setVisible(true);
    } else {
        compIssues_->setVisible(false);
    }

    // Warnings
    if (!result.warnings.empty()) {
        QStringList lines;
        for (const auto& w : result.warnings)
            lines << QStringLiteral("⚠ ") + QString::fromStdString(w);
        compWarnings_->setText(lines.join('\n'));
        QPalette p = compWarnings_->palette();
        p.setColor(QPalette::WindowText, QColor(0xa0, 0x60, 0x00));
        compWarnings_->setPalette(p);
        compWarnings_->setVisible(true);
    } else {
        compWarnings_->setVisible(false);
    }

    // "Продолжить" is available for compatible/limited UAVs only.
    const bool canContinue = result.status == PayloadUAVCompatibilityStatus::compatible
                          || result.status == PayloadUAVCompatibilityStatus::limited;
    continueBtn_->setEnabled(canContinue);
    continueBtn_->setToolTip(canContinue
        ? tr("Готово к выбору точек крепления")
        : tr("Выберите совместимый аппарат для продолжения"));
}

void UAVSelectionDialog::applyStatusColor(QLabel* label,
                                          PayloadUAVCompatibilityStatus status)
{
    QPalette p = label->palette();
    p.setColor(QPalette::WindowText, statusColor(status));
    label->setPalette(p);
}

} // namespace cadnext::gui
