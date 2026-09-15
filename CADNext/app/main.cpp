#include <QApplication>
#include <QCommandLineParser>
#include <QTimer>
#include <QTranslator>
#include <QLocale>
#include <QString>

#include <Inventor/Qt/SoQt.h>

#include "cadnext/gui/MainWindow.hpp"
#include "cadnext/gui/AnalysisResultWindow.hpp"

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

    // --open-structural-result lets another program (the Workbench) show a result where the part
    // lives. --screenshot grabs the window it opened and exits — documentation images and a
    // check of the real window without anyone at the keyboard.
    QCommandLineParser options;
    const QCommandLineOption openResult(QStringLiteral("open-structural-result"),
                                        QStringLiteral("Open a cadnext_structural result file (strength or modal)."), QStringLiteral("path"));
    const QCommandLineOption screenshot(QStringLiteral("screenshot"),
                                        QStringLiteral("Save the opened result window to a PNG and quit."), QStringLiteral("png"));
    options.addOptions({openResult, screenshot});
    options.process(app);

    window.resize(1440, 900);
    if (options.isSet(openResult)) {
        auto* result = cadnext::gui::AnalysisResultWindow::showResult(options.value(openResult), nullptr);
        if (result == nullptr) {
            return 2;
        }
        if (options.isSet(screenshot)) {
            const QString target = options.value(screenshot);
            QTimer::singleShot(1500, result, [result, target]() {
                const bool saved = result->snapshot().save(target);
                QApplication::exit(saved ? 0 : 3);
            });
        }
    } else {
        window.show();
    }

    return QApplication::exec();
}
