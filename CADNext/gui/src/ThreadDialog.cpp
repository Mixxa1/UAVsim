#include "cadnext/gui/ThreadDialog.hpp"

#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QStandardItemModel>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>
#include <limits>

namespace cadnext::gui {

namespace {

// "8", "1,25", "20,955": millimetres as a Russian drawing writes them.
QString mm(double value) {
    QString text = QString::number(value, 'f', 3);
    while (text.endsWith('0')) text.chop(1);
    if (text.endsWith('.')) text.chop(1);
    return text.replace('.', ',');
}

constexpr ThreadStandard kStandards[] = {ThreadStandard::MetricCoarse, ThreadStandard::MetricFine, ThreadStandard::Unc,
                                         ThreadStandard::Unf,          ThreadStandard::PipeG,      ThreadStandard::PipeR,
                                         ThreadStandard::Npt,          ThreadStandard::Custom};

} // namespace

ThreadDialog::ThreadDialog(const ThreadFace& face, QWidget* parent) : QDialog(parent), face_(face) {
    setWindowTitle(tr("Резьба"));
    auto* layout = new QVBoxLayout(this);
    auto* form = new QFormLayout;

    faceLabel_ = new QLabel(this);
    form->addRow(tr("Грань"), faceLabel_);

    standard_ = new QComboBox(this);
    for (const ThreadStandard standard : kStandards)
        standard_->addItem(QString::fromUtf8(threadStandardTitle(standard)), int(standard));
    form->addRow(tr("Стандарт"), standard_);

    size_ = new QComboBox(this);
    size_->setMaxVisibleItems(20);
    sizeLabel_ = new QLabel(tr("Размер"), this);
    form->addRow(sizeLabel_, size_);

    diameter_ = new QDoubleSpinBox(this);
    diameter_->setRange(0.5, 1000.0);
    diameter_->setDecimals(3);
    diameter_->setSuffix(tr(" мм"));
    diameterLabel_ = new QLabel(tr("Наружный диаметр"), this);
    form->addRow(diameterLabel_, diameter_);

    pitch_ = new QDoubleSpinBox(this);
    pitch_->setRange(0.05, 20.0);
    pitch_->setDecimals(3);
    pitch_->setSingleStep(0.25);
    pitch_->setValue(1.0);
    pitch_->setSuffix(tr(" мм"));
    pitchLabel_ = new QLabel(tr("Шаг"), this);
    form->addRow(pitchLabel_, pitch_);

    const double faceLengthMm = face_.surface.length() * 1000.0;
    length_ = new QDoubleSpinBox(this);
    length_->setRange(0.01, std::max(faceLengthMm, 0.01));
    length_->setDecimals(3);
    length_->setValue(faceLengthMm);
    length_->setSuffix(tr(" мм"));
    form->addRow(tr("Длина"), length_);

    start_ = new QComboBox(this);
    for (int end = 0; end < 2; ++end) {
        const Vector3& c = face_.ends[end];
        const QString kind = face_.free[end] ? tr("свободный")
                             : face_.surface.holeWall ? tr("дно или уступ отверстия")
                                                      : tr("уступ");
        start_->addItem(tr("Торец в (%1; %2; %3) — %4").arg(mm(c.x * 1000), mm(c.y * 1000), mm(c.z * 1000), kind));
    }
    start_->setCurrentIndex(!face_.free[0] && face_.free[1] ? 1 : 0);
    startLabel_ = new QLabel(tr("Начало"), this);
    form->addRow(startLabel_, start_);

    hand_ = new QComboBox(this);
    hand_->addItem(tr("Правая"));
    hand_->addItem(tr("Левая"));
    form->addRow(tr("Направление"), hand_);

    layout->addLayout(form);
    note_ = new QLabel(this);
    note_->setWordWrap(true);
    layout->addWidget(note_);

    auto* buttons = new QHBoxLayout;
    buttons->addStretch();
    build_ = new QPushButton(tr("Построить"), this);
    build_->setDefault(true);
    auto* cancel = new QPushButton(tr("Отмена"), this);
    buttons->addWidget(build_);
    buttons->addWidget(cancel);
    layout->addLayout(buttons);
    connect(build_, &QPushButton::clicked, this, &QDialog::accept);
    connect(cancel, &QPushButton::clicked, this, &QDialog::reject);

    // What the face is, and which standards fit it: parallel ones on a cylinder, taper ones on a cone of
    // their 1:16.
    const ThreadSurface& s = face_.surface;
    const QString what = s.holeWall ? tr("отверстие") : tr("вал");
    if (!cone()) {
        faceLabel_->setText(tr("%1 Ø%2 мм, длина %3 мм").arg(what, mm(2000 * s.radius), mm(faceLengthMm)));
    } else {
        const double a = 2000 * s.radiusAt(s.axialStart), b = 2000 * s.radiusAt(s.axialEnd);
        faceLabel_->setText(tr("%1, конус 1:%2, Ø%3–%4 мм, длина %5 мм")
                                .arg(what, mm(1.0 / (2 * std::fabs(s.slope))), mm(std::min(a, b)), mm(std::max(a, b)), mm(faceLengthMm)));
    }
    auto* model = qobject_cast<QStandardItemModel*>(standard_->model());
    for (int i = 0; i < standard_->count(); ++i) {
        const bool taper = threadIsTaper(kStandards[i]);
        const bool fits = cone() ? taper && taperFace() : !taper;
        if (model) model->item(i)->setEnabled(fits);
    }
    standard_->setCurrentIndex(cone() ? 5 : 0); // R on a cone, metric coarse on a cylinder

    connect(standard_, &QComboBox::currentIndexChanged, this, [this]() {
        fillSizes();
        refresh();
    });
    for (QComboBox* combo : {size_, start_, hand_}) connect(combo, &QComboBox::currentIndexChanged, this, [this]() { refresh(); });
    for (QDoubleSpinBox* spin : {diameter_, pitch_, length_})
        connect(spin, &QDoubleSpinBox::valueChanged, this, [this]() { refresh(); });
    fillSizes();
    refresh();
}

bool ThreadDialog::cone() const { return std::fabs(face_.surface.slope) > 1e-9; }

bool ThreadDialog::taperFace() const { return std::fabs(2 * std::fabs(face_.surface.slope) - 1.0 / 16) <= 1e-6; }

double ThreadDialog::faceDiameterMm() const {
    const ThreadSurface& s = face_.surface;
    if (!cone()) return 2000 * s.radius;
    const double sign = s.slope > 0 ? 1.0 : -1.0;
    const double small = std::min(sign * s.axialStart, sign * s.axialEnd), large = std::max(sign * s.axialStart, sign * s.axialEnd);
    return 2000 * (s.radius + std::fabs(s.slope) * (s.holeWall ? large : small));
}

void ThreadDialog::fillSizes() {
    const ThreadStandard standard = ThreadStandard(standard_->currentData().toInt());
    const bool custom = standard == ThreadStandard::Custom;
    for (QWidget* w : {static_cast<QWidget*>(size_), static_cast<QWidget*>(sizeLabel_)}) w->setVisible(!custom);
    for (QWidget* w : {static_cast<QWidget*>(diameter_), static_cast<QWidget*>(diameterLabel_), static_cast<QWidget*>(pitch_),
                       static_cast<QWidget*>(pitchLabel_)})
        w->setVisible(custom);
    const bool taper = threadIsTaper(standard);
    start_->setVisible(!taper);
    startLabel_->setVisible(!taper);

    const QSignalBlocker block(size_);
    size_->clear();
    const std::vector<ThreadSize>& sizes = threadSizes(standard);
    const ThreadForm form = threadForm(standard);
    const double face = faceDiameterMm();
    int best = 0;
    double bestGap = std::numeric_limits<double>::infinity();
    for (int i = 0; i < int(sizes.size()); ++i) {
        const ThreadSize& size = sizes[i];
        size_->addItem(QString::fromStdString(size.designation));
        // The size whose surface on this side lies nearest the face where the thread starts.
        double surface = size.majorDiameterMm;
        if (taper && !face_.surface.holeWall) surface -= size.gaugeLengthMm / 16;
        if (face_.surface.holeWall) surface -= 2 * threadDepthMm(form, size.pitchMm);
        if (const double gap = std::fabs(surface - face); gap < bestGap) bestGap = gap, best = i;
    }
    size_->setCurrentIndex(best);
    if (custom) {
        const QSignalBlocker blockDiameter(diameter_);
        diameter_->setValue(face_.surface.holeWall ? face + 2 * threadDepthMm(form, pitch_->value()) : face);
    }
}

ThreadParameters ThreadDialog::parameters() const {
    ThreadParameters p;
    p.standard = ThreadStandard(standard_->currentData().toInt());
    const std::vector<ThreadSize>& sizes = threadSizes(p.standard);
    if (p.standard == ThreadStandard::Custom || size_->currentIndex() < 0 || size_->currentIndex() >= int(sizes.size())) {
        p.majorDiameterMm = diameter_->value();
        p.pitchMm = pitch_->value();
    } else {
        const ThreadSize& size = sizes[size_->currentIndex()];
        p.designation = size.designation;
        p.majorDiameterMm = size.majorDiameterMm;
        p.pitchMm = size.pitchMm;
        p.gaugeLengthMm = size.gaugeLengthMm;
    }
    p.lengthMm = length_->value();
    p.fromFarEnd = !threadIsTaper(p.standard) && start_->currentIndex() == 1;
    p.internal = face_.surface.holeWall;
    p.rightHanded = hand_->currentIndex() == 0;
    return p;
}

void ThreadDialog::refresh() {
    const ThreadParameters p = parameters();
    const bool taper = threadIsTaper(p.standard);
    QStringList lines;
    bool ok = true;
    if (cone() && !taperFace()) {
        lines << tr("Резьба режется на цилиндре или на конусе 1:16 (R, Rc, NPT); эта грань — конус другой конусности.");
        ok = false;
    }
    const double depth = threadDepthMm(threadForm(p.standard), p.pitchMm);
    // The major diameter where the thread starts; the face's diameter there.
    const double major = taper && !p.internal ? p.majorDiameterMm - p.gaugeLengthMm / 16 : p.majorDiameterMm;
    const double face = faceDiameterMm();
    ThreadParameters marked = p;
    const QString marking = QString::fromStdString(threadMarking(marked));
    if (ok) {
        if (!(p.majorDiameterMm > 2 * p.pitchMm) || !(p.lengthMm > p.pitchMm)) {
            lines << tr("Длина резьбы должна быть больше шага, диаметр — больше двух шагов.");
            ok = false;
        } else if (!p.internal) {
            if (face <= major - 2 * depth) {
                lines << tr("Вал Ø%1 тоньше дна резьбы %2 (Ø%3) — витки не во что врезать.").arg(mm(face), marking, mm(major - 2 * depth));
                ok = false;
            } else if (face > major + 1e-3) {
                lines << tr("Вал Ø%1 толще резьбы %2 — зона резьбы будет проточена до Ø%3.").arg(mm(face), marking, mm(major));
            }
        } else {
            if (face >= major) {
                lines << tr("Отверстие Ø%1 не уже резьбы %2 (Ø%3) — витки не во что врезать.").arg(mm(face), marking, mm(major));
                ok = false;
            } else if (face < major - 2 * depth - 1e-3) {
                lines << tr("Отверстие Ø%1 уже резьбы %2 — зона резьбы будет расточена до Ø%3.")
                             .arg(mm(face), marking, mm(major - 2 * depth));
            }
        }
        if (taper) lines << (p.internal ? tr("Идёт от устья, где основная плоскость, вглубь.") : tr("Идёт от малого конца."));
    }
    note_->setText(lines.join('\n'));
    note_->setVisible(!lines.isEmpty());
    build_->setEnabled(ok);
    setWindowTitle(ok ? tr("Резьба %1").arg(marking) : tr("Резьба"));
}

} // namespace cadnext::gui
