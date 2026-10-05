// The toolbar glyphs and the toolbars that carry them.
//
// Criteria, fixed before the first run:
//   - Every glyph draws something, in a dark and in a light theme, and stays inside its square (a
//     stroke reaching the border is a glyph cut off by it).
//   - No two glyphs are the same picture, except «insert part», which is the «add box» one on purpose.
//   - A disabled glyph is fainter than the enabled one.
//   - The part window's two toolbars and the assembly window's one show glyphs only, and every
//     action there has a glyph and a tooltip to say what the glyph means.
//
//   cadnext_test_gui_tool_icons [sheet.png [side]]
#include "cadnext/gui/AssemblyWindow.hpp"
#include "cadnext/gui/SketchToolBar.hpp"
#include "cadnext/gui/ToolBar.hpp"
#include "cadnext/gui/ToolIcons.hpp"

#include <QAction>
#include <QApplication>
#include <QImage>
#include <QPainter>

#include <cstdio>
#include <string>
#include <vector>

using namespace cadnext::gui;

namespace {

int failures = 0;

void check(bool condition, const std::string& what) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", what.c_str());
    if (!condition) ++failures;
}

const QColor kLightInk(0xe4, 0xe4, 0xe6);
const QColor kDarkInk(0x26, 0x26, 0x28);
const int kIconCount = static_cast<int>(ToolIcon::Count);

QImage glyph(int index, const QColor& ink, QIcon::Mode mode = QIcon::Normal, int side = kToolIconSize) {
    return toolIconPixmap(static_cast<ToolIcon>(index), side, 2.0, ink, mode).toImage();
}

qint64 coverage(const QImage& image) {
    qint64 total = 0;
    for (int y = 0; y < image.height(); ++y)
        for (int x = 0; x < image.width(); ++x) total += qAlpha(image.pixel(x, y));
    return total;
}

bool touchesBorder(const QImage& image) {
    const int w = image.width(), h = image.height();
    for (int x = 0; x < w; ++x)
        if (qAlpha(image.pixel(x, 0)) > 0 || qAlpha(image.pixel(x, h - 1)) > 0) return true;
    for (int y = 0; y < h; ++y)
        if (qAlpha(image.pixel(0, y)) > 0 || qAlpha(image.pixel(w - 1, y)) > 0) return true;
    return false;
}

void checkToolBar(QToolBar& bar, const char* name) {
    check(bar.toolButtonStyle() == Qt::ToolButtonIconOnly, std::string(name) + ": glyphs only");
    int actions = 0, bare = 0;
    for (QAction* action : bar.actions()) {
        if (action->isSeparator() || bar.widgetForAction(action) == nullptr || action->text().isEmpty()) continue;
        ++actions;
        if (action->icon().isNull() || action->toolTip().isEmpty()) ++bare;
    }
    check(actions > 0 && bare == 0,
          std::string(name) + ": " + std::to_string(actions) + " actions, each with a glyph and a tooltip");
}

// Every glyph on a dark and on a light strip, enabled over disabled.
QImage sheet(int side) {
    const int columns = 12, cell = side * 2 + 24;
    const int rows = (kIconCount + columns - 1) / columns;
    QImage image(columns * cell, rows * cell * 4, QImage::Format_ARGB32_Premultiplied);
    QPainter painter(&image);
    for (int theme = 0; theme < 2; ++theme) {
        const QColor ink = theme == 0 ? kLightInk : kDarkInk;
        const int top = theme * rows * cell * 2;
        painter.fillRect(0, top, image.width(), rows * cell * 2, theme == 0 ? QColor(0x2c, 0x2c, 0x2e) : QColor(0xec, 0xec, 0xec));
        for (int index = 0; index < kIconCount; ++index) {
            for (int disabled = 0; disabled < 2; ++disabled) {
                QImage picture = glyph(index, ink, disabled ? QIcon::Disabled : QIcon::Normal, side);
                picture.setDevicePixelRatio(1.0);
                painter.drawImage((index % columns) * cell + 12, top + (disabled * rows + index / columns) * cell + 12, picture);
            }
        }
    }
    return image;
}

} // namespace

int main(int argc, char** argv) {
    QApplication app(argc, argv);

    int empty = 0, clipped = 0, notFainter = 0, repeated = 0;
    std::vector<QImage> pictures;
    for (int index = 0; index < kIconCount; ++index) {
        const QImage onDark = glyph(index, kLightInk);
        const QImage onLight = glyph(index, kDarkInk);
        if (coverage(onDark) == 0 || coverage(onLight) == 0) ++empty;
        if (touchesBorder(onDark)) {
            ++clipped;
            std::printf("  glyph %d reaches the border\n", index);
        }
        if (coverage(glyph(index, kLightInk, QIcon::Disabled)) >= coverage(onDark)) ++notFainter;
        for (int earlier = 0; earlier < index; ++earlier) {
            const bool alias = static_cast<ToolIcon>(index) == ToolIcon::InsertPart
                               && static_cast<ToolIcon>(earlier) == ToolIcon::AddBox;
            if (!alias && pictures[earlier] == onDark) {
                ++repeated;
                std::printf("  glyph %d repeats glyph %d\n", index, earlier);
            }
        }
        pictures.push_back(onDark);
    }
    check(empty == 0, "every glyph draws in both themes");
    check(clipped == 0, "no glyph is cut off by its square");
    check(repeated == 0, "no two glyphs are the same picture");
    check(notFainter == 0, "a disabled glyph is fainter than the enabled one");
    check(glyph(0, kLightInk).size() == QSize(kToolIconSize * 2, kToolIconSize * 2), "a glyph at 2x has twice the pixels");

    ToolBar toolBar;
    SketchToolBar sketchToolBar;
    checkToolBar(toolBar, "main toolbar");
    checkToolBar(sketchToolBar, "sketch toolbar");
    AssemblyWindow assembly;
    auto* assemblyToolBar = assembly.findChild<QToolBar*>(QStringLiteral("assemblyToolBar"));
    check(assemblyToolBar != nullptr, "the assembly window has its toolbar");
    if (assemblyToolBar != nullptr) checkToolBar(*assemblyToolBar, "assembly toolbar");
    check(!toolBar.extrudeAction()->icon().pixmap(QSize(kToolIconSize, kToolIconSize), 2.0, QIcon::Disabled).isNull(),
          "the icon answers for the disabled mode a button asks for");

    if (argc > 1) {
        const int side = argc > 2 ? std::atoi(argv[2]) : kToolIconSize;
        check(sheet(side).save(QString::fromLocal8Bit(argv[1])), "glyph sheet saved");
    }

    std::printf("%s\n", failures == 0 ? "cadnext_test_gui_tool_icons: OK" : "cadnext_test_gui_tool_icons: FAILED");
    return failures == 0 ? 0 : 1;
}
