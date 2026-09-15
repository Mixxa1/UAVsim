#include "cadnext/gui/StructuralResultWindow.hpp"

#include "ViewerSnapshot.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/StructuralReport.hpp"
#include "cadnext/viewer/StructuralFieldScene.hpp"

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/nodes/SoCamera.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoPerspectiveCamera.h>
#include <Inventor/nodes/SoSeparator.h>

#include <QComboBox>
#include <QDesktopServices>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLinearGradient>
#include <QMessageBox>
#include <QPainter>
#include <QPushButton>
#include <QScrollArea>
#include <QSlider>
#include <QSplitter>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>

namespace cadnext::gui {

namespace {

using fea::json::JsonValue;

QString si(double value, const QString& unit) {
    if (!std::isfinite(value)) return QStringLiteral("—");
    struct Prefix { double scale; const char* name; };
    std::vector<Prefix> prefixes;
    if (unit == "Pa") prefixes = {{1e9, "ГПа"}, {1e6, "МПа"}, {1e3, "кПа"}, {1, "Па"}};
    else if (unit == "m") prefixes = {{1, "м"}, {1e-3, "мм"}, {1e-6, "мкм"}};
    else prefixes = {{1, ""}};
    const double magnitude = std::fabs(value);
    Prefix chosen = prefixes.back();
    for (const auto& prefix : prefixes) {
        if (magnitude >= prefix.scale) {
            chosen = prefix;
            break;
        }
    }
    const double scaled = value / chosen.scale;
    const int digits = std::fabs(scaled) >= 100 ? 1 : (std::fabs(scaled) >= 10 ? 2 : 3);
    QString text = QString::number(scaled, 'f', digits);
    if (*chosen.name) text += QStringLiteral(" ") + QString::fromUtf8(chosen.name);
    return text;
}

const JsonValue* metricEntry(const JsonValue& result, const char* name) {
    const JsonValue* metrics = result.member("metrics");
    return metrics ? metrics->member(name) : nullptr;
}

QString metricLine(const JsonValue& result, const char* name, const QString& label, const QString& unit) {
    const JsonValue* entry = metricEntry(result, name);
    if (entry == nullptr) return QString("<tr><td>%1</td><td>—</td></tr>").arg(label);
    const double value = entry->numberOr("value", NAN);
    const QString valueText = unit == "1" ? QString::number(value, 'f', 3) : si(value, unit);
    const JsonValue* band = entry->member("numericalUncertainty");
    const QString bandText = band ? QString("± %1 (сетка)").arg(unit == "1" ? QString::number(band->numberValue, 'f', 3) : si(band->numberValue, unit))
                                  : QStringLiteral("погрешность не оценена");
    return QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2</b></td></tr>"
                   "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
        .arg(label, valueText, bandText);
}

} // namespace

// Colour scale drawn from the field file's own stops, with the meaning of the current quantity.
class StructuralLegend : public QWidget {
public:
    explicit StructuralLegend(QWidget* parent) : QWidget(parent) { setMinimumHeight(118); }

    void configure(const fea::StructuralFieldFile& field, viewer::FieldQuantity quantity, double assessedUtilization) {
        field_ = &field;
        quantity_ = quantity;
        assessedUtilization_ = assessedUtilization;
        update();
    }

protected:
    void paintEvent(QPaintEvent*) override {
        if (field_ == nullptr) return;
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing);
        const QRect bar(0, 22, width() - 1, 14);
        QLinearGradient gradient(bar.topLeft(), bar.topRight());
        for (const auto& stop : field_->colorStops) {
            gradient.setColorAt(stop.position, QColor::fromRgbF(stop.rgb[0], stop.rgb[1], stop.rgb[2]));
        }
        painter.setPen(palette().color(QPalette::WindowText));
        QFont bold = font();
        bold.setBold(true);
        painter.setFont(bold);
        QString title;
        QStringList ticks;
        QString note;
        if (quantity_ == viewer::FieldQuantity::Utilization) {
            title = QStringLiteral("Использование σ / σдоп");
            ticks = {"0", "0.25", "0.5", "0.75", "1.0"};
            note = QString("σдоп = %1 (%2). В оценке %3.")
                       .arg(si(field_->allowableStressPa, "Pa"),
                            field_->allowableBasis == "yield" ? QStringLiteral("предел текучести")
                                                              : QString("σв / %1").arg(field_->factorOfSafety),
                            QString::number(assessedUtilization_, 'f', 3));
        } else if (quantity_ == viewer::FieldQuantity::VonMises) {
            title = QStringLiteral("σ Мизеса — автодиапазон, не мера запаса");
            ticks = {"0", si(field_->maxVonMisesPa() / 2, "Pa"), si(field_->maxVonMisesPa(), "Pa")};
        } else {
            title = QStringLiteral("|перемещение| — автодиапазон");
            ticks = {"0", si(field_->maxDisplacementM / 2, "m"), si(field_->maxDisplacementM, "m")};
        }
        painter.drawText(QRect(0, 0, width(), 20), Qt::AlignLeft | Qt::AlignVCenter, title);
        painter.setFont(font());
        painter.fillRect(bar, gradient);
        for (int i = 0; i < ticks.size(); ++i) {
            const double t = ticks.size() == 1 ? 0.0 : static_cast<double>(i) / (ticks.size() - 1);
            const Qt::Alignment alignment = i == 0 ? Qt::AlignLeft : (i == ticks.size() - 1 ? Qt::AlignRight : Qt::AlignHCenter);
            const int x = static_cast<int>(t * bar.width());
            const QRect box = i == 0 ? QRect(0, 38, 80, 16) : (i == ticks.size() - 1 ? QRect(width() - 80, 38, 80, 16) : QRect(x - 40, 38, 80, 16));
            painter.drawText(box, alignment, ticks[i]);
        }
        if (quantity_ == viewer::FieldQuantity::Utilization) {
            const auto& o = field_->overflowColor.rgb;
            painter.fillRect(QRect(0, 60, 14, 12), QColor::fromRgbF(o[0], o[1], o[2]));
            painter.drawText(QRect(20, 56, width() - 20, 20), Qt::AlignLeft | Qt::AlignVCenter, QStringLiteral("выше допускаемого"));
            painter.drawText(QRect(0, 78, width(), 40), Qt::AlignLeft | Qt::AlignTop | Qt::TextWordWrap, note);
        }
    }

private:
    const fea::StructuralFieldFile* field_ = nullptr;
    viewer::FieldQuantity quantity_ = viewer::FieldQuantity::Utilization;
    double assessedUtilization_ = 0.0;
};

StructuralResultWindow::StructuralResultWindow(QWidget* parent) : AnalysisResultWindow(parent) {
    setAttribute(Qt::WA_DeleteOnClose);
    resize(1280, 820);
    buildInterface();
}

StructuralResultWindow::~StructuralResultWindow() {
    delete viewer_;
    if (viewerRoot_ != nullptr) viewerRoot_->unref();
}

void StructuralResultWindow::buildInterface() {
    auto* splitter = new QSplitter(this);
    auto* viewport = new QWidget(splitter);
    new QVBoxLayout(viewport);
    viewport->layout()->setContentsMargins(0, 0, 0, 0);

    auto* panel = new QWidget;
    auto* layout = new QVBoxLayout(panel);
    title_ = new QLabel;
    title_->setWordWrap(true);
    QFont titleFont = title_->font();
    titleFont.setPointSize(titleFont.pointSize() + 4);
    titleFont.setBold(true);
    title_->setFont(titleFont);
    verdict_ = new QLabel;
    numbers_ = new QLabel;
    numbers_->setTextFormat(Qt::RichText);
    reasons_ = new QLabel;
    reasons_->setWordWrap(true);
    reasons_->setTextFormat(Qt::RichText);
    quantity_ = new QComboBox;
    quantity_->addItems({tr("Использование σ/σдоп"), tr("σ Мизеса"), tr("Перемещение")});
    deformation_ = new QSlider(Qt::Horizontal);
    deformation_->setRange(0, 200);
    deformation_->setValue(100);
    scaleLabel_ = new QLabel;
    auto* trueScale = new QPushButton(tr("×1 истинный"));
    legend_ = new StructuralLegend(panel);
    study_ = new QLabel;
    study_->setTextFormat(Qt::RichText);
    study_->setWordWrap(true);
    auto* report = new QPushButton(tr("Сохранить HTML-отчёт…"));

    layout->addWidget(title_);
    layout->addWidget(verdict_);
    layout->addWidget(numbers_);
    layout->addWidget(reasons_);
    auto* view = new QFormLayout;
    view->addRow(tr("Величина"), quantity_);
    auto* scaleRow = new QHBoxLayout;
    scaleRow->addWidget(deformation_, 1);
    scaleRow->addWidget(scaleLabel_);
    view->addRow(tr("Деформация"), scaleRow);
    view->addRow(QString(), trueScale);
    layout->addLayout(view);
    layout->addWidget(legend_);
    layout->addWidget(study_);
    layout->addStretch(1);
    layout->addWidget(report);

    auto* scroll = new QScrollArea(splitter);
    scroll->setWidgetResizable(true);
    scroll->setWidget(panel);
    scroll->setMinimumWidth(420);
    scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    splitter->addWidget(viewport);
    splitter->addWidget(scroll);
    splitter->setStretchFactor(0, 1);
    splitter->setSizes({860, 420});
    setCentralWidget(splitter);

    viewerRoot_ = new SoSeparator;
    viewerRoot_->ref();
    auto* camera = new SoPerspectiveCamera;
    viewerRoot_->addChild(camera);
    viewer_ = new SoQtExaminerViewer(viewport);
    viewer_->setDecoration(FALSE);
    viewer_->setHeadlight(TRUE);
    viewer_->getHeadlight()->intensity = viewer::kStructuralHeadlightIntensity;
    // Mid-grey: the dark end of viridis has to stay visible against the background.
    viewer_->setBackgroundColor(SbColor(0.29f, 0.29f, 0.27f));
    viewer_->setSceneGraph(viewerRoot_);
    // The examiner viewer creates its GL widget as a child; without joining the layout it stays a
    // few pixels in the corner (the first screenshot of this window showed an empty viewport).
    viewport->layout()->addWidget(viewer_->getWidget());

    connect(quantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this](int index) { applyQuantity(index); });
    connect(deformation_, &QSlider::valueChanged, this, [this](int position) { applyDeformationSlider(position); });
    connect(trueScale, &QPushButton::clicked, this, [this]() {
        if (!scene_) return;
        const QSignalBlocker block(deformation_);
        deformation_->setValue(static_cast<int>(std::lround(100.0 / scene_->field().deformationAutoScale)));
        scene_->setDeformationScale(1.0);
        updateScaleLabel();
    });
    connect(report, &QPushButton::clicked, this, [this]() { saveReport(); });
}

bool StructuralResultWindow::openResult(const QString& resultPath) {
    QFile resultFile(resultPath);
    if (!resultFile.open(QIODevice::ReadOnly)) {
        QMessageBox::warning(this, tr("Результат прочности"), tr("Не удалось открыть %1").arg(resultPath));
        return false;
    }
    resultJson_ = resultFile.readAll();
    JsonValue result;
    std::string error;
    if (!fea::json::parseJson(resultJson_.toStdString(), result, error)
        || result.stringOr("schema", "") != "cadnext-structural-result/1") {
        QMessageBox::warning(this, tr("Результат прочности"), tr("Это не результат cadnext-structural-result/1"));
        return false;
    }
    const QString fieldName = QString::fromStdString(result.stringOr("fieldRef", ""));
    if (fieldName.isEmpty()) {
        QMessageBox::warning(this, tr("Результат прочности"),
                             result.stringOr("outcome", "") == "error"
                                 ? tr("Расчёт не завершён: %1").arg(QString::fromStdString(
                                       result.member("failureReasons") && !result.member("failureReasons")->arrayItems.empty()
                                           ? result.member("failureReasons")->arrayItems.front().stringValue
                                           : std::string("причина не указана")))
                                 : tr("У результата нет файла поля"));
        return false;
    }
    QFile fieldFile(QFileInfo(resultPath).dir().filePath(fieldName));
    if (!fieldFile.open(QIODevice::ReadOnly)) {
        QMessageBox::warning(this, tr("Результат прочности"), tr("Нет файла поля %1").arg(fieldName));
        return false;
    }
    fieldJson_ = fieldFile.readAll();
    auto field = fea::parseStructuralField(fieldJson_.toStdString());
    if (!field.isOk()) {
        QMessageBox::warning(this, tr("Результат прочности"), QString::fromStdString(field.error().message));
        return false;
    }
    resultPath_ = resultPath;

    if (scene_) viewerRoot_->removeChild(scene_->root());
    scene_ = std::make_unique<viewer::StructuralFieldScene>(field.value());
    viewerRoot_->addChild(scene_->root());
    // Framed after the window is laid out: before show() the viewport still has its default size,
    // and a camera fitted to that aspect crops the part once the real one applies.
    QTimer::singleShot(0, this, [this]() {
        SoCamera* camera = viewer_->getCamera();
        const QWidget* area = viewer_->getWidget();
        if (camera == nullptr || area == nullptr || !scene_) return;
        viewer::applyAxonometricZUpOrientation(*camera);
        scene_->frame(*camera, static_cast<double>(area->width()) / std::max(area->height(), 1));
    });

    const JsonValue* settings = result.member("settings");
    const JsonValue* loadCase = settings ? settings->member("loadCase") : nullptr;
    const QString loadCaseName = loadCase ? QString::fromStdString(loadCase->stringOr("name", "")) : QString();
    setWindowTitle(tr("Прочность — %1").arg(loadCaseName));
    title_->setText(loadCaseName.isEmpty() ? tr("Прочность") : loadCaseName);

    const QString outcome = QString::fromStdString(result.stringOr("outcome", ""));
    const QString colour = outcome == "pass" ? "#2e7d4f" : (outcome == "warning" ? "#a86500" : (outcome == "fail" ? "#b2182b" : "#5c5c5c"));
    verdict_->setText(QString("<span style='background:%1;color:white;padding:4px 10px;font-weight:700;font-family:Menlo'>&nbsp;%2&nbsp;</span>&nbsp;&nbsp;<span style='color:#9c9a92'>%3</span>")
                          .arg(colour, outcome.toUpper(), QString::fromStdString(result.stringOr("solverVersion", ""))));

    numbers_->setText("<table>" + metricLine(result, "maxVonMisesPa", tr("Макс. σ Мизеса"), "Pa")
                      + metricLine(result, "reserveFactor", tr("Коэффициент запаса"), "1")
                      + metricLine(result, "maxDisplacementM", tr("Макс. перемещение"), "m") + "</table>");

    QStringList reasons;
    for (const char* list : {"failureReasons", "warnings"}) {
        if (const JsonValue* items = result.member(list)) {
            for (const auto& item : items->arrayItems) reasons << "• " + QString::fromStdString(item.stringValue).toHtmlEscaped();
        }
    }
    reasons_->setText(reasons.isEmpty() ? QString()
                                        : QString("<b>%1</b><br>%2").arg(outcome == "pass" ? tr("Примечания") : tr("Почему не PASS"), reasons.join("<br>")));

    QString studyText = "<b>" + tr("Сходимость по сетке") + "</b><table>";
    if (const JsonValue* levels = result.member("meshStudy")) {
        for (const auto& level : levels->arrayItems) {
            studyText += QString("<tr><td>h %1 мм&nbsp;</td><td align=right>%2 эл.&nbsp;</td><td align=right>%3</td></tr>")
                             .arg(level.numberOr("maximumElementSizeM", 0) * 1000, 0, 'f', 2)
                             .arg(static_cast<qlonglong>(level.numberOr("elements", 0)))
                             .arg(si(level.numberOr("maxVonMisesPa", NAN), "Pa"));
        }
    }
    study_->setText(studyText + "</table>");

    {
        const QSignalBlocker block(deformation_);
        deformation_->setValue(100);
    }
    updateScaleLabel();
    applyQuantity(quantity_->currentIndex());
    return true;
}

void StructuralResultWindow::applyQuantity(int index) {
    if (!scene_) return;
    const auto quantity = index == 1 ? viewer::FieldQuantity::VonMises
                                     : (index == 2 ? viewer::FieldQuantity::Displacement : viewer::FieldQuantity::Utilization);
    scene_->setQuantity(quantity);
    JsonValue result;
    std::string error;
    double assessed = NAN;
    if (fea::json::parseJson(resultJson_.toStdString(), result, error)) {
        if (const JsonValue* entry = metricEntry(result, "maxVonMisesPa")) {
            assessed = entry->numberOr("value", NAN) / scene_->field().allowableStressPa;
        }
    }
    legend_->configure(scene_->field(), quantity, assessed);
}

void StructuralResultWindow::applyDeformationSlider(int position) {
    if (!scene_) return;
    scene_->setDeformationScale(scene_->field().deformationAutoScale * position / 100.0);
    updateScaleLabel();
}

void StructuralResultWindow::updateScaleLabel() {
    if (!scene_) return;
    const double scale = scene_->deformationScale();
    scaleLabel_->setText(QString("×%1").arg(scale >= 100 ? QString::number(std::lround(scale)) : QString::number(scale, 'g', 3)));
}

QImage StructuralResultWindow::snapshot() {
    if (viewer_ == nullptr) return grab().toImage();
    return detail::snapshotWithViewer(*this, *viewer_, viewerRoot_);
}

void StructuralResultWindow::saveReport() {
    if (resultPath_.isEmpty()) return;
    QString suggested = resultPath_;
    suggested.replace(".result.json", ".report.html");
    if (suggested == resultPath_) suggested += ".report.html";
    const QString path = QFileDialog::getSaveFileName(this, tr("HTML-отчёт"), suggested, tr("HTML (*.html)"));
    if (path.isEmpty()) return;
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        QMessageBox::warning(this, tr("HTML-отчёт"), tr("Не удалось записать %1").arg(path));
        return;
    }
    file.write(QByteArray::fromStdString(fea::structuralReportHtml(resultJson_.toStdString(), fieldJson_.toStdString())));
    file.close();
    QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

} // namespace cadnext::gui
