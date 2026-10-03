#include "cadnext/gui/NativeSolidWorksFeatureBodies.hpp"

#include <QObject>
#include <QSet>

#include <zlib.h>

#include <algorithm>

namespace cadnext::gui {
namespace {

constexpr quint32 kMaxItems = 4096;
constexpr quint64 kMaxBodyBytes = 256ull * 1024 * 1024;
constexpr quint64 kMaxTotalBytes = 512ull * 1024 * 1024;
const QByteArray kMagic = QByteArray::fromHex("231dd571da8148a2a85898b21b89ef99");
// A transmit longer than this is stored in pieces, each deflated on its own: the first of this
// size, the rest of kNextPiece (one witness: a 1 238 091-byte body of a SOLIDWORKS 2022 part,
// 1 048 576 + 46 × 4096 + 1099; the 89 other transmits of the samples are shorter and whole).
constexpr quint32 kFirstPiece = 0x100000;
constexpr quint32 kNextPiece = 4096;

bool validName(const SolidWorksFeatureBodies& feature) {
    return !feature.featureName.isEmpty() && feature.featureName.size() <= kMaxItems &&
        !feature.featureName.contains(QChar(u'\0')) &&
        (feature.unicodeName ||
         QString::fromLatin1(feature.featureName.toLatin1()) == feature.featureName);
}

class Reader {
public:
    explicit Reader(const QByteArray& bytes) : bytes_(bytes) {}
    qsizetype at = 0;
    quint64 remaining() const { return quint64(bytes_.size() - at); }
    bool byte(quint8& value) {
        if (!remaining()) return false;
        value = uchar(bytes_[at++]); return true;
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
    bool string(SolidWorksFeatureBodies& feature) {
        quint32 size = 0;
        if (!length(size)) return false;
        feature.unicodeName = size == 0xfffe;
        if (feature.unicodeName && !length(size)) return false;
        if (size > kMaxItems || remaining() < quint64(size) * (feature.unicodeName ? 2 : 1)) return false;
        if (feature.unicodeName) {
            feature.featureName.reserve(size);
            for (quint32 i = 0; i < size; ++i) {
                quint16 c = 0; if (!word(c)) return false;
                feature.featureName += QChar(c);
            }
        } else {
            feature.featureName = QString::fromLatin1(bytes_.constData() + at, size);
            at += size;
        }
        return validName(feature);
    }
    bool body(SolidWorksFeatureBody& body, quint64& decodedTotal) {
        quint32 outerLength = 0, innerLength = 0, unpacked = 0, packed = 0;
        if (!integer(body.nativeField) || !byte(body.nativeByte) || !integer(outerLength)) return false;
        const quint64 end = quint64(at) + outerLength;
        if (outerLength < 37 || outerLength > kMaxBodyBytes + 37 || end > quint64(bytes_.size()) ||
            !byte(body.wrapperByte) || !integer(innerLength) ||
            innerLength != outerLength - 5 || bytes_.mid(at, 16) != kMagic) return false;
        at += 16;
        if (!integer(unpacked) || !integer(packed) || unpacked < 4) return false;
        // The pieces of the transmit, then the two closing words (zero in every document read).
        for (;;) {
            if (!unpacked || unpacked > kMaxBodyBytes || !packed || quint64(at) + packed + 8 > end ||
                quint64(body.parasolid.size()) + unpacked > kMaxBodyBytes) return false;
            decodedTotal += unpacked;
            if (decodedTotal > kMaxTotalBytes) return false;
            const qsizetype start = body.parasolid.size();
            body.parasolid.resize(start + unpacked);
            z_stream stream{};
            stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(bytes_.constData() + at));
            stream.avail_in = packed;
            stream.next_out = reinterpret_cast<Bytef*>(body.parasolid.data() + start);
            stream.avail_out = unpacked;
            if (inflateInit(&stream) != Z_OK) return false;
            const int status = inflate(&stream, Z_FINISH);
            inflateEnd(&stream);
            if (status != Z_STREAM_END || stream.total_in != packed || stream.total_out != unpacked) return false;
            at += packed;
            if (!integer(unpacked) || !integer(packed)) return false;
            if (quint64(at) == end) break;
        }
        body.nativeTrailer = {unpacked, packed};
        return body.parasolid.startsWith(QByteArray("PS\0\0", 4));
    }
private:
    bool length(quint32& size) {
        quint8 first = 0; if (!byte(first)) return false;
        size = first; if (first != 0xff) return true;
        quint16 small = 0; if (!word(small)) return false;
        size = small; return small != 0xffff || integer(size);
    }
    const QByteArray& bytes_;
};

class Writer {
public:
    QByteArray bytes;
    void byte(quint8 value) { bytes += char(value); }
    void word(quint16 value) { byte(quint8(value)); byte(quint8(value >> 8)); }
    void integer(quint32 value) { word(quint16(value)); word(quint16(value >> 16)); }
    void string(const SolidWorksFeatureBodies& feature) {
        if (feature.unicodeName) { byte(0xff); word(0xfffe); }
        const auto size = feature.featureName.size();
        if (size < 255) byte(quint8(size));
        else { byte(0xff); word(quint16(size)); }
        if (feature.unicodeName) for (QChar c : feature.featureName) word(c.unicode());
        else bytes += feature.featureName.toLatin1();
    }
    bool body(const SolidWorksFeatureBody& body) {
        // The pieces, each with its two lengths before it.
        QByteArray pieces;
        const auto word = [&pieces](quint32 value) {
            for (int i = 0; i < 4; ++i) pieces += char((value >> (8 * i)) & 0xFF);
        };
        for (qsizetype from = 0; from < body.parasolid.size();) {
            const qsizetype count = std::min<qsizetype>(from ? kNextPiece : kFirstPiece, body.parasolid.size() - from);
            uLongf size = compressBound(uLong(count));
            QByteArray packed(qsizetype(size), '\0');
            if (compress2(reinterpret_cast<Bytef*>(packed.data()), &size,
                          reinterpret_cast<const Bytef*>(body.parasolid.constData() + from),
                          uLong(count), 1) != Z_OK) return false; // level 1: SOLIDWORKS's own bytes back
            word(quint32(count)); word(quint32(size));
            pieces.append(packed.constData(), qsizetype(size));
            if (quint64(pieces.size()) > kMaxBodyBytes) return false;
            from += count;
        }
        if (quint64(bytes.size()) + pieces.size() + 38 > kMaxTotalBytes) return false;
        integer(body.nativeField); byte(body.nativeByte);
        integer(quint32(pieces.size() + 29));
        byte(body.wrapperByte); integer(quint32(pieces.size() + 24));
        bytes += kMagic;
        bytes += pieces;
        for (const auto value : body.nativeTrailer) integer(value);
        return true;
    }
};

bool decode(const QByteArray& bytes, SolidWorksFeatureBodyLayout layout,
            std::vector<SolidWorksFeatureBodies>& features) {
    Reader r(bytes); quint32 count = 0;
    if (!r.integer(count) || count > kMaxItems) return false;
    std::vector<SolidWorksFeatureBodies> staged;
    QSet<QString> names;
    quint64 decodedTotal = 0, bodyCount = 0;
    for (quint32 i = 0; i < count; ++i) {
        SolidWorksFeatureBodies feature; quint32 size = 1;
        if (!r.string(feature) || names.contains(feature.featureName)) return false;
        if (layout == SolidWorksFeatureBodyLayout::GroupedBodies &&
            (!r.integer(feature.nativeField) || !r.integer(size))) return false;
        if (size > kMaxItems || (bodyCount += size) > kMaxItems) return false;
        names.insert(feature.featureName);
        feature.bodies.resize(size);
        for (auto& body : feature.bodies) if (!r.body(body, decodedTotal)) return false;
        staged.push_back(std::move(feature));
    }
    if (r.remaining()) return false;
    features = std::move(staged); return true;
}

} // namespace

bool decodeSolidWorksFeatureBodies(const QByteArray& bytes,
    std::vector<SolidWorksFeatureBodies>& features, QString& error,
    SolidWorksFeatureBodyLayout* layout) {
    features.clear(); error.clear();
    if (layout) *layout = SolidWorksFeatureBodyLayout::GroupedBodies;
    if (bytes.size() > qsizetype(kMaxTotalBytes)) {
        error = QObject::tr("Раздел тел операций SOLIDWORKS превышает 512 МиБ."); return false;
    }
    // A zero-entry section has the same four bytes in both versions; its
    // geometry and ownership are identical, so use the current layout.
    if (bytes == QByteArray(4, '\0')) return true;
    unsigned matches = 0;
    std::vector<SolidWorksFeatureBodies> staged;
    SolidWorksFeatureBodyLayout detected = SolidWorksFeatureBodyLayout::GroupedBodies;
    for (const auto kind : {SolidWorksFeatureBodyLayout::SingleBodyEntries, SolidWorksFeatureBodyLayout::GroupedBodies}) {
        std::vector<SolidWorksFeatureBodies> candidate;
        if (decode(bytes, kind, candidate)) {
            ++matches; detected = kind; staged = std::move(candidate);
        }
    }
    if (matches != 1) {
        error = QObject::tr("Раздел тел операций SOLIDWORKS повреждён или имеет неоднозначную схему."); return false;
    }
    features = std::move(staged);
    if (layout) *layout = detected;
    return true;
}

std::vector<SolidWorksFeatureBody> findSolidWorksStoredBodies(const QByteArray& stream) {
    std::vector<SolidWorksFeatureBody> bodies;
    quint64 decodedTotal = 0;
    // A body record: 14 bytes (a word, a byte, the two lengths with a byte between), then the marker.
    for (qsizetype at = stream.indexOf(kMagic, 14); at >= 0; at = stream.indexOf(kMagic, at + 1)) {
        Reader r(stream);
        r.at = at - 14;
        SolidWorksFeatureBody body;
        if (!r.body(body, decodedTotal)) continue;
        bodies.push_back(std::move(body));
        if (bodies.size() >= kMaxItems) break;
        at = r.at - 1;
    }
    return bodies;
}

bool encodeSolidWorksFeatureBodies(const std::vector<SolidWorksFeatureBodies>& features,
    QByteArray& bytes, QString& error, SolidWorksFeatureBodyLayout layout) {
    bytes.clear(); error.clear();
    QSet<QString> names;
    quint64 decodedTotal = 0, bodyCount = 0;
    if (features.size() > kMaxItems ||
        (layout != SolidWorksFeatureBodyLayout::SingleBodyEntries && layout != SolidWorksFeatureBodyLayout::GroupedBodies)) {
        error = QObject::tr("Слишком много операций в разделе тел SOLIDWORKS."); return false;
    }
    for (const auto& feature : features) {
        if (!validName(feature) || names.contains(feature.featureName) ||
            feature.bodies.size() > kMaxItems || (bodyCount += feature.bodies.size()) > kMaxItems) {
            error = QObject::tr("Недопустимые имена или владельцы тел операций SOLIDWORKS."); return false;
        }
        if (layout == SolidWorksFeatureBodyLayout::SingleBodyEntries &&
            (feature.nativeField || feature.bodies.size() != 1)) {
            error = QObject::tr("Старая структура SOLIDWORKS требует одно тело на имя без поля группы."); return false;
        }
        names.insert(feature.featureName);
        for (const auto& body : feature.bodies) {
            decodedTotal += quint64(body.parasolid.size());
            if (!body.parasolid.startsWith(QByteArray("PS\0\0", 4)) ||
                quint64(body.parasolid.size()) > kMaxBodyBytes || decodedTotal > kMaxTotalBytes) {
                error = QObject::tr("Недопустимая точная геометрия тела операции SOLIDWORKS."); return false;
            }
        }
    }
    Writer w; w.integer(quint32(features.size()));
    for (const auto& feature : features) {
        w.string(feature);
        if (layout == SolidWorksFeatureBodyLayout::GroupedBodies) {
            w.integer(feature.nativeField); w.integer(quint32(feature.bodies.size()));
        }
        for (const auto& body : feature.bodies) if (!w.body(body)) {
            error = QObject::tr("Не удалось сжать раздел тел операций SOLIDWORKS."); return false;
        }
        if (quint64(w.bytes.size()) > kMaxTotalBytes) {
            error = QObject::tr("Раздел тел операций SOLIDWORKS превышает 512 МиБ."); return false;
        }
    }
    bytes = std::move(w.bytes); return true;
}

} // namespace cadnext::gui
