#include "cadnext/gui/NativeSolidWorksWriter.hpp"
#include "cadnext/gui/NativeSolidWorksConfiguration.hpp"
#include "cadnext/gui/NativeSolidWorksFeatureBodies.hpp"
#include "cadnext/gui/NativeCompoundFile.hpp"

#include "cadnext/gui/ParasolidXtWriter.hpp"

#include <QSaveFile>
#include <QObject>
#include <QSet>

#include <zlib.h>

namespace cadnext::gui {
namespace {

constexpr quint64 kMaxSectionBytes = 256ull * 1024 * 1024;
constexpr quint64 kMaxTotalBytes = 512ull * 1024 * 1024;

bool validIdentity(const SolidWorksImportedBodyIdentity& identity) {
    return identity.featureId > 0 && identity.bodyAtomId > 0;
}

std::vector<ParasolidXtIntegerBodyAttribute> bodyAttributes(const SolidWorksImportedBodyIdentity& identity) {
    return {{"ATOM_ID_2001", {identity.bodyAtomId}, true},
            {"LAST_BODY_MODIFYING_FEATURE_ID", {identity.featureId}, true}};
}

void word(QByteArray& bytes, quint16 value) {
    bytes.append(char(value & 0xff));
    bytes.append(char(value >> 8));
}

void integer(QByteArray& bytes, quint32 value) {
    word(bytes, quint16(value & 0xffff));
    word(bytes, quint16(value >> 16));
}

bool partitionSection(const std::string& partition, QByteArray& section, QString& error) {
    if (partition.empty() || quint64(partition.size()) > kMaxSectionBytes) {
        error = QObject::tr("Нативный раздел конфигурации SOLIDWORKS пуст или превышает 256 МиБ.");
        return false;
    }
    uLongf size = compressBound(uLong(partition.size()));
    if (quint64(size) + 28 > kMaxSectionBytes) {
        error = QObject::tr("Сжатый раздел конфигурации SOLIDWORKS превышает предел размера.");
        return false;
    }
    QByteArray packed(qsizetype(size), '\0');
    if (compress2(reinterpret_cast<Bytef*>(packed.data()), &size,
                  reinterpret_cast<const Bytef*>(partition.data()),
                  uLong(partition.size()), Z_DEFAULT_COMPRESSION) != Z_OK) {
        error = QObject::tr("Не удалось сжать нативную геометрию конфигурации SOLIDWORKS.");
        return false;
    }
    packed.resize(qsizetype(size));
    if (quint64(packed.size()) + 28 > kMaxSectionBytes) {
        error = QObject::tr("Раздел конфигурации SOLIDWORKS превышает предел размера.");
        return false;
    }
    integer(section, quint32(24 + packed.size())); // bytes following the chain length
    section += QByteArray::fromHex("231dd571da8148a2a85898b21b89ef99");
    integer(section, quint32(partition.size()));
    integer(section, quint32(packed.size()));
    section += packed;
    return true;
}

} // namespace

bool encodeSolidWorksConfigurationSections(
    kernel::OcctKernel& kernel,
    const std::vector<SolidWorksWriteConfiguration>& configurations,
    std::vector<SolidWorksWriteSection>& sections, QString& error) {
    sections.clear();
    error.clear();
    if (configurations.empty() || configurations.size() > 4096) {
        error = QObject::tr("Для записи SOLIDWORKS требуется от 1 до 4096 конфигураций.");
        return false;
    }
    QSet<quint32> ids;
    QSet<QString> names;
    for (const auto& config : configurations) {
        if (config.name.isEmpty() || config.name.size() > 4096 ||
            config.name.contains(QChar(u'\0')) || ids.contains(config.id) ||
            names.contains(config.name)) {
            error = QObject::tr("Идентификаторы и имена конфигураций SOLIDWORKS должны быть уникальны; имя — от 1 до 4096 знаков.");
            return false;
        }
        if (config.importedBody && !validIdentity(*config.importedBody)) {
            error = QObject::tr("Идентификаторы операции и тела SOLIDWORKS должны быть положительными.");
            return false;
        }
        ids.insert(config.id);
        names.insert(config.name);
    }
    std::vector<SolidWorksWriteSection> staged;
    SolidWorksConfigurationHeader header;
    for (std::size_t i = 0; i < configurations.size(); ++i) {
        const auto& config = configurations[i];
        SolidWorksConfigurationHeaderEntry entry;
        entry.id = config.id;
        entry.name = entry.displayName = config.name;
        entry.mostRecent = i == 0;
        entry.modifiedStamp = 1;
        // Native part flags for independent configurations. The separate
        // mostRecent word selects the current configuration; native flag 0x80
        // is not a reliable substitute for that word in multi-configuration data.
        entry.nativeFlags = 0x80400100u;
        entry.nativeStamps = {1, 1};
        header.entries.push_back(std::move(entry));
    }
    SolidWorksWriteSection headerSection{"Contents/CMgrHdr2", {}};
    if (!encodeSolidWorksConfigurationHeader(header, headerSection.data, error)) return false;
    staged.push_back(std::move(headerSection));
    quint64 total = quint64(staged.front().data.size());
    quint64 decodedTotal = total;
    for (const auto& config : configurations) {
        const auto partition = encodeParasolidXtPartition(kernel, config.shape,
            config.importedBody ? bodyAttributes(*config.importedBody)
                                : std::vector<ParasolidXtIntegerBodyAttribute>{});
        if (!partition.isOk()) {
            error = QObject::tr("Конфигурация %1: %2")
                        .arg(config.name, QString::fromStdString(partition.error().message));
            return false;
        }
        decodedTotal += quint64(partition.value().size());
        if (decodedTotal > kMaxTotalBytes) {
            error = QObject::tr("Распакованная геометрия конфигураций SOLIDWORKS превышает 512 МиБ.");
            return false;
        }
        SolidWorksWriteSection section;
        section.name = "Contents/Config-" + QByteArray::number(config.id) + "-Partition";
        if (!partitionSection(partition.value(), section.data, error)) return false;
        total += quint64(section.data.size());
        if (total > kMaxTotalBytes) {
            error = QObject::tr("Нативные разделы SOLIDWORKS превышают 512 МиБ.");
            return false;
        }
        staged.push_back(std::move(section));
    }
    sections = std::move(staged);
    return true;
}

bool encodeSolidWorksImportedFeatureBodySection(
    kernel::OcctKernel& kernel, quint32 configurationId, const QString& featureName,
    const std::vector<kernel::ShapeHandle>& shapes,
    SolidWorksWriteSection& section, QString& error, SolidWorksFeatureBodyLayout layout,
    const std::vector<SolidWorksImportedBodyIdentity>& identities) {
    section = {}; error.clear();
    if (shapes.empty() || shapes.size() > 4096 ||
        (layout == SolidWorksFeatureBodyLayout::SingleBodyEntries && shapes.size() != 1) || featureName.isEmpty() ||
        featureName.size() > 4096 || featureName.contains(QChar(u'\0'))) {
        error = QObject::tr("Для операции импорта SOLIDWORKS нужны имя и от 1 до 4096 тел.");
        return false;
    }
    if (!identities.empty()) {
        if (identities.size() != shapes.size()) {
            error = QObject::tr("Для каждого сохраняемого тела SOLIDWORKS нужен один идентификатор.");
            return false;
        }
        QSet<qint32> atoms;
        for (const auto& identity : identities) {
            if (!validIdentity(identity) || identity.featureId != identities.front().featureId ||
                atoms.contains(identity.bodyAtomId)) {
                error = QObject::tr("Тела операции SOLIDWORKS должны иметь общий идентификатор операции и различные положительные идентификаторы тел.");
                return false;
            }
            atoms.insert(identity.bodyAtomId);
        }
    }
    SolidWorksFeatureBodies feature;
    feature.featureName = featureName;
    quint64 total = 0;
    for (std::size_t i = 0; i < shapes.size(); ++i) {
        const auto bodyStream = encodeParasolidXtBodyStream(kernel, shapes[i],
            identities.empty() ? std::vector<ParasolidXtIntegerBodyAttribute>{}
                               : bodyAttributes(identities[i]));
        if (!bodyStream.isOk()) {
            error = QString::fromStdString(bodyStream.error().message); return false;
        }
        total += quint64(bodyStream.value().size());
        if (total > kMaxTotalBytes) {
            error = QObject::tr("Геометрия тел операции SOLIDWORKS превышает 512 МиБ."); return false;
        }
        SolidWorksFeatureBody body;
        body.parasolid = QByteArray::fromStdString(bodyStream.value());
        feature.bodies.push_back(std::move(body));
    }
    QByteArray bytes;
    if (!encodeSolidWorksFeatureBodies({feature}, bytes, error, layout)) return false;
    section.name = "Config-" + QByteArray::number(configurationId) + "-FeatureBodies/LocalBodies";
    section.data = std::move(bytes);
    return true;
}

bool writeSolidWorksConfigurationContainer(
    kernel::OcctKernel& kernel,
    const std::vector<SolidWorksWriteConfiguration>& configurations,
    const QString& path, QString& error) {
    error.clear();
    std::vector<SolidWorksWriteSection> sections;
    if (!encodeSolidWorksConfigurationSections(kernel, configurations, sections, error)) return false;
    CompoundFile file;
    file.entries.push_back({"Contents", CompoundFileEntry::Kind::Storage});
    for (const auto& section : sections) {
        const auto name = QString::fromLatin1(section.name);
        if (!name.startsWith("Contents/") || name.size() <= 9) {
            error = QObject::tr("Недопустимое имя раздела SOLIDWORKS.");
            return false;
        }
        file.entries.push_back({name, CompoundFileEntry::Kind::Stream, section.data});
    }
    QByteArray encoded;
    if (!encodeCompoundFile(file, encoded, error)) return false;
    QSaveFile output(path);
    if (!output.open(QIODevice::WriteOnly) || output.write(encoded) != encoded.size() || !output.commit()) {
        error = QObject::tr("Не удалось сохранить контейнер SOLIDWORKS: %1").arg(output.errorString());
        return false;
    }
    return true;
}

} // namespace cadnext::gui
