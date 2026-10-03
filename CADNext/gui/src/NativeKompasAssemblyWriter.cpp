#include "cadnext/gui/NativeKompasWriter.hpp"
#include "cadnext/gui/NativeKompasAssembly.hpp"
#include "cadnext/gui/NativeKompasCatalog.hpp"
#include "cadnext/gui/NativeKompasDocument.hpp"
#include "cadnext/gui/NativeKompasMesh.hpp"
#include "cadnext/gui/NativeKompasModel.hpp"
#include "cadnext/gui/NativeKompasPreview.hpp"
#include "cadnext/gui/NativeKompasProperties.hpp"
#include "cadnext/gui/NativeKompasService.hpp"
#include "cadnext/gui/NativeKompasStorage.hpp"
#include "cadnext/gui/NativeKompasTextStyles.hpp"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QObject>

#include <zlib.h>

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <map>
#include <optional>

namespace cadnext::gui {
namespace {

// The rotation's columns (the part's axes in the assembly) from a unit quaternion (w, x, y, z).
std::array<double, 9> axesOf(const kernel::ProductPlacement& p) {
    double w = p.rotation[0], x = p.rotation[1], y = p.rotation[2], z = p.rotation[3];
    const double n = std::sqrt(w * w + x * x + y * y + z * z);
    w /= n, x /= n, y /= n, z /= n;
    return {1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y),
            2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x),
            2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)};
}

} // namespace

bool writeKompasNativeAssembly(kernel::OcctKernel& kernel, const std::vector<KompasAssemblyPart>& parts,
                               const std::vector<KompasAssemblyComponent>& components, const QString& path,
                               QString& error, const KompasNativeWriteOptions& options) {
    error.clear();
    if (parts.empty() || components.empty() || components.size() > kKompasAssemblyLinkKeys) {
        error = QObject::tr("Сборке КОМПАС нужны детали и от 1 до %1 компонентов.").arg(kKompasAssemblyLinkKeys);
        return false;
    }
    if (options.title.size() > 65536 || options.title.contains(QChar(u'\0')) || options.color > 0xffffff ||
        !std::isfinite(options.nativeDensity) || options.nativeDensity <= 0) {
        error = QObject::tr("Недопустимые свойства сборки КОМПАС.");
        return false;
    }
    for (const auto& part : parts) {
        if (part.bodies.empty() || !part.fileName.endsWith(QStringLiteral(".m3d"), Qt::CaseInsensitive) ||
            part.fileName.contains('/') || part.fileName.contains('\\') || part.fileName.size() > 255) {
            error = QObject::tr("Деталь сборки КОМПАС: нужны тела и имя файла .m3d без папок.");
            return false;
        }
    }
    for (const auto& c : components) {
        if (c.part >= parts.size()) {
            error = QObject::tr("Компонент сборки КОМПАС ссылается на несуществующую деталь.");
            return false;
        }
    }
    const QDir folder = QFileInfo(path).absoluteDir();

    // The parts first, each its own document; then what the assembly needs of each: its bodies placed (as
    // writeKompasNativeDocument places them), and the file's mark.
    std::vector<std::vector<kernel::ShapeHandle>> placed(parts.size());
    std::vector<quint32> marks(parts.size());
    for (std::size_t i = 0; i < parts.size(); ++i) {
        const QString file = folder.filePath(parts[i].fileName);
        if (!writeKompasNativeDocument(kernel, parts[i].bodies, file, error, parts[i].options)) {
            error = QObject::tr("Деталь %1: %2").arg(parts[i].fileName, error);
            return false;
        }
        QFile written(file);
        if (!written.open(QIODevice::ReadOnly)) {
            error = QObject::tr("Не удалось прочитать записанную деталь %1.").arg(parts[i].fileName);
            return false;
        }
        const QByteArray bytes = written.readAll();
        marks[i] = quint32(crc32(0, reinterpret_cast<const Bytef*>(bytes.constData()), uInt(bytes.size())));
        for (const auto& body : parts[i].bodies) {
            const auto shape = kernel.placeExchangeBody({body.shape, body.placement});
            if (!shape.isOk()) {
                error = QObject::tr("Размещение тела детали %1: %2").arg(parts[i].fileName, QString::fromStdString(shape.error().message));
                return false;
            }
            placed[i].push_back(shape.value());
        }
    }

    // Each component: its frame, its bodies in the assembly, its box, which placement of its part it is.
    const std::size_t links = parts.size();
    std::vector<KompasComponentRecord> records;
    std::vector<std::vector<kernel::ShapeHandle>> inAssembly;
    std::map<std::size_t, quint32> seen;
    std::array<double, 6> total{1e300, 1e300, 1e300, -1e300, -1e300, -1e300};
    for (std::size_t k = 0; k < components.size(); ++k) {
        const auto& c = components[k];
        const auto axes = axesOf(c.placement);
        const auto& t = c.placement.translation;
        const std::array<double, 16> matrix{axes[0], axes[1], axes[2], 0, axes[3], axes[4], axes[5], 0,
                                            axes[6], axes[7], axes[8], 0, t[0], t[1], t[2], 1};
        KompasComponentRecord r;
        r.index = quint32(k + 1);
        r.link = quint16(c.part);
        r.bodies = quint32(parts[c.part].bodies.size());
        r.instance = ++seen[c.part];
        // KOMPAS names a second (third...) placement of a part after it.
        if (r.instance > 1) r.instanceName = parts[c.part].options.title;
        r.frame = {t[0] * 1000, t[1] * 1000, t[2] * 1000, axes[0], axes[1], axes[2], axes[3], axes[4], axes[5], axes[6], axes[7], axes[8]};
        std::array<double, 6> box{1e300, 1e300, 1e300, -1e300, -1e300, -1e300};
        std::vector<kernel::ShapeHandle> shapes;
        for (const auto& shape : placed[c.part]) {
            const auto moved = kernel.transformShape(shape, matrix);
            if (!moved.isOk()) {
                error = QObject::tr("Компонент %1 сборки КОМПАС: %2").arg(k + 1).arg(QString::fromStdString(moved.error().message));
                return false;
            }
            const auto bounds = kernel.boundingBox(moved.value());
            if (!bounds.isOk()) {
                error = QObject::tr("Габарит компонента %1 сборки КОМПАС: %2").arg(k + 1).arg(QString::fromStdString(bounds.error().message));
                return false;
            }
            const auto& lo = bounds.value().min;
            const auto& hi = bounds.value().max;
            const double mm[6] = {lo.x * 1000, lo.y * 1000, lo.z * 1000, hi.x * 1000, hi.y * 1000, hi.z * 1000};
            for (int a = 0; a < 3; ++a) {
                box[a] = std::min(box[a], mm[a]);
                box[a + 3] = std::max(box[a + 3], mm[a + 3]);
            }
            shapes.push_back(moved.value());
        }
        r.box = box;
        for (int a = 0; a < 3; ++a) {
            total[a] = std::min(total[a], box[a]);
            total[a + 3] = std::max(total[a + 3], box[a + 3]);
        }
        records.push_back(std::move(r));
        inAssembly.push_back(std::move(shapes));
    }

    // Ids as in the samples: the file links from 0, then the seven datums; the catalog's "last" id is the next
    // free one.
    std::vector<KompasDocumentFileLink> fileLinks;
    for (std::size_t i = 0; i < links; ++i) {
        KompasDocumentFileLink link;
        link.objectId = quint16(i);
        link.relativePath = parts[i].fileName;
        link.absolutePath = QDir::toNativeSeparators(folder.filePath(parts[i].fileName));
        link.nativeMark = marks[i];
        fileLinks.push_back(std::move(link));
    }
    const quint16 firstDatum = quint16(links);
    const quint32 nextId = quint32(links) + 7;
    if (nextId > 65535) {
        error = QObject::tr("Реестр объектов сборки КОМПАС превышает 16-битный диапазон.");
        return false;
    }
    std::map<quint16, quint16> registry;
    QByteArray datumBytes;
    for (const KompasDatum& datum : kompasDefaultDatums(25, firstDatum, 93)) {
        QByteArray encoded;
        if (!encodeKompasDatum(datum, registry, encoded, error)) return false;
        registry.emplace(datum.objectId, datum.kind == KompasDatum::Plane ? 0x507a : datum.kind == KompasDatum::Axis ? 0x2c70 : 0x4170);
        datumBytes += encoded;
    }
    KompasModelHeader header;
    header.controllerCount = 7;
    for (auto& box : header.boxes) box = total;
    KompasModelFooter footer;
    footer.originId = quint16(firstDatum + 6);
    // As in every sample assembly: 7 + n, 0, 3, 4 + n for n components.
    const quint64 n = components.size();
    footer.nativeCounters = {7 + n, 0, 3, 4 + n};
    footer.nextMainName = 93 + 7;
    QByteArray headerBytes, footerBytes;
    if (!encodeKompasModelHeader(header, headerBytes, error) || !encodeKompasModelFooter(footer, registry, footerBytes, error)) return false;
    const QByteArray modelRecord = headerBytes + datumBytes + footerBytes;

    std::vector<QByteArray> componentBytes;
    for (const auto& r : records) {
        QByteArray encoded;
        if (!encodeKompasComponentRecord(r, encoded, error)) return false;
        componentBytes.push_back(std::move(encoded));
    }
    QByteArray linkBytes;
    if (!encodeKompasDocumentFileLinks(fileLinks, linkBytes, error)) return false;

    KompasModelProperties modelProperties;
    modelProperties.name = options.title;
    modelProperties.color = options.color;
    modelProperties.material = options.material;
    modelProperties.materialName = options.materialName;
    modelProperties.nativeDensity = options.nativeDensity;
    QByteArray modelPropertyBytes, massBytes;
    KompasDeferredMassProperties mass;
    mass.nativeDensity = options.nativeDensity / 1000.0;
    if (!encodeKompasModelProperties(modelProperties, modelPropertyBytes, error) || !encodeKompasDeferredMassProperties(mass, massBytes, error))
        return false;

    KompasDocumentSettings settings;
    settings.title = options.title;
    settings.assembly = true;
    for (std::size_t i = 0; i < KompasDocumentSettings::styleCount; ++i) {
        KompasDocumentStyle style;
        style.name = QStringLiteral("CADNext style %1").arg(i);
        style.color = options.color;
        style.material = options.material;
        settings.styles.push_back(std::move(style));
    }
    QByteArray settingsBytes, definitionBytes, tuningBytes;
    if (!encodeKompasDocumentSettings(settings, settingsBytes, error) ||
        !encodeKompasPropertyDefinitions(kompasStandardPropertyDefinitions(), definitionBytes, error) ||
        !encodeKompasPropertyTuning(kompasStandardPropertyTuning(), tuningBytes, error)) return false;

    // The records every document has (NativeKompasService.hpp), as the part writer writes them.
    QByteArray versionBytes, set100, set500, set700, model180, model210, d205, d230, d260, d280, d290, passwords, layers, model109,
        view, userSettings, dates, authors, representations, designation, textStyles, documentCounter, modelCounter, metaLinks;
    const auto service = [&](KompasServiceRecord kind, QByteArray& bytes) { return encodeKompasServiceRecord(kind, 0x11001011, bytes, error); };
    if (!service(KompasServiceRecord::ApplicationVersion, versionBytes) || !service(KompasServiceRecord::ModelSet100, set100) ||
        !service(KompasServiceRecord::ModelSet500, set500) || !service(KompasServiceRecord::ModelSet700, set700) ||
        !service(KompasServiceRecord::Model180, model180) || !service(KompasServiceRecord::Model210, model210) ||
        !service(KompasServiceRecord::Document205, d205) || !service(KompasServiceRecord::Document230, d230) ||
        !service(KompasServiceRecord::Document260, d260) || !service(KompasServiceRecord::Document280, d280) ||
        !service(KompasServiceRecord::Document290, d290) || !service(KompasServiceRecord::Passwords, passwords) ||
        !service(KompasServiceRecord::Model109, model109) || !service(KompasServiceRecord::View, view) ||
        !service(KompasServiceRecord::UserSettings, userSettings) || !encodeKompasLayers({KompasLayer{}}, layers, error) ||
        !encodeKompasTextStyles(kompasDefaultTextStyles(), textStyles, error) ||
        !encodeKompasRepresentations(kompasStandardRepresentations(double(QDateTime::currentMSecsSinceEpoch())), representations, error) ||
        !encodeKompasDesignationRecord(options.designation.value_or(QString()), designation, error) ||
        // 7 + 2 · components in every sample assembly; the model's counter is the next free id.
        !encodeKompasDocumentCounter(quint32(7 + 2 * n), documentCounter, error) ||
        !encodeKompasAssemblyModelCounter(nextId, modelCounter, error) ||
        !encodeKompasAssemblyMetaInfoLinks(components.size(), metaLinks, error)) return false;
    {
        const QDateTime now = QDateTime::currentDateTime();
        if (!encodeKompasDocumentDates({now, now}, dates, error)) return false;
        if (options.author && !encodeKompasDocumentAuthors({{*options.author, options.organization}}, authors, error)) return false;
    }
    KompasModelCounters counters;
    counters.firstBodyShell = nextId; // an assembly has no body: only the other three records are written
    counters.lastObjectId = nextId;
    counters.layoutCounter = nextId;
    KompasModelCounterRecords counterBytes;
    if (!encodeKompasModelCounters(counters, counterBytes, error)) return false;

    // The catalog in the order of KOMPAS 17.1's assemblies (the same in all 5 of the samples).
    std::vector<QByteArray> pool;
    const auto stream = [&](std::optional<quint16> numericName, const QString& textName, QByteArray bytes) {
        KompasCatalogEntry entry;
        entry.numericName = numericName;
        entry.textName = textName;
        entry.recordIndex = pool.size();
        pool.push_back(std::move(bytes));
        return entry;
    };
    const auto numeric = [&](quint16 name, QByteArray bytes) { return stream(name, {}, std::move(bytes)); };
    const auto text = [&](const QString& name, QByteArray bytes) { return stream(std::nullopt, name, std::move(bytes)); };
    const auto directory = [](std::optional<quint16> numericName, const QString& textName, std::vector<KompasCatalogEntry> children) {
        KompasCatalogEntry entry;
        entry.directory = true;
        entry.numericName = numericName;
        entry.textName = textName;
        entry.children = std::move(children);
        return entry;
    };
    std::vector<KompasCatalogEntry> componentEntries;
    for (std::size_t k = 0; k < componentBytes.size(); ++k) componentEntries.push_back(numeric(quint16(k + 1), std::move(componentBytes[k])));
    KompasCatalog catalog;
    catalog.lastObjectId = nextId;
    catalog.entries.push_back(numeric(114, std::move(documentCounter)));
    catalog.entries.push_back(numeric(113, std::move(versionBytes)));
    {
        std::vector<KompasCatalogEntry> info{text(QStringLiteral("_DI_D"), std::move(dates))};
        if (!authors.isEmpty()) info.push_back(text(QStringLiteral("_DI_C"), std::move(authors)));
        info.push_back(directory(std::nullopt, QStringLiteral("_SA_DN"), {text(QStringLiteral("_RR_FN"), std::move(representations))}));
        info.push_back(directory(std::nullopt, QStringLiteral("_PW_DN"), {text(QStringLiteral("_PW_FN"), std::move(passwords))}));
        catalog.entries.push_back(directory(std::nullopt, QStringLiteral("_KD_I"), std::move(info)));
    }
    catalog.entries.push_back(directory(std::nullopt, QStringLiteral("_DUS_D"), {text(QStringLiteral("_DUS_F"), std::move(userSettings))}));
    catalog.entries.push_back(numeric(100, std::move(settingsBytes)));
    catalog.entries.push_back(numeric(250, std::move(textStyles)));
    catalog.entries.push_back(numeric(260, std::move(d260)));
    catalog.entries.push_back(numeric(140, std::move(view)));
    catalog.entries.push_back(numeric(270, std::move(layers)));
    catalog.entries.push_back(numeric(204, std::move(designation)));
    catalog.entries.push_back(directory(170, {}, {
        directory(155, {}, {numeric(100, std::move(set100)), numeric(500, std::move(set500)), numeric(700, std::move(set700))}),
        directory(240, {}, {numeric(100, std::move(massBytes))}),
        numeric(109, std::move(model109)),
        directory(std::nullopt, QStringLiteral("_DC_D"), {text(QStringLiteral("_DE_F"), std::move(linkBytes))}),
        text(QStringLiteral("LayoutInstances"), std::move(counterBytes.layoutInstances)),
        directory(110, {}, std::move(componentEntries)),
        numeric(130, modelRecord),
        numeric(180, std::move(model180)),
        numeric(210, std::move(model210)),
        numeric(110, std::move(modelCounter)),
        directory(200, {}, {numeric(201, std::move(counterBytes.lastObjectId))}),
        numeric(202, std::move(counterBytes.layout)),
        numeric(100, std::move(modelPropertyBytes))}));
    catalog.entries.push_back(directory(230, {}, {numeric(230, std::move(d230))}));
    catalog.entries.push_back(directory(std::nullopt, QStringLiteral("_ADDPROP_D"), {text(QStringLiteral("_ADDPROP_F"), std::move(definitionBytes))}));
    catalog.entries.push_back(directory(std::nullopt, QStringLiteral("_ADDPROP_TUNING_D"), {text(QStringLiteral("_ADDPROP_TUNING_F"), std::move(tuningBytes))}));
    catalog.entries.push_back(numeric(205, std::move(d205)));
    catalog.entries.push_back(numeric(280, std::move(d280)));
    catalog.entries.push_back(numeric(290, std::move(d290)));
    catalog.entries.push_back(text(QStringLiteral("MetoInfoLinks"), std::move(metaLinks)));
    std::vector<QByteArray> ordered;
    const std::function<void(KompasCatalogEntry&)> place = [&](KompasCatalogEntry& entry) {
        if (!entry.directory) {
            ordered.push_back(std::move(pool[entry.recordIndex]));
            entry.recordIndex = ordered.size() - 1;
        }
        for (auto& child : entry.children) place(child);
    };
    for (auto& entry : catalog.entries) place(entry);
    KompasStoragePrefix prefix;
    QByteArray catalogBytes;
    KompasStorageImage image;
    if (!prepareKompasStorageRecords(ordered, prefix, error) || !encodeKompasCatalog(catalog, prefix, catalogBytes, error) ||
        !finishKompasStorage(prefix, catalogBytes, image, error)) return false;

    // MetaInfo: the assembly's values, and a component per placement naming its part file.
    KompasMetaInfo meta;
    meta.assembly = true;
    meta.designation = options.designation;
    meta.name = options.title;
    meta.material = options.materialName;
    meta.author = options.author;
    meta.organization = options.organization;
    for (const auto& c : components) {
        const auto& part = parts[c.part];
        KompasMetaInfoBody body;
        body.name = part.options.title;
        body.material = part.options.materialName;
        body.relativeSource = part.fileName;
        body.absoluteSource = QDir::toNativeSeparators(folder.filePath(part.fileName));
        body.designation = part.options.designation;
        body.author = part.options.author;
        body.organization = part.options.organization;
        meta.bodies.push_back(std::move(body));
    }
    QByteArray metaInfo;
    if (!encodeKompasMetaInfo(meta, metaInfo, error)) return false;

    // The preview: every component's bodies, meshed in place.
    std::vector<KompasMesh> meshes;
    {
        const double diagonal = std::sqrt((total[3] - total[0]) * (total[3] - total[0]) + (total[4] - total[1]) * (total[4] - total[1]) +
                                          (total[5] - total[2]) * (total[5] - total[2]));
        const auto step = kompasMeshStep(diagonal);
        for (const auto& shapes : inAssembly)
            for (const auto& shape : shapes) {
                KompasMesh mesh;
                if (!kompasBodyMesh(kernel, shape, 1, step, options.color, options.material, mesh, error)) return false;
                meshes.push_back(std::move(mesh));
            }
    }
    KompasPreview preview;
    preview.image = renderKompasPreview(meshes, options.color);
    preview.designation = options.designation.value_or(QString());
    preview.name = options.title;
    preview.author = options.author.value_or(QString());
    QByteArray previewBytes;
    if (!encodeKompasPreview(preview, previewBytes, error)) return false;

    KompasFileInfo fileInfo;
    fileInfo.fileType = 6;
    fileInfo.fileTypeName.clear(); // as KOMPAS 17.1 writes an assembly's
    fileInfo.createdAt = QDateTime::currentDateTime().toString(QStringLiteral("M/d/yyyy H:mm:ss"));
    fileInfo.modifiedAt = fileInfo.createdAt;
    QByteArray fileInfoBytes;
    if (!encodeKompasFileInfo(fileInfo, fileInfoBytes, error)) return false;
    const std::vector<KompasStorageArchiveMember> extras{
        {QByteArrayLiteral("FileInfo"), std::move(fileInfoBytes)},
        {QByteArrayLiteral("Preview"), std::move(previewBytes)},
        {QByteArrayLiteral("MetaInfo"), std::move(metaInfo)}};
    return writeKompasStorageArchive(path, image, extras, error);
}

} // namespace cadnext::gui
