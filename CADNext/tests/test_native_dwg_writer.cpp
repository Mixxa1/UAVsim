// The AutoCAD 2000 (AC1015) codecs of NativeDwgR2000 against the drawings of the samples, then our own
// drawing of solids read back.
//
// Samples (CADNEXT_TEST_SAMPLES, ~/cadnext-samples by default): dwg/blowdryer, eleven drawings AutoCAD
// 2000 (Mechanical Desktop 4) wrote; dwg/libredwg/example_2000.dwg, one AutoCAD 2020 for Mac saved as
// 2000 (its solid's SAT names "Autodesk AutoCAD 20 ASM 223 … OSX"). Each part of each file must decode
// and encode back as it was: bit for bit, but for the bits AutoCAD pads classes and objects with
// (whatever its buffer held) and the eight junk bytes of the second file header.

#include "cadnext/gui/NativeDwgR2000.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/gui/AcisSatWriter.hpp"
#include "cadnext/gui/DwgWriter.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <cstdio>
#include <map>
#include <set>
#include <string>

using namespace cadnext;
using namespace cadnext::gui;

namespace {

int failures = 0;
int passes = 0;

void check(bool ok, const std::string& what) {
    std::printf("%s: %s\n", ok ? "PASS" : "FAIL", what.c_str());
    if (ok) ++passes;
    else ++failures;
}

QByteArray readFile(const QString& path) {
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

// Equal but for `padding` bits before the last two bytes (the CRC, also skipped).
bool sameButPadding(const QByteArray& mine, const QByteArray& theirs, qint64 dataEndByte, int padding) {
    if (mine.size() != theirs.size()) return false;
    for (qint64 i = 0; i < mine.size(); ++i) {
        if (i == dataEndByte - 1 && padding > 0) {
            const uchar mask = uchar(0xFF << padding);
            if ((uchar(mine[i]) & mask) != (uchar(theirs[i]) & mask)) return false;
            continue;
        }
        if (i == dataEndByte || i == dataEndByte + 1) continue; // CRC
        if (mine[i] != theirs[i]) return false;
    }
    return true;
}

// Every handle an object refers to.
void references(const DwgR2000Object& o, std::vector<quint64>& out) {
    const auto add = [&](const DwgHandleRef& h) { if (h.value) out.push_back(h.value); };
    const auto& f = o.frame;
    add(f.owner);
    for (const auto& r : f.reactors) add(r);
    add(f.xdictionary);
    if (f.entity) { add(f.previous); add(f.next); add(f.layer); add(f.linetype); add(f.plotStyle); }
    std::visit([&](const auto& d) {
        using T = std::decay_t<decltype(d)>;
        if constexpr (std::is_same_v<T, DwgControlData>) { for (const auto& h : d.handles) add(h); for (const auto& h : d.more) add(h); }
        if constexpr (std::is_same_v<T, DwgBlockHeaderData>) {
            add(d.block); add(d.first); add(d.last); add(d.endBlock); add(d.layout);
            for (const auto& h : d.inserts) add(h);
        }
        if constexpr (std::is_same_v<T, DwgLayerData>) { add(d.plotStyle); add(d.linetype); }
        if constexpr (std::is_same_v<T, DwgDictionaryData>) { for (const auto& h : d.items) add(h); if (d.defaultEntry) add(*d.defaultEntry); }
        if constexpr (std::is_same_v<T, DwgLayoutData>) { add(d.block); add(d.lastViewport); add(d.baseUcs); add(d.namedUcs); }
        if constexpr (std::is_same_v<T, DwgDimStyleData>) { add(d.DIMTXSTY); add(d.DIMLDRBLK); add(d.DIMBLK); add(d.DIMBLK1); add(d.DIMBLK2); }
        if constexpr (std::is_same_v<T, DwgViewportData>) { add(d.namedUcs); add(d.baseUcs); }
    }, o.data);
}

struct FileReport {
    int objects = 0;
    std::map<QString, std::pair<int, int>> kinds; // decoded, re-encoded the same
};

// All the parts of one AC1015 file.
void samplesFile(const QString& path, std::map<QString, std::pair<int, int>>& totals, int& fileParts, int& fileGood, int& auxFiles) {
    const QByteArray file = readFile(path);
    const QString name = QFileInfo(path).fileName();
    QString error;
    DwgR2000FileHeader header;
    bool good = decodeDwgR2000FileHeader(file, header, error);
    std::map<int, DwgSectionLocator> loc;
    for (const auto& l : header.locators) loc[l.number] = l;
    // Header variables: whole, bit for bit.
    DwgR2000HeaderVariables variables;
    if (good) good = decodeDwgR2000HeaderVariables(file, loc[0].seeker, variables, error);
    const bool variablesSame = good && encodeDwgR2000HeaderVariables(variables) == file.mid(loc[0].seeker, loc[0].size);
    // Classes: but for their padding.
    std::vector<DwgClassRecord> classes;
    int padding = 0;
    bool classesSame = good && decodeDwgR2000Classes(file, loc[1].seeker, classes, error, &padding);
    if (classesSame) {
        const QByteArray mine = encodeDwgR2000Classes(classes);
        classesSame = sameButPadding(mine, file.mid(loc[1].seeker, loc[1].size), mine.size() - 18, padding);
    }
    // Object map, auxiliary header, free space, template: bit for bit.
    std::vector<std::pair<quint64, quint32>> map;
    const bool mapSame = good && decodeDwgR2000ObjectMap(file, loc[2].seeker, loc[2].size, map, error) &&
                         encodeDwgR2000ObjectMap(map) == file.mid(loc[2].seeker, loc[2].size);
    // The auxiliary header as AutoCAD 2000 lays it out (it begins ff 77 01). AutoCAD 2020 writes another
    // (ff 88 01, other fields in places AutoCAD 2000 keeps zero): not this codec's, not written by us.
    DwgR2000AuxHeader aux;
    const bool auxOf2000 = loc.count(5) && file.mid(loc[5].seeker, 3) == QByteArray::fromHex("ff7701");
    const bool auxSame = !auxOf2000 || decodeDwgR2000AuxHeader(file, loc[5].seeker, aux, error);
    auxFiles += auxOf2000 ? 1 : 0;
    DwgR2000FreeSpace freeSpace;
    const bool freeSame = loc[3].size == 0 || decodeDwgR2000FreeSpace(file, loc[3].seeker, freeSpace, error);
    // Second header: but for its junk.
    const qint64 secondAt = file.lastIndexOf(QByteArray::fromHex("D47B21CE28939FBF53244009123CAA01"));
    DwgR2000SecondHeader second;
    bool secondSame = secondAt > 0 && decodeDwgR2000SecondHeader(file, quint32(secondAt), second, error);
    if (secondSame) {
        const QByteArray mine = encodeDwgR2000SecondHeader(second);
        const QByteArray theirs = file.mid(secondAt, mine.size());
        secondSame = mine.left(mine.size() - 24) == theirs.left(theirs.size() - 24) && mine.right(16) == theirs.right(16);
    }
    DwgR2000Preview preview;
    const bool previewSame = decodeDwgR2000Preview(file, header.imageSeeker, preview, error);
    const bool all = good && variablesSame && classesSame && mapSame && auxSame && freeSame && secondSame && previewSame;
    ++fileParts;
    fileGood += all ? 1 : 0;
    if (!all)
        std::printf("  %s: header %d variables %d classes %d map %d aux %d free %d second %d preview %d (%s)\n",
                    qPrintable(name), good, variablesSame, classesSame, mapSame, auxSame, freeSame, secondSame, previewSame, qPrintable(error));

    // Objects of the kinds the codecs know.
    DwgFile parsed;
    if (!readDwgR2000(path, parsed, error)) { check(false, name.toStdString() + ": прочитан читателем DWG"); return; }
    for (const DwgObject& object : parsed.objects) {
        const QString type = dwgTypeName(parsed, object.type);
        const auto kind = dwgObjectKind(type);
        if (!kind) continue;
        auto& counts = totals[type.trimmed().remove(QChar(u'\0'))];
        DwgR2000Object decoded;
        DwgObjectExtent extent;
        QString objectError;
        if (!decodeDwgR2000Object(file, object.offset, *kind, decoded, objectError, &extent)) {
            if (counts.first - counts.second < 3)
                std::printf("  %s %llx %s: %s\n", qPrintable(name), (unsigned long long)object.handle, qPrintable(type), qPrintable(objectError));
            ++counts.first;
            continue;
        }
        ++counts.first;
        QByteArray mine;
        DwgObjectExtent myExtent;
        if (!encodeDwgR2000Object(decoded, mine, objectError, &myExtent)) continue;
        const QByteArray theirs = file.mid(object.offset, extent.sizeBytes + extent.bytes + 2);
        const int pad = int(quint64(extent.bytes) * 8 - extent.handlesEnd);
        if (myExtent.dataBits == extent.dataBits && myExtent.handlesEnd == extent.handlesEnd &&
            sameButPadding(mine, theirs, extent.sizeBytes + extent.bytes, pad))
            ++counts.second;
        else if (counts.first - counts.second < 3)
            std::printf("  %s %llx %s: encoded back differently (%lld vs %lld bytes)\n", qPrintable(name),
                        (unsigned long long)object.handle, qPrintable(type), (long long)mine.size(), (long long)theirs.size());
    }
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples");

    // 1. The samples.
    QStringList files;
    for (const QFileInfo& f : QDir(root + "/dwg/blowdryer").entryInfoList({"*.dwg"}, QDir::Files, QDir::Name)) files << f.absoluteFilePath();
    if (QFileInfo::exists(root + "/dwg/libredwg/example_2000.dwg")) files << root + "/dwg/libredwg/example_2000.dwg";
    if (files.isEmpty()) {
        std::printf("SKIP образцов: нет %s/dwg\n", qPrintable(root));
    } else {
        std::map<QString, std::pair<int, int>> totals;
        int parts = 0, good = 0, auxFiles = 0;
        for (const QString& f : files) samplesFile(f, totals, parts, good, auxFiles);
        check(good == parts, "заголовок файла, переменные, классы, карта объектов, второй заголовок, свободное место, "
                             "картинка — как в файле: " + std::to_string(good) + " из " + std::to_string(parts) +
                             " файлов; вспомогательный заголовок AutoCAD 2000 — в " + std::to_string(auxFiles));
        for (const auto& [type, counts] : totals)
            check(counts.first > 0 && counts.first == counts.second,
                  type.toStdString() + ": " + std::to_string(counts.second) + " из " + std::to_string(counts.first) +
                  " объектов закодированы обратно как в файле");
    }

    // 2. Our drawing: two solids, read back.
    kernel::OcctKernel kernel;
    const auto box = kernel.makeBox({0.04, 0.03, 0.02});
    const auto cylinder = kernel.makeCylinder({0.01, 0.025});
    if (!box.isOk() || !cylinder.isOk()) {
        check(false, "тела для записи построены");
    } else {
        std::vector<QByteArray> sats;
        for (const kernel::NamedExchangeBody& body : {kernel::NamedExchangeBody{"box", {box.value(), {}}},
                                                      kernel::NamedExchangeBody{"cylinder", {cylinder.value(), {}}}}) {
            AcisSatWriteReport report;
            const auto sat = encodeAcisSat(kernel, {body}, report);
            if (sat.isOk()) sats.push_back(sat.value());
        }
        DwgR2000SolidsDocument document;
        document.solids = sats;
        document.extents = {0, -10, 0, 70, 30, 25};
        document.created = {2461316, 43200000};
        document.fingerprint = "{8A4B8E5C-6F3B-4E62-9C51-0C7A7E2D3B10}";
        document.version = "{2D0F5E91-1A47-4C38-B7E4-5B9C0E6A8F21}";
        QByteArray drawing;
        QString error;
        const bool written = sats.size() == 2 && encodeDwgR2000SolidsDocument(document, drawing, error);
        check(written, "чертёж AC1015 из двух тел записан" + (written ? std::string() : " — " + error.toStdString()));
        QTemporaryDir dir;
        const QString path = dir.filePath("solids.dwg");
        QFile out(path);
        const bool saved = written && out.open(QIODevice::WriteOnly) && out.write(drawing) == drawing.size();
        out.close();
        // For looking at the file with other tools.
        if (const QString keep = qEnvironmentVariable("CADNEXT_TEST_KEEP_DWG"); written && !keep.isEmpty()) {
            QFile copy(keep);
            if (copy.open(QIODevice::WriteOnly)) copy.write(drawing);
        }
        if (saved) {
            // Every part of our file decodes and encodes back to the same bytes; every reference resolves.
            DwgR2000FileHeader header;
            std::map<int, DwgSectionLocator> loc;
            bool same = decodeDwgR2000FileHeader(drawing, header, error);
            for (const auto& l : header.locators) loc[l.number] = l;
            DwgR2000HeaderVariables variables;
            same = same && decodeDwgR2000HeaderVariables(drawing, loc[0].seeker, variables, error) &&
                   encodeDwgR2000HeaderVariables(variables) == drawing.mid(loc[0].seeker, loc[0].size);
            std::vector<DwgClassRecord> classes;
            same = same && decodeDwgR2000Classes(drawing, loc[1].seeker, classes, error) &&
                   encodeDwgR2000Classes(classes) == drawing.mid(loc[1].seeker, loc[1].size);
            std::vector<std::pair<quint64, quint32>> map;
            same = same && decodeDwgR2000ObjectMap(drawing, loc[2].seeker, loc[2].size, map, error);
            DwgR2000AuxHeader aux;
            DwgR2000FreeSpace freeSpace;
            DwgR2000SecondHeader second;
            DwgR2000Preview preview;
            same = same && decodeDwgR2000AuxHeader(drawing, loc[5].seeker, aux, error) &&
                   decodeDwgR2000FreeSpace(drawing, loc[3].seeker, freeSpace, error) &&
                   decodeDwgR2000SecondHeader(drawing, quint32(loc[3].seeker + loc[3].size), second, error) &&
                   decodeDwgR2000Preview(drawing, header.imageSeeker, preview, error);
            check(same, "наш чертёж: все разделы читаются нашими же кодеками и дают те же байты" + (same ? std::string() : " — " + error.toStdString()));

            DwgFile parsed;
            const bool read = readDwgR2000(path, parsed, error);
            std::set<quint64> handles;
            for (const auto& [h, offset] : map) handles.insert(h);
            int decodedSame = 0, dangling = 0;
            for (const DwgObject& object : parsed.objects) {
                const auto kind = dwgObjectKind(dwgTypeName(parsed, object.type));
                DwgR2000Object decoded;
                QByteArray again;
                if (!kind || !decodeDwgR2000Object(drawing, object.offset, *kind, decoded, error) ||
                    !encodeDwgR2000Object(decoded, again, error) || drawing.mid(object.offset, again.size()) != again)
                    continue;
                ++decodedSame;
                std::vector<quint64> refs;
                references(decoded, refs);
                for (quint64 r : refs) dangling += handles.count(r) ? 0 : 1;
            }
            check(read && decodedSame == int(parsed.objects.size()) && decodedSame == int(map.size()),
                  "наш чертёж: все " + std::to_string(map.size()) + " объектов читаются и кодируются обратно байт в байт (" +
                  std::to_string(decodedSame) + ")");
            check(dangling == 0, "наш чертёж: все ссылки на объекты ведут к объектам карты (висячих " + std::to_string(dangling) + ")");
            check(variables.HANDSEED.value > *handles.rbegin(), "HANDSEED больше последнего номера объекта");

            DwgModel model;
            const bool modelRead = readDwgModel(path, model, error);
            bool bodiesSame = modelRead && model.version == "AC1015" && model.bodies.size() == sats.size();
            constexpr std::array<double, 16> identity{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
            for (std::size_t i = 0; bodiesSame && i < sats.size(); ++i)
                bodiesSame = model.bodies[i].acis.trimmed() == sats[i].trimmed() &&
                             model.bodies[i].millimetresPerUnit == 1.0 && model.bodies[i].placement == identity;
            check(bodiesSame, "читатель DWG CADNext: версия AC1015, два тела, тот же SAT, миллиметры, на месте" +
                              (modelRead ? std::string() : " — " + error.toStdString()));
        }
    }

    // 3. The export the application calls: the drawing with its picture, as AutoCAD 2000 keeps one.
    if (box.isOk()) {
        QTemporaryDir dir;
        const QString path = dir.filePath("export.dwg");
        const auto written = writeDwgSolids(kernel, {{"box", {box.value(), {}}}}, path);
        const QByteArray drawing = readFile(path);
        DwgR2000FileHeader header;
        DwgR2000Preview preview;
        QString error;
        const bool pictured = written.isOk() && decodeDwgR2000FileHeader(drawing, header, error) &&
                              decodeDwgR2000Preview(drawing, header.imageSeeker, preview, error) && preview.header.size() == 80 &&
                              preview.bitmap.size() == 40 + 1024 + 220 * 140;
        int colours = 0;
        if (pictured) {
            std::set<char> used;
            for (qsizetype i = 40 + 1024; i < preview.bitmap.size(); ++i) used.insert(preview.bitmap[i]);
            colours = int(used.size());
        }
        check(pictured && colours > 2, "экспорт DWG: картинка 220 × 140, 8 бит на точку, " + std::to_string(colours) + " цветов" +
                                       (written.isOk() ? std::string() : " — " + written.error().message));
    }

    std::printf("%s: PASS %d FAIL %d\n", failures ? "FAILED" : "OK", passes, failures);
    return failures ? 1 : 0;
}
