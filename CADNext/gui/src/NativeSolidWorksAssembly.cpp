#include "cadnext/gui/NativeSolidWorksAssembly.hpp"
#include "cadnext/gui/NativeSolidWorksDocument.hpp"
#include "cadnext/gui/NativeSolidWorksPackage.hpp"
#include "cadnext/gui/NativeSolidWorksPart.hpp"

#include "NativeSolidWorksAssemblyBlueprint.hpp"

#include <QDir>
#include <QFileInfo>
#include <QObject>
#include <QRandomGenerator>
#include <QSaveFile>
#include <QSet>
#include <QTimeZone>
#include <QStringList>
#include <QPair>

#include <algorithm>
#include <cstdio>

#ifdef CADNEXT_WITH_OCCT
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#endif

#include <cmath>
#include <cstring>

namespace cadnext::gui {
namespace {

namespace bp = solidworks_assembly_blueprint;

const bp::Stream* findStream(const QByteArray& name) {
    for (const bp::Stream& stream : bp::streams())
        if (name == stream.name) return &stream;
    return nullptr;
}

void putBytes(QByteArray& out, quint64 value, int size) {
    for (int i = 0; i < size; ++i) out.append(char((value >> (8 * i)) & 0xFF));
}

quint64 getBytes(const QByteArray& b, qint64 at, int size) {
    quint64 value = 0;
    for (int i = 0; i < size; ++i) value |= quint64(uchar(b[at + i])) << (8 * i);
    return value;
}

void putDouble(QByteArray& out, double value) {
    quint64 raw = 0;
    std::memcpy(&raw, &value, 8);
    putBytes(out, raw, 8);
}

QByteArray archiveString(const QString& text) {
    QByteArray out = QByteArray::fromHex("fffeff");
    if (text.size() < 0xFF) out.append(char(text.size()));
    else { out.append(char(0xFF)); putBytes(out, quint64(text.size()), 2); }
    for (QChar c : text) putBytes(out, c.unicode(), 2);
    return out;
}

// A string at `at`: false when there is none; `at` moves past it.
bool readArchiveString(const QByteArray& b, qint64& at, QString& text) {
    if (at + 4 > b.size() || uchar(b[at]) != 0xFF || uchar(b[at + 1]) != 0xFE || uchar(b[at + 2]) != 0xFF) return false;
    qint64 length = uchar(b[at + 3]), j = at + 4;
    if (length == 0xFF) {
        if (j + 2 > b.size()) return false;
        length = qint64(getBytes(b, j, 2));
        j += 2;
    }
    if (j + 2 * length > b.size()) return false;
    text.clear();
    for (qint64 i = 0; i < length; ++i) text += QChar(ushort(getBytes(b, j + 2 * i, 2)));
    at = j + 2 * length;
    return true;
}

// A + B·n + C·k from "a,b,c".
qint64 linear(const char* text, std::size_t n, std::size_t k) {
    const QList<QByteArray> parts = QByteArray(text).split(',');
    if (parts.size() != 3) return 0;
    return parts[0].toLongLong() + parts[1].toLongLong() * qint64(n) + parts[2].toLongLong() * qint64(k);
}

QString filled(const char* templateText, const SolidWorksAssemblyValues& values, const SolidWorksAssemblyPartValues* part) {
    QString text = QString::fromUtf8(templateText);
    text.replace(QStringLiteral("{title}"), values.title);
    text.replace(QStringLiteral("{folder}"), values.folder);
    text.replace(QStringLiteral("{author}"), values.author);
    text.replace(QStringLiteral("{configuration}"), values.configuration);
    if (part) text.replace(QStringLiteral("{name}"), part->name);
    return text;
}

// The ten doubles of a part's box as its Header2 holds them (the part writer's formulas).
std::array<double, 10> partBlock(const SolidWorksAssemblyPartValues& part) {
    static const char* const kFormulas[10] = {"c0", "c1", "c2", "M0", "M1", "M2", "m0", "m1", "m2", "r"};
    std::array<double, 10> block{};
    for (int i = 0; i < 10; ++i) solidWorksPartFormula(QString::fromLatin1(kFormulas[i]), part.boxMin, part.boxMax, block[std::size_t(i)]);
    return block;
}

// One section into `out` for block index k (part: the block's component, or none).
bool encodeSection(const bp::Section& section, const SolidWorksAssemblyValues& values, std::size_t k,
                   const SolidWorksAssemblyPartValues* part, QByteArray& out, QString& error) {
    const std::size_t n = values.parts.size();
    for (std::size_t i = 0; i < section.count; ++i) {
        const bp::Piece& p = section.pieces[i];
        switch (p.kind) {
        case 'B': out += QByteArray::fromHex(p.text); break;
        case 'S': out += archiveString(QString::fromUtf8(p.text)); break;
        case 'V':
            if (!part && QByteArray(p.text).contains("{name}")) {
                error = QObject::tr("Чертёж сборки SOLIDWORKS: имя компонента вне его блока.");
                return false;
            }
            out += archiveString(filled(p.text, values, part));
            break;
        case 'I': putBytes(out, quint64(linear(p.text, n, k)), p.number); break;
        case 'T': putBytes(out, values.saved, 4); break;
        case 'F': putBytes(out, values.filetime, 8); break;
        case 'G':
            putBytes(out, values.filetime >> 32, 4);
            putBytes(out, values.filetime & 0xFFFFFFFFu, 4);
            break;
        case 'O': {
            if (!part) { error = QObject::tr("Чертёж сборки SOLIDWORKS: габарит детали вне её блока."); return false; }
            for (double v : partBlock(*part)) putDouble(out, v);
            break;
        }
        case 'A':
            for (double v : solidWorksAssemblyBlock(values)) putDouble(out, v);
            break;
        case 'U': out.append(reinterpret_cast<const char*>(values.guid.data()), 16); break;
        case 'Z': out += QByteArray::fromHex(p.text); break;
        default:
            error = QObject::tr("Чертёж сборки SOLIDWORKS: неизвестный вид части потока.");
            return false;
        }
    }
    return true;
}

// The same section read at `at`: false (with the place) when it differs outside the slots.
bool matchSection(const bp::Section& section, const QByteArray& b, qint64& at, std::size_t n, std::size_t k,
                  const QByteArray& name, QString& error) {
    const auto differs = [&](std::size_t piece) {
        error = QObject::tr("Поток «%1» сборки отличается от чертежа: часть %2, байт %3.")
                    .arg(QString::fromLatin1(name)).arg(piece).arg(at);
        return false;
    };
    for (std::size_t i = 0; i < section.count; ++i) {
        const bp::Piece& p = section.pieces[i];
        switch (p.kind) {
        case 'B': {
            const QByteArray want = QByteArray::fromHex(p.text);
            if (b.mid(at, want.size()) != want) return differs(i);
            at += want.size();
            break;
        }
        case 'S': case 'V': {
            QString text;
            if (!readArchiveString(b, at, text)) return differs(i);
            if (p.kind == 'S' && text != QString::fromUtf8(p.text)) return differs(i);
            break;
        }
        case 'I':
            if (at + p.number > b.size() || getBytes(b, at, p.number) != (quint64(linear(p.text, n, k)) & (p.number == 8 ? ~0ull : ((1ull << (8 * p.number)) - 1))))
                return differs(i);
            at += p.number;
            break;
        case 'T': at += 4; break;
        case 'F': case 'G': at += 8; break;
        case 'O': case 'A': at += 80; break;
        case 'U': at += 16; break;
        case 'Z': at += p.number; break;
        default: return differs(i);
        }
        if (at > b.size()) return differs(i);
    }
    return true;
}

} // namespace

QStringList solidWorksAssemblyFeatureNames() {
    // ids 0 and 2–23; English as the NIST MTC assembly (SOLIDWORKS 2018) and the walrus part have them.
    return {QStringLiteral("Assem2"), QStringLiteral("Annotations"), QStringLiteral("Front Plane"), QStringLiteral("Top Plane"),
            QStringLiteral("Right Plane"), QStringLiteral("Origin"), QStringLiteral("Lights, Cameras and Scene"),
            QStringLiteral("Design Binder"), QStringLiteral("Comments"), QStringLiteral("Live Section Planes"), QStringLiteral("Mates"),
            QStringLiteral("Ambient"), QStringLiteral("Directional1"), QStringLiteral("Directional2"), QStringLiteral("Directional3"),
            QStringLiteral("Equations"), QStringLiteral("Notes"), QStringLiteral("Notes1___EndTag___"), QStringLiteral("Markups"),
            QStringLiteral("Sensors"), QStringLiteral("Favorites"), QStringLiteral("History"), QStringLiteral("Selection Sets")};
}

SolidWorksAssemblyHeaderFields solidWorksAssemblyHeaderFields(const SolidWorksAssemblyValues& values) {
    SolidWorksAssemblyHeaderFields f;
    f.author = values.author;
    f.features = solidWorksAssemblyFeatureNames();
    f.templateTime = f.importTime = f.modifiedAt = f.referenceTime = values.saved;
    f.path = values.folder + QLatin1Char('\\') + values.title + QStringLiteral(".SLDASM");
    f.title = values.title;
    f.source = values.folder + QLatin1Char('\\') + values.title + QStringLiteral(".step");
    f.configuration = values.configuration;
    for (const auto& part : values.parts)
        f.components.push_back({part.name + QStringLiteral("-1"), values.folder + QLatin1Char('\\') + part.name + QStringLiteral(".SLDPRT"),
                                part.name, values.saved, values.saved});
    f.bounds = solidWorksAssemblyBlock(values);
    return f;
}

bool encodeSolidWorksAssemblyHeader(const SolidWorksAssemblyHeaderFields& f, QByteArray& bytes, QString& error) {
    bytes.clear();
    if (f.features.size() != 23 || f.components.size() < 2) {
        error = QObject::tr("Заголовку сборки SOLIDWORKS нужны 23 элемента дерева и не меньше двух компонентов.");
        return false;
    }
    const auto text = [](const QString& s) { return SolidWorksArchiveString{s, true}; };
    SolidWorksDocumentHeader h;
    h.layout = SolidWorksDocumentHeaderLayout::ExtendedByte;
    h.authors = {text(f.author)};
    h.secondaryStrings = {text(QString())};
    // The standing logs: id 0, then 2–23; ids 3–6 (the planes and the origin) were also modified;
    // the first seventeen come with the template, the rest with the import.
    for (int i = 0; i < 23; ++i) {
        SolidWorksDocumentLog log;
        log.featureId = quint32(i == 0 ? 0 : i + 1);
        log.featureName = text(f.features[i]);
        const quint32 time = log.featureId <= 16 ? f.templateTime : f.importTime;
        log.stamps.push_back({0, 0, time, text(QStringLiteral("Created"))});
        if (log.featureId >= 3 && log.featureId <= 6) log.stamps.push_back({1, 0, time, text(QStringLiteral("Modified"))});
        h.logs.push_back(std::move(log));
    }
    for (std::size_t k = 0; k < f.components.size(); ++k) {
        SolidWorksDocumentLog log;
        log.featureId = quint32(24 + k);
        log.featureName = text(f.components[k].log);
        log.stamps.push_back({0, 0, f.importTime, text(QStringLiteral("Created"))});
        h.logs.push_back(std::move(log));
    }
    h.createdAt = f.templateTime;
    h.nextFeatureId = quint32(24 + f.components.size());
    const auto reference = [&](const QString& path, const QString& title, quint16 type, quint32 modifiedAt) {
        SolidWorksDocumentReference r;
        r.path = std::make_shared<SolidWorksArchiveString>(text(path));
        r.title = std::make_shared<SolidWorksArchiveString>(text(title));
        r.documentType = type;
        r.modifiedAt = modifiedAt;
        r.auxiliaryStrings = {text(QString()), text(f.source), text(QString())};
        return r;
    };
    for (std::size_t k = 0; k < f.components.size(); ++k) {
        const auto& c = f.components[k];
        SolidWorksDocumentReference r = reference(c.path, c.title, 2, c.modifiedAt);
        r.nativeFields = {c.referenceTime, 1, 0, quint32(k)};
        r.configurationId = 0xFFFFFFFFu;
        r.nativeFields2 = {0, c.referenceTime};
        h.references.push_back(std::move(r));
    }
    h.modifiedStamp = 103;
    h.currentDocument = reference(f.path, f.title, 3, f.modifiedAt);
    h.currentDocument.nativeFields = {f.referenceTime, 1, 0, 0xFFFFFFFFu};
    h.currentDocument.configurationName = text(f.configuration);
    h.currentDocument.configurationId = 0;
    h.nativeFields = {101, 0, 0, f.importTime, 0, 0, 0};
    h.nativeCounters = {quint32(f.components.size()), 0, f.importTime};
    h.allocatedEmptyList = false;
    h.nativeBounds = f.bounds;
    h.nativeTrailer = std::array<quint32, 4>{0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 2};
    h.nativeExtension = std::vector<quint32>(7, 0);
    return encodeSolidWorksDocumentHeader(h, bytes, error);
}

namespace {

QString xmlAttribute(QString text) {
    text.replace(QLatin1Char('&'), QStringLiteral("&amp;"));
    text.replace(QLatin1Char('<'), QStringLiteral("&lt;"));
    text.replace(QLatin1Char('>'), QStringLiteral("&gt;"));
    text.replace(QLatin1Char('"'), QStringLiteral("&quot;"));
    return text;
}

QString boxText(const std::array<double, 6>& box) {
    QStringList values;
    for (double v : box) {
        char buffer[40];
        std::snprintf(buffer, sizeof buffer, "%.16g", v);
        values << QString::fromLatin1(buffer);
    }
    return values.join(QLatin1Char(' '));
}

std::array<double, 6> sixOf(const std::array<double, 3>& min, const std::array<double, 3>& max) {
    return {min[0], min[1], min[2], max[0], max[1], max[2]};
}

} // namespace

SolidWorksAssemblyTreeFields solidWorksAssemblyTreeFields(const SolidWorksAssemblyValues& values) {
    SolidWorksAssemblyTreeFields f;
    f.modelName = f.importedName = values.title;
    f.path = values.folder + QLatin1Char('\\') + values.title + QStringLiteral(".SLDASM");
    f.source = values.folder + QLatin1Char('\\') + values.title + QStringLiteral(".step");
    f.configuration = values.configuration;
    f.displayState = QStringLiteral("Display State-1");
    f.created = values.saved;
    const auto block = solidWorksAssemblyBlock(values);
    f.box = {block[6], block[7], block[8], block[3], block[4], block[5]};
    for (const auto& part : values.parts)
        f.parts.push_back({part.name, values.folder + QLatin1Char('\\') + part.name + QStringLiteral(".SLDPRT"), values.saved,
                           sixOf(part.boxMin, part.boxMax)});
    return f;
}

QByteArray encodeSolidWorksAssemblyTree(const SolidWorksAssemblyTreeFields& f) {
    const int n = int(f.parts.size());
    const auto a = [](const QString& s) { return xmlAttribute(s); };
    QString x = QStringLiteral("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n");
    x += QStringLiteral("<swSolidWorks xmlns=\"http://www.solidworks.com/sw2003/schema\" swObjCount=\"%1\" swVersion=\"14000\">").arg(3 * n + 5);
    x += QStringLiteral("<swHeader swObjCount=\"%1\">").arg(n + 1);
    x += QStringLiteral("<swFile id=\"3\" swDocType=\"ASSEMBLY\" swCreationTime=\"%1\" swPath=\"%2\" swImportedPath=\"%3\"/>")
             .arg(f.created).arg(a(f.path), a(f.source));
    for (int k = 0; k < n; ++k)
        x += QStringLiteral("<swFile id=\"%1\" swDocType=\"PART\" swCreationTime=\"%2\" swPath=\"%3\" swImportedPath=\"%4\"/>")
                 .arg(3 * k + 6).arg(f.parts[std::size_t(k)].created).arg(a(f.parts[std::size_t(k)].path), a(f.source));
    x += QStringLiteral("</swHeader><swModelList swObjCount=\"%1\">").arg(n + 1);
    const QString model = QStringLiteral("<swModel id=\"%1\" swName=\"%2\" swImportedName=\"%3\" swConfigurationName=\"%4\" "
                                         "swConfigurationId=\"0\" swLastModifiedStamp=\"%5\" swConfigurationFlags=\"%6\" swFileRef=\"%7\" "
                                         "swBoundingBox=\"%8\"");
    for (int k = 0; k < n; ++k)
        x += model.arg(3 * k + 5).arg(a(f.modelName), a(f.importedName), a(f.configuration)).arg(102).arg(-2143288960).arg(3 * k + 6)
                 .arg(boxText(f.parts[std::size_t(k)].box)) + QStringLiteral("/>");
    x += model.arg(2).arg(a(f.modelName), a(f.importedName), a(f.configuration)).arg(103).arg(-2147221120).arg(3).arg(boxText(f.box)) +
         QStringLiteral(" swAssemblyFeatureEffectedComponents=\"\">");
    for (int k = 0; k < n; ++k) {
        const QString name = a(f.parts[std::size_t(k)].name);
        x += QStringLiteral("<swReference id=\"%1\" swName=\"%2\" swImportedName=\"%3\" swReferenceNumber=\"1\" swComponentReference=\"\" "
                            "swComponentName=\"%4\" swID=\"%5\" swIsVirtualComponent=\"NO\" swConfigurationId=\"0\" swConfigurationName=\"%6\" "
                            "swDisplayMode=\"6\" swHlrDisplayQuality=\"1\" swSuppressed=\"NO\" swHidden=\"NO\" swEdgesInShadedMode=\"NO\" "
                            "swFlexible=\"NO\" swExcludeFromBOM=\"NO\" swZone=\"NO\" swModelRef=\"%7\" "
                            "swTransform=\"1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1\" swTransformStamp=\"102\"/>")
                 .arg(3 * k + 4).arg(name, a(f.importedName), name).arg(24 + k).arg(a(f.configuration)).arg(3 * k + 5);
    }
    QString ids, shows;
    for (int k = 0; k < n; ++k) { ids += QString::number(24 + k) + QLatin1Char(','); shows += QStringLiteral("Yes,"); }
    x += QStringLiteral("</swModel></swModelList><swConfigurationList swObjCount=\"1\"><swConfiguration id=\"1\" swName=\"%1\" swID=\"0\" "
                        "swReference=\"%2\" swMostRecentConfiguration=\"YES\" swConfigurationNeedsUpdate=\"NO\" swModelRef=\"2\">"
                        "<swDisplayStateList id=\"%3\" swCompNameList=\"%4\"><swDisplayState id=\"%5\" swDisplayStateName=\"%6\" "
                        "swShowState=\"%7\"/></swDisplayStateList></swConfiguration></swConfigurationList>"
                        "<swExtFeatureList swObjCount=\"0\"/></swSolidWorks>\r\n")
             .arg(a(f.configuration), a(f.modelName)).arg(3 * n + 4).arg(ids).arg(3 * n + 5).arg(a(f.displayState), shows);
    return x.toUtf8();
}

SolidWorksAssemblyKeyWordsFields solidWorksAssemblyKeyWordsFields(const SolidWorksAssemblyValues& values) {
    SolidWorksAssemblyKeyWordsFields f;
    f.created = values.saved;
    f.name = values.title;
    f.configuration = values.configuration;
    // The standing features (ids as the samples have them; names and types in English, as the NIST
    // assembly and the walrus part write them).
    const struct { quint32 id; const char* name; const char* type; } standing[] = {
        {1, "", "Exploded Views"}, {2, "Annotations", "Annotations"}, {3, "Front Plane", "PLANE"}, {4, "Top Plane", "PLANE"},
        {5, "Right Plane", "PLANE"}, {7, "Lights, Cameras and Scene", "Lights, Cameras and Scene"}, {8, "Design Binder", "Design Binder"},
        {9, "Comments", "Comments"}, {10, "Live Section Planes", "Live Section Planes"}, {11, "Mates", "Mates"}, {12, "Ambient", "Ambient"},
        {13, "Directional1", "Directional"}, {14, "Directional2", "Directional"}, {15, "Directional3", "Directional"},
        {16, "Equations", "Equations"}, {17, "Notes", "Notes"}, {18, "Notes1___EndTag___", "Notes"}, {19, "Markups", "Markups"},
        {20, "Sensors", "Sensors"}, {21, "Favorites", "Favorites"}, {22, "History", "History"}, {23, "Selection Sets", "Selection Sets"}};
    for (const auto& s : standing)
        f.items.push_back({QStringLiteral("Feature"), s.id, QString::fromUtf8(s.name), QString(), QString::fromUtf8(s.type)});
    for (std::size_t k = 0; k < values.parts.size(); ++k) {
        const QString& name = values.parts[k].name;
        f.items.push_back({QStringLiteral("Reference"), quint32(24 + k), name + QStringLiteral("-1"),
                           k == 0 ? QStringLiteral("PART-%1-DESC").arg(name) : QStringLiteral("PART--DESC"), name + QLatin1Char('-')});
    }
    f.items.push_back({QStringLiteral("Sketch"), 6, QStringLiteral("Origin"), QString(), QStringLiteral("Origin")});
    return f;
}

QByteArray encodeSolidWorksAssemblyKeyWords(const SolidWorksAssemblyKeyWordsFields& f) {
    auto items = f.items;
    std::stable_sort(items.begin(), items.end(), [](const auto& l, const auto& r) {
        if (l.element != r.element) return l.element < r.element;
        return QString::number(l.id) < QString::number(r.id);
    });
    QString x = QStringLiteral("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<Keywords id=\"%1\" Name=\"%2\">"
                               "<Configuration id=\"0\" Name=\"%3\" Type=\"ConfigurationManager\"/>")
                    .arg(f.created).arg(xmlAttribute(f.name), xmlAttribute(f.configuration));
    for (const auto& item : items) {
        x += QStringLiteral("<%1 id=\"%2\" Name=\"%3\"").arg(item.element).arg(item.id).arg(xmlAttribute(item.name));
        if (!item.description.isEmpty()) x += QStringLiteral(" Description=\"%1\"").arg(xmlAttribute(item.description));
        x += QStringLiteral(" Type=\"%1\"/>").arg(xmlAttribute(item.type));
    }
    x += QStringLiteral("</Keywords>\r\n");
    QByteArray out(1, char(0x86));
    out += x.toUtf8();
    return out;
}

QByteArray encodeSolidWorksAssemblyInformation(const SolidWorksAssemblyValues& values) {
    // The dates as the part writer writes them (English, the saved moment, UTC).
    SolidWorksPartWriteOptions options;
    options.title = values.title;
    options.author = values.author;
    options.folder = values.folder;
    options.saved = QDateTime::fromSecsSinceEpoch(values.saved, Qt::UTC);
    const SolidWorksPartValues partValues = solidWorksPartValues(values.title, {0, 0, 0}, {0, 0, 0}, 0, options);
    const QString shortDate = partValues.text.value(QStringLiteral("date.short"));
    const QString longDate = partValues.text.value(QStringLiteral("date.long"));
    const QString stamp = partValues.text.value(QStringLiteral("date.created"));
    struct Property { const char* name; int pid; const char* type; QString value; const char* alias; };
    const Property properties[] = {
        {"SW-File Name", 3, "lpstr", values.title, "File Name"}, {"SW-BOM Part Number", 4, "lpstr", values.title, "BOM Part Number"},
        {"SW-Folder Name", 5, "lpstr", values.folder + QLatin1Char('\\'), "Folder Name"}, {"SW-Short Date", 6, "lpstr", shortDate, "Short Date"},
        {"SW-Long Date", 7, "lpstr", longDate, "Long Date"}, {"SW-Configuration Name", 8, "lpstr", values.configuration, "Configuration Name"},
        {"SW-Author", 9, "lpstr", QString(), "Author"}, {"SW-Keywords", 10, "lpstr", QString(), "Keywords"},
        {"SW-Comments", 11, "lpstr", QString(), "Comments"}, {"SW-Title", 12, "lpstr", QString(), "Title"},
        {"SW-Subject", 13, "lpstr", QString(), "Subject"}, {"SW-Created Date", 14, "lpstr", stamp, "Created Date"},
        {"SW-Last Saved Date", 15, "lpstr", stamp, "Last Saved Date"}, {"SW-Last Saved By", 16, "lpstr", values.author, "Last Saved By"},
        {"SW-File Title", 17, "lpstr", values.title, "File Title"}, {"Assembly type", 18, "bool", QStringLiteral("No"), nullptr},
        {"SW-HasDesignTable", 19, "i4", QStringLiteral("0"), nullptr}};
    QString x = QStringLiteral("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n<Properties xmlns=\"http://schemas.openxmlformats.org/"
                               "officeDocument/2006/SolidworksInformation-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/"
                               "2006/docPropsVTypes\"><propertySection xmlns=\"\" name=\"UserDefinedProperties\" "
                               "fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\"><property name=\"\" pid=\"1\"><vt:i2>65001</vt:i2></property>");
    QList<QPair<QString, int>> dictionary{{QString(), 0}};
    for (const Property& p : properties) {
        x += QStringLiteral("<property name=\"%1\" pid=\"%2\"><vt:%3>%4</vt:%3></property>")
                 .arg(QString::fromUtf8(p.name)).arg(p.pid).arg(QString::fromLatin1(p.type), xmlAttribute(p.value));
        dictionary.push_back({QString::fromUtf8(p.name), p.pid});
        if (p.alias) dictionary.push_back({QStringLiteral("%1(%2)").arg(QString::fromUtf8(p.name), QString::fromUtf8(p.alias)), p.pid});
    }
    std::stable_sort(dictionary.begin(), dictionary.end(), [](const auto& l, const auto& r) { return l.first.toUtf8() < r.first.toUtf8(); });
    for (const auto& entry : dictionary)
        x += QStringLiteral("<propertyNameDictionaryElement name=\"%1\" pid=\"%2\"></propertyNameDictionaryElement>").arg(entry.first).arg(entry.second);
    x += QStringLiteral("</propertySection></Properties>\r\n");
    return x.toUtf8();
}

QList<QByteArray> solidWorksAssemblyBlueprintStreams() {
    QList<QByteArray> names;
    for (const bp::Stream& stream : bp::streams()) names.push_back(stream.name);
    return names;
}

std::array<double, 10> solidWorksAssemblyBlock(const SolidWorksAssemblyValues& values) {
    std::array<double, 10> block{};
    if (values.parts.empty()) return block;
    std::array<double, 3> centre{}, max{}, min{};
    double radius = 0;
    for (std::size_t i = 0; i < values.parts.size(); ++i) {
        const auto part = partBlock(values.parts[i]);
        const std::array<double, 3> c{part[0], part[1], part[2]};
        const double r = part[9];
        for (int a = 0; a < 3; ++a) {
            max[a] = i == 0 ? part[3 + a] : std::max(max[a], part[3 + a]);
            min[a] = i == 0 ? part[6 + a] : std::min(min[a], part[6 + a]);
        }
        if (i == 0) { centre = c; radius = r; continue; }
        // The sphere that holds both: unchanged when one holds the other, else grown along the line
        // between the centres.
        const double d = std::sqrt((c[0] - centre[0]) * (c[0] - centre[0]) + (c[1] - centre[1]) * (c[1] - centre[1]) +
                                   (c[2] - centre[2]) * (c[2] - centre[2]));
        if (d + r <= radius) continue;
        if (d + radius <= r) { centre = c; radius = r; continue; }
        const double grown = (d + radius + r) / 2;
        for (int a = 0; a < 3; ++a) centre[a] += (c[a] - centre[a]) * (grown - radius) / d;
        radius = grown;
    }
    for (int a = 0; a < 3; ++a) {
        block[std::size_t(a)] = centre[a];
        block[std::size_t(3 + a)] = max[a];
        block[std::size_t(6 + a)] = min[a];
    }
    block[9] = radius;
    return block;
}

bool encodeSolidWorksAssemblyStream(const QByteArray& name, const SolidWorksAssemblyValues& values, QByteArray& bytes,
                                    QString& error) {
    bytes.clear();
    error.clear();
    const bp::Stream* stream = findStream(name);
    if (!stream) {
        error = QObject::tr("В чертеже сборки SOLIDWORKS нет потока «%1».").arg(QString::fromLatin1(name));
        return false;
    }
    QByteArray out;
    if (!encodeSection(stream->prefix, values, 0, nullptr, out, error)) return false;
    if (stream->layout == bp::Layout::Components) {
        const std::size_t n = values.parts.size();
        if (n < 2) {
            error = QObject::tr("Сборке SOLIDWORKS нужно не меньше двух компонентов, а их %1.").arg(n);
            return false;
        }
        const auto component = [&](std::size_t k) { return &values.parts[stream->reverse ? n - 1 - k : k]; };
        if (!encodeSection(stream->first, values, 0, component(0), out, error)) return false;
        for (std::size_t k = 1; k < n; ++k) {
            if (!encodeSection(stream->body, values, k, component(k), out, error)) return false;
            if (k + 1 < n && !encodeSection(stream->sep, values, k, component(k), out, error)) return false;
        }
        if (!encodeSection(stream->tail, values, 0, nullptr, out, error)) return false;
    }
    bytes = out;
    return true;
}

bool matchSolidWorksAssemblyStream(const QByteArray& name, const QByteArray& bytes, std::size_t components, QString& error) {
    error.clear();
    const bp::Stream* stream = findStream(name);
    if (!stream) {
        error = QObject::tr("В чертеже сборки SOLIDWORKS нет потока «%1».").arg(QString::fromLatin1(name));
        return false;
    }
    qint64 at = 0;
    if (!matchSection(stream->prefix, bytes, at, components, 0, name, error)) return false;
    if (stream->layout == bp::Layout::Components) {
        if (components < 2) {
            error = QObject::tr("Сборке SOLIDWORKS нужно не меньше двух компонентов.");
            return false;
        }
        if (!matchSection(stream->first, bytes, at, components, 0, name, error)) return false;
        for (std::size_t k = 1; k < components; ++k) {
            if (!matchSection(stream->body, bytes, at, components, k, name, error)) return false;
            if (k + 1 < components && !matchSection(stream->sep, bytes, at, components, k, name, error)) return false;
        }
        if (!matchSection(stream->tail, bytes, at, components, 0, name, error)) return false;
    }
    if (at != bytes.size()) {
        error = QObject::tr("Поток «%1» сборки длиннее чертежа: %2 байт сверх.").arg(QString::fromLatin1(name)).arg(bytes.size() - at);
        return false;
    }
    return true;
}

bool writeSolidWorksImportedAssembly(kernel::OcctKernel& kernel, const std::vector<SolidWorksAssemblyBody>& bodies,
                                     const QString& path, QString& error, const SolidWorksAssemblyWriteOptions& options) {
    error.clear();
#ifndef CADNEXT_WITH_OCCT
    Q_UNUSED(kernel); Q_UNUSED(bodies); Q_UNUSED(path); Q_UNUSED(options);
    error = QObject::tr("Запись SOLIDWORKS требует OCCT.");
    return false;
#else
    if (bodies.size() < 2 || bodies.size() > 1000) {
        error = QObject::tr("Сборка SOLIDWORKS записывается для 2–1000 тел, а их %1; одно тело — деталь.").arg(bodies.size());
        return false;
    }
    SolidWorksAssemblyValues values;
    values.title = options.title.isEmpty() ? QFileInfo(path).completeBaseName() : options.title;
    if (values.title.isEmpty() || values.title.size() > 200) {
        error = QObject::tr("Имя сборки SOLIDWORKS должно быть от 1 до 200 знаков.");
        return false;
    }
    values.folder = options.folder;
    values.author = options.author;
    const QDateTime saved = options.saved.isValid() ? options.saved : QDateTime::currentDateTimeUtc();
    values.saved = quint32(saved.toSecsSinceEpoch());
    values.filetime = (quint64(saved.toSecsSinceEpoch()) + 11644473600ull) * 10000000ull;
    // A random GUID (version 4), its first three fields little-endian as Windows stores them.
    for (auto& b : values.guid) b = quint8(QRandomGenerator::global()->bounded(256));
    values.guid[7] = quint8((values.guid[7] & 0x0F) | 0x40);
    values.guid[8] = quint8((values.guid[8] & 0x3F) | 0x80);

    // The parts, each where it belongs, beside the assembly.
    const QDir directory = QFileInfo(path).absoluteDir();
    QSet<QString> taken;
    SolidWorksPartWriteOptions partOptions;
    partOptions.author = options.author;
    partOptions.saved = saved;
    partOptions.folder = options.folder;
    for (const auto& body : bodies) {
        QString name = body.name.trimmed();
        for (QChar& c : name)
            if (QStringLiteral("\\/:*?\"<>|").contains(c) || c.unicode() < 32) c = QLatin1Char('_');
        if (name.isEmpty()) name = QStringLiteral("Part");
        name.truncate(180);
        QString unique = name;
        for (int i = 2; taken.contains(unique.toLower()) || unique.compare(values.title, Qt::CaseInsensitive) == 0; ++i)
            unique = QStringLiteral("%1 (%2)").arg(name).arg(i);
        taken.insert(unique.toLower());
        const auto* solid = kernel.findShape(body.shape);
        if (!solid) {
            error = QObject::tr("Тело «%1» для сборки SOLIDWORKS не найдено.").arg(body.name);
            return false;
        }
        Bnd_Box box;   // as the part writer measures it: no gap
        BRepBndLib::AddOptimal(*solid, box, false, false);
        if (box.IsVoid()) {
            error = QObject::tr("У тела «%1» нет габарита.").arg(body.name);
            return false;
        }
        box.SetGap(0.0);
        SolidWorksAssemblyPartValues part;
        part.name = unique;
        box.Get(part.boxMin[0], part.boxMin[1], part.boxMin[2], part.boxMax[0], part.boxMax[1], part.boxMax[2]);
        partOptions.title = unique;
        if (!writeSolidWorksImportedPart(kernel, body.shape, directory.filePath(unique + QStringLiteral(".SLDPRT")), error, partOptions)) {
            error = QObject::tr("Деталь «%1» сборки: %2").arg(unique, error);
            return false;
        }
        values.parts.push_back(part);
    }

    // The streams, in SOLIDWORKS's order.
    QByteArray header;
    if (!encodeSolidWorksAssemblyHeader(solidWorksAssemblyHeaderFields(values), header, error)) return false;
    SolidWorksPartWriteOptions documentOptions = partOptions;
    documentOptions.title = values.title;
    const SolidWorksPartValues document = solidWorksPartValues(values.title, {0, 0, 0}, {0, 0, 0}, 0, documentOptions);
    SolidWorksPackage package;
    for (const auto& entry : solidworks_assembly_blueprint::entries()) {
        SolidWorksPackageEntry e;
        e.name = entry.name;
        e.stamp = entry.stamp;
        if (e.name == "Header2" || e.name == "Contents/Config-0-ModelHeader") e.data = header;
        else if (e.name == "swXmlContents/COMPINSTANCETREE") e.data = encodeSolidWorksAssemblyTree(solidWorksAssemblyTreeFields(values));
        else if (e.name == "swXmlContents/KeyWords") e.data = encodeSolidWorksAssemblyKeyWords(solidWorksAssemblyKeyWordsFields(values));
        else if (e.name == "docProps/ISolidWorksInformation.xml") e.data = encodeSolidWorksAssemblyInformation(values);
        else if (e.name == "docProps/core.xml") {
            if (!encodeSolidWorksPartStream(e.name, document, e.data, error)) return false;
        } else if (!encodeSolidWorksAssemblyStream(e.name, values, e.data, error)) return false;
        bool text = false;
        if (encodeSolidWorksPackageRecord(package, e, &text).isEmpty()) {
            error = QObject::tr("Не удалось сжать поток «%1» сборки SOLIDWORKS.").arg(QString::fromLatin1(e.name));
            return false;
        }
        e.text = text && !e.data.isEmpty();
        package.entries.push_back(std::move(e));
    }
    QByteArray file;
    if (!encodeSolidWorksPackage(package, file, error)) return false;
    // Read back before the destination is touched: the same streams, each blueprint stream the
    // blueprint's, the header readable with as many references as components.
    SolidWorksPackage back;
    if (!decodeSolidWorksPackage(file, back, error) || back.entries != package.entries) {
        if (error.isEmpty()) error = QObject::tr("Записанный пакет сборки SOLIDWORKS читается обратно иначе.");
        return false;
    }
    for (const auto& e : back.entries) {
        if (findStream(e.name) && !matchSolidWorksAssemblyStream(e.name, e.data, values.parts.size(), error)) return false;
        if (e.name == "Header2") {
            SolidWorksDocumentHeader h;
            if (!decodeSolidWorksDocumentHeader(e.data, h, error) || h.references.size() != values.parts.size()) {
                if (error.isEmpty()) error = QObject::tr("Заголовок записанной сборки SOLIDWORKS читается иначе.");
                return false;
            }
        }
    }
    QSaveFile output(path);
    if (!output.open(QIODevice::WriteOnly) || output.write(file) != file.size() || !output.commit()) {
        error = QObject::tr("Не удалось сохранить сборку SOLIDWORKS: %1").arg(output.errorString());
        return false;
    }
    return true;
#endif
}

} // namespace cadnext::gui
