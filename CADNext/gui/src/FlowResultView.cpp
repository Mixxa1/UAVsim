#include "FlowResultView.hpp"

#include "FlowAnimation.hpp"
#include "FlowScene3D.hpp"
#include "ViewerSnapshot.hpp"

#include "cadnext/cfd/FlowVolume.hpp"

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/Qt/viewers/SoQtPlaneViewer.h>
#include <Inventor/SbRotation.h>
#include <Inventor/SbViewportRegion.h>
#include <Inventor/actions/SoGLRenderAction.h>
#include <Inventor/nodes/SoCamera.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoLightModel.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoOrthographicCamera.h>
#include <Inventor/nodes/SoSeparator.h>

#include <QButtonGroup>
#include <QCheckBox>
#include <QDir>
#include <QFile>
#include <QComboBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLinearGradient>
#include <QPainter>
#include <QPushButton>
#include <QSlider>
#include <QStackedWidget>
#include <QTimer>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>

namespace cadnext::gui::detail {

// A vertical colour bar with its scale — the way flow simulations label their pictures.
class ColourLegend final : public QWidget {
public:
    enum class Palette { Turbo, CoolWarm };
    explicit ColourLegend(QWidget* parent = nullptr) : QWidget(parent) { setFixedWidth(118); }
    void set(Palette palette, const QString& title, double low, double high, const QString& middle = {}) {
        palette_ = palette; title_ = title; low_ = low; high_ = high; middle_ = middle;
        update();
    }
    void paintEvent(QPaintEvent*) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing);
        p.fillRect(rect(), palette().window());
        if (title_.isEmpty()) return;
        QFont titleFont = font();
        titleFont.setBold(true);
        p.setFont(titleFont);
        p.setPen(palette().text().color());
        p.drawText(QRect(4, 4, width() - 8, 40), Qt::AlignLeft | Qt::TextWordWrap, title_);
        p.setFont(font());
        const QRect bar(8, 50, 20, std::max(height() - 70, 40));
        QLinearGradient gradient(bar.bottomLeft(), bar.topLeft());
        for (int i = 0; i <= 16; ++i) {
            const double t = i / 16.0;
            SbColor c = palette_ == Palette::Turbo ? turbo(t) : SbColor(0, 0, 0);
            if (palette_ == Palette::CoolWarm) {
                const SbColor blue(0.230f, 0.299f, 0.754f), mid(0.865f, 0.865f, 0.865f), red(0.706f, 0.016f, 0.150f);
                const float f = static_cast<float>(std::fabs(2 * t - 1));
                c = t < 0.5 ? mid * (1 - f) + blue * f : mid * (1 - f) + red * f;
            }
            gradient.setColorAt(t, QColor::fromRgbF(c[0], c[1], c[2]));
        }
        p.fillRect(bar, gradient);
        p.setPen(QColor(90, 96, 106));
        p.drawRect(bar);
        p.setPen(palette().text().color());
        for (int i = 0; i <= 4; ++i) {
            const double t = i / 4.0;
            const int y = bar.bottom() - static_cast<int>(t * bar.height());
            p.drawLine(bar.right(), y, bar.right() + 4, y);
            QString label = QString::number(low_ + t * (high_ - low_), 'g', 3);
            if (i == 2 && !middle_.isEmpty()) label = middle_;
            p.drawText(QRect(bar.right() + 7, y - 9, width() - bar.right() - 8, 18), Qt::AlignLeft | Qt::AlignVCenter, label);
        }
    }

private:
    Palette palette_ = Palette::Turbo;
    QString title_, middle_;
    double low_ = 0, high_ = 1;
};

namespace {

QCheckBox* toggle(const QString& text, bool on, QLayout* layout) {
    auto* box = new QCheckBox(text);
    box->setChecked(on);
    layout->addWidget(box);
    return box;
}

// Nodal velocity (V/V∞) of a SU2 volume CSV, by PointID; NaN where a node is absent.
bool readVelocity(const QString& path, std::vector<cfd::FlowSection::Vector>& out, QString& problem) {
    std::ifstream file(path.toStdString());
    std::string line;
    if (!file || !std::getline(file, line)) { problem = QObject::tr("нет поля скорости %1").arg(path); return false; }
    int id = -1, vx = -1, vy = -1, vz = -1, column = 0;
    std::string name;
    for (char c : line + ",") {
        if (c == ',') {
            std::string clean;
            for (char k : name) if (k != '"' && k != ' ' && k != '\r') clean += k;
            if (clean == "PointID") id = column;
            if (clean == "Velocity_x") vx = column;
            if (clean == "Velocity_y") vy = column;
            if (clean == "Velocity_z") vz = column;
            name.clear();
            ++column;
        } else name += c;
    }
    if (id < 0 || vx < 0 || vy < 0 || vz < 0) { problem = QObject::tr("в поле нет номеров узлов или скорости"); return false; }
    const int last = std::max({id, vx, vy, vz});
    out.clear();
    while (std::getline(file, line)) {
        std::array<const char*, 64> starts{};
        int n = 0;
        starts[0] = line.c_str();
        for (const char* c = line.c_str(); *c && n < last; ++c) if (*c == ',') starts[++n] = c + 1;
        if (n < last) continue;
        const long node = std::strtol(starts[id], nullptr, 10);
        if (node < 0 || node > 50000000) { problem = QObject::tr("поле записывается или повреждено"); return false; }
        if (out.size() <= static_cast<std::size_t>(node)) out.resize(static_cast<std::size_t>(node) + 1, {NAN, NAN, NAN});
        out[static_cast<std::size_t>(node)] = {std::strtod(starts[vx], nullptr), std::strtod(starts[vy], nullptr), std::strtod(starts[vz], nullptr)};
    }
    if (out.empty()) { problem = QObject::tr("пустое поле скорости"); return false; }
    return true;
}

} // namespace

FlowResultView::FlowResultView(QWidget* parent) : QWidget(parent) {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(8);

    // What to look at: three plain choices instead of a quantity list.
    auto* modeRow = new QHBoxLayout;
    modes_ = new QButtonGroup(this);
    modes_->setExclusive(true);
    const std::array<std::pair<QString, QString>, 3> modeNames{{
        {tr("Обтекание 3D"), tr("Тело, траектории потока и бегущие по ним стрелки. Мышь: вращать, колесо — масштаб.")},
        {tr("Давление на теле"), tr("Коэффициент давления Cp на поверхности: красное — поток тормозится, синее — разгоняется.")},
        {tr("Сечение"), tr("Разрез посередине размаха: скорость относительно набегающего потока, линии тока, частицы; кадры URANS.")},
    }};
    for (int i = 0; i < 3; ++i) {
        auto* button = new QPushButton(modeNames[i].first);
        button->setCheckable(true);
        button->setToolTip(modeNames[i].second);
        button->setMinimumHeight(30);
        modes_->addButton(button, i);
        modeRow->addWidget(button);
    }
    modes_->button(0)->setChecked(true);
    layout->addLayout(modeRow);

    auto* controlRow = new QHBoxLayout;
    flowControls_ = new QWidget;
    auto* flowLayout = new QHBoxLayout(flowControls_);
    flowLayout->setContentsMargins(0, 0, 0, 0);
    lines_ = toggle(tr("Траектории"), true, flowLayout);
    arrows_ = toggle(tr("Стрелки"), true, flowLayout);
    pressureOnBody_ = toggle(tr("Давление на теле"), false, flowLayout);
    controlRow->addWidget(flowControls_);
    sectionControls_ = new QWidget;
    auto* sectionLayout = new QHBoxLayout(sectionControls_);
    sectionLayout->setContentsMargins(0, 0, 0, 0);
    sectionMap_ = toggle(tr("Цвет"), true, sectionLayout);
    sectionLines_ = toggle(tr("Линии тока"), true, sectionLayout);
    particles_ = toggle(tr("Частицы"), true, sectionLayout);
    frames_ = toggle(tr("Кадры URANS"), true, sectionLayout);
    frames_->setToolTip(tr("Поле меняется во времени, как в расчёте; без галочки остаётся последний кадр."));
    clock_ = new QLabel;
    sectionLayout->addWidget(clock_);
    controlRow->addWidget(sectionControls_);
    controlRow->addStretch(1);
    cameraControls_ = new QWidget;
    auto* cameraLayout = new QHBoxLayout(cameraControls_);
    cameraLayout->setContentsMargins(0, 0, 0, 0);
    // One list instead of five buttons: the row has to fit beside the settings panel. `activated`
    // fires on the item already shown too, so picking it again returns to that view after rotating.
    auto* views = new QComboBox;
    views->addItems({tr("Изометрия"), tr("Сзади"), tr("Сбоку"), tr("Сверху"), tr("Спереди")});
    views->setToolTip(tr("Поставить камеру; мышью вид вращается свободно."));
    connect(views, &QComboBox::activated, this, [this](int i) { viewPreset(i); });
    cameraLayout->addWidget(new QLabel(tr("Вид")));
    cameraLayout->addWidget(views);
    controlRow->addWidget(cameraControls_);
    layout->addLayout(controlRow);

    auto* speedRow = new QHBoxLayout;
    speedRow->addWidget(new QLabel(tr("Скорость анимации")));
    speed_ = new QSlider(Qt::Horizontal);
    speed_->setRange(0, 100);
    speed_->setValue(57); // 0.05 × physical time
    speed_->setToolTip(tr("Во сколько раз анимация медленнее реального потока."));
    speedRow->addWidget(speed_, 1);
    speedLabel_ = new QLabel;
    speedLabel_->setMinimumWidth(220);
    speedRow->addWidget(speedLabel_);
    layout->addLayout(speedRow);

    auto* centre = new QHBoxLayout;
    stack_ = new QStackedWidget;
    auto* host3d = new QWidget;
    host3d->setLayout(new QVBoxLayout);
    host3d->layout()->setContentsMargins(0, 0, 0, 0);
    auto* host2d = new QWidget;
    host2d->setLayout(new QVBoxLayout);
    host2d->layout()->setContentsMargins(0, 0, 0, 0);
    stack_->addWidget(host3d);
    stack_->addWidget(host2d);
    centre->addWidget(stack_, 1);
    legend_ = new ColourLegend;
    centre->addWidget(legend_);
    layout->addLayout(centre, 1);
    status_ = new QLabel;
    status_->setWordWrap(true);
    status_->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
    layout->addWidget(status_);

    scene_ = std::make_unique<FlowScene3D>();
    root3d_ = new SoSeparator;
    root3d_->ref();
    auto* fill = new SoDirectionalLight;
    fill->direction.setValue(0.3f, -1.0f, -0.4f);
    fill->intensity = 0.35f;
    root3d_->addChild(fill);
    root3d_->addChild(scene_->root());
    viewer3d_ = new SoQtExaminerViewer(host3d);
    viewer3d_->setDecoration(false);
    viewer3d_->setHeadlight(true);
    viewer3d_->setBackgroundColor(SbColor(0.955f, 0.96f, 0.965f));
    viewer3d_->setTransparencyType(SoGLRenderAction::SORTED_OBJECT_BLEND);
    viewer3d_->setSceneGraph(root3d_);
    host3d->layout()->addWidget(viewer3d_->getWidget());

    root2d_ = new SoSeparator;
    root2d_->ref();
    viewer2d_ = new SoQtPlaneViewer(host2d);
    viewer2d_->setDecoration(false);
    viewer2d_->setCameraType(SoOrthographicCamera::getClassTypeId());
    viewer2d_->setBackgroundColor(SbColor(0.965f, 0.97f, 0.975f));
    viewer2d_->setTransparencyType(SoGLRenderAction::SORTED_OBJECT_BLEND);
    viewer2d_->setSceneGraph(root2d_);
    host2d->layout()->addWidget(viewer2d_->getWidget());

    connect(modes_, &QButtonGroup::idClicked, this, [this](int id) { setMode(static_cast<Mode>(id)); });
    for (auto* box : {lines_, arrows_, pressureOnBody_, sectionMap_, sectionLines_, particles_, frames_})
        connect(box, &QCheckBox::toggled, this, [this] { applyToggles(); });
    connect(speed_, &QSlider::valueChanged, this, [this] {
        const double rate = playbackRate();
        speedLabel_->setText(tr("%1× · 1 с на экране = %2 мс потока").arg(rate, 0, 'g', 2).arg(rate * 1000.0, 0, 'g', 3));
    });
    emit speed_->valueChanged(speed_->value());

    timer_ = new QTimer(this);
    timer_->setInterval(33);
    wall_.start();
    connect(timer_, &QTimer::timeout, this, [this] {
        const double dt = std::min(wall_.restart() / 1000.0, 0.1);
        if (!isVisible()) return;
        if (mode_ == Mode::Flow && arrows_->isChecked() && haveField_) scene_->advance(dt * playbackRate());
        if (mode_ == Mode::Section && section_ && particles_->isChecked()) {
            section_->advance(dt * playbackRate(), frames_->isChecked() && point_.playFrames);
            clock_->setText(section_->unsteady() ? section_->clockLabel() : QString());
        }
    });
    timer_->start();
    setMode(Mode::Flow);
}

FlowResultView::~FlowResultView() {
    timer_->stop();
    delete viewer3d_;
    delete viewer2d_;
    section_.reset();
    if (sectionBody_) sectionBody_->unref();
    root2d_->unref();
    root3d_->unref();
}

double FlowResultView::playbackRate() const { return std::pow(10.0, -3.0 + 3.0 * speed_->value() / 100.0); }

void FlowResultView::showGeometry(const bridge::ConstructionDescriptor& construction) {
    // Export frame (x left, y back, z up) → solver frame (x aft, y right, z up).
    std::vector<std::array<cfd::FlowVolume::Point, 3>> walls;
    const auto& v = construction.mesh.vertices;
    const auto& indices = construction.mesh.indices;
    auto solver = [&](std::uint32_t i) { return cfd::FlowVolume::Point{v[3 * i + 1], -v[3 * i], v[3 * i + 2]}; };
    for (std::size_t i = 0; i + 2 < indices.size(); i += 3) walls.push_back({solver(indices[i]), solver(indices[i + 1]), solver(indices[i + 2])});
    scene_->setBody(walls);
    scene_->setTrajectories({}, 1.0);
    haveField_ = false;
    shownDirectory_.clear();
    setMode(Mode::Flow);
    viewPreset(0);
    status_->setText(tr("Геометрия текущего документа. Поток появится после первой записи поля решателем."));
    legend_->set(ColourLegend::Palette::Turbo, {}, 0, 1);
}

bool FlowResultView::showPoint(const Point& point, QString& problem) {
    const QDir directory(point.directory);
    const double speed = point.settings.value(QStringLiteral("speedMps")).toDouble(1.0);
    // Surface: wall nodes, their Cp and the body's bounds.
    std::vector<FlowScene3D::SurfaceValue> pressure;
    {
        QFile surface(directory.filePath(QStringLiteral("surface") + point.fieldSuffix + QStringLiteral(".csv")));
        if (!surface.open(QIODevice::ReadOnly)) { problem = tr("нет поверхностного поля"); return false; }
        QString header = QString::fromUtf8(surface.readLine());
        header.remove('"');
        auto names = header.trimmed().split(',');
        for (auto& n : names) n = n.trimmed();
        const int x = names.indexOf("x"), y = names.indexOf("y"), z = names.indexOf("z"), cp = names.indexOf("Pressure_Coefficient");
        if (x < 0 || y < 0 || z < 0 || cp < 0) { problem = tr("в поверхностном поле нет координат или Cp"); return false; }
        body_ = {INFINITY, -INFINITY, INFINITY, -INFINITY, INFINITY, -INFINITY};
        while (!surface.atEnd()) {
            const auto cols = QString::fromUtf8(surface.readLine()).trimmed().split(',');
            if (cols.size() != names.size()) continue;
            const std::array<double, 3> p{cols[x].toDouble(), cols[y].toDouble(), cols[z].toDouble()};
            pressure.push_back({p, cols[cp].toDouble()});
            for (int a = 0; a < 3; ++a) { body_[2 * a] = std::min(body_[2 * a], p[a]); body_[2 * a + 1] = std::max(body_[2 * a + 1], p[a]); }
        }
        if (pressure.empty()) { problem = tr("пустое поверхностное поле"); return false; }
    }
    if (!readVelocity(directory.filePath(QStringLiteral("volume") + point.fieldSuffix + QStringLiteral(".csv")), normalisedVelocity_, problem)) return false;

    // The region the trajectories live in: from a third of the body ahead of it to a body length
    // behind, and a fifth to a third of it to the sides.
    const double length = std::max({body_[1] - body_[0], body_[3] - body_[2], body_[5] - body_[4], 1e-3});
    const std::array<double, 6> region{body_[0] - 0.35 * length, body_[1] + 1.0 * length, body_[2] - 0.2 * length,
                                       body_[3] + 0.2 * length, body_[4] - 0.35 * length, body_[5] + 0.35 * length};
    std::vector<cfd::FlowVolume::Point> velocity(normalisedVelocity_.size());
    for (std::size_t i = 0; i < velocity.size(); ++i)
        for (int k = 0; k < 3; ++k) velocity[i][k] = normalisedVelocity_[i][k] * speed;
    cfd::FlowVolume volume;
    try {
        std::ifstream mesh(directory.filePath(QStringLiteral("mesh.su2")).toStdString());
        volume = cfd::FlowVolume::read(mesh, velocity, region);
    } catch (const std::exception& error) {
        problem = tr("объёмное поле ещё не готово: %1").arg(QString::fromUtf8(error.what()));
        return false;
    }
    // Seeds where the flow does something: a rake close to the body across its whole width, and a
    // small one around each side edge, where a lifting surface sheds its tip vortex. Both are moved
    // along the incoming stream, so at an angle of attack they still meet the body rather than pass
    // above or below it.
    const double rakeX = region[0] + 0.01 * (region[1] - region[0]);
    double lift = 0.0;
    {
        cfd::FlowVolume::Point v{};
        if (volume.sample({rakeX, 0.5 * (body_[2] + body_[3]), 0.5 * (body_[4] + body_[5])}, v) && std::fabs(v[0]) > 1e-9)
            lift = v[2] / v[0] * (body_[0] - rakeX);
    }
    const double z0 = body_[4] - lift, z1 = body_[5] - lift;
    std::vector<cfd::Trajectory> trajectories;
    auto seed = [&](std::array<double, 4> span, int columns, int rows, unsigned seedValue) {
        cfd::TrajectorySettings rake;
        rake.rakeX = rakeX;
        rake.rakeSpan = span;
        rake.columns = columns;
        rake.rows = rows;
        rake.seed = seedValue;
        for (auto& line : cfd::traceTrajectories(volume, rake)) trajectories.push_back(std::move(line));
    };
    seed({body_[2] - 0.04 * length, body_[3] + 0.04 * length, z0 - 0.05 * length, z1 + 0.05 * length}, 30, 5, 7);
    for (double edge : {body_[2], body_[3]})
        seed({edge - 0.04 * length, edge + 0.04 * length, z0 - 0.04 * length, z1 + 0.04 * length}, 5, 5, 13);
    // Vortices: cores found by stream-wise vorticity just behind the body, and a ring of lines
    // traced through each, upstream to the rake region and downstream out of the picture — the
    // roll-up of a tip vortex is where the eye expects to see the flow turn.
    const double behind = body_[1] + 0.12 * length;
    vortexCores_ = 0;
    const std::size_t firstVortexLine = trajectories.size();
    for (const auto& core : cfd::findVortexCores(volume, behind, {body_[2] - 0.15 * length, body_[3] + 0.15 * length,
                                                               z0 - 0.25 * length, z1 + 0.25 * length})) {
        std::vector<cfd::FlowVolume::Point> ring;
        const double r = 0.018 * length;
        for (int k = 0; k < 10; ++k) {
            const double a = 2 * M_PI * k / 10;
            ring.push_back({behind, core.position[1] + r * std::cos(a), core.position[2] + r * std::sin(a)});
        }
        for (auto& line : cfd::traceThrough(volume, ring)) trajectories.push_back(std::move(line));
        ++vortexCores_;
    }

    const bool samePoint = shownDirectory_ == point.directory;
    point_ = point;
    freeStream_ = speed;
    haveField_ = true;
    scene_->setBody(volume.walls());
    std::vector<double> cps;
    for (const auto& p : pressure) cps.push_back(p.value);
    std::sort(cps.begin(), cps.end());
    cpLow_ = cps[cps.size() * 2 / 100];
    cpHigh_ = std::max(cps[cps.size() * 98 / 100], cpLow_ + 1e-6);
    scene_->setBodyValues(pressure, cpLow_, cpHigh_);
    scene_->setTrajectories(std::move(trajectories), speed, firstVortexLine);
    section_.reset();
    root2d_->removeAllChildren();
    if (sectionBody_) { sectionBody_->unref(); sectionBody_ = nullptr; }
    if (!samePoint) {
        shownDirectory_ = point.directory;
        if (mode_ != Mode::Section) viewPreset(0);
    }
    if (mode_ == Mode::Section) ensureSection();
    applyToggles();
    updateLegend();
    status_->setText(describe());
    return true;
}

void FlowResultView::ensureSection() {
    if (section_ || !haveField_) return;
    const double chord = body_[1] - body_[0], thickness = body_[5] - body_[4];
    const double plane = point_.haveSectionPlane ? point_.sectionPlane : 0.5 * (body_[2] + body_[3]);
    const double centreX = 0.5 * (body_[0] + body_[1]), centreZ = 0.5 * (body_[4] + body_[5]);
    const double aspect = std::max<double>(viewer2d_->getViewportRegion().getViewportAspectRatio(), 0.5);
    const double half = std::clamp(std::max({chord * 0.55, thickness * 1.5, chord * 4.2 / (2.0 * aspect)}), chord * 0.55, chord * 1.6);
    sectionRegion_ = {centreX - chord * 1.2, centreX + chord * 3.0, centreZ - half, centreZ + half};
    cfd::FlowSection section;
    try {
        std::ifstream mesh(QDir(point_.directory).filePath(QStringLiteral("mesh.su2")).toStdString());
        section = cfd::FlowSection::read(mesh, normalisedVelocity_, plane, sectionRegion_);
    } catch (const std::exception& error) {
        status_->setText(tr("Сечение не построено: %1").arg(QString::fromUtf8(error.what())));
        return;
    }
    root2d_->removeAllChildren();
    auto* body = new SoSeparator;
    auto* material = new SoMaterial;
    material->diffuseColor.setValue(0.10f, 0.11f, 0.13f);
    body->addChild(material);
    auto* coordinates = new SoCoordinate3;
    auto* faces = new SoIndexedFaceSet;
    int vertex = 0, index = 0;
    for (const auto& face : section.walls) {
        for (const auto& p : face) {
            coordinates->point.set1Value(vertex, SbVec3f(static_cast<float>(p[1]), static_cast<float>(p[2]), static_cast<float>(p[0])));
            faces->coordIndex.set1Value(index++, vertex++);
        }
        faces->coordIndex.set1Value(index++, -1);
    }
    body->addChild(coordinates);
    body->addChild(faces);
    section_ = std::make_unique<FlowAnimation>(std::move(section), sectionRegion_, plane, freeStream_);
    if (point_.playFrames) {
        std::vector<FlowAnimation::Frame> frames;
        const QDir directory(point_.directory);
        const double step = point_.settings.value(QStringLiteral("timeStepSeconds")).toDouble();
        for (const auto& name : directory.entryList({"section_*.csv"}, QDir::Files, QDir::Name)) {
            bool ok = false;
            const int n = name.mid(8, name.size() - 12).toInt(&ok);
            if (ok) frames.push_back({directory.filePath(name).toStdString(), n * step, n});
        }
        if (frames.size() > 1) {
            // A time-accurate record plays in about eight seconds.
            const double span = frames.back().time - frames.front().time;
            if (span > 0) speed_->setValue(static_cast<int>(std::lround((std::log10(std::clamp(span / 8.0, 1e-3, 1.0)) + 3.0) / 3.0 * 100.0)));
        }
        section_->setFrames(std::move(frames));
    }
    if (sectionBody_) sectionBody_->unref();
    sectionBody_ = body;
    sectionBody_->ref();
    // Look along the span at the section region.
    if (auto* camera = viewer2d_->getCamera()) {
        camera->orientation.setValue(SbRotation(SbVec3f(0, 0, -1), SbVec3f(1, 0, 0)));
        viewer2d_->viewAll();
        const float width = static_cast<float>(sectionRegion_[1] - sectionRegion_[0]), height = static_cast<float>(sectionRegion_[3] - sectionRegion_[2]);
        camera->position.setValue(camera->position.getValue()[0], static_cast<float>(sectionRegion_[2] + sectionRegion_[3]) * 0.5f,
                                  static_cast<float>(sectionRegion_[0] + sectionRegion_[1]) * 0.5f);
        if (auto* ortho = dynamic_cast<SoOrthographicCamera*>(camera)) {
            const float viewAspect = std::max(viewer2d_->getViewportRegion().getViewportAspectRatio(), 0.1f);
            ortho->height = std::max(height, width / viewAspect) * 1.04f;
        }
    }
    applyToggles();
}

void FlowResultView::setMode(Mode mode) {
    mode_ = mode;
    modes_->button(static_cast<int>(mode))->setChecked(true);
    const bool section = mode == Mode::Section;
    stack_->setCurrentIndex(section ? 1 : 0);
    flowControls_->setVisible(mode == Mode::Flow);
    sectionControls_->setVisible(section);
    cameraControls_->setVisible(!section);
    if (section) ensureSection();
    applyToggles();
    updateLegend();
    if (haveField_) status_->setText(describe());
}

void FlowResultView::applyToggles() {
    const bool flow = mode_ == Mode::Flow;
    scene_->setShowLines(flow && lines_->isChecked() && haveField_);
    scene_->setShowArrows(flow && arrows_->isChecked() && haveField_);
    scene_->setBodyColoured(mode_ == Mode::Pressure || (flow && pressureOnBody_->isChecked()));
    if (section_) {
        // Drawing order: colour map, body, streamlines, particles.
        root2d_->removeAllChildren();
        if (sectionMap_->isChecked()) root2d_->addChild(section_->colourMap());
        if (sectionBody_) root2d_->addChild(sectionBody_);
        if (sectionLines_->isChecked()) root2d_->addChild(section_->streamlines());
        if (particles_->isChecked()) root2d_->addChild(section_->particles());
    }
    updateLegend();
}

void FlowResultView::updateLegend() {
    if (!haveField_) { legend_->set(ColourLegend::Palette::Turbo, {}, 0, 1); return; }
    if (mode_ == Mode::Section && section_) {
        const double d = section_->deviation();
        legend_->set(ColourLegend::Palette::CoolWarm, tr("Скорость, м/с"), freeStream_ * (1 - d), freeStream_ * (1 + d),
                     tr("%1 = V∞").arg(freeStream_, 0, 'g', 3));
    } else if (mode_ == Mode::Pressure || pressureOnBody_->isChecked()) {
        legend_->set(ColourLegend::Palette::Turbo, tr("Давление на теле, Cp"), cpLow_, cpHigh_);
    } else {
        legend_->set(ColourLegend::Palette::Turbo, tr("Скорость, м/с"), scene_->speedLow(), scene_->speedHigh());
    }
}

void FlowResultView::viewPreset(int preset) {
    auto* camera = viewer3d_->getCamera();
    if (!camera) return;
    // Pressure: the body alone. Flow: the body and the lines around it, centred a little behind the
    // body so the wake is in the picture too.
    const bool flow = mode_ == Mode::Flow && haveField_;
    const SbVec3f low = flow ? scene_->sceneMin() : scene_->bodyMin(), high = flow ? scene_->sceneMax() : scene_->bodyMax();
    const SbVec3f bodyCentre = (scene_->bodyMin() + scene_->bodyMax()) * 0.5f;
    const SbVec3f centre = flow ? bodyCentre * 0.6f + (low + high) * 0.2f : (low + high) * 0.5f;
    const float size = std::max((high - low).length() * (flow ? 0.75f : 1.0f), 1e-3f);
    // Isometric from ahead, above and to the left; from behind (the wake and the tip vortices);
    // side from the left; top; front from upstream.
    const std::array<SbVec3f, 5> from{SbVec3f(-0.9f, 0.75f, 1.1f), SbVec3f(1.0f, 0.55f, 0.75f), SbVec3f(0, 0, 1), SbVec3f(0, 1, 0), SbVec3f(-1, 0, 0)};
    const std::array<SbVec3f, 5> up{SbVec3f(0, 1, 0), SbVec3f(0, 1, 0), SbVec3f(0, 1, 0), SbVec3f(0, 0, -1), SbVec3f(0, 1, 0)};
    SbVec3f direction = from[static_cast<std::size_t>(preset)];
    direction.normalize();
    camera->position = centre + direction * (1.35f * size);
    camera->pointAt(centre, up[static_cast<std::size_t>(preset)]);
    camera->focalDistance = 1.35f * size;
    camera->nearDistance = 0.01f * size;
    camera->farDistance = 20.0f * size;
}

QString FlowResultView::describe() const {
    switch (mode_) {
    case Mode::Flow:
        return tr("%1 траекторий по рассчитанному полю: от решётки перед телом и через %2 найденных вихрей за ним; цвет — скорость. "
                  "Стрелки движутся с расчётной скоростью, замедленной ползунком: где они сгущаются, воздух тормозится.")
            .arg(scene_->lineCount()).arg(vortexCores_);
    case Mode::Pressure:
        return tr("Cp = (p − p∞)/(½ρV∞²): около 1 — торможение потока, отрицательные значения — разрежение.");
    case Mode::Section:
        return section_ && section_->unsteady()
                   ? tr("Сечение посередине размаха; кадры URANS сменяются по физическому времени, между кадрами поле интерполируется.")
                   : tr("Сечение посередине размаха: цвет — скорость относительно набегающего потока, частицы идут с расчётной скоростью.");
    }
    return {};
}

QImage FlowResultView::capture() {
    SoQtViewer* viewer = mode_ == Mode::Section ? static_cast<SoQtViewer*>(viewer2d_) : static_cast<SoQtViewer*>(viewer3d_);
    auto* root = new SoSeparator;
    root->ref();
    root->addChild(viewer->getCamera());
    root->addChild(viewer->getSceneGraph());
    const QImage image = snapshotWithViewer(*window(), *viewer, root);
    root->unref();
    return image;
}

} // namespace cadnext::gui::detail
