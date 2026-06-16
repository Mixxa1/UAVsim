#include <QApplication>
#include <QTranslator>
#include <QLocale>
#include <QString>

#include <Inventor/Qt/SoQt.h>

#include "cadnext/gui/MainWindow.hpp"

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("CADNext"));

    // Load translation based on system locale (e.g. ru_RU → cadnext_ru.qm)
    QTranslator translator;
    const QString locale = QLocale::system().name();
    const QString qmDir = QCoreApplication::applicationDirPath() + QStringLiteral("/../translations");
    if (!translator.load(QStringLiteral("cadnext_") + locale, qmDir)) {
        translator.load(QStringLiteral("cadnext_") + locale.split(QLatin1Char('_')).first(), qmDir);
    }
    app.installTranslator(&translator);
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
