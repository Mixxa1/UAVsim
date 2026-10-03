// The blueprint of a SOLIDWORKS assembly made from a STEP file (NativeSolidWorksAssembly) against the
// samples (CADNEXT_TEST_SAMPLES, ~/cadnext-samples by default; sw-assemblies/step-made: three such
// assemblies SOLIDWORKS 2022 made, of 2, 5 and 7 components), then streams of our own.

#include "cadnext/gui/NativeSolidWorksAssembly.hpp"
#include "cadnext/gui/NativeSolidWorksDocument.hpp"
#include "cadnext/gui/NativeSolidWorksPackage.hpp"
#include "cadnext/gui/NativeSolidWorksPart.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QXmlStreamReader>
#include <QTemporaryDir>
#include <QTimeZone>
#include <QDate>
#include <QTime>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

using namespace cadnext;
using namespace cadnext::gui;

namespace {
int failures = 0;
void check(bool ok, const std::string& what) {
    std::printf("%s: %s\n", ok ? "PASS" : "FAIL", what.c_str());
    if (!ok) ++failures;
}
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples") + "/sw-assemblies/step-made";
    const QList<QByteArray> streams = solidWorksAssemblyBlueprintStreams();
    struct Sample { const char* file; std::size_t components; };
    const Sample samples[] = {{"LIFTING_WHEEL_D80.stp.SLDASM", 2}, {"Bracket_45_45_with_fastening_set.stp.SLDASM", 5},
                              {"CUBIC_CONNECTOR_45X45.stp.SLDASM", 7}};
    if (!QFileInfo::exists(root + "/" + samples[0].file)) {
        std::printf("SKIP образцов: нет %s\n", qPrintable(root));
    } else {
        // Every blueprint stream of every sample: the same outside the slots, its sections adding up.
        int matched = 0, total = 0;
        for (const Sample& sample : samples) {
            QFile file(root + "/" + sample.file);
            SolidWorksPackage package;
            QString error;
            if (!file.open(QIODevice::ReadOnly) || !decodeSolidWorksPackage(file.readAll(), package, error)) continue;
            for (const QByteArray& name : streams) {
                ++total;
                const auto entry = std::find_if(package.entries.begin(), package.entries.end(), [&](const auto& e) { return e.name == name; });
                if (entry == package.entries.end()) { std::printf("  %s: нет потока %s\n", sample.file, name.constData()); continue; }
                QString why;
                if (matchSolidWorksAssemblyStream(name, entry->data, sample.components, why)) ++matched;
                else std::printf("  %s: %s\n", sample.file, qPrintable(why));
            }
        }
        check(total == 3 * streams.size() && matched == total, "каждый поток чертежа сборки совпадает с тремя образцами вне слотов: " +
                                                                 std::to_string(matched) + " из " + std::to_string(total));
        // Header2: built from the sample's own strings, times and bounds, it is the sample's, byte for byte.
        int headers = 0;
        for (const Sample& sample : samples) {
            QFile file(root + "/" + sample.file);
            SolidWorksPackage package;
            QString error;
            if (!file.open(QIODevice::ReadOnly) || !decodeSolidWorksPackage(file.readAll(), package, error)) continue;
            const auto entry = std::find_if(package.entries.begin(), package.entries.end(), [](const auto& e) { return e.name == "Header2"; });
            SolidWorksDocumentHeader h;
            if (entry == package.entries.end() || !decodeSolidWorksDocumentHeader(entry->data, h, error) || h.logs.size() != 23 + sample.components) continue;
            SolidWorksAssemblyHeaderFields f;
            f.author = h.authors.front().text;
            for (int i = 0; i < 23; ++i) f.features.push_back(h.logs[std::size_t(i)].featureName.text);
            f.templateTime = h.createdAt;
            f.importTime = h.nativeCounters[2];
            f.path = h.currentDocument.path->text;
            f.title = h.currentDocument.title->text;
            f.source = h.currentDocument.auxiliaryStrings.at(1).text;
            f.configuration = h.currentDocument.configurationName.text;
            f.modifiedAt = h.currentDocument.modifiedAt;
            f.referenceTime = h.currentDocument.nativeFields[0];
            for (std::size_t k = 0; k < sample.components; ++k) {
                const auto& r = h.references[k];
                f.components.push_back({h.logs[23 + k].featureName.text, r.path->text, r.title->text, r.modifiedAt, r.nativeFields[0]});
            }
            f.bounds = *h.nativeBounds;
            QByteArray built;
            if (encodeSolidWorksAssemblyHeader(f, built, error) && built == entry->data) ++headers;
            else std::printf("  %s: Header2 %s (%lld against %lld bytes)\n", sample.file, qPrintable(error), (long long)built.size(), (long long)entry->data.size());
        }
        check(headers == 3, "Header2 собран из полей образца байт в байт: " + std::to_string(headers) + " из 3");

        // The component tree and the keywords: built from what the sample's own XML says, they are the
        // sample's, byte for byte. The information properties: the same ids with the same value types.
        int trees = 0, keywords = 0, informations = 0;
        for (const Sample& sample : samples) {
            QFile file(root + "/" + sample.file);
            SolidWorksPackage package;
            QString error;
            if (!file.open(QIODevice::ReadOnly) || !decodeSolidWorksPackage(file.readAll(), package, error)) continue;
            QHash<QByteArray, QByteArray> data;
            for (const auto& e : package.entries) data.insert(e.name, e.data);
            const QByteArray tree = data.value("swXmlContents/COMPINSTANCETREE");
            SolidWorksAssemblyTreeFields tf;
            QXmlStreamReader r(tree);
            const auto six = [](const QString& text) {
                std::array<double, 6> box{};
                const QStringList v = text.split(QLatin1Char(' '));
                for (int i = 0; i < 6 && i < v.size(); ++i) box[std::size_t(i)] = v[i].toDouble();
                return box;
            };
            while (!r.atEnd()) {
                if (r.readNext() != QXmlStreamReader::StartElement) continue;
                const auto at = r.attributes();
                const auto v = [&](const char* name) { return at.value(QLatin1String(name)).toString(); };
                if (r.name() == QLatin1String("swFile") && v("id") == "3") { tf.path = v("swPath"); tf.source = v("swImportedPath"); tf.created = v("swCreationTime").toUInt(); }
                else if (r.name() == QLatin1String("swFile")) tf.parts.push_back({QString(), v("swPath"), v("swCreationTime").toUInt(), {}});
                else if (r.name() == QLatin1String("swModel") && v("id") == "2") { tf.modelName = v("swName"); tf.importedName = v("swImportedName"); tf.configuration = v("swConfigurationName"); tf.box = six(v("swBoundingBox")); }
                else if (r.name() == QLatin1String("swModel")) { const int k = (v("id").toInt() - 5) / 3; if (k >= 0 && k < int(tf.parts.size())) tf.parts[std::size_t(k)].box = six(v("swBoundingBox")); }
                else if (r.name() == QLatin1String("swReference")) { const int k = (v("id").toInt() - 4) / 3; if (k >= 0 && k < int(tf.parts.size())) tf.parts[std::size_t(k)].name = v("swName"); }
                else if (r.name() == QLatin1String("swDisplayState")) tf.displayState = v("swDisplayStateName");
            }
            if (encodeSolidWorksAssemblyTree(tf) == tree) ++trees;
            else std::printf("  %s: дерево компонентов отличается\n", sample.file);

            const QByteArray words = data.value("swXmlContents/KeyWords");
            SolidWorksAssemblyKeyWordsFields kf;
            QXmlStreamReader w(words.mid(1));
            while (!w.atEnd()) {
                if (w.readNext() != QXmlStreamReader::StartElement) continue;
                const auto at = w.attributes();
                const auto v = [&](const char* name) { return at.value(QLatin1String(name)).toString(); };
                if (w.name() == QLatin1String("Keywords")) { kf.created = v("id").toUInt(); kf.name = v("Name"); }
                else if (w.name() == QLatin1String("Configuration")) kf.configuration = v("Name");
                else kf.items.push_back({w.name().toString(), v("id").toUInt(), v("Name"), v("Description"), v("Type")});
            }
            if (encodeSolidWorksAssemblyKeyWords(kf) == words) ++keywords;
            else std::printf("  %s: ключевые слова отличаются\n", sample.file);

            const auto layout = [](const QByteArray& xml) {
                QStringList out;
                QXmlStreamReader x(xml);
                QString pid;
                while (!x.atEnd()) {
                    x.readNext();
                    if (x.isStartElement() && x.name() == QLatin1String("property")) pid = x.attributes().value(QLatin1String("pid")).toString();
                    else if (x.isStartElement() && x.prefix() == QLatin1String("vt")) out << pid + QLatin1Char(':') + x.name().toString();
                }
                return out;
            };
            SolidWorksAssemblyValues own;
            own.title = QStringLiteral("Assembly");
            own.saved = 1665070834u;
            if (layout(encodeSolidWorksAssemblyInformation(own)) == layout(data.value("docProps/ISolidWorksInformation.xml"))) ++informations;
            else std::printf("  %s: свойства документа отличаются по номерам или типам\n", sample.file);
        }
        check(trees == 3, "дерево компонентов собрано из полей образца байт в байт: " + std::to_string(trees) + " из 3");
        check(keywords == 3, "ключевые слова собраны из полей образца байт в байт: " + std::to_string(keywords) + " из 3");
        check(informations == 3, "свойства документа: те же номера и типы значений, что у образцов: " + std::to_string(informations) + " из 3");
    }

    // Our own streams, for 2 to 9 components: they match the blueprint, and the parts' boxes in them are
    // the parts' own box blocks.
    {
        bool own = true;
        for (std::size_t n = 2; n <= 9 && own; ++n) {
            SolidWorksAssemblyValues values;
            values.title = QStringLiteral("Assembly");
            values.saved = 1700000000u;
            values.filetime = 133000000000000000ull;
            for (std::size_t i = 0; i < n; ++i) {
                SolidWorksAssemblyPartValues part;
                part.name = QStringLiteral("Part%1").arg(i + 1);
                part.boxMin = {0.01 * double(i), -0.02, 0.0};
                part.boxMax = {0.01 * double(i) + 0.03, 0.02, 0.005 * double(i + 1)};
                values.parts.push_back(part);
            }
            for (const QByteArray& name : streams) {
                QByteArray bytes;
                QString why;
                if (!encodeSolidWorksAssemblyStream(name, values, bytes, why) || !matchSolidWorksAssemblyStream(name, bytes, n, why)) {
                    std::printf("  %zu компонентов, %s: %s\n", n, name.constData(), qPrintable(why));
                    own = false;
                    break;
                }
            }
        }
        check(own, "наши потоки на 2–9 компонентов совпадают с чертежом");
    }

    // An assembly of our own: three bodies where they belong, written as parts beside it, read back.
    {
        kernel::OcctKernel kernel;
        const auto box = kernel.makeBox({0.04, 0.03, 0.02});
        const auto cylinder = kernel.makeCylinder({0.01, 0.05});
        const auto sphere = kernel.makeSphere({0.015});
        std::vector<SolidWorksAssemblyBody> bodies;
        std::vector<std::pair<double, gp_Pnt>> expected;
        const auto place = [&](const QString& name, const auto& made, double x, double y, double z) {
            if (!made.isOk()) return;
            std::array<double, 16> t{};
            t[0] = t[5] = t[10] = t[15] = 1.0;
            t[12] = x; t[13] = y; t[14] = z;
            const auto moved = kernel.transformShape(made.value(), t);
            if (!moved.isOk()) return;
            GProp_GProps g;
            BRepGProp::VolumeProperties(*kernel.findShape(moved.value()), g);
            expected.push_back({g.Mass(), g.CentreOfMass()});
            bodies.push_back({name, moved.value()});
        };
        place(QStringLiteral("Block:1"), box, 0.0, 0.0, 0.0);   // not a file name: made one
        place(QStringLiteral("Pin"), cylinder, 0.06, 0.01, 0.0);
        place(QStringLiteral("Pin"), sphere, -0.03, 0.02, 0.05);       // the same name: numbered
        bodies.back().name = QStringLiteral("Pin");
        QTemporaryDir dir;
        const QString path = dir.filePath("Bracket set.SLDASM");
        QString e;
        SolidWorksAssemblyWriteOptions options;
        options.saved = QDateTime(QDate(2026, 10, 3), QTime(12, 0, 0), QTimeZone::UTC);
        const bool written = bodies.size() == 3 && writeSolidWorksImportedAssembly(kernel, bodies, path, e, options);
        check(written, "сборка SOLIDWORKS записана" + (written ? std::string() : " — " + e.toStdString()));
        if (written) {
            const QStringList files = QDir(dir.path()).entryList({"*.SLDPRT", "*.SLDASM"}, QDir::Files, QDir::Name);
            check(files == QStringList({"Block_1.SLDPRT", "Bracket set.SLDASM", "Pin (2).SLDPRT", "Pin.SLDPRT"}),
                  "рядом со сборкой её детали, имя исправлено до имени файла, повторённое пронумеровано: " + files.join(", ").toStdString());
            std::vector<SolidWorksAssemblyComponent> parts;
            bool tree = readSolidWorksAssemblyParts(path, parts, e) && parts.size() == 3;
            for (std::size_t i = 0; tree && i < parts.size(); ++i) {
                const auto& m = parts[i].transform;
                tree = m[0] == 1 && m[5] == 1 && m[10] == 1 && m[15] == 1 && m[12] == 0 && m[13] == 0 && m[14] == 0 && m[1] == 0 && m[4] == 0;
            }
            check(tree && parts[0].name == "Block_1" && parts[1].name == "Pin" && parts[2].name == "Pin (2)" &&
                      parts[2].sourcePath.endsWith("\\Pin (2).SLDPRT"),
                  "дерево компонентов: три детали, единичные матрицы, пути к деталям" + (tree ? std::string() : " — " + e.toStdString()));
            kernel::OcctKernel reader;
            std::vector<SolidWorksImportedBody> back;
            bool same = readSolidWorksAnalyticAssembly(path, reader, back, e) && back.size() == expected.size();
            double worstVolume = 0, worstCentre = 0;
            for (std::size_t i = 0; same && i < back.size(); ++i) {
                GProp_GProps g;
                BRepGProp::VolumeProperties(*reader.findShape(back[i].shape), g);
                worstVolume = std::max(worstVolume, std::fabs(g.Mass() / expected[i].first - 1));
                worstCentre = std::max(worstCentre, g.CentreOfMass().Distance(expected[i].second));
            }
            check(same && worstVolume <= 1e-9 && worstCentre <= 1e-9,
                  "сборка читается обратно: три тела на своих местах, объём до " + QString::number(worstVolume, 'g', 3).toStdString() + ", центр до " +
                      QString::number(worstCentre, 'g', 3).toStdString() + " м" + (same ? std::string() : " — " + e.toStdString()));
            QFile file(path);
            SolidWorksPackage package;
            bool clean = file.open(QIODevice::ReadOnly) && decodeSolidWorksPackage(file.readAll(), package, e);
            int blueprint = 0;
            for (const auto& entry : package.entries) {
                for (const char* leak : {"Tobias", "TOBIAS", "Schwien", "Personen", "2022_10", "LIFTING", "Bracket_45", "CUBIC", "Standard", "Anzeige", "Ebene", "Gerichtet", "Baugr"}) {
                    const QByteArray text(leak);
                    if (entry.data.contains(text) || entry.data.contains(QByteArray(reinterpret_cast<const char*>(QString::fromLatin1(leak).utf16()), 2 * text.size()))) {
                        std::printf("  %s: «%s»\n", entry.name.constData(), leak);
                        clean = false;
                    }
                }
                if (matchSolidWorksAssemblyStream(entry.name, entry.data, 3, e)) ++blueprint;
            }
            check(clean, "в нашей сборке нет имён, путей и немецких названий из образцов");
            check(blueprint == streams.size(), "каждый поток чертежа нашей сборки совпадает с чертежом: " + std::to_string(blueprint));
        }
        const QString kept = dir.filePath("kept.SLDASM");
        QFile existing(kept);
        if (existing.open(QIODevice::WriteOnly)) { existing.write("keep"); existing.close(); }
        const bool refused = !writeSolidWorksImportedAssembly(kernel, {bodies.front()}, kept, e) && !e.isEmpty();
        check(refused && existing.open(QIODevice::ReadOnly) && existing.readAll() == "keep", "одно тело отклоняется, существующий файл не тронут");
    }

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
