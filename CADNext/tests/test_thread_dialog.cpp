// The Thread tool's window on faces it is given: the size it suggests, what it says about the face, and
// when it lets the thread be built.
//
// Criteria, fixed before the first run:
//   - A shaft Ø8 suggests M8 (coarse, 1.25), a hole Ø6.8 M8 internal, a pipe end cone 1:16 at R1/2's small
//     end R1/2; the length defaults to the face's; right-handed.
//   - A shaft thicker than the thread says it will be turned down, and still builds; one thinner than the
//     thread's root, or a cone of another taper, does not build and says why.
//   - On a cylinder the taper standards cannot be picked; on a cone of 1:16 only they can.
#include "cadnext/gui/ThreadDialog.hpp"

#include <QApplication>
#include <QComboBox>
#include <QLabel>
#include <QPushButton>
#include <QStandardItemModel>

#include <cstdio>
#include <string>

using namespace cadnext;
using namespace cadnext::gui;

namespace {

int failures = 0;

void check(bool condition, const std::string& what) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", what.c_str());
    if (!condition) ++failures;
}

ThreadFace shaft(double diameterMm, double lengthMm, bool hole = false, double slope = 0.0) {
    ThreadFace face;
    face.surface.axisOrigin = {0, 0, 0};
    face.surface.axisDirection = {0, 0, 1};
    face.surface.radius = diameterMm / 2000;
    face.surface.slope = slope;
    face.surface.axialStart = 0;
    face.surface.axialEnd = lengthMm / 1000;
    face.surface.holeWall = hole;
    face.free = {true, false};
    face.ends = {Vector3{0, 0, 0}, Vector3{0, 0, lengthMm / 1000}};
    return face;
}

QPushButton* buildButton(ThreadDialog& dialog) {
    for (QPushButton* button : dialog.findChildren<QPushButton*>())
        if (button->text() == QStringLiteral("Построить")) return button;
    return nullptr;
}

QString note(ThreadDialog& dialog) {
    QString all;
    for (QLabel* label : dialog.findChildren<QLabel*>())
        if (label->wordWrap()) all += label->text();
    return all;
}

// The standard combo is the first combo made; its items' enabled state.
bool standardEnabled(ThreadDialog& dialog, int index) {
    const auto combos = dialog.findChildren<QComboBox*>();
    auto* model = combos.isEmpty() ? nullptr : qobject_cast<QStandardItemModel*>(combos.first()->model());
    return model && model->item(index)->isEnabled();
}

} // namespace

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QApplication app(argc, argv);

    {
        ThreadDialog dialog(shaft(8, 30));
        const ThreadParameters p = dialog.parameters();
        check(p.standard == ThreadStandard::MetricCoarse && p.designation == "M8" && p.pitchMm == 1.25,
              "вал Ø8: предложена M8 с шагом 1,25");
        check(p.lengthMm == 30 && p.rightHanded && !p.internal, "длина по грани, правая, наружная");
        check(buildButton(dialog) && buildButton(dialog)->isEnabled() && note(dialog).isEmpty(), "вал Ø8: строится, без оговорок");
        check(!standardEnabled(dialog, 5) && !standardEnabled(dialog, 6) && standardEnabled(dialog, 4),
              "на цилиндре R и NPT недоступны, G доступна");
    }
    {
        ThreadDialog dialog(shaft(6.8, 15, true));
        const ThreadParameters p = dialog.parameters();
        check(p.designation == "M8" && p.internal, "отверстие Ø6,8: предложена M8, внутренняя");
    }
    {
        ThreadDialog dialog(shaft(8.2, 20));
        check(buildButton(dialog)->isEnabled() && note(dialog).contains(QStringLiteral("проточена до Ø8")),
              "вал Ø8,2 под M8: строится, сказано о проточке до Ø8");
    }
    {
        // Ø5 with M8 picked by hand: thinner than its root.
        ThreadDialog dialog(shaft(5, 20));
        const auto combos = dialog.findChildren<QComboBox*>();
        QComboBox* size = combos.size() > 1 ? combos[1] : nullptr;
        if (size) size->setCurrentIndex(size->findText(QStringLiteral("M8")));
        check(dialog.parameters().designation == "M8" && !buildButton(dialog)->isEnabled() &&
                  note(dialog).contains(QStringLiteral("тоньше дна")),
              "вал Ø5 под M8: не строится, сказано почему");
    }
    {
        // R1/2's small end: 20.955 - 8.2/16 mm, taper 1:16 (slope 1/32 on the radius).
        ThreadDialog dialog(shaft(20.955 - 8.2 / 16, 16, false, 1.0 / 32));
        const ThreadParameters p = dialog.parameters();
        check(p.standard == ThreadStandard::PipeR && p.designation == "R1/2" && p.gaugeLengthMm == 8.2,
              "конус 1:16 у малого конца R1/2: предложена R1/2");
        check(buildButton(dialog)->isEnabled() && standardEnabled(dialog, 6) && !standardEnabled(dialog, 0),
              "на конусе 1:16 строится, доступны только конические");
    }
    {
        ThreadDialog dialog(shaft(20, 16, false, 0.05));
        check(!buildButton(dialog)->isEnabled() && note(dialog).contains(QStringLiteral("другой конусности")),
              "конус 1:10: не строится, сказано почему");
    }
    std::printf("%s: %d failures\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
