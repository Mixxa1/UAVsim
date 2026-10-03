#include "cadnext/gui/NativeSolidWorksPart.hpp"

#include "NativeSolidWorksPartBlueprint.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/gui/NativeSolidWorksFeatureBodies.hpp"
#include "cadnext/gui/NativeSolidWorksPackage.hpp"
#include "cadnext/gui/NativeSolidWorksWriter.hpp"

#include <QFileInfo>
#include <QLocale>
#include <QObject>
#include <QSaveFile>

#ifdef CADNEXT_WITH_OCCT
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#endif

#include <zlib.h>

#include <cmath>
#include <cstring>

namespace cadnext::gui {
namespace {

namespace bp = solidworks_blueprint;

const bp::Stream* findStream(const QByteArray& name) {
    for (const bp::Stream& s : bp::streams())
        if (name == s.name) return &s;
    return nullptr;
}

void put16(QByteArray& b, quint16 v) { b.append(char(v & 0xFF)); b.append(char(v >> 8)); }
void put32(QByteArray& b, quint32 v) { put16(b, quint16(v & 0xFFFF)); put16(b, quint16(v >> 16)); }
void put64(QByteArray& b, quint64 v) { put32(b, quint32(v & 0xFFFFFFFFu)); put32(b, quint32(v >> 32)); }
quint16 get16(const QByteArray& b, qint64 at) { return quint16(uchar(b[at]) | uchar(b[at + 1]) << 8); }
quint32 get32(const QByteArray& b, qint64 at) { return quint32(get16(b, at)) | quint32(get16(b, at + 2)) << 16; }
quint64 get64(const QByteArray& b, qint64 at) { return quint64(get32(b, at)) | quint64(get32(b, at + 4)) << 32; }

// An MFC Unicode string: FF FE FF, the length (a byte; FF and 16 bits from 255 on), UTF-16.
QByteArray archiveString(const QString& text) {
    QByteArray out = QByteArray::fromHex("fffeff");
    if (text.size() < 255) out.append(char(text.size()));
    else { out.append(char(0xFF)); put16(out, quint16(text.size())); }
    for (QChar c : text) put16(out, c.unicode());
    return out;
}
bool readArchiveString(const QByteArray& b, qint64& at, QString& text) {
    if (at + 4 > b.size() || uchar(b[at]) != 0xFF || uchar(b[at + 1]) != 0xFE || uchar(b[at + 2]) != 0xFF) return false;
    qint64 p = at + 3;
    quint32 size = uchar(b[p++]);
    if (size == 0xFF) {
        if (p + 2 > b.size()) return false;
        size = get16(b, p);
        p += 2;
    }
    if (p + 2 * qint64(size) > b.size()) return false;
    text.resize(size);
    for (quint32 i = 0; i < size; ++i) text[i] = QChar(get16(b, p + 2 * i));
    at = p + 2 * qint64(size);
    return true;
}

QByteArray classTag(const char* name, quint16 schema) {
    QByteArray out = QByteArray::fromHex("ffff");
    put16(out, schema);
    put16(out, quint16(std::strlen(name)));
    out.append(name);
    return out;
}

QString xmlEscaped(const QString& text) {
    QString out;
    for (QChar c : text) {
        if (c == u'&') out += QLatin1String("&amp;");
        else if (c == u'<') out += QLatin1String("&lt;");
        else if (c == u'>') out += QLatin1String("&gt;");
        else if (c == u'"') out += QLatin1String("&quot;");
        else out += c;
    }
    return out;
}
QString xmlPlain(QString text) {
    return text.replace(QLatin1String("&lt;"), QLatin1String("<")).replace(QLatin1String("&gt;"), QLatin1String(">"))
               .replace(QLatin1String("&quot;"), QLatin1String("\"")).replace(QLatin1String("&amp;"), QLatin1String("&"));
}

// "name=default in hex" of a numeric piece.
void namedDefault(const char* text, QString& name, quint64& fallback) {
    const QString t = QString::fromLatin1(text);
    const qsizetype eq = t.indexOf(u'=');
    name = t.left(eq);
    fallback = t.mid(eq + 1).toULongLong(nullptr, 16);
}

bool slotText(const SolidWorksPartValues& values, const char* slot, QString& text, QString& error) {
    const QString name = QString::fromUtf8(slot);
    const auto it = values.text.find(name);
    if (it != values.text.end()) { text = *it; return true; }
    for (const bp::Default& d : bp::defaults())
        if (name == QLatin1String(d.slot)) { text = QString::fromUtf8(d.text); return true; }
    error = QObject::tr("Документ SOLIDWORKS: не задано значение «%1».").arg(name);
    return false;
}

QString numberKey(char kind, const char* text) {
    return (kind == 'T' ? QStringLiteral("time.") : QStringLiteral("filetime.")) + QString::fromLatin1(text);
}

bool bindText(SolidWorksPartValues& values, const char* slot, const QString& text, QString& error) {
    const QString name = QString::fromUtf8(slot);
    const auto it = values.text.find(name);
    if (it == values.text.end()) { values.text.insert(name, text); return true; }
    if (*it == text) return true;
    error = QObject::tr("Документ SOLIDWORKS: «%1» читается по-разному — «%2» и «%3».").arg(name, *it, text);
    return false;
}

} // namespace

QList<QByteArray> solidWorksPartBlueprintStreams() {
    QList<QByteArray> names;
    for (const bp::Stream& s : bp::streams()) names << QByteArray(s.name);
    return names;
}

bool solidWorksPartFormula(const QString& formula, const std::array<double, 3>& m, const std::array<double, 3>& M, double& value) {
    std::array<double, 3> c{}, e{};
    for (int i = 0; i < 3; ++i) {
        c[i] = (M[i] + m[i]) / 2;
        const double h = (M[i] - m[i]) / 2;
        e[i] = h + 0.1 * h;
    }
    const auto axis = [&](qsizetype at) { return formula.size() > at ? formula[at].unicode() - u'0' : -1; };
    const auto good = [](int i) { return i >= 0 && i < 3; };
    if (formula == QLatin1String("0")) { value = 0.0; return true; }
    if (formula == QLatin1String("r")) {
        value = std::sqrt((M[0] - m[0]) * (M[0] - m[0]) + (M[1] - m[1]) * (M[1] - m[1]) + (M[2] - m[2]) * (M[2] - m[2])) / 2;
        return true;
    }
    if (formula.startsWith(QLatin1String("pr")) && formula.size() == 4 && good(axis(2)) && good(axis(3))) {
        value = std::sqrt(e[axis(2)] * e[axis(2)] + e[axis(3)] * e[axis(3)]);
        return true;
    }
    if (formula.size() == 2 && good(axis(1))) {
        const int i = axis(1);
        if (formula[0] == u'c') { value = c[i]; return true; }
        if (formula[0] == u'M') { value = M[i]; return true; }
        if (formula[0] == u'm') { value = m[i]; return true; }
        if (formula[0] == u'e') { value = e[i]; return true; }
    }
    if (formula.size() == 3 && formula.startsWith(QLatin1String("-e")) && good(axis(2))) { value = -e[axis(2)]; return true; }
    if (formula.size() == 5 && formula[0] == u'c' && formula[3] == u'e' && good(axis(1)) && axis(1) == axis(4)) {
        const int i = axis(1);
        if (formula[2] == u'+') { value = c[i] + e[i]; return true; }
        if (formula[2] == u'-') { value = c[i] - e[i]; return true; }
    }
    return false;
}

bool encodeSolidWorksPartStream(const QByteArray& name, const SolidWorksPartValues& values, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    const bp::Stream* stream = findStream(name);
    if (!stream) {
        error = QObject::tr("В чертеже документа SOLIDWORKS нет потока «%1».").arg(QString::fromLatin1(name));
        return false;
    }
    QByteArray out;
    if (stream->kind == bp::StreamKind::Text) {
        QString text;
        for (std::size_t i = 0; i < stream->count; ++i) {
            const bp::Piece& p = stream->pieces[i];
            if (p.kind == 'L') { text += QString::fromUtf8(p.text); continue; }
            QString value;
            if (!slotText(values, p.text, value, error)) return false;
            text += xmlEscaped(value);
        }
        if (name == "swXmlContents/KeyWords") out.append(char(bp::keyWordsPrefix()));
        out += text.toUtf8();
        bytes = out;
        return true;
    }
    QMap<QByteArray, int> classes;
    int count = 1;
    for (std::size_t i = 0; i < stream->count; ++i) {
        const bp::Piece& p = stream->pieces[i];
        switch (p.kind) {
        case 'C':
            out += classTag(p.text, p.number);
            classes.insert(p.text, count);
            count += 2;
            break;
        case 'R': {
            const auto it = classes.find(p.text);
            if (it == classes.end()) { error = QObject::tr("Чертёж SOLIDWORKS: класс %1 не объявлен.").arg(QLatin1String(p.text)); return false; }
            put16(out, quint16(0x8000 | *it));
            ++count;
            break;
        }
        case 'S': out += archiveString(QString::fromUtf8(p.text)); break;
        case 'V': {
            QString value;
            if (!slotText(values, p.text, value, error)) return false;
            if (value.size() > 0xFFFD) { error = QObject::tr("Строка «%1» документа SOLIDWORKS слишком длинна.").arg(QLatin1String(p.text)); return false; }
            out += archiveString(value);
            break;
        }
        case 'B': out += QByteArray::fromHex(p.text); break;
        case 'T': put32(out, quint32(values.number.value(numberKey('T', p.text)))); break;
        case 'F': put64(out, values.number.value(numberKey('F', p.text))); break;
        case 'G': {
            const quint64 v = values.number.value(numberKey('G', p.text));
            put32(out, quint32(v >> 32));
            put32(out, quint32(v & 0xFFFFFFFFu));
            break;
        }
        case 'D': {
            double v = 0;
            if (!solidWorksPartFormula(QString::fromLatin1(p.text), values.boxMin, values.boxMax, v)) {
                error = QObject::tr("Чертёж SOLIDWORKS: неизвестная формула %1.").arg(QLatin1String(p.text));
                return false;
            }
            quint64 raw = 0;
            std::memcpy(&raw, &v, 8);
            put64(out, raw);
            break;
        }
        case 'U': case 'Q': case 'Y': {
            QString key;
            quint64 fallback = 0;
            namedDefault(p.text, key, fallback);
            const quint64 v = values.number.value(key, fallback);
            if (p.kind == 'U') put32(out, quint32(v));
            else if (p.kind == 'Q') put64(out, v);
            else out.append(char(v));
            break;
        }
        default:
            error = QObject::tr("Чертёж SOLIDWORKS: неизвестный вид части потока.");
            return false;
        }
    }
    bytes = out;
    return true;
}

bool matchSolidWorksPartStream(const QByteArray& name, const QByteArray& b, SolidWorksPartValues& values, QString& error) {
    error.clear();
    const bp::Stream* stream = findStream(name);
    if (!stream) {
        error = QObject::tr("В чертеже документа SOLIDWORKS нет потока «%1».").arg(QString::fromLatin1(name));
        return false;
    }
    const auto differs = [&](std::size_t piece, qint64 at) {
        error = QObject::tr("Поток «%1» отличается от чертежа вне слотов: часть %2, байт %3.").arg(QString::fromLatin1(name)).arg(piece).arg(at);
        return false;
    };
    if (stream->kind == bp::StreamKind::Text) {
        QByteArray body = b;
        if (name == "swXmlContents/KeyWords") {
            if (body.isEmpty() || uchar(body[0]) != bp::keyWordsPrefix()) return differs(0, 0);
            body.remove(0, 1);
        }
        const QString text = QString::fromUtf8(body);
        qsizetype at = 0;
        const char* pending = nullptr;
        for (std::size_t i = 0; i < stream->count; ++i) {
            const bp::Piece& p = stream->pieces[i];
            if (p.kind != 'L') { pending = p.text; continue; }
            const QString literal = QString::fromUtf8(p.text);
            if (pending) {
                const qsizetype next = text.indexOf(literal, at);
                if (next < 0) return differs(i, at);
                if (!bindText(values, pending, xmlPlain(text.mid(at, next - at)), error)) return false;
                at = next;
                pending = nullptr;
            }
            if (text.mid(at, literal.size()) != literal) return differs(i, at);
            at += literal.size();
        }
        if (pending) {
            if (!bindText(values, pending, xmlPlain(text.mid(at)), error)) return false;
            at = text.size();
        }
        return at == text.size() ? true : differs(stream->count, at);
    }
    QMap<QByteArray, int> classes;
    int count = 1;
    qint64 at = 0;
    const auto expect = [&](const QByteArray& want) {
        if (b.mid(at, want.size()) != want) return false;
        at += want.size();
        return true;
    };
    for (std::size_t i = 0; i < stream->count; ++i) {
        const bp::Piece& p = stream->pieces[i];
        switch (p.kind) {
        case 'C':
            if (!expect(classTag(p.text, p.number))) return differs(i, at);
            classes.insert(p.text, count);
            count += 2;
            break;
        case 'R': {
            QByteArray want;
            put16(want, quint16(0x8000 | classes.value(p.text)));
            if (!expect(want)) return differs(i, at);
            ++count;
            break;
        }
        case 'S':
            if (!expect(archiveString(QString::fromUtf8(p.text)))) return differs(i, at);
            break;
        case 'V': {
            QString value;
            if (!readArchiveString(b, at, value)) return differs(i, at);
            if (!bindText(values, p.text, value, error)) return false;
            break;
        }
        case 'B':
            if (!expect(QByteArray::fromHex(p.text))) return differs(i, at);
            break;
        case 'T':
            if (at + 4 > b.size()) return differs(i, at);
            if (!values.number.contains(numberKey('T', p.text))) values.number.insert(numberKey('T', p.text), get32(b, at));
            at += 4;
            break;
        case 'F': case 'G': {
            if (at + 8 > b.size()) return differs(i, at);
            const quint64 v = p.kind == 'F' ? get64(b, at) : (quint64(get32(b, at)) << 32 | get32(b, at + 4));
            // A FILETIME of 2001–2100, as every one of these is.
            if ((v >> 32) < 0x01C00000u || (v >> 32) > 0x02400000u) return differs(i, at);
            if (!values.number.contains(numberKey(p.kind, p.text))) values.number.insert(numberKey(p.kind, p.text), v);
            at += 8;
            break;
        }
        case 'D': {
            if (at + 8 > b.size()) return differs(i, at);
            const quint64 raw = get64(b, at);
            double v = 0;
            std::memcpy(&v, &raw, 8);
            const QString formula = QString::fromLatin1(p.text);
            if (formula.size() == 2 && (formula[0] == u'M' || formula[0] == u'm') && !values.real.contains(formula))
                (formula[0] == u'M' ? values.boxMax : values.boxMin)[formula[1].unicode() - u'0'] = v;
            values.real.insert(formula, v);
            at += 8;
            break;
        }
        case 'U': case 'Q': case 'Y': {
            const int size = p.kind == 'U' ? 4 : p.kind == 'Q' ? 8 : 1;
            if (at + size > b.size()) return differs(i, at);
            QString key;
            quint64 fallback = 0;
            namedDefault(p.text, key, fallback);
            const quint64 v = size == 4 ? get32(b, at) : size == 8 ? get64(b, at) : uchar(b[at]);
            if (!values.number.contains(key)) values.number.insert(key, v);
            at += size;
            break;
        }
        default:
            return differs(i, at);
        }
    }
    return at == b.size() ? true : differs(stream->count, at);
}

QByteArray encodeSolidWorksPartitionStream(const std::vector<QByteArray>& transmits) {
    QByteArray out;
    for (const QByteArray& transmit : transmits) {
        uLongf size = compressBound(uLong(transmit.size()));
        QByteArray packed(qsizetype(size), '\0');
        if (compress2(reinterpret_cast<Bytef*>(packed.data()), &size, reinterpret_cast<const Bytef*>(transmit.constData()),
                      uLong(transmit.size()), 1) != Z_OK) return {};
        packed.resize(qsizetype(size));
        // The length counts what follows it: the marker, two sizes, the data and eight zero bytes.
        put32(out, quint32(32 + packed.size()));
        out += QByteArray::fromHex(bp::partitionGuid());
        put32(out, quint32(transmit.size()));
        put32(out, quint32(packed.size()));
        out += packed;
        out += QByteArray(8, '\0');
    }
    return out;
}

bool decodeSolidWorksPartitionStream(const QByteArray& stream, std::vector<QByteArray>& transmits) {
    transmits.clear();
    const QByteArray guid = QByteArray::fromHex(bp::partitionGuid());
    qint64 at = 0;
    while (at < stream.size()) {
        if (at + 28 > stream.size()) { transmits.clear(); return false; }
        const quint32 length = get32(stream, at), unpacked = get32(stream, at + 20), packed = get32(stream, at + 24);
        if (stream.mid(at + 4, 16) != guid || length != 32 + packed || at + 36 + qint64(packed) > stream.size() || unpacked > (256u << 20) ||
            stream.mid(at + 28 + packed, 8) != QByteArray(8, '\0')) {
            transmits.clear();
            return false;
        }
        QByteArray raw(qsizetype(unpacked), '\0');
        uLongf size = unpacked;
        if (uncompress(reinterpret_cast<Bytef*>(raw.data()), &size, reinterpret_cast<const Bytef*>(stream.constData() + at + 28), packed) != Z_OK ||
            size != unpacked) {
            transmits.clear();
            return false;
        }
        transmits.push_back(raw);
        at += 36 + packed;
    }
    return true;
}

SolidWorksPartValues solidWorksPartValues(const QString& title, const std::array<double, 3>& boxMin,
                                          const std::array<double, 3>& boxMax, int faces,
                                          const SolidWorksPartWriteOptions& options) {
    SolidWorksPartValues v;
    v.boxMin = boxMin;
    v.boxMax = boxMax;
    const QDateTime saved = (options.saved.isValid() ? options.saved : QDateTime::currentDateTimeUtc()).toUTC();
    const QString folder = options.folder, slash = folder + QLatin1Char('\\');
    const QString source = title + QStringLiteral(".step");
    auto& t = v.text;
    t[QStringLiteral("title")] = title;
    t[QStringLiteral("name")] = title;
    t[QStringLiteral("author")] = options.author;
    t[QStringLiteral("source.file")] = source;
    t[QStringLiteral("source.feature")] = source + QStringLiteral("<1>");
    t[QStringLiteral("source.name")] = title;
    t[QStringLiteral("folder")] = folder;
    t[QStringLiteral("folder.slash")] = slash;
    t[QStringLiteral("path.document")] = slash + title + QStringLiteral(".SLDPRT");
    t[QStringLiteral("path.working")] = t[QStringLiteral("path.document")];
    t[QStringLiteral("path.source")] = slash + source;
    t[QStringLiteral("history.templateFolder")] = slash;
    t[QStringLiteral("history.tempFolder")] = slash;
    t[QStringLiteral("history.tempFile")] = t[QStringLiteral("path.document")];
    t[QStringLiteral("info.folder")] = slash;
    const QLocale english(QLocale::English, QLocale::UnitedStates);
    const QString iso = saved.toString(QStringLiteral("yyyy-MM-ddTHH:mm:ss")) + QLatin1Char('Z');
    t[QStringLiteral("iso.created")] = iso;
    t[QStringLiteral("iso.modified")] = iso;
    t[QStringLiteral("date.short")] = english.toString(saved.date(), QStringLiteral("M/d/yyyy"));
    t[QStringLiteral("date.long")] = english.toString(saved.date(), QStringLiteral("dddd, MMMM d, yyyy"));
    const QString moment = t[QStringLiteral("date.long")] + QLatin1Char(' ') + english.toString(saved.time(), QStringLiteral("h:mm:ss AP"));
    t[QStringLiteral("date.created")] = moment;
    t[QStringLiteral("date.saved")] = moment;
    const quint64 seconds = quint64(saved.toSecsSinceEpoch());
    t[QStringLiteral("unix.created")] = QString::number(seconds);
    t[QStringLiteral("unix.saved")] = QString::number(seconds);
    t[QStringLiteral("unix.source")] = QString::number(seconds);
    v.number[QStringLiteral("time.saved")] = seconds;
    v.number[QStringLiteral("time.source")] = seconds;
    v.number[QStringLiteral("filetime.saved")] = (seconds + 11644473600ull) * 10000000ull; // 100 ns since 1601
    v.number[QStringLiteral("import.faces")] = quint64(faces);
    v.number[QStringLiteral("import.lastFace")] = quint64(faces > 0 ? faces - 1 : 0);
    return v;
}

bool writeSolidWorksImportedPart(kernel::OcctKernel& kernel, kernel::ShapeHandle shape, const QString& path,
                                 QString& error, const SolidWorksPartWriteOptions& options) {
    error.clear();
#ifndef CADNEXT_WITH_OCCT
    Q_UNUSED(kernel); Q_UNUSED(shape); Q_UNUSED(path); Q_UNUSED(options);
    error = QObject::tr("Запись SOLIDWORKS требует OCCT.");
    return false;
#else
    const auto* solid = kernel.findShape(shape);
    if (!solid) {
        error = QObject::tr("Тело для записи SOLIDWORKS не найдено.");
        return false;
    }
    const QString title = options.title.isEmpty() ? QFileInfo(path).completeBaseName() : options.title;
    if (title.isEmpty() || title.size() > 200) {
        error = QObject::tr("Имя детали SOLIDWORKS должно быть от 1 до 200 знаков.");
        return false;
    }
    // The body, kept with its import feature.
    const QString feature = title + QStringLiteral(".step<1>");
    SolidWorksWriteSection localBodies;
    if (!encodeSolidWorksImportedFeatureBodySection(kernel, 0, feature, {shape}, localBodies, error)) return false;
    std::vector<SolidWorksFeatureBodies> stored;
    if (!decodeSolidWorksFeatureBodies(localBodies.data, stored, error) || stored.size() != 1 || stored.front().bodies.size() != 1) {
        if (error.isEmpty()) error = QObject::tr("Раздел тел операции SOLIDWORKS не читается обратно.");
        return false;
    }
    const QByteArray transmit = stored.front().bodies.front().parasolid;
    ParasolidXtTopology topology;
    if (!readParasolidXtTransmitStream(transmit, topology, error)) return false;
    // Its box: no gap around it.
    Bnd_Box box;
    BRepBndLib::AddOptimal(*solid, box, false, false);
    if (box.IsVoid()) {
        error = QObject::tr("У тела для записи SOLIDWORKS нет габарита.");
        return false;
    }
    box.SetGap(0.0);
    std::array<double, 3> low{}, high{};
    box.Get(low[0], low[1], low[2], high[0], high[1], high[2]);
    const SolidWorksPartValues values = solidWorksPartValues(title, low, high, int(topology.faces.size()), options);

    SolidWorksPackage package;
    QByteArray header;
    if (!encodeSolidWorksPartStream("Header2", values, header, error)) return false;
    for (const solidworks_blueprint::Entry& entry : solidworks_blueprint::entries()) {
        SolidWorksPackageEntry e;
        e.name = entry.name;
        e.stamp = entry.stamp;
        if (e.name == localBodies.name) e.data = localBodies.data;
        else if (e.name == "Contents/Config-0-ModelHeader") e.data = header;
        else if (e.name == "Contents/Config-0-Partition") {
            std::vector<QByteArray> transmits(2);
            if (!encodeSolidWorksPartStream("Contents/Config-0-Partition#0", values, transmits[0], error) ||
                !encodeSolidWorksPartStream("Contents/Config-0-Partition#1", values, transmits[1], error)) return false;
            e.data = encodeSolidWorksPartitionStream(transmits);
        } else if (!encodeSolidWorksPartStream(e.name, values, e.data, error)) return false;
        bool text = false;
        if (encodeSolidWorksPackageRecord(package, e, &text).isEmpty()) {
            error = QObject::tr("Не удалось сжать поток «%1» документа SOLIDWORKS.").arg(QString::fromLatin1(e.name));
            return false;
        }
        e.text = text && !e.data.isEmpty();
        package.entries.push_back(std::move(e));
    }
    QByteArray file;
    if (!encodeSolidWorksPackage(package, file, error)) return false;
    // Read back before the destination is touched.
    SolidWorksPackage back;
    if (!decodeSolidWorksPackage(file, back, error) || back.entries != package.entries) {
        if (error.isEmpty()) error = QObject::tr("Записанный пакет SOLIDWORKS читается обратно иначе.");
        return false;
    }
    QSaveFile output(path);
    if (!output.open(QIODevice::WriteOnly) || output.write(file) != file.size() || !output.commit()) {
        error = QObject::tr("Не удалось сохранить деталь SOLIDWORKS: %1").arg(output.errorString());
        return false;
    }
    return true;
#endif
}

} // namespace cadnext::gui
