#include "cadnext/gui/NativeSolidWorksDocument.hpp"

#include <QMap>
#include <QObject>

#include <cmath>
#include <cstring>

namespace cadnext::gui {
namespace {

constexpr qsizetype kMaxBytes = 64 * 1024 * 1024;
constexpr quint32 kMaxItems = 4096;
constexpr quint32 kMaxStamps = 8192;
constexpr quint32 kMaxMapIndex = 0x7ffe;

struct Layout {
    unsigned strings;
    bool extraByte;
    bool trailer;
    unsigned extension;
    bool extraReferenceWord = false;
    unsigned trailerWords = 4;
};
std::optional<Layout> layoutInfo(SolidWorksDocumentHeaderLayout layout) {
    switch (layout) {
    case SolidWorksDocumentHeaderLayout::Classic: return Layout{1, false, false, 0};
    case SolidWorksDocumentHeaderLayout::Standard: return Layout{2, false, true, 0};
    case SolidWorksDocumentHeaderLayout::Extended: return Layout{3, false, true, 6};
    case SolidWorksDocumentHeaderLayout::ExtendedByte: return Layout{3, true, true, 7};
    case SolidWorksDocumentHeaderLayout::StandardCompact: return Layout{2, false, false, 0};
    case SolidWorksDocumentHeaderLayout::ExtendedByteModern: return Layout{3, true, true, 16, true};
    case SolidWorksDocumentHeaderLayout::StandardLegacy: return Layout{2, false, true, 0, false, 3};
    }
    return std::nullopt;
}

class Writer {
public:
    QByteArray bytes;
    void byte(quint8 value) { bytes += char(value); }
    void word(quint16 value) { byte(quint8(value)); byte(quint8(value >> 8)); }
    void integer(quint32 value) { word(quint16(value)); word(quint16(value >> 16)); }
    void real(double value) {
        quint64 bits = 0; std::memcpy(&bits, &value, sizeof(bits));
        integer(quint32(bits)); integer(quint32(bits >> 32));
    }
    void count(quint32 size) { word(quint16(size)); }
    void string(const SolidWorksArchiveString& value) {
        if (value.unicode) { byte(0xff); word(0xfffe); }
        if (value.text.size() < 255) byte(quint8(value.text.size()));
        else { byte(0xff); word(quint16(value.text.size())); }
        if (value.unicode) for (QChar c : value.text) word(c.unicode());
        else bytes += value.text.toLatin1();
    }
    quint32 object(const QByteArray& name, quint16 schema = 1) {
        const auto found = classes_.constFind(name);
        if (found == classes_.cend()) {
            classes_.insert(name, next_++);
            word(0xffff); word(schema); word(quint16(name.size())); bytes += name;
        } else word(quint16(0x8000 | found.value()));
        return next_++;
    }
    void handle(const std::shared_ptr<SolidWorksArchiveString>& value) {
        const auto found = handles_.constFind(value.get());
        if (found != handles_.cend()) { word(quint16(found.value())); return; }
        const auto id = object("moCStringHandle_c");
        handles_.insert(value.get(), id); string(*value);
    }
    bool valid() const { return next_ <= kMaxMapIndex && bytes.size() <= kMaxBytes; }
private:
    quint32 next_ = 1;
    QMap<QByteArray, quint32> classes_;
    QMap<const SolidWorksArchiveString*, quint32> handles_;
};

class Reader {
public:
    explicit Reader(const QByteArray& bytes) : bytes_(bytes) {}
    qsizetype remaining() const { return bytes_.size() - at_; }
    bool byte(quint8& value) {
        if (remaining() < 1) return false;
        value = uchar(bytes_[at_++]); return true;
    }
    bool word(quint16& value) {
        quint8 low = 0, high = 0;
        if (!byte(low) || !byte(high)) return false;
        value = quint16(low) | quint16(high) << 8; return true;
    }
    bool integer(quint32& value) {
        quint16 low = 0, high = 0;
        if (!word(low) || !word(high)) return false;
        value = quint32(low) | quint32(high) << 16; return true;
    }
    bool real(double& value) {
        quint32 low = 0, high = 0;
        if (!integer(low) || !integer(high)) return false;
        const quint64 bits = quint64(low) | quint64(high) << 32;
        std::memcpy(&value, &bits, sizeof(bits)); return std::isfinite(value);
    }
    bool count(quint32& size) {
        quint16 small = 0; if (!word(small)) return false;
        size = small;
        if (small == 0xffff && !integer(size)) return false;
        return size <= kMaxItems;
    }
    bool prefix(std::optional<quint32>& value) {
        const auto before = at_; quint16 tag = 0;
        if (!word(tag)) return false;
        at_ = before;
        if (tag == 0xffff) return true;
        quint32 field = 0;
        if (!integer(field) || field != 1) return false;
        value = field; return true;
    }
    bool string(SolidWorksArchiveString& value) {
        quint32 size = 0; if (!length(size)) return false;
        value.unicode = size == 0xfffe;
        if (value.unicode && !length(size)) return false;
        if (size > kMaxItems || quint64(remaining()) < quint64(size) * (value.unicode ? 2 : 1)) return false;
        value.text.clear(); value.text.reserve(size);
        if (value.unicode) {
            for (quint32 i = 0; i < size; ++i) {
                quint16 c = 0; if (!word(c)) return false; value.text += QChar(c);
            }
        } else {
            value.text = QString::fromLatin1(bytes_.constData() + at_, size); at_ += size;
        }
        return !value.text.contains(QChar(u'\0'));
    }
    bool object(const QByteArray& name, quint16 schema = 1) {
        quint16 tag = 0; return word(tag) && objectTag(tag, name, schema);
    }
    bool nullOrList(const QByteArray& name, bool& allocated, quint32& size) {
        quint16 tag = 0; if (!word(tag)) return false;
        allocated = tag != 0; size = 0;
        return !allocated || (objectTag(tag, name, 1) && count(size));
    }
    bool handle(std::shared_ptr<SolidWorksArchiveString>& value) {
        quint16 tag = 0; if (!word(tag)) return false;
        if (tag < 0x8000) {
            const auto found = handles_.constFind(tag);
            if (found == handles_.cend()) return false;
            value = found.value(); return true;
        }
        if (!objectTag(tag, "moCStringHandle_c", 1)) return false;
        auto text = std::make_shared<SolidWorksArchiveString>();
        if (!string(*text)) return false;
        handles_.insert(next_ - 1, text); value = std::move(text); return true;
    }
private:
    bool objectTag(quint16 tag, const QByteArray& name, quint16 schema) {
        if (tag == 0xffff) {
            quint16 actualSchema = 0, size = 0;
            if (!word(actualSchema) || actualSchema != schema || !word(size) || size != name.size() ||
                remaining() < size || bytes_.mid(at_, size) != name || classes_.contains(name)) return false;
            at_ += size; classes_.insert(name, next_++);
        } else {
            const auto found = classes_.constFind(name);
            if (!(tag & 0x8000) || found == classes_.cend() || (tag & 0x7fff) != found.value()) return false;
        }
        return ++next_ <= kMaxMapIndex;
    }
    bool length(quint32& size) {
        quint8 first = 0; if (!byte(first)) return false;
        size = first; if (first != 0xff) return true;
        quint16 small = 0; if (!word(small)) return false;
        size = small; return small != 0xffff || integer(size);
    }
    const QByteArray& bytes_;
    qsizetype at_ = 0;
    quint32 next_ = 1;
    QMap<QByteArray, quint32> classes_;
    QMap<quint32, std::shared_ptr<SolidWorksArchiveString>> handles_;
};

bool validString(const SolidWorksArchiveString& value) {
    return value.text.size() <= kMaxItems && !value.text.contains(QChar(u'\0')) &&
        (value.unicode || QString::fromLatin1(value.text.toLatin1()) == value.text);
}
bool validReference(const SolidWorksDocumentReference& ref, Layout layout, bool current) {
    if (!ref.path || !ref.title || !validString(*ref.path) || !validString(*ref.title) ||
        ref.documentType < 2 || ref.documentType > (current ? 3 : 5) ||
        ref.auxiliaryStrings.size() != layout.strings ||
        ref.nativeField3.has_value() != layout.extraReferenceWord ||
        (!layout.extraByte && ref.extendedByte) || !validString(ref.configurationName) ||
        (ref.nativeFields[3] == 0xffffffff) != current) return false;
    for (const auto& text : ref.auxiliaryStrings) if (!validString(text)) return false;
    return true;
}
bool valid(const SolidWorksDocumentHeader& h) {
    const auto info = layoutInfo(h.layout);
    if (!info || (h.nativePrefixWord && *h.nativePrefixWord != 1) ||
        h.authors.size() > kMaxItems || h.secondaryStrings.size() > kMaxItems ||
        h.logs.size() > kMaxItems || h.references.size() > kMaxItems ||
        h.nativeTrailer.has_value() != info->trailer || h.nativeExtension.size() != info->extension ||
        !validReference(h.currentDocument, *info, true)) return false;
    if (info->trailerWords == 3 && (*h.nativeTrailer)[3]) return false;
    for (const auto& value : h.authors) if (!validString(value)) return false;
    for (const auto& value : h.secondaryStrings) if (!validString(value)) return false;
    quint32 stampCount = 0;
    for (const auto& log : h.logs) {
        if (!validString(log.featureName) || log.featureId > h.nextFeatureId || log.stamps.size() > kMaxItems) return false;
        stampCount += quint32(log.stamps.size()); if (stampCount > kMaxStamps) return false;
        for (const auto& stamp : log.stamps)
            if (stamp.authorIndex >= h.authors.size() || !validString(stamp.text)) return false;
    }
    for (const auto& ref : h.references) if (!validReference(ref, *info, false)) return false;
    if (h.nativeBounds) for (const auto value : *h.nativeBounds) if (!std::isfinite(value)) return false;
    return true;
}

bool readReference(Reader& r, Layout layout, SolidWorksDocumentReference& ref) {
    quint8 virtualFlag = 0;
    if (!r.object("moExtObject_c") || !r.handle(ref.path) || !r.handle(ref.title) ||
        !r.word(ref.documentType) || !r.byte(virtualFlag) || virtualFlag > 1 || !r.integer(ref.modifiedAt)) return false;
    ref.virtualDocument = virtualFlag != 0;
    ref.auxiliaryStrings.resize(layout.strings);
    for (auto& text : ref.auxiliaryStrings) if (!r.string(text)) return false;
    if ((layout.extraByte && !r.byte(ref.extendedByte)) || !r.byte(ref.nativeByte)) return false;
    for (auto& value : ref.nativeFields) if (!r.integer(value)) return false;
    if (!r.string(ref.configurationName) || !r.integer(ref.configurationId)) return false;
    for (auto& value : ref.nativeFields2) if (!r.integer(value)) return false;
    if (layout.extraReferenceWord) {
        ref.nativeField3.emplace();
        if (!r.integer(*ref.nativeField3)) return false;
    }
    return true;
}
void writeReference(Writer& w, Layout layout, const SolidWorksDocumentReference& ref) {
    w.object("moExtObject_c"); w.handle(ref.path); w.handle(ref.title);
    w.word(ref.documentType); w.byte(ref.virtualDocument); w.integer(ref.modifiedAt);
    for (const auto& text : ref.auxiliaryStrings) w.string(text);
    if (layout.extraByte) w.byte(ref.extendedByte);
    w.byte(ref.nativeByte);
    for (const auto value : ref.nativeFields) w.integer(value);
    w.string(ref.configurationName); w.integer(ref.configurationId);
    for (const auto value : ref.nativeFields2) w.integer(value);
    if (ref.nativeField3) w.integer(*ref.nativeField3);
}

bool decode(const QByteArray& bytes, SolidWorksDocumentHeaderLayout kind, SolidWorksDocumentHeader& h) {
    Reader r(bytes); const auto layout = *layoutInfo(kind); h.layout = kind;
    quint32 size = 0;
    if (!r.object("moHeader_c") || !r.prefix(h.nativePrefixWord) ||
        !r.object("su_CStringArray", 0) || !r.count(size)) return false;
    h.authors.resize(size); for (auto& value : h.authors) if (!r.string(value)) return false;
    if (!r.object("su_CStringArray", 0) || !r.count(size)) return false;
    h.secondaryStrings.resize(size); for (auto& value : h.secondaryStrings) if (!r.string(value)) return false;
    if (!r.object("suObList") || !r.count(size)) return false;
    h.logs.resize(size); quint32 stampCount = 0;
    for (auto& log : h.logs) {
        if (!r.object("moLogs_c") || !r.count(size)) return false;
        stampCount += size; if (stampCount > kMaxStamps) return false;
        log.stamps.resize(size);
        for (auto& stamp : log.stamps)
            if (!r.object("moStamp_c") || !r.integer(stamp.nativeAction) || !r.word(stamp.authorIndex) ||
                !r.integer(stamp.time) || !r.string(stamp.text)) return false;
        if (!r.integer(log.featureId) || !r.string(log.featureName)) return false;
    }
    bool allocated = false;
    if (!r.integer(h.createdAt) || !r.integer(h.nextFeatureId) ||
        !r.nullOrList("moExtObjectList_c", allocated, size) || (allocated && !size)) return false;
    h.references.resize(size);
    for (auto& ref : h.references) if (!readReference(r, layout, ref)) return false;
    if (!r.integer(h.modifiedStamp) || !readReference(r, layout, h.currentDocument)) return false;
    for (auto& value : h.nativeFields) if (!r.integer(value)) return false;
    if (!r.word(h.nativeWord)) return false;
    for (auto& value : h.nativeCounters) if (!r.integer(value)) return false;
    if (!r.nullOrList("suObList", h.allocatedEmptyList, size) || size) return false;
    for (auto& value : h.nativeFields2) if (!r.integer(value)) return false;
    quint32 bounds = 0; if (!r.integer(bounds) || bounds > 1) return false;
    if (bounds) {
        h.nativeBounds.emplace();
        for (auto& value : *h.nativeBounds) if (!r.real(value)) return false;
    }
    if (layout.trailer) {
        h.nativeTrailer.emplace();
        for (unsigned i = 0; i < layout.trailerWords; ++i)
            if (!r.integer((*h.nativeTrailer)[i])) return false;
    }
    h.nativeExtension.resize(layout.extension);
    for (auto& value : h.nativeExtension) if (!r.integer(value)) return false;
    return !r.remaining() && valid(h);
}

} // namespace

bool decodeSolidWorksDocumentHeader(const QByteArray& bytes, SolidWorksDocumentHeader& header, QString& error) {
    header = {}; error.clear();
    if (bytes.isEmpty() || bytes.size() > kMaxBytes) {
        error = QObject::tr("Заголовок документа SOLIDWORKS пуст или превышает 64 МиБ."); return false;
    }
    unsigned matches = 0; SolidWorksDocumentHeader staged;
    for (const auto layout : {SolidWorksDocumentHeaderLayout::Classic, SolidWorksDocumentHeaderLayout::Standard,
                             SolidWorksDocumentHeaderLayout::Extended, SolidWorksDocumentHeaderLayout::ExtendedByte,
                             SolidWorksDocumentHeaderLayout::StandardCompact, SolidWorksDocumentHeaderLayout::ExtendedByteModern,
                             SolidWorksDocumentHeaderLayout::StandardLegacy}) {
        SolidWorksDocumentHeader candidate;
        if (decode(bytes, layout, candidate)) { ++matches; staged = std::move(candidate); }
    }
    if (matches != 1) {
        error = QObject::tr("Заголовок документа SOLIDWORKS повреждён или имеет неподдерживаемую либо неоднозначную схему.");
        return false;
    }
    header = std::move(staged); return true;
}

bool encodeSolidWorksDocumentHeader(const SolidWorksDocumentHeader& header, QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear();
    if (!valid(header)) {
        error = QObject::tr("Недопустимые строки, ссылки, журнал или схема заголовка документа SOLIDWORKS."); return false;
    }
    const auto layout = *layoutInfo(header.layout); Writer w;
    w.object("moHeader_c");
    if (header.nativePrefixWord) w.integer(*header.nativePrefixWord);
    w.object("su_CStringArray", 0); w.count(quint32(header.authors.size()));
    for (const auto& value : header.authors) w.string(value);
    w.object("su_CStringArray", 0); w.count(quint32(header.secondaryStrings.size()));
    for (const auto& value : header.secondaryStrings) w.string(value);
    w.object("suObList"); w.count(quint32(header.logs.size()));
    for (const auto& log : header.logs) {
        w.object("moLogs_c"); w.count(quint32(log.stamps.size()));
        for (const auto& stamp : log.stamps) {
            w.object("moStamp_c"); w.integer(stamp.nativeAction); w.word(stamp.authorIndex);
            w.integer(stamp.time); w.string(stamp.text);
        }
        w.integer(log.featureId); w.string(log.featureName);
        if (!w.valid()) {
            error = QObject::tr("Журнал документа SOLIDWORKS превышает предел размера или таблицы объектов."); return false;
        }
    }
    w.integer(header.createdAt); w.integer(header.nextFeatureId);
    if (header.references.empty()) w.word(0);
    else { w.object("moExtObjectList_c"); w.count(quint32(header.references.size())); }
    for (const auto& ref : header.references) {
        writeReference(w, layout, ref);
        if (!w.valid()) {
            error = QObject::tr("Ссылки документа SOLIDWORKS превышают предел размера или таблицы объектов."); return false;
        }
    }
    w.integer(header.modifiedStamp); writeReference(w, layout, header.currentDocument);
    for (const auto value : header.nativeFields) w.integer(value);
    w.word(header.nativeWord);
    for (const auto value : header.nativeCounters) w.integer(value);
    if (header.allocatedEmptyList) { w.object("suObList"); w.count(0); } else w.word(0);
    for (const auto value : header.nativeFields2) w.integer(value);
    w.integer(header.nativeBounds.has_value());
    if (header.nativeBounds) for (const auto value : *header.nativeBounds) w.real(value);
    if (header.nativeTrailer)
        for (unsigned i = 0; i < layout.trailerWords; ++i) w.integer((*header.nativeTrailer)[i]);
    for (const auto value : header.nativeExtension) w.integer(value);
    if (!w.valid()) {
        error = QObject::tr("Заголовок документа SOLIDWORKS превышает предел размера или таблицы объектов."); return false;
    }
    bytes = std::move(w.bytes); return true;
}

} // namespace cadnext::gui
