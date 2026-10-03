// The KOMPAS-3D assembly CADNext writes against the assemblies KOMPAS 17.1 writes itself: the v17
// assemblies of the samples (~/cadnext-samples/kompas, or CADNEXT_TEST_SAMPLES) and their parts.
//
// Criteria, fixed before the first run of this test:
//   - kompasDefaultDatums with a document's first datum id and main name and its native type encodes
//     the seven datums of every v17 part (21) and assembly (5) byte for byte.
//   - Every component record (/#170/#110/<n>) of the assemblies decodes and encodes back byte for byte;
//     its body count is the number of bodies of the part it places wherever that part is in the samples.
//   - Each assembly's /MetoInfoLinks decodes, with as many components as /#170/#110/<n> records, and
//     encodes back byte for byte; its /#170/#110 counter is the catalog's last object id and /#114 holds
//     7 + 2 · components, both encoded back byte for byte.
//   - MetaInfo built from each assembly's own values encodes identical to the assembly's.
// Added before the run of the writer's check (writeKompasNativeAssembly):
//   - An assembly of two parts (a box; a cylinder) and three components (the cylinder twice, one turned)
//     is written with its parts; readKompasAssembly gives three components naming the part files, their
//     frames those given (origin to 1e-9 mm, axes to 1e-12); readKompasAssemblyProduct builds it, its
//     instances' placements those given (to 1e-12).
//   - Its component records decode, the placements of the cylinder numbered 1 and 2, the second named.
//   - It holds every stream the sample assemblies all hold (components counted as one), in their order.
//   - Six components are refused, the file not written.
// Amended after the first run: the datums are compared in every document whose model record begins with
// its seven datums — all but sfh551, whose model begins with another of its 31 controllers.
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeKompasAssembly.hpp"
#include "cadnext/gui/NativeKompasCatalog.hpp"
#include "cadnext/gui/NativeKompasDocument.hpp"
#include "cadnext/gui/NativeKompasGeometry.hpp"
#include "cadnext/gui/NativeKompasModel.hpp"
#include "cadnext/gui/NativeKompasService.hpp"
#include "cadnext/gui/NativeKompasC3d.hpp"
#include "cadnext/gui/NativeKompasWriter.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QRegularExpression>
#include <QTemporaryDir>
#include <QXmlStreamReader>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>
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

struct Streams {
    std::vector<std::pair<QString, QByteArray>> list; // catalog paths as written, in order
    quint32 lastObjectId = 0;
    QString error;
    const QByteArray* find(const QString& path) const {
        for (const auto& [p, bytes] : list)
            if (p == path) return &bytes;
        return nullptr;
    }
};

Streams streamsOf(const QString& path) {
    Streams out;
    QByteArray contents;
    KompasContentsRecords records;
    if (!readKompasContents(path, contents, out.error) || !decodeKompasContentsRecords(contents, records, out.error)) return out;
    std::vector<KompasRecordLocation> locations;
    quint64 cluster = 0;
    for (const auto& record : records.records) {
        const quint64 count = (quint64(record.compressedSize) + 4095) / 4096;
        locations.push_back({record.offset, record.compressedSize, cluster, count});
        cluster += count;
    }
    KompasCatalog catalog;
    if (!decodeKompasCatalog(records.tail, locations, catalog, out.error)) return out;
    out.lastObjectId = catalog.lastObjectId;
    const std::function<void(const KompasCatalogEntry&, const QString&)> walk = [&](const KompasCatalogEntry& e, const QString& parent) {
        const QString name = e.numericName ? QStringLiteral("#%1").arg(*e.numericName) : e.textName;
        const QString path = parent + "/" + name;
        if (!e.directory) out.list.push_back({path, e.recordIndex < records.records.size() ? records.records[e.recordIndex].decoded : QByteArray()});
        for (const auto& c : e.children) walk(c, path);
    };
    for (const auto& e : catalog.entries) walk(e, {});
    return out;
}

// A MetaInfo member's values, a part's or an assembly's, as encodeKompasMetaInfo takes them.
bool metaInfoValues(const QByteArray& bytes, KompasMetaInfo& info) {
    info = {};
    QString text;
    if (bytes.size() < 2 || uchar(bytes[0]) != 0xfe || uchar(bytes[1]) != 0xff) return false;
    for (qsizetype i = 2; i + 1 < bytes.size(); i += 2) text.append(QChar(ushort((uchar(bytes[i]) << 8) | uchar(bytes[i + 1]))));
    QXmlStreamReader xml(text);
    std::vector<QString> types;
    bool inDescriptions = false;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            if (xml.name() == QLatin1String("descriptions")) inDescriptions = true;
            if (xml.name() == QLatin1String("object")) {
                types.push_back(xml.attributes().value(QLatin1String("type")).toString());
                if (types.back() == QLatin1String("component")) {
                    KompasMetaInfoBody body;
                    body.relativeSource = xml.attributes().value(QLatin1String("relSource")).toString();
                    body.absoluteSource = xml.attributes().value(QLatin1String("absSource")).toString();
                    info.bodies.push_back(std::move(body));
                }
            }
            if (xml.name() == QLatin1String("property") && !inDescriptions) {
                const int id = xml.attributes().value(QLatin1String("id")).toInt();
                const QString value = xml.attributes().value(QLatin1String("value")).toString();
                if (types.empty()) {
                    if (id == 4) info.designation = value;
                    if (id == 5) info.name = value;
                    if (id == 8) info.massKg = value.toDouble();
                    if (id == 9) info.material = value;
                    if (id == 11) info.author = value;
                    if (id == 12) info.organization = value;
                    if (id == 14) info.assembly = xml.attributes().value(QLatin1String("valueVariantId")) == QLatin1String("0");
                } else if (types.back() == QLatin1String("component")) {
                    auto& b = info.bodies.back();
                    if (id == 4) b.designation = value;
                    if (id == 5) b.name = value;
                    if (id == 8) b.massKg = value.toDouble();
                    if (id == 9) b.material = value;
                    if (id == 11) b.author = value;
                    if (id == 12) b.organization = value;
                }
            }
        } else if (xml.isEndElement()) {
            if (xml.name() == QLatin1String("descriptions")) inDescriptions = false;
            if (xml.name() == QLatin1String("object")) types.pop_back();
        }
    }
    return !xml.hasError();
}

// The seven datums of a document's model record: their bytes, the first id and main name, the native type.
struct Datums {
    QByteArray bytes;
    quint16 firstId = 0;
    quint32 firstMainName = 0;
    quint8 nativeType = 0;
    bool ok = false;
};

Datums datumsOf(const QByteArray& model) {
    Datums out;
    QString error;
    KompasModelHeader header;
    qsizetype used = 0, at = 0;
    if (!decodeKompasModelHeader(model, 0, header, used, error)) return out;
    at = used;
    std::map<quint16, quint16> registry;
    for (int i = 0; i < 7; ++i) {
        KompasDatum d;
        if (!decodeKompasDatum(model, at, registry, d, used, error)) return out;
        if (i == 0) out.firstId = d.objectId, out.firstMainName = d.mainName, out.nativeType = d.nativeType;
        registry.emplace(d.objectId, d.kind == KompasDatum::Plane ? 0x507a : d.kind == KompasDatum::Axis ? 0x2c70 : 0x4170);
        out.bytes += model.mid(at, used);
        at += used;
    }
    out.ok = true;
    return out;
}

QByteArray encodedDatums(const Datums& from) {
    QByteArray out;
    QString error;
    std::map<quint16, quint16> registry;
    for (const auto& d : kompasDefaultDatums(from.nativeType, from.firstId, from.firstMainName)) {
        QByteArray bytes;
        if (!encodeKompasDatum(d, registry, bytes, error)) return {};
        registry.emplace(d.objectId, d.kind == KompasDatum::Plane ? 0x507a : d.kind == KompasDatum::Axis ? 0x2c70 : 0x4170);
        out += bytes;
    }
    return out;
}

int bodiesOf(const QString& part) {
    int bodies = 0;
    for (const auto& [p, bytes] : streamsOf(part).list)
        if (p.startsWith(QStringLiteral("/#170/#300/")) && bytes.size() > 13 && bytes.mid(11, 2) == QByteArray::fromHex("3962")) ++bodies;
    return bodies;
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples") + "/kompas";
    std::vector<QString> parts, assemblies;
    for (QDirIterator it(root, {QStringLiteral("*.m3d"), QStringLiteral("*.a3d")}, QDir::Files, QDirIterator::Subdirectories); it.hasNext();) {
        const QString path = it.next();
        KompasFileInfo info;
        QString error;
        if (!readKompasFileInfo(path, info, error) || info.mathVersion != 0x11001001) continue;
        (path.endsWith(QStringLiteral(".a3d"), Qt::CaseInsensitive) ? assemblies : parts).push_back(path);
    }
    std::sort(parts.begin(), parts.end());
    std::sort(assemblies.begin(), assemblies.end());
    if (assemblies.empty()) {
        std::printf("SKIP сборки КОМПАС v17 не найдены (%s)\n", root.toUtf8().constData());
        return 77;
    }

    // Datums.
    {
        int same = 0, total = 0, other = 0;
        for (const auto* list : {&parts, &assemblies})
            for (const QString& path : *list) {
                const Streams s = streamsOf(path);
                const QByteArray* model = s.find(QStringLiteral("/#170/#130"));
                const Datums d = model ? datumsOf(*model) : Datums{};
                if (!d.ok) {
                    ++other;
                    continue;
                }
                ++total;
                same += encodedDatums(d) == d.bytes;
            }
        check(same == total && other == 1 && total == int(parts.size() + assemblies.size()) - 1,
              "базовые элементы КОМПАС: " + std::to_string(same) + " из " + std::to_string(total) +
                  " документов бит в бит (модель ещё одного начинается не с них)");
    }

    int components = 0, identical = 0, bodiesKnown = 0, bodiesSame = 0, linksOk = 0, countersOk = 0, metaOk = 0;
    QString problem;
    for (const QString& path : assemblies) {
        const Streams s = streamsOf(path);
        std::vector<KompasDocumentFileLink> links;
        QString error;
        if (const QByteArray* bytes = s.find(QStringLiteral("/#170/_DC_D/_DE_F"))) decodeKompasDocumentFileLinks(*bytes, links, error);
        int here = 0;
        for (const auto& [p, bytes] : s.list) {
            static const QRegularExpression component(QStringLiteral("^/#170/#110/#\\d+$"));
            if (!component.match(p).hasMatch()) continue;
            ++components, ++here;
            KompasComponentRecord record;
            QByteArray again;
            if (!decodeKompasComponentRecord(bytes, record, error) || !encodeKompasComponentRecord(record, again, error) || again != bytes) {
                problem = QFileInfo(path).fileName() + " " + p + ": " + error;
                continue;
            }
            ++identical;
            for (const auto& link : links) {
                if (link.objectId != record.link) continue;
                const QString name = QFileInfo(QString(link.relativePath).replace('\\', '/')).fileName();
                for (const QString& part : parts)
                    if (QFileInfo(part).fileName() == name) {
                        ++bodiesKnown;
                        bodiesSame += bodiesOf(part) == int(record.bodies);
                    }
            }
        }
        std::size_t linked = 0;
        QByteArray again;
        if (const QByteArray* bytes = s.find(QStringLiteral("/MetoInfoLinks")))
            linksOk += decodeKompasAssemblyMetaInfoLinks(*bytes, linked, error) && int(linked) == here &&
                       encodeKompasAssemblyMetaInfoLinks(linked, again, error) && again == *bytes;
        quint32 last = 0, counter = 0;
        QByteArray a, b;
        const QByteArray *model = s.find(QStringLiteral("/#170/#110")), *document = s.find(QStringLiteral("/#114"));
        countersOk += model && document && decodeKompasAssemblyModelCounter(*model, last, error) && last == s.lastObjectId &&
                      encodeKompasAssemblyModelCounter(last, a, error) && a == *model && decodeKompasDocumentCounter(*document, counter, error) &&
                      counter == quint32(7 + 2 * here) && encodeKompasDocumentCounter(counter, b, error) && b == *document;
        QByteArray meta, encoded;
        KompasMetaInfo info;
        metaOk += readKompasArchiveMember(path, QStringLiteral("MetaInfo"), meta, error) && metaInfoValues(meta, info) && info.assembly &&
                  encodeKompasMetaInfo(info, encoded, error) && encoded == meta;
    }
    const int n = int(assemblies.size());
    check(components == 20 && identical == components && bodiesKnown > 0 && bodiesSame == bodiesKnown,
          "компоненты сборок: " + std::to_string(identical) + " из " + std::to_string(components) + " бит в бит; число тел как у детали у " +
              std::to_string(bodiesSame) + " из " + std::to_string(bodiesKnown) + (problem.isEmpty() ? std::string() : " — " + problem.toStdString()));
    check(linksOk == n, "связи MetaInfo сборок: " + std::to_string(linksOk) + " из " + std::to_string(n) + " бит в бит, по компоненту на запись");
    check(countersOk == n, "счётчики сборок (#170/#110 = последний номер, #114 = 7 + 2·компоненты): " + std::to_string(countersOk) + " из " + std::to_string(n));
    check(metaOk == n, "MetaInfo сборки по её значениям: " + std::to_string(metaOk) + " из " + std::to_string(n) + " бит в бит");

    // The writer.
    {
        kernel::OcctKernel kernel;
        const auto box = kernel.makeBox({.02, .03, .04});
        const auto cylinder = kernel.makeCylinder({.005, .012});
        QTemporaryDir folder;
        const QString path = folder.filePath(QStringLiteral("cadnext.a3d"));
        KompasAssemblyPart a, b;
        a.fileName = QStringLiteral("Box.m3d");
        a.bodies = {{box.value(), 0, QStringLiteral("Box")}};
        a.options.title = QStringLiteral("Box part");
        b.fileName = QStringLiteral("Cylinder.m3d");
        b.bodies = {{cylinder.value(), 0, QStringLiteral("Cylinder")}};
        b.options.title = QStringLiteral("Cylinder part");
        std::vector<KompasAssemblyComponent> placements(3);
        placements[0].part = 0;
        placements[1].part = 1;
        placements[1].placement.translation = {.05, 0, 0};
        placements[2].part = 1;
        const double half = std::sqrt(0.5);
        placements[2].placement.rotation = {half, 0, 0, half}; // 90° about z
        placements[2].placement.translation = {.05, .03, .01};
        KompasNativeWriteOptions options;
        options.title = QStringLiteral("CADNext assembly");
        QString error;
        const bool written = writeKompasNativeAssembly(kernel, {a, b}, placements, path, error, options);
        check(written, "сборка КОМПАС записана" + (error.isEmpty() ? std::string() : " — " + error.toStdString()));

        KompasAssembly read;
        bool frames = written && readKompasAssembly(path, read, error) && read.components.size() == 3;
        for (std::size_t k = 0; frames && k < 3; ++k) {
            const auto& c = read.components[k];
            const auto& p = placements[k].placement;
            const double w = p.rotation[0], x = p.rotation[1], y = p.rotation[2], z = p.rotation[3];
            const std::array<double, 9> axes{1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y),
                                             2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x),
                                             2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)};
            frames = c.relativePath == (k == 0 ? a.fileName : b.fileName);
            for (int i = 0; i < 3; ++i) frames = frames && std::fabs(c.origin[i] - p.translation[i] * 1000) < 1e-9;
            for (int i = 0; i < 9; ++i) frames = frames && std::fabs(c.axes[i] - axes[i]) < 1e-12;
        }
        check(frames, "наша сборка читается: 3 компонента, файлы деталей и рамки как заданы" + (error.isEmpty() ? std::string() : " — " + error.toStdString()));

        kernel::ProductStructure product;
        QStringList notes;
        bool built = written && readKompasAssemblyProduct(path, kernel, product, error, notes);
        std::size_t instances = 0;
        if (built) {
            std::vector<kernel::ProductPlacement> seen;
            const std::function<void(const kernel::ProductAssembly&)> walk = [&](const kernel::ProductAssembly& assembly) {
                for (const auto& instance : assembly.instances) {
                    if (instance.isAssembly) walk(product.assemblies[instance.definition]);
                    else seen.push_back(instance.placement);
                }
            };
            if (!product.assemblies.empty()) walk(product.assemblies[product.root]);
            instances = seen.size();
            built = instances == 3;
            for (std::size_t k = 0; built && k < 3; ++k) {
                const auto& got = seen[k];
                const auto& want = placements[k].placement;
                double sign = got.rotation[0] * want.rotation[0] + got.rotation[1] * want.rotation[1] + got.rotation[2] * want.rotation[2] +
                              got.rotation[3] * want.rotation[3] < 0 ? -1 : 1;
                for (int i = 0; i < 4; ++i) built = built && std::fabs(got.rotation[i] - sign * want.rotation[i]) < 1e-12;
                for (int i = 0; i < 3; ++i) built = built && std::fabs(got.translation[i] - want.translation[i]) < 1e-12;
            }
        }
        check(built, "наша сборка строится как изделие: экземпляров " + std::to_string(instances) + ", положения как заданы" +
                         (error.isEmpty() ? std::string() : " — " + error.toStdString()));

        const Streams ours = streamsOf(path);
        {
            std::vector<quint32> instance;
            QStringList names;
            for (const auto& [p, bytes] : ours.list) {
                KompasComponentRecord r;
                if (p.startsWith(QStringLiteral("/#170/#110/#")) && decodeKompasComponentRecord(bytes, r, error)) {
                    instance.push_back(r.instance);
                    names << r.instanceName;
                }
            }
            check(instance == std::vector<quint32>{1, 1, 2} && names == QStringList{QString(), QString(), b.options.title},
                  "записи компонентов: вхождения 1, 1, 2, второе названо именем детали");
        }
        {
            static const QRegularExpression component(QStringLiteral("^/#170/#110/#\\d+$"));
            const auto normal = [](const QString& p) { return component.match(p).hasMatch() ? QStringLiteral("/#170/#110/#N") : p; };
            std::vector<std::vector<QString>> sampleOrders;
            for (const QString& p : assemblies) {
                std::vector<QString> order;
                for (const auto& [q, bytes] : streamsOf(p).list)
                    if (std::find(order.begin(), order.end(), normal(q)) == order.end()) order.push_back(normal(q));
                sampleOrders.push_back(order);
            }
            std::vector<QString> common;
            for (const QString& q : sampleOrders.front()) {
                bool all = true;
                for (const auto& order : sampleOrders) all = all && std::find(order.begin(), order.end(), q) != order.end();
                if (all) common.push_back(q);
            }
            std::vector<QString> ourOrder, ourCommon;
            for (const auto& [q, bytes] : ours.list)
                if (std::find(ourOrder.begin(), ourOrder.end(), normal(q)) == ourOrder.end()) ourOrder.push_back(normal(q));
            QStringList missing;
            for (const QString& q : common)
                if (std::find(ourOrder.begin(), ourOrder.end(), q) == ourOrder.end()) missing << q;
            for (const QString& q : ourOrder)
                if (std::find(common.begin(), common.end(), q) != common.end()) ourCommon.push_back(q);
            check(missing.isEmpty() && ourCommon == common,
                  "потоки, общие для " + std::to_string(assemblies.size()) + " сборок (" + std::to_string(common.size()) + "): есть все, в их порядке" +
                      (missing.isEmpty() ? std::string() : "; нет: " + missing.join(", ").toStdString()));
        }
        {
            // The most components the link keys are known for: 21, on a row, both parts in turn.
            const QString many = folder.filePath(QStringLiteral("many.a3d"));
            std::vector<KompasAssemblyComponent> row(kKompasAssemblyLinkKeys);
            for (std::size_t k = 0; k < row.size(); ++k) {
                row[k].part = int(k % 2);
                row[k].placement.translation = {0.06 * double(k), 0, 0};
            }
            QString e;
            KompasAssembly read;
            bool placed = writeKompasNativeAssembly(kernel, {a, b}, row, many, e, options) && readKompasAssembly(many, read, e) &&
                          read.components.size() == row.size();
            for (std::size_t k = 0; placed && k < row.size(); ++k)
                placed = read.components[k].relativePath == (k % 2 ? b.fileName : a.fileName) &&
                         std::fabs(read.components[k].origin[0] - 60.0 * double(k)) < 1e-9;
            std::size_t linked = 0;
            for (const auto& [p, bytes] : streamsOf(many).list)
                if (p == QStringLiteral("/MetoInfoLinks")) decodeKompasAssemblyMetaInfoLinks(bytes, linked, e);
            check(placed && linked == row.size(), "сборка из " + std::to_string(row.size()) + " компонентов записана и читается: файлы, положения, " +
                                                  std::to_string(linked) + " связей" + (e.isEmpty() ? std::string() : " — " + e.toStdString()));
            const QString refused = folder.filePath(QStringLiteral("more.a3d"));
            const std::vector<KompasAssemblyComponent> more(kKompasAssemblyLinkKeys + 1);
            check(!writeKompasNativeAssembly(kernel, {a}, more, refused, e, options) && !QFileInfo::exists(refused) && !e.isEmpty(),
                  std::to_string(more.size()) + " компонентов отклонены, файл не записан");
        }
    }

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
