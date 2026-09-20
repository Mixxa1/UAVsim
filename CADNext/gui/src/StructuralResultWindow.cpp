#include "cadnext/gui/StructuralResultWindow.hpp"

#include "ViewerSnapshot.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/viewer/StructuralFieldScene.hpp"

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/nodes/SoCamera.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoPerspectiveCamera.h>
#include <Inventor/nodes/SoSeparator.h>

#include <QComboBox>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLinearGradient>
#include <QMessageBox>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QPushButton>
#include <QScrollArea>
#include <QSlider>
#include <QSplitter>
#include <QTimer>
#include <QVBoxLayout>
#include <QTreeWidget>
#include <QCheckBox>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>

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

    void configure(const fea::StructuralFieldFile& field, viewer::FieldQuantity quantity, double assessedUtilization,
                   const QString& vibrationNote = {}) {
        vibrationNote_ = vibrationNote;
        setMinimumHeight(vibrationNote.isEmpty() ? 118 : 150);
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
        } else if (quantity_ == viewer::FieldQuantity::Temperature && !field_->temperatureK.empty()) {
            const auto [lo, hi] = std::minmax_element(field_->temperatureK.begin(), field_->temperatureK.end());
            title = QStringLiteral("Температура, °C — от самой холодной до самой горячей точки");
            auto celsius = [](double k) { return QString::number(k - 273.15, 'f', 2) + QStringLiteral(" °C"); };
            ticks = {celsius(*lo), celsius(0.5 * (*lo + *hi)), celsius(*hi)};
        } else if (quantity_ == viewer::FieldQuantity::IceThickness && !field_->iceThicknessM.empty()) {
            const auto [lo, hi] = std::minmax_element(field_->iceThicknessM.begin(), field_->iceThicknessM.end());
            title = QStringLiteral("Толщина льда — от чистой поверхности до самой обледеневшей");
            auto millimetres = [](double value) { return QString::number(value * 1e3, 'f', 2) + QStringLiteral(" мм"); };
            ticks = {millimetres(*lo), millimetres(0.5 * (*lo + *hi)), millimetres(*hi)};
        } else if (quantity_ == viewer::FieldQuantity::ElectricField && !field_->electricFieldVm.empty()) {
            const auto [lo, hi] = std::minmax_element(field_->electricFieldVm.begin(), field_->electricFieldVm.end());
            title = QStringLiteral("|E| на поверхности — от самой слабой до самой сильной точки");
            auto volts = [](double value) { return QString::number(value, 'g', 3) + QStringLiteral(" В/м"); };
            ticks = {volts(*lo), volts(0.5 * (*lo + *hi)), volts(*hi)};
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
        if (!vibrationNote_.isEmpty()) {
            const int top = quantity_ == viewer::FieldQuantity::Utilization ? 116 : 60;
            painter.drawText(QRect(0, top, width(), 40), Qt::AlignLeft | Qt::AlignTop | Qt::TextWordWrap, vibrationNote_);
        }
    }

private:
    const fea::StructuralFieldFile* field_ = nullptr;
    viewer::FieldQuantity quantity_ = viewer::FieldQuantity::Utilization;
    double assessedUtilization_ = 0.0;
    QString vibrationNote_;
};

// One response curve against frequency or time: log–log for sweeps and spectra, linear for time
// histories (signed values). Natural frequencies as dashed lines (frequency axes), the allowable as a red
// line, the worst point marked, and the computed value nearest the mouse — never an interpolated one.
class ResponsePlot : public QWidget {
public:
    struct Series {
        QString title, unit;
        std::vector<double> values;
        double scale = 1.0;       // display = value / scale
        double limit = NAN;       // a horizontal line (allowable), in the same units as values
        QString limitLabel;
        bool logX = true, logY = true;
        QString xUnit = QStringLiteral("Гц");
        double xScale = 1.0;      // display x = x / xScale
        // Own abscissa and worst point, when the series does not share the plot's (a spectrum next to
        // time histories).
        std::vector<double> x;
        double worstX = NAN;
    };

    explicit ResponsePlot(QWidget* parent) : QWidget(parent) {
        setMinimumHeight(230);
        setMouseTracking(true);
    }

    void setData(std::vector<double> xs, std::vector<double> modes, double worstX) {
        xs_ = std::move(xs);
        modes_ = std::move(modes);
        worstX_ = worstX;
        update();
    }
    void setSeries(Series series) {
        if (!series.x.empty()) {
            xs_ = series.x;
            worstX_ = series.worstX;
        }
        series_ = std::move(series);
        update();
    }

protected:
    void mouseMoveEvent(QMouseEvent* event) override {
        cursorX_ = event->position().x();
        update();
    }
    void leaveEvent(QEvent*) override {
        cursorX_ = -1;
        update();
    }

    static std::vector<double> niceTicks(double low, double high) {
        const double span = high - low;
        if (!(span > 0.0)) return {low};
        const double raw = span / 6.0, magnitude = std::pow(10.0, std::floor(std::log10(raw)));
        double step = magnitude;
        for (double m : {1.0, 2.0, 5.0, 10.0})
            if (m * magnitude >= raw) { step = m * magnitude; break; }
        std::vector<double> ticks;
        for (double v = std::ceil(low / step) * step; v <= high + 1e-9 * step; v += step) ticks.push_back(std::fabs(v) < 1e-12 * step ? 0.0 : v);
        return ticks;
    }

    void paintEvent(QPaintEvent*) override {
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing);
        const QColor text = palette().color(QPalette::WindowText), faint(0x9c, 0x9a, 0x92), grid(0x3a, 0x3a, 0x37);
        painter.fillRect(rect(), QColor(0x24, 0x24, 0x22));
        if (xs_.size() < 2 || series_.values.size() != xs_.size()) {
            painter.setPen(faint);
            painter.drawText(rect(), Qt::AlignCenter, QStringLiteral("Нет данных"));
            return;
        }
        plot_ = rect().adjusted(64, 26, -16, -30);
        const bool logX = series_.logX, logY = series_.logY;
        // Axis ranges in plot coordinates (log10 or linear).
        xLow_ = logX ? std::log10(xs_.front()) : xs_.front();
        xHigh_ = logX ? std::log10(xs_.back()) : xs_.back();
        if (logY) {
            double low = INFINITY, high = 0.0;
            for (double v : series_.values)
                if (v > 0.0) { low = std::min(low, v); high = std::max(high, v); }
            if (std::isfinite(series_.limit) && series_.limit > 0.0) high = std::max(high, series_.limit * 1.1);
            if (!(high > 0.0) || !std::isfinite(low)) return;
            // Six decades: a spectrum's valleys between modes are real and sit far below its peaks.
            low = std::max(low, high * 1e-6);
            yLow_ = std::floor(std::log10(low));
            yHigh_ = std::ceil(std::log10(high));
            if (yHigh_ - yLow_ < 1) yHigh_ = yLow_ + 1;
        } else {
            double low = 0.0, high = 0.0;
            for (double v : series_.values) { low = std::min(low, v); high = std::max(high, v); }
            if (std::isfinite(series_.limit)) high = std::max(high, series_.limit * 1.05);
            const double pad = 0.05 * std::max(high - low, 1e-30);
            yLow_ = low - pad;
            yHigh_ = high + pad;
        }
        auto X = [&](double x) { return xOf(logX ? std::log10(x) : x); };
        auto Y = [&](double v) {
            if (logY) return yOf(std::log10(std::max(v, std::pow(10.0, yLow_))));
            return yOf(v);
        };

        painter.setPen(text);
        QFont bold = font();
        bold.setBold(true);
        painter.setFont(bold);
        painter.drawText(QRect(8, 4, width() - 16, 20), Qt::AlignLeft | Qt::AlignVCenter, series_.title + ", " + series_.unit);
        painter.setFont(font());
        // Grid and labels.
        if (logY) {
            for (int d = static_cast<int>(yLow_); d <= static_cast<int>(yHigh_); ++d) {
                for (int m = 1; m < 10; ++m) {
                    const double value = std::log10(m * std::pow(10.0, d));
                    if (value > yHigh_) break;
                    painter.setPen(grid);
                    painter.drawLine(plot_.left(), yOf(value), plot_.right(), yOf(value));
                }
                painter.setPen(faint);
                painter.drawText(QRect(0, yOf(d) - 8, plot_.left() - 6, 16), Qt::AlignRight | Qt::AlignVCenter,
                                 QString::number(std::pow(10.0, d) / series_.scale, 'g', 3));
            }
        } else {
            for (double v : niceTicks(yLow_, yHigh_)) {
                painter.setPen(v == 0.0 ? faint : grid);
                painter.drawLine(plot_.left(), yOf(v), plot_.right(), yOf(v));
                painter.setPen(faint);
                painter.drawText(QRect(0, yOf(v) - 8, plot_.left() - 6, 16), Qt::AlignRight | Qt::AlignVCenter, QString::number(v / series_.scale, 'g', 3));
            }
        }
        if (logX) {
            for (int d = static_cast<int>(std::floor(xLow_)); d <= static_cast<int>(std::ceil(xHigh_)); ++d) {
                for (int m = 1; m < 10; ++m) {
                    const double value = std::log10(m * std::pow(10.0, d));
                    if (value < xLow_ || value > xHigh_) continue;
                    painter.setPen(grid);
                    painter.drawLine(xOf(value), plot_.top(), xOf(value), plot_.bottom());
                    if (m == 1 || m == 2 || m == 5) {
                        painter.setPen(faint);
                        painter.drawText(QRect(xOf(value) - 30, plot_.bottom() + 4, 60, 16), Qt::AlignHCenter,
                                         QString::number(m * std::pow(10.0, d) / series_.xScale, 'g', 4));
                    }
                }
            }
        } else {
            // Ticks in the units the axis is labelled in (hours of a day, not every 20 000 s).
            for (double shown : niceTicks(xLow_ / series_.xScale, xHigh_ / series_.xScale)) {
                const double v = shown * series_.xScale;
                painter.setPen(grid);
                painter.drawLine(xOf(v), plot_.top(), xOf(v), plot_.bottom());
                painter.setPen(faint);
                painter.drawText(QRect(xOf(v) - 30, plot_.bottom() + 4, 60, 16), Qt::AlignHCenter, QString::number(shown, 'g', 4));
            }
        }
        painter.setPen(faint);
        painter.drawText(QRect(plot_.right() - 60, plot_.bottom() + 14, 60, 16), Qt::AlignRight, series_.xUnit);
        // Natural frequencies (frequency axes only).
        if (series_.xUnit == QStringLiteral("Гц")) {
            QPen modePen(QColor(0x8a, 0xa8, 0xd8), 1, Qt::DashLine);
            for (std::size_t i = 0; i < modes_.size(); ++i) {
                if (modes_[i] < xs_.front() || modes_[i] > xs_.back()) continue;
                const int x = X(modes_[i]);
                painter.setPen(modePen);
                painter.drawLine(x, plot_.top(), x, plot_.bottom());
                painter.setPen(QColor(0x8a, 0xa8, 0xd8));
                painter.drawText(QRect(x + 3, plot_.top(), 60, 14), Qt::AlignLeft, QString("f%1").arg(i + 1));
            }
        }
        if (std::isfinite(series_.limit) && (!logY || series_.limit > 0.0)) {
            const int y = Y(series_.limit);
            painter.setPen(QPen(QColor(0xd6, 0x45, 0x3d), 1.5));
            painter.drawLine(plot_.left(), y, plot_.right(), y);
            painter.drawText(QRect(plot_.left() + 4, y - 16, plot_.width() - 8, 14), Qt::AlignRight, series_.limitLabel);
        }
        QPainterPath path;
        bool started = false;
        for (std::size_t i = 0; i < xs_.size(); ++i) {
            if (logY && !(series_.values[i] > 0.0)) continue;
            const QPointF p(X(xs_[i]), Y(series_.values[i]));
            if (!started) { path.moveTo(p); started = true; } else path.lineTo(p);
        }
        painter.setPen(QPen(QColor(0xf2, 0xc1, 0x4e), 2));
        painter.drawPath(path);
        // Worst point (NaN when there is none; NaN compares false, hence the explicit test).
        for (std::size_t i = 0; std::isfinite(worstX_) && i < xs_.size(); ++i) {
            if (std::fabs(xs_[i] - worstX_) > 1e-9 * std::fabs(worstX_)) continue;
            painter.setBrush(QColor(0xd6, 0x45, 0x3d));
            painter.setPen(Qt::NoPen);
            painter.drawEllipse(QPointF(X(xs_[i]), Y(series_.values[i])), 4.5, 4.5);
            painter.setBrush(Qt::NoBrush);
        }
        if (cursorX_ >= plot_.left() && cursorX_ <= plot_.right()) {
            const double position = xLow_ + (cursorX_ - plot_.left()) / plot_.width() * (xHigh_ - xLow_);
            const double target = logX ? std::pow(10.0, position) : position;
            std::size_t nearest = 0;
            for (std::size_t i = 1; i < xs_.size(); ++i)
                if (std::fabs(xs_[i] - target) < std::fabs(xs_[nearest] - target)) nearest = i;
            const int x = X(xs_[nearest]);
            painter.setPen(QPen(text, 1, Qt::DotLine));
            painter.drawLine(x, plot_.top(), x, plot_.bottom());
            painter.setPen(text);
            painter.drawText(QRect(plot_.left() + 8, plot_.top() + 2, plot_.width() - 16, 16), Qt::AlignLeft,
                             QString("%1 %2: %3 %4").arg(xs_[nearest] / series_.xScale, 0, 'g', 5).arg(series_.xUnit)
                                 .arg(series_.values[nearest] / series_.scale, 0, 'g', 4).arg(series_.unit));
        }
    }

private:
    int xOf(double v) const { return plot_.left() + static_cast<int>((v - xLow_) / (xHigh_ - xLow_) * plot_.width()); }
    int yOf(double v) const { return plot_.bottom() - static_cast<int>((v - yLow_) / (yHigh_ - yLow_) * plot_.height()); }

    std::vector<double> xs_, modes_;
    double worstX_ = NAN;
    Series series_;
    QRect plot_;
    double yLow_ = 0, yHigh_ = 1, xLow_ = 0, xHigh_ = 1;
    double cursorX_ = -1;
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
    auto* left = new QSplitter(Qt::Vertical, splitter);
    viewSplitter_ = left;
    auto* viewport = new QWidget(left);
    new QVBoxLayout(viewport);
    viewport->layout()->setContentsMargins(0, 0, 0, 0);
    // Sine sweep response under the part; hidden for a static result.
    responseBox_ = new QWidget(left);
    auto* responseLayout = new QVBoxLayout(responseBox_);
    responseLayout->setContentsMargins(0, 0, 0, 0);
    auto* responseRow = new QHBoxLayout;
    responseRow->addWidget(new QLabel(tr("Отклик")));
    responseQuantity_ = new QComboBox;
    responseRow->addWidget(responseQuantity_, 1);
    responseLayout->addLayout(responseRow);
    response_ = new ResponsePlot(responseBox_);
    responseLayout->addWidget(response_, 1);
    responseBox_->hide();
    left->setStretchFactor(0, 3);
    left->setStretchFactor(1, 2);

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
    meshVisible_=new QCheckBox(tr("Показать сетку"));criticalVisible_=new QCheckBox(tr("Критическая точка"));criticalVisible_->setChecked(true);
    view->addRow(meshVisible_);view->addRow(criticalVisible_);
    connect(meshVisible_,&QCheckBox::toggled,this,[this](bool v){if(scene_)scene_->setMeshVisible(v);});
    connect(criticalVisible_,&QCheckBox::toggled,this,[this](bool v){if(scene_)scene_->setCriticalPointVisible(v);});
    auto* undeformed=new QPushButton(tr("Исходная форма"));view->addRow(undeformed);connect(undeformed,&QPushButton::clicked,this,[this]{deformation_->setValue(0);});
    layout->addLayout(view);
    layout->addWidget(legend_);
    layout->addWidget(study_);
    details_=new QTreeWidget;details_->setHeaderLabels({tr("Условия расчёта"),tr("Значение")});details_->setMinimumHeight(260);layout->addWidget(details_);
    layout->addStretch(1);

    auto* scroll = new QScrollArea(splitter);
    scroll->setWidgetResizable(true);
    scroll->setWidget(panel);
    scroll->setMinimumWidth(420);
    scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    splitter->addWidget(left);
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
        || (result.stringOr("schema", "") != "cadnext-structural-result/1" && result.stringOr("schema", "") != "cadnext-harmonic-result/1"
            && result.stringOr("schema", "") != "cadnext-random-result/1" && result.stringOr("schema", "") != "cadnext-shock-result/1"
            && result.stringOr("schema", "") != "cadnext-climate-result/1" && result.stringOr("schema", "") != "cadnext-fire-result/1"
            && result.stringOr("schema", "") != "cadnext-lightning-result/1" && result.stringOr("schema", "") != "cadnext-emc-result/1"
            && result.stringOr("schema", "") != "cadnext-icing-result/1"
            && result.stringOr("schema", "") != "cadnext-flutter-result/1" && result.stringOr("schema", "") != "cadnext-bird-result/1")) {
        QMessageBox::warning(this, tr("Результат прочности"), tr("Это не результат прочности или вибрации"));
        return false;
    }
    harmonic_ = result.stringOr("schema", "") == "cadnext-harmonic-result/1";
    random_ = result.stringOr("schema", "") == "cadnext-random-result/1";
    shock_ = result.stringOr("schema", "") == "cadnext-shock-result/1";
    climate_ = result.stringOr("schema", "") == "cadnext-climate-result/1";
    fire_ = result.stringOr("schema", "") == "cadnext-fire-result/1";
    lightning_ = result.stringOr("schema", "") == "cadnext-lightning-result/1";
    emc_ = result.stringOr("schema", "") == "cadnext-emc-result/1";
    icing_ = result.stringOr("schema", "") == "cadnext-icing-result/1";
    flutter_ = result.stringOr("schema", "") == "cadnext-flutter-result/1";
    bird_ = result.stringOr("schema", "") == "cadnext-bird-result/1";
    {
        // Temperature belongs to climatic, fire and lightning fields; the electric field to the
        // radiated-susceptibility one. Both take the fourth slot of the list.
        const QSignalBlocker block(quantity_);
        while (quantity_->count() > 3) quantity_->removeItem(3);
        if (climate_ || fire_ || lightning_ || emc_ || icing_) {
            quantity_->addItem(emc_ ? tr("Электрическое поле") : icing_ ? tr("Толщина льда") : tr("Температура"));
            quantity_->setCurrentIndex(3);
        } else if (flutter_) {
            // The flutter field carries a mode shape, not a stress: colour it by its own amplitude.
            quantity_->setCurrentIndex(2);
        } else if (quantity_->currentIndex() > 2) {
            quantity_->setCurrentIndex(0);
        }
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
    const QString kindTitle = bird_ ? tr("Удар птицы") : flutter_ ? tr("Флаттер") : icing_ ? tr("Обледенение") : emc_ ? tr("ЭМС") : lightning_ ? tr("Молния") : fire_ ? tr("Огнестойкость") : climate_ ? tr("Климат") : shock_ ? tr("Удар") : random_ ? tr("Случайная вибрация") : harmonic_ ? tr("Вибрация") : tr("Прочность");
    setWindowTitle(kindTitle + QStringLiteral(" — ") + loadCaseName);
    title_->setText(loadCaseName.isEmpty() ? kindTitle : loadCaseName);

    const QString outcome = QString::fromStdString(result.stringOr("outcome", ""));
    const QString colour = outcome == "pass" ? "#2e7d4f" : (outcome == "warning" ? "#a86500" : (outcome == "fail" ? "#b2182b" : "#5c5c5c"));
    verdict_->setText(QString("<span style='background:%1;color:white;padding:4px 10px;font-weight:700;font-family:Menlo'>&nbsp;%2&nbsp;</span>&nbsp;&nbsp;<span style='color:#9c9a92'>%3</span>")
                          .arg(colour, outcome.toUpper(), QString::fromStdString(result.stringOr("solverVersion", ""))));

    auto plainLine = [](const QString& label, const QString& value) {
        return QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2</b></td></tr>").arg(label, value);
    };
    auto metricValue = [&](const char* name) {
        const JsonValue* entry = metricEntry(result, name);
        return entry ? entry->numberOr("value", NAN) : NAN;
    };
    const auto native = QJsonDocument::fromJson(resultJson_).object();
    if (flutter_) {
        const QJsonObject surface = native["surface"].toObject();
        QString rows = plainLine(tr("Моды"), tr("изгиб %1 Гц (мода %2), кручение %3 Гц (мода %4)")
                                                 .arg(metricValue("bendingFrequencyHz"), 0, 'f', 2)
                                                 .arg(surface["bendingMode"].toInt())
                                                 .arg(metricValue("torsionFrequencyHz"), 0, 'f', 2)
                                                 .arg(surface["torsionMode"].toInt()));
        if (surface["flutterFound"].toBool()) {
            const JsonValue* speed = metricEntry(result, "flutterSpeedMps");
            const double band = speed && speed->member("numericalUncertainty") ? speed->member("numericalUncertainty")->numberValue : NAN;
            rows += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b style='color:#d6453d'>%2</b></td></tr>"
                            "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
                        .arg(tr("Флаттер"), tr("%1 м/с").arg(metricValue("flutterSpeedMps"), 0, 'f', 1),
                             tr("± %1 м/с (сетка), на %2 Гц, M = %3")
                                 .arg(band, 0, 'f', 1)
                                 .arg(metricValue("flutterFrequencyHz"), 0, 'f', 2)
                                 .arg(surface["machAtFlutter"].toDouble(), 0, 'f', 3));
        } else {
            rows += plainLine(tr("Флаттер"), tr("в развёртке не найден"));
        }
        if (metricEntry(result, "divergenceSpeedMps")) {
            rows += plainLine(tr("Дивергенция"), tr("%1 м/с").arg(metricValue("divergenceSpeedMps"), 0, 'f', 1));
        }
        if (metricEntry(result, "requiredSpeedMps")) {
            rows += plainLine(tr("Требуется (1.15·V_D)"), tr("%1 м/с, запас %2 %")
                                                              .arg(metricValue("requiredSpeedMps"), 0, 'f', 1)
                                                              .arg(100.0 * metricValue("marginFraction"), 0, 'f', 1));
        }
        rows += plainLine(tr("Размах / полухорда"), tr("%1 м / %2 м")
                                                        .arg(surface["spanM"].toDouble(), 0, 'f', 3)
                                                        .arg(surface["referenceSemichordM"].toDouble(), 0, 'f', 4));
        numbers_->setText("<table>" + rows + "</table>");
    } else if (icing_) {
        const QJsonObject cloud = native["cloud"].toObject();
        QString rows = plainLine(tr("Условие"), cloud["source"].toString().toHtmlEscaped());
        rows += plainLine(tr("Облако"), tr("%1 °C, %2 г/м³, %3 мкм")
                                            .arg(cloud["temperatureK"].toDouble() - 273.15, 0, 'f', 1)
                                            .arg(cloud["lwcKgM3"].toDouble() * 1e3, 0, 'f', 2)
                                            .arg(cloud["dropletDiameterM"].toDouble() * 1e6, 0, 'f', 1));
        rows += plainLine(tr("Полёт"), tr("%1 м/с, %2 мин, параметр инерции %3")
                                           .arg(cloud["airspeedMps"].toDouble(), 0, 'f', 1)
                                           .arg(cloud["durationS"].toDouble() / 60.0, 0, 'f', 1)
                                           .arg(cloud["inertiaParameter"].toDouble(), 0, 'f', 3));
        const JsonValue* ice = metricEntry(result, "iceThicknessM");
        const double band = ice && ice->member("numericalUncertainty") ? ice->member("numericalUncertainty")->numberValue : NAN;
        rows += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2</b></td></tr>"
                        "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
                    .arg(tr("Лёд, наибольшая толщина"), tr("%1 мм").arg(metricValue("iceThicknessM") * 1e3, 0, 'f', 2),
                         tr("± %1 мм (сетка); при теплоотдаче вдвое меньше и вдвое больше %2…%3 мм")
                             .arg(band * 1e3, 0, 'f', 2)
                             .arg(cloud["heatTransferBandLowM"].toDouble() * 1e3, 0, 'f', 2)
                             .arg(cloud["heatTransferBandHighM"].toDouble() * 1e3, 0, 'f', 2));
        rows += plainLine(tr("Масса льда"), tr("%1 кг на %2 м размаха").arg(metricValue("iceMassKg"), 0, 'f', 3).arg(cloud["spanM"].toDouble(), 0, 'f', 2));
        rows += plainLine(tr("Захват воды"), tr("%1 от лобовой площади").arg(metricValue("collectionEfficiency"), 0, 'f', 3));
        if (metricEntry(result, "antiIcePowerW")) rows += plainLine(tr("Обогрев"), tr("%1 Вт").arg(metricValue("antiIcePowerW"), 0, 'f', 0));
        const QJsonArray stations = native["stations"].toArray();
        QString table;
        if (!stations.isEmpty()) {
            table = "<br><b>" + tr("Сечения") + "</b><table>";
            for (const auto& value : stations) {
                const QJsonObject station = value.toObject();
                table += QString("<tr><td style='padding-right:8px'>%1 м</td><td>хорда %2 м</td><td style='padding-left:8px'>β max %3</td>"
                                 "<td style='padding-left:8px'><b>%4 мм</b></td><td style='color:#9c9a92;padding-left:8px'>%5</td></tr>")
                             .arg(station["spanPositionM"].toDouble(), 0, 'f', 3)
                             .arg(station["chordM"].toDouble(), 0, 'f', 3)
                             .arg(station["maximumBeta"].toDouble(), 0, 'f', 3)
                             .arg(station["iceThicknessM"].toDouble() * 1e3, 0, 'f', 2)
                             .arg(station["glaze"].toBool() ? tr("мокрый рост, 0 °C") : tr("иней, %1 °C").arg(station["surfaceTemperatureK"].toDouble() - 273.15, 0, 'f', 1));
            }
            table += "</table>";
        }
        numbers_->setText("<table>" + rows + "</table>" + table);
    } else if (emc_) {
        const QJsonObject environment = native["environment"].toObject();
        QString rows = plainLine(tr("Уровень"), environment["description"].toString().isEmpty()
                                                    ? tr("%1 В/м (своё)").arg(environment["fieldVm"].toDouble(), 0, 'f', 1)
                                                    : environment["description"].toString().toHtmlEscaped());
        rows += plainLine(tr("Развёртка"), tr("%1 … %2 МГц, %3 точек")
                                               .arg(environment["lowHz"].toDouble() / 1e6, 0, 'f', 0)
                                               .arg(environment["highHz"].toDouble() / 1e6, 0, 'f', 0)
                                               .arg(environment["frequenciesHz"].toArray().size()));
        const JsonValue* shielding = metricEntry(result, "shieldingEffectivenessDb");
        const double band = shielding && shielding->member("numericalUncertainty") ? shielding->member("numericalUncertainty")->numberValue : NAN;
        rows += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2</b></td></tr>"
                        "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
                    .arg(tr("Экранирование, худшее"), tr("%1 дБ").arg(metricValue("shieldingEffectivenessDb"), 0, 'f', 1),
                         tr("± %1 дБ (сетка), на %2 МГц").arg(band, 0, 'f', 1).arg(metricValue("worstFrequencyHz") / 1e6, 0, 'f', 0));
        rows += plainLine(tr("Поле внутри"), tr("%1 В/м").arg(metricValue("interiorFieldVm"), 0, 'g', 3));
        rows += plainLine(tr("Ячеек на длину волны"), tr("%1 на верхней частоте").arg(metricValue("cellsPerWavelength"), 0, 'f', 1));
        const QJsonArray resonances = environment["resonancesHz"].toArray();
        if (!resonances.isEmpty()) {
            QStringList list;
            for (const auto& value : resonances) list << QString::number(value.toDouble() / 1e6, 'f', 0);
            rows += plainLine(tr("Резонансы полости"), tr("%1 МГц").arg(list.join(", ")));
        }
        const QJsonArray equipment = native["equipment"].toArray();
        QString table;
        if (!equipment.isEmpty()) {
            table = "<br><b>" + tr("Оборудование") + "</b><table>";
            for (const auto& value : equipment) {
                const QJsonObject c = value.toObject();
                const QString outcome = c["outcome"].toString();
                const QString colour = outcome == "pass" ? "#2e7d4f" : outcome == "warning" ? "#a86500" : outcome == "unknown" ? "#9c9a92" : "#b2182b";
                const double immunity = c["immunityVm"].toDouble();
                table += QString("<tr><td style='padding-right:8px'>%1</td><td><b>%2 В/м</b></td><td style='color:#9c9a92;padding-left:8px'>%3</td>"
                                 "<td style='color:%4;padding-left:8px'><b>%5</b></td></tr>")
                             .arg(c["name"].toString().toHtmlEscaped(), QString::number(c["fieldVm"].toDouble(), 'g', 3),
                                  immunity > 0.0 ? tr("предел %1 В/м").arg(immunity, 0, 'g', 3) : tr("предела нет"), colour, outcome.toUpper());
            }
            table += "</table>";
        }
        numbers_->setText("<table>" + rows + "</table>" + table);
    } else if (lightning_) {
        auto celsius = [](double k) { return QString::number(k - 273.15, 'f', 1) + QStringLiteral(" °C"); };
        auto milliseconds = [](double s) { return s < 1e-3 ? QString::number(s * 1e6, 'f', 1) + QStringLiteral(" мкс") : QString::number(s * 1e3, 'f', 2) + QStringLiteral(" мс"); };
        const QJsonObject strike = native["strike"].toObject(), integrity = native["integrity"].toObject();
        QStringList components;
        for (const auto& value : strike["waveforms"].toArray()) {
            const QString source = value.toObject()["source"].toString();
            const int at = source.indexOf("component ");
            components << (at >= 0 ? source.mid(at + 10, 1) : QStringLiteral("?"));
        }
        QString rows = plainLine(tr("Составляющие"), components.join(" + "));
        rows += plainLine(tr("Пик тока"), tr("%1 кА").arg(strike["peakCurrentA"].toDouble() / 1e3, 0, 'f', 1));
        rows += plainLine(tr("Заряд, ∫i dt"), tr("%1 Кл").arg(strike["totalChargeC"].toDouble(), 0, 'f', 1));
        rows += plainLine(tr("Интеграл действия, ∫i² dt"), tr("%1·10⁶ А²·с").arg(strike["totalActionIntegralA2s"].toDouble() / 1e6, 0, 'f', 3));
        rows += plainLine(tr("Корень дуги"), tr("радиус %1 мм (площадь привязки %2 см²)")
                                                 .arg(strike["arcRootRadiusM"].toDouble() * 1e3, 0, 'f', 1)
                                                 .arg(strike["attachmentAreaM2"].toDouble() * 1e4, 0, 'f', 2));
        if (integrity["burnedThrough"].toBool()) {
            rows += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b style='color:#d6453d'>%2</b></td></tr>"
                            "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
                        .arg(tr("Прожог"), milliseconds(integrity["timeS"].toDouble()),
                             tr("± %1 (сетка и шаг); %2 — прочность по EN 1999-1-2 равна нулю")
                                 .arg(milliseconds(integrity["uncertaintyS"].toDouble()), celsius(integrity["noStrengthK"].toDouble())));
        } else {
            rows += plainLine(tr("Прожог"), tr("нет: деталь выдержала все составляющие"));
        }
        const JsonValue* peak = metricEntry(result, "peakTemperatureK");
        rows += plainLine(tr("Максимум температуры"), peak ? celsius(peak->numberOr("value", NAN)) : QStringLiteral("—"));
        rows += plainLine(tr("Сопротивление детали"), tr("%1 мкОм (при 20 °C)").arg(metricValue("resistanceOhm") * 1e6, 0, 'f', 2));
        rows += plainLine(tr("Тепло дуги / джоулево"), tr("%1 Дж / %2 Дж").arg(metricValue("arcEnergyJ"), 0, 'f', 0).arg(metricValue("jouleEnergyJ"), 0, 'g', 2));
        rows += plainLine(tr("Плотность тока, пик"), tr("%1 МА/м²").arg(metricValue("peakCurrentDensityAm2") / 1e6, 0, 'f', 2));
        const QJsonArray equipment = native["equipment"].toArray();
        QString table;
        if (!equipment.isEmpty()) {
            table = "<br><b>" + tr("Оборудование") + "</b><table>";
            for (const auto& value : equipment) {
                const QJsonObject c = value.toObject();
                const QString outcome = c["outcome"].toString();
                const QString colour = outcome == "pass" ? "#2e7d4f" : outcome == "warning" ? "#a86500" : "#b2182b";
                QString limits;
                for (const auto& check : c["checks"].toArray())
                    limits += (limits.isEmpty() ? "" : ", ") + QString(check.toObject()["limit"].toString() == "maximum" ? "≤ " : "≥ ")
                              + celsius(check.toObject()["limitK"].toDouble());
                table += QString("<tr><td style='padding-right:8px'>%1</td><td>до <b>%2</b></td><td style='color:#9c9a92;padding-left:8px'>%3</td>"
                                 "<td style='color:%4;padding-left:8px'><b>%5</b></td></tr>")
                             .arg(c["name"].toString().toHtmlEscaped(), celsius(c["maximumK"].toDouble()), limits.isEmpty() ? tr("пределов нет") : limits, colour,
                                  outcome.toUpper());
            }
            table += "</table>";
        }
        numbers_->setText("<table>" + rows + "</table>" + table);
    } else if (fire_) {
        auto celsius = [](double k) { return QString::number(k - 273.15, 'f', 1) + QStringLiteral(" °C"); };
        const QJsonObject flame = native["flame"].toObject(), integrity = native["integrity"].toObject(), strength = native["strength"].toObject();
        QString rows = plainLine(tr("Пламя"), flame["source"].toString().toHtmlEscaped());
        rows += plainLine(tr("Требуется"), tr("%1 мин").arg(integrity["requiredDurationS"].toDouble() / 60.0, 0, 'g', 3));
        rows += plainLine(tr("Худший предел пламени"), flame["governingModel"].toString() == "radiative" ? tr("излучение (ε = %1)").arg(flame["emissivity"].toDouble(), 0, 'f', 3)
                                                                                                        : tr("конвекция (h = %1 Вт/(м²·К))").arg(flame["convectionWm2K"].toDouble(), 0, 'f', 1));
        if (integrity["lost"].toBool()) {
            rows += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b style='color:#d6453d'>%2</b></td></tr>"
                            "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
                        .arg(tr("Потеря целостности"), tr("через %1 с").arg(integrity["timeS"].toDouble(), 0, 'f', 1),
                             tr("± %1 с (сетка и шаг); %2 — прочность по EN 1999-1-2 равна нулю").arg(integrity["uncertaintyS"].toDouble(), 0, 'g', 3)
                                 .arg(celsius(integrity["noStrengthK"].toDouble())));
        } else {
            rows += plainLine(tr("Целостность"), integrity.contains("noStrengthK") ? tr("сохранена до конца") : tr("нет данных"));
        }
        const JsonValue* peak = metricEntry(result, "peakTemperatureK");
        rows += plainLine(tr("Максимум температуры"), peak ? celsius(peak->numberOr("value", NAN)) : QStringLiteral("—"));
        if (strength["assessed"].toBool()) {
            rows += plainLine(tr("Использование прочности при нагреве"), tr("%1 ± %2 (σ / k₀.₂(θ)·f₀.₂)").arg(strength["utilization"].toDouble(), 0, 'f', 3)
                                                                             .arg(strength["uncertainty"].toDouble(), 0, 'g', 2));
        } else {
            rows += plainLine(tr("Прочность при нагреве"), tr("нет данных"));
        }
        const QJsonArray components = native["components"].toArray();
        QString table;
        if (!components.isEmpty()) {
            table = "<br><b>" + tr("Оборудование") + "</b><table>";
            for (const auto& value : components) {
                const QJsonObject c = value.toObject();
                const QString outcome = c["outcome"].toString();
                const QString colour = outcome == "pass" ? "#2e7d4f" : outcome == "warning" ? "#a86500" : "#b2182b";
                QString limits;
                for (const auto& check : c["checks"].toArray())
                    limits += (limits.isEmpty() ? "" : ", ") + QString(check.toObject()["limit"].toString() == "maximum" ? "≤ " : "≥ ")
                              + celsius(check.toObject()["limitK"].toDouble());
                table += QString("<tr><td style='padding-right:8px'>%1</td><td>до <b>%2</b></td><td style='color:#9c9a92;padding-left:8px'>%3</td>"
                                 "<td style='color:%4;padding-left:8px'><b>%5</b></td></tr>")
                             .arg(c["name"].toString().toHtmlEscaped(), celsius(c["maximumK"].toDouble()), limits.isEmpty() ? tr("пределов нет") : limits, colour,
                                  outcome.toUpper());
            }
            table += "</table>";
        }
        numbers_->setText("<table>" + rows + "</table>" + table);
    } else if (climate_) {
        auto celsius = [](double k) { return QString::number(k - 273.15, 'f', 1) + QStringLiteral(" °C"); };
        auto temperatureLine = [&](const char* name, const QString& label) {
            const JsonValue* entry = metricEntry(result, name);
            if (entry == nullptr) return plainLine(label, QStringLiteral("—"));
            const JsonValue* band = entry->member("numericalUncertainty");
            return QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2</b></td></tr>"
                           "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
                .arg(label, celsius(entry->numberOr("value", NAN)),
                     band ? tr("± %1 K (сетка и шаг по времени)").arg(band->numberValue, 0, 'g', 3) : tr("погрешность не оценена"));
        };
        const QJsonObject environment = native["environment"].toObject(), heat = native["heatExchange"].toObject(), time = native["time"].toObject();
        QString rows = temperatureLine("peakTemperatureK", tr("Максимум температуры детали")) + temperatureLine("lowTemperatureK", tr("Минимум температуры детали"));
        rows += plainLine(tr("Воздух"), environment["airPeakK"].toDouble() == environment["airLowK"].toDouble()
                                            ? celsius(environment["airPeakK"].toDouble())
                                            : tr("%1 … %2").arg(celsius(environment["airLowK"].toDouble()), celsius(environment["airPeakK"].toDouble())));
        if (environment["irradiancePeakWm2"].toDouble() > 0.0) rows += plainLine(tr("Солнце, пик"), tr("%1 Вт/м²").arg(environment["irradiancePeakWm2"].toDouble(), 0, 'f', 0));
        rows += plainLine(tr("Теплоотдача h"), tr("%1 Вт/(м²·К), полоса %2–%3")
                                                   .arg(heat["convectionWm2K"].toDouble(), 0, 'f', 1)
                                                   .arg(heat["convectionLowWm2K"].toDouble(), 0, 'f', 1)
                                                   .arg(heat["convectionHighWm2K"].toDouble(), 0, 'f', 1));
        rows += metricLine(result, "peakThermalStressPa", tr("Термонапряжение, σ Мизеса"), "Pa") + metricLine(result, "reserveFactor", tr("Коэффициент запаса"), "1");
        if (time["transient"].toBool()) {
            rows += plainLine(tr("Суточных циклов"), tr("%1 (изменение пика за последний %2 K)").arg(time["cycles"].toInt()).arg(time["lastCycleChangeK"].toDouble(), 0, 'g', 2));
        }
        const QJsonArray components = native["components"].toArray();
        QString table;
        if (!components.isEmpty()) {
            table = "<br><b>" + tr("Оборудование") + "</b><table>";
            for (const auto& value : components) {
                const QJsonObject c = value.toObject();
                const QString outcome = c["outcome"].toString();
                const QString colour = outcome == "pass" ? "#2e7d4f" : outcome == "warning" ? "#a86500" : "#b2182b";
                QString limits;
                for (const auto& check : c["checks"].toArray())
                    limits += (limits.isEmpty() ? "" : ", ") + QString(check.toObject()["limit"].toString() == "maximum" ? "≤ " : "≥ ")
                              + celsius(check.toObject()["limitK"].toDouble());
                table += QString("<tr><td style='padding-right:8px'>%1</td><td>%2 … <b>%3</b></td><td style='color:#9c9a92;padding-left:8px'>%4</td>"
                                 "<td style='color:%5;padding-left:8px'><b>%6</b></td></tr>")
                             .arg(c["name"].toString().toHtmlEscaped(), celsius(c["minimumK"].toDouble()), celsius(c["maximumK"].toDouble()),
                                  limits.isEmpty() ? tr("пределов нет") : limits, colour, outcome.toUpper());
            }
            table += "</table>";
        }
        numbers_->setText("<table>" + rows + "</table>" + table);
    } else if (bird_) {
        const QJsonObject load = native["load"].toObject();
        const QJsonObject birdSettings = native["settings"].toObject()["bird"].toObject()["bird"].toObject();
        QString rows = plainLine(tr("Птица"), tr("%1 кг при %2 м/с, %3° — цилиндр %4 × %5 мм")
                                                  .arg(birdSettings["massKg"].toDouble(), 0, 'f', 2)
                                                  .arg(birdSettings["speedMps"].toDouble(), 0, 'f', 1)
                                                  .arg(birdSettings["obliquityDeg"].toDouble(), 0, 'f', 0)
                                                  .arg(load["diameterM"].toDouble() * 1e3, 0, 'f', 1)
                                                  .arg(load["lengthM"].toDouble() * 1e3, 0, 'f', 1));
        rows += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2</b></td></tr>"
                        "<tr><td></td><td style='color:#9c9a92;font-size:small;padding-bottom:4px'>%3</td></tr>")
                    .arg(tr("Импульс"), tr("%1 Н·с за %2 мкс").arg(metricValue("impulseNs"), 0, 'f', 2).arg(metricValue("impactDurationS") * 1e6, 0, 'f', 0),
                         tr("ударная фаза %1 мкс несёт %2 % импульса; %3 Дж кинетической энергии")
                             .arg(metricValue("shockDurationS") * 1e6, 0, 'f', 1)
                             .arg(100.0 * metricValue("shockImpulseFraction"), 0, 'f', 1)
                             .arg(metricValue("energyJ"), 0, 'f', 0));
        rows += plainLine(tr("Давление"), tr("удар %1 МПа, торможение %2 МПа")
                                              .arg(metricValue("hugoniotPressurePa") / 1e6, 0, 'f', 1)
                                              .arg(metricValue("steadyPressurePa") / 1e6, 0, 'f', 2));
        rows += plainLine(tr("Пик силы"), tr("%1 кН").arg(metricValue("peakForceN") / 1e3, 0, 'f', 1));
        rows += plainLine(tr("Грань удара / мидель птицы"), tr("%1 см² / %2 см² = %3")
                                                                .arg(metricValue("impactFaceAreaM2") * 1e4, 0, 'f', 1)
                                                                .arg(metricValue("birdAreaM2") * 1e4, 0, 'f', 1)
                                                                .arg(metricValue("patchRatio"), 0, 'f', 2));
        rows += metricLine(result, "peakStressPa", tr("Пиковое σ Мизеса"), "Pa")
                + plainLine(tr("в момент"), QString("%1 мс").arg(1e3 * metricValue("peakTimeS"), 0, 'f', 3))
                + metricLine(result, "reserveFactor", tr("Коэффициент запаса"), "1");
        rows += plainLine(tr("Самая быстрая мода"), tr("%1 кГц против ударного фронта %2 кГц")
                                                        .arg(metricValue("highestModeHz") / 1e3, 0, 'f', 1)
                                                        .arg(1e-3 / std::max(metricValue("shockDurationS"), 1e-12), 0, 'f', 1));
        numbers_->setText("<table>" + rows + "</table>");
    } else if (shock_) {
        QString rows = metricLine(result, "peakStressPa", tr("Пиковое σ Мизеса"), "Pa")
                       + plainLine(tr("в момент"), QString("%1 мс").arg(1e3 * metricValue("peakTimeS"), 0, 'f', 2))
                       + metricLine(result, "reserveFactor", tr("Коэффициент запаса"), "1")
                       + plainLine(tr("Вход, пик ускорения"), QString("%1 g").arg(metricValue("peakInputAccelerationMps2") / 9.80665, 0, 'f', 2));
        if (metricEntry(result, "peakProbeAccelerationMps2"))
            rows += plainLine(tr("Датчик, пик ускорения"), QString("%1 g").arg(metricValue("peakProbeAccelerationMps2") / 9.80665, 0, 'f', 2))
                    + plainLine(tr("Датчик, пик перемещения"), si(metricValue("peakProbeDisplacementM"), "m"));
        if (metricEntry(result, "effectiveMassFraction"))
            rows += plainLine(tr("Масса в модах вдоль удара"), QString("%1 %").arg(100.0 * metricValue("effectiveMassFraction"), 0, 'f', 1));
        numbers_->setText("<table>" + rows + "</table>");
    } else if (random_) {
        QString rows = metricLine(result, "rmsVonMisesPa", tr("RMS σ Мизеса (1σ)"), "Pa") + metricLine(result, "threeSigmaStressPa", tr("3σ — уровень оценки"), "Pa")
                       + metricLine(result, "reserveFactor", tr("Коэффициент запаса по 3σ"), "1")
                       + plainLine(tr("Вход, ускорение"), QString("%1 g RMS").arg(metricValue("inputRmsAccelerationMps2") / 9.80665, 0, 'f', 3));
        if (metricEntry(result, "probeRmsAccelerationMps2"))
            rows += plainLine(tr("Датчик, ускорение"), QString("%1 g RMS").arg(metricValue("probeRmsAccelerationMps2") / 9.80665, 0, 'f', 3));
        rows += plainLine(tr("Кажущаяся частота напряжения"), QString("%1 Гц").arg(metricValue("stressApparentFrequencyHz"), 0, 'f', 1));
        if (metricEntry(result, "effectiveMassFraction"))
            rows += plainLine(tr("Масса в модах вдоль возбуждения"), QString("%1 %").arg(100.0 * metricValue("effectiveMassFraction"), 0, 'f', 1));
        numbers_->setText("<table>" + rows + "</table>");
    } else if (harmonic_) {
        const JsonValue* frequency = metricEntry(result, "peakStressFrequencyHz");
        QString extra;
        if (const JsonValue* acceleration = metricEntry(result, "peakProbeAccelerationMps2")) {
            extra += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2 g</b></td></tr>")
                         .arg(tr("Ускорение датчика, пик"))
                         .arg(acceleration->numberOr("value", NAN) / 9.80665, 0, 'f', 2);
        }
        if (const JsonValue* mass = metricEntry(result, "effectiveMassFraction")) {
            extra += QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2 %</b></td></tr>")
                         .arg(tr("Масса в модах вдоль возбуждения"))
                         .arg(100.0 * mass->numberOr("value", NAN), 0, 'f', 1);
        }
        numbers_->setText("<table>" + metricLine(result, "peakDynamicStressPa", tr("Пиковое σ за цикл"), "Pa")
                          + QString("<tr><td style='color:#9c9a92;padding-right:10px'>%1</td><td><b>%2 Гц</b></td></tr>")
                                .arg(tr("на частоте"))
                                .arg(frequency ? frequency->numberOr("value", NAN) : NAN, 0, 'f', 2)
                          + metricLine(result, "reserveFactor", tr("Коэффициент запаса"), "1")
                          + metricLine(result, "peakDisplacementM", tr("Пиковое перемещение"), "m") + extra + "</table>");
    } else {
        numbers_->setText("<table>" + metricLine(result, "maxVonMisesPa", tr("Макс. σ Мизеса"), "Pa")
                          + metricLine(result, "reserveFactor", tr("Коэффициент запаса"), "1")
                          + metricLine(result, "maxDisplacementM", tr("Макс. перемещение"), "m") + "</table>");
    }

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
            if (fire_) {
                const double loss = level.numberOr("integrityLossTimeS", -1.0);
                studyText += QString("<tr><td>h %1 мм&nbsp;</td><td align=right>%2 эл.&nbsp;</td><td align=right>%3</td></tr>")
                                 .arg(level.numberOr("maximumElementSizeM", 0) * 1000, 0, 'f', 2)
                                 .arg(static_cast<qlonglong>(level.numberOr("elements", 0)))
                                 .arg(loss >= 0.0 ? tr("отказ %1 с").arg(loss, 0, 'f', 2) : tr("%1 °C").arg(level.numberOr("peakK", NAN) - 273.15, 0, 'f', 2));
                continue;
            }
            if (flutter_) {
                studyText += QString("<tr><td>h %1 мм&nbsp;</td><td align=right>%2 эл.&nbsp;</td><td align=right>%3 / %4 Гц</td>"
                                     "<td align=right>&nbsp;%5 м/с</td></tr>")
                                 .arg(level.numberOr("maximumElementSizeM", 0) * 1000, 0, 'f', 2)
                                 .arg(static_cast<qlonglong>(level.numberOr("elements", 0)))
                                 .arg(level.numberOr("bendingHz", NAN), 0, 'f', 2)
                                 .arg(level.numberOr("torsionHz", NAN), 0, 'f', 2)
                                 .arg(level.numberOr("flutterSpeedMps", NAN), 0, 'f', 1);
                continue;
            }
            if (icing_) {
                studyText += QString("<tr><td>%1 панелей&nbsp;</td><td align=right>%2 траекторий&nbsp;</td><td align=right>%3 мм</td></tr>")
                                 .arg(static_cast<qlonglong>(level.numberOr("panels", 0)))
                                 .arg(static_cast<qlonglong>(level.numberOr("trajectories", 0)))
                                 .arg(level.numberOr("iceThicknessM", NAN) * 1e3, 0, 'f', 3);
                continue;
            }
            if (emc_) {
                studyText += QString("<tr><td>ячейка %1 мм&nbsp;</td><td align=right>%2&nbsp;</td><td align=right>%3 дБ</td></tr>")
                                 .arg(level.numberOr("cellM", 0) * 1000, 0, 'f', 2)
                                 .arg(QString::fromStdString(level.stringOr("grid", "")))
                                 .arg(level.numberOr("worstShieldingDb", NAN), 0, 'f', 1);
                continue;
            }
            if (lightning_) {
                const double burn = level.numberOr("burnThroughTimeS", -1.0);
                studyText += QString("<tr><td>h %1 мм&nbsp;</td><td align=right>%2 эл.&nbsp;</td><td align=right>%3</td><td align=right>&nbsp;%4 мкОм</td></tr>")
                                 .arg(level.numberOr("maximumElementSizeM", 0) * 1000, 0, 'f', 2)
                                 .arg(static_cast<qlonglong>(level.numberOr("elements", 0)))
                                 .arg(burn >= 0.0 ? tr("прожог %1 мс").arg(burn * 1e3, 0, 'f', 3) : tr("%1 °C").arg(level.numberOr("peakK", NAN) - 273.15, 0, 'f', 2))
                                 .arg(level.numberOr("resistanceOhm", NAN) * 1e6, 0, 'f', 3);
                continue;
            }
            if (climate_) {
                studyText += QString("<tr><td>h %1 мм&nbsp;</td><td align=right>%2 эл.&nbsp;</td><td align=right>%3 °C</td><td align=right>&nbsp;%4</td></tr>")
                                 .arg(level.numberOr("maximumElementSizeM", 0) * 1000, 0, 'f', 2)
                                 .arg(static_cast<qlonglong>(level.numberOr("elements", 0)))
                                 .arg(level.numberOr("peakK", NAN) - 273.15, 0, 'f', 4)
                                 .arg(si(level.numberOr("peakStressPa", NAN), "Pa"));
                continue;
            }
            studyText += QString("<tr><td>h %1 мм&nbsp;</td><td align=right>%2 эл.&nbsp;</td><td align=right>%3</td>%4</tr>")
                             .arg(level.numberOr("maximumElementSizeM", 0) * 1000, 0, 'f', 2)
                             .arg(static_cast<qlonglong>(level.numberOr("elements", 0)))
                             .arg(si(level.numberOr(shock_ || bird_ ? "peakStressPa" : random_ ? "rmsVonMisesPa" : harmonic_ ? "peakDynamicStressPa" : "maxVonMisesPa", NAN), "Pa"))
                             .arg(harmonic_          ? QString("<td align=right>&nbsp;%1 Гц</td>").arg(level.numberOr("peakFrequencyHz", NAN), 0, 'f', 2)
                                  : shock_ || bird_  ? QString("<td align=right>&nbsp;%1 мс</td>").arg(1e3 * level.numberOr("peakTimeS", NAN), 0, 'f', 3)
                                                     : QString());
        }
    }
    study_->setText(studyText + "</table>");
    details_->clear();
    const QMap<QString,QString> labels{{"name",tr("Название")},{"supports",tr("Закрепления")},{"forces",tr("Силы")},{"pressures",tr("Давления")},{"bodyAccelerationMps2",tr("Ускорение, м/с²")},{"stressExclusions",tr("Исключения напряжений")},{"face",tr("Грань")},{"fix",tr("Закреплённые оси")},{"totalForceN",tr("Сила, Н")},{"pressurePa",tr("Давление, Па")},{"distanceM",tr("Расстояние, м")},{"youngModulusPa",tr("Модуль Юнга, Па")},{"poissonRatio",tr("Коэффициент Пуассона")},{"densityKgM3",tr("Плотность, кг/м³")},{"yieldStrengthPa",tr("Предел текучести, Па")},{"ultimateStrengthPa",tr("Предел прочности, Па")},{"factorOfSafety",tr("Коэффициент безопасности")}};
    std::function<void(QTreeWidgetItem*,QString,QJsonValue)> add=[&](QTreeWidgetItem* parent,QString key,QJsonValue value){auto* item=parent?new QTreeWidgetItem(parent):new QTreeWidgetItem(details_);item->setText(0,labels.value(key,key));if(value.isObject()){auto object=value.toObject();for(auto it=object.begin();it!=object.end();++it)add(item,it.key(),it.value());}else if(value.isArray()){int i=0;for(auto v:value.toArray())add(item,QString::number(++i),v);}else item->setText(1,value.isString()?value.toString():value.isDouble()?QString::number(value.toDouble(),'g',8):value.isBool()?(value.toBool()?tr("Да"):tr("Нет")):QStringLiteral("—"));};
    add(nullptr,tr("Нагрузочный случай"),native["settings"].toObject()["loadCase"]);add(nullptr,tr("Материал"),native["material"]);add(nullptr,tr("Критерий и параметры"),native["settings"]);details_->expandToDepth(0);details_->resizeColumnToContents(0);
    scene_->setMeshVisible(meshVisible_->isChecked());scene_->setCriticalPointVisible(criticalVisible_->isChecked());
    if (harmonic_) add(nullptr,tr("Вибрация"),native["settings"].toObject()["harmonic"]);
    if (random_) add(nullptr,tr("Случайная вибрация"),native["settings"].toObject()["random"]);
    if (shock_) add(nullptr,tr("Удар"),native["settings"].toObject()["shock"]);
    if (bird_) {
        add(nullptr, tr("Удар птицы"), native["settings"].toObject()["bird"]);
        add(nullptr, tr("Нагрузка птицы"), native["load"]);
    }
    if (climate_) {
        add(nullptr, tr("Климат"), native["settings"].toObject()["climate"]);
        add(nullptr, tr("Условия стандарта"), native["environment"]);
        add(nullptr, tr("Теплообмен"), native["heatExchange"]);
        add(nullptr, tr("Время"), native["time"]);
    }

    if (fire_) {
        add(nullptr, tr("Огонь"), native["settings"].toObject()["fire"]);
        add(nullptr, tr("Пламя"), native["flame"]);
        add(nullptr, tr("Целостность"), native["integrity"]);
    }
    if (flutter_) {
        add(nullptr, tr("Флаттер"), native["settings"].toObject()["flutter"]);
        add(nullptr, tr("Поверхность"), native["surface"]);
    }
    if (icing_) {
        add(nullptr, tr("Обледенение"), native["settings"].toObject()["icing"]);
        add(nullptr, tr("Облако"), native["cloud"]);
    }
    if (emc_) {
        add(nullptr, tr("ЭМС"), native["settings"].toObject()["emc"]);
        add(nullptr, tr("Условия"), native["environment"]);
    }
    if (lightning_) {
        add(nullptr, tr("Молния"), native["settings"].toObject()["lightning"]);
        add(nullptr, tr("Удар молнии"), native["strike"]);
        add(nullptr, tr("Целостность"), native["integrity"]);
    }
    const bool daySeries = climate_ && native["series"].toObject()["timeS"].toArray().size() > 1;
    const bool fireSeries = fire_ && native["series"].toObject()["timeS"].toArray().size() > 1;
    const bool strikeSeries = lightning_ && native["series"].toObject()["timeS"].toArray().size() > 1;
    const bool sweepSeries = emc_ && native["environment"].toObject()["frequenciesHz"].toArray().size() > 1;
    const bool sectionSeries = icing_ && !native["stations"].toArray().isEmpty();
    const bool flutterSeries = flutter_ && native["series"].toObject()["speedMps"].toArray().size() > 1;
    responseBox_->setVisible(harmonic_ || random_ || shock_ || bird_ || daySeries || fireSeries || strikeSeries || sweepSeries || sectionSeries || flutterSeries);
    // A splitter left to itself shares height by size hints, and the GL viewport has almost none:
    // the first harmonic window showed the plot over the whole height and no part at all.
    if (harmonic_ || random_ || shock_ || bird_ || daySeries || fireSeries || strikeSeries || sweepSeries || sectionSeries || flutterSeries) {
        viewSplitter_->setSizes({600, 380});
    }
    if (flutterSeries) {
        const QJsonObject series = native["series"].toObject();
        auto plain = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& item : value.toArray()) out.push_back(item.toDouble());
            return out;
        };
        const std::vector<double> speeds = plain(series["speedMps"]);
        response_->setData(speeds, {}, native["surface"].toObject()["flutterFound"].toBool() ? metricValue("flutterSpeedMps") : NAN);
        auto curve = [&](const QString& title, const QString& unit, std::vector<double> values, double limit, const QString& limitLabel) {
            ResponsePlot::Series out{title, unit, std::move(values), 1.0, limit, limitLabel};
            out.logX = out.logY = false;
            out.xUnit = tr("м/с");
            out.x = speeds;
            out.worstX = native["surface"].toObject()["flutterFound"].toBool() ? metricValue("flutterSpeedMps") : NAN;
            return out;
        };
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        choices.push_back({tr("Демпфирование, изгиб"), curve(tr("Затухание первой ветви (плюс — рост)"), QString(), plain(series["dampingFirst"]), 0.0,
                                                             tr("граница устойчивости"))});
        choices.push_back({tr("Демпфирование, кручение"), curve(tr("Затухание второй ветви (плюс — рост)"), QString(), plain(series["dampingSecond"]), 0.0,
                                                                tr("граница устойчивости"))});
        choices.push_back({tr("Частота, изгиб"), curve(tr("Частота первой ветви"), tr("Гц"), plain(series["frequencyFirst"]), NAN, {})});
        choices.push_back({tr("Частота, кручение"), curve(tr("Частота второй ветви"), tr("Гц"), plain(series["frequencySecond"]), NAN, {})});
        const QSignalBlocker block(responseQuantity_);
        responseQuantity_->clear();
        for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
        responseQuantity_->disconnect(this);
        connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
            if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
        });
        response_->setSeries(choices.front().series);
    }
    if (sectionSeries) {
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        for (const auto& value : native["stations"].toArray()) {
            const QJsonObject station = value.toObject();
            std::vector<double> arc, beta, ice;
            for (const auto& item : station["arcLengthM"].toArray()) arc.push_back(item.toDouble());
            for (const auto& item : station["beta"].toArray()) beta.push_back(item.toDouble());
            for (const auto& item : station["iceM"].toArray()) ice.push_back(item.toDouble() * 1e3);
            if (arc.size() < 2 || beta.size() != arc.size()) continue;
            const QString where = tr("%1 м").arg(station["spanPositionM"].toDouble(), 0, 'f', 3);
            auto series = [&](const QString& title, const QString& unit, std::vector<double> values, double limit, const QString& limitLabel) {
                ResponsePlot::Series out{title, unit, std::move(values), 1.0, limit, limitLabel};
                out.logX = out.logY = false;
                out.xUnit = tr("мм");
                out.xScale = 1e-3;
                out.x = arc;
                return out;
            };
            choices.push_back({tr("%1: захват β").arg(where), series(tr("Местная эффективность захвата вдоль поверхности"), QString(), beta, 1.0, tr("единица"))});
            if (ice.size() == arc.size()) {
                choices.push_back({tr("%1: лёд").arg(where), series(tr("Толщина льда вдоль поверхности"), tr("мм"), ice, NAN, {})});
            }
        }
        if (!choices.empty()) {
            std::vector<double> arc;
            for (const auto& item : native["stations"].toArray().first().toObject()["arcLengthM"].toArray()) arc.push_back(item.toDouble());
            response_->setData(arc, {}, NAN);
            const QSignalBlocker block(responseQuantity_);
            responseQuantity_->clear();
            for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
            responseQuantity_->disconnect(this);
            connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
                if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
            });
            response_->setSeries(choices.front().series);
        }
    }
    if (sweepSeries) {
        const QJsonObject environment = native["environment"].toObject();
        std::vector<double> frequencies;
        for (const auto& value : environment["frequenciesHz"].toArray()) frequencies.push_back(value.toDouble());
        response_->setData(frequencies, {}, NAN);
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        const QJsonArray equipment = native["equipment"].toArray();
        for (const auto& value : equipment) {
            const QJsonObject c = value.toObject();
            std::vector<double> shielding;
            for (const auto& item : c["shieldingDb"].toArray()) shielding.push_back(item.toDouble());
            ResponsePlot::Series series{tr("%1: экранирование").arg(c["name"].toString()), tr("дБ"), shielding, 1.0, NAN, {}};
            series.logX = true;
            series.logY = false;
            series.xUnit = tr("МГц");
            series.xScale = 1e6;
            series.x = frequencies;
            series.worstX = c["worstFrequencyHz"].toDouble();
            choices.push_back({c["name"].toString(), std::move(series)});
        }
        if (!choices.empty()) {
            const QSignalBlocker block(responseQuantity_);
            responseQuantity_->clear();
            for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
            responseQuantity_->disconnect(this);
            connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
                if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
            });
            response_->setSeries(choices.front().series);
        }
    }
    if (strikeSeries) {
        const QJsonObject series = native["series"].toObject();
        auto plain = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble());
            return out;
        };
        auto celsiusValues = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble() - 273.15);
            return out;
        };
        const std::vector<double> time = plain(series["timeS"]);
        response_->setData(time, {}, NAN);
        // Microseconds to half a second in one history: the time axis is logarithmic, values are not.
        auto strikeSeriesOf = [&](const QString& title, const QString& unit, std::vector<double> values, double limit, const QString& limitLabel) {
            ResponsePlot::Series out{title, unit, std::move(values), 1.0, limit, limitLabel};
            out.logX = false;
            out.logY = false;
            out.xUnit = tr("мс");
            out.xScale = 1e-3;
            out.x = time;
            return out;
        };
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        const QJsonObject integrity = native["integrity"].toObject();
        const double noStrength = integrity.contains("noStrengthK") ? integrity["noStrengthK"].toDouble() - 273.15 : NAN;
        choices.push_back({tr("Самая горячая точка"),
                           strikeSeriesOf(tr("Самая горячая точка детали"), tr("°C"), celsiusValues(series["partMaximumK"]), noStrength, tr("прочность равна нулю"))});
        std::vector<double> kiloamperes;
        for (double value : plain(series["currentA"])) kiloamperes.push_back(value / 1e3);
        choices.push_back({tr("Ток молнии"), strikeSeriesOf(tr("Ток через деталь"), tr("кА"), std::move(kiloamperes), NAN, {})});
        const QJsonArray equipment = native["equipment"].toArray();
        const QJsonArray equipmentSeries = series["equipment"].toArray();
        for (int c = 0; c < equipmentSeries.size() && c < equipment.size(); ++c) {
            double limit = NAN;
            for (const auto& check : equipment[c].toObject()["checks"].toArray())
                if (check.toObject()["limit"].toString() == "maximum") limit = check.toObject()["limitK"].toDouble() - 273.15;
            const QString name = equipment[c].toObject()["name"].toString();
            choices.push_back({tr("%1 — температура грани").arg(name),
                               strikeSeriesOf(tr("%1: самая горячая точка грани крепления").arg(name), tr("°C"),
                                              celsiusValues(equipmentSeries[c].toObject()["maximumK"]), limit, tr("предел по паспорту"))});
        }
        const QSignalBlocker block(responseQuantity_);
        responseQuantity_->clear();
        for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
        responseQuantity_->disconnect(this);
        connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
            if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
        });
        response_->setSeries(choices.front().series);
    }
    if (fireSeries) {
        const QJsonObject series = native["series"].toObject();
        auto celsiusValues = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble() - 273.15);
            return out;
        };
        auto plain = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble());
            return out;
        };
        const std::vector<double> time = plain(series["timeS"]);
        response_->setData(time, {}, NAN);
        auto timeSeries = [&](const QString& title, const QString& unit, std::vector<double> values, double limit, const QString& limitLabel,
                              std::vector<double> x) {
            ResponsePlot::Series out{title, unit, std::move(values), 1.0, limit, limitLabel};
            out.logX = out.logY = false;
            out.xUnit = tr("с");
            out.x = std::move(x);
            return out;
        };
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        const QJsonObject integrity = native["integrity"].toObject();
        const double noStrength = integrity.contains("noStrengthK") ? integrity["noStrengthK"].toDouble() - 273.15 : NAN;
        choices.push_back({tr("Самая горячая точка"), timeSeries(tr("Самая горячая точка детали"), tr("°C"), celsiusValues(series["partMaximumK"]), noStrength,
                                                                 tr("прочность равна нулю"), time)});
        const QJsonArray components = native["components"].toArray();
        const QJsonArray componentSeries = series["components"].toArray();
        for (int c = 0; c < componentSeries.size() && c < components.size(); ++c) {
            double limit = NAN;
            for (const auto& check : components[c].toObject()["checks"].toArray())
                if (check.toObject()["limit"].toString() == "maximum") limit = check.toObject()["limitK"].toDouble() - 273.15;
            const QString name = components[c].toObject()["name"].toString();
            choices.push_back({tr("%1 — температура грани").arg(name), timeSeries(tr("%1: самая горячая точка грани крепления").arg(name), tr("°C"),
                                                                              celsiusValues(componentSeries[c].toObject()["maximumK"]), limit, tr("предел по паспорту"), time)});
        }
        choices.push_back({tr("Самая холодная точка"), timeSeries(tr("Самая холодная точка детали"), tr("°C"), celsiusValues(series["partMinimumK"]), NAN, {}, time)});
        const auto samples = plain(series["sampleTimeS"]);
        if (samples.size() > 1)
            choices.push_back({tr("Использование прочности"), timeSeries(tr("Наибольшее σ / (k₀.₂(θ)·f₀.₂) к этому моменту"), QString(), plain(series["utilization"]), 1.0,
                                                                         tr("предел"), samples)});
        const QSignalBlocker block(responseQuantity_);
        responseQuantity_->clear();
        for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
        responseQuantity_->disconnect(this);
        connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
            if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
        });
        response_->setSeries(choices.front().series);
    }
    if (daySeries) {
        const QJsonObject series = native["series"].toObject();
        auto celsiusValues = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble() - 273.15);
            return out;
        };
        std::vector<double> time;
        for (const auto& v : series["timeS"].toArray()) time.push_back(v.toDouble());
        response_->setData(time, {}, NAN);
        auto daySeriesOf = [&](const QString& title, const QString& unit, std::vector<double> values, double limit, const QString& limitLabel, double worst) {
            ResponsePlot::Series out{title, unit, std::move(values), 1.0, limit, limitLabel};
            out.logX = out.logY = false;
            out.xUnit = tr("ч");
            out.xScale = 3600.0;
            out.x = time;
            out.worstX = worst;
            return out;
        };
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        const QJsonObject temperature = native["temperature"].toObject();
        double materialMaximum = NAN;
        for (const auto& check : temperature["materialChecks"].toArray())
            if (check.toObject()["limit"].toString() == "maximum") materialMaximum = check.toObject()["limitK"].toDouble() - 273.15;
        // The worst point is marked only where a sample falls on it.
        choices.push_back({tr("Максимум температуры детали"), daySeriesOf(tr("Самая горячая точка детали"), tr("°C"), celsiusValues(series["partMaximumK"]), materialMaximum,
                                                                          tr("предел материала"), NAN)});
        const QJsonArray components = native["components"].toArray();
        const QJsonArray componentSeries = series["components"].toArray();
        for (int c = 0; c < componentSeries.size() && c < components.size(); ++c) {
            double limit = NAN;
            for (const auto& check : components[c].toObject()["checks"].toArray())
                if (check.toObject()["limit"].toString() == "maximum") limit = check.toObject()["limitK"].toDouble() - 273.15;
            const QString name = components[c].toObject()["name"].toString();
            choices.push_back({tr("%1 — температура грани").arg(name),
                               daySeriesOf(tr("%1: самая горячая точка грани крепления").arg(name), tr("°C"), celsiusValues(componentSeries[c].toObject()["maximumK"]), limit,
                                           tr("предел по паспорту"), NAN)});
        }
        choices.push_back({tr("Минимум температуры детали"), daySeriesOf(tr("Самая холодная точка детали"), tr("°C"), celsiusValues(series["partMinimumK"]), NAN, {}, NAN)});
        choices.push_back({tr("Воздух (стандарт)"), daySeriesOf(tr("Температура воздуха по стандарту"), tr("°C"), celsiusValues(series["airK"]), NAN, {}, NAN)});
        std::vector<double> sun;
        for (const auto& v : series["irradianceWm2"].toArray()) sun.push_back(v.toDouble());
        if (std::any_of(sun.begin(), sun.end(), [](double v) { return v > 0.0; }))
            choices.push_back({tr("Солнце (стандарт)"), daySeriesOf(tr("Облучённость по стандарту"), tr("Вт/м²"), sun, NAN, {}, NAN)});
        const QSignalBlocker block(responseQuantity_);
        responseQuantity_->clear();
        for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
        responseQuantity_->disconnect(this);
        connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
            if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
        });
        response_->setSeries(choices.front().series);
    }
    if (bird_) {
        const QJsonObject history = native["history"].toObject();
        auto numbers = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble());
            return out;
        };
        const std::vector<double> time = numbers(history["timeS"]);
        const double worstTime = native["criticalRegion"].toObject()["timeS"].toDouble();
        response_->setData(time, numbers(native["modeFrequenciesHz"]), worstTime);
        auto timeSeries = [&](const QString& title, const QString& unit, const QString& key, double scale, double limit, const QString& limitLabel) {
            ResponsePlot::Series series{title, unit, numbers(history[key]), scale, limit, limitLabel};
            series.logX = series.logY = false;
            series.xUnit = tr("мс");
            series.xScale = 1e-3;
            series.x = time;
            series.worstX = worstTime;
            return series;
        };
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        choices.push_back({tr("Максимум σ Мизеса во времени"),
                           timeSeries(tr("Максимум σ Мизеса по детали"), tr("МПа"), "maxVonMisesPa", 1e6, scene_->field().allowableStressPa, tr("σдоп"))});
        choices.push_back({tr("Сила птицы"), timeSeries(tr("Сила, с которой птица давит на грань"), tr("кН"), "forceN", 1e3, NAN, {})});
        const QSignalBlocker block(responseQuantity_);
        responseQuantity_->clear();
        for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
        responseQuantity_->disconnect(this);
        connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
            if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
        });
        response_->setSeries(choices.front().series);
    }
    if (shock_) {
        const QJsonObject history = native["history"].toObject(), srs = native["inputSrs"].toObject();
        auto numbers = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble());
            return out;
        };
        const std::vector<double> time = numbers(history["timeS"]);
        const double worstTime = native["criticalRegion"].toObject()["timeS"].toDouble();
        const double g = 9.80665;
        std::vector<double> modes = numbers(native["modeFrequenciesHz"]);
        response_->setData(time, modes, worstTime);
        auto timeSeries = [&](const QString& title, const QString& unit, const QString& key, double scale, double limit, const QString& limitLabel) {
            ResponsePlot::Series series{title, unit, numbers(history[key]), scale, limit, limitLabel};
            series.logX = series.logY = false;
            series.xUnit = tr("мс");
            series.xScale = 1e-3;
            series.x = time;
            series.worstX = worstTime;
            return series;
        };
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        choices.push_back({tr("Максимум σ Мизеса во времени"),
                           timeSeries(tr("Максимум σ Мизеса по детали"), tr("МПа"), "maxVonMisesPa", 1e6, scene_->field().allowableStressPa, tr("σдоп"))});
        if (history.contains("probeAccelerationMps2")) {
            choices.push_back({tr("Ускорение датчика"), timeSeries(tr("Ускорение датчика (абсолютное)"), tr("g"), "probeAccelerationMps2", g, NAN, {})});
            choices.push_back({tr("Перемещение датчика"), timeSeries(tr("Перемещение датчика относительно оснастки"), tr("мм"), "probeDisplacementM", 1e-3, NAN, {})});
        }
        choices.push_back({tr("Входной импульс"), timeSeries(tr("Ускорение оснастки"), tr("g"), "baseAccelerationMps2", g, NAN, {})});
        {
            ResponsePlot::Series spectrum{tr("Спектр ударного отклика входа, Q = 10"), tr("g"), numbers(srs["accelerationMps2"]), g, NAN, {}};
            spectrum.x = numbers(srs["frequencyHz"]);
            choices.push_back({tr("Спектр ударного отклика (SRS)"), spectrum});
        }
        const QSignalBlocker block(responseQuantity_);
        responseQuantity_->clear();
        for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
        responseQuantity_->disconnect(this);
        connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
            if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
        });
        response_->setSeries(choices.front().series);
    }
    if (random_) {
        const QJsonObject spectra = native["spectra"].toObject();
        auto numbers = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble());
            return out;
        };
        std::vector<double> modes = numbers(native["modeFrequenciesHz"]);
        response_->setData(numbers(spectra["frequencyHz"]), modes, NAN);
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        const double g2 = 9.80665 * 9.80665;
        choices.push_back({tr("Спектр σ Мизеса в критической точке"), {tr("Спектр σ Мизеса в критической точке"), tr("МПа²/Гц"), numbers(spectra["criticalStressPsd"]), 1e12, NAN, {}}});
        if (spectra.contains("probeAccelerationPsd"))
            choices.push_back({tr("Спектр ускорения датчика"), {tr("Спектр ускорения датчика (абсолютного)"), tr("g²/Гц"), numbers(spectra["probeAccelerationPsd"]), g2, NAN, {}}});
        choices.push_back({tr("Входной спектр"), {tr("Входной спектр ускорения"), tr("g²/Гц"), numbers(spectra["inputPsd"]), g2, NAN, {}}});
        const QSignalBlocker block(responseQuantity_);
        responseQuantity_->clear();
        for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
        responseQuantity_->disconnect(this);
        connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
            if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
        });
        response_->setSeries(choices.front().series);
    }
    if (harmonic_) {
        const QJsonObject response = native["response"].toObject();
        auto numbers = [](const QJsonValue& value) {
            std::vector<double> out;
            for (const auto& v : value.toArray()) out.push_back(v.toDouble());
            return out;
        };
        std::vector<double> modes = numbers(native["modeFrequenciesHz"]);
        const double worstHz = native["criticalRegion"].toObject()["frequencyHz"].toDouble();
        response_->setData(numbers(response["frequencyHz"]), modes, worstHz);
        const double allowable = scene_->field().allowableStressPa;
        struct Choice { QString name; ResponsePlot::Series series; };
        std::vector<Choice> choices;
        choices.push_back({tr("Пиковое σ Мизеса (вне зон исключения)"), {tr("Пиковое σ Мизеса за цикл"), tr("МПа"), numbers(response["maxVonMisesPa"]), 1e6, allowable, tr("σдоп")}});
        if (response.contains("probeAccelerationMps2"))
            choices.push_back({tr("Ускорение датчика"), {tr("Ускорение датчика (абсолютное)"), tr("g"), numbers(response["probeAccelerationMps2"]), 9.80665, NAN, {}}});
        choices.push_back({tr("Пиковое перемещение"), {tr("Пиковое перемещение относительно оснастки"), tr("мм"), numbers(response["maxDisplacementM"]), 1e-3, NAN, {}}});
        const QSignalBlocker block(responseQuantity_);
        responseQuantity_->clear();
        for (const auto& choice : choices) responseQuantity_->addItem(choice.name);
        responseQuantity_->disconnect(this);
        connect(responseQuantity_, qOverload<int>(&QComboBox::currentIndexChanged), this, [this, choices](int index) {
            if (index >= 0 && index < static_cast<int>(choices.size())) response_->setSeries(choices[index].series);
        });
        response_->setSeries(choices.front().series);
    }

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
    const auto quantity = index == 1   ? viewer::FieldQuantity::VonMises
                          : index == 2 ? viewer::FieldQuantity::Displacement
                          : index == 3 ? (emc_     ? viewer::FieldQuantity::ElectricField
                                          : icing_ ? viewer::FieldQuantity::IceThickness
                                                   : viewer::FieldQuantity::Temperature)
                                       : viewer::FieldQuantity::Utilization;
    scene_->setQuantity(quantity);
    JsonValue result;
    std::string error;
    double assessed = NAN;
    if (flutter_) {
        assessed = 0.0; // there is no stress in a flutter result, and no utilisation to report
    } else if (fea::json::parseJson(resultJson_.toStdString(), result, error)) {
        if (fire_) {
            if (const JsonValue* entry = metricEntry(result, "hotUtilization")) assessed = entry->numberOr("value", NAN);
        } else if (const JsonValue* entry = metricEntry(result, climate_ ? "peakThermalStressPa" : shock_ || bird_ ? "peakStressPa" : random_ ? "threeSigmaStressPa" : harmonic_ ? "peakDynamicStressPa" : "maxVonMisesPa")) {
            assessed = entry->numberOr("value", NAN) / scene_->field().allowableStressPa;
        }
    }
    QString note;
    if (random_) note = tr("Цвет — 3σ фон Мизеса (Сегалман). Формы нет: у случайного отклика нет одного положения.");
    if (fire_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        const QJsonObject integrity = native["integrity"].toObject();
        note = quantity == viewer::FieldQuantity::Temperature
                   ? (integrity["lost"].toBool() ? tr("Температура в момент потери целостности, t = %1 с.").arg(integrity["timeS"].toDouble(), 0, 'f', 1)
                                                 : tr("Температура в конце воздействия, t = %1 с.").arg(integrity["requiredDurationS"].toDouble(), 0, 'f', 0))
                   : tr("Использование — σ / (k₀.₂(θ)·f₀.₂) при температуре каждой точки (EN 1999-1-2, γM,fi = 1.0), t = %1 с.")
                         .arg(native["criticalRegion"].toObject()["timeS"].toDouble(), 0, 'f', 0);
    }
    if (flutter_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        note = tr("Форма — мода кручения (%1 Гц), та, что сходится с изгибом (%2 Гц) на флаттере; масштаб условный.")
                   .arg(native["metrics"].toObject()["torsionFrequencyHz"].toObject()["value"].toDouble(), 0, 'f', 2)
                   .arg(native["metrics"].toObject()["bendingFrequencyHz"].toObject()["value"].toDouble(), 0, 'f', 2);
    }
    if (icing_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        note = quantity == viewer::FieldQuantity::IceThickness
                   ? tr("Толщина льда после %1 мин в облаке; лёд не менял обтекание, форма наледи не восстанавливается.")
                         .arg(native["cloud"].toObject()["durationS"].toDouble() / 60.0, 0, 'f', 1)
                   : tr("Механика при этом расчёте не считается: цвет имеет смысл только у льда.");
    }
    if (emc_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        const QJsonObject environment = native["environment"].toObject();
        note = quantity == viewer::FieldQuantity::ElectricField
                   ? tr("Напряжённость поля на поверхности корпуса на частоте худшего экранирования, %1 МГц, при падающем поле %2 В/м.")
                         .arg(native["metrics"].toObject()["worstFrequencyHz"].toObject()["value"].toDouble() / 1e6, 0, 'f', 0)
                         .arg(environment["fieldVm"].toDouble(), 0, 'f', 0)
                   : tr("Механика при этом расчёте не считается: цвет имеет смысл только у поля.");
    }
    if (lightning_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        const QJsonObject integrity = native["integrity"].toObject();
        const double timeS = integrity["timeS"].toDouble();
        note = quantity == viewer::FieldQuantity::Temperature
                   ? (integrity["burnedThrough"].toBool()
                          ? tr("Температура в момент прожога, t = %1 мс. Плавление и унос металла дугой не моделируются.").arg(timeS * 1e3, 0, 'f', 3)
                          : tr("Температура в конце последней составляющей тока."))
                   : tr("Механика при ударе молнии не считается: цвет имеет смысл только у температуры.");
    }
    if (climate_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        const bool transient = native["time"].toObject()["transient"].toBool();
        auto clock = [](double s) { return QString("%1:%2").arg(static_cast<int>(s / 3600) % 24, 2, 10, QChar('0')).arg(static_cast<int>(s / 60) % 60, 2, 10, QChar('0')); };
        const double hot = native["temperature"].toObject()["peakTimeS"].toDouble(), stressed = native["criticalRegion"].toObject()["timeS"].toDouble();
        note = transient ? tr("Температура — в самый жаркий момент суток (%1); напряжения и форма — в момент наибольшего напряжения (%2).").arg(clock(hot), clock(stressed))
                         : tr("Постоянная температура: выдержка%1.").arg(hot > 0.5 ? tr(" и работа оборудования") : QString());
    }
    if (shock_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        note = tr("Цвет и форма — в момент наибольшего напряжения, t = %1 мс.").arg(1e3 * native["criticalRegion"].toObject()["timeS"].toDouble(), 0, 'f', 2);
    }
    if (bird_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        note = tr("Цвет и форма — в момент наибольшего напряжения, t = %1 мс. Модель линейно-упругая: за пределом текучести она показывает "
                  "необходимость испытания, а не величину напряжения.")
                   .arg(1e3 * native["criticalRegion"].toObject()["timeS"].toDouble(), 0, 'f', 3);
    }
    if (harmonic_) {
        const auto native = QJsonDocument::fromJson(resultJson_).object();
        note = tr("Цвет — амплитуда за цикл на %1 Гц; форма — мгновенное положение в момент наибольшего размаха.")
                   .arg(native["criticalRegion"].toObject()["frequencyHz"].toDouble(), 0, 'f', 2);
    }
    legend_->configure(scene_->field(), quantity, assessed, note);
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

} // namespace cadnext::gui
