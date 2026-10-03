#include "cadnext/gui/NativeDwgR2000.hpp"

#include <QObject>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <type_traits>

namespace cadnext::gui {
namespace {

constexpr quint64 kMaxCount = 1u << 20;

const unsigned char kHeaderSentinel[16] = {0xCF, 0x7B, 0x1F, 0x23, 0xFD, 0xDE, 0x38, 0xA9, 0x5F, 0x7C, 0x68, 0xB8, 0x4E, 0x6D, 0x33, 0x5F};
const unsigned char kHeaderEnd[16] = {0x30, 0x84, 0xE0, 0xDC, 0x02, 0x21, 0xC7, 0x56, 0xA0, 0x83, 0x97, 0x47, 0xB1, 0x92, 0xCC, 0xA0};
const unsigned char kClassesSentinel[16] = {0x8D, 0xA1, 0xC4, 0xB8, 0xC4, 0xA9, 0xF8, 0xC5, 0xC0, 0xDC, 0xF4, 0x5F, 0xE7, 0xCF, 0xB6, 0x8A};
const unsigned char kClassesEnd[16] = {0x72, 0x5E, 0x3B, 0x47, 0x3B, 0x56, 0x07, 0x3A, 0x3F, 0x23, 0x0B, 0xA0, 0x18, 0x30, 0x49, 0x75};
const unsigned char kFileSentinel[16] = {0x95, 0xA0, 0x4E, 0x28, 0x99, 0x82, 0x1A, 0xE5, 0x5E, 0x41, 0xE0, 0x5F, 0x9D, 0x3A, 0x4D, 0x00};
const unsigned char kSecondSentinel[16] = {0xD4, 0x7B, 0x21, 0xCE, 0x28, 0x93, 0x9F, 0xBF, 0x53, 0x24, 0x40, 0x09, 0x12, 0x3C, 0xAA, 0x01};
const unsigned char kSecondEnd[16] = {0x2B, 0x84, 0xDE, 0x31, 0xD7, 0x6C, 0x60, 0x40, 0xAC, 0xDB, 0xBF, 0xF6, 0xED, 0xC3, 0x55, 0xFE};
const unsigned char kImageSentinel[16] = {0x1F, 0x25, 0x6D, 0x07, 0xD4, 0x36, 0x28, 0x28, 0x9D, 0x57, 0xCA, 0x3F, 0x9D, 0x44, 0x10, 0x2B};
const unsigned char kImageEnd[16] = {0xE0, 0xDA, 0x92, 0xF8, 0x2B, 0xC9, 0xD7, 0xD7, 0x62, 0xA8, 0x35, 0xC0, 0x62, 0xBB, 0xEF, 0xD4};

QByteArray sentinel(const unsigned char (&bytes)[16]) { return QByteArray(reinterpret_cast<const char*>(bytes), 16); }
bool hasSentinel(const QByteArray& file, qint64 at, const unsigned char (&bytes)[16]) {
    return at >= 0 && at + 16 <= file.size() && std::memcmp(file.constData() + at, bytes, 16) == 0;
}

quint32 le32(const QByteArray& b, qint64 at) {
    return quint32(uchar(b[at])) | quint32(uchar(b[at + 1])) << 8 | quint32(uchar(b[at + 2])) << 16 | quint32(uchar(b[at + 3])) << 24;
}
quint16 le16(const QByteArray& b, qint64 at) { return quint16(uchar(b[at]) | uchar(b[at + 1]) << 8); }
void put16(QByteArray& b, quint16 v) { b.append(char(v & 0xFF)); b.append(char(v >> 8)); }
void put32(QByteArray& b, quint32 v) { put16(b, quint16(v & 0xFFFF)); put16(b, quint16(v >> 16)); }

// ---- bit streams: one interface for reading and writing, so that every layout is written once ----

class BitWriter {
public:
    static constexpr bool reading = false;
    bool ok = true;

    void bit(const bool& v) { push(v ? 1 : 0); }
    void bits(unsigned value, int count) {
        for (int i = count - 1; i >= 0; --i) push((value >> i) & 1u);
    }
    void bb(const int& v) { bits(unsigned(v) & 3u, 2); }
    void rc(const quint8& v) { bits(v, 8); }
    void rs(const quint16& v) { rc(quint8(v & 0xFF)); rc(quint8(v >> 8)); }
    void rl(const quint32& v) { rs(quint16(v & 0xFFFF)); rs(quint16(v >> 16)); }
    void rd(const double& v) {
        quint64 raw = 0;
        std::memcpy(&raw, &v, 8);
        for (int i = 0; i < 8; ++i) rc(quint8(raw >> (8 * i)));
    }
    // The shortest form, as AutoCAD writes every value of the samples.
    void bs(const int& v) {
        if (v == 0) bits(2, 2);
        else if (v == 256) bits(3, 2);
        else if (v > 0 && v < 256) { bits(1, 2); rc(quint8(v)); }
        else { bits(0, 2); rs(quint16(v & 0xFFFF)); }
    }
    void bsFull(const quint16& v) { bits(0, 2); rs(v); }
    void bl(const qint32& v) {
        if (v == 0) bits(2, 2);
        else if (v > 0 && v < 256) { bits(1, 2); rc(quint8(v)); }
        else { bits(0, 2); rl(quint32(v)); }
    }
    void bd(const double& v) {
        quint64 raw = 0, one = 0;
        const double unit = 1.0;
        std::memcpy(&raw, &v, 8);
        std::memcpy(&one, &unit, 8);
        if (raw == one) bits(1, 2);
        else if (raw == 0) bits(2, 2);
        else { bits(0, 2); rd(v); }
    }
    void handle(const DwgHandleRef& h) {
        int counter = 0;
        for (quint64 x = h.value; x; x >>= 8) ++counter;
        bits(h.code & 15u, 4);
        bits(unsigned(counter), 4);
        for (int i = counter - 1; i >= 0; --i) rc(quint8(h.value >> (8 * i)));
    }
    void text(const QByteArray& t) {
        bs(int(t.size()));
        for (char c : t) rc(quint8(c));
    }
    void raw(const QByteArray& bytes, qsizetype count) {
        if (bytes.size() != count) { ok = false; return; }
        for (char c : bytes) rc(quint8(c));
    }
    void point3(const std::array<double, 3>& p) { for (double v : p) bd(v); }
    void point2(const std::array<double, 2>& p) { for (double v : p) bd(v); }
    void rawPoint2(const std::array<double, 2>& p) { for (double v : p) rd(v); }
    // A count of a list: the list's own size.
    template <class T>
    bool countBL(std::vector<T>& list) { bl(qint32(list.size())); return true; }
    template <class T>
    bool countBS(std::vector<T>& list) { bs(int(list.size())); return true; }
    template <class T>
    bool countRC(std::vector<T>& list) {
        if (list.size() > 255) return ok = false;
        rc(quint8(list.size()));
        return true;
    }

    std::size_t position() const { return bits_.size(); }
    void patch32(std::size_t at, quint32 value) {
        for (int byte = 0; byte < 4; ++byte)
            for (int i = 0; i < 8; ++i) bits_[at + std::size_t(byte) * 8 + std::size_t(i)] = (value >> (8 * byte + 7 - i)) & 1u;
    }
    QByteArray bytes() const {
        QByteArray out(qsizetype((bits_.size() + 7) / 8), '\0');
        for (std::size_t i = 0; i < bits_.size(); ++i)
            if (bits_[i]) out[qsizetype(i >> 3)] = char(uchar(out[qsizetype(i >> 3)]) | (0x80u >> (i & 7)));
        return out;
    }

private:
    void push(unsigned b) { bits_.push_back(quint8(b)); }
    std::vector<quint8> bits_;
};

class BitReader {
public:
    static constexpr bool reading = true;
    bool ok = true;

    BitReader(const QByteArray& data, quint64 begin, quint64 end) : data_(data), position_(begin), end_(end) {
        if (end_ > quint64(data.size()) * 8) { end_ = quint64(data.size()) * 8; ok = false; }
    }
    unsigned take() {
        if (position_ >= end_) { ok = false; return 0; }
        const unsigned b = (uchar(data_[qsizetype(position_ >> 3)]) >> (7 - (position_ & 7))) & 1u;
        ++position_;
        return b;
    }
    unsigned bits(int count) {
        unsigned v = 0;
        while (count-- > 0) v = (v << 1) | take();
        return v;
    }
    void bit(bool& v) { v = take() != 0; }
    void bb(int& v) { v = int(bits(2)); }
    void rc(quint8& v) { v = quint8(bits(8)); }
    quint8 rc() { quint8 v; rc(v); return v; }
    void rs(quint16& v) { const quint16 low = rc(); v = quint16(low | (rc() << 8)); }
    quint16 rs() { quint16 v; rs(v); return v; }
    void rl(quint32& v) { const quint32 low = rs(); v = low | (quint32(rs()) << 16); }
    void rd(double& v) {
        quint64 raw = 0;
        for (int i = 0; i < 8; ++i) raw |= quint64(rc()) << (8 * i);
        std::memcpy(&v, &raw, 8);
    }
    // Refuses forms the writer would not choose: the codecs must give the file back as it was.
    void bs(int& v) {
        switch (bits(2)) {
        case 0: v = qint16(rs()); if (v == 0 || v == 256 || (v > 0 && v < 256)) canonical = false; break;
        case 1: v = rc(); if (v == 0) canonical = false; break;
        case 2: v = 0; break;
        default: v = 256; break;
        }
    }
    void bsFull(quint16& v) { if (bits(2) != 0) ok = false; rs(v); }
    void bl(qint32& v) {
        switch (bits(2)) {
        case 0: { quint32 r; rl(r); v = qint32(r); if (v >= 0 && v < 256) canonical = false; break; }
        case 1: v = rc(); if (v == 0) canonical = false; break;
        case 2: v = 0; break;
        default: ok = false; v = 0; break;
        }
    }
    void bd(double& v) {
        switch (bits(2)) {
        case 0: {
            rd(v);
            quint64 raw = 0;
            std::memcpy(&raw, &v, 8);
            if (v == 1.0 || raw == 0) canonical = false;
            break;
        }
        case 1: v = 1.0; break;
        case 2: v = 0.0; break;
        default: ok = false; v = 0; break;
        }
    }
    void handle(DwgHandleRef& h) {
        h.code = quint8(bits(4));
        const int counter = int(bits(4));
        h.value = 0;
        for (int i = 0; i < counter; ++i) h.value = (h.value << 8) | rc();
        if (counter > 0 && (h.value >> (8 * (counter - 1))) == 0) canonical = false;
        if (counter > 8) ok = false;
    }
    void text(QByteArray& t) {
        int n = 0;
        bs(n);
        if (n < 0 || quint64(n) * 8 > end_ - std::min(end_, position_)) { ok = false; t.clear(); return; }
        t.resize(n);
        for (int i = 0; i < n; ++i) t[i] = char(rc());
    }
    void raw(QByteArray& bytes, qsizetype count) {
        if (count < 0 || quint64(count) * 8 > end_ - std::min(end_, position_)) { ok = false; bytes.clear(); return; }
        bytes.resize(count);
        for (qsizetype i = 0; i < count; ++i) bytes[i] = char(rc());
    }
    void point3(std::array<double, 3>& p) { for (double& v : p) bd(v); }
    void point2(std::array<double, 2>& p) { for (double& v : p) bd(v); }
    void rawPoint2(std::array<double, 2>& p) { for (double& v : p) rd(v); }
    template <class T>
    bool countBL(std::vector<T>& list) {
        qint32 n = 0;
        bl(n);
        return resize(list, n);
    }
    template <class T>
    bool countBS(std::vector<T>& list) {
        int n = 0;
        bs(n);
        return resize(list, n);
    }
    template <class T>
    bool countRC(std::vector<T>& list) {
        quint8 n = 0;
        rc(n);
        return resize(list, n);
    }

    quint64 position() const { return position_; }
    void seek(quint64 p) { position_ = p; }
    quint64 end() const { return end_; }
    bool canonical = true;

private:
    template <class T>
    bool resize(std::vector<T>& list, qint64 n) {
        if (!ok || n < 0 || quint64(n) > kMaxCount || quint64(n) > end_ - std::min(end_, position_)) {
            ok = false;
            list.clear();
            return false;
        }
        list.resize(std::size_t(n));
        return true;
    }
    const QByteArray& data_;
    quint64 position_;
    quint64 end_;
};

// ---- header variables ----

template <class IO>
void ioHeader(IO& io, DwgR2000HeaderVariables& h) {
    io.bd(h.unk1); io.bd(h.unk2); io.bd(h.unk3); io.bd(h.unk4);
    io.text(h.unk5); io.text(h.unk6); io.text(h.unk7); io.text(h.unk8);
    io.bl(h.unk9); io.bl(h.unk10);
    io.handle(h.VIEWPORTENTHDR);
    io.bit(h.DIMASO); io.bit(h.DIMSHO); io.bit(h.PLINEGEN); io.bit(h.ORTHOMODE); io.bit(h.REGENMODE);
    io.bit(h.FILLMODE); io.bit(h.QTEXTMODE); io.bit(h.PSLTSCALE); io.bit(h.LIMCHECK); io.bit(h.USRTIMER);
    io.bit(h.SKPOLY); io.bit(h.ANGDIR); io.bit(h.SPLFRAME); io.bit(h.MIRRTEXT); io.bit(h.WORLDVIEW);
    io.bit(h.TILEMODE); io.bit(h.PLIMCHECK); io.bit(h.VISRETAIN); io.bit(h.DISPSILH); io.bit(h.PELLIPSE);
    io.bs(h.PROXYGRAPHICS); io.bs(h.TREEDEPTH); io.bs(h.LUNITS); io.bs(h.LUPREC); io.bs(h.AUNITS);
    io.bs(h.AUPREC); io.bs(h.ATTMODE); io.bs(h.PDMODE); io.bs(h.USERI1); io.bs(h.USERI2); io.bs(h.USERI3);
    io.bs(h.USERI4); io.bs(h.USERI5); io.bs(h.SPLINESEGS); io.bs(h.SURFU); io.bs(h.SURFV); io.bs(h.SURFTYPE);
    io.bs(h.SURFTAB1); io.bs(h.SURFTAB2); io.bs(h.SPLINETYPE); io.bs(h.SHADEDGE); io.bs(h.SHADEDIF);
    io.bs(h.UNITMODE); io.bs(h.MAXACTVP); io.bs(h.ISOLINES); io.bs(h.CMLJUST); io.bs(h.TEXTQLTY);
    io.bd(h.LTSCALE); io.bd(h.TEXTSIZE); io.bd(h.TRACEWID); io.bd(h.SKETCHINC); io.bd(h.FILLETRAD);
    io.bd(h.THICKNESS); io.bd(h.ANGBASE); io.bd(h.PDSIZE); io.bd(h.PLINEWID); io.bd(h.USERR1); io.bd(h.USERR2);
    io.bd(h.USERR3); io.bd(h.USERR4); io.bd(h.USERR5); io.bd(h.CHAMFERA); io.bd(h.CHAMFERB); io.bd(h.CHAMFERC);
    io.bd(h.CHAMFERD); io.bd(h.FACETRES); io.bd(h.CMLSCALE); io.bd(h.CELTSCALE);
    io.text(h.MENUNAME);
    io.bl(h.TDCREATED); io.bl(h.TDCREATEMS); io.bl(h.TDUPDATED); io.bl(h.TDUPDATEMS);
    io.bl(h.TDINDWGD); io.bl(h.TDINDWGMS); io.bl(h.TDUSRTIMERD); io.bl(h.TDUSRTIMERMS);
    io.bs(h.CECOLOR);
    io.handle(h.HANDSEED); io.handle(h.CLAYER); io.handle(h.TEXTSTYLE); io.handle(h.CELTYPE);
    io.handle(h.DIMSTYLE); io.handle(h.CMLSTYLE);
    io.bd(h.PSVPSCALE);
    io.point3(h.PINSBASE); io.point3(h.PEXTMIN); io.point3(h.PEXTMAX);
    io.rawPoint2(h.PLIMMIN); io.rawPoint2(h.PLIMMAX);
    io.bd(h.PELEVATION);
    io.point3(h.PUCSORG); io.point3(h.PUCSXDIR); io.point3(h.PUCSYDIR);
    io.handle(h.PUCSNAME); io.handle(h.PUCSORTHOREF); io.bs(h.PUCSORTHOVIEW); io.handle(h.PUCSBASE);
    io.point3(h.PORGTOP); io.point3(h.PORGBOTTOM); io.point3(h.PORGLEFT); io.point3(h.PORGRIGHT);
    io.point3(h.PORGFRONT); io.point3(h.PORGBACK);
    io.point3(h.MINSBASE); io.point3(h.MEXTMIN); io.point3(h.MEXTMAX);
    io.rawPoint2(h.MLIMMIN); io.rawPoint2(h.MLIMMAX);
    io.bd(h.MELEVATION);
    io.point3(h.MUCSORG); io.point3(h.MUCSXDIR); io.point3(h.MUCSYDIR);
    io.handle(h.MUCSNAME); io.handle(h.MUCSORTHOREF); io.bs(h.MUCSORTHOVIEW); io.handle(h.MUCSBASE);
    io.point3(h.MORGTOP); io.point3(h.MORGBOTTOM); io.point3(h.MORGLEFT); io.point3(h.MORGRIGHT);
    io.point3(h.MORGFRONT); io.point3(h.MORGBACK);
    io.text(h.DIMPOST); io.text(h.DIMAPOST);
    io.bd(h.DIMSCALE); io.bd(h.DIMASZ); io.bd(h.DIMEXO); io.bd(h.DIMDLI); io.bd(h.DIMEXE); io.bd(h.DIMRND);
    io.bd(h.DIMDLE); io.bd(h.DIMTP); io.bd(h.DIMTM);
    io.bit(h.DIMTOL); io.bit(h.DIMLIM); io.bit(h.DIMTIH); io.bit(h.DIMTOH); io.bit(h.DIMSE1); io.bit(h.DIMSE2);
    io.bs(h.DIMTAD); io.bs(h.DIMZIN); io.bs(h.DIMAZIN);
    io.bd(h.DIMTXT); io.bd(h.DIMCEN); io.bd(h.DIMTSZ); io.bd(h.DIMALTF); io.bd(h.DIMLFAC); io.bd(h.DIMTVP);
    io.bd(h.DIMTFAC); io.bd(h.DIMGAP); io.bd(h.DIMALTRND);
    io.bit(h.DIMALT); io.bs(h.DIMALTD);
    io.bit(h.DIMTOFL); io.bit(h.DIMSAH); io.bit(h.DIMTIX); io.bit(h.DIMSOXD);
    io.bs(h.DIMCLRD); io.bs(h.DIMCLRE); io.bs(h.DIMCLRT);
    io.bs(h.DIMADEC); io.bs(h.DIMDEC); io.bs(h.DIMTDEC); io.bs(h.DIMALTU); io.bs(h.DIMALTTD); io.bs(h.DIMAUNIT);
    io.bs(h.DIMFRAC); io.bs(h.DIMLUNIT); io.bs(h.DIMDSEP); io.bs(h.DIMTMOVE); io.bs(h.DIMJUST);
    io.bit(h.DIMSD1); io.bit(h.DIMSD2);
    io.bs(h.DIMTOLJ); io.bs(h.DIMTZIN); io.bs(h.DIMALTZ); io.bs(h.DIMALTTZ);
    io.bit(h.DIMUPT); io.bs(h.DIMATFIT);
    io.handle(h.DIMTXSTY); io.handle(h.DIMLDRBLK); io.handle(h.DIMBLK); io.handle(h.DIMBLK1); io.handle(h.DIMBLK2);
    io.bs(h.DIMLWD); io.bs(h.DIMLWE);
    io.handle(h.BLOCKCONTROL); io.handle(h.LAYERCONTROL); io.handle(h.STYLECONTROL); io.handle(h.LTYPECONTROL);
    io.handle(h.VIEWCONTROL); io.handle(h.UCSCONTROL); io.handle(h.VPORTCONTROL); io.handle(h.APPIDCONTROL);
    io.handle(h.DIMSTYLECONTROL); io.handle(h.VXCONTROL);
    io.handle(h.DICTGROUP); io.handle(h.DICTMLINESTYLE); io.handle(h.DICTNAMED);
    io.bs(h.TSTACKALIGN); io.bs(h.TSTACKSIZE);
    io.text(h.HYPERLINKBASE); io.text(h.STYLESHEET);
    io.handle(h.DICTLAYOUTS); io.handle(h.DICTPLOTSETTINGS); io.handle(h.DICTPLOTSTYLES);
    io.bl(h.FLAGS); io.bs(h.INSUNITS); io.bs(h.CEPSNTYPE);
    if (h.CEPSNTYPE == 3) io.handle(h.CPSNID);
    io.text(h.FINGERPRINTGUID); io.text(h.VERSIONGUID);
    io.handle(h.BRPAPER); io.handle(h.BRMODEL);
    io.handle(h.LTBYLAYER); io.handle(h.LTBYBLOCK); io.handle(h.LTCONTINUOUS);
    for (quint16& s : h.trailing) io.bsFull(s);
}

// ---- objects ----

template <class IO>
void ioEntry(IO& io, DwgTableEntry& e) {
    io.text(e.name);
    io.bit(e.flag64);
    io.bs(e.xrefIndexPlusOne);
    io.bit(e.xrefDependent);
}

template <class IO>
void ioWire(IO& io, DwgWire& w) {
    io.rc(w.type);
    io.bl(w.selectionMarker);
    io.bs(w.color);
    io.bl(w.acisIndex);
    if (!io.countBL(w.points)) return;
    for (auto& p : w.points) io.point3(p);
    io.bit(w.transformPresent);
    if (w.transformPresent) {
        for (double& v : w.transform) io.bd(v);
        io.bd(w.scale);
        io.bit(w.rotation);
        io.bit(w.reflection);
        io.bit(w.shear);
    }
}

char satCipher(char c) {
    const uchar u = uchar(c);
    return char(u <= 32 ? u : (159 - u) & 0xFF);
}

template <class IO>
void ioSolid(IO& io, DwgSolidData& s) {
    io.bit(s.empty);
    io.bit(s.unknownBit);
    if (!s.empty) {
        io.bs(s.version);
        if (s.version != 1) { io.ok = false; return; }
        if constexpr (IO::reading) {
            s.sat.clear();
            s.blockSizes.clear();
            while (io.ok) {
                qint32 size = 0;
                io.bl(size);
                if (size == 0) break;
                if (size < 0 || s.blockSizes.size() > kMaxCount) { io.ok = false; return; }
                QByteArray block;
                io.raw(block, size);
                for (char& c : block) c = satCipher(c);
                s.sat += block;
                s.blockSizes.push_back(size);
            }
        } else {
            std::vector<qint32> sizes = s.blockSizes;
            if (sizes.empty())
                for (qsizetype at = 0; at < s.sat.size(); at += 4096) sizes.push_back(qint32(std::min<qsizetype>(4096, s.sat.size() - at)));
            qsizetype at = 0;
            for (qint32 size : sizes) {
                if (size <= 0 || at + size > s.sat.size()) { io.ok = false; return; }
                io.bl(size);
                for (qsizetype i = 0; i < size; ++i) io.rc(quint8(satCipher(s.sat[at + i])));
                at += size;
            }
            if (at != s.sat.size()) { io.ok = false; return; }
            io.bl(qint32(0));
        }
    }
    io.bit(s.wireframe);
    if (s.wireframe) {
        io.bit(s.pointPresent);
        if (s.pointPresent) io.point3(s.point);
        io.bl(s.isolines);
        io.bit(s.isolinesPresent);
        if (s.isolinesPresent) {
            if (!io.countBL(s.wires)) return;
            for (auto& w : s.wires) ioWire(io, w);
            if (!io.countBL(s.silhouettes)) return;
            for (auto& sil : s.silhouettes) {
                io.bl(sil.viewportId);
                io.point3(sil.target);
                io.point3(sil.direction);
                io.point3(sil.up);
                io.bit(sil.perspective);
                if (!io.countBL(sil.wires)) return;
                for (auto& w : sil.wires) ioWire(io, w);
            }
        }
    }
    io.bit(s.acisEmpty2);
    if (!s.acisEmpty2) io.ok = false; // a second body: not seen in R2000 3DSOLIDs of the samples
}

int extraControlHandles(DwgObjectKind kind) {
    return kind == DwgObjectKind::BlockControl || kind == DwgObjectKind::LinetypeControl ? 2 : 0;
}

bool isControl(DwgObjectKind k) {
    return k == DwgObjectKind::BlockControl || k == DwgObjectKind::LayerControl || k == DwgObjectKind::StyleControl ||
           k == DwgObjectKind::LinetypeControl || k == DwgObjectKind::ViewControl || k == DwgObjectKind::UcsControl ||
           k == DwgObjectKind::ViewportControl || k == DwgObjectKind::AppIdControl || k == DwgObjectKind::DimStyleControl ||
           k == DwgObjectKind::ViewportEntityControl;
}
bool isEntityKind(DwgObjectKind k) {
    return k == DwgObjectKind::Block || k == DwgObjectKind::EndBlock || k == DwgObjectKind::Region ||
           k == DwgObjectKind::Solid3d || k == DwgObjectKind::Body;
}

// The data (before the handles) of each kind.
template <class IO>
void ioData(IO& io, DwgObjectKind kind, DwgObjectData& data) {
    if (isControl(kind)) {
        auto& c = std::get<DwgControlData>(data);
        io.bl(c.entries);
        if (kind == DwgObjectKind::DimStyleControl) io.countRC(c.more);
        return;
    }
    switch (kind) {
    case DwgObjectKind::BlockHeader: {
        auto& b = std::get<DwgBlockHeaderData>(data);
        ioEntry(io, b.entry);
        io.bit(b.anonymous); io.bit(b.hasAttributes); io.bit(b.xref); io.bit(b.overlaid); io.bit(b.loaded);
        io.point3(b.base);
        io.text(b.xrefPath);
        if constexpr (IO::reading) {
            b.insertRun.clear();
            while (io.ok) {
                quint8 c = 0;
                io.rc(c);
                if (c == 0) break;
                if (b.insertRun.size() > kMaxCount) { io.ok = false; break; }
                b.insertRun.push_back(c);
            }
        } else {
            for (quint8 c : b.insertRun) { if (c == 0) io.ok = false; io.rc(c); }
            io.rc(quint8(0));
        }
        io.text(b.description);
        qint32 size = qint32(b.preview.size());
        io.bl(size);
        io.raw(b.preview, size);
        break;
    }
    case DwgObjectKind::Layer: {
        auto& l = std::get<DwgLayerData>(data);
        ioEntry(io, l.entry);
        io.bs(l.values);
        io.bs(l.color);
        break;
    }
    case DwgObjectKind::TextStyle: {
        auto& s = std::get<DwgTextStyleData>(data);
        ioEntry(io, s.entry);
        io.bit(s.vertical); io.bit(s.shapeFile);
        io.bd(s.height); io.bd(s.width); io.bd(s.oblique);
        io.rc(s.generation);
        io.bd(s.lastHeight);
        io.text(s.font); io.text(s.bigFont);
        break;
    }
    case DwgObjectKind::Linetype: {
        auto& l = std::get<DwgLinetypeData>(data);
        ioEntry(io, l.entry);
        io.text(l.description);
        io.bd(l.patternLength);
        io.rc(l.alignment);
        if (!io.countRC(l.dashes)) return;
        for (auto& d : l.dashes) {
            io.bd(d.length); io.bs(d.shapeCode); io.rd(d.xOffset); io.rd(d.yOffset);
            io.bd(d.scale); io.bd(d.rotation); io.bs(d.shapeFlag);
        }
        io.raw(l.strings, 256);
        break;
    }
    case DwgObjectKind::AppId: {
        auto& a = std::get<DwgAppIdData>(data);
        ioEntry(io, a.entry);
        io.rc(a.unknown);
        break;
    }
    case DwgObjectKind::Viewport: {
        auto& v = std::get<DwgViewportData>(data);
        ioEntry(io, v.entry);
        io.bd(v.height); io.bd(v.aspect);
        io.rawPoint2(v.center);
        io.point3(v.target); io.point3(v.direction);
        io.bd(v.twist); io.bd(v.lens); io.bd(v.front); io.bd(v.back);
        for (bool& m : v.viewMode) io.bit(m);
        io.rc(v.renderMode);
        io.rawPoint2(v.lowerLeft); io.rawPoint2(v.upperRight);
        io.bit(v.ucsFollow);
        io.bs(v.circleZoom);
        io.bit(v.fastZoom);
        for (bool& i : v.ucsIcon) io.bit(i);
        io.bit(v.grid);
        io.rawPoint2(v.gridSpacing);
        io.bit(v.snap); io.bit(v.snapStyle);
        io.bs(v.isoPair);
        io.bd(v.snapRotation);
        io.rawPoint2(v.snapBase); io.rawPoint2(v.snapSpacing);
        io.bit(v.unknown); io.bit(v.ucsPerViewport);
        io.point3(v.ucsOrigin); io.point3(v.ucsX); io.point3(v.ucsY);
        io.bd(v.ucsElevation);
        io.bs(v.ucsOrthographic);
        break;
    }
    case DwgObjectKind::DimStyle: {
        auto& d = std::get<DwgDimStyleData>(data);
        ioEntry(io, d.entry);
        io.text(d.DIMPOST); io.text(d.DIMAPOST);
        for (double& r : d.real1) io.bd(r);
        for (bool& b : d.flags1) io.bit(b);
        for (int& s : d.short1) io.bs(s);
        for (double& r : d.real2) io.bd(r);
        io.bit(d.DIMALT); io.bs(d.DIMALTD);
        for (bool& b : d.flags2) io.bit(b);
        for (int& s : d.short2) io.bs(s);
        io.bit(d.DIMSD1); io.bit(d.DIMSD2);
        for (int& s : d.short3) io.bs(s);
        io.bit(d.DIMUPT); io.bs(d.DIMFIT); io.bs(d.DIMLWD); io.bs(d.DIMLWE);
        io.bit(d.unknown);
        break;
    }
    case DwgObjectKind::Dictionary:
    case DwgObjectKind::DictionaryWithDefault: {
        auto& d = std::get<DwgDictionaryData>(data);
        if (!io.countBL(d.names)) return;
        io.bs(d.cloning);
        io.rc(d.hardOwner);
        for (auto& n : d.names) io.text(n);
        break;
    }
    case DwgObjectKind::Placeholder:
    case DwgObjectKind::EndBlock:
        break;
    case DwgObjectKind::MlineStyle: {
        auto& m = std::get<DwgMlineStyleData>(data);
        io.text(m.name); io.text(m.description);
        io.bs(m.flags); io.bs(m.fillColor);
        io.bd(m.startAngle); io.bd(m.endAngle);
        if (!io.countRC(m.lines)) return;
        for (auto& l : m.lines) { io.bd(l.offset); io.bs(l.color); io.bs(l.linetypeIndex); }
        break;
    }
    case DwgObjectKind::Layout: {
        auto& l = std::get<DwgLayoutData>(data);
        io.text(l.pageSetup); io.text(l.printer);
        io.bs(l.plotFlags);
        for (double& m : l.margins) io.bd(m);
        io.bd(l.paperWidth); io.bd(l.paperHeight);
        io.text(l.paperSize);
        io.point2(l.plotOrigin);
        io.bs(l.paperUnits); io.bs(l.rotation); io.bs(l.plotType);
        io.point2(l.windowMin); io.point2(l.windowMax);
        io.text(l.plotView);
        io.bd(l.realUnits); io.bd(l.drawingUnits);
        io.text(l.styleSheet);
        io.bs(l.scaleType); io.bd(l.scaleFactor);
        io.point2(l.imageOrigin);
        io.text(l.layoutName);
        io.bl(l.tabOrder);
        io.bs(l.flag);
        io.point3(l.ucsOrigin);
        io.rawPoint2(l.limitsMin); io.rawPoint2(l.limitsMax);
        io.point3(l.insertionBase); io.point3(l.ucsX); io.point3(l.ucsY);
        io.bd(l.elevation);
        io.bs(l.orthographicView);
        io.point3(l.extentsMin); io.point3(l.extentsMax);
        break;
    }
    case DwgObjectKind::Block:
        io.text(std::get<DwgBlockData>(data).name);
        break;
    case DwgObjectKind::Region:
    case DwgObjectKind::Solid3d:
    case DwgObjectKind::Body:
        ioSolid(io, std::get<DwgSolidData>(data));
        break;
    default:
        io.ok = false;
    }
}

// The handles of each kind after the common ones.
template <class IO>
void ioHandles(IO& io, DwgObjectKind kind, DwgObjectData& data) {
    if (isControl(kind)) {
        auto& c = std::get<DwgControlData>(data);
        if constexpr (IO::reading) {
            const qint64 count = qint64(c.entries) + extraControlHandles(kind);
            if (count < 0 || quint64(count) > kMaxCount) { io.ok = false; return; }
            c.handles.resize(std::size_t(count));
        } else if (qint64(c.handles.size()) != qint64(c.entries) + extraControlHandles(kind)) {
            io.ok = false;
            return;
        }
        for (auto& h : c.handles) io.handle(h);
        for (auto& h : c.more) io.handle(h);
        return;
    }
    switch (kind) {
    case DwgObjectKind::BlockHeader: {
        auto& b = std::get<DwgBlockHeaderData>(data);
        io.handle(b.entry.xrefBlock);
        io.handle(b.block);
        if (!b.xref && !b.overlaid) { io.handle(b.first); io.handle(b.last); }
        io.handle(b.endBlock);
        if constexpr (IO::reading) b.inserts.resize(b.insertRun.size());
        else if (b.inserts.size() != b.insertRun.size()) { io.ok = false; return; }
        for (auto& h : b.inserts) io.handle(h);
        io.handle(b.layout);
        break;
    }
    case DwgObjectKind::Layer: {
        auto& l = std::get<DwgLayerData>(data);
        io.handle(l.entry.xrefBlock); io.handle(l.plotStyle); io.handle(l.linetype);
        break;
    }
    case DwgObjectKind::TextStyle: io.handle(std::get<DwgTextStyleData>(data).entry.xrefBlock); break;
    case DwgObjectKind::AppId: io.handle(std::get<DwgAppIdData>(data).entry.xrefBlock); break;
    case DwgObjectKind::Linetype: {
        auto& l = std::get<DwgLinetypeData>(data);
        io.handle(l.entry.xrefBlock);
        for (auto& d : l.dashes) io.handle(d.shapeFile);
        break;
    }
    case DwgObjectKind::Viewport: {
        auto& v = std::get<DwgViewportData>(data);
        io.handle(v.entry.xrefBlock); io.handle(v.namedUcs); io.handle(v.baseUcs);
        break;
    }
    case DwgObjectKind::DimStyle: {
        auto& d = std::get<DwgDimStyleData>(data);
        io.handle(d.entry.xrefBlock);
        io.handle(d.DIMTXSTY); io.handle(d.DIMLDRBLK); io.handle(d.DIMBLK); io.handle(d.DIMBLK1); io.handle(d.DIMBLK2);
        break;
    }
    case DwgObjectKind::Dictionary:
    case DwgObjectKind::DictionaryWithDefault: {
        auto& d = std::get<DwgDictionaryData>(data);
        if constexpr (IO::reading) d.items.resize(d.names.size());
        else if (d.items.size() != d.names.size()) { io.ok = false; return; }
        for (auto& h : d.items) io.handle(h);
        if (kind == DwgObjectKind::DictionaryWithDefault) {
            if constexpr (IO::reading) d.defaultEntry.emplace();
            else if (!d.defaultEntry) { io.ok = false; return; }
            io.handle(*d.defaultEntry);
        }
        break;
    }
    case DwgObjectKind::Layout: {
        auto& l = std::get<DwgLayoutData>(data);
        io.handle(l.block); io.handle(l.lastViewport); io.handle(l.baseUcs); io.handle(l.namedUcs);
        break;
    }
    default:
        break;
    }
}

template <class IO>
void ioEed(IO& io, std::vector<DwgEedItem>& eed) {
    if constexpr (IO::reading) {
        eed.clear();
        while (io.ok) {
            int size = 0;
            io.bs(size);
            if (size == 0) break;
            if (size < 0 || eed.size() > kMaxCount) { io.ok = false; return; }
            DwgEedItem item;
            io.handle(item.application);
            io.raw(item.data, size);
            eed.push_back(std::move(item));
        }
    } else {
        for (const auto& item : eed) {
            if (item.data.isEmpty() || item.data.size() > 32767) { io.ok = false; return; }
            io.bs(int(item.data.size()));
            io.handle(item.application);
            io.raw(item.data, item.data.size());
        }
        io.bs(0);
    }
}

template <class IO>
void ioCommon(IO& io, DwgObjectFrame& f) {
    if (f.entity) {
        io.bit(f.graphicPresent);
        if (f.graphicPresent) {
            quint32 size = quint32(f.graphic.size());
            io.rl(size);
            io.raw(f.graphic, qsizetype(size));
        }
        io.bb(f.entityMode);
        qint32 reactors = qint32(f.reactors.size());
        io.bl(reactors);
        if constexpr (IO::reading) {
            if (reactors < 0 || quint64(reactors) > kMaxCount) { io.ok = false; return; }
            f.reactors.resize(std::size_t(reactors));
        }
        io.bit(f.noLinks);
        io.bs(f.color);
        io.bd(f.linetypeScale);
        io.bb(f.linetypeFlags);
        io.bb(f.plotStyleFlags);
        io.bs(f.invisibility);
        quint8 lw = quint8(f.lineweight);
        io.rc(lw);
        f.lineweight = lw;
    } else {
        qint32 reactors = qint32(f.reactors.size());
        io.bl(reactors);
        if constexpr (IO::reading) {
            if (reactors < 0 || quint64(reactors) > kMaxCount) { io.ok = false; return; }
            f.reactors.resize(std::size_t(reactors));
        }
    }
}

template <class IO>
void ioCommonHandles(IO& io, DwgObjectFrame& f) {
    if (!f.entity || f.entityMode == 0) io.handle(f.owner);
    for (auto& r : f.reactors) io.handle(r);
    io.handle(f.xdictionary);
    if (f.entity) {
        if (!f.noLinks) { io.handle(f.previous); io.handle(f.next); }
        io.handle(f.layer);
        if (f.linetypeFlags == 3) io.handle(f.linetype);
        if (f.plotStyleFlags == 3) io.handle(f.plotStyle);
    }
}

DwgObjectData emptyData(DwgObjectKind kind) {
    if (isControl(kind)) return DwgControlData{};
    switch (kind) {
    case DwgObjectKind::BlockHeader: return DwgBlockHeaderData{};
    case DwgObjectKind::Layer: return DwgLayerData{};
    case DwgObjectKind::TextStyle: return DwgTextStyleData{};
    case DwgObjectKind::Linetype: return DwgLinetypeData{};
    case DwgObjectKind::AppId: return DwgAppIdData{};
    case DwgObjectKind::Viewport: return DwgViewportData{};
    case DwgObjectKind::DimStyle: return DwgDimStyleData{};
    case DwgObjectKind::Dictionary:
    case DwgObjectKind::DictionaryWithDefault: return DwgDictionaryData{};
    case DwgObjectKind::Placeholder: return DwgPlaceholderData{};
    case DwgObjectKind::MlineStyle: return DwgMlineStyleData{};
    case DwgObjectKind::Layout: return DwgLayoutData{};
    case DwgObjectKind::Block: return DwgBlockData{};
    case DwgObjectKind::EndBlock: return DwgEndBlockData{};
    default: return DwgSolidData{};
    }
}

// Modular short / char helpers (byte aligned).
bool readModularShort(const QByteArray& file, qint64& at, quint32& value, quint32& words) {
    value = 0;
    words = 0;
    for (int shift = 0; shift < 30; shift += 15) {
        if (at + 2 > file.size()) return false;
        const quint16 w = le16(file, at);
        at += 2;
        ++words;
        value |= quint32(w & 0x7FFF) << shift;
        if (!(w & 0x8000)) return true;
    }
    return false;
}
QByteArray modularShort(quint32 value) {
    QByteArray out;
    do {
        quint16 w = quint16(value & 0x7FFF);
        value >>= 15;
        if (value) w |= 0x8000;
        put16(out, w);
    } while (value);
    return out;
}

} // namespace

quint16 dwgCrc16(quint16 seed, const char* data, qsizetype size) {
    static const std::array<quint16, 256> table = [] {
        std::array<quint16, 256> t{};
        for (unsigned i = 0; i < 256; ++i) {
            unsigned c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? (c >> 1) ^ 0xA001 : c >> 1;
            t[i] = quint16(c);
        }
        return t;
    }();
    quint16 dx = seed;
    for (qsizetype i = 0; i < size; ++i) {
        const quint8 al = quint8(uchar(data[i]) ^ (dx & 0xFF));
        dx = quint16((dx >> 8) ^ table[al]);
    }
    return dx;
}

// ---- file header ----

QByteArray encodeDwgR2000FileHeader(const DwgR2000FileHeader& h) {
    QByteArray out("AC1015");
    out.append(QByteArray(5, '\0'));
    out.append(char(h.maintenance));
    out.append(char(h.byte0C));
    put32(out, h.imageSeeker);
    out.append(char(h.applicationVersion));
    out.append(char(h.applicationMaintenance));
    put16(out, h.codepage);
    put32(out, quint32(h.locators.size()));
    for (const auto& l : h.locators) {
        out.append(char(l.number));
        put32(out, l.seeker);
        put32(out, l.size);
    }
    static const std::map<std::size_t, quint16> xorValue{{3, 0xA598}, {4, 0x8101}, {5, 0x3CC4}, {6, 0x8461}};
    const auto x = xorValue.find(h.locators.size());
    put16(out, quint16(dwgCrc16(0, out.constData(), out.size()) ^ (x == xorValue.end() ? 0 : x->second)));
    out.append(sentinel(kFileSentinel));
    return out;
}

bool decodeDwgR2000FileHeader(const QByteArray& file, DwgR2000FileHeader& h, QString& error) {
    h = {};
    if (file.size() < 25 || !file.startsWith("AC1015")) {
        error = QObject::tr("Это не файл DWG 2000 (AC1015).");
        return false;
    }
    const quint32 count = le32(file, 21);
    if (count < 3 || count > 6 || 25 + 9 * qint64(count) + 18 > file.size()) {
        error = QObject::tr("Заголовок DWG 2000 повреждён: число указателей разделов %1.").arg(count);
        return false;
    }
    if (file.mid(6, 5) != QByteArray(5, '\0')) { error = QObject::tr("Заголовок DWG 2000: не нули после версии."); return false; }
    h.maintenance = quint8(file[11]);
    h.byte0C = quint8(file[12]);
    h.imageSeeker = le32(file, 13);
    h.applicationVersion = quint8(file[17]);
    h.applicationMaintenance = quint8(file[18]);
    h.codepage = le16(file, 19);
    for (quint32 i = 0; i < count; ++i) {
        const qint64 at = 25 + 9 * qint64(i);
        h.locators.push_back({quint8(file[at]), le32(file, at + 1), le32(file, at + 5)});
    }
    const QByteArray again = encodeDwgR2000FileHeader(h);
    if (file.left(again.size()) != again) {
        h = {};
        error = QObject::tr("Заголовок DWG 2000: контрольная сумма или метка не сходятся.");
        return false;
    }
    return true;
}

// ---- header variables ----

QByteArray encodeDwgR2000HeaderVariables(const DwgR2000HeaderVariables& variables) {
    BitWriter w;
    ioHeader(w, const_cast<DwgR2000HeaderVariables&>(variables));
    const QByteArray data = w.bytes();
    QByteArray out = sentinel(kHeaderSentinel);
    QByteArray body;
    put32(body, quint32(data.size()));
    body += data;
    out += body;
    put16(out, dwgCrc16(0xC0C1, body.constData(), body.size()));
    out += sentinel(kHeaderEnd);
    return out;
}

bool decodeDwgR2000HeaderVariables(const QByteArray& file, quint32 seeker, DwgR2000HeaderVariables& variables,
                                   QString& error) {
    variables = {};
    if (!hasSentinel(file, seeker, kHeaderSentinel) || qint64(seeker) + 20 > file.size()) {
        error = QObject::tr("Переменные заголовка DWG: нет начальной метки.");
        return false;
    }
    const quint32 size = le32(file, seeker + 16);
    const qint64 end = qint64(seeker) + 20 + size;
    if (end + 18 > file.size() || !hasSentinel(file, end + 2, kHeaderEnd) ||
        dwgCrc16(0xC0C1, file.constData() + seeker + 16, 4 + size) != le16(file, end)) {
        error = QObject::tr("Переменные заголовка DWG: размер, контрольная сумма или конечная метка не сходятся.");
        return false;
    }
    BitReader r(file, (quint64(seeker) + 20) * 8, quint64(end) * 8);
    ioHeader(r, variables);
    if (!r.ok || r.end() - r.position() >= 8) {
        variables = {};
        error = QObject::tr("Переменные заголовка DWG не заканчиваются там, где говорит размер раздела.");
        return false;
    }
    return true;
}

// ---- classes ----

QByteArray encodeDwgR2000Classes(const std::vector<DwgClassRecord>& classes) {
    BitWriter w;
    for (const auto& c : classes) {
        w.bs(c.number); w.bs(c.version);
        w.text(c.application); w.text(c.cplusplus); w.text(c.dxfName);
        w.bit(c.zombie);
        w.bs(c.itemClassId);
    }
    const QByteArray data = w.bytes();
    QByteArray body;
    put32(body, quint32(data.size()));
    body += data;
    QByteArray out = sentinel(kClassesSentinel) + body;
    put16(out, dwgCrc16(0xC0C1, body.constData(), body.size()));
    out += sentinel(kClassesEnd);
    return out;
}

bool decodeDwgR2000Classes(const QByteArray& file, quint32 seeker, std::vector<DwgClassRecord>& classes,
                           QString& error, int* paddingBits) {
    classes.clear();
    if (!hasSentinel(file, seeker, kClassesSentinel) || qint64(seeker) + 20 > file.size()) {
        error = QObject::tr("Классы DWG: нет начальной метки.");
        return false;
    }
    const quint32 size = le32(file, seeker + 16);
    const qint64 end = qint64(seeker) + 20 + size;
    if (end + 18 > file.size() || !hasSentinel(file, end + 2, kClassesEnd) ||
        dwgCrc16(0xC0C1, file.constData() + seeker + 16, 4 + size) != le16(file, end)) {
        error = QObject::tr("Классы DWG: размер, контрольная сумма или конечная метка не сходятся.");
        return false;
    }
    BitReader r(file, (quint64(seeker) + 20) * 8, quint64(end) * 8);
    while (r.ok && r.end() - r.position() >= 8 * 8) {
        const quint64 at = r.position();
        DwgClassRecord c;
        r.bs(c.number); r.bs(c.version);
        r.text(c.application); r.text(c.cplusplus); r.text(c.dxfName);
        r.bit(c.zombie);
        r.bs(c.itemClassId);
        if (!r.ok) { r.seek(at); r.ok = true; break; }
        classes.push_back(std::move(c));
    }
    if (r.end() - r.position() >= 8) {
        classes.clear();
        error = QObject::tr("Классы DWG не заканчиваются там, где говорит размер раздела.");
        return false;
    }
    if (paddingBits) *paddingBits = int(r.end() - r.position());
    return true;
}

// ---- object map ----

QByteArray encodeDwgR2000ObjectMap(const std::vector<std::pair<quint64, quint32>>& offsets) {
    QByteArray out, run;
    quint64 lastHandle = 0;
    qint64 lastOffset = 0;
    const auto flush = [&] {
        QByteArray body;
        body.append(char((run.size() + 2) >> 8));
        body.append(char((run.size() + 2) & 0xFF));
        body += run;
        out += body;
        const quint16 crc = dwgCrc16(0xC0C1, body.constData(), body.size());
        out.append(char(crc >> 8));
        out.append(char(crc & 0xFF));
        run.clear();
    };
    for (const auto& [handle, offset] : offsets) {
        quint64 dh = handle - lastHandle;
        do {
            const quint8 c = quint8(dh & 0x7F);
            dh >>= 7;
            run.append(char(dh ? c | 0x80 : c));
        } while (dh);
        qint64 dl = qint64(offset) - lastOffset;
        const bool negative = dl < 0;
        quint64 magnitude = quint64(negative ? -dl : dl);
        while (magnitude >= 0x40) {
            run.append(char((magnitude & 0x7F) | 0x80));
            magnitude >>= 7;
        }
        run.append(char(magnitude | (negative ? 0x40 : 0)));
        lastHandle = handle;
        lastOffset = offset;
        if (run.size() + 2 >= 2032) {
            flush();
            lastHandle = 0;
            lastOffset = 0;
        }
    }
    if (!run.isEmpty()) flush();
    flush(); // the empty run
    return out;
}

bool decodeDwgR2000ObjectMap(const QByteArray& file, quint32 seeker, quint32 size,
                             std::vector<std::pair<quint64, quint32>>& offsets, QString& error) {
    offsets.clear();
    qint64 at = seeker;
    const qint64 end = qint64(seeker) + size;
    if (end > file.size()) { error = QObject::tr("Карта объектов DWG выходит за файл."); return false; }
    while (true) {
        if (at + 4 > end) { offsets.clear(); error = QObject::tr("Карта объектов DWG оборвана."); return false; }
        const int runSize = (uchar(file[at]) << 8) | uchar(file[at + 1]);
        if (runSize < 2 || at + runSize + 2 > end) { offsets.clear(); error = QObject::tr("Карта объектов DWG: неверный размер участка."); return false; }
        const quint16 crc = quint16((uchar(file[at + runSize]) << 8) | uchar(file[at + runSize + 1]));
        if (dwgCrc16(0xC0C1, file.constData() + at, runSize) != crc) {
            offsets.clear();
            error = QObject::tr("Карта объектов DWG: контрольная сумма участка не сходится.");
            return false;
        }
        if (runSize == 2) { at += 4; break; }
        qint64 p = at + 2;
        quint64 handle = 0;
        qint64 offset = 0;
        while (p < at + runSize) {
            quint64 dh = 0;
            for (int shift = 0;; shift += 7) {
                if (p >= at + runSize || shift > 56) { offsets.clear(); error = QObject::tr("Карта объектов DWG повреждена."); return false; }
                const uchar c = uchar(file[p++]);
                dh |= quint64(c & 0x7F) << shift;
                if (!(c & 0x80)) break;
            }
            qint64 dl = 0;
            for (int shift = 0;; shift += 7) {
                if (p >= at + runSize || shift > 56) { offsets.clear(); error = QObject::tr("Карта объектов DWG повреждена."); return false; }
                const uchar c = uchar(file[p++]);
                if (c & 0x80) { dl |= qint64(c & 0x7F) << shift; continue; }
                dl |= qint64(c & 0x3F) << shift;
                if (c & 0x40) dl = -dl;
                break;
            }
            handle += dh;
            offset += dl;
            if (offset < 0 || offset > std::numeric_limits<quint32>::max()) { offsets.clear(); error = QObject::tr("Карта объектов DWG повреждена."); return false; }
            offsets.push_back({handle, quint32(offset)});
        }
        at += runSize + 2;
    }
    if (at != end) { offsets.clear(); error = QObject::tr("Карта объектов DWG не заканчивается там, где говорит её размер."); return false; }
    return true;
}

// ---- auxiliary header, free space, template, second header ----

QByteArray encodeDwgR2000AuxHeader(const DwgR2000AuxHeader& h) {
    QByteArray out = QByteArray::fromHex("ff7701");
    put16(out, h.version); put16(out, h.maintenance);
    put32(out, h.saves); put32(out, quint32(h.unknown));
    put16(out, h.savesPart1); put16(out, h.savesPart2);
    put32(out, 0);
    for (quint16 v : h.versions) put16(out, v);
    for (quint16 v : h.constants) put16(out, v);
    for (quint16 v : h.constants2) put16(out, v);
    for (int i = 0; i < 5; ++i) put32(out, 0);
    for (quint32 v : h.created) put32(out, v);
    for (quint32 v : h.updated) put32(out, v);
    put32(out, h.handseed);
    put32(out, h.educational);
    put16(out, 0);
    put16(out, h.savesDifference);
    for (int i = 0; i < 3; ++i) put32(out, 0);
    put32(out, h.savesAgain);
    for (int i = 0; i < 4; ++i) put32(out, 0);
    return out;
}

bool decodeDwgR2000AuxHeader(const QByteArray& file, quint32 seeker, DwgR2000AuxHeader& h, QString& error) {
    h = {};
    if (qint64(seeker) + 123 > file.size() || file.mid(seeker, 3) != QByteArray::fromHex("ff7701")) {
        error = QObject::tr("Вспомогательный заголовок DWG не найден.");
        return false;
    }
    qint64 at = seeker + 3;
    const auto r16 = [&] { const quint16 v = le16(file, at); at += 2; return v; };
    const auto r32 = [&] { const quint32 v = le32(file, at); at += 4; return v; };
    h.version = r16(); h.maintenance = r16();
    h.saves = r32(); h.unknown = qint32(r32());
    h.savesPart1 = r16(); h.savesPart2 = r16();
    r32();
    for (quint16& v : h.versions) v = r16();
    for (quint16& v : h.constants) v = r16();
    for (quint16& v : h.constants2) v = r16();
    for (int i = 0; i < 5; ++i) r32();
    for (quint32& v : h.created) v = r32();
    for (quint32& v : h.updated) v = r32();
    h.handseed = r32(); h.educational = r32();
    r16();
    h.savesDifference = r16();
    for (int i = 0; i < 3; ++i) r32();
    h.savesAgain = r32();
    if (encodeDwgR2000AuxHeader(h) != file.mid(seeker, 123)) {
        h = {};
        error = QObject::tr("Вспомогательный заголовок DWG: поля, которые должны быть нулями, не нули.");
        return false;
    }
    return true;
}

QByteArray encodeDwgR2000FreeSpace(const DwgR2000FreeSpace& f) {
    QByteArray out;
    put32(out, 0);
    put32(out, f.handles);
    for (quint32 v : f.updated) put32(out, v);
    put32(out, f.objectsOffset);
    out.append(char(4));
    for (quint32 v : {0x32u, 0u, 0x64u, 0u, 0x200u, 0u, 0xFFFFFFFFu, 0u}) put32(out, v);
    return out;
}

bool decodeDwgR2000FreeSpace(const QByteArray& file, quint32 seeker, DwgR2000FreeSpace& f, QString& error) {
    f = {};
    if (qint64(seeker) + 53 > file.size()) { error = QObject::tr("Таблица свободного места DWG выходит за файл."); return false; }
    f.handles = le32(file, seeker + 4);
    f.updated = {le32(file, seeker + 8), le32(file, seeker + 12)};
    f.objectsOffset = le32(file, seeker + 16);
    if (encodeDwgR2000FreeSpace(f) != file.mid(seeker, 53)) {
        f = {};
        error = QObject::tr("Таблица свободного места DWG отличается от известной разметки.");
        return false;
    }
    return true;
}

QByteArray encodeDwgR2000Template(quint16 measurement) {
    QByteArray out;
    put16(out, 0);
    put16(out, measurement);
    return out;
}

namespace {
template <class IO>
void ioSecond(IO& io, DwgR2000SecondHeader& h) {
    qint32 location = qint32(h.location);
    io.bl(location);
    h.location = quint32(location);
    QByteArray version("AC1015");
    io.raw(version, 6);
    if (IO::reading && version != "AC1015") io.ok = false;
    QByteArray zeros(5, '\0');
    io.raw(zeros, 5);
    if (IO::reading && zeros != QByteArray(5, '\0')) io.ok = false;
    io.rc(h.maintenance);
    quint8 one = 1;
    io.rc(one);
    if (IO::reading && one != 1) io.ok = false;
    if constexpr (IO::reading) h.unknown12 = quint16(io.bits(12));
    else io.bits(h.unknown12, 12);
    for (quint8& m : h.magic) io.rc(m);
    for (auto& l : h.locators) {
        io.rc(l.number);
        qint32 seeker = qint32(l.seeker), size = qint32(l.size);
        io.bl(seeker);
        io.bl(size);
        l.seeker = quint32(seeker);
        l.size = quint32(size);
    }
    if (!io.countBS(h.handles)) return;
    for (auto& [index, bytes] : h.handles) {
        quint8 n = quint8(bytes.size());
        io.rc(n);
        io.rc(index);
        io.raw(bytes, n);
    }
}
} // namespace

QByteArray encodeDwgR2000SecondHeader(const DwgR2000SecondHeader& header) {
    BitWriter w;
    ioSecond(w, const_cast<DwgR2000SecondHeader&>(header));
    const QByteArray data = w.bytes();
    QByteArray body;
    put32(body, quint32(4 + data.size() + 2 + 8));
    body += data;
    QByteArray out = sentinel(kSecondSentinel) + body;
    put16(out, dwgCrc16(0xC0C1, body.constData(), body.size()));
    out += QByteArray(8, '\0');
    out += sentinel(kSecondEnd);
    return out;
}

bool decodeDwgR2000SecondHeader(const QByteArray& file, quint32 location, DwgR2000SecondHeader& header,
                                QString& error) {
    header = {};
    if (!hasSentinel(file, location, kSecondSentinel) || qint64(location) + 20 > file.size()) {
        error = QObject::tr("Второй заголовок DWG: нет начальной метки.");
        return false;
    }
    const quint32 size = le32(file, location + 16);
    const qint64 endSentinel = qint64(location) + 16 + size;
    if (size < 4 + 10 || endSentinel + 16 > file.size() || !hasSentinel(file, endSentinel, kSecondEnd)) {
        error = QObject::tr("Второй заголовок DWG: размер или конечная метка не сходятся.");
        return false;
    }
    const qint64 crcAt = endSentinel - 10;
    BitReader r(file, (quint64(location) + 20) * 8, quint64(crcAt) * 8);
    ioSecond(r, header);
    if (!r.ok || r.end() - r.position() >= 8 ||
        dwgCrc16(0xC0C1, file.constData() + location + 16, crcAt - location - 16) != le16(file, crcAt)) {
        header = {};
        error = QObject::tr("Второй заголовок DWG: данные или контрольная сумма не сходятся.");
        return false;
    }
    return true;
}

// ---- preview ----

QByteArray encodeDwgR2000Preview(const DwgR2000Preview& preview, quint32 seeker) {
    const int count = preview.bitmap.isEmpty() ? 1 : 2;
    QByteArray out = sentinel(kImageSentinel);
    const quint32 headerStart = seeker + 16 + 4 + 1 + 9 * count;
    QByteArray body;
    body.append(char(count));
    body.append(char(1));
    put32(body, headerStart);
    put32(body, quint32(preview.header.size()));
    if (count == 2) {
        body.append(char(2));
        put32(body, headerStart + quint32(preview.header.size()));
        put32(body, quint32(preview.bitmap.size()));
    }
    body += preview.header;
    body += preview.bitmap;
    put32(out, quint32(body.size()));
    out += body;
    out += sentinel(kImageEnd);
    return out;
}

bool decodeDwgR2000Preview(const QByteArray& file, quint32 seeker, DwgR2000Preview& preview, QString& error) {
    preview = {};
    preview.header.clear();
    if (!hasSentinel(file, seeker, kImageSentinel) || qint64(seeker) + 21 > file.size()) {
        error = QObject::tr("Картинка DWG: нет начальной метки.");
        return false;
    }
    const quint32 size = le32(file, seeker + 16);
    const qint64 end = qint64(seeker) + 20 + size;
    const int count = uchar(file[seeker + 20]);
    if (end + 16 > file.size() || !hasSentinel(file, end, kImageEnd) || count < 1 || count > 3 ||
        qint64(seeker) + 21 + 9 * count > end) {
        error = QObject::tr("Картинка DWG: размер или конечная метка не сходятся.");
        return false;
    }
    for (int i = 0; i < count; ++i) {
        const qint64 at = qint64(seeker) + 21 + 9 * i;
        const int code = uchar(file[at]);
        const quint32 start = le32(file, at + 1), length = le32(file, at + 5);
        if (start < seeker || qint64(start) + length > end) { preview = {}; error = QObject::tr("Картинка DWG выходит за свой раздел."); return false; }
        if (code == 1) preview.header = file.mid(start, length);
        else if (code == 2) preview.bitmap = file.mid(start, length);
    }
    if (encodeDwgR2000Preview(preview, seeker) != file.mid(seeker, end + 16 - seeker)) {
        preview = {};
        error = QObject::tr("Картинка DWG: разметка отличается от известной (заголовок, растр).");
        return false;
    }
    return true;
}

QByteArray dwgPreviewBitmap(int width, int height, const std::vector<quint8>& rgb) {
    if (width <= 0 || height <= 0 || rgb.size() != std::size_t(width) * std::size_t(height) * 3) return {};
    // The palette: the picture's colours; past 256, a 6 × 7 × 6 cube nearest.
    std::map<quint32, int> index;
    for (std::size_t i = 0; i < rgb.size() && index.size() <= 256; i += 3)
        index.emplace(quint32(rgb[i]) << 16 | quint32(rgb[i + 1]) << 8 | rgb[i + 2], 0);
    std::vector<quint32> palette;
    const bool cube = index.size() > 256;
    if (cube) {
        for (int r = 0; r < 6; ++r)
            for (int g = 0; g < 7; ++g)
                for (int b = 0; b < 6; ++b)
                    palette.push_back(quint32(r * 51) << 16 | quint32(g * 255 / 6) << 8 | quint32(b * 51));
    } else {
        for (auto& [colour, i] : index) { i = int(palette.size()); palette.push_back(colour); }
    }
    palette.resize(256, 0);
    const int stride = (width + 3) / 4 * 4;
    QByteArray out;
    put32(out, 40); put32(out, quint32(width)); put32(out, quint32(height));
    put16(out, 1); put16(out, 8);
    put32(out, 0); put32(out, quint32(stride * height));
    put32(out, 0); put32(out, 0); put32(out, 256); put32(out, 0);
    for (quint32 c : palette) { out.append(char(c & 0xFF)); out.append(char((c >> 8) & 0xFF)); out.append(char(c >> 16)); out.append('\0'); }
    for (int y = height - 1; y >= 0; --y) {
        for (int x = 0; x < width; ++x) {
            const std::size_t p = (std::size_t(y) * width + x) * 3;
            int i = 0;
            if (cube) i = (rgb[p] * 5 + 127) / 255 * 42 + (rgb[p + 1] * 6 + 127) / 255 * 6 + (rgb[p + 2] * 5 + 127) / 255;
            else i = index.at(quint32(rgb[p]) << 16 | quint32(rgb[p + 1]) << 8 | rgb[p + 2]);
            out.append(char(i));
        }
        out.append(QByteArray(stride - width, '\0'));
    }
    return out;
}

// ---- objects ----

std::optional<DwgObjectKind> dwgObjectKind(const QString& t) {
    static const std::map<QString, DwgObjectKind> kinds{
        {"BLOCK_CONTROL", DwgObjectKind::BlockControl}, {"LAYER_CONTROL", DwgObjectKind::LayerControl},
        {"STYLE_CONTROL", DwgObjectKind::StyleControl}, {"LTYPE_CONTROL", DwgObjectKind::LinetypeControl},
        {"VIEW_CONTROL", DwgObjectKind::ViewControl}, {"UCS_CONTROL", DwgObjectKind::UcsControl},
        {"VPORT_CONTROL", DwgObjectKind::ViewportControl}, {"APPID_CONTROL", DwgObjectKind::AppIdControl},
        {"DIMSTYLE_CONTROL", DwgObjectKind::DimStyleControl}, {"VX_CONTROL", DwgObjectKind::ViewportEntityControl},
        {"VP_ENT_HDR_CONTROL", DwgObjectKind::ViewportEntityControl},
        {"BLOCK_HEADER", DwgObjectKind::BlockHeader}, {"LAYER", DwgObjectKind::Layer}, {"STYLE", DwgObjectKind::TextStyle},
        {"LTYPE", DwgObjectKind::Linetype}, {"APPID", DwgObjectKind::AppId}, {"VPORT", DwgObjectKind::Viewport},
        {"DIMSTYLE", DwgObjectKind::DimStyle}, {"DICTIONARY", DwgObjectKind::Dictionary},
        {"ACDBDICTIONARYWDFLT", DwgObjectKind::DictionaryWithDefault}, {"ACDBPLACEHOLDER", DwgObjectKind::Placeholder},
        {"MLINESTYLE", DwgObjectKind::MlineStyle}, {"LAYOUT", DwgObjectKind::Layout}, {"BLOCK", DwgObjectKind::Block},
        {"ENDBLK", DwgObjectKind::EndBlock}, {"REGION", DwgObjectKind::Region}, {"3DSOLID", DwgObjectKind::Solid3d},
        {"BODY", DwgObjectKind::Body}};
    QString name = t;
    while (name.endsWith(QChar(u'\0'))) name.chop(1);
    const auto it = kinds.find(name);
    if (it == kinds.end()) return std::nullopt;
    return it->second;
}

bool decodeDwgR2000Object(const QByteArray& file, quint32 offset, DwgObjectKind kind, DwgR2000Object& object,
                          QString& error, DwgObjectExtent* extent) {
    object = {};
    object.kind = kind;
    object.data = emptyData(kind);
    qint64 at = offset;
    quint32 size = 0, words = 0;
    if (!readModularShort(file, at, size, words) || at + size + 2 > file.size()) {
        object = {};
        error = QObject::tr("Объект DWG по смещению %1: размер выходит за файл.").arg(offset);
        return false;
    }
    const quint64 start = quint64(at) * 8, end = start + quint64(size) * 8;
    BitReader r(file, start, end);
    DwgObjectFrame& f = object.frame;
    f.entity = isEntityKind(kind);
    r.bs(f.type);
    quint32 dataBits = 0;
    r.rl(dataBits);
    DwgHandleRef own;
    r.handle(own);
    f.handle = own.value;
    if (own.code != 0) r.ok = false;
    ioEed(r, f.eed);
    ioCommon(r, f);
    ioData(r, kind, object.data);
    const quint64 dataEnd = r.position();
    bool good = r.ok && dataEnd == start + dataBits;
    if (good) {
        r.seek(start + dataBits);
        ioCommonHandles(r, f);
        ioHandles(r, kind, object.data);
        good = r.ok && end - r.position() < 8;
    }
    if (!good) {
        object = {};
        error = QObject::tr("Объект DWG по смещению %1 не сходится с разметкой своего типа.").arg(offset);
        return false;
    }
    if (dwgCrc16(0xC0C1, file.constData() + offset, (at - offset) + size) != le16(file, at + size)) {
        object = {};
        error = QObject::tr("Объект DWG по смещению %1: контрольная сумма не сходится.").arg(offset);
        return false;
    }
    if (extent) *extent = {dataBits, r.position() - start, size, quint32(at - offset)};
    return true;
}

bool encodeDwgR2000Object(const DwgR2000Object& object, QByteArray& bytes, QString& error, DwgObjectExtent* extent) {
    bytes.clear();
    DwgR2000Object copy = object;
    DwgObjectFrame& f = copy.frame;
    f.entity = isEntityKind(copy.kind);
    BitWriter w;
    w.bs(f.type);
    const std::size_t bitsAt = w.position();
    w.rl(0);
    w.handle(DwgHandleRef{0, f.handle});
    ioEed(w, f.eed);
    ioCommon(w, f);
    ioData(w, copy.kind, copy.data);
    const std::size_t dataBits = w.position();
    w.patch32(bitsAt, quint32(dataBits));
    ioCommonHandles(w, f);
    ioHandles(w, copy.kind, copy.data);
    if (!w.ok) {
        error = QObject::tr("Объект DWG %1: данные не укладываются в разметку своего типа.").arg(f.handle, 0, 16);
        return false;
    }
    const std::size_t handlesEnd = w.position();
    const QByteArray body = w.bytes();
    bytes = modularShort(quint32(body.size())) + body;
    put16(bytes, dwgCrc16(0xC0C1, bytes.constData(), bytes.size()));
    if (extent) *extent = {quint64(dataBits), quint64(handlesEnd), quint32(body.size()), quint32(bytes.size() - body.size() - 2)};
    return true;
}

// ---- the document ----

namespace {

DwgHandleRef soft(quint64 h) { return {4, h}; }
DwgHandleRef hard(quint64 h) { return {5, h}; }
DwgHandleRef softOwner(quint64 h) { return {2, h}; }
DwgHandleRef hardOwner(quint64 h) { return {3, h}; }

DwgR2000Object makeObject(DwgObjectKind kind, int type, quint64 handle, DwgObjectData data, DwgHandleRef owner,
                          std::vector<DwgHandleRef> reactors = {}) {
    DwgR2000Object o;
    o.kind = kind;
    o.frame.type = type;
    o.frame.handle = handle;
    o.frame.owner = owner;
    o.frame.reactors = std::move(reactors);
    o.data = std::move(data);
    return o;
}

DwgTableEntry entryNamed(const char* name) {
    DwgTableEntry e;
    e.name = name;
    return e;
}

DwgControlData control(qint32 entries, std::vector<DwgHandleRef> handles) {
    DwgControlData c;
    c.entries = entries;
    c.handles = std::move(handles);
    return c;
}

DwgR2000Object entity(DwgObjectKind kind, int type, quint64 handle, int mode, DwgObjectData data) {
    DwgR2000Object o;
    o.kind = kind;
    o.frame.type = type;
    o.frame.handle = handle;
    o.frame.entity = true;
    o.frame.entityMode = mode;
    o.frame.noLinks = false;
    o.frame.layer = hard(0x10);
    o.data = std::move(data);
    return o;
}

DwgLayoutData layout(const char* name, qint32 tab, quint64 block, bool model) {
    DwgLayoutData l;
    l.printer = "none_device";
    l.layoutName = name;
    l.tabOrder = tab;
    l.plotFlags = model ? 1712 : 688;
    l.plotType = model ? 0 : 5;
    l.scaleType = model ? 0 : 16;
    l.limitsMax = {420.0, 297.0};
    // AutoCAD 2000 leaves the extents of the model's and of a layout not yet opened at zero; the
    // first layout's are the empty box.
    if (tab != 1) { l.extentsMin = {}; l.extentsMax = {}; }
    l.block = soft(block);
    return l;
}

} // namespace

bool encodeDwgR2000SolidsDocument(const DwgR2000SolidsDocument& document, QByteArray& file, QString& error) {
    file.clear();
    if (document.solids.empty() || document.solids.size() > 4096) {
        error = QObject::tr("Для DWG нужно от 1 до 4096 тел.");
        return false;
    }
    // Class numbers, as AutoCAD 2000 numbers its three own.
    const std::vector<DwgClassRecord> classes{
        {500, 0, "AutoCAD 2000", "AcDbDictionaryWithDefault", "ACDBDICTIONARYWDFLT", false, 0x1F3},
        {501, 0, "AutoCAD 2000", "AcDbPlaceHolder", "ACDBPLACEHOLDER", false, 0x1F3},
        {502, 0, "AutoCAD 2000", "AcDbLayout", "LAYOUT", false, 0x1F3}};
    constexpr int kWdflt = 500, kPlaceholder = 501, kLayout = 502;
    const quint64 firstSolid = 0x29;
    const quint64 lastSolid = firstSolid + document.solids.size() - 1;
    std::vector<DwgR2000Object> objects;
    using K = DwgObjectKind;
    // Tables.
    objects.push_back(makeObject(K::BlockControl, 48, 0x1, control(1, {softOwner(0x23), hardOwner(0x1F), hardOwner(0x1B)}), soft(0)));
    objects.push_back(makeObject(K::LayerControl, 50, 0x2, control(1, {softOwner(0x10)}), soft(0)));
    objects.push_back(makeObject(K::StyleControl, 52, 0x3, control(1, {softOwner(0x11)}), soft(0)));
    objects.push_back(makeObject(K::LinetypeControl, 56, 0x5, control(1, {softOwner(0x16), hardOwner(0x14), hardOwner(0x15)}), soft(0)));
    objects.push_back(makeObject(K::ViewControl, 60, 0x6, control(0, {}), soft(0)));
    objects.push_back(makeObject(K::UcsControl, 62, 0x7, control(0, {}), soft(0)));
    objects.push_back(makeObject(K::ViewportControl, 64, 0x8, control(1, {softOwner(0x28)}), soft(0)));
    objects.push_back(makeObject(K::AppIdControl, 66, 0x9, control(1, {softOwner(0x12)}), soft(0)));
    {
        DwgControlData c = control(1, {softOwner(0x27)});
        c.more = {hard(0x27)};
        objects.push_back(makeObject(K::DimStyleControl, 68, 0xA, c, soft(0)));
    }
    objects.push_back(makeObject(K::ViewportEntityControl, 70, 0xB, control(0, {}), soft(0)));
    // The named-object dictionary and its own.
    {
        DwgDictionaryData d;
        d.names = {"ACAD_GROUP", "ACAD_LAYOUT", "ACAD_MLINESTYLE", "ACAD_PLOTSETTINGS", "ACAD_PLOTSTYLENAME"};
        d.items = {softOwner(0xD), softOwner(0x1A), softOwner(0x17), softOwner(0x19), softOwner(0xE)};
        objects.push_back(makeObject(K::Dictionary, 42, 0xC, d, soft(0)));
    }
    objects.push_back(makeObject(K::Dictionary, 42, 0xD, DwgDictionaryData{}, soft(0xC), {soft(0xC)}));
    {
        DwgDictionaryData d;
        d.names = {"Normal"};
        d.items = {softOwner(0xF)};
        d.defaultEntry = hard(0xF);
        objects.push_back(makeObject(K::DictionaryWithDefault, kWdflt, 0xE, d, soft(0xC), {soft(0xC)}));
    }
    objects.push_back(makeObject(K::Placeholder, kPlaceholder, 0xF, DwgPlaceholderData{}, soft(0xE), {soft(0xE)}));
    {
        DwgLayerData l;
        l.entry = entryNamed("0");
        l.plotStyle = hard(0xF);
        l.linetype = hard(0x16);
        objects.push_back(makeObject(K::Layer, 51, 0x10, l, soft(0x2)));
    }
    {
        DwgTextStyleData s;
        s.entry = entryNamed("Standard");
        objects.push_back(makeObject(K::TextStyle, 53, 0x11, s, soft(0x3)));
    }
    {
        DwgAppIdData a;
        a.entry = entryNamed("ACAD");
        objects.push_back(makeObject(K::AppId, 67, 0x12, a, soft(0x9)));
    }
    for (auto [handle, name, description] : {std::tuple<quint64, const char*, const char*>{0x14, "ByBlock", ""},
                                             {0x15, "ByLayer", ""}, {0x16, "Continuous", "Solid line"}}) {
        DwgLinetypeData l;
        l.entry = entryNamed(name);
        l.description = description;
        objects.push_back(makeObject(K::Linetype, 57, handle, l, soft(0x5)));
    }
    {
        DwgDictionaryData d;
        d.names = {"Standard"};
        d.items = {softOwner(0x18)};
        objects.push_back(makeObject(K::Dictionary, 42, 0x17, d, soft(0xC), {soft(0xC)}));
        DwgMlineStyleData m;
        m.name = "STANDARD";
        m.lines = {{0.5, 256, 32767}, {-0.5, 256, 32767}};
        objects.push_back(makeObject(K::MlineStyle, 73, 0x18, m, soft(0x17), {soft(0x17)}));
    }
    objects.push_back(makeObject(K::Dictionary, 42, 0x19, DwgDictionaryData{}, soft(0xC), {soft(0xC)}));
    {
        DwgDictionaryData d;
        d.names = {"Layout1", "Layout2", "Model"};
        d.items = {softOwner(0x1E), softOwner(0x26), softOwner(0x22)};
        objects.push_back(makeObject(K::Dictionary, 42, 0x1A, d, soft(0xC), {soft(0xC)}));
    }
    // The three blocks of the spaces and their layouts.
    const auto space = [&](quint64 header, const char* name, const char* blockName, int mode, quint64 layoutHandle,
                           const char* layoutName, qint32 tab, bool model) {
        DwgBlockHeaderData b;
        b.entry = entryNamed(name);
        b.block = hardOwner(header + 1);
        b.endBlock = hardOwner(header + 2);
        b.layout = hard(layoutHandle);
        if (model) { b.first = soft(firstSolid); b.last = soft(lastSolid); }
        objects.push_back(makeObject(K::BlockHeader, 49, header, b, soft(0x1)));
        DwgBlockData blockData;
        blockData.name = blockName;
        DwgR2000Object block = entity(K::Block, 4, header + 1, mode, blockData);
        DwgR2000Object end = entity(K::EndBlock, 5, header + 2, mode, DwgEndBlockData{});
        if (mode == 0) { block.frame.owner = soft(header); end.frame.owner = soft(header); }
        objects.push_back(block);
        objects.push_back(end);
        objects.push_back(makeObject(K::Layout, kLayout, layoutHandle, layout(layoutName, tab, header, model), soft(0x1A), {soft(0x1A)}));
    };
    space(0x1B, "*Paper_Space", "*Paper_Space", 1, 0x1E, "Layout1", 1, false);
    space(0x1F, "*Model_Space", "*Model_Space", 2, 0x22, "Model", 0, true);
    // The second paper space: its header named as the first's, its BLOCK numbered, as AutoCAD names them.
    space(0x23, "*Paper_Space", "*Paper_Space0", 0, 0x26, "Layout2", 2, false);
    {
        DwgDimStyleData d;
        d.entry = entryNamed("Standard");
        d.DIMTXSTY = hard(0x11);
        objects.push_back(makeObject(K::DimStyle, 69, 0x27, d, soft(0xA)));
    }
    // The active viewport: the model seen from above, all of it.
    {
        DwgViewportData v;
        v.entry = entryNamed("*Active");
        const auto& e = document.extents;
        const double width = std::max(e[3] - e[0], 1.0), height = std::max(e[4] - e[1], 1.0);
        v.height = std::max(height, width / 1.5) * 1.1;
        v.aspect = v.height * 1.5;
        v.center = {(e[0] + e[3]) / 2, (e[1] + e[4]) / 2};
        v.gridSpacing = {10.0, 10.0};
        v.snapSpacing = {10.0, 10.0};
        objects.push_back(makeObject(K::Viewport, 65, 0x28, v, soft(0x8)));
    }
    // The solids, model space, layer 0.
    for (std::size_t i = 0; i < document.solids.size(); ++i) {
        DwgSolidData s;
        s.sat = document.solids[i];
        if (s.sat.isEmpty()) { error = QObject::tr("Тело %1 для DWG пустое.").arg(i + 1); return false; }
        s.wires.clear();
        const quint64 handle = firstSolid + i;
        DwgR2000Object o = entity(K::Solid3d, 38, handle, 2, s);
        o.frame.previous = soft(i == 0 ? 0 : handle - 1);
        o.frame.next = soft(handle == lastSolid ? 0 : handle + 1);
        o.frame.noLinks = i > 0 && handle < lastSolid;
        objects.push_back(o);
    }
    const quint64 handseed = lastSolid + 1;

    // Header variables.
    DwgR2000HeaderVariables h;
    h.TDCREATED = qint32(document.created[0]);
    h.TDCREATEMS = qint32(document.created[1]);
    h.TDUPDATED = h.TDCREATED;
    h.TDUPDATEMS = h.TDCREATEMS;
    h.HANDSEED = {0, handseed};
    h.INSUNITS = 4;
    h.MLIMMAX = {420.0, 297.0};
    h.MEXTMIN = {document.extents[0], document.extents[1], document.extents[2]};
    h.MEXTMAX = {document.extents[3], document.extents[4], document.extents[5]};
    h.FINGERPRINTGUID = document.fingerprint;
    h.VERSIONGUID = document.version;

    // Layout: file header, auxiliary header, preview, header variables, classes, padding, objects,
    // object map, free space, second header, template.
    DwgR2000FileHeader fileHeader;
    fileHeader.imageSeeker = 220;
    const QByteArray preview = encodeDwgR2000Preview(document.preview, 220);
    const QByteArray variablesProbe = encodeDwgR2000HeaderVariables(h);
    const quint32 variablesAt = 220 + quint32(preview.size());
    const QByteArray classesBytes = encodeDwgR2000Classes(classes);
    const quint32 classesAt = variablesAt + quint32(variablesProbe.size());
    const quint32 objectsAt = classesAt + quint32(classesBytes.size()) + 0x200;
    QByteArray objectBytes;
    std::vector<std::pair<quint64, quint32>> offsets;
    for (const auto& o : objects) {
        QByteArray bytes;
        if (!encodeDwgR2000Object(o, bytes, error)) return false;
        offsets.push_back({o.frame.handle, objectsAt + quint32(objectBytes.size())});
        objectBytes += bytes;
        if (objectBytes.size() > 256ll * 1024 * 1024) { error = QObject::tr("Объекты DWG превышают 256 МиБ."); return false; }
    }
    std::sort(offsets.begin(), offsets.end());
    const QByteArray map = encodeDwgR2000ObjectMap(offsets);
    const quint32 mapAt = objectsAt + quint32(objectBytes.size());
    const quint32 freeAt = mapAt + quint32(map.size());
    DwgR2000FreeSpace freeSpace;
    freeSpace.handles = quint32(handseed - 1);
    freeSpace.updated = document.created;
    freeSpace.objectsOffset = objectsAt;
    const QByteArray freeBytes = encodeDwgR2000FreeSpace(freeSpace);
    const quint32 secondAt = freeAt + quint32(freeBytes.size());

    fileHeader.locators = {{0, variablesAt, quint32(variablesProbe.size())},
                           {1, classesAt, quint32(classesBytes.size())},
                           {2, mapAt, quint32(map.size())},
                           {3, freeAt, quint32(freeBytes.size())},
                           {4, 0, 4},
                           {5, 97, 123}};
    DwgR2000SecondHeader second;
    second.location = secondAt;
    second.handles = {{0, {}}, {1, {}}, {2, {}}, {3, {}}, {4, {}}, {5, {}}, {6, {}}, {7, {}}, {8, {}}, {9, {}},
                      {10, {}}, {11, {}}, {12, {}}, {13, {}}};
    const std::array<quint64, 14> secondHandles{handseed, 0x1, 0x2, 0x3, 0x5, 0x6, 0x7, 0x8, 0x9, 0xA, 0xB, 0xC, 0x17, 0xD};
    for (std::size_t i = 0; i < secondHandles.size(); ++i) {
        QByteArray bytes;
        for (quint64 v = secondHandles[i]; v; v >>= 8) bytes.prepend(char(v & 0xFF));
        second.handles[i].second = bytes;
    }
    // The second header's size does not depend on the template's seeker's value but on its length:
    // place the template after it, then fill both seekers in.
    QByteArray secondBytes;
    for (int pass = 0; pass < 3; ++pass) {
        const quint32 templateAt = secondAt + quint32(secondBytes.size());
        fileHeader.locators[4].seeker = templateAt;
        for (std::size_t i = 0; i < 6; ++i) second.locators[i] = fileHeader.locators[i];
        second.maintenance = fileHeader.maintenance;
        secondBytes = encodeDwgR2000SecondHeader(second);
    }
    if (fileHeader.locators[4].seeker != secondAt + quint32(secondBytes.size())) {
        error = QObject::tr("Не удалось разместить разделы DWG.");
        return false;
    }

    DwgR2000AuxHeader aux;
    aux.created = document.created;
    aux.updated = document.created;
    aux.handseed = quint32(std::min<quint64>(handseed, 0x7FFFFFFF));

    file = encodeDwgR2000FileHeader(fileHeader);
    file += encodeDwgR2000AuxHeader(aux);
    if (file.size() != 220) { file.clear(); error = QObject::tr("Заголовки DWG не той длины."); return false; }
    file += preview;
    file += variablesProbe;
    file += classesBytes;
    file += QByteArray(0x200, '\0');
    file += objectBytes;
    file += map;
    file += freeBytes;
    file += secondBytes;
    file += encodeDwgR2000Template(1);
    return true;
}

} // namespace cadnext::gui
