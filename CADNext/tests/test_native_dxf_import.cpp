#include "cadnext/gui/NativeDxfImport.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/WorkPlane.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QCoreApplication>
#include <QFile>
#include <QTemporaryDir>

#include <cassert>
#include <bit>
#include <cmath>

namespace {
QString writeDxf(const QTemporaryDir& directory, const QByteArray& bytes) {
    const QString path = directory.filePath(QStringLiteral("sample.dxf"));
    QFile file(path);
    assert(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    assert(file.write(bytes) == bytes.size());
    return path;
}
}

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    QTemporaryDir directory;
    assert(directory.isValid());
    const QByteArray valid = R"(0
SECTION
2
HEADER
9
$INSUNITS
70
1
0
ENDSEC
0
SECTION
2
ENTITIES
0
LINE
10
0
20
0
11
1
21
0
0
CIRCLE
10
1
20
2
40
0.5
0
LWPOLYLINE
90
4
70
1
10
0
20
0
10
1
20
0
10
1
20
1
10
0
20
1
0
ENDSEC
0
EOF
)";
    const QString path = writeDxf(directory, valid);
    cadnext::gui::DxfSketchData data;
    QString error;
    assert(cadnext::gui::readDxfSketch(path, data, error));
    assert(data.entities.size() == 6);
    assert(data.drawingUnits == 1);
    assert(!data.assumedMillimeters);
    assert(std::fabs(data.entities[0].line.end.u - 0.0254) < 1e-12);
    assert(std::fabs(data.entities[1].circle.radius - 0.0127) < 1e-12);

    QByteArray surveyFeet = valid;
    surveyFeet.replace("$INSUNITS\n70\n1\n", "$INSUNITS\n70\n21\n");
    writeDxf(directory, surveyFeet);
    cadnext::gui::DxfSketchData surveyData;
    assert(cadnext::gui::readDxfSketch(path, surveyData, error));
    assert(std::fabs(surveyData.entities[0].line.end.u - 1200.0 / 3937.0) < 1e-12);

    cadnext::Sketch sketch;
    sketch.id = "imported";
    sketch.entities.assign(data.entities.begin() + 2, data.entities.end());
    for (std::size_t i = 0; i < sketch.entities.size(); ++i)
        sketch.entities[i].id = "edge-" + std::to_string(i);
    const auto profiles = cadnext::SketchProfileDetector().detect(sketch);
    assert(profiles.size() == 1);
    assert(profiles[0].isValid && profiles[0].isClosed);
    assert(std::fabs(profiles[0].area - 0.0254 * 0.0254) < 1e-12);

    const QString exportedPath = directory.filePath(QStringLiteral("exported.dxf"));
    cadnext::Sketch exported;
    exported.entities = data.entities;
    assert(cadnext::gui::writeDxfSketch(exportedPath, exported, error));
    cadnext::gui::DxfSketchData roundtrip;
    assert(cadnext::gui::readDxfSketch(exportedPath, roundtrip, error));
    assert(roundtrip.entities.size() == data.entities.size());
    assert(roundtrip.drawingUnits == 4);
    assert(std::fabs(roundtrip.entities[1].circle.radius - 0.0127) < 1e-12);

    const QString binaryPath = directory.filePath(QStringLiteral("exported-binary.dxf"));
    assert(cadnext::gui::writeDxfSketch(binaryPath, exported, error, true));
    QFile binaryFile(binaryPath);
    assert(binaryFile.open(QIODevice::ReadOnly));
    const QByteArray binaryExport = binaryFile.readAll();
    binaryFile.close();
    assert(binaryExport.startsWith(QByteArray("AutoCAD Binary DXF\r\n\x1a\0", 22)));
    assert(cadnext::gui::readDxfSketch(binaryPath, roundtrip, error));
    assert(roundtrip.entities.size() == data.entities.size());
    assert(std::fabs(roundtrip.entities[1].circle.radius - 0.0127) < 1e-12);

    QByteArray independentBinary("AutoCAD Binary DXF\r\n\x1a\0", 22);
    const auto integer = [&independentBinary](quint64 value, int width) {
        for (int i = 0; i < width; ++i)
            independentBinary.append(char((value >> (8 * i)) & 255));
    };
    const auto string = [&](int code, const char* value) {
        integer(code, 2);
        independentBinary.append(value);
        independentBinary.append('\0');
    };
    const auto number = [&](int code, double value) {
        integer(code, 2);
        integer(std::bit_cast<quint64>(value), 8);
    };
    string(0, "SECTION"); string(2, "ENTITIES"); string(0, "LINE");
    number(10, 1.25); number(20, 2.5); number(11, 3.75); number(21, 4.5);
    string(0, "ENDSEC"); string(0, "EOF");
    writeDxf(directory, independentBinary);
    assert(cadnext::gui::readDxfSketch(path, roundtrip, error));
    assert(roundtrip.entities.size() == 1);
    assert(std::fabs(roundtrip.entities[0].line.start.u - 0.00125) < 1e-12);
    assert(std::fabs(roundtrip.entities[0].line.end.v - 0.0045) < 1e-12);
    independentBinary.chop(3);
    writeDxf(directory, independentBinary);
    assert(!cadnext::gui::readDxfSketch(path, roundtrip, error));

    cadnext::Sketch rectangle;
    cadnext::SketchEntity rect;
    rect.type = cadnext::SketchEntityType::Rectangle;
    rect.rectangle.origin = {2.0, 3.0};
    rect.rectangle.width = 4.0;
    rect.rectangle.height = 5.0;
    rectangle.entities.push_back(rect);
    assert(cadnext::gui::writeDxfSketch(exportedPath, rectangle, error));
    QFile rectangleFile(exportedPath);
    assert(rectangleFile.open(QIODevice::ReadOnly));
    assert(rectangleFile.readAll().contains("10\n2000\n20\n3000\n"));
    assert(cadnext::gui::readDxfSketch(exportedPath, roundtrip, error));
    assert(roundtrip.entities.size() == 4);
    assert(std::fabs(roundtrip.entities[3].line.end.u - 2.0) < 1e-10);

    QByteArray arc = valid;
    arc.replace("0\nCIRCLE\n10\n1\n20\n2\n40\n0.5\n",
                "0\nARC\n10\n1\n20\n2\n40\n0.5\n50\n0\n51\n90\n");
    writeDxf(directory, arc);
    error.clear();
    assert(cadnext::gui::readDxfSketch(path, data, error));
    assert(data.entities[1].type == cadnext::SketchEntityType::Arc);
    assert(std::fabs(data.entities[1].arc.center.u - 0.0254) < 1e-12);
    assert(std::fabs(data.entities[1].arc.radius - 0.0127) < 1e-12);
    assert(std::fabs(data.entities[1].arc.sweepDegrees - 90.0) < 1e-12);
    exported.entities = data.entities;
    assert(cadnext::gui::writeDxfSketch(exportedPath, exported, error));
    assert(cadnext::gui::readDxfSketch(exportedPath, roundtrip, error));
    assert(roundtrip.entities[1].type == cadnext::SketchEntityType::Arc);
    assert(std::fabs(roundtrip.entities[1].arc.radius - 0.0127) < 1e-12);
    assert(cadnext::gui::writeDxfSketch(binaryPath, exported, error, true));
    assert(cadnext::gui::readDxfSketch(binaryPath, roundtrip, error));
    assert(roundtrip.entities[1].type == cadnext::SketchEntityType::Arc);

    QByteArray wrappedArc = arc;
    wrappedArc.replace("50\n0\n51\n90\n", "50\n315\n51\n45\n");
    writeDxf(directory, wrappedArc);
    assert(cadnext::gui::readDxfSketch(path, data, error));
    assert(std::fabs(data.entities[1].arc.startAngleDegrees - 315.0) < 1e-12);
    assert(std::fabs(data.entities[1].arc.sweepDegrees - 90.0) < 1e-12);

    const QByteArray curvedPolyline = R"(0
SECTION
2
ENTITIES
0
LWPOLYLINE
90
2
10
0
20
0
42
1
10
2
20
0
0
ENDSEC
0
EOF
)";
    writeDxf(directory, curvedPolyline);
    assert(cadnext::gui::readDxfSketch(path, data, error));
    assert(data.entities.size() == 1);
    assert(data.entities[0].type == cadnext::SketchEntityType::Arc);
    assert(std::fabs(data.entities[0].arc.center.u - 0.001) < 1e-12);
    assert(std::fabs(data.entities[0].arc.center.v) < 1e-12);
    assert(std::fabs(data.entities[0].arc.radius - 0.001) < 1e-12);
    assert(std::fabs(data.entities[0].arc.startAngleDegrees - 180.0) < 1e-12);
    assert(std::fabs(data.entities[0].arc.sweepDegrees - 180.0) < 1e-12);
    QByteArray negativeBulge = curvedPolyline;
    negativeBulge.replace("42\n1\n", "42\n-1\n");
    writeDxf(directory, negativeBulge);
    assert(cadnext::gui::readDxfSketch(path, data, error));
    assert(std::fabs(data.entities[0].arc.startAngleDegrees) < 1e-12);
    assert(std::fabs(data.entities[0].arc.sweepDegrees - 180.0) < 1e-12);

    QByteArray closedCurvedPolyline = curvedPolyline;
    closedCurvedPolyline.replace("90\n2\n", "90\n2\n70\n1\n");
    closedCurvedPolyline.replace("10\n2\n20\n0\n", "10\n2\n20\n0\n42\n1\n");
    writeDxf(directory, closedCurvedPolyline);
    assert(cadnext::gui::readDxfSketch(path, data, error));
    assert(data.entities.size() == 2);
    assert(data.entities[0].type == cadnext::SketchEntityType::Arc);
    assert(data.entities[1].type == cadnext::SketchEntityType::Arc);
    assert(std::fabs(data.entities[1].arc.sweepDegrees - 180.0) < 1e-12);
    QByteArray mixedBulge = closedCurvedPolyline;
    mixedBulge.replace("10\n2\n20\n0\n42\n1\n", "10\n2\n20\n0\n");
    writeDxf(directory, mixedBulge);
    cadnext::gui::DxfSketchData bulgedData;
    assert(cadnext::gui::readDxfSketch(path, bulgedData, error));
    assert(bulgedData.entities.size() == 2);
    assert(bulgedData.entities[0].type == cadnext::SketchEntityType::Arc);
    assert(bulgedData.entities[1].type == cadnext::SketchEntityType::Line);
    cadnext::Sketch bulgedSketch;
    bulgedSketch.id = "bulged-semicircle";
    bulgedSketch.entities = bulgedData.entities;
    bulgedSketch.entities[0].id = "bulged-arc";
    bulgedSketch.entities[1].id = "closing-line";
    const auto bulgedProfiles = cadnext::SketchProfileDetector().detect(bulgedSketch);
    assert(bulgedProfiles.size() == 1);
    assert(bulgedProfiles[0].kind == cadnext::SketchProfileKind::Curved);
    assert(std::fabs(bulgedProfiles[0].area - M_PI * 0.001 * 0.001 * 0.5) < 1e-12);
    cadnext::Sketch circularSketch;
    circularSketch.id = "imported-circle";
    circularSketch.entities = data.entities;
    circularSketch.entities[0].id = "arc-a";
    circularSketch.entities[1].id = "arc-b";
    const auto circularProfiles = cadnext::SketchProfileDetector().detect(circularSketch);
    assert(circularProfiles.size() == 1);
    assert(circularProfiles[0].kind == cadnext::SketchProfileKind::Circle);
    assert(circularProfiles[0].isValid);
    assert(std::fabs(circularProfiles[0].circleCenter.u - 0.001) < 1e-12);
    assert(std::fabs(circularProfiles[0].circleRadius - 0.001) < 1e-12);
    cadnext::kernel::OcctKernel kernel;
    cadnext::kernel::GeometryEvaluator evaluator(kernel);
    cadnext::ExtrudeParameters extrusion;
    extrusion.sketchId = circularSketch.id;
    extrusion.profileId = circularProfiles[0].id;
    extrusion.distance = 0.002;
    const auto cylinder = evaluator.evaluateExtrude(
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XY),
        circularProfiles[0], extrusion);
    assert(cylinder.isOk() && cylinder.value().isValid);
    const auto cylinderVolume = kernel.volumeProperties(cylinder.value().shape);
    assert(cylinderVolume.isOk());
    assert(std::fabs(cylinderVolume.value().volumeM3 - 2.0e-9 * M_PI) < 1e-13);
    const QString stepPath = directory.filePath(QStringLiteral("dxf-circle.stp"));
    assert(kernel.exportExchangeFile({{cylinder.value().shape, {}}},
                                     stepPath.toStdString()).isOk());
    QFile stepFile(stepPath);
    assert(stepFile.open(QIODevice::ReadOnly));
    const QByteArray stepBytes = stepFile.readAll();
    assert(stepBytes.contains("CYLINDRICAL_SURFACE"));
    assert(stepBytes.contains("CIRCLE"));
    assert(!stepBytes.contains("B_SPLINE_SURFACE"));
    const auto restoredCylinder = kernel.importExchangeFile(stepPath.toStdString());
    assert(restoredCylinder.isOk());
    const auto restoredVolume = kernel.volumeProperties(restoredCylinder.value());
    assert(restoredVolume.isOk());
    assert(std::fabs(restoredVolume.value().volumeM3 -
                     cylinderVolume.value().volumeM3) < 1e-13);
    cadnext::kernel::ExchangeBody scaledBody{cylinder.value().shape, {}};
    scaledBody.placement.scale = {2.0, 2.0, 2.0};
    stepFile.close();
    assert(kernel.exportExchangeFile({scaledBody}, stepPath.toStdString()).isOk());
    assert(stepFile.open(QIODevice::ReadOnly));
    const QByteArray scaledStep = stepFile.readAll();
    assert(scaledStep.contains("CYLINDRICAL_SURFACE"));
    assert(!scaledStep.contains("B_SPLINE_SURFACE"));
    const auto scaledCylinder = kernel.importExchangeFile(stepPath.toStdString());
    assert(scaledCylinder.isOk());
    const auto scaledVolume = kernel.volumeProperties(scaledCylinder.value());
    assert(scaledVolume.isOk());
    assert(std::fabs(scaledVolume.value().volumeM3 -
                     cylinderVolume.value().volumeM3 * 8.0) < 1e-12);
    circularSketch.entities[1].arc.sweepDegrees = 179.0;
    assert(cadnext::SketchProfileDetector().detect(circularSketch).empty());

    const QByteArray semicircle = R"(0
SECTION
2
HEADER
9
$INSUNITS
70
4
0
ENDSEC
0
SECTION
2
ENTITIES
0
ARC
10
0
20
0
40
10
50
0
51
180
0
LINE
10
-10
20
0
11
10
21
0
0
ENDSEC
0
EOF
)";
    writeDxf(directory, semicircle);
    assert(cadnext::gui::readDxfSketch(path, data, error));
    assert(data.entities.size() == 2);
    cadnext::Sketch mixedSketch;
    mixedSketch.id = "arc-and-line";
    mixedSketch.entities = data.entities;
    mixedSketch.entities[0].id = "semicircle";
    mixedSketch.entities[1].id = "diameter";
    const auto mixedProfiles = cadnext::SketchProfileDetector().detect(mixedSketch);
    assert(mixedProfiles.size() == 1);
    assert(mixedProfiles[0].kind == cadnext::SketchProfileKind::Curved);
    assert(mixedProfiles[0].isValid && mixedProfiles[0].segments.size() == 2);
    assert(std::fabs(mixedProfiles[0].area - 0.5 * M_PI * 0.01 * 0.01) < 1e-12);
    extrusion.sketchId = mixedSketch.id;
    extrusion.profileId = mixedProfiles[0].id;
    const auto curvedPrism = evaluator.evaluateExtrude(
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XY),
        mixedProfiles[0], extrusion);
    assert(curvedPrism.isOk() && curvedPrism.value().isValid);
    const auto curvedVolume = kernel.volumeProperties(curvedPrism.value().shape);
    assert(curvedVolume.isOk());
    assert(std::fabs(curvedVolume.value().volumeM3 -
                     M_PI * 0.01 * 0.01 * 0.001) < 1e-12);
    assert(kernel.exportExchangeFile({{curvedPrism.value().shape, {}}},
                                     stepPath.toStdString()).isOk());
    stepFile.close();
    assert(stepFile.open(QIODevice::ReadOnly));
    const QByteArray curvedStep = stepFile.readAll();
    assert(curvedStep.contains("CYLINDRICAL_SURFACE"));
    assert(!curvedStep.contains("B_SPLINE_SURFACE"));
    stepFile.close();
    const auto restoredCurved = kernel.importExchangeFile(stepPath.toStdString());
    assert(restoredCurved.isOk());
    const auto restoredCurvedVolume = kernel.volumeProperties(restoredCurved.value());
    assert(restoredCurvedVolume.isOk());
    assert(std::fabs(restoredCurvedVolume.value().volumeM3 -
                     curvedVolume.value().volumeM3) < 1e-12);
    const QString mixedDxfPath = directory.filePath(QStringLiteral("mixed-roundtrip.dxf"));
    assert(cadnext::gui::writeDxfSketch(mixedDxfPath, mixedSketch, error));
    cadnext::gui::DxfSketchData mixedRoundTrip;
    assert(cadnext::gui::readDxfSketch(mixedDxfPath, mixedRoundTrip, error));
    assert(mixedRoundTrip.entities.size() == 2);
    cadnext::Sketch restoredSketch;
    restoredSketch.id = "mixed-roundtrip";
    restoredSketch.entities = mixedRoundTrip.entities;
    for (std::size_t i = 0; i < restoredSketch.entities.size(); ++i)
        restoredSketch.entities[i].id = "restored-" + std::to_string(i);
    const auto restoredProfiles = cadnext::SketchProfileDetector().detect(restoredSketch);
    assert(restoredProfiles.size() == 1);
    assert(restoredProfiles[0].kind == cadnext::SketchProfileKind::Curved);
    assert(std::fabs(restoredProfiles[0].area - mixedProfiles[0].area) < 1e-12);
    cadnext::RevolveParameters curvedRevolve;
    curvedRevolve.sketchId = mixedSketch.id;
    curvedRevolve.profileId = mixedProfiles[0].id;
    curvedRevolve.axis = cadnext::RevolveAxis::U;
    curvedRevolve.axisOffset = -0.02;
    curvedRevolve.angleDegrees = 180.0;
    const auto revolvedCurved = evaluator.evaluateRevolve(
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XY),
        mixedProfiles[0], curvedRevolve);
    assert(revolvedCurved.isOk() && revolvedCurved.value().isValid);
    const auto revolvedCurvedVolume = kernel.volumeProperties(revolvedCurved.value().shape);
    assert(revolvedCurvedVolume.isOk() && revolvedCurvedVolume.value().volumeM3 > 0.0);
    cadnext::Sketch lens;
    lens.id = "two-arc-lens";
    const double alpha = std::atan2(3.0, 4.0) * 180.0 / M_PI;
    cadnext::SketchEntity lowerArc;
    lowerArc.id = "lower";
    lowerArc.type = cadnext::SketchEntityType::Arc;
    lowerArc.arc.center = {0.0, 0.003};
    lowerArc.arc.radius = 0.005;
    lowerArc.arc.startAngleDegrees = 180.0 + alpha;
    lowerArc.arc.sweepDegrees = 180.0 - 2.0 * alpha;
    cadnext::SketchEntity upperArc = lowerArc;
    upperArc.id = "upper";
    upperArc.arc.center = {0.0, -0.003};
    upperArc.arc.startAngleDegrees = alpha;
    lens.entities = {upperArc, lowerArc};
    const auto lensProfiles = cadnext::SketchProfileDetector().detect(lens);
    assert(lensProfiles.size() == 1);
    assert(lensProfiles[0].kind == cadnext::SketchProfileKind::Curved);
    assert(lensProfiles[0].isValid && lensProfiles[0].segments.size() == 2);
    extrusion.sketchId = lens.id;
    extrusion.profileId = lensProfiles[0].id;
    const auto lensPrism = evaluator.evaluateExtrude(
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XY),
        lensProfiles[0], extrusion);
    assert(lensPrism.isOk() && lensPrism.value().isValid);
    const auto lensVolume = kernel.volumeProperties(lensPrism.value().shape);
    assert(lensVolume.isOk());
    assert(std::fabs(lensVolume.value().volumeM3 -
                     lensProfiles[0].area * extrusion.distance) < 1e-12);
    mixedSketch.entities.pop_back();
    assert(cadnext::SketchProfileDetector().detect(mixedSketch).empty());

    QByteArray widePolyline = curvedPolyline;
    widePolyline.replace("90\n2\n", "90\n2\n43\n0.5\n");
    writeDxf(directory, widePolyline);
    error.clear();
    assert(!cadnext::gui::readDxfSketch(path, data, error));
    assert(error.contains(QStringLiteral("ширину")));

    QByteArray unsupported = valid;
    unsupported.replace("0\nCIRCLE\n10\n1\n20\n2\n40\n0.5\n",
                        "0\nSPLINE\n");
    writeDxf(directory, unsupported);
    error.clear();
    assert(!cadnext::gui::readDxfSketch(path, data, error));
    assert(error.contains(QStringLiteral("SPLINE")));

    QByteArray nonplanar = valid;
    nonplanar.replace("11\n1\n21\n0\n", "11\n1\n21\n0\n31\n1\n");
    writeDxf(directory, nonplanar);
    error.clear();
    assert(!cadnext::gui::readDxfSketch(path, data, error));
    assert(error.contains(QStringLiteral("XY")));
}
