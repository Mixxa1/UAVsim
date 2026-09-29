// DWG 2004 (AC1018) and 2010 (AC1024) against the same drawings saved in the versions read before
// (2000, 2013, 2018): LibreDWG's test data (github.com/LibreDWG/libredwg, test/test-data, used as data only).
//
// Criteria, fixed before the first run of this test:
//   - Every 2004 and 2010 file (example_2004, example_2010, Arc, circle, Ellipse, Line, Polyline): read,
//     not one object misread — each block header, insert and plane entity ending exactly where its data ends.
//   - example_2004 and example_2010 as example_2013: 35 classes, 16 block headers, 10 inserts, 86 plane
//     entities, 3 ACIS objects each with its ACIS data; INSUNITS 4; the model extents' x and y as 2013's.
//   - The sketch (readDwgModel, dwgSketchEntities) of example_2004 and example_2010 the same, bit for bit,
//     as example_2000's; that of each small drawing of 2004 and 2010 as its 2018 one's.
//   - The bodies (importBodiesFromFile) of example_2004 and example_2010: as many as example_2000's, the
//     same faces, their volumes within 1e-12 relative.
//   - A 2007 file (AC1021): refused, the version named.
// Amended 2026-09-27 when the 2007 container was read (before this form was run): 2007 (example_2007 and
// its five small drawings) held to every criterion above as 2004 and 2010 are, instead of the refusal.
#include "cadnext/gui/BackgroundCadImport.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

using namespace cadnext;
using namespace cadnext::gui;

namespace {

int failures = 0;

void check(bool ok, const std::string& what) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what.c_str());
    if (!ok) ++failures;
}

// A drawing's sketch as sorted records: the entity's type, then its numbers.
std::vector<std::vector<double>> sketchOf(const QString& path) {
    std::vector<std::vector<double>> out;
    DwgModel model;
    QString error;
    if (!readDwgModel(path, model, error)) return out;
    std::vector<SketchEntity> entities;
    std::map<QString, int> left;
    dwgSketchEntities(model, entities, left);
    for (const SketchEntity& s : entities) {
        std::vector<double> r{double(int(s.type))};
        switch (s.type) {
        case SketchEntityType::Line: r.insert(r.end(), {s.line.start.u, s.line.start.v, s.line.end.u, s.line.end.v}); break;
        case SketchEntityType::Circle: r.insert(r.end(), {s.circle.center.u, s.circle.center.v, s.circle.radius}); break;
        case SketchEntityType::Arc:
            r.insert(r.end(), {s.arc.center.u, s.arc.center.v, s.arc.radius, s.arc.startAngleDegrees, s.arc.sweepDegrees});
            break;
        default: r.insert(r.end(), {s.rectangle.origin.u, s.rectangle.origin.v, s.rectangle.width, s.rectangle.height});
        }
        out.push_back(r);
    }
    std::sort(out.begin(), out.end());
    return out;
}

struct Bodies {
    std::vector<std::pair<std::size_t, double>> faceVolume; // faces, volume — sorted
    QString error;
};

Bodies bodiesOf(const QString& path) {
    Bodies b;
    const BodyImportResult imported = importBodiesFromFile(path);
    b.error = imported.error;
    kernel::OcctKernel kernel;
    for (const ImportedBody& body : imported.bodies) {
        const auto shape = kernel.importBRep(body.brep);
        if (!shape.isOk()) continue;
        GProp_GProps p;
        BRepGProp::VolumeProperties(*kernel.findShape(shape.value()), p);
        b.faceVolume.push_back({body.faces.size(), p.Mass()});
    }
    std::sort(b.faceVolume.begin(), b.faceVolume.end());
    return b;
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples") + "/dwg/libredwg";
    if (!QFileInfo::exists(root + "/example_2004.dwg")) {
        std::printf("SKIP образцы LibreDWG не найдены (%s)\n", root.toUtf8().constData());
        return 77;
    }
    const QStringList small{"Arc", "circle", "Ellipse", "Line", "Polyline"};

    // Every 2004 and 2010 file, not one object misread.
    for (const QString& version : {QStringLiteral("2004"), QStringLiteral("2007"), QStringLiteral("2010")}) {
        QStringList files{root + "/example_" + version + ".dwg"};
        for (const QString& name : small) files << root + "/" + version + "/" + name + ".dwg";
        int read = 0, misread = 0;
        QString problem;
        for (const QString& path : files) {
            DwgFile file;
            QString error;
            if (readDwgFile(path, file, error)) ++read;
            else problem = error;
            misread += file.misread;
        }
        check(read == files.size() && misread == 0,
              "DWG " + version.toStdString() + ": " + std::to_string(read) + " из " + std::to_string(files.size()) +
                  " файлов прочитаны, объектов с ошибкой " + std::to_string(misread) +
                  (problem.isEmpty() ? std::string() : " — " + problem.toStdString()));
    }

    // example_2004 and example_2010 as example_2013.
    DwgFile reference;
    QString error;
    readDwgFile(root + "/example_2013.dwg", reference, error);
    const auto counts = [](const DwgFile& f) {
        int acis = 0, withData = 0;
        for (const DwgObject& o : f.objects)
            if (o.type == 37 || o.type == 38 || o.type == 39) ++acis, withData += o.acis.isEmpty() ? 0 : 1;
        return std::vector<long long>{(long long)f.classes.size(), (long long)f.blocks.size(), (long long)f.inserts.size(),
                                      (long long)f.planar.size(), acis, withData, f.header.insunits};
    };
    const auto expected = counts(reference);
    for (const QString& version : {QStringLiteral("2004"), QStringLiteral("2007"), QStringLiteral("2010")}) {
        DwgFile file;
        readDwgFile(root + "/example_" + version + ".dwg", file, error);
        const auto got = counts(file);
        const bool extents = file.header.extentsMin[0] == reference.header.extentsMin[0] &&
                             file.header.extentsMin[1] == reference.header.extentsMin[1] &&
                             file.header.extentsMax[0] == reference.header.extentsMax[0] &&
                             file.header.extentsMax[1] == reference.header.extentsMax[1];
        char line[256];
        std::snprintf(line, sizeof line,
                      "example_%s: классов %lld, блоков %lld, вставок %lld, плоских %lld, тел ACIS %lld (с данными %lld), INSUNITS %lld — как у 2013",
                      version.toUtf8().constData(), got[0], got[1], got[2], got[3], got[4], got[5], got[6]);
        check(got == expected && expected == std::vector<long long>{35, 16, 10, 86, 3, 3, 4} && extents, line);
    }

    // Sketches, bit for bit.
    const auto sketch2000 = sketchOf(root + "/example_2000.dwg");
    for (const QString& version : {QStringLiteral("2004"), QStringLiteral("2007"), QStringLiteral("2010")}) {
        const auto sketch = sketchOf(root + "/example_" + version + ".dwg");
        check(!sketch2000.empty() && sketch == sketch2000,
              "example_" + version.toStdString() + ": эскиз (" + std::to_string(sketch.size()) + " примитивов) тот же, бит в бит, что у 2000 (" +
                  std::to_string(sketch2000.size()) + ")");
        int same = 0;
        for (const QString& name : small)
            same += !sketchOf(root + "/2018/" + name + ".dwg").empty() &&
                    sketchOf(root + "/" + version + "/" + name + ".dwg") == sketchOf(root + "/2018/" + name + ".dwg");
        // (The ellipse gives no sketch entity: an ellipse is left out, as in 2018.)
        const bool ellipseEmpty = sketchOf(root + "/" + version + "/Ellipse.dwg").empty() && sketchOf(root + "/2018/Ellipse.dwg").empty();
        check(same == 4 && ellipseEmpty,
              "DWG " + version.toStdString() + ": эскизы отрезка, дуги, окружности, полилинии те же, что у 2018 (" + std::to_string(same) +
                  " из 4); эллипс, как и там, не входит");
    }

    // Bodies.
    const Bodies bodies2000 = bodiesOf(root + "/example_2000.dwg");
    for (const QString& version : {QStringLiteral("2004"), QStringLiteral("2007"), QStringLiteral("2010")}) {
        const Bodies bodies = bodiesOf(root + "/example_" + version + ".dwg");
        bool same = !bodies2000.faceVolume.empty() && bodies.faceVolume.size() == bodies2000.faceVolume.size();
        double worst = 0.0;
        for (std::size_t i = 0; same && i < bodies.faceVolume.size(); ++i) {
            same = bodies.faceVolume[i].first == bodies2000.faceVolume[i].first;
            worst = std::max(worst, std::fabs(bodies.faceVolume[i].second - bodies2000.faceVolume[i].second) / bodies2000.faceVolume[i].second);
        }
        char line[256];
        std::snprintf(line, sizeof line, "example_%s: тел %zu (у 2000 %zu), грани те же, объём до %.1e (допуск 1e-12)", version.toUtf8().constData(),
                      bodies.faceVolume.size(), bodies2000.faceVolume.size(), worst);
        check(same && worst <= 1e-12, line + (bodies.error.isEmpty() ? std::string() : " — " + bodies.error.toStdString()));
    }


    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
