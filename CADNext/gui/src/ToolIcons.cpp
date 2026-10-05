#include "cadnext/gui/ToolIcons.hpp"

#include <QFont>
#include <QGuiApplication>
#include <QIconEngine>
#include <QImage>
#include <QPainter>
#include <QPainterPath>
#include <QPalette>
#include <QPixmapCache>

#include <cmath>
#include <initializer_list>

namespace cadnext::gui {

namespace {

// Every glyph is drawn on a 24×24 grid and scaled to the size asked for.
constexpr qreal kGrid = 24.0;
constexpr qreal kStroke = 1.5;
constexpr qreal kDisabledOpacity = 0.36;

struct Inks {
    QColor line;   // the geometry the tool works on
    QColor accent; // what the tool makes
    QColor add;    // creation
    QColor remove; // deletion and cutting
    QColor soft;   // construction lines, the shape before the operation
};

QColor tint(QColor color, qreal factor) {
    color.setAlphaF(color.alphaF() * factor);
    return color;
}

Inks inksFor(const QColor& ink, QIcon::Mode mode) {
    if (mode == QIcon::Disabled) {
        // One colour, faded as a whole afterwards: fading each stroke would darken every joint.
        return {ink, ink, ink, ink, tint(ink, 0.5)};
    }
    const bool darkTheme = ink.lightnessF() > 0.5;
    return {ink,
            darkTheme ? QColor(0x5b, 0xb0, 0xff) : QColor(0x19, 0x6f, 0xd2),
            darkTheme ? QColor(0x4c, 0xd9, 0x64) : QColor(0x1f, 0x9d, 0x45),
            darkTheme ? QColor(0xff, 0x6b, 0x5e) : QColor(0xd6, 0x36, 0x2b),
            tint(ink, 0.45)};
}

QPen pen(const QColor& color, qreal width = kStroke, Qt::PenStyle style = Qt::SolidLine) {
    QPen result(color, width, style);
    result.setCapStyle(Qt::RoundCap);
    result.setJoinStyle(Qt::RoundJoin);
    return result;
}

QPainterPath poly(std::initializer_list<QPointF> points, bool closed = true) {
    QPainterPath path;
    bool first = true;
    for (const QPointF& point : points) {
        if (first) {
            path.moveTo(point);
            first = false;
        } else {
            path.lineTo(point);
        }
    }
    if (closed) path.closeSubpath();
    return path;
}

void stroke(QPainter& p, const QPainterPath& path, const QColor& color, qreal width = kStroke,
            Qt::PenStyle style = Qt::SolidLine) {
    p.setBrush(Qt::NoBrush);
    p.setPen(pen(color, width, style));
    p.drawPath(path);
}

void fill(QPainter& p, const QPainterPath& path, const QColor& color) {
    p.setPen(Qt::NoPen);
    p.setBrush(color);
    p.drawPath(path);
}

void line(QPainter& p, QPointF from, QPointF to, const QColor& color, qreal width = kStroke,
          Qt::PenStyle style = Qt::SolidLine) {
    p.setPen(pen(color, width, style));
    p.drawLine(from, to);
}

void dot(QPainter& p, QPointF center, qreal radius, const QColor& color) {
    p.setPen(Qt::NoPen);
    p.setBrush(color);
    p.drawEllipse(center, radius, radius);
}

void ring(QPainter& p, QPointF center, qreal radius, const QColor& color, qreal width = kStroke) {
    p.setBrush(Qt::NoBrush);
    p.setPen(pen(color, width));
    p.drawEllipse(center, radius, radius);
}

// Clears what is already drawn under a shape, so the shape reads as lying on top.
void knockOut(QPainter& p, const QPainterPath& path, qreal margin) {
    p.save();
    p.setCompositionMode(QPainter::CompositionMode_Clear);
    p.setPen(pen(Qt::black, margin * 2.0));
    p.setBrush(Qt::black);
    p.drawPath(path);
    p.restore();
}

void arrowHead(QPainter& p, QPointF tip, QPointF direction, const QColor& color, qreal size = 3.0,
               qreal width = kStroke) {
    const qreal norm = std::hypot(direction.x(), direction.y());
    if (norm <= 0.0) return;
    const QPointF along = direction / norm;
    const QPointF across(-along.y(), along.x());
    const QPointF back = tip - along * size;
    stroke(p, poly({back + across * size * 0.62, tip, back - across * size * 0.62}, false), color, width);
}

void arrow(QPainter& p, QPointF from, QPointF to, const QColor& color, qreal width = kStroke,
           qreal head = 3.0) {
    line(p, from, to, color, width);
    arrowHead(p, to, to - from, color, head, width);
}

// Point of an ellipse at a Qt arc angle (degrees, counter-clockwise from three o'clock), and the
// direction a counter-clockwise arc travels there.
QPointF arcPoint(QPointF center, qreal rx, qreal ry, qreal degrees) {
    const qreal radians = degrees * M_PI / 180.0;
    return {center.x() + rx * std::cos(radians), center.y() - ry * std::sin(radians)};
}

QPointF arcDirection(qreal rx, qreal ry, qreal degrees) {
    const qreal radians = degrees * M_PI / 180.0;
    return {-rx * std::sin(radians), -ry * std::cos(radians)};
}

QPainterPath arc(QPointF center, qreal rx, qreal ry, qreal startDegrees, qreal sweepDegrees) {
    QPainterPath path;
    const QRectF box(center.x() - rx, center.y() - ry, rx * 2.0, ry * 2.0);
    path.arcMoveTo(box, startDegrees);
    path.arcTo(box, startDegrees, sweepDegrees);
    return path;
}

// A box seen from above its front corner: a is the far top corner, c the near one.
struct Box {
    QPointF a, b, c, d, e, f, g;

    QPainterPath top() const { return poly({a, b, c, d}); }
    QPainterPath left() const { return poly({d, c, e, g}); }
    QPainterPath right() const { return poly({c, b, f, e}); }
    QPainterPath outline() const { return poly({a, b, f, e, g, d}); }
    QPainterPath inner() const {
        QPainterPath path = poly({d, c, b}, false);
        path.moveTo(c);
        path.lineTo(e);
        return path;
    }
};

Box box(qreal centerX, qreal topY, qreal halfWidth, qreal height) {
    const qreal rise = halfWidth * 0.5;
    return {{centerX, topY},
            {centerX + halfWidth, topY + rise},
            {centerX, topY + rise * 2.0},
            {centerX - halfWidth, topY + rise},
            {centerX, topY + rise * 2.0 + height},
            {centerX + halfWidth, topY + rise + height},
            {centerX - halfWidth, topY + rise + height}};
}

void drawBox(QPainter& p, const Box& shape, const QColor& color, qreal width = kStroke) {
    stroke(p, shape.outline(), color, width);
    stroke(p, shape.inner(), color, width);
}

// The "new" mark in the top right corner.
void plusBadge(QPainter& p, const Inks& k) {
    const QPointF center(19.0, 5.0);
    QPainterPath disc;
    disc.addEllipse(center, 4.2, 4.2);
    knockOut(p, disc, 0.6);
    fill(p, disc, k.add);
    QPainterPath cross;
    cross.moveTo(center.x() - 2.1, center.y());
    cross.lineTo(center.x() + 2.1, center.y());
    cross.moveTo(center.x(), center.y() - 2.1);
    cross.lineTo(center.x(), center.y() + 2.1);
    p.save();
    p.setCompositionMode(QPainter::CompositionMode_Clear);
    p.setBrush(Qt::NoBrush);
    p.setPen(pen(Qt::black, 1.5));
    p.drawPath(cross);
    p.restore();
}

void pencil(QPainter& p, QPointF tip, QPointF direction, qreal length, const QColor& color) {
    const qreal norm = std::hypot(direction.x(), direction.y());
    const QPointF along = direction / norm;
    const QPointF across = QPointF(-along.y(), along.x()) * 1.7;
    const QPointF neck = tip + along * 3.6;
    const QPointF end = tip + along * length;
    const QPainterPath body = poly({tip, neck + across, end + across, end - across, neck - across});
    knockOut(p, body, 1.0);
    fill(p, body, tint(color, 0.25));
    stroke(p, body, color, 1.3);
    line(p, neck + across, neck - across, color, 1.3);
}

void label(QPainter& p, const QString& text, const QColor& color) {
    QFont font = QGuiApplication::font();
    font.setPixelSize(9);
    font.setBold(true);
    QPainterPath letters;
    letters.addText(QPointF(0.0, 0.0), font, text);
    const QRectF bounds = letters.boundingRect();
    letters.translate(23.2 - bounds.right(), 22.4 - bounds.bottom());
    knockOut(p, letters, 1.0);
    fill(p, letters, color);
}

void sketchPlane(QPainter& p, const Inks& k, int face, const QString& name) {
    const Box planes = box(8.0, 1.5, 6.5, 7.0);
    const QPainterPath chosen = face == 0 ? planes.top() : face == 1 ? planes.left() : planes.right();
    fill(p, chosen, tint(k.accent, 0.5));
    drawBox(p, planes, k.soft, 1.2);
    stroke(p, chosen, k.accent, 1.4);
    label(p, name, k.line);
}

void trashCan(QPainter& p, const Inks& k) {
    line(p, {4.5, 6.5}, {19.5, 6.5}, k.remove);
    stroke(p, poly({{9.5, 6.5}, {9.5, 4.0}, {14.5, 4.0}, {14.5, 6.5}}, false), k.remove);
    QPainterPath can;
    can.moveTo(6.3, 6.5);
    can.lineTo(7.2, 19.3);
    can.quadTo(7.3, 21.0, 9.0, 21.0);
    can.lineTo(15.0, 21.0);
    can.quadTo(16.7, 21.0, 16.8, 19.3);
    can.lineTo(17.7, 6.5);
    stroke(p, can, k.remove);
    line(p, {10.3, 10.0}, {10.3, 17.5}, k.remove, 1.3);
    line(p, {13.7, 10.0}, {13.7, 17.5}, k.remove, 1.3);
}

void solidWithPlus(QPainter& p, const Inks& k) {
    const Box shape = box(10.5, 5.5, 7.5, 8.0);
    fill(p, shape.top(), tint(k.accent, 0.25));
    drawBox(p, shape, k.line);
    plusBadge(p, k);
}

void cornerProfile(QPainter& p, const Inks& k, bool rounded) {
    QPainterPath body;
    QPainterPath edge;
    if (rounded) {
        const QRectF quarter(4.0, 4.5, 16.0, 16.0);
        body.moveTo(12.0, 4.5);
        body.arcTo(quarter, 90.0, -90.0);
        edge.moveTo(12.0, 4.5);
        edge.arcTo(quarter, 90.0, -90.0);
        stroke(p, poly({{12.0, 4.5}, {20.0, 4.5}, {20.0, 12.5}}, false), k.soft, 1.1, Qt::DotLine);
    } else {
        body.moveTo(12.5, 4.5);
        body.lineTo(20.0, 12.0);
        edge.moveTo(12.5, 4.5);
        edge.lineTo(20.0, 12.0);
        stroke(p, poly({{12.5, 4.5}, {20.0, 4.5}, {20.0, 12.0}}, false), k.soft, 1.1, Qt::DotLine);
    }
    const QPointF edgeStart = body.elementAt(0);
    const QPointF edgeEnd = body.currentPosition();
    body.lineTo(20.0, 20.5);
    body.lineTo(4.0, 20.5);
    body.lineTo(4.0, 4.5);
    body.closeSubpath();
    fill(p, body, tint(k.line, 0.1));
    stroke(p, poly({edgeEnd, {20.0, 20.5}, {4.0, 20.5}, {4.0, 4.5}, edgeStart}, false), k.line);
    stroke(p, edge, k.accent, 2.2);
}

void drawGlyph(QPainter& p, ToolIcon icon, const Inks& k) {
    switch (icon) {
    case ToolIcon::AddBox:
    case ToolIcon::InsertPart:
        solidWithPlus(p, k);
        break;

    case ToolIcon::AddCylinder: {
        const QPointF top(9.5, 8.3);
        const qreal rx = 6.0, ry = 2.4, height = 10.0;
        QPainterPath side;
        side.moveTo(top.x() - rx, top.y());
        side.lineTo(top.x() - rx, top.y() + height);
        side.arcTo(QRectF(top.x() - rx, top.y() + height - ry, rx * 2.0, ry * 2.0), 180.0, 180.0);
        side.lineTo(top.x() + rx, top.y());
        QPainterPath lid;
        lid.addEllipse(top, rx, ry);
        fill(p, lid, tint(k.accent, 0.25));
        stroke(p, side, k.line);
        stroke(p, lid, k.line);
        plusBadge(p, k);
        break;
    }

    case ToolIcon::AddSphere: {
        const QPointF center(10.5, 13.5);
        const qreal radius = 7.5;
        QPainterPath ball;
        ball.addEllipse(center, radius, radius);
        fill(p, ball, tint(k.accent, 0.16));
        stroke(p, arc(center, radius, 2.7, 0.0, 180.0), k.soft, 1.1);
        stroke(p, arc(center, radius, 2.7, 180.0, 180.0), k.line, 1.2);
        stroke(p, ball, k.line);
        plusBadge(p, k);
        break;
    }

    case ToolIcon::AddPlane: {
        const QPainterPath plane = poly({{1.5, 19.5}, {7.0, 10.5}, {18.5, 10.5}, {13.0, 19.5}});
        fill(p, plane, tint(k.accent, 0.25));
        stroke(p, plane, k.line);
        plusBadge(p, k);
        break;
    }

    case ToolIcon::Extrude: {
        const Box shape = box(12.0, 8.5, 7.0, 5.5);
        fill(p, shape.top(), tint(k.accent, 0.3));
        drawBox(p, shape, k.line);
        arrow(p, {12.0, 12.0}, {12.0, 2.2}, k.accent, 1.9, 3.2);
        break;
    }

    case ToolIcon::Revolve: {
        const QPainterPath profile = poly({{12.0, 3.5}, {16.0, 3.5}, {19.5, 7.5}, {19.5, 14.0}, {12.0, 14.0}});
        fill(p, profile, tint(k.accent, 0.28));
        stroke(p, poly({{12.0, 3.5}, {8.0, 3.5}, {4.5, 7.5}, {4.5, 14.0}, {12.0, 14.0}}, false), k.soft, 1.2);
        stroke(p, profile, k.accent);
        line(p, {12.0, 1.3}, {12.0, 16.2}, k.line, 1.2, Qt::DashLine);
        const QPointF turn(12.0, 18.8);
        stroke(p, arc(turn, 8.0, 2.8, 165.0, 225.0), k.line);
        arrowHead(p, arcPoint(turn, 8.0, 2.8, 30.0), arcDirection(8.0, 2.8, 30.0), k.line, 2.8);
        break;
    }

    case ToolIcon::CutExtrude: {
        const Box shape = box(12.0, 8.0, 8.0, 5.5);
        drawBox(p, shape, k.line);
        const QPainterPath pocket = poly({{12.0, 10.1}, {15.8, 12.0}, {12.0, 13.9}, {8.2, 12.0}});
        knockOut(p, pocket, 0.4);
        fill(p, pocket, tint(k.remove, 0.4));
        stroke(p, pocket, k.remove, 1.3);
        arrow(p, {12.0, 1.6}, {12.0, 10.6}, k.remove, 1.9, 3.2);
        break;
    }

    case ToolIcon::Chamfer:
        cornerProfile(p, k, false);
        break;

    case ToolIcon::Fillet:
        cornerProfile(p, k, true);
        break;

    case ToolIcon::Thread: {
        QPainterPath head;
        head.addRoundedRect(QRectF(5.5, 2.5, 13.0, 5.0), 1.3, 1.3);
        fill(p, head, tint(k.line, 0.14));
        stroke(p, head, k.line);
        stroke(p, poly({{9.0, 7.5}, {9.0, 19.3}, {12.0, 22.0}, {15.0, 19.3}, {15.0, 7.5}}, false), k.line);
        for (const qreal y : {10.6, 13.8, 17.0}) {
            line(p, {8.0, y + 1.1}, {16.0, y - 1.1}, k.accent, 1.7);
        }
        break;
    }

    case ToolIcon::SketchOnFace: {
        const Box shape = box(10.5, 7.5, 8.0, 6.5);
        fill(p, shape.top(), tint(k.accent, 0.3));
        drawBox(p, shape, k.line);
        pencil(p, {10.5, 11.6}, {1.0, -1.0}, 13.0, k.accent);
        break;
    }

    case ToolIcon::WorkPlaneFromFace: {
        // The plane of the box's right face, carried past the face on every side.
        const Box shape = box(10.0, 6.5, 6.0, 6.0);
        drawBox(p, shape, k.line);
        const QPointF reach = (shape.b - shape.c) * 0.45;
        const QPointF lift(0.0, 2.2);
        const QPainterPath plane = poly({shape.c - reach - lift, shape.b + reach - lift,
                                         shape.f + reach + lift, shape.e - reach + lift});
        fill(p, plane, tint(k.accent, 0.32));
        stroke(p, plane, k.accent);
        break;
    }

    case ToolIcon::NormalToFace: {
        const QPainterPath plane = poly({{2.5, 21.0}, {7.5, 14.0}, {21.5, 14.0}, {16.5, 21.0}});
        fill(p, plane, tint(k.accent, 0.22));
        stroke(p, plane, k.line);
        QPainterPath eye;
        eye.moveTo(6.5, 5.5);
        eye.quadTo(12.0, 0.8, 17.5, 5.5);
        eye.quadTo(12.0, 10.2, 6.5, 5.5);
        stroke(p, eye, k.accent);
        dot(p, {12.0, 5.5}, 1.6, k.accent);
        arrow(p, {12.0, 10.6}, {12.0, 17.6}, k.accent, 1.5, 2.6);
        break;
    }

    case ToolIcon::AttachmentPoint: {
        stroke(p, poly({{2.0, 21.5}, {6.5, 15.5}, {22.0, 15.5}, {17.5, 21.5}}), k.line);
        const QPointF head(12.0, 7.3);
        const qreal radius = 4.7;
        const QPointF tip(12.0, 18.6);
        QPainterPath pin;
        pin.moveTo(tip);
        pin.lineTo(arcPoint(head, radius, radius, 205.0));
        pin.arcTo(QRectF(head.x() - radius, head.y() - radius, radius * 2.0, radius * 2.0), 205.0, -230.0);
        pin.closeSubpath();
        knockOut(p, pin, 1.1);
        fill(p, pin, k.accent);
        QPainterPath eye;
        eye.addEllipse(head, 1.8, 1.8);
        knockOut(p, eye, 0.0);
        break;
    }

    case ToolIcon::Delete:
        trashCan(p, k);
        break;

    case ToolIcon::FitSelection: {
        const QRectF selection(6.9, 6.9, 6.2, 6.2);
        p.setPen(pen(k.accent, 1.3));
        p.setBrush(tint(k.accent, 0.35));
        p.drawRect(selection);
        ring(p, {10.0, 10.0}, 6.8, k.line);
        line(p, {15.2, 15.2}, {20.8, 20.8}, k.line, 2.6);
        break;
    }

    case ToolIcon::FitView: {
        stroke(p, poly({{3.0, 8.0}, {3.0, 3.0}, {8.0, 3.0}}, false), k.line);
        stroke(p, poly({{16.0, 3.0}, {21.0, 3.0}, {21.0, 8.0}}, false), k.line);
        stroke(p, poly({{21.0, 16.0}, {21.0, 21.0}, {16.0, 21.0}}, false), k.line);
        stroke(p, poly({{8.0, 21.0}, {3.0, 21.0}, {3.0, 16.0}}, false), k.line);
        const Box shape = box(12.0, 7.0, 5.0, 4.5);
        fill(p, shape.outline(), tint(k.accent, 0.25));
        drawBox(p, shape, k.accent, 1.3);
        break;
    }

    case ToolIcon::ResetCamera: {
        stroke(p, poly({{5.5, 10.5}, {5.5, 20.5}, {18.5, 20.5}, {18.5, 10.5}}, false), k.line);
        stroke(p, poly({{2.6, 11.9}, {12.0, 3.5}, {21.4, 11.9}}, false), k.line);
        const QPainterPath door = poly({{10.0, 20.5}, {10.0, 14.5}, {14.0, 14.5}, {14.0, 20.5}}, false);
        fill(p, door, tint(k.accent, 0.3));
        stroke(p, door, k.accent);
        break;
    }

    case ToolIcon::SketchXY:
        sketchPlane(p, k, 0, QStringLiteral("XY"));
        break;

    case ToolIcon::SketchXZ:
        sketchPlane(p, k, 1, QStringLiteral("XZ"));
        break;

    case ToolIcon::SketchYZ:
        sketchPlane(p, k, 2, QStringLiteral("YZ"));
        break;

    case ToolIcon::CreateSketch: {
        const QPainterPath plane = poly({{1.5, 20.5}, {7.5, 12.0}, {22.0, 12.0}, {16.0, 20.5}});
        fill(p, plane, tint(k.accent, 0.22));
        stroke(p, plane, k.line);
        pencil(p, {9.5, 16.8}, {1.0, -1.0}, 14.5, k.accent);
        break;
    }

    case ToolIcon::EnterSketch:
        stroke(p, poly({{12.5, 3.5}, {20.5, 3.5}, {20.5, 20.5}, {12.5, 20.5}}, false), k.line);
        arrow(p, {2.5, 12.0}, {14.5, 12.0}, k.accent, 1.9, 3.4);
        break;

    case ToolIcon::ExitSketch:
        stroke(p, poly({{11.5, 3.5}, {3.5, 3.5}, {3.5, 20.5}, {11.5, 20.5}}, false), k.line);
        arrow(p, {9.0, 12.0}, {21.5, 12.0}, k.accent, 1.9, 3.4);
        break;

    case ToolIcon::SelectTool: {
        const QPainterPath cursor = poly({{6.0, 2.8}, {6.0, 19.2}, {10.1, 15.4}, {12.9, 21.6},
                                          {15.6, 20.4}, {12.8, 14.3}, {18.4, 14.3}});
        fill(p, cursor, tint(k.line, 0.18));
        stroke(p, cursor, k.line);
        break;
    }

    case ToolIcon::LineTool:
        line(p, {5.0, 19.0}, {19.0, 5.0}, k.line, 1.7);
        dot(p, {5.0, 19.0}, 2.5, k.accent);
        dot(p, {19.0, 5.0}, 2.5, k.accent);
        break;

    case ToolIcon::RectangleTool:
        p.setBrush(Qt::NoBrush);
        p.setPen(pen(k.line, 1.7));
        p.drawRect(QRectF(4.5, 6.5, 15.0, 11.0));
        dot(p, {4.5, 6.5}, 2.4, k.accent);
        dot(p, {19.5, 17.5}, 2.4, k.accent);
        break;

    case ToolIcon::CircleTool: {
        const QPointF center(12.0, 12.0);
        const QPointF rim = arcPoint(center, 8.3, 8.3, 40.0);
        ring(p, center, 8.3, k.line, 1.7);
        line(p, center, rim, k.soft, 1.2);
        dot(p, center, 2.0, k.accent);
        dot(p, rim, 2.4, k.accent);
        break;
    }

    case ToolIcon::SnapGrid: {
        QPainterPath magnet;
        magnet.moveTo(4.5, 16.5);
        magnet.lineTo(4.5, 10.0);
        magnet.arcTo(QRectF(4.5, 2.5, 15.0, 15.0), 180.0, -180.0);
        magnet.lineTo(19.5, 16.5);
        magnet.lineTo(15.3, 16.5);
        magnet.lineTo(15.3, 10.0);
        magnet.arcTo(QRectF(8.7, 6.7, 6.6, 6.6), 0.0, 180.0);
        magnet.lineTo(8.7, 16.5);
        magnet.closeSubpath();
        fill(p, QPainterPath(poly({{4.5, 13.0}, {8.7, 13.0}, {8.7, 16.5}, {4.5, 16.5}})), k.accent);
        fill(p, QPainterPath(poly({{15.3, 13.0}, {19.5, 13.0}, {19.5, 16.5}, {15.3, 16.5}})), k.accent);
        stroke(p, magnet, k.line);
        dot(p, {12.0, 20.8}, 1.7, k.accent);
        break;
    }

    case ToolIcon::ShowGrid: {
        QPainterPath frame;
        frame.addRoundedRect(QRectF(3.0, 3.0, 18.0, 18.0), 2.0, 2.0);
        stroke(p, frame, k.line);
        for (const qreal at : {9.0, 15.0}) {
            line(p, {at, 3.0}, {at, 21.0}, k.line, 1.2);
            line(p, {3.0, at}, {21.0, at}, k.line, 1.2);
        }
        break;
    }

    case ToolIcon::Aerodynamics: {
        QPainterPath wing;
        wing.moveTo(3.5, 13.8);
        wing.cubicTo(5.5, 9.0, 13.0, 9.8, 21.0, 14.6);
        wing.cubicTo(14.0, 15.6, 6.5, 16.6, 3.5, 13.8);
        fill(p, wing, tint(k.line, 0.16));
        stroke(p, wing, k.line);
        QPainterPath over;
        over.moveTo(1.5, 7.8);
        over.cubicTo(6.0, 4.6, 13.0, 4.6, 21.5, 8.6);
        stroke(p, over, k.accent, 1.4);
        arrowHead(p, {21.5, 8.6}, {2.0, 1.0}, k.accent, 2.4, 1.4);
        line(p, {1.5, 3.2}, {21.5, 3.2}, k.accent, 1.4);
        arrowHead(p, {21.5, 3.2}, {1.0, 0.0}, k.accent, 2.4, 1.4);
        QPainterPath under;
        under.moveTo(1.5, 19.6);
        under.cubicTo(8.0, 20.4, 15.0, 20.0, 21.5, 18.8);
        stroke(p, under, k.accent, 1.4);
        arrowHead(p, {21.5, 18.8}, {5.0, -1.0}, k.accent, 2.4, 1.4);
        break;
    }

    case ToolIcon::Structural: {
        for (const qreal y : {5.0, 9.0, 13.0, 17.0}) {
            line(p, {4.5, y}, {1.8, y + 2.6}, k.soft, 1.1);
        }
        line(p, {4.5, 3.0}, {4.5, 21.0}, k.line, 1.8);
        QPainterPath beam;
        beam.moveTo(4.5, 9.0);
        beam.quadTo(14.0, 9.0, 21.5, 13.5);
        beam.lineTo(20.0, 17.6);
        beam.quadTo(13.0, 13.6, 4.5, 13.6);
        fill(p, beam, tint(k.accent, 0.3));
        stroke(p, beam, k.line);
        arrow(p, {20.4, 2.5}, {20.4, 10.8}, k.remove, 1.9, 3.0);
        break;
    }

    case ToolIcon::NewDocument: {
        const QPainterPath sheet = poly({{3.5, 4.0}, {11.0, 4.0}, {15.5, 8.5}, {15.5, 21.5}, {3.5, 21.5}});
        fill(p, sheet, tint(k.line, 0.1));
        stroke(p, sheet, k.line);
        stroke(p, poly({{11.0, 4.0}, {11.0, 8.5}, {15.5, 8.5}}, false), k.line, 1.2);
        plusBadge(p, k);
        break;
    }

    case ToolIcon::OpenDocument: {
        stroke(p, poly({{3.0, 19.5}, {2.5, 5.5}, {9.0, 5.5}, {11.0, 8.0}, {19.0, 8.0}, {19.0, 11.0}}, false), k.line);
        const QPainterPath flap = poly({{3.0, 19.5}, {6.0, 11.0}, {22.0, 11.0}, {19.0, 19.5}});
        fill(p, flap, tint(k.accent, 0.28));
        stroke(p, flap, k.line);
        break;
    }

    case ToolIcon::SaveDocument: {
        const QPainterPath disk = poly({{3.5, 3.5}, {16.5, 3.5}, {20.5, 7.5}, {20.5, 20.5}, {3.5, 20.5}});
        stroke(p, disk, k.line);
        stroke(p, poly({{7.5, 3.5}, {7.5, 8.5}, {15.0, 8.5}, {15.0, 3.5}}, false), k.line, 1.3);
        const QPainterPath sticker = poly({{7.0, 20.5}, {7.0, 13.5}, {17.0, 13.5}, {17.0, 20.5}}, false);
        fill(p, sticker, tint(k.accent, 0.3));
        stroke(p, sticker, k.accent, 1.3);
        break;
    }

    case ToolIcon::Ground: {
        ring(p, {12.0, 4.7}, 2.2, k.line);
        line(p, {12.0, 6.9}, {12.0, 20.6}, k.line);
        line(p, {8.0, 10.6}, {16.0, 10.6}, k.line);
        QPainterPath arms;
        arms.moveTo(4.2, 13.6);
        arms.cubicTo(4.6, 18.6, 8.6, 20.6, 12.0, 20.6);
        arms.cubicTo(15.4, 20.6, 19.4, 18.6, 19.8, 13.6);
        stroke(p, arms, k.line);
        stroke(p, poly({{2.4, 16.0}, {4.2, 13.4}, {6.8, 15.2}}, false), k.line);
        stroke(p, poly({{17.2, 15.2}, {19.8, 13.4}, {21.6, 16.0}}, false), k.line);
        break;
    }

    case ToolIcon::Move: {
        const QPointF center(12.0, 12.0);
        for (const QPointF& end : {QPointF(12.0, 2.3), QPointF(12.0, 21.7), QPointF(2.3, 12.0), QPointF(21.7, 12.0)}) {
            arrow(p, center, end, k.line, kStroke, 2.8);
        }
        break;
    }

    case ToolIcon::JointCoincident: {
        const QRectF first(2.5, 4.0, 9.5, 11.0);
        const QRectF second(12.0, 9.0, 9.5, 11.0);
        p.setPen(pen(k.line));
        p.setBrush(tint(k.line, 0.12));
        p.drawRect(first);
        p.drawRect(second);
        line(p, {12.0, 9.0}, {12.0, 15.0}, k.accent, 2.6);
        break;
    }

    case ToolIcon::JointParallel:
        line(p, {4.5, 20.0}, {11.5, 4.0}, k.accent, 2.0);
        line(p, {12.5, 20.0}, {19.5, 4.0}, k.accent, 2.0);
        break;

    case ToolIcon::JointPerpendicular:
        stroke(p, poly({{12.0, 15.5}, {16.0, 15.5}, {16.0, 19.5}}, false), k.line, 1.2);
        line(p, {3.5, 19.5}, {20.5, 19.5}, k.accent, 2.0);
        line(p, {12.0, 19.5}, {12.0, 4.0}, k.accent, 2.0);
        break;

    case ToolIcon::JointConcentric:
        ring(p, {12.0, 12.0}, 8.6, k.line);
        ring(p, {12.0, 12.0}, 4.4, k.accent, 1.8);
        dot(p, {12.0, 12.0}, 1.3, k.accent);
        break;

    case ToolIcon::JointDistance:
        line(p, {4.0, 4.5}, {4.0, 19.5}, k.line, 1.7);
        line(p, {20.0, 4.5}, {20.0, 19.5}, k.line, 1.7);
        arrow(p, {12.0, 12.0}, {6.3, 12.0}, k.accent, kStroke, 2.6);
        arrow(p, {12.0, 12.0}, {17.7, 12.0}, k.accent, kStroke, 2.6);
        break;

    case ToolIcon::JointAngle:
        stroke(p, poly({{15.5, 4.5}, {3.5, 19.5}, {21.0, 19.5}}, false), k.line, 1.7);
        stroke(p, arc({3.5, 19.5}, 10.5, 10.5, 0.0, 51.3), k.accent, 1.8);
        break;

    case ToolIcon::JointRigid: {
        QPainterPath shackle;
        shackle.moveTo(8.0, 10.5);
        shackle.lineTo(8.0, 8.0);
        shackle.arcTo(QRectF(8.0, 4.0, 8.0, 8.0), 180.0, -180.0);
        shackle.lineTo(16.0, 10.5);
        stroke(p, shackle, k.line);
        QPainterPath body;
        body.addRoundedRect(QRectF(5.0, 10.5, 14.0, 10.0), 2.0, 2.0);
        fill(p, body, tint(k.line, 0.14));
        stroke(p, body, k.line);
        dot(p, {12.0, 14.6}, 1.5, k.accent);
        line(p, {12.0, 15.0}, {12.0, 17.6}, k.accent, 1.5);
        break;
    }

    case ToolIcon::Recompute: {
        const QPointF center(12.0, 12.0);
        const qreal radius = 7.8;
        for (const qreal start : {35.0, 215.0}) {
            stroke(p, arc(center, radius, radius, start, 135.0), k.accent, 1.8);
            arrowHead(p, arcPoint(center, radius, radius, start + 135.0),
                      arcDirection(radius, radius, start + 135.0), k.accent, 3.0, 1.8);
        }
        break;
    }

    case ToolIcon::Count:
        break;
    }
}

QPixmap renderGlyph(ToolIcon icon, int side, qreal devicePixelRatio, const QColor& ink, QIcon::Mode mode) {
    const int pixels = qMax(1, qRound(side * devicePixelRatio));
    QImage glyph(pixels, pixels, QImage::Format_ARGB32_Premultiplied);
    glyph.fill(Qt::transparent);
    {
        QPainter painter(&glyph);
        painter.setRenderHint(QPainter::Antialiasing);
        painter.scale(pixels / kGrid, pixels / kGrid);
        drawGlyph(painter, icon, inksFor(ink, mode));
    }
    if (mode == QIcon::Disabled) {
        QImage faded(glyph.size(), QImage::Format_ARGB32_Premultiplied);
        faded.fill(Qt::transparent);
        QPainter painter(&faded);
        painter.setOpacity(kDisabledOpacity);
        painter.drawImage(0, 0, glyph);
        painter.end();
        glyph = faded;
    }
    QPixmap pixmap = QPixmap::fromImage(glyph);
    pixmap.setDevicePixelRatio(devicePixelRatio);
    return pixmap;
}

// The palette's text colour, pulled a little towards the window: full-contrast lines of this
// weight glare next to the system's own toolbar symbols.
QColor paletteInk() {
    const QPalette palette = QGuiApplication::palette();
    const QColor text = palette.color(QPalette::Active, QPalette::WindowText);
    const QColor window = palette.color(QPalette::Active, QPalette::Window);
    const qreal keep = 0.86;
    return QColor::fromRgbF(text.redF() * keep + window.redF() * (1.0 - keep),
                            text.greenF() * keep + window.greenF() * (1.0 - keep),
                            text.blueF() * keep + window.blueF() * (1.0 - keep));
}

class ToolIconEngine final : public QIconEngine {
public:
    explicit ToolIconEngine(ToolIcon icon) : icon_(icon) {}

    void paint(QPainter* painter, const QRect& rect, QIcon::Mode mode, QIcon::State) override {
        const qreal ratio = painter->device() != nullptr ? painter->device()->devicePixelRatioF() : 1.0;
        const int side = qMin(rect.width(), rect.height());
        const QRect target(rect.x() + (rect.width() - side) / 2, rect.y() + (rect.height() - side) / 2, side, side);
        painter->drawPixmap(target, glyph(side, ratio, mode));
    }

    QPixmap pixmap(const QSize& size, QIcon::Mode mode, QIcon::State) override {
        return glyph(qMin(size.width(), size.height()), 1.0, mode);
    }

    QPixmap scaledPixmap(const QSize& size, QIcon::Mode mode, QIcon::State, qreal scale) override {
        return glyph(qMin(size.width(), size.height()), scale, mode);
    }

    QIconEngine* clone() const override { return new ToolIconEngine(icon_); }

private:
    QPixmap glyph(int side, qreal ratio, QIcon::Mode mode) const {
        const QColor ink = paletteInk();
        const QString key = QStringLiteral("cadnext-tool-icon/%1/%2/%3/%4/%5")
                                .arg(static_cast<int>(icon_))
                                .arg(side)
                                .arg(ratio)
                                .arg(static_cast<int>(mode))
                                .arg(ink.rgba(), 8, 16, QLatin1Char('0'));
        QPixmap cached;
        if (!QPixmapCache::find(key, &cached)) {
            cached = renderGlyph(icon_, side, ratio, ink, mode);
            QPixmapCache::insert(key, cached);
        }
        return cached;
    }

    ToolIcon icon_;
};

} // namespace

QIcon toolIcon(ToolIcon icon) {
    return QIcon(new ToolIconEngine(icon));
}

QPixmap toolIconPixmap(ToolIcon icon, int side, qreal devicePixelRatio, const QColor& ink,
                       QIcon::Mode mode) {
    return renderGlyph(icon, side, devicePixelRatio, ink, mode);
}

} // namespace cadnext::gui
