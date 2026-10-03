#include "cadnext/gui/NativeKompasPreview.hpp"

#include <QObject>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <map>
#include <stdexcept>

namespace cadnext::gui {
namespace {

struct Writer {
    QByteArray bytes;
    void little(quint64 value, int width) {
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void big(quint64 value, int width) {
        for (int i = width - 1; i >= 0; --i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void text(const QString& value) {
        little(quint64(value.size()), 4);
        for (const auto c : value) little(c.unicode(), 2);
    }
};

struct Reader {
    const QByteArray& bytes;
    qsizetype at = 0;
    quint64 little(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("truncated");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    QString text() {
        const auto count = little(4);
        if (count > 65536 || count * 2 > quint64(bytes.size() - at)) throw std::runtime_error("text");
        QString value;
        for (quint64 i = 0; i < count; ++i) value.append(QChar(ushort(little(2))));
        return value;
    }
};

quint64 big(const QByteArray& b, qsizetype at, int width) {
    if (at < 0 || width > b.size() - at) throw std::runtime_error("truncated");
    quint64 value = 0;
    for (int i = 0; i < width; ++i) value = (value << 8) | uchar(b[at + i]);
    return value;
}

// TIFF's LZW: codes from 9 to 12 bits, most significant bit first, 256 clears the table and 257 ends the
// strip; the code width grows one code early (when the decoder's next code reaches 511, 1023, 2047).
QByteArray lzwEncode(const quint8* data, std::size_t size) {
    QByteArray out;
    quint32 buffer = 0;
    int filled = 0;
    int width = 9;
    const auto put = [&](int code) {
        buffer = (buffer << width) | quint32(code);
        filled += width;
        while (filled >= 8) {
            out.append(char((buffer >> (filled - 8)) & 0xff));
            filled -= 8;
        }
        buffer &= (1u << filled) - 1;
    };
    std::map<std::pair<int, int>, int> table; // (prefix code, byte) -> code
    int next = 258;
    put(256);
    if (size > 0) {
        int prefix = data[0];
        for (std::size_t i = 1; i < size; ++i) {
            const auto found = table.find({prefix, data[i]});
            if (found != table.end()) {
                prefix = found->second;
                continue;
            }
            put(prefix);
            table.emplace(std::pair{prefix, int(data[i])}, next++);
            if (next == 4094) {
                put(256);
                table.clear();
                next = 258;
                width = 9;
            } else if (next > (1 << width) - 1) {
                ++width;
            }
            prefix = data[i];
        }
        put(prefix);
        ++next; // the decoder adds an entry for this code too, so the end code may be one bit wider
        if (next > (1 << width) - 1 && width < 12) ++width;
    }
    put(257);
    if (filled > 0) out.append(char((buffer << (8 - filled)) & 0xff));
    return out;
}

std::vector<quint8> lzwDecode(const QByteArray& in, std::size_t expected) {
    std::vector<quint8> out;
    std::vector<std::vector<quint8>> table;
    const auto reset = [&] {
        table.assign(258, {});
        for (int i = 0; i < 256; ++i) table[std::size_t(i)] = {quint8(i)};
    };
    reset();
    int width = 9;
    quint64 bits = 0;
    int filled = 0;
    qsizetype at = 0;
    int old = -1;
    for (;;) {
        while (filled < width) {
            // A strip may end without its end code once its row is complete, as libtiff accepts.
            if (at >= in.size()) {
                if (out.size() == expected) return out;
                throw std::runtime_error("lzw");
            }
            bits = (bits << 8) | uchar(in[at++]);
            filled += 8;
        }
        const int code = int((bits >> (filled - width)) & ((1u << width) - 1));
        filled -= width;
        if (code == 257) break;
        if (code == 256) {
            reset();
            width = 9;
            old = -1;
            continue;
        }
        std::vector<quint8> entry;
        if (code < int(table.size())) {
            entry = table[std::size_t(code)];
            if (old >= 0) {
                auto added = table[std::size_t(old)];
                added.push_back(entry.front());
                table.push_back(std::move(added));
            }
        } else if (code == int(table.size()) && old >= 0) {
            entry = table[std::size_t(old)];
            entry.push_back(entry.front());
            table.push_back(entry);
        } else {
            throw std::runtime_error("lzw code");
        }
        out.insert(out.end(), entry.begin(), entry.end());
        if (out.size() > expected) throw std::runtime_error("lzw size");
        old = code;
        if (int(table.size()) + 1 > (1 << width) - 1 && width < 12) ++width;
    }
    if (out.size() != expected) throw std::runtime_error("lzw size");
    return out;
}

constexpr int kTags = 15;

} // namespace

bool encodeKompasPreview(const KompasPreview& p, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    const int w = p.image.width, h = p.image.height;
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || p.image.rgb.size() != std::size_t(w) * std::size_t(h) * 3) {
        error = QObject::tr("Недопустимая миниатюра КОМПАС.");
        return false;
    }
    // The TIFF: its header, the strips, the directory, then the arrays it points to — as KOMPAS lays it out.
    Writer t;
    t.bytes.append("MM", 2);
    t.big(42, 2);
    t.big(0, 4); // the directory's offset, set below
    std::vector<quint32> offsets, counts;
    for (int y = 0; y < h; ++y) {
        const QByteArray strip = lzwEncode(p.image.rgb.data() + std::size_t(y) * std::size_t(w) * 3, std::size_t(w) * 3);
        offsets.push_back(quint32(t.bytes.size()));
        counts.push_back(quint32(strip.size()));
        t.bytes += strip;
    }
    const quint32 directory = quint32(t.bytes.size());
    const quint32 bitsAt = directory + 2 + kTags * 12 + 4;
    const quint32 offsetsAt = bitsAt + 6, countsAt = offsetsAt + 4 * quint32(h), xAt = countsAt + 4 * quint32(h), yAt = xAt + 8;
    for (int i = 0; i < 4; ++i) t.bytes[4 + i] = char((directory >> (8 * (3 - i))) & 0xff);
    t.big(kTags, 2);
    const auto tag = [&](int id, int type, quint32 count, quint32 value) {
        t.big(quint64(id), 2);
        t.big(quint64(type), 2);
        t.big(count, 4);
        if (type == 3 && count == 1) {
            t.big(value, 2);
            t.big(0, 2);
        } else {
            t.big(value, 4);
        }
    };
    tag(254, 4, 1, 0);      // NewSubfileType
    tag(256, 3, 1, quint32(w)); // ImageWidth
    tag(257, 3, 1, quint32(h)); // ImageLength
    tag(258, 3, 3, bitsAt); // BitsPerSample
    tag(259, 3, 1, 5);      // Compression: LZW
    tag(262, 3, 1, 2);      // Photometric: RGB
    tag(273, 4, quint32(h), offsetsAt);
    tag(274, 3, 1, 1);      // Orientation
    tag(277, 3, 1, 3);      // SamplesPerPixel
    tag(278, 3, 1, 1);      // RowsPerStrip
    tag(279, 4, quint32(h), countsAt);
    tag(282, 5, 1, xAt);    // XResolution
    tag(283, 5, 1, yAt);    // YResolution
    tag(284, 3, 1, 1);      // PlanarConfiguration
    tag(296, 3, 1, 2);      // ResolutionUnit: inch
    t.big(0, 4);
    for (int i = 0; i < 3; ++i) t.big(8, 2);
    for (const quint32 o : offsets) t.big(o, 4);
    for (const quint32 c : counts) t.big(c, 4);
    // 72/1 dots per inch, its two words written low byte first as KOMPAS 17.1 writes them (still read as 72).
    for (int i = 0; i < 2; ++i) {
        t.little(72, 4);
        t.little(1, 4);
    }
    Writer w2;
    w2.bytes.append("KF", 2);
    w2.little(p.sizeA, 4);
    w2.little(p.sizeB, 4);
    w2.little(p.background, 4);
    w2.little(quint64(t.bytes.size()), 4);
    w2.bytes += t.bytes;
    w2.little(4, 4);
    for (const QString* s : {&p.designation, &p.name, &p.author, &p.comment}) {
        if (s->size() > 65536) {
            error = QObject::tr("Недопустимая подпись миниатюры КОМПАС.");
            return false;
        }
        w2.text(*s);
    }
    bytes = std::move(w2.bytes);
    return true;
}

bool decodeKompasPreview(const QByteArray& bytes, KompasPreview& p, QString& error) {
    p = {};
    error.clear();
    try {
        if (!bytes.startsWith("KF")) throw std::runtime_error("kf");
        Reader r{bytes, 2};
        p.sizeA = quint32(r.little(4));
        p.sizeB = quint32(r.little(4));
        p.background = quint32(r.little(4));
        const auto length = r.little(4);
        if (length > quint64(bytes.size() - r.at)) throw std::runtime_error("tiff");
        const QByteArray t = bytes.mid(r.at, qsizetype(length));
        r.at += qsizetype(length);
        if (!t.startsWith(QByteArray("MM\0*", 4))) throw std::runtime_error("tiff");
        const qsizetype directory = qsizetype(big(t, 4, 4));
        const int tags = int(big(t, directory, 2));
        int w = 0, h = 0, compression = 0, samples = 0, rows = 0;
        qsizetype offsetsAt = 0, countsAt = 0;
        for (int i = 0; i < tags; ++i) {
            const qsizetype e = directory + 2 + 12 * i;
            const int id = int(big(t, e, 2)), type = int(big(t, e + 2, 2));
            const quint32 count = quint32(big(t, e + 4, 4));
            const quint32 value = type == 3 && count == 1 ? quint32(big(t, e + 8, 2)) : quint32(big(t, e + 8, 4));
            if (id == 256) w = int(value);
            if (id == 257) h = int(value);
            if (id == 259) compression = int(value);
            if (id == 277) samples = int(value);
            if (id == 278) rows = int(value);
            if (id == 273) offsetsAt = value;
            if (id == 279) countsAt = value;
        }
        if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || compression != 5 || samples != 3 || rows != 1)
            throw std::runtime_error("profile");
        p.image.width = w;
        p.image.height = h;
        p.image.rgb.reserve(std::size_t(w) * std::size_t(h) * 3);
        for (int y = 0; y < h; ++y) {
            const qsizetype offset = qsizetype(big(t, offsetsAt + 4 * y, 4)), count = qsizetype(big(t, countsAt + 4 * y, 4));
            if (offset < 0 || count < 0 || offset + count > t.size()) throw std::runtime_error("strip");
            const auto row = lzwDecode(t.mid(offset, count), std::size_t(w) * 3);
            p.image.rgb.insert(p.image.rgb.end(), row.begin(), row.end());
        }
        if (r.little(4) != 4) throw std::runtime_error("texts");
        p.designation = r.text();
        p.name = r.text();
        p.author = r.text();
        p.comment = r.text();
        if (r.at != bytes.size()) throw std::runtime_error("trailing");
        return true;
    } catch (const std::exception& failure) {
        p = {};
        error = QObject::tr("Миниатюра КОМПАС вне поддержанного профиля v17 (%1).").arg(QString::fromUtf8(failure.what()));
        return false;
    }
}

KompasPreviewImage renderKompasPreview(const std::vector<KompasMesh>& meshes, quint32 color, int width, int height) {
    KompasPreviewImage image;
    image.width = width;
    image.height = height;
    image.rgb.assign(std::size_t(width) * std::size_t(height) * 3, 0xff);
    // The default view's rows (/#140): screen right, screen up, towards the viewer.
    const double r[3][3] = {{-0.93969262078590832, 0.34202014332566882, 0.0},
                            {-0.11697777844051101, -0.32139380484326963, 0.93969262078590832},
                            {0.32139380484326974, 0.88302222155948895, 0.34202014332566871}};
    const auto project = [&](const std::array<float, 3>& p, int row) {
        return r[row][0] * p[0] + r[row][1] * p[1] + r[row][2] * p[2];
    };
    double x0 = 1e300, x1 = -1e300, y0 = 1e300, y1 = -1e300;
    for (const auto& m : meshes)
        for (const auto* list : {&m.curved, &m.planar})
            for (const auto& g : *list)
                for (const auto& grid : g.grids)
                    for (const auto& p : grid.points) {
                        const double sx = project(p, 0), sy = project(p, 1);
                        x0 = std::min(x0, sx), x1 = std::max(x1, sx), y0 = std::min(y0, sy), y1 = std::max(y1, sy);
                    }
    if (!(x1 > x0) && !(y1 > y0)) return image;
    const double scale = std::min(width * 0.84 / std::max(x1 - x0, 1e-9), height * 0.84 / std::max(y1 - y0, 1e-9));
    const double cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    const auto screen = [&](const std::array<float, 3>& p, double& sx, double& sy, double& depth) {
        sx = width / 2.0 + (project(p, 0) - cx) * scale;
        sy = height / 2.0 - (project(p, 1) - cy) * scale;
        depth = project(p, 2);
    };
    std::vector<double> zbuffer(std::size_t(width) * std::size_t(height), -std::numeric_limits<double>::infinity());
    double light[3] = {r[2][0] + 0.35 * r[1][0] - 0.25 * r[0][0], r[2][1] + 0.35 * r[1][1] - 0.25 * r[0][1],
                       r[2][2] + 0.35 * r[1][2] - 0.25 * r[0][2]};
    const double ll = std::sqrt(light[0] * light[0] + light[1] * light[1] + light[2] * light[2]);
    for (double& v : light) v /= ll;
    const double base[3] = {double((color >> 16) & 0xff), double((color >> 8) & 0xff), double(color & 0xff)};
    const auto pixel = [&](int x, int y, double depth, const double rgb[3]) {
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        double& z = zbuffer[std::size_t(y) * std::size_t(width) + std::size_t(x)];
        if (depth <= z) return;
        z = depth;
        quint8* out = &image.rgb[(std::size_t(y) * std::size_t(width) + std::size_t(x)) * 3];
        for (int c = 0; c < 3; ++c) out[c] = quint8(std::clamp(rgb[c], 0.0, 255.0));
    };
    for (const auto& m : meshes)
        for (const auto* list : {&m.curved, &m.planar})
            for (const auto& g : *list)
                for (const auto& grid : g.grids)
                    for (const auto& t : grid.triangles) {
                        double sx[3], sy[3], sz[3], shade[3];
                        for (int k = 0; k < 3; ++k) {
                            screen(grid.points[t[k]], sx[k], sy[k], sz[k]);
                            const auto& n = grid.normals[t[k]];
                            shade[k] = 0.3 + 0.7 * std::max(0.0, n[0] * light[0] + n[1] * light[1] + n[2] * light[2]);
                        }
                        const double area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0]);
                        if (std::fabs(area) < 1e-12) continue;
                        const int ax = std::max(0, int(std::floor(std::min({sx[0], sx[1], sx[2]})))),
                                  bx = std::min(width - 1, int(std::ceil(std::max({sx[0], sx[1], sx[2]})))),
                                  ay = std::max(0, int(std::floor(std::min({sy[0], sy[1], sy[2]})))),
                                  by = std::min(height - 1, int(std::ceil(std::max({sy[0], sy[1], sy[2]}))));
                        for (int y = ay; y <= by; ++y)
                            for (int x = ax; x <= bx; ++x) {
                                const double px = x + 0.5, py = y + 0.5;
                                const double w0 = ((sx[1] - px) * (sy[2] - py) - (sx[2] - px) * (sy[1] - py)) / area;
                                const double w1 = ((sx[2] - px) * (sy[0] - py) - (sx[0] - px) * (sy[2] - py)) / area;
                                const double w2 = 1 - w0 - w1;
                                if (w0 < -1e-9 || w1 < -1e-9 || w2 < -1e-9) continue;
                                const double s = w0 * shade[0] + w1 * shade[1] + w2 * shade[2];
                                const double rgb[3] = {base[0] * s, base[1] * s, base[2] * s};
                                pixel(x, y, w0 * sz[0] + w1 * sz[1] + w2 * sz[2], rgb);
                            }
                    }
    // Face boundaries in black: the triangulation's edges used by one triangle, except the seam of a closed
    // face (two such edges in the same place).
    const double black[3] = {0, 0, 0};
    const double bias = 2.0 / scale; // two pixels, in the model's units: an edge is not hidden by its own faces
    for (const auto& m : meshes)
        for (const auto* list : {&m.curved, &m.planar})
            for (const auto& g : *list)
                for (const auto& grid : g.grids) {
                    std::map<std::pair<quint32, quint32>, int> uses;
                    for (const auto& t : grid.triangles)
                        for (int k = 0; k < 3; ++k) ++uses[{std::min(t[k], t[(k + 1) % 3]), std::max(t[k], t[(k + 1) % 3])}];
                    std::map<std::array<long long, 6>, int> places;
                    const auto place = [&](quint32 a, quint32 b) {
                        auto key = [&](quint32 i) {
                            return std::array<long long, 3>{std::llround(grid.points[i][0] * 1e4), std::llround(grid.points[i][1] * 1e4),
                                                            std::llround(grid.points[i][2] * 1e4)};
                        };
                        auto ka = key(a), kb = key(b);
                        if (kb < ka) std::swap(ka, kb);
                        return std::array<long long, 6>{ka[0], ka[1], ka[2], kb[0], kb[1], kb[2]};
                    };
                    for (const auto& [edge, n] : uses)
                        if (n == 1) ++places[place(edge.first, edge.second)];
                    for (const auto& [edge, n] : uses) {
                        if (n != 1 || places[place(edge.first, edge.second)] > 1) continue;
                        double ax, ay, az, bx, by, bz;
                        screen(grid.points[edge.first], ax, ay, az);
                        screen(grid.points[edge.second], bx, by, bz);
                        const int steps = std::max(1, int(std::ceil(std::max(std::fabs(bx - ax), std::fabs(by - ay)))));
                        for (int s = 0; s <= steps; ++s) {
                            const double f = double(s) / steps;
                            pixel(int(std::floor(ax + (bx - ax) * f)), int(std::floor(ay + (by - ay) * f)), az + (bz - az) * f + bias, black);
                        }
                    }
                }
    return image;
}

} // namespace cadnext::gui
