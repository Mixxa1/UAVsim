#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/gui/NativeDwgR2007.hpp"
#include "cadnext/gui/NativeDwgImport.hpp"
#include "cadnext/gui/NativeDxfImport.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QObject>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <functional>
#include <set>

namespace cadnext::gui {

namespace {

// A DWG bit stream: bits most significant first; the "bit" primitives of the specification.
class Bits {
public:
    Bits(const uchar* data, std::size_t bytes) : data_(data), size_(bytes * 8) {}
    // Bits [begin, end) of `data`.
    Bits(const uchar* data, std::size_t begin, std::size_t end) : position(begin), data_(data), size_(end) {}

    std::size_t position = 0; // in bits
    bool ok = true;

    unsigned bit() {
        if (position >= size_) return ok = false, 0u;
        const unsigned b = (data_[position >> 3] >> (7 - (position & 7))) & 1u;
        ++position;
        return b;
    }
    unsigned bits(int count) {
        unsigned value = 0;
        while (count-- > 0) value = (value << 1) | bit();
        return value;
    }
    unsigned RC() { return bits(8); }
    unsigned RS() {
        const unsigned low = RC();
        return low | (RC() << 8);
    }
    quint32 RL() {
        const quint32 low = RS();
        return low | (quint32(RS()) << 16);
    }
    double RD() {
        quint64 raw = 0;
        for (int i = 0; i < 8; ++i) raw |= quint64(RC()) << (8 * i);
        double value = 0;
        std::memcpy(&value, &raw, sizeof value);
        return value;
    }
    int BS() {
        switch (bits(2)) {
        case 0: return qint16(RS());
        case 1: return int(RC());
        case 2: return 0;
        default: return 256;
        }
    }
    qint32 BL() {
        switch (bits(2)) {
        case 0: return qint32(RL());
        case 1: return qint32(RC());
        case 2: return 0;
        default: return ok = false, 0;
        }
    }
    double BD() {
        switch (bits(2)) {
        case 0: return RD();
        case 1: return 1.0;
        case 2: return 0.0;
        default: return ok = false, 0.0;
        }
    }
    // A double with a default: kept, its low four bytes replaced, its low six bytes replaced, or read whole.
    double DD(double fallback) {
        const unsigned code = bits(2);
        if (code == 3) return RD();
        if (code == 0) return fallback;
        quint64 raw = 0;
        std::memcpy(&raw, &fallback, sizeof raw);
        if (code == 2) {
            raw = (raw & ~(quint64(0xFFFF) << 32)) | quint64(RC()) << 32 | quint64(RC()) << 40;
        }
        quint64 low = 0;
        for (int i = 0; i < 4; ++i) low |= quint64(RC()) << (8 * i);
        raw = (raw & ~quint64(0xFFFFFFFF)) | low;
        double value = 0;
        std::memcpy(&value, &raw, sizeof value);
        return value;
    }
    void BD3(double* v) {
        for (int i = 0; i < 3; ++i) v[i] = BD();
    }
    // A handle reference: code and counter in one byte, then the counter's bytes, most significant first.
    quint64 H(int* code = nullptr) {
        const unsigned first = RC();
        if (code) *code = int(first >> 4);
        quint64 value = 0;
        for (unsigned i = 0; i < (first & 15u); ++i) value = (value << 8) | RC();
        return value;
    }
    // A reference in a handle stream, made absolute: codes 6 and 8 are the referring object's handle
    // plus or minus one, 0xA and 0xC plus or minus the value.
    quint64 reference(quint64 own) {
        int code = 0;
        const quint64 value = H(&code);
        switch (code) {
        case 6: return own + 1;
        case 8: return own - 1;
        case 0xA: return own + value;
        case 0xC: return own - value;
        default: return value;
        }
    }
    QByteArray TV() {
        const int length = BS();
        QByteArray text;
        for (int i = 0; i < length && ok; ++i) text.append(char(RC()));
        return text;
    }
    // AutoCAD 2007 on: text in a string stream, its length in characters, then UTF-16.
    QString TU() {
        const int length = BS();
        QString text;
        for (int i = 0; i < length && ok; ++i) text.append(QChar(char16_t(RS())));
        return text;
    }
    // A count of bytes in three bits, then those bytes, least significant first.
    quint64 BLL() {
        const unsigned count = bits(3);
        quint64 value = 0;
        for (unsigned i = 0; i < count; ++i) value |= quint64(RC()) << (8 * i);
        return value;
    }
    // The object type from AutoCAD 2010 on: a byte, a byte past 0x1F0, or a short.
    int OT() {
        switch (bits(2)) {
        case 0: return int(RC());
        case 1: return int(RC()) + 0x1F0;
        default: return int(RS());
        }
    }
    std::size_t end() const { return size_; }
    void skipBytes(qint64 count) {
        if (count < 0 || position + std::size_t(count) * 8 > size_) return void(ok = false);
        position += std::size_t(count) * 8;
    }

private:
    const uchar* data_;
    std::size_t size_;
};

// Byte primitives outside the bit stream.
quint32 le32(const QByteArray& b, qint64 at) {
    return quint32(uchar(b[at])) | quint32(uchar(b[at + 1])) << 8 | quint32(uchar(b[at + 2])) << 16 | quint32(uchar(b[at + 3])) << 24;
}

const char* fixedTypeName(int type) {
    static const char* names[] = {"UNUSED", "TEXT", "ATTRIB", "ATTDEF", "BLOCK", "ENDBLK", "SEQEND", "INSERT", "MINSERT", "?9",
                                  "VERTEX_2D", "VERTEX_3D", "VERTEX_MESH", "VERTEX_PFACE", "VERTEX_PFACE_FACE", "POLYLINE_2D",
                                  "POLYLINE_3D", "ARC", "CIRCLE", "LINE", "DIMENSION_ORDINATE", "DIMENSION_LINEAR", "DIMENSION_ALIGNED",
                                  "DIMENSION_ANG3PT", "DIMENSION_ANG2LN", "DIMENSION_RADIUS", "DIMENSION_DIAMETER", "POINT", "3DFACE",
                                  "POLYLINE_PFACE", "POLYLINE_MESH", "SOLID", "TRACE", "SHAPE", "VIEWPORT", "ELLIPSE", "SPLINE",
                                  "REGION", "3DSOLID", "BODY", "RAY", "XLINE", "DICTIONARY", "OLEFRAME", "MTEXT", "LEADER", "TOLERANCE",
                                  "MLINE", "BLOCK_CONTROL", "BLOCK_HEADER", "LAYER_CONTROL", "LAYER", "STYLE_CONTROL", "STYLE", "?54",
                                  "?55", "LTYPE_CONTROL", "LTYPE", "?58", "?59", "VIEW_CONTROL", "VIEW", "UCS_CONTROL", "UCS",
                                  "VPORT_CONTROL", "VPORT", "APPID_CONTROL", "APPID", "DIMSTYLE_CONTROL", "DIMSTYLE", "VP_ENT_HDR_CONTROL",
                                  "VP_ENT_HDR", "GROUP", "MLINESTYLE", "OLE2FRAME", "?75", "LONG_TRANSACTION", "LWPOLYLINE", "HATCH",
                                  "XRECORD", "ACDBPLACEHOLDER", "VBA_PROJECT", "LAYOUT"};
    return type >= 0 && type < int(sizeof names / sizeof *names) ? names[type] : nullptr;
}

// Fixed types that are entities.
bool fixedEntity(int type) {
    return (type >= 1 && type <= 41) || (type >= 44 && type <= 47) || type == 74 || type == 77 || type == 78;
}

// A string stream (AutoCAD 2007 on): at the end of an object's data, flagged by its last bit, its size
// in the 16 bits (or 32, the top one set) before that. The text between them and the size.
bool stringStream(const uchar* data, std::size_t begin, std::size_t end, Bits& strings) {
    if (end < begin + 17) return false;
    Bits b(data, begin, end);
    b.position = end - 1;
    if (!b.bit()) return false;
    b.position = end - 17;
    quint64 size = b.RS();
    std::size_t at = end - 17;
    if (size & 0x8000) {
        if (end < begin + 33) return false;
        b.position = end - 33;
        const quint64 high = b.RS();
        size = (size & 0x7FFF) | (high << 15);
        at = end - 33;
    }
    if (size > at - begin) return false;
    strings = Bits(data, at - size, at);
    return true;
}

// The data of a plane entity, after the common entity data; `r2010` for AutoCAD 2010 on (a polyline's
// vertex ids). False for a type that is none of them.
bool readPlanar(Bits& b, const QString& name, bool r2010, DwgPlanar& e) {
    using K = DwgPlanar::Kind;
    const auto thickness = [&]() { return b.bit() ? 0.0 : b.BD(); };
    const auto extrusion = [&](double* v) {
        if (b.bit()) v[0] = 0.0, v[1] = 0.0, v[2] = 1.0;
        else b.BD3(v);
    };
    if (name == QLatin1String("LINE")) {
        e.kind = K::Line;
        const bool flat = b.bit();
        e.start[0] = b.RD();
        e.end[0] = b.DD(e.start[0]);
        e.start[1] = b.RD();
        e.end[1] = b.DD(e.start[1]);
        if (!flat) {
            e.start[2] = b.RD();
            e.end[2] = b.DD(e.start[2]);
        }
        e.thickness = thickness();
        extrusion(e.extrusion);
    } else if (name == QLatin1String("CIRCLE") || name == QLatin1String("ARC")) {
        e.kind = name == QLatin1String("ARC") ? K::Arc : K::Circle;
        b.BD3(e.center);
        e.radius = b.BD();
        e.thickness = thickness();
        extrusion(e.extrusion);
        if (e.kind == K::Arc) {
            e.startAngle = b.BD();
            e.endAngle = b.BD();
        }
    } else if (name == QLatin1String("ELLIPSE")) {
        e.kind = K::Ellipse;
        b.BD3(e.center);
        b.BD3(e.majorAxis);
        b.BD3(e.extrusion);
        e.ratio = b.BD();
        e.startAngle = b.BD();
        e.endAngle = b.BD();
    } else if (name == QLatin1String("LWPOLYLINE")) {
        e.kind = K::Polyline;
        const int flags = b.BS();
        if (flags & 4) e.widths = b.BD() != 0.0 || e.widths;
        if (flags & 8) e.elevation = b.BD();
        if (flags & 2) e.thickness = b.BD();
        if (flags & 1) b.BD3(e.extrusion);
        const qint32 count = b.BL();
        const qint32 bulges = (flags & 16) ? b.BL() : 0;
        const qint32 ids = (r2010 && (flags & 1024)) ? b.BL() : 0;
        const qint32 widths = (flags & 32) ? b.BL() : 0;
        if (!b.ok || count < 0 || count > 1000000 || bulges < 0 || bulges > count || ids < 0 || ids > count || widths < 0 || widths > count)
            return b.ok = false, true;
        for (qint32 i = 0; i < count && b.ok; ++i) {
            std::array<double, 2> p{};
            if (i == 0) {
                p[0] = b.RD();
                p[1] = b.RD();
            } else {
                p[0] = b.DD(e.points.back()[0]);
                p[1] = b.DD(e.points.back()[1]);
            }
            e.points.push_back(p);
        }
        e.bulges.assign(std::size_t(count), 0.0);
        for (qint32 i = 0; i < bulges && b.ok; ++i) e.bulges[std::size_t(i)] = b.BD();
        for (qint32 i = 0; i < ids && b.ok; ++i) b.BL();
        for (qint32 i = 0; i < widths && b.ok; ++i) {
            const double from = b.BD(), to = b.BD();
            e.widths = e.widths || from != 0.0 || to != 0.0;
        }
        e.closed = flags & 512;
    } else {
        return false;
    }
    return true;
}

} // namespace

double dwgMillimetresPerUnit(int insunits) {
    switch (insunits) {
    case 1: return 25.4;
    case 2: return 304.8;
    case 3: return 1609344.0;
    case 4: return 1.0;
    case 5: return 10.0;
    case 6: return 1000.0;
    case 7: return 1.0e6;
    case 8: return 25.4e-6;
    case 9: return 25.4e-3;
    case 10: return 914.4;
    case 11: return 1.0e-7;
    case 12: return 1.0e-6;
    case 13: return 1.0e-3;
    case 14: return 100.0;
    case 15: return 1.0e4;
    case 16: return 1.0e5;
    default: return 0.0;
    }
}

QString dwgTypeName(const DwgR2000File& file, int type) {
    for (const DwgClass& c : file.classes)
        if (c.number == type) return c.dxfName;
    if (const char* name = fixedTypeName(type)) return QString::fromLatin1(name);
    return QStringLiteral("type %1").arg(type);
}

// The objects of an R13–R2000 file (their locations in the file) or of an R2004 one (in its objects'
// section): each a modular short size, then its bit stream — type, where its handles begin, its handle,
// extended data; R2004 adds an extension-dictionary flag and colours with flags.
void readObjectsR2000(const QByteArray& bytes, const std::vector<std::pair<quint64, qint64>>& map, DwgR2000File& file, bool r2004) {
    // The objects: a modular short size, then that many bytes of bit stream.
    const auto within = [&](qint64 at, qint64 length) { return at >= 0 && length >= 0 && at + length <= bytes.size(); };
    for (const auto& [handle, location] : map) {
        if (!within(location, 2)) continue;
        qint64 p = location;
        quint32 size = 0;
        for (int shift = 0; within(p, 2); shift += 15) {
            const unsigned word = uchar(bytes[p]) | (unsigned(uchar(bytes[p + 1])) << 8);
            p += 2;
            size |= quint32(word & 0x7FFF) << shift;
            if (!(word & 0x8000)) break;
        }
        if (!within(p, size) || size == 0) continue;
        Bits b(reinterpret_cast<const uchar*>(bytes.constData()) + p, size);
        DwgObject object;
        object.offset = quint32(location);
        object.type = b.BS();
        const quint32 handleStream = b.RL(); // where the handles begin, in bits
        object.handle = b.H();
        // Extended entity data.
        for (int extended = b.BS(); b.ok && extended != 0; extended = b.BS()) {
            b.H();
            b.skipBytes(extended);
        }
        bool entity = fixedEntity(object.type);
        for (const DwgClass& c : file.classes)
            if (c.number == object.type) entity = c.entity;
        object.entity = entity;
        if (!entity && object.type == 49 && b.ok) {
            // A block header: reactors, then the table entry's name and flags, then the base point.
            b.BL();
            if (r2004) b.bit();               // no extension dictionary, from 2004 on
            DwgBlock block;
            block.handle = object.handle;
            block.name = QString::fromLatin1(b.TV());
            b.bit();                          // 64-flag
            b.BS();                           // xref index + 1
            b.bit();                          // dependent on an xref
            block.anonymous = b.bit();
            b.bit();                          // has attributes
            block.xref = b.bit();
            const bool overlaid = b.bit();
            b.bit();                          // loaded
            if (r2004 && !block.xref && !overlaid) block.owned = b.BL(); // owned entities, from 2004 on
            b.BD3(block.base);
            block.xrefPath = QString::fromLatin1(b.TV());
            if (r2004) {
                // The rest, to its end (checked there from 2004 on): inserts' counts, description, preview.
                while (b.ok && b.RC() != 0) {
                }
                b.TV();
                b.skipBytes(b.BL());
                if (b.ok && b.position == handleStream) file.blocks.push_back(block);
                else ++file.misread;
            } else if (b.ok) {
                file.blocks.push_back(block);
            }
        }
        if (entity && b.ok) {
            // Common entity data, R2000.
            if (b.bit()) b.skipBytes(b.RL()); // a graphic image
            object.entityMode = int(b.bits(2));
            const qint32 reactors = b.BL();
            // From 2004 on: whether it has no extension dictionary; the neighbours' links are gone (a block
            // lists its entities instead). Before: the links' flag.
            const bool noDictionary = r2004 && b.bit();
            const bool noLinks = r2004 || b.bit();
            // The colour: an index, or from 2004 on with flags — an RGB value unless a colour object says
            // it (its handle in the stream), a transparency.
            const unsigned colour = unsigned(b.BS()) & 0xFFFF;
            const unsigned colourFlags = r2004 ? colour >> 8 : 0;
            if ((colourFlags & 0x80) && !(colourFlags & 0x40)) b.BL();
            if (colourFlags & 0x20) b.BL();
            b.BD();                           // line type scale
            const unsigned lineTypeFlags = b.bits(2);
            const unsigned plotStyleFlags = b.bits(2);
            b.BS();                           // invisibility
            b.RC();                           // line weight
            // The handles every entity starts its stream with: owner (inside a block), reactors,
            // extension dictionary, the neighbours' links, layer, line type, plot style.
            const auto commonHandles = [&](Bits& h) {
                h.position = handleStream;
                if (object.entityMode == 0) object.owner = h.reference(object.handle);
                for (qint32 i = 0; i < reactors && h.ok; ++i) h.reference(object.handle);
                if (!noDictionary) h.reference(object.handle);
                if (!noLinks) {
                    h.reference(object.handle);
                    h.reference(object.handle);
                }
                if (colourFlags & 0x40) h.reference(object.handle);
                h.reference(object.handle);
                if (lineTypeFlags == 3) h.reference(object.handle);
                if (plotStyleFlags == 3) h.reference(object.handle);
            };
            if (object.type == 7 && b.ok) {
                DwgInsert insert;
                insert.handle = object.handle;
                insert.entityMode = object.entityMode;
                b.BD3(insert.point);
                switch (b.bits(2)) {
                case 3: break;
                case 1:
                    insert.scale[1] = b.DD(1.0);
                    insert.scale[2] = b.DD(1.0);
                    break;
                case 2:
                    insert.scale[0] = insert.scale[1] = insert.scale[2] = b.RD();
                    break;
                default:
                    insert.scale[0] = b.RD();
                    insert.scale[1] = b.DD(insert.scale[0]);
                    insert.scale[2] = b.DD(insert.scale[0]);
                }
                insert.rotation = b.BD();
                b.BD3(insert.extrusion);
                if (b.bit() && r2004) b.BL(); // has attributes, and from 2004 on how many
                Bits h = b;
                commonHandles(h);
                insert.owner = object.owner;
                insert.block = h.reference(object.handle);
                if (b.ok && h.ok && b.position == handleStream) file.inserts.push_back(insert);
                else ++file.misread;
            } else {
                Bits h = b;
                commonHandles(h);
            }
            // Plane geometry, its data ending exactly where the handles begin.
            QString name;
            if (const char* fixed = fixedTypeName(object.type)) name = QString::fromLatin1(fixed);
            for (const DwgClass& c : file.classes)
                if (c.number == object.type) name = c.dxfName;
            DwgPlanar planar;
            Bits data = b;
            if (b.ok && readPlanar(data, name, false, planar)) {
                if (data.ok && data.position == handleStream) {
                    planar.handle = object.handle;
                    planar.owner = object.owner;
                    planar.entityMode = object.entityMode;
                    file.planar.push_back(std::move(planar));
                } else {
                    ++file.misread;
                }
            }
            // A Mechanical Desktop part (AcAdPart) is a solid of its own class: its data begins as a 3DSOLID's.
            bool solidClass = false;
            for (const DwgClass& c : file.classes)
                if (c.number == object.type && c.cplusplus == QLatin1String("AcAdPart")) solidClass = true;
            if (b.ok && (object.type == 37 || object.type == 38 || object.type == 39 || solidClass)) {
                // An ACIS body: empty flag, an unknown bit, the version; version 1 carries SAT text in
                // blocks, each printable character written as 159 - c (spaces and line breaks as they are).
                if (!b.bit()) {
                    b.bit();
                    if (const int acisVersion = b.BS(); acisVersion == 1) {
                        for (qint32 block = b.BL(); b.ok && block > 0; block = b.BL())
                            for (qint32 i = 0; i < block && b.ok; ++i) {
                                const unsigned c = b.RC();
                                object.acis.append(char(c <= 32 ? c : (159 - c) & 0xFF));
                            }
                    } else if (acisVersion == 2) {
                        // Binary ACIS (SAB) straight after, as far as its end marker.
                        QByteArray sab;
                        while (b.ok && b.position + 8 <= handleStream) {
                            sab.append(char(b.RC()));
                            if (sab.endsWith("End-of-ACIS-data") || sab.endsWith("End-of-ASM-data")) break;
                        }
                        if (sab.startsWith("ACIS BinaryFile") || sab.startsWith("ASM BinaryFile")) object.acis = sab;
                    }
                }
            }
        }
        file.objects.push_back(std::move(object));
    }
}

bool readDwgR2000(const QString& path, DwgR2000File& file, QString& error) {
    QFile input(path);
    if (!input.open(QIODevice::ReadOnly)) {
        error = QObject::tr("Не удалось открыть %1.").arg(path);
        return false;
    }
    const QByteArray bytes = input.readAll();
    if (bytes.size() < 0x80) {
        error = QObject::tr("Файл DWG слишком короткий.");
        return false;
    }
    file.version = QString::fromLatin1(bytes.left(6));
    if (file.version != QLatin1String("AC1015") && file.version != QLatin1String("AC1014") && file.version != QLatin1String("AC1012")) {
        static const std::map<QString, const char*> releases{{"AC1018", "2004"}, {"AC1021", "2007"}, {"AC1024", "2010"},
                                                             {"AC1027", "2013"}, {"AC1032", "2018"}};
        const auto release = releases.find(file.version);
        error = QObject::tr("DWG %1%2: читаются версии R13–2018 (AC1012–AC1032); у этой версии раскладки здесь нет. "
                            "Сохраните чертёж как DWG 2018.")
                    .arg(file.version, release == releases.end() ? QString() : QObject::tr(" (AutoCAD %1)").arg(release->second));
        return false;
    }
    // Section locators: at 0x15 their count, then 9 bytes each (number, seeker, size).
    const quint32 count = le32(bytes, 0x15);
    if (count < 3 || count > 16 || 0x19 + qint64(count) * 9 > bytes.size()) {
        error = QObject::tr("Таблица секций DWG повреждена.");
        return false;
    }
    std::map<int, std::pair<quint32, quint32>> sections;
    for (quint32 i = 0; i < count; ++i) {
        const qint64 at = 0x19 + qint64(i) * 9;
        sections[uchar(bytes[at])] = {le32(bytes, at + 1), le32(bytes, at + 5)};
    }
    const auto within = [&](qint64 at, qint64 length) { return at >= 0 && length >= 0 && at + length <= bytes.size(); };

    // The header variables (section 0), R2000 only, read as far as INSUNITS: a sentinel, the data's
    // size, then the variables in their fixed order. What is not needed is read past by its type.
    if (const auto it = sections.find(0); file.version == QLatin1String("AC1015") && it != sections.end() &&
                                          within(it->second.first + 20, 0)) {
        const qint64 at = it->second.first + 16;
        const quint32 size = le32(bytes, at);
        if (within(at + 4, size)) {
            Bits b(reinterpret_cast<const uchar*>(bytes.constData()) + at + 4, size);
            for (int i = 0; i < 4; ++i) b.BD();
            for (int i = 0; i < 4; ++i) b.TV();
            b.BL();
            b.BL();
            b.H();                          // the current viewport's entity header
            b.bits(20);                     // DIMASO … PELLIPSE
            for (int i = 0; i < 27; ++i) b.BS(); // PROXYGRAPHICS … TEXTQLTY
            for (int i = 0; i < 21; ++i) b.BD(); // LTSCALE … CELTSCALE
            b.TV();                         // MENUNAME
            for (int i = 0; i < 8; ++i) b.BL(); // creation, update, editing time, user timer
            b.BS();                         // CECOLOR
            for (int i = 0; i < 6; ++i) b.H(); // HANDSEED, CLAYER, TEXTSTYLE, CELTYPE, DIMSTYLE, CMLSTYLE
            b.BD();                         // PSVPSCALE
            const auto space = [&](double* low, double* high) {
                double base[3];
                b.BD3(base);                // INSBASE
                b.BD3(low);
                b.BD3(high);
                for (int i = 0; i < 4; ++i) b.RD(); // LIMMIN, LIMMAX
                b.BD();                     // ELEVATION
                for (int i = 0; i < 9; ++i) b.BD(); // UCSORG, UCSXDIR, UCSYDIR
                b.H();                      // UCSNAME
                b.H();                      // UCSORTHOREF
                b.BS();                     // UCSORTHOVIEW
                b.H();                      // UCSBASE
                for (int i = 0; i < 18; ++i) b.BD(); // the six orthographic UCS origins
            };
            double paperLow[3], paperHigh[3];
            space(paperLow, paperHigh);
            space(file.header.extentsMin, file.header.extentsMax);
            b.TV();                         // DIMPOST
            b.TV();                         // DIMAPOST
            for (int i = 0; i < 9; ++i) b.BD(); // DIMSCALE … DIMTM
            b.bits(6);                      // DIMTOL … DIMSE2
            for (int i = 0; i < 3; ++i) b.BS(); // DIMTAD, DIMZIN, DIMAZIN
            for (int i = 0; i < 9; ++i) b.BD(); // DIMTXT … DIMALTRND
            b.bit();                        // DIMALT
            b.BS();                         // DIMALTD
            b.bits(4);                      // DIMTOFL, DIMSAH, DIMTIX, DIMSOXD
            for (int i = 0; i < 3; ++i) b.BS(); // DIMCLRD, DIMCLRE, DIMCLRT
            for (int i = 0; i < 11; ++i) b.BS(); // DIMADEC … DIMJUST
            b.bits(2);                      // DIMSD1, DIMSD2
            for (int i = 0; i < 4; ++i) b.BS(); // DIMTOLJ … DIMALTTZ
            b.bit();                        // DIMUPT
            b.BS();                         // DIMATFIT
            for (int i = 0; i < 5; ++i) b.H(); // DIMTXSTY, DIMLDRBLK, DIMBLK, DIMBLK1, DIMBLK2
            b.BS();                         // DIMLWD
            b.BS();                         // DIMLWE
            for (int i = 0; i < 13; ++i) b.H(); // the table controls and dictionaries
            b.BS();                         // TSTACKALIGN
            b.BS();                         // TSTACKSIZE
            b.TV();                         // HYPERLINKBASE
            b.TV();                         // STYLESHEET
            for (int i = 0; i < 3; ++i) b.H(); // the layout, plot setting and plot style dictionaries
            b.BL();                         // flags
            const int insunits = b.BS();
            if (b.ok) {
                file.header.read = true;
                file.header.insunits = insunits;
            }
        }
    }

    // Classes (section 1): a sentinel, the data's size, then the class records as a bit stream.
    if (const auto it = sections.find(1); it != sections.end() && within(it->second.first + 20, 0)) {
        const qint64 at = it->second.first + 16;
        const quint32 size = le32(bytes, at);
        if (within(at + 4, size)) {
            Bits b(reinterpret_cast<const uchar*>(bytes.constData()) + at + 4, size);
            while (b.ok && b.position + 8 * 8 < std::size_t(size) * 8) {
                DwgClass c;
                c.number = b.BS();
                b.BS(); // version / proxy flags
                b.TV(); // application
                c.cplusplus = QString::fromLatin1(b.TV());
                c.dxfName = QString::fromLatin1(b.TV());
                b.bit(); // was a zombie
                c.entity = b.BS() == 0x1F2;
                if (!b.ok || c.number < 500) break;
                file.classes.push_back(c);
            }
        }
    }

    // The object map (section 2): runs of up to 2032 bytes, each its big-endian size, then handle and
    // location deltas as modular chars, then a CRC.
    const auto it = sections.find(2);
    if (it == sections.end()) {
        error = QObject::tr("В DWG нет карты объектов.");
        return false;
    }
    std::vector<std::pair<quint64, qint64>> map;
    {
        qint64 at = it->second.first;
        const qint64 end = qint64(it->second.first) + it->second.second;
        const auto modularChar = [&](qint64& p, bool isSigned) -> qint64 {
            qint64 value = 0;
            int shift = 0;
            while (p < bytes.size()) {
                const uchar c = uchar(bytes[p++]);
                if (c & 0x80) {
                    value |= qint64(c & 0x7F) << shift;
                    shift += 7;
                    continue;
                }
                if (isSigned) {
                    value |= qint64(c & 0x3F) << shift;
                    return (c & 0x40) ? -value : value;
                }
                return value | (qint64(c & 0x7F) << shift);
            }
            return 0;
        };
        while (within(at, 2) && at < end) {
            const int size = (uchar(bytes[at]) << 8) | uchar(bytes[at + 1]);
            if (size <= 2) break;
            qint64 p = at + 2;
            const qint64 stop = at + size;
            quint64 handle = 0;
            qint64 location = 0;
            while (p < stop) {
                handle += quint64(modularChar(p, false));
                location += modularChar(p, true);
                map.push_back({handle, location});
            }
            at = stop + 2;
        }
    }
    if (map.empty()) {
        error = QObject::tr("Карта объектов DWG пуста.");
        return false;
    }

    readObjectsR2000(bytes, map, file, false);
    return true;
}

// The object map of an R2004-style file (its AcDb:Handles section): runs, each its big-endian size, then
// handle and location deltas as modular chars (locations in the objects' section), then a CRC.
std::vector<std::pair<quint64, qint64>> sectionObjectMap(const QByteArray& handles) {
    std::vector<std::pair<quint64, qint64>> map;
        const auto modularChar = [&](qint64& p, bool isSigned) -> qint64 {
            qint64 value = 0;
            int shift = 0;
            while (p < handles.size()) {
                const uchar c = uchar(handles[p++]);
                if (c & 0x80) {
                    value |= qint64(c & 0x7F) << shift;
                    shift += 7;
                    continue;
                }
                if (isSigned) {
                    value |= qint64(c & 0x3F) << shift;
                    return (c & 0x40) ? -value : value;
                }
                return value | (qint64(c & 0x7F) << shift);
            }
            return 0;
        };
        qint64 at = 0;
        while (at + 2 <= handles.size()) {
            const int size = (uchar(handles[at]) << 8) | uchar(handles[at + 1]);
            if (size <= 2) break;
            qint64 p = at + 2;
            const qint64 stop = std::min<qint64>(at + size, handles.size());
            quint64 handle = 0;
            qint64 location = 0;
            while (p < stop) {
                handle += quint64(modularChar(p, false));
                location += modularChar(p, true);
                map.push_back({handle, location});
            }
            at = stop + 2;
        }
        return map;
}

// AutoCAD 2004 (AC1018): the container of 2004 on (its sections), the objects as R2000's with 2004's
// additions (readObjectsR2000), texts in the data as R2000's.
bool readDwgR2004(const QString& path, DwgFile& file, QString& error) {
    DwgStructure structure;
    if (!readDwgStructure(path, structure, error)) return false;
    file.version = structure.version;
    QByteArray classes, handles, objects, header;
    for (const auto& [name, bytes] : {std::pair<const char*, QByteArray*>{"AcDb:Classes", &classes}, {"AcDb:Handles", &handles},
                                     {"AcDb:AcDbObjects", &objects}, {"AcDb:Header", &header}})
        if (!readDwgSection(path, structure, QString::fromLatin1(name), *bytes, error)) return false;
    const auto uchars = [](const QByteArray& b) { return reinterpret_cast<const uchar*>(b.constData()); };

    // Classes: a sentinel, the size in bytes, the highest class number and three flags; the records, their
    // texts in the data, each with 2004's counts after it.
    if (classes.size() >= 20) {
        const std::size_t size = le32(classes, 16);
        Bits b(uchars(classes), 20 * 8, std::min<std::size_t>(20 + size, std::size_t(classes.size())) * 8);
        const int highest = b.BS();
        b.RC();
        b.RC();
        b.bit();
        while (b.ok) {
            DwgClass c;
            c.number = b.BS();
            b.BS();                           // proxy flags
            b.TV();                           // application
            c.cplusplus = QString::fromLatin1(b.TV());
            c.dxfName = QString::fromLatin1(b.TV());
            b.bit();                          // was a zombie
            c.entity = b.BS() == 0x1F2;
            c.objects = b.BL();
            b.BS();                           // version
            b.BS();                           // maintenance version
            b.BL();
            b.BL();
            if (!b.ok || c.number < 500) break;
            file.classes.push_back(c);
            if (c.number >= highest) break;
        }
    }

    // The header, as far as INSUNITS: R2000's fields with 2004's additions, its handles in the data.
    if (header.size() >= 20) {
        const std::size_t size = le32(header, 16);
        Bits b(uchars(header), 20 * 8, std::min<std::size_t>(20 + size, std::size_t(header.size())) * 8);
        const auto colour = [&]() {           // CMC from 2004 on: index, RGB, flags; a name and a book where flagged
            b.BS();
            b.BL();
            const unsigned flags = b.RC();
            if (flags & 1) b.TV();
            if (flags & 2) b.TV();
        };
        for (int i = 0; i < 4; ++i) b.BD();
        for (int i = 0; i < 4; ++i) b.TV();
        b.BL();
        b.BL();
        b.bits(21);                           // DIMASO … PELLIPSE, with the 2004 bit
        for (int i = 0; i < 8; ++i) b.BS();   // PROXYGRAPHICS … PDMODE
        for (int i = 0; i < 3; ++i) b.BL();
        for (int i = 0; i < 19; ++i) b.BS(); // USERI1 … TEXTQLTY
        for (int i = 0; i < 21; ++i) b.BD(); // LTSCALE … CELTSCALE
        b.TV();                               // MENUNAME
        for (int i = 0; i < 11; ++i) b.BL(); // creation, update, 2004's three, editing, user timer
        colour();                             // CECOLOR
        for (int i = 0; i < 6; ++i) b.H();   // HANDSEED, CLAYER, TEXTSTYLE, CELTYPE, DIMSTYLE, CMLSTYLE
        b.BD();                               // PSVPSCALE
        const auto space = [&](double* low, double* high) {
            double base[3];
            b.BD3(base);
            b.BD3(low);
            b.BD3(high);
            for (int i = 0; i < 4; ++i) b.RD();
            b.BD();
            for (int i = 0; i < 9; ++i) b.BD();
            b.H();                            // UCSNAME
            b.H();                            // UCSORTHOREF
            b.BS();                           // UCSORTHOVIEW
            b.H();                            // UCSBASE
            for (int i = 0; i < 18; ++i) b.BD();
        };
        double paperLow[3], paperHigh[3], modelLow[3], modelHigh[3];
        space(paperLow, paperHigh);
        space(modelLow, modelHigh);
        if (b.ok) {
            std::copy(modelLow, modelLow + 3, file.header.extentsMin);
            std::copy(modelHigh, modelHigh + 3, file.header.extentsMax);
        }
        b.TV();                               // DIMPOST
        b.TV();                               // DIMAPOST
        for (int i = 0; i < 9; ++i) b.BD();   // DIMSCALE … DIMTM
        b.bits(6);                            // DIMTOL … DIMSE2
        for (int i = 0; i < 3; ++i) b.BS();   // DIMTAD, DIMZIN, DIMAZIN
        for (int i = 0; i < 9; ++i) b.BD();   // DIMTXT … DIMALTRND
        b.bit();                              // DIMALT
        b.BS();                               // DIMALTD
        b.bits(4);                            // DIMTOFL, DIMSAH, DIMTIX, DIMSOXD
        for (int i = 0; i < 3; ++i) colour(); // DIMCLRD, DIMCLRE, DIMCLRT
        for (int i = 0; i < 11; ++i) b.BS();  // DIMADEC … DIMJUST
        b.bits(2);                            // DIMSD1, DIMSD2
        for (int i = 0; i < 4; ++i) b.BS();   // DIMTOLJ … DIMALTTZ
        b.bit();                              // DIMUPT
        b.BS();                               // DIMATFIT
        for (int i = 0; i < 5; ++i) b.H();    // DIMTXSTY, DIMLDRBLK, DIMBLK, DIMBLK1, DIMBLK2
        b.BS();                               // DIMLWD
        b.BS();                               // DIMLWE
        for (int i = 0; i < 12; ++i) b.H();   // the table controls (no viewport entity headers' from 2004 on), dictionaries
        b.BS();                               // TSTACKALIGN
        b.BS();                               // TSTACKSIZE
        b.TV();                               // HYPERLINKBASE
        b.TV();                               // STYLESHEET
        for (int i = 0; i < 5; ++i) b.H();    // layout, plot setting, plot style dictionaries; 2004's material, colour
        b.BL();                               // flags
        const int insunits = b.BS();
        if (b.ok) {
            file.header.read = true;
            file.header.insunits = insunits;
        }
    }

    const std::vector<std::pair<quint64, qint64>> map = sectionObjectMap(handles);
    if (map.empty()) {
        error = QObject::tr("Карта объектов DWG пуста.");
        return false;
    }
    readObjectsR2000(objects, map, file, true);
    return true;
}

bool readDwgR2013(const QString& path, DwgFile& file, QString& error) {
    // 2007 (AC1021): its own container, the objects as 2010's but for their type (a BS) and where their data
    // ends (an RL, as R2000's) instead of the handle stream's size, entities without visual styles; 2010: the
    // objects as 2013's, the header without its first field; both keep their ACIS data in the object.
    QFile head(path);
    file.version = head.open(QIODevice::ReadOnly) ? QString::fromLatin1(head.read(6)) : QString();
    head.close();
    const bool r2007 = file.version == QLatin1String("AC1021");
    const bool r2010 = file.version == QLatin1String("AC1024") || r2007; // before 2013
    if (file.version != QLatin1String("AC1027") && file.version != QLatin1String("AC1032") && !r2010) {
        error = QObject::tr("DWG %1: объекты разбираются здесь у R13–R2000 и AutoCAD 2007–2018 (AC1021–AC1032).").arg(file.version);
        return false;
    }
    DwgStructure structure;
    QByteArray classes, handles, objects, header;
    if (r2007) {
        std::map<QString, QByteArray> sections;
        if (!readDwgR2007Sections(path, sections, error, {"AcDb:Classes", "AcDb:Handles", "AcDb:AcDbObjects", "AcDb:Header"})) return false;
        classes = sections["AcDb:Classes"];
        handles = sections["AcDb:Handles"];
        objects = sections["AcDb:AcDbObjects"];
        header = sections["AcDb:Header"];
    } else {
        if (!readDwgStructure(path, structure, error)) return false;
        for (const auto& [name, bytes] : {std::pair<const char*, QByteArray*>{"AcDb:Classes", &classes}, {"AcDb:Handles", &handles},
                                         {"AcDb:AcDbObjects", &objects}, {"AcDb:Header", &header}})
            if (!readDwgSection(path, structure, QString::fromLatin1(name), *bytes, error)) return false;
    }
    const auto uchars = [](const QByteArray& b) { return reinterpret_cast<const uchar*>(b.constData()); };

    // Classes: a sentinel, the size, its high half, the size in bits; the records, their names in the
    // section's string stream.
    // (2007's has no high half of the size: the size in bits at 20, the data at 24.)
    const std::size_t bitsAt = r2007 ? 20 : 24;
    if (classes.size() >= qsizetype(bitsAt + 4)) {
        const std::size_t bits = le32(classes, qint64(bitsAt));
        const std::size_t end = std::min<std::size_t>(bitsAt * 8 + bits, std::size_t(classes.size()) * 8);
        Bits b(uchars(classes), (bitsAt + 4) * 8, end);
        Bits strings(uchars(classes), 0, 0);
        if (stringStream(uchars(classes), bitsAt * 8, end, strings)) {
            const int highest = b.BS();
            b.RC();
            b.RC();
            b.bit();
            while (b.ok && strings.ok) {
                DwgClass c;
                c.number = b.BS();
                b.BS();                          // proxy flags
                strings.TU();                    // application
                c.cplusplus = strings.TU();
                c.dxfName = strings.TU();
                b.bit();                         // was a zombie
                c.entity = b.BS() == 0x1F2;
                c.objects = b.BL();
                for (int i = 0; i < 4; ++i) b.BL(); // version, maintenance, two unknown
                if (!b.ok || !strings.ok || c.number < 500) break;
                file.classes.push_back(c);
                if (c.number >= highest) break;
            }
        }
    }

    // The header, as far as INSUNITS: R2013's fields in their order, the texts in its string stream, the
    // handles in a stream of their own after the data.
    if (header.size() >= qsizetype(bitsAt + 4)) {
        const std::size_t bits = le32(header, qint64(bitsAt));
        const std::size_t end = std::min<std::size_t>(bitsAt * 8 + bits, std::size_t(header.size()) * 8);
        Bits b(uchars(header), (bitsAt + 4) * 8, end);
        Bits strings(uchars(header), 0, 0);
        stringStream(uchars(header), bitsAt * 8, end, strings);
        const auto colour = [&]() {           // CMC: index, RGB, flags; a name and a book where flagged
            b.BS();
            b.BL();
            const unsigned flags = b.RC();
            if (flags & 1) strings.TU();
            if (flags & 2) strings.TU();
        };
        if (!r2010) b.BLL();                  // REQUIREDVERSIONS, from 2013 on
        for (int i = 0; i < 4; ++i) b.BD();
        for (int i = 0; i < 4; ++i) strings.TU();
        b.BL();
        b.BL();
        b.bits(21);                           // DIMASO … PELLIPSE, with the 2004 bit
        for (int i = 0; i < 8; ++i) b.BS();   // PROXYGRAPHICS, TREEDEPTH … AUPREC, ATTMODE, PDMODE
        for (int i = 0; i < 3; ++i) b.BL();
        for (int i = 0; i < 19; ++i) b.BS(); // USERI1 … TEXTQLTY
        for (int i = 0; i < 21; ++i) b.BD(); // LTSCALE … CELTSCALE
        for (int i = 0; i < 11; ++i) b.BL(); // creation, update, 2004's three, editing, user timer
        colour();                             // CECOLOR
        b.H();                                // HANDSEED (the only handle in the data)
        b.BD();                               // PSVPSCALE
        const auto space = [&](double* low, double* high) {
            double base[3];
            b.BD3(base);
            b.BD3(low);
            b.BD3(high);
            for (int i = 0; i < 4; ++i) b.RD();
            b.BD();
            for (int i = 0; i < 9; ++i) b.BD();
            b.BS();                           // UCSORTHOVIEW
            for (int i = 0; i < 18; ++i) b.BD();
        };
        double paperLow[3], paperHigh[3];
        space(paperLow, paperHigh);
        double modelLow[3], modelHigh[3];
        space(modelLow, modelHigh);
        if (b.ok) {
            std::copy(modelLow, modelLow + 3, file.header.extentsMin);
            std::copy(modelHigh, modelHigh + 3, file.header.extentsMax);
        }
        strings.TU();                         // DIMPOST
        strings.TU();                         // DIMAPOST
        for (int i = 0; i < 9; ++i) b.BD();   // DIMSCALE … DIMTM
        b.BD();                               // DIMFXL
        b.BD();                               // DIMJOGANG
        b.BS();                               // DIMTFILL
        colour();                             // DIMTFILLCLR
        b.bits(6);                            // DIMTOL … DIMSE2
        for (int i = 0; i < 4; ++i) b.BS();   // DIMTAD, DIMZIN, DIMAZIN, DIMARCSYM
        for (int i = 0; i < 9; ++i) b.BD();   // DIMTXT … DIMALTRND
        b.bit();                              // DIMALT
        b.BS();                               // DIMALTD
        b.bits(4);                            // DIMTOFL, DIMSAH, DIMTIX, DIMSOXD
        for (int i = 0; i < 3; ++i) colour(); // DIMCLRD, DIMCLRE, DIMCLRT
        for (int i = 0; i < 11; ++i) b.BS();  // DIMADEC … DIMJUST
        b.bits(2);                            // DIMSD1, DIMSD2
        for (int i = 0; i < 4; ++i) b.BS();   // DIMTOLJ … DIMALTTZ
        b.bit();                              // DIMUPT
        b.BS();                               // DIMATFIT
        b.bit();                              // DIMFXLON
        if (!r2007) {
            b.bit();                          // DIMTXTDIRECTION, from 2010 on
            b.BD();                           // DIMALTMZF
            strings.TU();                     // DIMALTMZS
            b.BD();                           // DIMMZF
            strings.TU();                     // DIMMZS
        }
        b.BS();                               // DIMLWD
        b.BS();                               // DIMLWE
        b.BS();                               // TSTACKALIGN
        b.BS();                               // TSTACKSIZE
        b.BL();                               // flags
        const int insunits = b.BS();
        if (b.ok) {
            file.header.read = true;
            file.header.insunits = insunits;
        }
    }

    // The object map: as R2000's, locations in the objects' section.
    const std::vector<std::pair<quint64, qint64>> map = sectionObjectMap(handles);
    if (map.empty()) {
        error = QObject::tr("Карта объектов DWG пуста.");
        return false;
    }

    std::map<int, const DwgClass*> classByNumber;
    for (const DwgClass& c : file.classes) classByNumber[c.number] = &c;
    const auto typeName = [&](int type) {
        if (const auto it = classByNumber.find(type); it != classByNumber.end()) return it->second->dxfName;
        if (const char* fixed = fixedTypeName(type)) return QString::fromLatin1(fixed);
        return QString();
    };
    int solids = 0;
    for (const auto& [mapped, location] : map) {
        if (location < 0 || location + 2 > objects.size()) continue;
        // A modular short size in bytes, a modular char handle-stream size in bits, then the object.
        qint64 p = location;
        quint64 size = 0;
        for (int shift = 0; p + 2 <= objects.size(); shift += 15) {
            const unsigned word = uchar(objects[p]) | (unsigned(uchar(objects[p + 1])) << 8);
            p += 2;
            size |= quint64(word & 0x7FFF) << shift;
            if (!(word & 0x8000)) break;
        }
        quint64 handleBits = 0;
        if (!r2007)
            for (int shift = 0; p < objects.size(); shift += 7) {
                const uchar c = uchar(objects[p++]);
                handleBits |= quint64(c & 0x7F) << shift;
                if (!(c & 0x80)) break;
            }
        if (size == 0 || p + qint64(size) > objects.size() || handleBits > size * 8) continue;
        const std::size_t begin = std::size_t(p) * 8, end = begin + size * 8;
        std::size_t dataEnd = end - handleBits;
        if (r2007) {
            // 2007: the type a BS, then where the data ends (the handles begin), in bits from the object's start.
            Bits front(uchars(objects), begin, end);
            front.BS();
            const std::size_t stop = begin + front.RL();
            if (!front.ok || stop > end || stop < front.position) continue;
            dataEnd = stop;
        }
        Bits b(uchars(objects), begin, dataEnd);
        // Where the data proper ends: at its string stream, or at the flag saying there is none.
        Bits strings(uchars(objects), 0, 0);
        const std::size_t dataStop = stringStream(uchars(objects), begin, dataEnd, strings) ? strings.position : dataEnd - 1;
        DwgObject object;
        object.offset = quint32(location);
        if (r2007) {
            object.type = b.BS();
            b.RL();
        } else {
            object.type = b.OT();
        }
        object.handle = b.H();
        for (int extended = b.BS(); b.ok && extended != 0; extended = b.BS()) {
            b.H();
            b.skipBytes(extended);
        }
        const QString name = typeName(object.type);
        bool entity = fixedEntity(object.type);
        if (const auto it = classByNumber.find(object.type); it != classByNumber.end()) entity = it->second->entity;
        object.entity = entity;
        Bits h(uchars(objects), dataEnd, end);
        if (!entity && object.type == 49 && b.ok) {
            // A block header: reactors, extension dictionary, binary data; the name; the flags (no
            // 64-flag or xref dependence in the data from 2013 on); owned entities; the base point.
            b.BL();
            b.bit();
            if (!r2010) b.bit();              // binary data, from 2013 on
            DwgBlock block;
            block.handle = object.handle;
            block.name = strings.TU();
            b.BS();                           // xref index + 1
            block.anonymous = b.bit();
            b.bit();                          // has attributes
            block.xref = b.bit();
            const bool overlaid = b.bit();
            b.bit();                          // loaded
            if (!block.xref && !overlaid) block.owned = b.BL();
            b.BD3(block.base);
            block.xrefPath = strings.TU();
            while (b.ok && b.RC() != 0) {
            }
            strings.TU();                     // description
            b.skipBytes(b.BL());              // preview
            b.BS();                           // insert units
            b.bit();                          // explodable
            b.RC();                           // scaling
            if (b.ok && strings.ok && b.position == dataStop) file.blocks.push_back(block);
            else ++file.misread;
        }
        if (entity && b.ok) {
            // Common entity data, 2013 on.
            if (b.bit()) b.skipBytes(r2007 ? qint64(b.RL()) : qint64(b.BLL())); // a graphic image (its size an RL before 2010)
            object.entityMode = int(b.bits(2));
            const qint32 reactors = b.BL();
            const bool noDictionary = b.bit();
            if (!r2010) b.bit();              // binary data, from 2013 on
            const unsigned colour = unsigned(b.BS()) & 0xFFFF;
            const unsigned colourFlags = colour >> 8;
            if ((colourFlags & 0x80) && !(colourFlags & 0x40)) b.BL(); // RGB, unless a colour object says it
            if (colourFlags & 0x20) b.BL();   // transparency
            b.BD();                           // line type scale
            const unsigned lineType = b.bits(2);
            const unsigned flagsA = b.bits(2), flagsB = b.bits(2); // material, plot style
            b.RC();                           // shadows
            int styles = 0;
            if (!r2007)
                for (int i = 0; i < 3; ++i) styles += int(b.bit()); // full, face, edge visual style, from 2010 on
            b.BS();                           // invisibility
            b.RC();                           // line weight
            // Its handles: owner, reactors, extension dictionary, colour object, layer, line type,
            // material and plot style, visual styles; then its own.
            if (object.entityMode == 0) object.owner = h.reference(object.handle);
            for (qint32 i = 0; i < reactors && h.ok; ++i) h.reference(object.handle);
            if (!noDictionary) h.reference(object.handle);
            if (colourFlags & 0x40) h.reference(object.handle);
            h.reference(object.handle);
            if (lineType == 3) h.reference(object.handle);
            if (flagsA == 3) h.reference(object.handle);
            if (flagsB == 3) h.reference(object.handle);
            for (int i = 0; i < styles; ++i) h.reference(object.handle);
            if (object.type == 7 && b.ok) {
                DwgInsert insert;
                insert.handle = object.handle;
                insert.entityMode = object.entityMode;
                insert.owner = object.owner;
                b.BD3(insert.point);
                switch (b.bits(2)) {
                case 3: break;
                case 1:
                    insert.scale[1] = b.DD(1.0);
                    insert.scale[2] = b.DD(1.0);
                    break;
                case 2:
                    insert.scale[0] = insert.scale[1] = insert.scale[2] = b.RD();
                    break;
                default:
                    insert.scale[0] = b.RD();
                    insert.scale[1] = b.DD(insert.scale[0]);
                    insert.scale[2] = b.DD(insert.scale[0]);
                }
                insert.rotation = b.BD();
                b.BD3(insert.extrusion);
                if (b.bit()) b.BL();          // attributes, and how many
                insert.block = h.reference(object.handle);
                if (b.ok && h.ok && b.position == dataStop) file.inserts.push_back(insert);
                else ++file.misread;
            }
            DwgPlanar planar;
            Bits data = b;
            if (readPlanar(data, name, true, planar)) {
                if (data.ok && data.position == dataStop) {
                    planar.handle = object.handle;
                    planar.owner = object.owner;
                    planar.entityMode = object.entityMode;
                    file.planar.push_back(std::move(planar));
                } else {
                    ++file.misread;
                }
            }
            if (object.type == 37 || object.type == 38 || object.type == 39) {
                ++solids;
                // Before 2013 the ACIS data is the object's own, as R2000's: empty or not, an unknown bit,
                // the version; version 1 SAT text in blocks, each printable character written as 159 - c.
                if (r2010 && b.ok && !b.bit()) {
                    b.bit();
                    if (const int acisVersion = b.BS(); acisVersion == 1) {
                        for (qint32 block = b.BL(); b.ok && block > 0; block = b.BL())
                            for (qint32 i = 0; i < block && b.ok; ++i) {
                                const unsigned c = b.RC();
                                object.acis.append(char(c <= 32 ? c : (159 - c) & 0xFF));
                            }
                    } else if (acisVersion == 2) {
                        // Version 2: binary ACIS (SAB) straight after, as far as its end marker.
                        QByteArray sab;
                        while (b.ok && b.position + 8 <= dataStop) {
                            sab.append(char(b.RC()));
                            if (sab.endsWith("End-of-ACIS-data") || sab.endsWith("End-of-ASM-data")) break;
                        }
                        if (sab.startsWith("ACIS BinaryFile") || sab.startsWith("ASM BinaryFile")) object.acis = sab;
                    }
                }
            }
        }
        file.objects.push_back(std::move(object));
    }
    // The solids' ACIS data: binary (SAB), in the data store (the AcDs section). Its data segments list
    // their records as 20-byte entries — 0x14, 1, the owning object's handle (8 bytes), the record's
    // offset — then, past a padding of 'b', the records, each its length and its bytes.
    int inline_ = 0;
    for (const DwgObject& object : file.objects) inline_ += object.acis.isEmpty() ? 0 : 1;
    if (solids > inline_) {
        QByteArray store;
        QString why;
        int found = 0;
        if (readDwgSection(path, structure, QStringLiteral("AcDb:AcDsPrototype_1b"), store, why)) {
            const auto u32 = [&](qint64 at) { return at + 4 <= store.size() ? le32(store, at) : 0u; };
            for (DwgObject& object : file.objects) {
                if (object.type != 37 && object.type != 38 && object.type != 39) continue;
                QByteArray key(16, '\0');
                key[0] = 0x14;
                key[4] = 0x01;
                for (int i = 0; i < 8; ++i) key[8 + i] = char((object.handle >> (8 * i)) & 0xFF);
                for (qint64 entry = store.indexOf(key); entry >= 0 && object.acis.isEmpty(); entry = store.indexOf(key, entry + 1)) {
                    const quint32 offset = u32(entry + 16);
                    qint64 end = entry;
                    while (u32(end) == 0x14 && u32(end + 4) == 1) end += 20;
                    while (end < store.size() && store[end] == 'b') ++end;
                    const qint64 at = end + qint64(offset);
                    const quint32 length = u32(at);
                    const QByteArray data = at + 4 + qint64(length) <= store.size() ? store.mid(at + 4, length) : QByteArray();
                    if (data.startsWith("ASM BinaryFile") || data.startsWith("ACIS BinaryFile")) object.acis = data;
                }
                found += object.acis.isEmpty() ? 0 : 1;
            }
        }
        found += inline_;
        if (found < solids)
            file.notes << QObject::tr("Тел ACIS (3DSOLID, REGION, BODY) DWG %1 без найденных данных в разделе AcDs: %2 из %3")
                              .arg(file.version)
                              .arg(solids - found)
                              .arg(solids);
    }
    return true;
}

bool readDwgFile(const QString& path, DwgFile& file, QString& error) {
    QFile input(path);
    if (!input.open(QIODevice::ReadOnly)) {
        error = QObject::tr("Не удалось открыть %1.").arg(path);
        return false;
    }
    const QByteArray version = input.read(6);
    if (version == "AC1021" || version == "AC1024" || version == "AC1027" || version == "AC1032") return readDwgR2013(path, file, error);
    if (version == "AC1018") return readDwgR2004(path, file, error);
    return readDwgR2000(path, file, error);
}

bool dxfHasAcisBodies(const QString& path) {
    std::vector<DxfGroup> groups;
    QString error;
    if (!readDxfGroups(path, groups, error)) return false;
    for (const DxfGroup& g : groups)
        if (g.code == 0 && (g.value.trimmed() == "3DSOLID" || g.value.trimmed() == "BODY")) return true;
    return false;
}

bool readDxfObjects(const QString& path, DwgR2000File& file, QString& error) {
    std::vector<DxfGroup> groups;
    if (!readDxfGroups(path, groups, error)) return false;
    const auto number = [](const QByteArray& v) { return v.trimmed().toDouble(); };
    // An ACIS body's text: each group 1 a line, each group 3 the rest of the line before; the DXF's
    // caret escapes undone ("^ " a caret, "^I" a tab, …), then every character past the space c → 159 − c.
    const auto body = [](const std::vector<QByteArray>& lines) {
        QByteArray text;
        for (const QByteArray& line : lines) {
            for (qsizetype i = 0; i < line.size(); ++i) {
                uchar c = uchar(line[i]);
                if (c == '^' && i + 1 < line.size()) {
                    const uchar next = uchar(line[i + 1]);
                    if (next == ' ') c = '^', ++i;
                    else if (next >= '@' && next <= '_') c = uchar(next - 64), ++i;
                }
                text.append(char(c <= 32 ? c : (159 - c) & 0xFF));
            }
            text.append('\n');
        }
        return text;
    };
    quint64 synthetic = quint64(1) << 48; // handles for what the DXF does not number
    std::map<QString, quint64> blockHandles;
    QString section;
    quint64 currentBlock = 0; // inside BLOCKS: the block being read
    bool sab = false;
    for (std::size_t i = 0; i < groups.size();) {
        const DxfGroup& g = groups[i];
        if (g.code != 0) {
            ++i;
            continue;
        }
        const QByteArray type = g.value.trimmed();
        std::vector<DxfGroup> fields;
        ++i;
        while (i < groups.size() && groups[i].code != 0) fields.push_back(groups[i++]);
        const auto field = [&](int code) -> const QByteArray* {
            for (const DxfGroup& f : fields)
                if (f.code == code) return &f.value;
            return nullptr;
        };
        const auto real = [&](int code, double fallback) {
            const QByteArray* f = field(code);
            return f ? number(*f) : fallback;
        };
        if (type == "SECTION") {
            section = field(2) ? QString::fromLatin1(field(2)->trimmed()) : QString();
            if (section == QLatin1String("HEADER")) {
                // Header variables: 9 names one, the groups up to the next 9 its value.
                for (std::size_t k = 0; k < fields.size(); ++k) {
                    if (fields[k].code != 9) continue;
                    const QByteArray name = fields[k].value.trimmed();
                    std::vector<const DxfGroup*> value;
                    for (std::size_t m = k + 1; m < fields.size() && fields[m].code != 9; ++m) value.push_back(&fields[m]);
                    const auto get = [&](int code, double fallback) {
                        for (const DxfGroup* v : value)
                            if (v->code == code) return number(v->value);
                        return fallback;
                    };
                    if (name == "$ACADVER" && !value.empty()) file.version = QString::fromLatin1(value.front()->value.trimmed());
                    if (name == "$INSUNITS") file.header.insunits = int(get(70, -1)), file.header.read = true;
                    if (name == "$EXTMIN") for (int a = 0; a < 3; ++a) file.header.extentsMin[a] = get(10 + 10 * a, 0);
                    if (name == "$EXTMAX") for (int a = 0; a < 3; ++a) file.header.extentsMax[a] = get(10 + 10 * a, 0);
                }
            }
            continue;
        }
        if (type == "ENDSEC") {
            section.clear();
            continue;
        }
        if (type == "EOF") break;
        if (section == QLatin1String("BLOCKS") && type == "BLOCK") {
            DwgBlock block;
            block.handle = synthetic++;
            block.name = field(2) ? QString::fromLatin1(field(2)->trimmed()) : QString();
            const int flags = field(70) ? int(number(*field(70))) : 0;
            block.anonymous = flags & 1;
            block.xref = flags & 4;
            if (block.xref && field(1)) block.xrefPath = QString::fromLocal8Bit(field(1)->trimmed());
            for (int a = 0; a < 3; ++a) block.base[a] = real(10 + 10 * a, 0.0);
            blockHandles[block.name.toUpper()] = block.handle;
            file.blocks.push_back(block);
            currentBlock = block.handle;
            continue;
        }
        if (section == QLatin1String("BLOCKS") && type == "ENDBLK") {
            currentBlock = 0;
            continue;
        }
        if (section != QLatin1String("BLOCKS") && section != QLatin1String("ENTITIES")) continue;
        const bool inBlock = section == QLatin1String("BLOCKS");
        if (inBlock && currentBlock == 0) continue;
        const QByteArray* handleField = field(5);
        bool numbered = false;
        const quint64 handle = handleField ? handleField->trimmed().toULongLong(&numbered, 16) : 0;
        const int mode = inBlock ? 0 : (field(67) && number(*field(67)) == 1.0 ? 1 : 2);
        if (type == "3DSOLID" || type == "BODY" || type == "REGION") {
            DwgObject object;
            object.handle = numbered ? handle : synthetic++;
            object.type = type == "REGION" ? 37 : type == "3DSOLID" ? 38 : 39;
            object.entity = true;
            object.entityMode = mode;
            object.owner = inBlock ? currentBlock : 0;
            std::vector<QByteArray> lines;
            for (const DxfGroup& f : fields) {
                if (f.code == 1) lines.push_back(f.value);
                else if (f.code == 3 && !lines.empty()) lines.back().append(f.value);
            }
            if (lines.empty()) sab = sab || field(2) != nullptr;
            else object.acis = body(lines);
            file.objects.push_back(std::move(object));
        } else if (type == "INSERT") {
            DwgInsert insert;
            insert.handle = numbered ? handle : synthetic++;
            insert.entityMode = mode;
            insert.owner = inBlock ? currentBlock : 0;
            for (int a = 0; a < 3; ++a) {
                insert.point[a] = real(10 + 10 * a, 0.0);
                insert.scale[a] = real(41 + a, 1.0);
                insert.extrusion[a] = real(210 + 10 * a, a == 2 ? 1.0 : 0.0);
            }
            insert.rotation = real(50, 0.0) * 3.14159265358979323846 / 180.0;
            // A block name, resolved once the blocks are all read.
            const QString name = field(2) ? QString::fromLatin1(field(2)->trimmed()).toUpper() : QString();
            insert.block = 0;
            const int columns = field(70) ? int(number(*field(70))) : 1, rows = field(71) ? int(number(*field(71))) : 1;
            if (columns > 1 || rows > 1) insert.scale[0] = 0.0; // an array insert: left out, counted as scaled
            file.inserts.push_back(insert);
            file.insertNames.push_back(name);
        }
    }
    for (std::size_t k = 0; k < file.inserts.size(); ++k)
        if (const auto it = blockHandles.find(file.insertNames[k]); it != blockHandles.end()) file.inserts[k].block = it->second;
    if (file.version.isEmpty()) file.version = QStringLiteral("DXF");
    if (sab)
        file.notes << QObject::tr("Тела DXF %1 записаны в двоичном ACIS (SAB, раздел ACDSDATA) — такие здесь пока не читаются")
                          .arg(file.version);
    return true;
}

namespace {

using Matrix = std::array<double, 16>; // column-major 4×4

Matrix multiply(const Matrix& a, const Matrix& b) {
    Matrix c{};
    for (int column = 0; column < 4; ++column)
        for (int row = 0; row < 4; ++row)
            for (int k = 0; k < 4; ++k) c[column * 4 + row] += a[k * 4 + row] * b[column * 4 + k];
    return c;
}

// The arbitrary axis algorithm: the object frame (x, y) of an extrusion direction n (made unit): x = W × n,
// W the world's y where n is near the world's z, else its z. False for a zero direction.
bool objectFrame(const double* extrusion, double* x, double* y, double* n) {
    const double length = std::sqrt(extrusion[0] * extrusion[0] + extrusion[1] * extrusion[1] + extrusion[2] * extrusion[2]);
    if (!(length > 0.0)) return false;
    for (int i = 0; i < 3; ++i) n[i] = extrusion[i] / length;
    if (std::fabs(n[0]) < 1.0 / 64 && std::fabs(n[1]) < 1.0 / 64) x[0] = n[2], x[1] = 0.0, x[2] = -n[0];
    else x[0] = -n[1], x[1] = n[0], x[2] = 0.0;
    const double xLength = std::sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
    for (int i = 0; i < 3; ++i) x[i] /= xLength;
    y[0] = n[1] * x[2] - n[2] * x[1];
    y[1] = n[2] * x[0] - n[0] * x[2];
    y[2] = n[0] * x[1] - n[1] * x[0];
    return true;
}

// An INSERT as an affine map of metres: p ↦ E·(insertion + Rz·S·(p − base)), the drawing's units turned
// to metres (`metresPerUnit`), E the object frame of the extrusion direction. `rigid` when it neither
// scales nor mirrors. False where a scale is zero (or an array insert, which the DXF reader marks so).
bool insertMatrix(const DwgInsert& insert, const double base[3], double metresPerUnit, Matrix& m, bool& rigid) {
    rigid = true;
    for (double s : insert.scale) {
        if (!(std::fabs(s) > 0.0) || !std::isfinite(s)) return false;
        rigid = rigid && std::fabs(s - 1.0) <= 1e-9;
    }
    double ax[3], ay[3], n[3];
    if (!objectFrame(insert.extrusion, ax, ay, n)) return false;
    const double c = std::cos(insert.rotation), s = std::sin(insert.rotation);
    const double* k = insert.scale;
    // Columns of E·Rz·S, and E·(insertion − Rz·S·base).
    const double x[3] = {k[0] * (c * ax[0] + s * ay[0]), k[0] * (c * ax[1] + s * ay[1]), k[0] * (c * ax[2] + s * ay[2])};
    const double y[3] = {k[1] * (-s * ax[0] + c * ay[0]), k[1] * (-s * ax[1] + c * ay[1]), k[1] * (-s * ax[2] + c * ay[2])};
    const double z[3] = {k[2] * n[0], k[2] * n[1], k[2] * n[2]};
    const double scaled[3] = {k[0] * base[0], k[1] * base[1], k[2] * base[2]};
    const double local[3] = {insert.point[0] - (c * scaled[0] - s * scaled[1]), insert.point[1] - (s * scaled[0] + c * scaled[1]),
                             insert.point[2] - scaled[2]};
    m = {x[0], x[1], x[2], 0, y[0], y[1], y[2], 0, z[0], z[1], z[2], 0, 0, 0, 0, 1};
    for (int i = 0; i < 3; ++i) m[12 + i] = metresPerUnit * (ax[i] * local[0] + ay[i] * local[1] + n[i] * local[2]);
    return true;
}

} // namespace

bool readDwgModel(const QString& path, DwgModel& model, QString& error) {
    // Each file read once, however often it is referenced.
    std::map<QString, DwgFile> files;
    const auto load = [&](const QString& file, QString& why) -> const DwgFile* {
        const QString key = QFileInfo(file).absoluteFilePath();
        if (const auto it = files.find(key); it != files.end()) return &it->second;
        DwgFile read;
        const bool dxf = QFileInfo(key).suffix().compare(QLatin1String("dxf"), Qt::CaseInsensitive) == 0;
        if (!(dxf ? readDxfObjects(key, read, why) : readDwgFile(key, read, why))) return nullptr;
        for (const QString& note : read.notes)
            if (!model.notes.contains(note)) model.notes << note;
        return &files.emplace(key, std::move(read)).first->second;
    };
    const DwgFile* top = load(path, error);
    if (!top) return false;
    model.version = top->version;

    // A reference's file: as written, else by its name next to the drawing (case aside).
    const auto locate = [](const QString& written, const QString& from) -> QString {
        QString name = written;
        name.replace('\\', '/');
        if (QFileInfo(name).isAbsolute() && QFileInfo::exists(name)) return name;
        const QDir dir = QFileInfo(from).absoluteDir();
        if (QFileInfo::exists(dir.filePath(name))) return dir.filePath(name);
        const QString leaf = name.section('/', -1);
        for (const QString& entry : dir.entryList(QDir::Files))
            if (entry.compare(leaf, Qt::CaseInsensitive) == 0) return dir.filePath(entry);
        return {};
    };

    std::map<QString, int> names;
    std::set<std::pair<QString, quint64>> reached; // (file, body handle)
    int scaled = 0, regions = 0, scaledBodies = 0;
    QStringList missing;
    std::vector<QString> chain; // files being inserted, against a reference to itself
    std::function<void(const QString&, const DwgFile&, quint64, double, const Matrix&, bool, const QString&)> place =
        [&](const QString& file, const DwgFile& dwg, quint64 block, double millimetres, const Matrix& at, bool rigid,
            const QString& through) {
            std::map<quint64, const DwgBlock*> blocks;
            quint64 modelSpace = 0;
            for (const DwgBlock& b : dwg.blocks) {
                blocks[b.handle] = &b;
                if (b.name.compare(QLatin1String("*Model_Space"), Qt::CaseInsensitive) == 0) modelSpace = b.handle;
            }
            const bool inModel = block == 0 || block == modelSpace;
            const auto contains = [&](const auto& entity) {
                return inModel ? entity.entityMode == 2 : entity.entityMode == 0 && entity.owner == block;
            };
            // Plane geometry, placed as the inserts on the way place it.
            std::set<quint64> planarHandles;
            for (const DwgPlanar& entity : dwg.planar) {
                if (!contains(entity)) continue;
                planarHandles.insert(entity.handle);
                model.planar.push_back({entity, millimetres, at});
            }
            // What else the block holds, by type (blocks' own markers aside).
            for (const DwgObject& object : dwg.objects) {
                if (!object.entity || !contains(object) || planarHandles.count(object.handle) || !object.acis.isEmpty()) continue;
                if (object.type == 4 || object.type == 5 || object.type == 6 || object.type == 7) continue;
                ++model.otherEntities[dwgTypeName(dwg, object.type)];
            }
            for (const DwgObject& object : dwg.objects) {
                if (object.acis.isEmpty() || !contains(object)) continue;
                if (object.type == 37) {
                    ++regions;
                    continue;
                }
                reached.insert({file, object.handle});
                if (!rigid) {
                    ++scaledBodies;
                    continue;
                }
                DwgModelBody body;
                const int n = ++names[through];
                body.name = n == 1 ? through : QStringLiteral("%1 %2").arg(through).arg(n);
                body.acis = object.acis;
                body.millimetresPerUnit = millimetres;
                body.placement = at;
                model.bodies.push_back(std::move(body));
            }
            for (const DwgInsert& insert : dwg.inserts) {
                if (!contains(insert)) continue;
                const auto target = blocks.find(insert.block);
                if (target == blocks.end()) continue;
                const DwgBlock& b = *target->second;
                Matrix local;
                bool rigidInsert = true;
                if (!insertMatrix(insert, b.base, (millimetres > 0.0 ? millimetres : 1.0) * 1e-3, local, rigidInsert)) {
                    ++scaled;
                    continue;
                }
                const Matrix world = multiply(at, local);
                const bool rigidWorld = rigid && rigidInsert;
                const QString name = b.anonymous ? through : b.name;
                if (!b.xref) {
                    if (chain.size() < 32) place(file, dwg, b.handle, millimetres, world, rigidWorld, name);
                    continue;
                }
                const QString referenced = locate(b.xrefPath, file);
                QString why;
                const DwgFile* child = referenced.isEmpty() ? nullptr : load(referenced, why);
                if (!child) {
                    const QString what = referenced.isEmpty() ? QObject::tr("%1 (%2) не найдена рядом с чертежом").arg(b.name, b.xrefPath)
                                                              : QObject::tr("%1: %2").arg(b.name, why);
                    if (!missing.contains(what)) missing << what;
                    continue;
                }
                const QString key = QFileInfo(referenced).absoluteFilePath();
                if (std::find(chain.begin(), chain.end(), key) != chain.end() || chain.size() >= 32) continue;
                const double own = dwgMillimetresPerUnit(child->header.insunits);
                chain.push_back(key);
                place(key, *child, 0, own > 0.0 ? own : millimetres, world, rigidWorld, name);
                chain.pop_back();
            }
        };
    const QString key = QFileInfo(path).absoluteFilePath();
    chain.push_back(key);
    place(key, *top, 0, dwgMillimetresPerUnit(top->header.insunits), Matrix{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}, true,
          QFileInfo(path).completeBaseName());
    for (const DwgObject& object : top->objects)
        if (object.entity && object.entityMode == 1) ++model.paperSpaceEntities;

    int unused = 0;
    for (const DwgObject& object : top->objects)
        if (!object.acis.isEmpty() && object.type != 37 && !reached.count({key, object.handle})) ++unused;
    if (unused > 0)
        model.notes << QObject::tr("Тел ACIS в блоках, которые модель не вставляет (например, тела-инструменты "
                                   "сборки Mechanical Desktop): %1 — не показаны").arg(unused);
    if (regions > 0) model.notes << QObject::tr("Плоских областей (REGION) пропущено: %1").arg(regions);
    if (scaled > 0) model.notes << QObject::tr("Вставок с нулевым масштабом или массивом (MINSERT) пропущено: %1").arg(scaled);
    if (scaledBodies > 0)
        model.notes << QObject::tr("Тел во вставках с масштабом или зеркалом: %1 — не показаны (тело переносится только жёстко)").arg(scaledBodies);
    for (const QString& what : missing) model.notes << QObject::tr("Внешняя ссылка %1").arg(what);
    return true;
}

void dwgSketchEntities(const DwgModel& model, std::vector<SketchEntity>& entities, std::map<QString, int>& left) {
    constexpr double kPi = 3.14159265358979323846;
    constexpr double kDegrees = 180.0 / kPi;
    const auto normalized = [](double degrees) {
        degrees = std::fmod(degrees, 360.0);
        return degrees < 0.0 ? degrees + 360.0 : degrees;
    };
    for (const DwgModelPlanar& item : model.planar) {
        const DwgPlanar& e = item.entity;
        const Matrix& m = item.placement;
        const double unit = (item.millimetresPerUnit > 0.0 ? item.millimetresPerUnit : 1.0) * 1e-3; // metres a unit
        const double flat = 1e-9 * unit;
        // A point of the file (its units) to the model (metres); a direction likewise, without the move.
        const auto point = [&](const double* p) {
            std::array<double, 3> w{};
            for (int i = 0; i < 3; ++i) w[i] = m[i] * p[0] * unit + m[4 + i] * p[1] * unit + m[8 + i] * p[2] * unit + m[12 + i];
            return w;
        };
        const auto direction = [&](const double* d) {
            std::array<double, 3> w{};
            for (int i = 0; i < 3; ++i) w[i] = m[i] * d[0] * unit + m[4 + i] * d[1] * unit + m[8 + i] * d[2] * unit;
            return w;
        };
        if (e.thickness != 0.0) {
            ++left[QObject::tr("с толщиной (выдавленные)")];
            continue;
        }
        using K = DwgPlanar::Kind;
        const auto addLine = [&](const std::array<double, 3>& a, const std::array<double, 3>& b) {
            if (std::fabs(a[2]) > flat || std::fabs(b[2]) > flat) return void(++left[QObject::tr("вне плоскости XY")]);
            if (std::hypot(b[0] - a[0], b[1] - a[1]) <= flat) return void(++left[QObject::tr("нулевой длины")]);
            SketchEntity s;
            s.type = SketchEntityType::Line;
            s.line.start = {a[0], a[1]};
            s.line.end = {b[0], b[1]};
            entities.push_back(std::move(s));
        };
        // A circle or an arc of the file: centre c, the directions of its angle 0 and 90° scaled by the
        // radius (u, v); from angle `from` sweeping `sweep` radians counterclockwise about u × v, or all round.
        const auto addArc = [&](const double* c, const double* u, const double* v, double from, double sweep, bool full) {
            const auto centre = point(c);
            const auto U = direction(u), V = direction(v);
            const double lu = std::hypot(U[0], U[1], U[2]), lv = std::hypot(V[0], V[1], V[2]);
            if (std::fabs(centre[2]) > flat || std::fabs(U[2]) > 1e-12 * lu || std::fabs(V[2]) > 1e-12 * lv)
                return void(++left[QObject::tr("вне плоскости XY")]);
            if (!(lu > 0.0) || std::fabs(lu - lv) > 1e-12 * lu || std::fabs(U[0] * V[0] + U[1] * V[1]) > 1e-12 * lu * lv)
                return void(++left[QObject::tr("окружности, которые вставка превращает в эллипс")]);
            SketchEntity s;
            if (full) {
                s.type = SketchEntityType::Circle;
                s.circle.center = {centre[0], centre[1]};
                s.circle.radius = lu;
            } else {
                // Mirrored (u × v pointing down), the arc runs clockwise: its start is the file's end.
                const bool turned = U[0] * V[1] - U[1] * V[0] < 0.0;
                const double at = turned ? from + sweep : from;
                const double dx = std::cos(at) * U[0] + std::sin(at) * V[0], dy = std::cos(at) * U[1] + std::sin(at) * V[1];
                const double degrees = sweep * kDegrees;
                if (!(degrees > 0.0) || degrees >= 360.0) return void(++left[QObject::tr("дуги нулевой длины")]);
                s.type = SketchEntityType::Arc;
                s.arc.center = {centre[0], centre[1]};
                s.arc.radius = lu;
                s.arc.startAngleDegrees = normalized(std::atan2(dy, dx) * kDegrees);
                s.arc.sweepDegrees = degrees;
            }
            entities.push_back(std::move(s));
        };
        double ox[3], oy[3], on[3];
        if (e.kind != K::Line && e.kind != K::Ellipse && !objectFrame(e.extrusion, ox, oy, on)) {
            ++left[QObject::tr("без оси выдавливания")];
            continue;
        }
        // A point of the object frame (x, y, elevation) in the file's world coordinates.
        const auto framePoint = [&](double x, double y, double z, double* out) {
            for (int i = 0; i < 3; ++i) out[i] = x * ox[i] + y * oy[i] + z * on[i];
        };
        if (e.kind == K::Line) {
            addLine(point(e.start), point(e.end));
        } else if (e.kind == K::Circle || e.kind == K::Arc) {
            double c[3], u[3], v[3];
            framePoint(e.center[0], e.center[1], e.center[2], c);
            for (int i = 0; i < 3; ++i) u[i] = ox[i] * e.radius, v[i] = oy[i] * e.radius;
            if (e.kind == K::Circle) {
                addArc(c, u, v, 0.0, 2 * kPi, true);
            } else {
                double sweep = std::fmod(e.endAngle - e.startAngle, 2 * kPi);
                if (sweep < 0.0) sweep += 2 * kPi;
                addArc(c, u, v, e.startAngle, sweep, false);
            }
        } else if (e.kind == K::Ellipse) {
            if (std::fabs(e.ratio - 1.0) > 1e-12) {
                ++left[QObject::tr("эллипсы (эскиз их пока не хранит)")];
                continue;
            }
            double n[3], x[3], y[3];
            if (!objectFrame(e.extrusion, x, y, n)) {
                ++left[QObject::tr("без оси выдавливания")];
                continue;
            }
            const double* u = e.majorAxis;
            const double v[3] = {n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0]};
            double sweep = e.endAngle - e.startAngle;
            const bool full = std::fabs(sweep - 2 * kPi) <= 1e-12 || std::fabs(sweep) <= 1e-12;
            sweep = std::fmod(sweep, 2 * kPi);
            if (sweep < 0.0) sweep += 2 * kPi;
            addArc(e.center, u, v, e.startAngle, sweep, full);
        } else if (e.kind == K::Polyline) {
            if (e.widths) {
                ++left[QObject::tr("полилинии с шириной (заливка)")];
                continue;
            }
            const std::size_t n = e.points.size();
            const std::size_t segments = e.closed ? n : (n > 0 ? n - 1 : 0);
            for (std::size_t i = 0; i < segments; ++i) {
                const auto& a = e.points[i];
                const auto& b = e.points[(i + 1) % n];
                const double bulge = i < e.bulges.size() ? e.bulges[i] : 0.0;
                if (bulge == 0.0) {
                    double pa[3], pb[3];
                    framePoint(a[0], a[1], e.elevation, pa);
                    framePoint(b[0], b[1], e.elevation, pb);
                    addLine(point(pa), point(pb));
                    continue;
                }
                // The arc of a bulge (the tangent of a quarter of its angle), counterclockwise from a to b
                // where positive, in the object frame.
                const double dx = b[0] - a[0], dy = b[1] - a[1], chord = std::hypot(dx, dy);
                if (!(chord > 0.0)) {
                    ++left[QObject::tr("дуги нулевой длины")];
                    continue;
                }
                const double offset = chord * (1.0 - bulge * bulge) / (4.0 * bulge);
                const double cx = (a[0] + b[0]) / 2.0 - dy / chord * offset, cy = (a[1] + b[1]) / 2.0 + dx / chord * offset;
                const double radius = chord * (1.0 + bulge * bulge) / (4.0 * std::fabs(bulge));
                const auto& start = bulge > 0.0 ? a : b;
                const double from = std::atan2(start[1] - cy, start[0] - cx);
                double c[3], u[3], v[3];
                framePoint(cx, cy, e.elevation, c);
                for (int k = 0; k < 3; ++k) u[k] = ox[k] * radius, v[k] = oy[k] * radius;
                addArc(c, u, v, from, 4.0 * std::atan(std::fabs(bulge)), false);
            }
        }
    }
}


} // namespace cadnext::gui
