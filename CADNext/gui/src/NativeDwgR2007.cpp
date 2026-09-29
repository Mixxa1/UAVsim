#include "cadnext/gui/NativeDwgR2007.hpp"

#include <QFile>
#include <QObject>

#include <cstring>
#include <vector>

namespace cadnext::gui {

namespace {

using Bytes = std::vector<uchar>;

constexpr quint64 kMaxSection = 512ull * 1024 * 1024;

quint64 le64(const uchar* p) {
    quint64 v = 0;
    for (int i = 7; i >= 0; --i) v = (v << 8) | p[i];
    return v;
}

// The data bytes of `blocks` Reed-Solomon codewords of 255 bytes, `k` of them data: interleaved, byte i of
// codeword b at b + blocks·i; or not, the data parts one after another, the parity after them all.
Bytes rsData(const uchar* p, quint64 blocks, quint64 k, bool interleaved) {
    Bytes out;
    out.reserve(std::size_t(blocks * k));
    for (quint64 b = 0; b < blocks; ++b)
        for (quint64 i = 0; i < k; ++i) out.push_back(interleaved ? p[b + blocks * i] : p[b * k + i]);
    return out;
}

// A literal run's bytes in R21's orders (5.10.1): 32 at a time, the rest by the specification's table, each
// piece by its own copy — 2 bytes swapped, 3 reversed, 4 and 8 as they are, 16 their halves swapped.
void copy16(const uchar* s, uchar* d) {
    std::memcpy(d, s + 8, 8);
    std::memcpy(d + 8, s, 8);
}

void copyRest(const uchar* s, uchar* d, unsigned n) {
    struct Piece {
        unsigned char length, from;
    };
    static const std::vector<std::vector<Piece>> table = {
        {},
        {{1, 0}},
        {{1, 1}, {1, 0}},
        {{1, 2}, {1, 1}, {1, 0}},
        {{1, 0}, {1, 1}, {1, 2}, {1, 3}},
        {{1, 4}, {4, 0}},
        {{1, 5}, {4, 1}, {1, 0}},
        {{2, 5}, {4, 1}, {1, 0}},
        {{4, 0}, {4, 4}},
        {{1, 8}, {8, 0}},
        {{1, 9}, {8, 1}, {1, 0}},
        {{2, 9}, {8, 1}, {1, 0}},
        {{4, 8}, {8, 0}},
        {{1, 12}, {4, 8}, {8, 0}},
        {{1, 13}, {4, 9}, {8, 1}, {1, 0}},
        {{2, 13}, {4, 9}, {8, 1}, {1, 0}},
        {{8, 8}, {8, 0}},
        {{8, 9}, {1, 8}, {8, 0}},
        {{1, 17}, {16, 1}, {1, 0}},
        {{3, 16}, {16, 0}},
        {{4, 16}, {16, 0}},
        {{1, 20}, {4, 16}, {16, 0}},
        {{2, 20}, {4, 16}, {16, 0}},
        {{3, 20}, {4, 16}, {16, 0}},
        {{8, 16}, {16, 0}},
        {{8, 17}, {1, 16}, {16, 0}},
        {{1, 25}, {8, 17}, {1, 16}, {16, 0}},
        {{2, 25}, {8, 17}, {1, 16}, {16, 0}},
        {{4, 24}, {8, 16}, {16, 0}},
        {{1, 28}, {4, 24}, {8, 16}, {16, 0}},
        {{2, 28}, {4, 24}, {8, 16}, {16, 0}},
        {{1, 30}, {4, 26}, {8, 18}, {16, 2}, {2, 0}},
    };
    unsigned at = 0;
    for (const Piece& piece : table[n]) {
        const uchar* q = s + piece.from;
        switch (piece.length) {
        case 2:
            d[at] = q[1];
            d[at + 1] = q[0];
            break;
        case 3:
            d[at] = q[2];
            d[at + 1] = q[1];
            d[at + 2] = q[0];
            break;
        case 16: copy16(q, d + at); break;
        default: std::memcpy(d + at, q, piece.length);
        }
        at += piece.length;
    }
}

void copyLiteral(const uchar* s, uchar* d, quint32 n) {
    for (; n >= 32; s += 32, d += 32, n -= 32) {
        copy16(s + 16, d);
        copy16(s, d + 16);
    }
    if (n) copyRest(s, d, n);
}

// R21's LZ77 variant (5.10): a literal run, then copies from what is already decompressed, until the source
// ends; exactly `expected` bytes or false.
bool decompress(const uchar* src, quint64 size, Bytes& out, quint64 expected, QString& why) {
    out.assign(std::size_t(expected), 0);
    quint64 si = 0, di = 0;
    quint32 length = 0, offset = 0;
    const auto need = [&](quint64 n) { return si + n <= size; };
    if (!need(1)) return why = QObject::tr("сжатые данные DWG 2007 пусты"), false;
    uchar op = src[si++];
    if ((op & 0xF0) == 0x20) {
        if (!need(3)) return why = QObject::tr("сжатые данные DWG 2007 обрезаны"), false;
        si += 2;
        length = src[si++] & 7;
    }
    const auto literalLength = [&]() {
        length = op + 8u;
        if (length == 0x17) {
            if (!need(1)) return false;
            quint32 n = src[si++];
            length += n;
            if (n == 0xFF) {
                do {
                    if (!need(2)) return false;
                    n = src[si] | (quint32(src[si + 1]) << 8);
                    si += 2;
                    length += n;
                } while (n == 0xFFFF);
            }
        }
        return true;
    };
    const auto instructions = [&]() {
        switch (op >> 4) {
        case 0:
            if (!need(2)) return false;
            length = (op & 0xF) + 0x13;
            offset = src[si++];
            op = src[si++];
            length += (op >> 3) & 0x10;
            offset += ((op & 0x78) << 5) + 1;
            return true;
        case 1:
            if (!need(2)) return false;
            length = (op & 0xF) + 3;
            offset = src[si++];
            op = src[si++];
            offset += ((op & 0xF8) << 5) + 1;
            return true;
        case 2:
            if (!need(3)) return false;
            offset = src[si] | (quint32(src[si + 1]) << 8);
            si += 2;
            length = op & 7;
            if (!(op & 8)) {
                op = src[si++];
                length += op & 0xF8;
            } else {
                if (!need(2)) return false;
                ++offset;
                length += quint32(src[si++]) << 3;
                op = src[si++];
                length += ((op & 0xF8) << 8) + 0x100;
            }
            return true;
        default:
            if (!need(1)) return false;
            length = op >> 4;
            offset = op & 15;
            op = src[si++];
            offset += ((op & 0xF8) << 1) + 1;
            return true;
        }
    };
    while (si < size) {
        if (length == 0 && !literalLength()) return why = QObject::tr("сжатые данные DWG 2007 обрезаны"), false;
        if (di + length > expected || si + length > size) return why = QObject::tr("литерал сжатых данных DWG 2007 за концом"), false;
        copyLiteral(src + si, out.data() + di, length);
        si += length;
        di += length;
        if (si >= size) break;
        length = 0;
        op = src[si++];
        if (!instructions()) return why = QObject::tr("сжатые данные DWG 2007 обрезаны"), false;
        while (true) {
            if (offset > di || di + length > expected) return why = QObject::tr("ссылка сжатых данных DWG 2007 за пределами"), false;
            for (quint32 k = 0; k < length; ++k) out[std::size_t(di + k)] = out[std::size_t(di - offset + k)];
            di += length;
            length = op & 7;
            if (length != 0 || si >= size) break;
            op = src[si++];
            if ((op >> 4) == 0) break;
            if ((op >> 4) == 15) op &= 15;
            if (!instructions()) return why = QObject::tr("сжатые данные DWG 2007 обрезаны"), false;
        }
    }
    if (di != expected) return why = QObject::tr("сжатые данные DWG 2007 дали %1 байт вместо %2").arg(di).arg(expected), false;
    return true;
}

// A system page (5.3): its data repeated `factor` times, RS (255, 239) interleaved; the first copy,
// decompressed where compressed.
bool systemPage(const QByteArray& file, quint64 at, quint64 compressed, quint64 size, quint64 factor, Bytes& out, QString& why) {
    if (compressed == 0 || size == 0 || factor == 0 || factor > 64 || compressed > kMaxSection || size > kMaxSection)
        return why = QObject::tr("системная страница DWG 2007 с невероятными размерами"), false;
    const quint64 aligned = (compressed + 7) & ~quint64(7);
    const quint64 blocks = (aligned * factor + 238) / 239;
    if (at + blocks * 255 > quint64(file.size())) return why = QObject::tr("системная страница DWG 2007 за концом файла"), false;
    const Bytes data = rsData(reinterpret_cast<const uchar*>(file.constData()) + at, blocks, 239, true);
    if (compressed < size) return decompress(data.data(), compressed, out, size, why);
    out.assign(data.begin(), data.begin() + std::ptrdiff_t(size));
    return true;
}

} // namespace

bool readDwgR2007Sections(const QString& path, std::map<QString, QByteArray>& sections, QString& error, const QStringList& wanted) {
    sections.clear();
    QFile input(path);
    if (!input.open(QIODevice::ReadOnly)) return error = QObject::tr("Не удалось открыть %1.").arg(path), false;
    const QByteArray file = input.readAll();
    if (file.size() < 0x480 || !file.startsWith("AC1021")) return error = QObject::tr("Это не DWG 2007 (AC1021)."), false;
    const auto* bytes = reinterpret_cast<const uchar*>(file.constData());

    // The file header: 3 codewords of RS (255, 239), interleaved, at 0x80; its data compressed to 0x110 bytes.
    const Bytes coded = rsData(bytes + 0x80, 3, 239, true);
    const qint32 length = qint32(quint32(coded[0x18]) | quint32(coded[0x19]) << 8 | quint32(coded[0x1A]) << 16 | quint32(coded[0x1B]) << 24);
    Bytes header;
    QString why;
    if (length > 0) {
        if (quint64(length) + 0x20 > coded.size() || !decompress(coded.data() + 0x20, quint64(length), header, 0x110, why))
            return error = QObject::tr("Заголовок DWG 2007 не прочитан: %1").arg(why), false;
    } else if (-qint64(length) + 0x20 <= qint64(coded.size())) {
        header.assign(coded.begin() + 0x20, coded.begin() + 0x20 + (-length));
    }
    if (header.size() < 0x110) return error = QObject::tr("Заголовок DWG 2007 короче своих полей."), false;
    const auto field = [&](int index) { return le64(header.data() + 8 * index); };
    // (Its own check: its size 0x70 and the file's size as the file is.)
    if (field(0) != 0x70 || field(1) != quint64(file.size()))
        return error = QObject::tr("Заголовок DWG 2007 не сходится с файлом (размер %1 против %2).").arg(field(1)).arg(file.size()), false;

    // The page map: sizes and ids, the pages one after another from 0x480.
    Bytes pageMap;
    if (!systemPage(file, 0x480 + field(7), field(10), field(11), field(3), pageMap, why))
        return error = QObject::tr("Карта страниц DWG 2007: %1").arg(why), false;
    const quint64 maxId = field(13);
    if (maxId > 1000000) return error = QObject::tr("Карта страниц DWG 2007 невероятна."), false;
    std::vector<quint64> pageOffset(std::size_t(maxId + 1), ~quint64(0));
    quint64 offset = 0;
    for (std::size_t p = 0; p + 16 <= pageMap.size(); p += 16) {
        const quint64 size = le64(&pageMap[p]);
        const qint64 id = qint64(le64(&pageMap[p + 8]));
        const quint64 index = quint64(id > 0 ? id : -id);
        if (index <= maxId) pageOffset[std::size_t(index)] = offset;
        offset += size;
    }

    // The section map, then each section's pages.
    const quint64 sectionMapId = field(24);
    if (sectionMapId > maxId || pageOffset[std::size_t(sectionMapId)] == ~quint64(0))
        return error = QObject::tr("Карта разделов DWG 2007 не найдена."), false;
    Bytes map;
    if (!systemPage(file, 0x480 + pageOffset[std::size_t(sectionMapId)], field(22), field(25), field(27), map, why))
        return error = QObject::tr("Карта разделов DWG 2007: %1").arg(why), false;
    std::size_t p = 0;
    while (p + 64 <= map.size()) {
        const quint64 dataSize = le64(&map[p]), encryption = le64(&map[p + 16]), nameBytes = le64(&map[p + 32]),
                      encoding = le64(&map[p + 48]), pageCount = le64(&map[p + 56]);
        p += 64;
        if (nameBytes > 512 || p + nameBytes > map.size() || pageCount > 100000) break;
        QString name;
        for (quint64 i = 0; i + 1 < nameBytes; i += 2) {
            const char16_t c = char16_t(map[std::size_t(p + i)] | (map[std::size_t(p + i + 1)] << 8));
            if (c) name += QChar(c);
        }
        p += std::size_t(nameBytes);
        const bool keep = !name.isEmpty() && (wanted.isEmpty() || wanted.contains(name));
        QByteArray section;
        if (keep) {
            if (dataSize > kMaxSection) return error = QObject::tr("Раздел DWG 2007 %1 невероятно велик.").arg(name), false;
            if (encryption != 0) return error = QObject::tr("Раздел DWG 2007 %1 зашифрован — не читается.").arg(name), false;
            section = QByteArray(qsizetype(dataSize), '\0');
        }
        for (quint64 k = 0; k < pageCount; ++k, p += 56) {
            if (p + 56 > map.size()) return error = QObject::tr("Карта разделов DWG 2007 обрезана."), false;
            if (!keep) continue;
            const quint64 dataOffset = le64(&map[p]), id = le64(&map[p + 16]), size = le64(&map[p + 24]), compressed = le64(&map[p + 32]);
            if (id > maxId || pageOffset[std::size_t(id)] == ~quint64(0) || dataOffset + size > dataSize || compressed > kMaxSection)
                return error = QObject::tr("Страница раздела DWG 2007 %1 не на месте.").arg(name), false;
            const quint64 aligned = (compressed + 7) & ~quint64(7), blocks = (aligned + 250) / 251;
            const quint64 at = 0x480 + pageOffset[std::size_t(id)];
            if (at + blocks * 255 > quint64(file.size())) return error = QObject::tr("Страница раздела DWG 2007 %1 за концом файла.").arg(name), false;
            const Bytes data = rsData(bytes + at, blocks, 251, encoding == 4);
            Bytes page;
            if (compressed < size) {
                if (!decompress(data.data(), compressed, page, size, why))
                    return error = QObject::tr("Страница раздела DWG 2007 %1: %2").arg(name, why), false;
            } else {
                page.assign(data.begin(), data.begin() + std::ptrdiff_t(size));
            }
            std::memcpy(section.data() + dataOffset, page.data(), std::size_t(size));
        }
        if (keep) sections[name] = section;
    }
    for (const QString& name : wanted)
        if (!sections.count(name)) return error = QObject::tr("В DWG 2007 нет раздела %1.").arg(name), false;
    return true;
}

} // namespace cadnext::gui
