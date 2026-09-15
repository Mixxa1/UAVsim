#include "cadnext/gui/WorkbenchExportDialog.hpp"

#include "cadnext/fea/Material.hpp"

#include <QComboBox>
#include <QDialogButtonBox>
#include <QFormLayout>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QTableWidget>
#include <QUuid>
#include <QVBoxLayout>

namespace cadnext::gui {

namespace {

const QStringList kAxes = {"+x", "-x", "+y", "-y", "+z", "-z"};

QComboBox* axisBox(bool withPlaceholder) {
    auto* box = new QComboBox;
    if (withPlaceholder) box->addItem(QObject::tr("— выберите —"), QString());
    for (const QString& axis : kAxes) box->addItem(axis.toUpper().replace("+", "+ ").replace("-", "− "), axis);
    return box;
}

} // namespace

WorkbenchExportDialog::WorkbenchExportDialog(std::vector<WorkbenchExportBody> bodies, const QString& name, QWidget* parent)
    : QDialog(parent), bodies_(std::move(bodies)) {
    setWindowTitle(tr("Экспорт в Мастерскую"));
    resize(560, 460);
    auto* layout = new QVBoxLayout(this);
    auto* intro = new QLabel(tr("Точная геометрия тел (BRep), их материалы и привязка граней уходят в .uavframe: Мастерская будет считать прочность по ним."));
    intro->setWordWrap(true);
    layout->addWidget(intro);

    auto* form = new QFormLayout;
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    name_ = new QLineEdit(name);
    form->addRow(tr("Название рамы"), name_);
    forward_ = axisBox(true);
    forward_->setCurrentIndex(forward_->findData(QStringLiteral("-y")));
    forward_->setToolTip(tr("Ось CAD, смотрящая в нос аппарата. По умолчанию −Y: так Мастерская всегда показывала рамы CADNext. "
                            "Если нос модели смотрит в другую сторону, выберите её ось — иначе аппарат развернётся вместе с нагрузками."));
    form->addRow(tr("Вперёд (нос)"), forward_);
    up_ = axisBox(false);
    up_->setCurrentIndex(kAxes.indexOf("+z"));
    up_->setToolTip(tr("CADNext моделирует с осью Z вверх."));
    form->addRow(tr("Вверх"), up_);
    layout->addLayout(form);

    table_ = new QTableWidget(static_cast<int>(bodies_.size()), 2);
    table_->setHorizontalHeaderLabels({tr("Тело"), tr("Материал")});
    table_->verticalHeader()->hide();
    table_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
    table_->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);
    for (int row = 0; row < static_cast<int>(bodies_.size()); ++row) {
        auto* item = new QTableWidgetItem(bodies_[row].name);
        item->setFlags(item->flags() & ~Qt::ItemIsEditable);
        table_->setItem(row, 0, item);
        auto* material = new QComboBox;
        material->addItem(tr("— выберите —"), QString());
        for (const auto& entry : fea::materialLibrary()) {
            material->addItem(QString::fromStdString(entry.displayName), QString::fromStdString(entry.id));
        }
        if (bodies_[row].materialId) {
            if (const auto known = fea::findMaterial(*bodies_[row].materialId)) {
                material->setCurrentIndex(material->findData(QString::fromStdString(known->id)));
            }
        }
        connect(material, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() { refresh(); });
        table_->setCellWidget(row, 1, material);
    }
    layout->addWidget(table_, 1);

    status_ = new QLabel;
    status_->setWordWrap(true);
    layout->addWidget(status_);
    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    accept_ = buttons->button(QDialogButtonBox::Ok);
    accept_->setText(tr("Экспортировать…"));
    layout->addWidget(buttons);
    connect(buttons, &QDialogButtonBox::accepted, this, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
    for (QComboBox* box : {forward_, up_}) {
        connect(box, qOverload<int>(&QComboBox::currentIndexChanged), this, [this]() { refresh(); });
    }
    connect(name_, &QLineEdit::textChanged, this, [this]() { refresh(); });
    refresh();
}

void WorkbenchExportDialog::setForwardAxis(const QString& axis) {
    forward_->setCurrentIndex(forward_->findData(axis));
}

void WorkbenchExportDialog::setUpAxis(const QString& axis) {
    up_->setCurrentIndex(up_->findData(axis));
}

void WorkbenchExportDialog::setBodyMaterial(int row, const std::string& materialId) {
    if (auto* box = qobject_cast<QComboBox*>(table_->cellWidget(row, 1))) {
        box->setCurrentIndex(box->findData(QString::fromStdString(materialId)));
    }
}

void WorkbenchExportDialog::setConstructionName(const QString& name) {
    name_->setText(name);
}

Result<bridge::ConstructionBuildRequest> WorkbenchExportDialog::request() const {
    auto invalid = [](const QString& why) {
        return Result<bridge::ConstructionBuildRequest>::fail({ErrorCode::InvalidArgument, why.toStdString()});
    };
    if (bodies_.empty()) return invalid(tr("В документе нет тел с точной геометрией."));
    bridge::ConstructionBuildRequest request;
    request.name = name_->text().trimmed().toStdString();
    if (request.name.empty()) return invalid(tr("Не задано название рамы."));
    request.id = QUuid::createUuid().toString(QUuid::WithoutBraces).toStdString();
    request.cadAxes.forward = forward_->currentData().toString().toStdString();
    request.cadAxes.up = up_->currentData().toString().toStdString();
    if (request.cadAxes.forward.empty()) return invalid(tr("Не выбрана ось «вперёд»."));
    if (const auto check = bridge::cadToModel(request.cadAxes, {1, 0, 0}); !check.isOk()) {
        return invalid(QString::fromStdString(check.error().message));
    }
    for (int row = 0; row < static_cast<int>(bodies_.size()); ++row) {
        const auto* box = qobject_cast<QComboBox*>(table_->cellWidget(row, 1));
        const std::string materialId = box ? box->currentData().toString().toStdString() : std::string();
        const auto material = fea::findMaterial(materialId);
        if (materialId.empty() || !material) return invalid(tr("Не выбран материал тела «%1».").arg(bodies_[row].name));
        request.bodies.push_back({bodies_[row].id, bodies_[row].name.toStdString(), bodies_[row].shape, material->id, material->densityKgPerM3});
    }
    return Result<bridge::ConstructionBuildRequest>::ok(std::move(request));
}

void WorkbenchExportDialog::refresh() {
    const auto current = request();
    accept_->setEnabled(current.isOk());
    status_->setText(current.isOk() ? tr("Готово к экспорту: %1 тел.").arg(bodies_.size())
                                    : QString::fromStdString(current.error().message));
}

} // namespace cadnext::gui
