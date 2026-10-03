#include "cadnext/gui/NativeSolidWorksConfiguration.hpp"

#include <QMap>
#include <QObject>
#include <QSet>

namespace cadnext::gui {
namespace {

constexpr qsizetype kMaxHeaderBytes = 64 * 1024 * 1024;
constexpr quint32 kNoParent = 0xffffffff;

void word(QByteArray& bytes, quint16 value) {
    bytes += char(value & 0xff); bytes += char(value >> 8);
}
void integer(QByteArray& bytes, quint32 value) {
    word(bytes, quint16(value)); word(bytes, quint16(value >> 16));
}
void length(QByteArray& bytes, quint32 size) {
    if (size < 255) bytes += char(size);
    else { bytes += char(0xff); word(bytes, quint16(size)); }
}
void string(QByteArray& bytes, const QString& text, bool unicode) {
    if (unicode) { bytes += char(0xff); word(bytes, 0xfffe); }
    length(bytes, quint32(text.size()));
    if (unicode) for (QChar c : text) word(bytes, c.unicode());
    else bytes += text.toLatin1();
}
void objectClass(QByteArray& bytes, const QByteArray& name) {
    word(bytes, 0xffff); word(bytes, 1); word(bytes, quint16(name.size())); bytes += name;
}

class Reader {
public:
    explicit Reader(const QByteArray& bytes) : bytes_(bytes) {}
    qsizetype remaining() const { return bytes_.size() - at_; }
    bool word(quint16& value) {
        if (remaining() < 2) return false;
        value = quint16(uchar(bytes_[at_])) | quint16(uchar(bytes_[at_ + 1])) << 8;
        at_ += 2; return true;
    }
    bool integer(quint32& value) {
        quint16 low = 0, high = 0;
        if (!word(low) || !word(high)) return false;
        value = quint32(low) | quint32(high) << 16; return true;
    }
    bool objectClass(const QByteArray& name, bool repeated = false) {
        quint16 tag = 0, schema = 0, size = 0;
        if (!word(tag)) return false;
        if (repeated && tag == 0x8003) return true;
        if (tag != 0xffff || !word(schema) || schema != 1 || !word(size) ||
            size != name.size() || remaining() < size || bytes_.mid(at_, size) != name) return false;
        at_ += size; return true;
    }
    bool string(QString& text, bool& unicode) {
        quint32 size = 0;
        if (!length(size)) return false;
        unicode = size == 0xfffe;
        if (unicode && !length(size)) return false;
        if (size > 4096 || quint64(remaining()) < quint64(size) * (unicode ? 2 : 1)) return false;
        text.clear(); text.reserve(qsizetype(size));
        if (unicode) {
            for (quint32 i = 0; i < size; ++i) {
                quint16 c = 0; if (!word(c)) return false; text += QChar(c);
            }
        } else {
            text = QString::fromLatin1(bytes_.constData() + at_, qsizetype(size)); at_ += size;
        }
        return !text.contains(QChar(u'\0'));
    }
private:
    bool length(quint32& size) {
        if (!remaining()) return false;
        size = uchar(bytes_[at_++]);
        if (size != 255) return true;
        quint16 n = 0; if (!word(n)) return false;
        size = n; return n != 0xffff || integer(size);
    }
    const QByteArray& bytes_;
    qsizetype at_ = 0;
};

bool valid(const SolidWorksConfigurationHeader& header) {
    if (header.entries.empty() || header.entries.size() > 4096) return false;
    if (!header.managerFooter && (header.extendedStamps || header.savedAt || header.trailingField)) return false;
    QMap<quint32, std::size_t> ids;
    QSet<QString> names;
    unsigned recent = 0;
    for (std::size_t i = 0; i < header.entries.size(); ++i) {
        const auto& e = header.entries[i];
        if (e.id == kNoParent || e.name.isEmpty() || ids.contains(e.id) || names.contains(e.name)) return false;
        ids.insert(e.id, i); names.insert(e.name); recent += e.mostRecent;
        const std::array<QString, 4> texts{e.name, e.displayName, e.description, e.alternatePartName};
        for (std::size_t j = 0; j < texts.size(); ++j) {
            if (texts[j].size() > 4096 || texts[j].contains(QChar(u'\0'))) return false;
            if (!e.unicodeStrings[j] && QString::fromLatin1(texts[j].toLatin1()) != texts[j]) return false;
        }
        if (!header.extendedStamps && e.nativeStamps != std::array<quint32, 2>{}) return false;
    }
    if (recent != 1) return false;
    std::vector<unsigned char> state(header.entries.size(), 0);
    for (std::size_t i = 0; i < header.entries.size(); ++i) {
        std::vector<std::size_t> path;
        std::size_t next = i;
        while (state[next] != 2) {
            if (state[next] == 1) return false;
            state[next] = 1; path.push_back(next);
            const auto parent = header.entries[next].parentId;
            if (parent == kNoParent) break;
            const auto found = ids.constFind(parent);
            if (found == ids.cend()) return false;
            next = found.value();
        }
        for (const auto index : path) state[index] = 2;
    }
    return true;
}

bool decode(const QByteArray& bytes, bool extended, bool footer, SolidWorksConfigurationHeader& header) {
    Reader reader(bytes);
    quint16 size = 0;
    if (!reader.objectClass("dmConfigMgrHeader_c") || !reader.word(size) || !size || size > 4096) return false;
    header.extendedStamps = extended;
    header.managerFooter = footer;
    header.entries.reserve(size);
    for (quint16 i = 0; i < size; ++i) {
        SolidWorksConfigurationHeaderEntry e;
        quint32 recent = 0;
        if (!reader.objectClass("dmConfigHeader_c", i > 0) || !reader.integer(recent) || recent > 1 ||
            !reader.string(e.name, e.unicodeStrings[0]) || !reader.integer(e.id) ||
            !reader.integer(e.modifiedStamp) || !reader.string(e.displayName, e.unicodeStrings[1]) ||
            !reader.integer(e.parentId) || !reader.integer(e.parentField) ||
            !reader.string(e.description, e.unicodeStrings[2]) ||
            !reader.string(e.alternatePartName, e.unicodeStrings[3]) ||
            !reader.integer(e.nativeFlags) || !reader.integer(e.nativeField)) return false;
        e.mostRecent = recent != 0;
        if (extended && (!reader.integer(e.nativeStamps[0]) || !reader.integer(e.nativeStamps[1]))) return false;
        header.entries.push_back(std::move(e));
    }
    if (footer) {
        quint32 format = 0;
        if ((reader.remaining() != 8 && reader.remaining() != 12) ||
            !reader.integer(header.savedAt) || !reader.integer(format) || format != 2) return false;
        if (reader.remaining()) {
            quint32 value = 0; if (!reader.integer(value)) return false; header.trailingField = value;
        }
    }
    return reader.remaining() == 0 && valid(header);
}

} // namespace

bool decodeSolidWorksConfigurationHeader(const QByteArray& bytes,
    SolidWorksConfigurationHeader& header, QString& error) {
    header = {}; error.clear();
    if (bytes.isEmpty() || bytes.size() > kMaxHeaderBytes) {
        error = QObject::tr("Заголовок конфигураций SOLIDWORKS пуст или превышает 64 МиБ."); return false;
    }
    SolidWorksConfigurationHeader legacyHeader, shortHeader, extendedHeader;
    const bool legacyOk = decode(bytes, false, false, legacyHeader);
    const bool shortOk = decode(bytes, false, true, shortHeader);
    const bool extendedOk = decode(bytes, true, true, extendedHeader);
    if (int(legacyOk) + int(shortOk) + int(extendedOk) != 1) {
        error = QObject::tr("Заголовок конфигураций SOLIDWORKS повреждён или имеет неоднозначную схему."); return false;
    }
    header = legacyOk ? std::move(legacyHeader) : shortOk ? std::move(shortHeader) : std::move(extendedHeader);
    return true;
}

bool encodeSolidWorksConfigurationHeader(const SolidWorksConfigurationHeader& header,
    QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear();
    if (!valid(header)) {
        error = QObject::tr("Недопустимые имена, идентификаторы, активная конфигурация или связи родителей SOLIDWORKS."); return false;
    }
    QByteArray staged;
    objectClass(staged, "dmConfigMgrHeader_c"); word(staged, quint16(header.entries.size()));
    for (std::size_t i = 0; i < header.entries.size(); ++i) {
        const auto& e = header.entries[i];
        if (!i) objectClass(staged, "dmConfigHeader_c"); else word(staged, 0x8003);
        integer(staged, e.mostRecent); string(staged, e.name, e.unicodeStrings[0]);
        integer(staged, e.id); integer(staged, e.modifiedStamp);
        string(staged, e.displayName, e.unicodeStrings[1]);
        integer(staged, e.parentId); integer(staged, e.parentField);
        string(staged, e.description, e.unicodeStrings[2]);
        string(staged, e.alternatePartName, e.unicodeStrings[3]);
        integer(staged, e.nativeFlags); integer(staged, e.nativeField);
        if (header.extendedStamps) { integer(staged, e.nativeStamps[0]); integer(staged, e.nativeStamps[1]); }
        if (staged.size() > kMaxHeaderBytes - 12) {
            error = QObject::tr("Заголовок конфигураций SOLIDWORKS превышает 64 МиБ."); return false;
        }
    }
    if (header.managerFooter) {
        integer(staged, header.savedAt); integer(staged, 2);
        if (header.trailingField) integer(staged, *header.trailingField);
    }
    bytes = std::move(staged); return true;
}

} // namespace cadnext::gui
