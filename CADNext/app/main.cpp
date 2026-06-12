#include <QApplication>

#include <Inventor/Qt/SoQt.h>

#include "cadnext/gui/MainWindow.hpp"

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("CADNext"));
    QApplication::setOrganizationName(QStringLiteral("UAVsim"));

    cadnext::gui::MainWindow window;

    // SoQt must be initialized with the application's top-level widget
    // before any Coin3D component is created.
    SoQt::init(&window);
    window.initializeViewport();

    window.resize(1440, 900);
    window.show();

    return QApplication::exec();
}
