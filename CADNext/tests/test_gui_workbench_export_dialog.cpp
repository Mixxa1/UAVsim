// «Экспорт в Мастерскую» as a user fills it: axes start at the Workbench's convention (nose −Y,
// Z up), a cleared forward axis and a missing material are refused with the reason, a complete dialog yields a request the builder turns into a
// .uavframe whose bodies carry the chosen materials and axes.
//
//   cadnext_test_gui_workbench_export_dialog [dialog.png]

#include "fea_test_support.hpp"

#include "cadnext/bridge/ConstructionExport.hpp"
#include "cadnext/gui/WorkbenchExportDialog.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QApplication>

using namespace cadnext;
using fea_test::check;

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    kernel::OcctKernel kernel;
    const auto plate = kernel.makeExtrudedPolygon({{{-0.1, -0.1, 0}, {0.1, -0.1, 0}, {0.1, 0.1, 0}, {-0.1, 0.1, 0}}, {0, 0, 0.01}});
    const auto arm = kernel.makeExtrudedPolygon({{{0.1, -0.01, 0}, {0.4, -0.01, 0}, {0.4, 0.01, 0}, {0.1, 0.01, 0}}, {0, 0, 0.02}});

    gui::WorkbenchExportDialog dialog({{"plate", QStringLiteral("Плита"), plate.value(), std::nullopt},
                                       {"arm", QStringLiteral("Луч"), arm.value(), std::string("pla_fdm")}},
                                      QStringLiteral("Рама"));
    auto reason = [&]() {
        const auto request = dialog.request();
        return request.isOk() ? std::string() : request.error().message;
    };
    {
        gui::WorkbenchExportDialog preset({{"arm", QStringLiteral("Луч"), arm.value(), std::string("pla_fdm")}}, QStringLiteral("Рама"));
        const auto defaults = preset.request();
        check(defaults.isOk() && defaults.value().cadAxes.forward == "-y" && defaults.value().cadAxes.up == "+z",
              "axes start at the Workbench's import convention: nose −Y, Z up");
    }
    dialog.setForwardAxis("");
    check(reason().find("вперёд") != std::string::npos, "no forward axis chosen: refused", reason());
    dialog.setForwardAxis("+z");
    check(reason().find("перпендикуляр") != std::string::npos, "forward along the default up (+Z): refused", reason());
    dialog.setForwardAxis("+x");
    check(reason().find("Плита") != std::string::npos, "a body without material: refused by name", reason());
    dialog.setBodyMaterial(0, "al_7075_t6");
    const auto request = dialog.request();
    check(request.isOk(), "complete dialog builds a request", reason());
    if (request.isOk()) {
        const auto& r = request.value();
        check(r.cadAxes.forward == "+x" && r.cadAxes.up == "+z" && r.bodies.size() == 2 && r.bodies[0].materialId == "al_7075_t6"
                  && r.bodies[1].materialId == "pla_fdm" && r.bodies[0].densityKgPerM3 > 0.0,
              "request carries the axes, the chosen material and the part's own preselected one");
        const auto built = bridge::buildConstruction(kernel, r);
        check(built.isOk() && built.value().bodies.size() == 2 && built.value().bodies[1].materialId == "pla_fdm",
              "the request builds a construction", built.isOk() ? "" : built.error().message);
    }
    if (argc > 1) {
        dialog.resize(560, 460);
        dialog.show();
        app.processEvents();
        check(dialog.grab().save(QString::fromLocal8Bit(argv[1])), "dialog image saved");
    }
    return fea_test::finish("test_gui_workbench_export_dialog");
}
