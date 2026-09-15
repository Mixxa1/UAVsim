#include "cadnext/gui/ModalResultWindow.hpp"

#include "ViewerSnapshot.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/StructuralReport.hpp"
#include "cadnext/viewer/ModalFieldScene.hpp"
#include "cadnext/viewer/StructuralFieldScene.hpp"

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/nodes/SoCamera.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoPerspectiveCamera.h>
#include <Inventor/nodes/SoSeparator.h>

#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QLabel>
#include <QLinearGradient>
#include <QMessageBox>
#include <QMouseEvent>
#include <QPainter>
#include <QPushButton>
#include <QScrollArea>
#include <QSlider>
#include <QSplitter>
#include <QTableWidget>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>
#include <functional>
#include <vector>

namespace cadnext::gui {

namespace {

using fea::json::JsonValue;

constexpr double kHalfPi = 1.5707963267948966;
// Display rate of the oscillation: the real frequency (tens to thousands of hertz) cannot be seen.
constexpr double kDisplayHz = 0.8;

const QColor kWarning(0xa8, 0x65, 0x00);
const QColor kAccent(0x26, 0x82, 0x8e);
const QColor kMuted(0x9c, 0x9a, 0x92);

QString hz(double value) {
    if (!std::isfinite(value)) return QStringLiteral("—");
    const double magnitude = std::fabs(value);
    if (magnitude >= 1000.0) return QString::number(value / 1000.0, 'f', magnitude >= 1e4 ? 2 : 3) + QStringLiteral(" кГц");
    return QString::number(value, 'f', magnitude >= 100 ? 1 : (magnitude >= 10 ? 2 : 3)) + QStringLiteral(" Гц");
}

QString percent(double fraction, int digits = 1) {
    return std::isfinite(fraction) ? QString::number(fraction * 100.0, 'f', digits) + QStringLiteral(" %") : QStringLiteral("—");
}

const JsonValue* member(const JsonValue* object, const char* name) {
    return object ? object->member(name) : nullptr;
}

} // namespace

// ---------------------------------------------------------------------------------------------
// Spectrum: modes with the band each was checked against the excitation with, and the bands.

class ModalSpectrum : public QWidget {
public:
    struct Mode {
        double frequencyHz = 0.0;
        double checkedUncertaintyHz = 0.0;
        bool overlaps = false;
    };
    struct Band {
        QString name;
        double minimumHz = 0.0;
        double maximumHz = 0.0;
    };

    explicit ModalSpectrum(QWidget* parent) : QWidget(parent) { setMinimumHeight(150); }

    void configure(std::vector<Mode> modes, std::vector<Band> bands, double margin) {
        modes_ = std::move(modes);
        bands_ = std::move(bands);
        margin_ = margin;
        update();
    }
    void setSelected(int index) {
        selected_ = index;
        update();
    }
    std::function<void(int)> onModeClicked;

protected:
    void paintEvent(QPaintEvent*) override {
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing);
        const QColor ink = palette().color(QPalette::WindowText);
        std::vector<double> values;
        for (const auto& m : modes_) {
            values.push_back(m.frequencyHz - m.checkedUncertaintyHz);
            values.push_back(m.frequencyHz + m.checkedUncertaintyHz);
        }
        for (const auto& b : bands_) {
            values.push_back(b.minimumHz * (1.0 - margin_));
            values.push_back(b.maximumHz * (1.0 + margin_));
        }
        double lo = INFINITY, hi = -INFINITY;
        for (double v : values) {
            if (v > 0.0) {
                lo = std::min(lo, v);
                hi = std::max(hi, v);
            }
        }
        if (!std::isfinite(lo) || !std::isfinite(hi)) {
            painter.setPen(kMuted);
            painter.drawText(rect(), Qt::AlignCenter, QStringLiteral("нет частот"));
            return;
        }
        // Log axis when the picture spans more than a decade, as in the HTML report.
        log_ = hi / lo > 10.0;
        if (log_) {
            lo /= 1.25;
            hi *= 1.25;
        } else {
            const double pad = hi > lo ? (hi - lo) * 0.08 : lo * 0.1;
            lo = std::max(0.0, lo - pad);
            hi += pad;
        }
        lo_ = lo;
        hi_ = hi;
        const double left = 10, right = width() - 10, top = 30, bottom = height() - 24;

        for (std::size_t i = 0; i < bands_.size(); ++i) {
            const auto& b = bands_[i];
            if (margin_ > 0.0) {
                const double x0 = x(b.minimumHz * (1.0 - margin_)), x1 = x(b.maximumHz * (1.0 + margin_));
                painter.fillRect(QRectF(x0, top, std::max(1.0, x1 - x0), bottom - top), QColor(kWarning.red(), kWarning.green(), kWarning.blue(), 22));
            }
            const double x0 = x(b.minimumHz), x1 = x(b.maximumHz);
            painter.setPen(QColor(kWarning.red(), kWarning.green(), kWarning.blue(), 140));
            painter.setBrush(QColor(kWarning.red(), kWarning.green(), kWarning.blue(), 55));
            painter.drawRect(QRectF(x0, top, std::max(1.0, x1 - x0), bottom - top));
            painter.setPen(kMuted);
            painter.drawText(QRectF((x0 + x1) / 2 - 80, top - 18 - (i % 2) * 12, 160, 14), Qt::AlignCenter, b.name);
        }
        painter.setBrush(Qt::NoBrush);
        painter.setPen(kMuted);
        painter.drawLine(QPointF(left, bottom), QPointF(right, bottom));
        std::vector<double> ticks;
        if (log_) {
            for (int e = static_cast<int>(std::floor(std::log10(lo))); e <= static_cast<int>(std::ceil(std::log10(hi))); ++e) {
                for (double m : {1.0, 2.0, 5.0}) {
                    const double v = m * std::pow(10.0, e);
                    if (v >= lo && v <= hi) ticks.push_back(v);
                }
            }
        } else {
            for (int i = 0; i <= 5; ++i) ticks.push_back(lo + (hi - lo) * i / 5.0);
        }
        for (double v : ticks) {
            painter.drawLine(QPointF(x(v), bottom), QPointF(x(v), bottom + 4));
            painter.drawText(QRectF(x(v) - 40, bottom + 5, 80, 16), Qt::AlignHCenter | Qt::AlignTop, hz(v));
        }
        for (std::size_t i = 0; i < modes_.size(); ++i) {
            const auto& m = modes_[i];
            const bool selected = static_cast<int>(i) == selected_;
            const QColor colour = selected ? kAccent : (m.overlaps ? kWarning : ink);
            painter.setPen(QPen(colour, selected ? 3.0 : (m.overlaps ? 2.5 : 1.5)));
            const double xm = x(m.frequencyHz);
            painter.drawLine(QPointF(xm, top), QPointF(xm, bottom));
            const double xa = x(m.frequencyHz - m.checkedUncertaintyHz), xb = x(m.frequencyHz + m.checkedUncertaintyHz);
            const double y = top + 12 + (i % 3) * 12;
            painter.setPen(QPen(colour, 1.0));
            painter.drawLine(QPointF(xa, y), QPointF(xb, y));
            painter.drawLine(QPointF(xa, y - 3), QPointF(xa, y + 3));
            painter.drawLine(QPointF(xb, y - 3), QPointF(xb, y + 3));
            painter.setPen(colour);
            painter.drawText(QPointF(xm + 3, bottom - 4 - (i % 3) * 12), QString::number(i + 1));
        }
    }

    void mousePressEvent(QMouseEvent* event) override {
        int best = -1;
        double bestDistance = 8.0;
        for (std::size_t i = 0; i < modes_.size(); ++i) {
            const double d = std::fabs(x(modes_[i].frequencyHz) - event->position().x());
            if (d < bestDistance) {
                bestDistance = d;
                best = static_cast<int>(i);
            }
        }
        if (best >= 0 && onModeClicked) onModeClicked(best);
    }

private:
    double x(double f) const {
        const double left = 10, right = width() - 10;
        const double t = log_ ? (std::log(std::max(f, lo_)) - std::log(lo_)) / (std::log(hi_) - std::log(lo_)) : (f - lo_) / (hi_ - lo_);
        return left + std::clamp(t, 0.0, 1.0) * (right - left);
    }

    std::vector<Mode> modes_;
    std::vector<Band> bands_;
    double margin_ = 0.0;
    int selected_ = 0;
    bool log_ = false;
    double lo_ = 1.0, hi_ = 10.0;
};

// ---------------------------------------------------------------------------------------------

class ModalLegend : public QWidget {
public:
    explicit ModalLegend(QWidget* parent) : QWidget(parent) { setMinimumHeight(118); }

    void configure(const fea::ModalFieldFile& field, int mode, const QString& band) {
        field_ = &field;
        mode_ = mode;
        band_ = band;
        update();
    }

protected:
    void paintEvent(QPaintEvent*) override {
        if (field_ == nullptr || mode_ >= static_cast<int>(field_->modes.size())) return;
        QPainter painter(this);
        QFont bold = font();
        bold.setBold(true);
        painter.setFont(bold);
        painter.setPen(palette().color(QPalette::WindowText));
        painter.drawText(QRect(0, 0, width(), 18), Qt::AlignLeft | Qt::AlignVCenter,
                         QString("Мода %1 — %2").arg(mode_ + 1).arg(hz(field_->modes[mode_].frequencyHz)));
        painter.setFont(font());
        if (!band_.isEmpty()) {
            painter.setPen(kWarning);
            painter.drawText(QRect(0, 18, width(), 16), Qt::AlignLeft | Qt::AlignVCenter, QString("в полосе «%1»").arg(band_));
        }
        const QRect bar(0, 38, width() - 1, 12);
        QLinearGradient gradient(bar.topLeft(), bar.topRight());
        for (const auto& stop : field_->colorStops) gradient.setColorAt(stop.position, QColor::fromRgbF(stop.rgb[0], stop.rgb[1], stop.rgb[2]));
        painter.fillRect(bar, gradient);
        painter.setPen(palette().color(QPalette::WindowText));
        painter.drawText(QRect(0, 52, 60, 14), Qt::AlignLeft, "0");
        painter.drawText(QRect(width() / 2 - 30, 52, 60, 14), Qt::AlignHCenter, "0.5");
        painter.drawText(QRect(width() - 60, 52, 60, 14), Qt::AlignRight, "1");
        painter.setPen(kMuted);
        painter.drawText(QRect(0, 70, width(), 48), Qt::AlignLeft | Qt::AlignTop | Qt::TextWordWrap,
                         QStringLiteral("Относительная амплитуда формы (максимум = 1). Размах на экране условный, не миллиметры: "
                                        "амплитуду задают возбуждение и демпфирование, которых модальный анализ не знает."));
    }

private:
    const fea::ModalFieldFile* field_ = nullptr;
    int mode_ = 0;
    QString band_;
};

// ---------------------------------------------------------------------------------------------

ModalResultWindow::ModalResultWindow(QWidget* parent) : AnalysisResultWindow(parent) {
    setAttribute(Qt::WA_DeleteOnClose);
    resize(1280, 860);
    buildInterface();
}

ModalResultWindow::~ModalResultWindow() {
    if (timer_ != nullptr) timer_->stop();
    delete viewer_;
    if (viewerRoot_ != nullptr) viewerRoot_->unref();
}

void ModalResultWindow::buildInterface() {
    auto* splitter = new QSplitter(this);
    auto* left = new QWidget(splitter);
    auto* leftLayout = new QVBoxLayout(left);
    leftLayout->setContentsMargins(0, 0, 0, 0);
    auto* viewport = new QWidget(left);
    new QVBoxLayout(viewport);
    viewport->layout()->setContentsMargins(0, 0, 0, 0);
    spectrum_ = new ModalSpectrum(left);
    auto* spectrumTitle = new QLabel(tr("<b>Спектр: моды и полосы возбуждения</b> — усы показывают погрешность, с которой мода проверялась на пересечение"));
    spectrumTitle->setWordWrap(true);
    spectrumTitle->setContentsMargins(10, 6, 10, 0);
    leftLayout->addWidget(viewport, 1);
    leftLayout->addWidget(spectrumTitle);
    leftLayout->addWidget(spectrum_);

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
    numbers_->setWordWrap(true);
    reasons_ = new QLabel;
    reasons_->setWordWrap(true);
    reasons_->setTextFormat(Qt::RichText);
    play_ = new QPushButton;
    amplitude_ = new QSlider(Qt::Horizontal);
    amplitude_->setRange(0, 300);
    amplitude_->setValue(100);
    legend_ = new ModalLegend(panel);
    modes_ = new QTableWidget(0, 7);
    modes_->setHorizontalHeaderLabels({"#", tr("частота"), tr("± сетка"), "m x", "m y", "m z", tr("отстройка")});
    modes_->verticalHeader()->hide();
    modes_->setEditTriggers(QAbstractItemView::NoEditTriggers);
    modes_->setSelectionBehavior(QAbstractItemView::SelectRows);
    modes_->setSelectionMode(QAbstractItemView::SingleSelection);
    modes_->horizontalHeader()->setSectionResizeMode(QHeaderView::ResizeToContents);
    modes_->setMinimumHeight(160);
    auto* modesNote = new QLabel(tr("m — эффективная масса вдоль оси, доля массы свободных степеней свободы. Моды сопоставлены между сетками по порядку."));
    modesNote->setWordWrap(true);
    modesNote->setStyleSheet("color:#9c9a92");
    conditions_ = new QLabel;
    conditions_->setTextFormat(Qt::RichText);
    conditions_->setWordWrap(true);
    study_ = new QLabel;
    study_->setTextFormat(Qt::RichText);
    study_->setWordWrap(true);
    auto* report = new QPushButton(tr("Сохранить HTML-отчёт…"));

    layout->addWidget(title_);
    layout->addWidget(verdict_);
    layout->addWidget(numbers_);
    layout->addWidget(reasons_);
    auto* animation = new QHBoxLayout;
    animation->addWidget(play_);
    animation->addWidget(new QLabel(tr("Амплитуда")));
    animation->addWidget(amplitude_, 1);
    layout->addLayout(animation);
    layout->addWidget(legend_);
    layout->addWidget(modes_);
    layout->addWidget(modesNote);
    layout->addWidget(conditions_);
    layout->addWidget(study_);
    layout->addStretch(1);
    layout->addWidget(report);

    auto* scroll = new QScrollArea(splitter);
    scroll->setWidgetResizable(true);
    scroll->setWidget(panel);
    scroll->setMinimumWidth(460);
    scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    splitter->addWidget(left);
    splitter->addWidget(scroll);
    splitter->setStretchFactor(0, 1);
    splitter->setSizes({820, 460});
    setCentralWidget(splitter);

    viewerRoot_ = new SoSeparator;
    viewerRoot_->ref();
    viewerRoot_->addChild(new SoPerspectiveCamera);
    viewer_ = new SoQtExaminerViewer(viewport);
    viewer_->setDecoration(FALSE);
    viewer_->setHeadlight(TRUE);
    viewer_->getHeadlight()->intensity = viewer::kStructuralHeadlightIntensity;
    viewer_->setBackgroundColor(SbColor(0.29f, 0.29f, 0.27f));
    viewer_->setSceneGraph(viewerRoot_);
    viewport->layout()->addWidget(viewer_->getWidget());

    timer_ = new QTimer(this);
    timer_->setInterval(33);
    connect(timer_, &QTimer::timeout, this, [this]() { advanceAnimation(); });
    connect(play_, &QPushButton::clicked, this, [this]() { setPlaying(!playing_); });
    connect(amplitude_, &QSlider::valueChanged, this, [this](int value) {
        if (scene_) scene_->setAmplitude(value / 100.0);
    });
    connect(modes_, &QTableWidget::itemSelectionChanged, this, [this]() {
        const auto rows = modes_->selectionModel()->selectedRows();
        if (!rows.isEmpty()) selectMode(rows.front().row());
    });
    spectrum_->onModeClicked = [this](int index) { selectMode(index); };
    connect(report, &QPushButton::clicked, this, [this]() { saveReport(); });
}

bool ModalResultWindow::openResult(const QString& resultPath) {
    const QString caption = tr("Собственные частоты");
    QFile resultFile(resultPath);
    if (!resultFile.open(QIODevice::ReadOnly)) {
        QMessageBox::warning(this, caption, tr("Не удалось открыть %1").arg(resultPath));
        return false;
    }
    resultJson_ = resultFile.readAll();
    JsonValue result;
    std::string error;
    if (!fea::json::parseJson(resultJson_.toStdString(), result, error) || result.stringOr("schema", "") != "cadnext-modal-result/1") {
        QMessageBox::warning(this, caption, tr("Это не результат cadnext-modal-result/1"));
        return false;
    }
    const QString fieldName = QString::fromStdString(result.stringOr("fieldRef", ""));
    if (fieldName.isEmpty()) {
        const JsonValue* reasons = result.member("failureReasons");
        QMessageBox::warning(this, caption,
                             result.stringOr("outcome", "") == "error"
                                 ? tr("Расчёт не завершён: %1").arg(QString::fromStdString(
                                       reasons && !reasons->arrayItems.empty() ? reasons->arrayItems.front().stringValue : "причина не указана"))
                                 : tr("У результата нет файла форм мод"));
        return false;
    }
    QFile fieldFile(QFileInfo(resultPath).dir().filePath(fieldName));
    if (!fieldFile.open(QIODevice::ReadOnly)) {
        QMessageBox::warning(this, caption, tr("Нет файла форм мод %1").arg(fieldName));
        return false;
    }
    fieldJson_ = fieldFile.readAll();
    auto field = fea::parseModalField(fieldJson_.toStdString());
    if (!field.isOk()) {
        QMessageBox::warning(this, caption, QString::fromStdString(field.error().message));
        return false;
    }
    resultPath_ = resultPath;

    if (scene_) viewerRoot_->removeChild(scene_->root());
    scene_ = std::make_unique<viewer::ModalFieldScene>(field.value());
    scene_->setAmplitude(amplitude_->value() / 100.0);
    viewerRoot_->addChild(scene_->root());
    QTimer::singleShot(0, this, [this]() {
        SoCamera* camera = viewer_->getCamera();
        const QWidget* area = viewer_->getWidget();
        if (camera == nullptr || area == nullptr || !scene_) return;
        viewer::applyAxonometricZUpOrientation(*camera);
        scene_->frame(*camera, static_cast<double>(area->width()) / std::max(area->height(), 1));
    });

    const JsonValue* settings = result.member("settings");
    const JsonValue* loadCase = member(settings, "loadCase");
    const JsonValue* modal = member(settings, "modal");
    const QString name = loadCase ? QString::fromStdString(loadCase->stringOr("name", "")) : QString();
    setWindowTitle(tr("Собственные частоты — %1").arg(name));
    title_->setText(name.isEmpty() ? caption : caption + " — " + name);

    const QString outcome = QString::fromStdString(result.stringOr("outcome", ""));
    const QString colour = outcome == "pass" ? "#2e7d4f" : (outcome == "warning" ? "#a86500" : (outcome == "fail" ? "#b2182b" : "#5c5c5c"));
    verdict_->setText(QString("<span style='background:%1;color:white;padding:4px 10px;font-weight:700;font-family:Menlo'>&nbsp;%2&nbsp;</span>&nbsp;&nbsp;<span style='color:#9c9a92'>%3</span>")
                          .arg(colour, outcome.toUpper(), QString::fromStdString(result.stringOr("solverVersion", ""))));

    // Modes, findings and bands as the result states them.
    const JsonValue* modeItems = result.member("modes");
    const JsonValue* findingItems = result.member("resonance");
    const JsonValue* bandItems = result.member("excitationBands");
    const double margin = result.numberOr("separationMargin", 0.0);
    std::vector<ModalSpectrum::Mode> spectrumModes;
    std::vector<ModalSpectrum::Band> spectrumBands;
    int overlapCount = 0;
    int firstOverlap = -1;
    const int modeCount = modeItems ? static_cast<int>(modeItems->arrayItems.size()) : 0;
    {
        const QSignalBlocker block(modes_);
        modes_->setRowCount(modeCount);
        for (int i = 0; i < modeCount; ++i) {
            const JsonValue& mode = modeItems->arrayItems[i];
            const JsonValue* finding = findingItems && i < static_cast<int>(findingItems->arrayItems.size()) ? &findingItems->arrayItems[i] : nullptr;
            const bool overlaps = finding && finding->boolOr("overlaps", false);
            if (overlaps) {
                ++overlapCount;
                if (firstOverlap < 0) firstOverlap = i;
            }
            spectrumModes.push_back({mode.numberOr("frequencyHz", NAN), mode.numberOr("resonanceUncertaintyHz", 0.0), overlaps});
            const JsonValue* band = mode.member("numericalUncertaintyHz");
            const JsonValue* convergence = mode.member("convergence");
            const JsonValue* mass = mode.member("effectiveMassFraction");
            QStringList cells = {QString::number(i + 1), hz(mode.numberOr("frequencyHz", NAN)),
                                 band ? hz(band->numberValue)
                                      : tr("не оценена (%1)").arg(QString::fromStdString(convergence ? convergence->stringOr("behaviour", "") : ""))};
            for (int d = 0; d < 3; ++d) {
                cells << (mass && mass->arrayItems.size() == 3 ? percent(mass->arrayItems[d].numberValue) : QStringLiteral("—"));
            }
            cells << (finding ? percent(finding->numberOr("separation", NAN)) + (overlaps ? tr(" — в «%1»") : tr(" от «%1»")).arg(QString::fromStdString(finding->stringOr("nearestBand", "")))
                              : QStringLiteral("—"));
            for (int c = 0; c < cells.size(); ++c) {
                auto* item = new QTableWidgetItem(cells[c]);
                if (c > 0 && c < 6) item->setTextAlignment(Qt::AlignRight | Qt::AlignVCenter);
                if (overlaps) item->setForeground(kWarning);
                modes_->setItem(i, c, item);
            }
        }
    }
    if (bandItems) {
        for (const auto& band : bandItems->arrayItems) {
            spectrumBands.push_back({QString::fromStdString(band.stringOr("name", "")), band.numberOr("minimumHz", 0.0), band.numberOr("maximumHz", 0.0)});
        }
    }
    spectrum_->configure(spectrumModes, spectrumBands, margin);

    const JsonValue* metrics = result.member("metrics");
    const JsonValue* first = member(metrics, "firstFrequencyHz");
    const JsonValue* separation = member(metrics, "minimumBandSeparation");
    QString numbers = "<table>";
    auto row = [&](const QString& label, const QString& value, const QString& note) {
        numbers += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2</b></td></tr>"
                           "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
                       .arg(label, value, note);
    };
    row(tr("Первая частота"), first ? hz(first->numberOr("value", NAN)) : "—",
        first ? (first->member("numericalUncertainty") ? tr("± %1 (сетка)").arg(hz(first->member("numericalUncertainty")->numberValue)) : tr("погрешность не оценена")) : QString());
    row(tr("Мин. отстройка от полос"), separation ? percent(separation->numberOr("value", NAN)) : "—",
        spectrumBands.empty() ? tr("полосы не заданы — резонанс не проверен")
                              : (overlapCount ? tr("пересечений: %1").arg(overlapCount) : tr("пересечений нет"))
                                    + (margin > 0 ? tr(" · запас ±%1").arg(percent(margin, 0)) : QString()));
    row(tr("Деталь"), result.stringOr("boundary", "") == "free" ? tr("свободная") : tr("закреплённая"),
        tr("масса %1 кг").arg(result.numberOr("totalMassKg", NAN), 0, 'f', 3)
            + (result.stringOr("boundary", "") == "free" ? tr("; 6 мод движения как целого не показаны") : QString()));
    numbers_->setText(numbers + "</table>");

    QStringList reasons;
    for (const char* list : {"failureReasons", "warnings"}) {
        if (const JsonValue* items = result.member(list)) {
            for (const auto& item : items->arrayItems) reasons << "• " + QString::fromStdString(item.stringValue).toHtmlEscaped();
        }
    }
    reasons_->setText(reasons.isEmpty() ? QString()
                                        : QString("<b>%1</b><br>%2").arg(outcome == "pass" ? tr("Примечания") : tr("Почему не PASS"), reasons.join("<br>")));

    QString conditions = "<b>" + tr("Опоры") + "</b><br>";
    const JsonValue* supports = member(loadCase, "supports");
    if (supports == nullptr || supports->arrayItems.empty()) {
        conditions += tr("нет — свободная деталь, как планер в полёте");
    } else {
        QStringList lines;
        for (const auto& support : supports->arrayItems) {
            QStringList axes;
            if (const JsonValue* fix = support.member("fix"))
                for (const auto& axis : fix->arrayItems) axes << QString::fromStdString(axis.stringValue).toUpper();
            lines << QString::fromStdString(support.stringOr("face", "")) + ": " + (axes.size() == 3 ? tr("жёсткая заделка") : tr("закреплено %1").arg(axes.join("")));
        }
        conditions += lines.join("<br>");
    }
    conditions += "<br><b>" + tr("Возбуждение") + "</b><br>";
    QStringList excitation;
    if (const JsonValue* rotors = member(modal, "rotors")) {
        for (const auto& rotor : rotors->arrayItems) {
            const double lo = rotor.numberOr("minimumRpm", 0), high = rotor.numberOr("maximumRpm", 0);
            const int blades = static_cast<int>(rotor.numberOr("bladeCount", 0));
            excitation << tr("%1: %2–%3 об/мин, лопастей %4 → 1P %5–%6, %4P %7–%8")
                              .arg(QString::fromStdString(rotor.stringOr("name", "")).toHtmlEscaped())
                              .arg(lo).arg(high).arg(blades)
                              .arg(hz(lo / 60), hz(high / 60), hz(lo * blades / 60), hz(high * blades / 60));
        }
    }
    if (const JsonValue* bands = member(modal, "bands")) {
        for (const auto& band : bands->arrayItems) {
            excitation << QString("%1: %2–%3").arg(QString::fromStdString(band.stringOr("name", "")).toHtmlEscaped(),
                                                   hz(band.numberOr("minimumHz", NAN)), hz(band.numberOr("maximumHz", NAN)));
        }
    }
    excitation << (margin > 0 ? tr("запас ±%1 к каждой полосе").arg(percent(margin, 0)) : tr("запас по частоте не задан (0)"));
    conditions_->setText(conditions + excitation.join("<br>"));

    QString studyText = "<b>" + tr("Сходимость по сетке") + "</b><table><tr><td>h, мм&nbsp;</td><td align=right>эл.&nbsp;</td>";
    for (int i = 0; i < modeCount; ++i) studyText += QString("<td align=right>&nbsp;f%1</td>").arg(i + 1);
    studyText += "</tr>";
    if (const JsonValue* levels = result.member("meshStudy")) {
        for (const auto& level : levels->arrayItems) {
            studyText += QString("<tr><td>%1</td><td align=right>%2</td>")
                             .arg(level.numberOr("maximumElementSizeM", 0) * 1000, 0, 'f', 2)
                             .arg(static_cast<qlonglong>(level.numberOr("elements", 0)));
            if (const JsonValue* frequencies = level.member("frequenciesHz"))
                for (const auto& f : frequencies->arrayItems) studyText += "<td align=right>&nbsp;" + hz(f.numberValue) + "</td>";
            studyText += "</tr>";
        }
    }
    study_->setText(studyText + "</table>");

    // Open on the first mode in a band, if any: that is what the verdict is about.
    selectMode(std::max(0, firstOverlap));
    setPlaying(true);
    return true;
}

void ModalResultWindow::selectMode(int index) {
    if (!scene_ || index < 0 || index >= static_cast<int>(scene_->field().modes.size())) return;
    scene_->setMode(index);
    spectrum_->setSelected(index);
    {
        const QSignalBlocker block(modes_);
        modes_->selectRow(index);
    }
    QString band;
    JsonValue result;
    std::string error;
    if (fea::json::parseJson(resultJson_.toStdString(), result, error)) {
        const JsonValue* findings = result.member("resonance");
        if (findings && index < static_cast<int>(findings->arrayItems.size()) && findings->arrayItems[index].boolOr("overlaps", false)) {
            band = QString::fromStdString(findings->arrayItems[index].stringOr("nearestBand", ""));
        }
    }
    legend_->configure(scene_->field(), index, band);
}

int ModalResultWindow::selectedMode() const {
    return scene_ ? scene_->mode() : -1;
}

void ModalResultWindow::setPlaying(bool playing) {
    playing_ = playing;
    play_->setText(playing ? tr("❚❚ Пауза") : tr("▶ Анимация"));
    if (playing) {
        clock_.restart();
        timer_->start();
    } else {
        timer_->stop();
        phase_ = kHalfPi;
        if (scene_) scene_->setPhase(phase_);
    }
}

void ModalResultWindow::advanceAnimation() {
    if (!scene_) return;
    phase_ = std::fmod(phase_ + clock_.restart() / 1000.0 * 2.0 * M_PI * kDisplayHz, 2.0 * M_PI);
    scene_->setPhase(phase_);
}

QImage ModalResultWindow::snapshot() {
    if (viewer_ == nullptr || !scene_) return grab().toImage();
    scene_->setPhase(kHalfPi);
    QImage image = detail::snapshotWithViewer(*this, *viewer_, viewerRoot_);
    scene_->setPhase(phase_);
    return image;
}

void ModalResultWindow::saveReport() {
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
    file.write(QByteArray::fromStdString(fea::modalReportHtml(resultJson_.toStdString(), fieldJson_.toStdString())));
    file.close();
    QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

} // namespace cadnext::gui
