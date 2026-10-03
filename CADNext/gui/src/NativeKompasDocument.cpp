#include "cadnext/gui/NativeKompasDocument.hpp"

#include <QObject>
#include <QDateTime>

#include <cstring>
#include <stdexcept>
#include <utility>
#include <set>

namespace cadnext::gui {
namespace {

constexpr qsizetype kMaxRecordBytes = 32 * 1024 * 1024;
constexpr quint64 kMaxStringUnits = 65536;

struct Reader {
    const QByteArray& bytes;
    qsizetype at = 0;
    quint64 number(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("Truncated document settings");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 value, int width) {
        if (number(width) != value) throw std::runtime_error("Unsupported document settings profile");
    }
    void expectReal(double expected) {
        quint64 bits;
        std::memcpy(&bits, &expected, sizeof(bits));
        expect(bits, 8);
    }
    bool boolean() {
        const auto value = number(1);
        if (value > 1) throw std::runtime_error("Invalid document settings flag");
        return value != 0;
    }
    QString string() {
        const auto count = number(4);
        if (count > kMaxStringUnits || count * 2 > quint64(bytes.size() - at))
            throw std::runtime_error("Invalid document settings string extent");
        QString value;
        value.reserve(qsizetype(count));
        for (quint64 i = 0; i < count; ++i) value.append(QChar(ushort(number(2))));
        return value;
    }
};

struct Writer {
    QByteArray bytes;
    void number(quint64 value, int width) {
        if (bytes.size() > kMaxRecordBytes - width) throw std::runtime_error("Oversized document settings");
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void real(double value) {
        quint64 bits;
        std::memcpy(&bits, &value, sizeof(bits));
        number(bits, 8);
    }
    void string(const QString& value) {
        number(quint64(value.size()), 4);
        for (const auto c : value) number(c.unicode(), 2);
    }
};

void validate(const KompasDocumentSettings& settings) {
    if (settings.title.size() > qsizetype(kMaxStringUnits))
        throw std::runtime_error("Oversized document title");
    if (settings.styles.size() != KompasDocumentSettings::styleCount)
        throw std::runtime_error("Invalid v17 document style count");
    for (const auto& style : settings.styles) {
        if (style.name.size() > qsizetype(kMaxStringUnits))
            throw std::runtime_error("Oversized document style name");
        if (style.color > 0xffffff) throw std::runtime_error("Invalid document style color");
        for (const auto value : style.material)
            if (value > 100) throw std::runtime_error("Invalid document style material field");
    }
}

void validate(const std::vector<KompasDocumentFileLink>& links) {
    if (links.size() > 65536) throw std::runtime_error("Oversized document file-link list");
    std::set<quint16> ids;
    for (const auto& link : links) {
        if (!ids.insert(link.objectId).second) throw std::runtime_error("Duplicate document file-link ID");
        if (!link.nativeMark) throw std::runtime_error("Missing native file-link state field");
        if (link.relativePath.size() > qsizetype(kMaxStringUnits) || link.absolutePath.size() > qsizetype(kMaxStringUnits))
            throw std::runtime_error("Oversized document file-link path");
        if (link.relativePath.isEmpty() && link.absolutePath.isEmpty())
            throw std::runtime_error("Empty document file-link paths");
    }
}

void readProfile(Reader& r, KompasDocumentSettings& settings) {
    // Supported native scalar and separator profile. No opaque header is
    // preserved; different profiles require their own verified field layout.
    r.expectReal(0.064); r.expectReal(0.375); r.expect(0x00040fff, 4);
    settings.assembly = r.boolean();
    r.expect(1, 1); r.expect(0, 8); r.expect(1, 1); r.expect(3, 4);
    for (const auto separator : {ushort('-'), ushort('.')}) {
        r.expect(1, 1); r.expect(1, 1); r.expect(1, 1);
        r.expect(separator, 2); r.expect(2, 4); r.expect(1, 4);
    }
    r.expect(1, 1); r.expect(0, 2); r.expect(1, 4); r.expect(1, 4);
    r.expect(0, 1);
    for (int i = 0; i < 4; ++i) r.expect(1, 1);
    r.expect(0, 4);
}

void writeProfile(Writer& w, const KompasDocumentSettings& settings) {
    w.real(0.064); w.real(0.375); w.number(0x00040fff, 4);
    w.number(settings.assembly, 1);
    w.number(1, 1); w.number(0, 8); w.number(1, 1); w.number(3, 4);
    for (const auto separator : {ushort('-'), ushort('.')}) {
        w.number(1, 1); w.number(1, 1); w.number(1, 1);
        w.number(separator, 2); w.number(2, 4); w.number(1, 4);
    }
    w.number(1, 1); w.number(0, 2); w.number(1, 4); w.number(1, 4);
    w.number(0, 1);
    for (int i = 0; i < 4; ++i) w.number(1, 1);
    w.number(0, 4);
}

QString failure(const std::exception& error) {
    return QObject::tr("Служебные записи документа КОМПАС: %1").arg(QString::fromUtf8(error.what()));
}

} // namespace

bool decodeKompasFileInfo(const QByteArray& bytes, KompasFileInfo& info, QString& error) {
    info = {}; error.clear();
    try {
        if (bytes.size() < 2 || bytes.size() > 128 * 1024 || bytes.size() % 2 ||
            uchar(bytes[0]) != 0xfe || uchar(bytes[1]) != 0xff)
            throw std::runtime_error("Unsupported FileInfo text encoding");
        QString text;
        text.reserve((bytes.size() - 2) / 2);
        for (qsizetype at = 2; at < bytes.size(); at += 2) {
            const ushort unit = (ushort(uchar(bytes[at])) << 8) | uchar(bytes[at + 1]);
            text.append(QChar(unit));
        }
        const auto lines = text.split(QLatin1Char('\n'));
        if (lines.size() < 14 || lines.front() != QLatin1String("[FileInfo]") ||
            !lines.back().isEmpty()) throw std::runtime_error("Invalid FileInfo section");
        qsizetype at = 1;
        const auto value = [&](const char* key) {
            const QString prefix = QString::fromLatin1(key) + QLatin1Char('=');
            if (at + 1 >= lines.size() || !lines[at].startsWith(prefix))
                throw std::runtime_error("Missing or reordered FileInfo field");
            return lines[at++].mid(prefix.size());
        };
        const auto number = [&](const char* key, int base) {
            QString field = value(key);
            if (base == 16) {
                if (!field.startsWith(QLatin1String("0x")))
                    throw std::runtime_error("Invalid FileInfo hexadecimal field");
                field.remove(0, 2);
            }
            bool ok = false;
            const quint32 result = field.toUInt(&ok, base);
            if (!ok || field.isEmpty()) throw std::runtime_error("Invalid FileInfo number");
            return result;
        };
        KompasFileInfo staged;
        staged.applicationName = value("AppName");
        staged.applicationVersion = value("AppVersion");
        staged.buildNumber = value("BuildNum");
        staged.platform = value("AppPlatform");
        staged.mathVersion = number("MathFileVersion", 16);
        staged.applicationFileVersion = number("AppFileVersion", 16);
        staged.fileTypeName = value("FileTypeName");
        staged.fileType = number("FileType", 10);
        staged.creationVersion = number("CreateAppVersion", 16);
        staged.createdAt = value("CreateData");
        staged.modifiedAt = value("ModifyData");
        if (at < lines.size() && lines[at].startsWith(QLatin1String("Author="))) {
            staged.author = value("Author");
            staged.organization = value("OrgName");
            staged.comment = value("Comment");
        }
        const QString autoSave = value("AutoSave");
        if (autoSave != QLatin1String("true") && autoSave != QLatin1String("false"))
            throw std::runtime_error("Invalid FileInfo autosave flag");
        staged.autoSave = autoSave == QLatin1String("true");
        if (at + 1 != lines.size()) throw std::runtime_error("Unexpected FileInfo fields");
        QByteArray canonical;
        if (!encodeKompasFileInfo(staged, canonical, error)) return false;
        if (canonical != bytes) throw std::runtime_error("Noncanonical FileInfo fields");
        info = std::move(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    return true;
}

bool encodeKompasFileInfo(const KompasFileInfo& info, QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear();
    try {
        if (info.applicationName.isEmpty() || info.applicationVersion.isEmpty() ||
            info.buildNumber.isEmpty() || info.platform != QLatin1String("x64") ||
            !info.mathVersion || !info.applicationFileVersion || !info.creationVersion ||
            (info.fileType != 4 && info.fileType != 6) ||
            (info.fileTypeName != QLatin1String("Kompas.m3d") &&
             info.fileTypeName != QLatin1String("Kompas.a3d") && !info.fileTypeName.isEmpty()) ||
            (info.fileTypeName == QLatin1String("Kompas.m3d") && info.fileType != 4) ||
            (info.fileTypeName == QLatin1String("Kompas.a3d") && info.fileType != 6) ||
            bool(info.author) != bool(info.organization) || bool(info.author) != bool(info.comment))
            throw std::runtime_error("Invalid FileInfo document profile");
        for (const auto& date : {info.createdAt, info.modifiedAt}) {
            if (!QDateTime::fromString(date, QStringLiteral("M/d/yyyy H:mm:ss")).isValid() &&
                !QDateTime::fromString(date, QStringLiteral("dd.MM.yyyy HH:mm:ss")).isValid())
                throw std::runtime_error("Invalid FileInfo timestamp");
        }
        QString text = QStringLiteral("[FileInfo]\n");
        const auto append = [&](const char* key, const QString& value) {
            if (value.size() > 65536 || value.contains(QLatin1Char('\n')) ||
                value.contains(QLatin1Char('\r')) || value.contains(QChar(u'\0')))
                throw std::runtime_error("Invalid FileInfo text field");
            text += QString::fromLatin1(key) + QLatin1Char('=') + value + QLatin1Char('\n');
        };
        const auto version = [&](const char* key, quint32 value) {
            append(key, QStringLiteral("0x%1").arg(value, 0, 16));
        };
        append("AppName", info.applicationName);
        append("AppVersion", info.applicationVersion);
        append("BuildNum", info.buildNumber);
        append("AppPlatform", info.platform);
        version("MathFileVersion", info.mathVersion);
        version("AppFileVersion", info.applicationFileVersion);
        append("FileTypeName", info.fileTypeName);
        append("FileType", QString::number(info.fileType));
        version("CreateAppVersion", info.creationVersion);
        append("CreateData", info.createdAt);
        append("ModifyData", info.modifiedAt);
        if (info.author) {
            append("Author", *info.author);
            append("OrgName", *info.organization);
            append("Comment", *info.comment);
        }
        append("AutoSave", info.autoSave ? QStringLiteral("true") : QStringLiteral("false"));
        if (text.size() > 65535) throw std::runtime_error("Oversized FileInfo");
        QByteArray staged;
        staged.reserve(2 + text.size() * 2);
        staged.append(char(0xfe)); staged.append(char(0xff));
        for (const QChar c : text) {
            staged.append(char(c.unicode() >> 8)); staged.append(char(c.unicode() & 0xff));
        }
        bytes = std::move(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    return true;
}

bool decodeKompasDocumentSettings(const QByteArray& bytes,
                                  KompasDocumentSettings& settings, QString& error) {
    settings = {}; error.clear(); KompasDocumentSettings staged; Reader r{bytes};
    try {
        if (bytes.size() > kMaxRecordBytes) throw std::runtime_error("Oversized document settings");
        staged.title = r.string(); readProfile(r, staged);
        r.expect(KompasDocumentSettings::styleCount, 4);
        staged.styles.reserve(KompasDocumentSettings::styleCount);
        for (std::size_t i = 0; i < KompasDocumentSettings::styleCount; ++i) {
            KompasDocumentStyle style;
            style.name = r.string(); style.color = quint32(r.number(4));
            for (auto& value : style.material) value = quint8(r.number(1));
            for (auto& value : style.nativeFlags) value = r.boolean();
            staged.styles.push_back(std::move(style));
        }
        if (r.at != bytes.size()) throw std::runtime_error("Trailing document settings data");
        validate(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    settings = std::move(staged); return true;
}

bool encodeKompasDocumentSettings(const KompasDocumentSettings& settings,
                                  QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(settings); w.string(settings.title); writeProfile(w, settings);
        w.number(settings.styles.size(), 4);
        for (const auto& style : settings.styles) {
            w.string(style.name); w.number(style.color, 4);
            for (const auto value : style.material) w.number(value, 1);
            for (const auto value : style.nativeFlags) w.number(value, 1);
        }
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes); return true;
}

bool decodeKompasDocumentFileLinks(const QByteArray& bytes,
                                   std::vector<KompasDocumentFileLink>& links, QString& error) {
    links.clear(); error.clear(); std::vector<KompasDocumentFileLink> staged; Reader r{bytes};
    try {
        if (bytes.size() > kMaxRecordBytes) throw std::runtime_error("Oversized document file-link record");
        r.expect(1, 1); const auto count = r.number(8);
        if (count > 65536) throw std::runtime_error("Oversized document file-link list");
        for (quint64 i = 0; i < count; ++i) {
            KompasDocumentFileLink link;
            r.expect(2, 1); r.expect(0x80, 1); r.expect(0x4821, 2); r.expect(1, 1);
            link.objectId = quint16(r.number(2)); r.expect(1, 1);
            link.relativePath = r.string(); link.absolutePath = r.string();
            link.nativeMark = quint32(r.number(4)); r.expect(0, 4); r.expect(4, 8); r.expect(0, 1);
            staged.push_back(std::move(link));
        }
        if (r.at != bytes.size()) throw std::runtime_error("Trailing document file-link data");
        validate(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    links = std::move(staged); return true;
}

bool encodeKompasDocumentFileLinks(const std::vector<KompasDocumentFileLink>& links,
                                   QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(links); w.number(1, 1); w.number(links.size(), 8);
        for (const auto& link : links) {
            w.number(2, 1); w.number(0x80, 1); w.number(0x4821, 2); w.number(1, 1);
            w.number(link.objectId, 2); w.number(1, 1);
            w.string(link.relativePath); w.string(link.absolutePath);
            w.number(*link.nativeMark, 4); w.number(0, 4); w.number(4, 8); w.number(0, 1);
        }
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes); return true;
}

} // namespace cadnext::gui
