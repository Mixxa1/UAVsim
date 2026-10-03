// The KOMPAS-3D part document CADNext writes (writeKompasNativeDocument) against the parts KOMPAS 17.1
// writes itself: every v17 part of the samples (~/cadnext-samples/kompas, or CADNEXT_TEST_SAMPLES).
//
// Criteria, fixed before the first run of this test:
//   - Each service record (NativeKompasService.hpp) of every v17 sample part decodes with its codec, and
//     the codec encodes it back byte for byte; so does the layer table (/#270).
//   - The codecs round-trip their own output and refuse a record with any one byte changed.
// Amended after the first run: a changed byte of a layer's name, colour or material is another valid
// layer, not a damaged record (the first form excepted colour and material only, the name forgotten).
//   - A document written by CADNext (a box and a cylinder) holds every catalog stream that all the v17
//     sample parts hold (body-numbered names taken as one), except those listed below as not yet
//     authored — the list the following phases empty — and holds them in the samples' order.
//   - The written document reads back: its two solids, valid, with their volumes within 1e-12.
// Added before the run of phase K2a (properties and MetaInfo):
//   - The standard property definitions (/_ADDPROP_D/_ADDPROP_F) and display lists (/_ADDPROP_TUNING_D/
//     _ADDPROP_TUNING_F) encode identical to every sample's, byte for byte.
//   - MetaInfo built from each sample's own values (its document's designation, name, mass, material,
//     author, organization; each component's name, mass, material) encodes identical to the sample's.
//   - Each sample's /MetoInfoLinks decodes and encodes back identical, with as many bodies as its
//     MetaInfo has components.
// Added before the run of phase K2b (dates, authors, the most common profile of four records):
//   - /#114, /#170/#109, /#140 and /_DUS_D/_DUS_F decode and encode back byte for byte in exactly the
//     samples that share the most common profile — 17, 19, 18 and 14 of the 21 — and are refused in the rest.
//   - /_KD_I/_DI_D (dates) of all 21 and /_KD_I/_DI_C (authors) of the 20 that have it decode and
//     encode back byte for byte.
// Added before the run of the model counters' check:
//   - The four counter records of every sample decode and encode back byte for byte, #201 being the
//     catalog's last object id and #110 the id of the numbered shell the first /#170/#300 entry defines.
// Amended after that run: #110 is the id of the first numbered object of the first /#170/#300 entry that
// holds a shell — the shell in 19 samples; in the two sfh parts the first entries are stubs of removed
// bodies, and the shell of the body that is left is not numbered, its first face is.
// Added before the run of the representations' and designation's checks:
//   - Every sample's /_KD_I/_SA_DN/_RR_FN decodes to the four standard representations (names and kinds
//     as kompasStandardRepresentations gives them, keys 100 apart) and encodes back byte for byte.
//   - /#204 decodes and encodes back byte for byte in the 14 samples whose /_DUS_D/_DUS_F has the
//     supported profile, its designation being MetaInfo's property 4 (empty where MetaInfo has none);
//     it is refused in the other 7.
// Added before the run of the text style table's check:
//   - Every sample's /#250 decodes (with the default table as its layout) and encodes back byte for byte;
//     18 are the default table byte for byte, the other 3 differ from it in one byte.
// Added before the run of the display meshes' check:
//   - The 35 meshes (/#170/#157/#303/N/Triangle) of the samples decode and encode back byte for byte, and
//     each grid's step is kompasMeshStep of its model's box diagonal (to 1e-9 relative).
//   - Each body of the written document has a mesh with one grid per face, the k-th named [main name,
//     k + 1]; its volume by the divergence theorem (which needs the triangles turned outward) and its area
//     within 1 % of the body's, every point within the sag + 1e-3 mm of the body.
// Added before the run of the preview's check:
//   - Every sample's Preview member decodes (its LZW strips by our decoder), its texts being MetaInfo's
//     designation (empty where none), name and author and an empty one; encoded again by our encoder and
//     decoded, it gives the same pixels, sizes and texts.
//   - The written document's Preview decodes to the picture renderKompasPreview draws of its meshes, not
//     blank, with its name in the texts.
//   - The written document's MetaInfo is the one encodeKompasMetaInfo gives for its bodies, its
//     /MetoInfoLinks names their body numbers in order, and its property records are the standard ones.
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeKompasC3d.hpp"
#include "cadnext/gui/NativeKompasCatalog.hpp"
#include "cadnext/gui/NativeKompasDocument.hpp"
#include "cadnext/gui/NativeKompasGeometry.hpp"
#include "cadnext/gui/NativeKompasService.hpp"
#include "cadnext/gui/NativeKompasTextStyles.hpp"
#include "cadnext/gui/NativeKompasMesh.hpp"
#include "cadnext/gui/NativeKompasPreview.hpp"
#include "cadnext/gui/NativeKompasWriter.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QRegularExpression>
#include <QTemporaryDir>
#include <QXmlStreamReader>

#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <gp_Pnt.hxx>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <tuple>
#include <vector>

using namespace cadnext;
using namespace cadnext::gui;

namespace {

int failures = 0;

void check(bool ok, const std::string& what) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what.c_str());
    if (!ok) ++failures;
}

// A document's streams: each catalog path (body numbers as 'N') with its record, in catalog order.
struct Streams {
    std::vector<std::pair<QString, QByteArray>> list;
    QString error;
    quint32 lastObjectId = 0;
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
    static const QRegularExpression number(QStringLiteral("^\\d+$"));
    const std::function<void(const KompasCatalogEntry&, const QString&)> walk = [&](const KompasCatalogEntry& e, const QString& parent) {
        QString name = e.numericName ? QStringLiteral("#%1").arg(*e.numericName) : e.textName;
        if (!e.numericName && number.match(e.textName).hasMatch()) name = QStringLiteral("N");
        const QString path = parent + "/" + name;
        if (!e.directory) out.list.push_back({path, e.recordIndex < records.records.size() ? records.records[e.recordIndex].decoded : QByteArray()});
        for (const auto& c : e.children) walk(c, path);
    };
    for (const auto& e : catalog.entries) walk(e, {});
    return out;
}

const std::vector<std::pair<QString, KompasServiceRecord>> kService{
    {QStringLiteral("/#113"), KompasServiceRecord::ApplicationVersion},
    {QStringLiteral("/#170/#155/#100"), KompasServiceRecord::ModelSet100},
    {QStringLiteral("/#170/#155/#500"), KompasServiceRecord::ModelSet500},
    {QStringLiteral("/#170/#155/#700"), KompasServiceRecord::ModelSet700},
    {QStringLiteral("/#170/#180"), KompasServiceRecord::Model180},
    {QStringLiteral("/#170/#210"), KompasServiceRecord::Model210},
    {QStringLiteral("/#205"), KompasServiceRecord::Document205},
    {QStringLiteral("/#230/#230"), KompasServiceRecord::Document230},
    {QStringLiteral("/#260"), KompasServiceRecord::Document260},
    {QStringLiteral("/#280"), KompasServiceRecord::Document280},
    {QStringLiteral("/#290"), KompasServiceRecord::Document290},
    {QStringLiteral("/_KD_I/_PW_DN/_PW_FN"), KompasServiceRecord::Passwords},
};

// Streams of the v17 parts not yet authored by the writer: the next phases' work.
const std::set<QString> kNotYetAuthored{};


// A sample's MetaInfo values, as encodeKompasMetaInfo takes them.
bool metaInfoValues(const QByteArray& bytes, KompasMetaInfo& info) {
    info = {};
    QString text;
    if (bytes.size() < 2 || uchar(bytes[0]) != 0xfe || uchar(bytes[1]) != 0xff) return false;
    for (qsizetype i = 2; i + 1 < bytes.size(); i += 2) text.append(QChar(ushort((uchar(bytes[i]) << 8) | uchar(bytes[i + 1]))));
    QXmlStreamReader xml(text);
    std::vector<QString> types;
    int propertiesDepth = 0;
    bool inDescriptions = false;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            if (xml.name() == QLatin1String("descriptions")) inDescriptions = true;
            if (xml.name() == QLatin1String("object")) {
                types.push_back(xml.attributes().value(QLatin1String("type")).toString());
                if (types.back() == QLatin1String("component")) info.bodies.push_back({});
            }
            if (xml.name() == QLatin1String("properties")) ++propertiesDepth;
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
                } else if (types.back() == QLatin1String("component")) {
                    if (id == 5) info.bodies.back().name = value;
                    if (id == 8) info.bodies.back().massKg = value.toDouble();
                    if (id == 9) info.bodies.back().material = value;
                }
            }
        } else if (xml.isEndElement()) {
            if (xml.name() == QLatin1String("descriptions")) inDescriptions = false;
            if (xml.name() == QLatin1String("object")) types.pop_back();
        }
    }
    return !xml.hasError();
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);

    // Round trips and refusals.
    {
        bool ok = true, refused = true;
        for (const auto& [path, kind] : kService) {
            QByteArray bytes;
            QString error;
            quint32 version = 0;
            ok = ok && encodeKompasServiceRecord(kind, 0x11001011, bytes, error) && decodeKompasServiceRecord(kind, bytes, version, error) &&
                 (kind != KompasServiceRecord::ApplicationVersion || version == 0x11001011);
            for (qsizetype i = 0; i < bytes.size(); ++i) {
                QByteArray changed = bytes;
                changed[i] = char(changed[i] ^ 0x5a);
                refused = refused && !decodeKompasServiceRecord(kind, changed, version, error);
            }
        }
        std::vector<KompasLayer> layers;
        QByteArray bytes;
        QString error;
        ok = ok && encodeKompasLayers({KompasLayer{}}, bytes, error) && decodeKompasLayers(bytes, layers, error) && layers.size() == 1 &&
             layers[0].name == KompasLayer{}.name && layers[0].color == 0x909090;
        for (qsizetype i = 0; i < bytes.size(); ++i) {
            QByteArray changed = bytes;
            changed[i] = char(changed[i] ^ 0x5a);
            std::vector<KompasLayer> decoded;
            // A changed byte of the layer's name, colour or material is another valid layer; any other is refused.
            if (decodeKompasLayers(changed, decoded, error))
                refused = refused && (decoded[0].name != KompasLayer{}.name || decoded[0].color != 0x909090 ||
                                      decoded[0].material != KompasLayer{}.material);
        }
        check(ok, "служебные записи и таблица слоёв: собственная запись читается обратно");
        check(refused, "служебные записи: любой изменённый байт отклоняется (у слоя байт имени, цвета или материала даёт другой слой)");
    }

    // The samples.
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples") + "/kompas";
    std::vector<QString> parts;
    for (QDirIterator it(root, {QStringLiteral("*.m3d"), QStringLiteral("*.M3D")}, QDir::Files, QDirIterator::Subdirectories); it.hasNext();) {
        const QString path = it.next();
        KompasFileInfo info;
        QString error;
        if (readKompasFileInfo(path, info, error) && info.mathVersion == 0x11001001) parts.push_back(path);
    }
    std::sort(parts.begin(), parts.end());
    std::vector<Streams> samples;
    for (const QString& path : parts) samples.push_back(streamsOf(path));

    if (parts.empty()) {
        std::printf("SKIP образцы КОМПАС v17 не найдены (%s)\n", root.toUtf8().constData());
    } else {
        int decoded = 0, identical = 0, total = 0;
        int layerDecoded = 0, layerIdentical = 0;
        QString problem;
        for (std::size_t f = 0; f < samples.size(); ++f) {
            if (!samples[f].error.isEmpty()) problem = QFileInfo(parts[f]).fileName() + ": " + samples[f].error;
            for (const auto& [path, bytes] : samples[f].list) {
                for (const auto& [servicePath, kind] : kService) {
                    if (path != servicePath) continue;
                    ++total;
                    quint32 version = 0;
                    QString error;
                    QByteArray again;
                    if (decodeKompasServiceRecord(kind, bytes, version, error)) {
                        ++decoded;
                        identical += encodeKompasServiceRecord(kind, version, again, error) && again == bytes;
                    } else {
                        problem = QFileInfo(parts[f]).fileName() + " " + path + ": " + error;
                    }
                }
                if (path == QStringLiteral("/#270")) {
                    std::vector<KompasLayer> layers;
                    QString error;
                    QByteArray again;
                    if (decodeKompasLayers(bytes, layers, error)) {
                        ++layerDecoded;
                        layerIdentical += encodeKompasLayers(layers, again, error) && again == bytes;
                    }
                }
            }
        }
        check(total == int(samples.size() * kService.size()) && decoded == total && identical == total,
              "служебные записи " + std::to_string(samples.size()) + " деталей v17: " + std::to_string(decoded) + " из " +
                  std::to_string(total) + " прочитаны, " + std::to_string(identical) + " записаны обратно бит в бит" +
                  (problem.isEmpty() ? std::string() : " — " + problem.toStdString()));
        check(layerDecoded == int(samples.size()) && layerIdentical == layerDecoded,
              "таблица слоёв: " + std::to_string(layerDecoded) + " из " + std::to_string(samples.size()) + " прочитаны, " +
                  std::to_string(layerIdentical) + " записаны обратно бит в бит");
    }

    // Phase K2b: the most common profile of four records, dates and authors.
    if (!parts.empty()) {
        const std::vector<std::tuple<QString, KompasServiceRecord, int>> common{
            {QStringLiteral("/#114"), KompasServiceRecord::Document114, 17},
            {QStringLiteral("/#170/#109"), KompasServiceRecord::Model109, 19},
            {QStringLiteral("/#140"), KompasServiceRecord::View, 18},
            {QStringLiteral("/_DUS_D/_DUS_F"), KompasServiceRecord::UserSettings, 14}};
        for (const auto& [path, kind, expected] : common) {
            int decoded = 0, identical = 0;
            for (const auto& sample : samples)
                for (const auto& [p, bytes] : sample.list) {
                    if (p != path) continue;
                    quint32 version;
                    QString error;
                    QByteArray again;
                    if (!decodeKompasServiceRecord(kind, bytes, version, error)) continue;
                    ++decoded;
                    identical += encodeKompasServiceRecord(kind, 0, again, error) && again == bytes;
                }
            check(decoded == expected && identical == expected, path.toStdString() + ": профиль большинства у " + std::to_string(decoded) +
                                                                     " деталей (ожидается " + std::to_string(expected) + "), бит в бит у " +
                                                                     std::to_string(identical) + ", остальные отклонены");
        }
        int dates = 0, datesSame = 0, authors = 0, authorsSame = 0, withAuthors = 0;
        for (const auto& sample : samples)
            for (const auto& [p, bytes] : sample.list) {
                QString error;
                QByteArray again;
                if (p == QStringLiteral("/_KD_I/_DI_D")) {
                    KompasDocumentDates d;
                    if (decodeKompasDocumentDates(bytes, d, error)) ++dates, datesSame += encodeKompasDocumentDates(d, again, error) && again == bytes;
                }
                if (p == QStringLiteral("/_KD_I/_DI_C")) {
                    ++withAuthors;
                    std::vector<KompasDocumentAuthor> a;
                    if (decodeKompasDocumentAuthors(bytes, a, error)) ++authors, authorsSame += encodeKompasDocumentAuthors(a, again, error) && again == bytes;
                }
            }
        const int n = int(samples.size());
        check(dates == n && datesSame == n, "даты документа: " + std::to_string(datesSame) + " из " + std::to_string(n) + " бит в бит");
        check(withAuthors == n - 1 && authors == withAuthors && authorsSame == withAuthors,
              "авторы документа: " + std::to_string(authorsSame) + " из " + std::to_string(withAuthors) + " бит в бит");
    }

    // The model's counters.
    if (!parts.empty()) {
        int ok = 0;
        QString problem;
        for (std::size_t f = 0; f < samples.size(); ++f) {
            const Streams& sample = samples[f];
            const QByteArray *shell = sample.find(QStringLiteral("/#170/#110")), *last = sample.find(QStringLiteral("/#170/#200/#201")),
                             *layout = sample.find(QStringLiteral("/#170/#202")), *instances = sample.find(QStringLiteral("/#170/LayoutInstances")),
                             *body = nullptr;
            // The first body entry holding a shell (others can be stubs of removed bodies), and in it the first
            // numbered object: the shell itself, or when the shell is not numbered, its first face.
            for (const auto& [p, bytes] : sample.list)
                if (!body && p == QStringLiteral("/#170/#300/N") && bytes.size() > 13 && bytes.mid(11, 2) == QByteArray::fromHex("3962")) body = &bytes;
            if (!shell || !last || !layout || !instances || !body) continue;
            KompasModelCounters counters;
            KompasModelCounterRecords again;
            QString error;
            quint32 shellId = 0;
            for (qsizetype at = 9; at + 6 < body->size() && !shellId; ++at)
                if (uchar((*body)[at]) == 2 && uchar((*body)[at + 1]) == 0x80 && uchar((*body)[at + 4]) == 1)
                    shellId = quint32(uchar((*body)[at + 5]) | (uchar((*body)[at + 6]) << 8));
            if (decodeKompasModelCounters({*shell, *last, *layout, *instances}, counters, error) && counters.lastObjectId == sample.lastObjectId &&
                counters.firstBodyShell == shellId && encodeKompasModelCounters(counters, again, error) && again.firstBodyShell == *shell &&
                again.lastObjectId == *last && again.layout == *layout && again.layoutInstances == *instances)
                ++ok;
            else
                problem = QFileInfo(parts[f]).fileName() + ": " + error;
        }
        check(ok == int(samples.size()), "счётчики модели: " + std::to_string(ok) + " из " + std::to_string(samples.size()) +
                                             " — #201 = последний номер каталога, #110 = оболочка первого тела, бит в бит" +
                                             (problem.isEmpty() ? std::string() : " — " + problem.toStdString()));
    }

    // Representations and the designation record.
    if (!parts.empty()) {
        int representations = 0, designations = 0, refused = 0;
        QString problem;
        for (std::size_t f = 0; f < samples.size(); ++f) {
            QString error;
            QByteArray again;
            if (const QByteArray* bytes = samples[f].find(QStringLiteral("/_KD_I/_SA_DN/_RR_FN"))) {
                std::vector<KompasRepresentation> list;
                if (decodeKompasRepresentations(*bytes, list, error) && list.size() == 4) {
                    const auto standard = kompasStandardRepresentations(list[0].key);
                    bool same = true;
                    for (std::size_t i = 0; i < 4; ++i)
                        same = same && list[i].name == standard[i].name && list[i].kind == standard[i].kind && list[i].key == standard[i].key;
                    representations += same && encodeKompasRepresentations(list, again, error) && again == *bytes;
                } else {
                    problem = QFileInfo(parts[f]).fileName() + " _RR_FN: " + error;
                }
            }
            const QByteArray* settings = samples[f].find(QStringLiteral("/_DUS_D/_DUS_F"));
            quint32 version;
            const bool supported = settings && decodeKompasServiceRecord(KompasServiceRecord::UserSettings, *settings, version, error);
            if (const QByteArray* bytes = samples[f].find(QStringLiteral("/#204"))) {
                QString designation;
                QByteArray meta;
                KompasMetaInfo info;
                const bool decoded = decodeKompasDesignationRecord(*bytes, designation, error);
                if (!supported) {
                    refused += !decoded;
                } else if (decoded && readKompasArchiveMember(parts[f], QStringLiteral("MetaInfo"), meta, error) && metaInfoValues(meta, info) &&
                           designation == info.designation.value_or(QString()) && encodeKompasDesignationRecord(designation, again, error) &&
                           again == *bytes) {
                    ++designations;
                } else {
                    problem = QFileInfo(parts[f]).fileName() + " #204: " + error;
                }
            }
        }
        check(representations == int(samples.size()), "представления документа: " + std::to_string(representations) + " из " +
                                                           std::to_string(samples.size()) + " — четыре стандартных, бит в бит" +
                                                           (problem.isEmpty() ? std::string() : " — " + problem.toStdString()));
        check(designations == 14 && refused == int(samples.size()) - 14,
              "#204: " + std::to_string(designations) + " из 14 бит в бит, обозначение как свойство 4 MetaInfo; " + std::to_string(refused) +
                  " с другим профилем отклонены");
    }

    // The text style table.
    if (!parts.empty()) {
        QByteArray defaults;
        QString error;
        encodeKompasTextStyles(kompasDefaultTextStyles(), defaults, error);
        int decoded = 0, identical = 0, asDefault = 0, oneByte = 0;
        for (const auto& sample : samples) {
            const QByteArray* bytes = sample.find(QStringLiteral("/#250"));
            KompasTextStyleTable table;
            QByteArray again;
            if (!bytes || !decodeKompasTextStyles(*bytes, table, error)) continue;
            ++decoded;
            identical += encodeKompasTextStyles(table, again, error) && again == *bytes;
            if (*bytes == defaults) {
                ++asDefault;
            } else if (bytes->size() == defaults.size()) {
                int differ = 0;
                for (qsizetype i = 0; i < defaults.size(); ++i) differ += (*bytes)[i] != defaults[i];
                oneByte += differ == 1;
            }
        }
        const int n = int(samples.size());
        check(decoded == n && identical == n && asDefault == 18 && oneByte == 3,
              "таблица текстовых стилей: " + std::to_string(identical) + " из " + std::to_string(n) + " бит в бит; умолчаниям равны " +
                  std::to_string(asDefault) + ", на один байт отличаются " + std::to_string(oneByte));
    }

    // Display meshes of the samples.
    if (!parts.empty()) {
        int meshes = 0, identical = 0, steps = 0;
        QString problem;
        for (std::size_t f = 0; f < samples.size(); ++f) {
            std::vector<KompasMesh> decoded;
            for (const auto& [p, bytes] : samples[f].list) {
                if (!p.endsWith(QStringLiteral("/Triangle"))) continue;
                ++meshes;
                KompasMesh mesh;
                QByteArray again;
                QString error;
                if (decodeKompasMesh(bytes, mesh, error) && encodeKompasMesh(mesh, again, error) && again == bytes) {
                    ++identical;
                    decoded.push_back(std::move(mesh));
                } else {
                    problem = QFileInfo(parts[f]).fileName() + " " + p + ": " + error;
                }
            }
            double low[3] = {1e300, 1e300, 1e300}, high[3] = {-1e300, -1e300, -1e300};
            bool any = false;
            for (const auto& m : decoded) {
                std::size_t grids = 0;
                for (const auto& g : m.curved) grids += g.grids.size();
                for (const auto& g : m.planar) grids += g.grids.size();
                if (!grids) continue;
                any = true;
                for (int a = 0; a < 3; ++a) low[a] = std::min(low[a], m.box[a]), high[a] = std::max(high[a], m.box[a + 3]);
            }
            if (!any) continue;
            const double diagonal = std::sqrt((high[0] - low[0]) * (high[0] - low[0]) + (high[1] - low[1]) * (high[1] - low[1]) +
                                              (high[2] - low[2]) * (high[2] - low[2]));
            const auto expected = kompasMeshStep(diagonal);
            bool same = true;
            for (const auto& m : decoded)
                for (const auto* list : {&m.curved, &m.planar})
                    for (const auto& g : *list)
                        for (const auto& grid : g.grids)
                            same = same && std::fabs(grid.step[0] / expected[0] - 1) < 1e-9 && std::fabs(grid.step[1] - expected[1]) < 1e-12 &&
                                   grid.step[2] == expected[2];
            steps += same;
        }
        check(meshes == 35 && identical == meshes && steps == int(samples.size()),
              "сетки отображения: " + std::to_string(identical) + " из " + std::to_string(meshes) + " бит в бит; шаг как kompasMeshStep в " +
                  std::to_string(steps) + " из " + std::to_string(samples.size()) + " деталей" +
                  (problem.isEmpty() ? std::string() : " — " + problem.toStdString()));
    }

    // Previews of the samples.
    if (!parts.empty()) {
        int decoded = 0, same = 0, texts = 0;
        QString problem;
        for (const QString& part : parts) {
            QByteArray member, meta, again;
            QString error;
            KompasPreview preview, back;
            KompasMetaInfo info;
            if (!readKompasArchiveMember(part, QStringLiteral("Preview"), member, error) || !decodeKompasPreview(member, preview, error)) {
                problem = QFileInfo(part).fileName() + ": " + error;
                continue;
            }
            ++decoded;
            same += encodeKompasPreview(preview, again, error) && decodeKompasPreview(again, back, error) && back.image.rgb == preview.image.rgb &&
                    back.image.width == preview.image.width && back.image.height == preview.image.height && back.sizeA == preview.sizeA &&
                    back.sizeB == preview.sizeB && back.name == preview.name && back.author == preview.author;
            texts += readKompasArchiveMember(part, QStringLiteral("MetaInfo"), meta, error) && metaInfoValues(meta, info) &&
                     preview.designation == info.designation.value_or(QString()) && preview.name == info.name &&
                     preview.author == info.author.value_or(QString()) && preview.comment.isEmpty();
        }
        const int n = int(parts.size());
        check(decoded == n && same == n && texts == n, "миниатюры: " + std::to_string(decoded) + " из " + std::to_string(n) +
                                                           " прочитаны нашим LZW, " + std::to_string(same) + " переписаны и прочитаны обратно без изменений, подписи как в MetaInfo у " +
                                                           std::to_string(texts) + (problem.isEmpty() ? std::string() : " — " + problem.toStdString()));
    }

    // Phase K2a: the standard properties, MetaInfo and its links, against every sample.
    if (!parts.empty()) {
        QByteArray definitions, tuning;
        QString error;
        encodeKompasPropertyDefinitions(kompasStandardPropertyDefinitions(), definitions, error);
        encodeKompasPropertyTuning(kompasStandardPropertyTuning(), tuning, error);
        int sameDefinitions = 0, sameTuning = 0, sameMeta = 0, sameLinks = 0;
        QString problem;
        for (std::size_t f = 0; f < samples.size(); ++f) {
            for (const auto& [path, bytes] : samples[f].list) {
                if (path == QStringLiteral("/_ADDPROP_D/_ADDPROP_F")) sameDefinitions += bytes == definitions;
                if (path == QStringLiteral("/_ADDPROP_TUNING_D/_ADDPROP_TUNING_F")) sameTuning += bytes == tuning;
            }
            QByteArray meta, encoded;
            KompasMetaInfo info;
            if (!readKompasArchiveMember(parts[f], QStringLiteral("MetaInfo"), meta, error) || !metaInfoValues(meta, info) ||
                !encodeKompasMetaInfo(info, encoded, error)) {
                problem = QFileInfo(parts[f]).fileName() + ": " + error;
            } else if (encoded == meta) {
                ++sameMeta;
            } else {
                qsizetype at = 0;
                while (at < encoded.size() && at < meta.size() && encoded[at] == meta[at]) ++at;
                problem = QFileInfo(parts[f]).fileName() + QStringLiteral(": MetaInfo расходится с байта %1 (%2 и %3 байт)").arg(at).arg(encoded.size()).arg(meta.size());
            }
            for (const auto& [path, bytes] : samples[f].list) {
                if (path != QStringLiteral("/MetoInfoLinks")) continue;
                std::vector<quint32> numbers;
                QByteArray again;
                sameLinks += decodeKompasMetaInfoLinks(bytes, numbers, error) && numbers.size() == info.bodies.size() &&
                             encodeKompasMetaInfoLinks(numbers, again, error) && again == bytes;
            }
        }
        const int n = int(samples.size());
        check(sameDefinitions == n && sameTuning == n, "стандартные свойства: определения как у " + std::to_string(sameDefinitions) + " из " +
                                                           std::to_string(n) + " деталей, списки показа как у " + std::to_string(sameTuning) + ", бит в бит");
        check(sameMeta == n, "MetaInfo по значениям детали совпадает бит в бит у " + std::to_string(sameMeta) + " из " + std::to_string(n) +
                                 (problem.isEmpty() ? std::string() : " — " + problem.toStdString()));
        check(sameLinks == n, "MetoInfoLinks: " + std::to_string(sameLinks) + " из " + std::to_string(n) +
                                  " прочитаны и записаны обратно бит в бит, тел столько же, сколько компонентов MetaInfo");
    }

    // A document of our own.
    kernel::OcctKernel kernel;
    const auto box = kernel.makeBox({.02, .03, .04});
    const auto cylinder = kernel.makeCylinder({.005, .012});
    QTemporaryDir folder;
    const QString path = folder.filePath(QStringLiteral("cadnext.m3d"));
    QString error;
    const bool written = box.isOk() && cylinder.isOk() &&
                         writeKompasNativeDocument(kernel, {{box.value(), 0, QStringLiteral("Box")}, {cylinder.value(), 0, QStringLiteral("Cylinder")}},
                                                   path, error);
    check(written, "документ КОМПАС записан" + (error.isEmpty() ? std::string() : " — " + error.toStdString()));
    const Streams ours = streamsOf(path);
    {
        KompasC3dResult restored;
        bool ok = written && readKompasC3dSolids(path, kernel, restored, error) && restored.solids.size() == 2;
        for (std::size_t i = 0; ok && i < 2; ++i) {
            const auto mass = kernel.volumeProperties(restored.solids[i].shape);
            const double expected = i == 0 ? .02 * .03 * .04 : M_PI * .005 * .005 * .012;
            ok = kernel.isShapeValid(restored.solids[i].shape) && mass.isOk() && std::fabs(mass.value().volumeM3 / expected - 1) < 1e-12;
        }
        check(ok, "записанный документ читается: два верных тела, объёмы до 1e-12");
    }
    {
        bool ok = written;
        QByteArray meta, expected, definitions, tuning, links;
        KompasMetaInfo info;
        info.name = KompasNativeWriteOptions{}.title;
        info.material = KompasNativeWriteOptions{}.materialName;
        info.bodies = {{QStringLiteral("Box"), 0, info.material}, {QStringLiteral("Cylinder"), 0, info.material}};
        ok = ok && readKompasArchiveMember(path, QStringLiteral("MetaInfo"), meta, error) && encodeKompasMetaInfo(info, expected, error) &&
             meta == expected;
        encodeKompasPropertyDefinitions(kompasStandardPropertyDefinitions(), definitions, error);
        encodeKompasPropertyTuning(kompasStandardPropertyTuning(), tuning, error);
        int found = 0;
        for (const auto& [p, bytes] : ours.list) {
            if (p == QStringLiteral("/_ADDPROP_D/_ADDPROP_F")) found += bytes == definitions;
            if (p == QStringLiteral("/_ADDPROP_TUNING_D/_ADDPROP_TUNING_F")) found += bytes == tuning;
            std::vector<quint32> numbers;
            if (p == QStringLiteral("/MetoInfoLinks")) found += decodeKompasMetaInfoLinks(bytes, numbers, error) && numbers == std::vector<quint32>{1, 2};
        }
        KompasModelInfo model;
        ok = ok && found == 3 && readKompasModelInfo(path, model, error) && model.objects == QStringList{QStringLiteral("Box"), QStringLiteral("Cylinder")};
        check(ok, "наш документ: MetaInfo как у КОМПАС для его тел, стандартные свойства, MetoInfoLinks с телами 1 и 2");
    }
    // Our document's preview.
    {
        QByteArray member;
        KompasPreview preview;
        std::vector<KompasMesh> meshes;
        for (const auto& [p, bytes] : ours.list) {
            KompasMesh mesh;
            if (p.endsWith(QStringLiteral("/Triangle")) && decodeKompasMesh(bytes, mesh, error)) meshes.push_back(std::move(mesh));
        }
        const bool ok = written && readKompasArchiveMember(path, QStringLiteral("Preview"), member, error) && decodeKompasPreview(member, preview, error);
        const KompasPreviewImage drawn = renderKompasPreview(meshes, KompasNativeWriteOptions{}.color);
        std::size_t inked = 0;
        for (std::size_t i = 0; ok && i + 2 < preview.image.rgb.size(); i += 3)
            inked += preview.image.rgb[i] != 0xff || preview.image.rgb[i + 1] != 0xff || preview.image.rgb[i + 2] != 0xff;
        check(ok && meshes.size() == 2 && preview.image.rgb == drawn.rgb && inked > 1000 && preview.name == KompasNativeWriteOptions{}.title,
              "наш документ: миниатюра " + std::to_string(preview.image.width) + "×" + std::to_string(preview.image.height) + " — рисунок его сеток, закрашено " +
                  std::to_string(inked) + " точек");
    }
    // Our document's meshes.
    {
        bool ok = written;
        std::string detail;
        std::size_t index = 0;
        for (const auto& [p, bytes] : ours.list) {
            if (!ok || !p.endsWith(QStringLiteral("/Triangle"))) continue;
            KompasMesh mesh;
            ok = decodeKompasMesh(bytes, mesh, error);
            const auto shape = index == 0 ? box.value() : cylinder.value();
            const TopoDS_Shape& body = *kernel.findShape(shape);
            GProp_GProps volume, area;
            BRepGProp::VolumeProperties(body, volume);
            BRepGProp::SurfaceProperties(body, area);
            std::vector<const KompasMeshGrid*> grids;
            for (const auto* list : {&mesh.curved, &mesh.planar})
                for (const auto& g : *list)
                    for (const auto& grid : g.grids) grids.push_back(&grid);
            std::sort(grids.begin(), grids.end(), [](const auto* a, const auto* b) { return a->names < b->names; });
            double v = 0, s = 0, worst = 0, sag = 0;
            for (std::size_t k = 0; ok && k < grids.size(); ++k) {
                const auto& g = *grids[k];
                ok = g.names == std::vector<quint32>{1003 + quint32(index), quint32(k + 1)} && g.nameTail == 0;
                sag = g.step[0];
                for (const auto& t : g.triangles) {
                    const auto& a = g.points[t[0]];
                    const auto& b = g.points[t[1]];
                    const auto& c = g.points[t[2]];
                    const double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]}, ac[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
                    const double n[3] = {ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0]};
                    s += 0.5 * std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
                    v += (double(a[0]) * n[0] + double(a[1]) * n[1] + double(a[2]) * n[2]) / 6.0;
                }
                for (const auto& p3 : g.points) {
                    BRepExtrema_DistShapeShape d(BRepBuilderAPI_MakeVertex(gp_Pnt(p3[0] / 1000.0, p3[1] / 1000.0, p3[2] / 1000.0)).Vertex(), body);
                    worst = std::max(worst, d.IsDone() ? d.Value() * 1000.0 : 1e9);
                }
            }
            const double bodyVolume = volume.Mass() * 1e9, bodyArea = area.Mass() * 1e6;
            ok = ok && grids.size() == std::size_t(index == 0 ? 6 : 3) && std::fabs(v / bodyVolume - 1) < 0.01 &&
                 std::fabs(s / bodyArea - 1) < 0.01 && worst <= sag + 1e-3;
            char line[200];
            std::snprintf(line, sizeof line, " [тело %zu: граней %zu, объём %.4g/%.4g, площадь %.4g/%.4g мм², отход до %.3g мм при прогибе %.3g]", index + 1,
                          grids.size(), v, bodyVolume, s, bodyArea, worst, sag);
            detail += line;
            ++index;
        }
        check(ok && index == 2, "наш документ: сетки отображения тел" + detail);
    }
    if (!samples.empty()) {
        // Streams all the samples hold, in the order of the first.
        std::vector<QString> common;
        for (const auto& [p, bytes] : samples.front().list) {
            bool everywhere = true;
            for (const auto& s : samples) {
                bool found = false;
                for (const auto& [q, b] : s.list) found = found || q == p;
                everywhere = everywhere && found;
            }
            if (everywhere && std::find(common.begin(), common.end(), p) == common.end()) common.push_back(p);
        }
        std::vector<QString> ourOrder;
        for (const auto& [p, bytes] : ours.list)
            if (std::find(ourOrder.begin(), ourOrder.end(), p) == ourOrder.end()) ourOrder.push_back(p);
        QStringList missing, unexpected;
        std::vector<QString> expectedOrder;
        for (const QString& p : common) {
            const bool have = std::find(ourOrder.begin(), ourOrder.end(), p) != ourOrder.end();
            if (!have && !kNotYetAuthored.count(p)) missing << p;
            if (have && kNotYetAuthored.count(p)) unexpected << p;
            if (have) expectedOrder.push_back(p);
        }
        std::vector<QString> ourCommon;
        for (const QString& p : ourOrder)
            if (std::find(common.begin(), common.end(), p) != common.end()) ourCommon.push_back(p);
        check(missing.isEmpty() && unexpected.isEmpty(),
              "потоки, общие для всех " + std::to_string(samples.size()) + " деталей (" + std::to_string(common.size()) + "): есть все, кроме " +
                  std::to_string(kNotYetAuthored.size()) + " ещё не написанных" +
                  (missing.isEmpty() ? std::string() : "; нет: " + missing.join(", ").toStdString()) +
                  (unexpected.isEmpty() ? std::string() : "; уже написаны, убрать из списка: " + unexpected.join(", ").toStdString()));
        check(ourCommon == expectedOrder, "порядок потоков тот же, что у КОМПАС 17.1");
    }

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
