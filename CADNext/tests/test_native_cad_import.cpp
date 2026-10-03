#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeCompoundFile.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/gui/NativeSolidWorksWriter.hpp"
#include "cadnext/gui/NativeSolidWorksConfiguration.hpp"
#include "cadnext/gui/NativeSolidWorksDocument.hpp"
#include "cadnext/gui/NativeSolidWorksFeatureBodies.hpp"
#include "cadnext/gui/NativeKompasC3d.hpp"
#include "cadnext/gui/NativeKompasGeometry.hpp"
#include "cadnext/gui/NativeKompasWriter.hpp"
#include "cadnext/gui/NativeKompasModel.hpp"
#include "cadnext/gui/NativeKompasProperties.hpp"
#include "cadnext/gui/NativeKompasDocument.hpp"
#include "cadnext/gui/NativeKompasStorage.hpp"
#include "cadnext/gui/NativeKompasCatalog.hpp"
#include "../gui/src/NativeKompasSplineSurface.hpp"
#include "cadnext/gui/ParasolidXtWriter.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/ExactBRepDescription.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QtGlobal>

#include <zlib.h>

#include <BRepAdaptor_Surface.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepBuilderAPI_NurbsConvert.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepLib.hxx>
#include <BRep_Tool.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <GeomAbs_CurveType.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>

#include <cassert>
#include <cmath>
#include <limits>
#include <map>
#include <set>
#include <utility>
#include <vector>

namespace {
struct SurfaceCounts {
    int faces = 0;
    int planes = 0;
    int cylinders = 0;
    int cones = 0;
    int spheres = 0;
    int tori = 0;
    int splines = 0;
    int revolutions = 0;
    int lineRevolutions = 0;
    int other = 0;
};

SurfaceCounts surfaceCounts(const cadnext::kernel::OcctKernel& kernel,
                            const cadnext::kernel::ShapeHandle& handle) {
    SurfaceCounts counts;
    const TopoDS_Shape* shape = kernel.findShape(handle);
    assert(shape != nullptr);
    for (TopExp_Explorer it(*shape, TopAbs_FACE); it.More(); it.Next()) {
        ++counts.faces;
        const BRepAdaptor_Surface surface(TopoDS::Face(it.Current()));
        const auto type = surface.GetType();
        if (type == GeomAbs_Plane) ++counts.planes;
        if (type == GeomAbs_Cylinder) ++counts.cylinders;
        if (type == GeomAbs_Cone) ++counts.cones;
        if (type == GeomAbs_Sphere) ++counts.spheres;
        if (type == GeomAbs_Torus) ++counts.tori;
        if (type == GeomAbs_BSplineSurface) ++counts.splines;
        if (type == GeomAbs_SurfaceOfRevolution) {
            ++counts.revolutions;
            if (surface.BasisCurve()->GetType() == GeomAbs_Line)
                ++counts.lineRevolutions;
        }
        if (type != GeomAbs_Plane && type != GeomAbs_Cylinder &&
            type != GeomAbs_Cone &&
            type != GeomAbs_Sphere &&
            type != GeomAbs_Torus &&
            type != GeomAbs_BSplineSurface && type != GeomAbs_SurfaceOfRevolution)
            ++counts.other;
    }
    return counts;
}

void put16(QByteArray& bytes, quint16 number) {
    bytes.append(char(number & 255));
    bytes.append(char(number >> 8));
}
void put32(QByteArray& bytes, quint32 number) {
    put16(bytes, quint16(number & 65535));
    put16(bytes, quint16(number >> 16));
}
void put16be(QByteArray& bytes, quint16 number) {
    bytes.append(char(number >> 8));
    bytes.append(char(number & 255));
}
void put32be(QByteArray& bytes, quint32 number) {
    put16be(bytes, quint16(number >> 16));
    put16be(bytes, quint16(number & 65535));
}

// Independently specified neutral-binary XT graph: one BODY with a placeholder
// FACE, one integer attribute, its definition/name and its value array.
QByteArray integerAttributeBodyFixture() {
    QByteArray b("PS\0\0", 4);
    const QByteArray modeller(": TRANSMIT FILE created by modeller version 1901315");
    put16be(b, modeller.size()); b += modeller;
    const QByteArray schema("SCH_1901315_19011_13006");
    put32be(b, schema.size()); b += schema;
    put16be(b, 205); put32be(b, 0);
    const auto pointer = [&](quint16 id) { put16be(b, id + 1); };
    const auto node = [&](quint16 type, quint16 id, int count = -1) {
        put16be(b, type); b += char(255); // unchanged public base schema
        if (count >= 0) put32be(b, quint32(count));
        pointer(id);
    };
    node(12, 1);
    put32be(b, 2); pointer(2); // highest_node_id, attributes_groups
    for (int i = 0; i < 5; ++i) pointer(0); // attribute_chains and geometry chains
    put32be(b, 0x408f4000); put32be(b, 0); // res_size = 1000
    put32be(b, 0x3e45798e); put32be(b, 0xe2308c3a); // res_linear = 1e-8
    for (int i = 0; i < 3; ++i) pointer(0);
    b += char(1); pointer(0); b += char(1); b += char(1);
    for (int i = 0; i < 7; ++i) pointer(0);
    node(81, 2, 1);
    put32be(b, 1); pointer(3); pointer(1);
    for (int i = 0; i < 4; ++i) pointer(0);
    pointer(5);
    node(80, 3, 1);
    pointer(0); pointer(4); put32be(b, 9000);
    b += QByteArray(8, '\0'); pointer(0);
    for (int i = 0; i < 14; ++i) b += char(i == 2); // BODY is a legal owner
    b += char(1); // integer field
    const QByteArray name("CADNext_Test_ID");
    node(79, 4, name.size()); b += name;
    node(82, 5, 3);
    put32be(b, 0xffffffffu); put32be(b, 17); put32be(b, 0x7fffffffu);
    node(14, 6);
    put32be(b, 2); pointer(0);
    put32be(b, 0); put32be(b, 0); // zero face tolerance
    for (int i = 0; i < 5; ++i) pointer(0);
    b += char('+');
    for (int i = 0; i < 5; ++i) pointer(0);
    put16be(b, 1); pointer(0);
    return b;
}

struct Member {
    QByteArray name;
    QByteArray data;
    bool compressed = false;
};

QByteArray zip(const std::vector<Member>& members) {
    QByteArray archive;
    QByteArray directory;
    for (const Member& member : members) {
        QByteArray packed = member.data;
        if (member.compressed) {
            z_stream stream{};
            assert(deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) == Z_OK);
            packed.resize(compressBound(member.data.size()));
            stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(member.data.constData()));
            stream.avail_in = member.data.size();
            stream.next_out = reinterpret_cast<Bytef*>(packed.data());
            stream.avail_out = packed.size();
            assert(deflate(&stream, Z_FINISH) == Z_STREAM_END);
            packed.resize(stream.total_out);
            deflateEnd(&stream);
        }
        const quint32 crc = crc32(0, reinterpret_cast<const Bytef*>(member.data.constData()),
                                  member.data.size());
        const quint32 offset = archive.size();
        put32(archive, 0x04034b50); put16(archive, 20); put16(archive, 0);
        put16(archive, member.compressed ? 8 : 0); put16(archive, 0); put16(archive, 0);
        put32(archive, crc); put32(archive, packed.size()); put32(archive, member.data.size());
        put16(archive, member.name.size()); put16(archive, 0);
        archive.append(member.name); archive.append(packed);

        put32(directory, 0x02014b50); put16(directory, 20); put16(directory, 20);
        put16(directory, 0); put16(directory, member.compressed ? 8 : 0);
        put16(directory, 0); put16(directory, 0);
        put32(directory, crc); put32(directory, packed.size()); put32(directory, member.data.size());
        put16(directory, member.name.size()); put16(directory, 0); put16(directory, 0);
        put16(directory, 0); put16(directory, 0); put32(directory, 0); put32(directory, offset);
        directory.append(member.name);
    }
    const quint32 directoryOffset = archive.size();
    archive.append(directory);
    put32(archive, 0x06054b50); put16(archive, 0); put16(archive, 0);
    put16(archive, members.size()); put16(archive, members.size());
    put32(archive, directory.size()); put32(archive, directoryOffset); put16(archive, 0);
    return archive;
}

QByteArray solidWorksAssembly(const QByteArray& xml) {
    QByteArray packed;
    z_stream stream{};
    assert(deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                        -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) == Z_OK);
    packed.resize(compressBound(xml.size()));
    stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(xml.constData()));
    stream.avail_in = xml.size();
    stream.next_out = reinterpret_cast<Bytef*>(packed.data());
    stream.avail_out = packed.size();
    assert(deflate(&stream, Z_FINISH) == Z_STREAM_END);
    packed.resize(stream.total_out);
    deflateEnd(&stream);

    QByteArray bytes(16, '\0');
    bytes[7] = 4;
    put32(bytes, 0);
    bytes.append(QByteArray::fromHex("140006000800"));
    put32(bytes, 0);
    put32(bytes, crc32(0, reinterpret_cast<const Bytef*>(xml.constData()),
                       xml.size()));
    put32(bytes, packed.size());
    put32(bytes, xml.size());
    const QByteArray name("swXmlContents/COMPINSTANCETREE");
    put32(bytes, name.size());
    for (char value : name) {
        const auto byte = static_cast<unsigned char>(value);
        bytes.append(char((byte >> 4) | (byte << 4)));
    }
    bytes.append(packed);
    return bytes;
}

QByteArray solidWorksChain(const QByteArray& parasolid) {
    QByteArray frame;
    frame.resize(compressBound(parasolid.size()));
    uLongf packedSize = frame.size();
    assert(compress2(reinterpret_cast<Bytef*>(frame.data()), &packedSize,
                     reinterpret_cast<const Bytef*>(parasolid.constData()),
                     parasolid.size(), Z_DEFAULT_COMPRESSION) == Z_OK);
    frame.resize(packedSize);
    QByteArray payload;
    put32(payload, 16 + 8 + frame.size());
    payload.append("0123456789ABCDEF", 16);
    put32(payload, parasolid.size());
    put32(payload, frame.size());
    payload.append(frame);
    return payload;
}

QByteArray solidWorksMember(const QByteArray& name, const QByteArray& payload,
                           bool badChecksum = false) {
    QByteArray packed;
    packed.resize(compressBound(payload.size()));
    z_stream stream{};
    assert(deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                        -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) == Z_OK);
    stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(payload.constData()));
    stream.avail_in = payload.size();
    stream.next_out = reinterpret_cast<Bytef*>(packed.data());
    stream.avail_out = packed.size();
    assert(deflate(&stream, Z_FINISH) == Z_STREAM_END);
    packed.resize(stream.total_out);
    deflateEnd(&stream);

    QByteArray bytes;
    bytes.append(QByteArray::fromHex("140006000800"));
    put32(bytes, 1);
    put32(bytes, crc32(0, reinterpret_cast<const Bytef*>(payload.constData()),
                       payload.size()) + (badChecksum ? 1 : 0));
    put32(bytes, packed.size());
    put32(bytes, payload.size());
    put32(bytes, name.size());
    for (char value : name) {
        const auto byte = static_cast<unsigned char>(value);
        bytes.append(char((byte >> 4) | (byte << 4)));
    }
    bytes.append(packed);
    return bytes;
}

QByteArray solidWorksPart(const QByteArray& parasolid, bool badChecksum = false,
                         const QByteArray& configuration = "0", const QByteArray& deltas = {}) {
    QByteArray bytes(16, '\0');
    bytes[7] = 4;
    QByteArray payload = solidWorksChain(parasolid);
    if (!deltas.isEmpty()) payload += solidWorksChain(deltas);
    return bytes + solidWorksMember("Contents/Config-" + configuration + "-Partition", payload, badChecksum);
}

// CMgrHdr2 schema 1, including Unicode MFC CStrings and the repeated class reference.
QByteArray configurationNames(const std::vector<std::pair<quint32, QString>>& names) {
    QByteArray data;
    const auto objectClass = [&](const QByteArray& name) {
        put16(data, 0xffff); put16(data, 1); put16(data, name.size()); data += name;
    };
    const auto string = [&](const QString& value) {
        assert(value.size() < 255);
        data += char(0xff); put16(data, 0xfffe); data += char(value.size());
        for (QChar c : value) put16(data, c.unicode());
    };
    objectClass("dmConfigMgrHeader_c");
    put16(data, names.size());
    for (std::size_t i = 0; i < names.size(); ++i) {
        if (i == 0) objectClass("dmConfigHeader_c");
        else put16(data, 0x8003);
        put32(data, i == 0); string(names[i].second); put32(data, names[i].first);
        put32(data, 0); string(names[i].second); put32(data, 0xffffffff); put32(data, 0);
        string({}); string({}); put32(data, 0); put32(data, 0);
    }
    put32(data, 0); put32(data, 2); // manager timestamp and format, outside the entries
    return data;
}

void verifyNativeSolidWorksConfigurationHeader() {
    using namespace cadnext::gui;
    // Independently specified archive: inactive Latin-1 root id 17, active
    // Unicode child id 29, two native stamps each, and the manager footer.
    const auto fixture = QByteArray::fromHex(
        "ffff01001300646d436f6e6669674d67724865616465725f630200ffff010010"
        "00646d436f6e6669674865616465725f63000000000141110000000500000001"
        "41ffffffff000000000000000140800000000003000000020000000380010000"
        "00fffeff0111041d00000006000000fffeff0111041100000000000000fffeff"
        "011404014ec00140800100000004000000020000007856341202000000443322"
        "11");
    SolidWorksConfigurationHeader header;
    QString error;
    QByteArray encoded;
    assert(decodeSolidWorksConfigurationHeader(fixture, header, error));
    assert(header.entries.size() == 2 && header.extendedStamps);
    assert(header.savedAt == 0x12345678 && header.trailingField == 0x11223344);
    assert(!header.entries[0].mostRecent && header.entries[0].id == 17);
    assert(header.entries[0].name == "A" && !header.entries[0].unicodeStrings[0]);
    assert(header.entries[0].modifiedStamp == 5 && header.entries[0].nativeStamps[0] == 3);
    assert(header.entries[1].mostRecent && header.entries[1].parentId == 17);
    assert(header.entries[1].name == QStringLiteral("Б") && header.entries[1].description == QStringLiteral("Д"));
    assert(header.entries[1].alternatePartName == "N" && header.entries[1].nativeField == 1);
    assert(encodeSolidWorksConfigurationHeader(header, encoded, error) && encoded == fixture);
    const auto source = header;
    for (qsizetype n = 0; n < fixture.size(); ++n) {
        // The trailing native word is optional; its complete removal is valid.
        const bool ok = decodeSolidWorksConfigurationHeader(fixture.left(n), header, error);
        assert(ok == (n == fixture.size() - 4));
        if (!ok) assert(header.entries.empty() && !error.isEmpty());
    }
    auto malformed = fixture; malformed[2] = 2;
    assert(!decodeSolidWorksConfigurationHeader(malformed, header, error));
    malformed = fixture; malformed[49] = 2; // mostRecent is Boolean, not schema/version
    assert(!decodeSolidWorksConfigurationHeader(malformed, header, error));
    malformed = fixture + char(0);
    assert(!decodeSolidWorksConfigurationHeader(malformed, header, error));
    for (int kind = 0; kind < 7; ++kind) {
        auto invalid = source;
        if (kind == 0) invalid.entries[1].id = 17;
        if (kind == 1) invalid.entries[1].name = "A";
        if (kind == 2) invalid.entries[1].parentId = 999;
        if (kind == 3) invalid.entries[0].parentId = 29;
        if (kind == 4) invalid.entries[0].mostRecent = true;
        if (kind == 5) invalid.entries[1].unicodeStrings[0] = false;
        if (kind == 6) invalid.entries[1].description.append(QChar(u'\0'));
        encoded = "stale";
        assert(!encodeSolidWorksConfigurationHeader(invalid, encoded, error));
        assert(encoded.isEmpty() && !error.isEmpty());
    }
    auto shortHeader = source;
    shortHeader.extendedStamps = false; shortHeader.trailingField.reset();
    for (auto& e : shortHeader.entries) e.nativeStamps = {};
    assert(encodeSolidWorksConfigurationHeader(shortHeader, encoded, error));
    assert(decodeSolidWorksConfigurationHeader(encoded, header, error));
    assert(!header.extendedStamps && !header.trailingField && header.entries[1].parentId == 17);
    assert(header.entries[0].name == "A" && header.entries[1].name == QStringLiteral("Б"));
    shortHeader.managerFooter = false; shortHeader.savedAt = 0;
    shortHeader.entries[0].nativeField = 0x12345678;
    assert(encodeSolidWorksConfigurationHeader(shortHeader, encoded, error));
    assert(decodeSolidWorksConfigurationHeader(encoded, header, error));
    assert(!header.managerFooter && !header.extendedStamps && header.entries[0].nativeField == 0x12345678);
}

void verifyNativeSolidWorksDocumentHeader() {
    using namespace cadnext::gui;
    // Independently specified archive: two authors, two stamps, one external
    // part, a current assembly, and an actual shared title handle (object 19).
    // MFC class ids: arrays 3, list 6, logs 8, stamps 10, external list 13,
    // external object 15, string handles 17. No production encoder builds it.
    const auto fixture = QByteArray::fromHex(
        "ffff01000a006d6f4865616465725f63ffff00000f0073755f43537472696e67"
        "417272617902000141fffeff0111040380010000ffff0100080073754f624c"
        "6973740100ffff010008006d6f4c6f67735f630200ffff010009006d6f537461"
        "6d705f630000000000000100000001430a8001000100010002000000fffeff"
        "01140401000000fffeff0122040100000003000000ffff010011006d6f457874"
        "4f626a6563744c6973745f630100ffff01000d006d6f4578744f626a6563745f"
        "63ffff010011006d6f43537472696e6748616e646c655f630b706172742e736c"
        "647072741180fffeff0614043504420430043b044c040200000300000000fffe"
        "ff000004000000010000000000000000000000fffeff074400650066006100"
        "75006c007400070000000000000005000000090000000f8011800f61737365"
        "6d626c792e736c6461736d13000300000600000000fffeff00000800000001"
        "00000000000000fffffffffffeff0121041100000000000000000000000a00"
        "000000000000000000000900000000000000000000001000000000000200"
        "000004000000010000000680000000000000000000000100000000000000"
        "0000000000000000000000000000000000000000000000000000f03f000000"
        "00000000400000000000000840000000000000f0bf00000000000000c00000"
        "0000000008c0000000000000104002000000ffffffffffffffff01000000");
    SolidWorksDocumentHeader header;
    QString error;
    QByteArray encoded;
    assert(decodeSolidWorksDocumentHeader(fixture, header, error));
    assert(header.layout == SolidWorksDocumentHeaderLayout::Standard);
    assert(header.authors.size() == 2 && header.authors[0].text == "A" && !header.authors[0].unicode);
    assert(header.authors[1].text == QStringLiteral("Б") && header.authors[1].unicode);
    assert(header.logs.size() == 1 && header.logs[0].featureId == 1);
    assert(header.logs[0].featureName.text == QStringLiteral("Т") && header.logs[0].stamps.size() == 2);
    assert(header.logs[0].stamps[1].nativeAction == 0x10001 && header.logs[0].stamps[1].authorIndex == 1);
    assert(header.nextFeatureId == 3 && header.modifiedStamp == 9);
    assert(header.references.size() == 1 && header.references[0].configurationId == 7);
    assert(header.currentDocument.documentType == 3 && header.currentDocument.configurationId == 17);
    assert(header.currentDocument.configurationName.text == QStringLiteral("С"));
    assert(header.references[0].title == header.currentDocument.title);
    assert(header.references[0].path != header.currentDocument.path);
    assert(header.nativeBounds && (*header.nativeBounds)[9] == 4 && (*header.nativeBounds)[7] == -2);
    assert(header.nativeFields[6] == 16 && header.nativeCounters[0] == 2);
    assert(encodeSolidWorksDocumentHeader(header, encoded, error) && encoded == fixture);
    const auto source = header;
    auto prefixed = fixture; prefixed.insert(16, QByteArray::fromHex("01000000"));
    assert(decodeSolidWorksDocumentHeader(prefixed, header, error) && header.nativePrefixWord == 1);
    assert(encodeSolidWorksDocumentHeader(header, encoded, error) && encoded == prefixed);
    prefixed[16] = 2;
    assert(!decodeSolidWorksDocumentHeader(prefixed, header, error));
    for (qsizetype n = 0; n < fixture.size(); ++n) {
        // This complete older layout ends immediately after bounds, with no
        // sixteen-byte trailer; removing its trailer is not a truncation.
        if (n == fixture.size() - 16 || n == fixture.size() - 4) {
            assert(decodeSolidWorksDocumentHeader(fixture.left(n), header, error));
            assert(header.layout == (n == fixture.size() - 16 ? SolidWorksDocumentHeaderLayout::StandardCompact :
                SolidWorksDocumentHeaderLayout::StandardLegacy));
            assert(header.nativeTrailer.has_value() == (n == fixture.size() - 4));
            assert(encodeSolidWorksDocumentHeader(header, encoded, error) && encoded == fixture.left(n));
            continue;
        }
        assert(!decodeSolidWorksDocumentHeader(fixture.left(n), header, error));
        assert(header.logs.empty() && header.references.empty() && !error.isEmpty());
    }
    auto malformed = fixture; malformed[2] = 2;
    assert(!decodeSolidWorksDocumentHeader(malformed, header, error));
    malformed = fixture; malformed[47] = 2; // class 2 is an object, not the CStringArray class 3
    assert(!decodeSolidWorksDocumentHeader(malformed, header, error));
    malformed = fixture; malformed[37] = 1; malformed[38] = 0x10; // 4097 authors
    assert(!decodeSolidWorksDocumentHeader(malformed, header, error));
    const auto sharedAt = fixture.indexOf(QByteArray::fromHex("130003000006000000"));
    assert(sharedAt > 0);
    malformed = fixture; malformed[sharedAt] = 22; // forward/unwritten string handle
    assert(!decodeSolidWorksDocumentHeader(malformed, header, error));
    malformed = fixture + char(0);
    assert(!decodeSolidWorksDocumentHeader(malformed, header, error));
    for (int kind = 0; kind < 12; ++kind) {
        auto invalid = source;
        if (kind == 0) invalid.logs[0].stamps[0].authorIndex = 2;
        if (kind == 1) invalid.logs[0].featureId = 4;
        if (kind == 2) invalid.currentDocument.path.reset();
        if (kind == 3) invalid.currentDocument.nativeFields[3] = 0;
        if (kind == 4) invalid.references[0].nativeFields[3] = 0xffffffff;
        if (kind == 5) invalid.authors[1].unicode = false;
        if (kind == 6) invalid.authors[0].text.append(QChar(u'\0'));
        if (kind == 7) (*invalid.nativeBounds)[0] = std::numeric_limits<double>::infinity();
        if (kind == 8) invalid.currentDocument.auxiliaryStrings.clear();
        if (kind == 9) invalid.nativeTrailer.reset();
        if (kind == 10) invalid.nativeExtension.push_back(1);
        if (kind == 11) invalid.nativePrefixWord = 2;
        encoded = "stale";
        assert(!encodeSolidWorksDocumentHeader(invalid, encoded, error));
        assert(encoded.isEmpty() && !error.isEmpty());
    }
    auto highWater = source; highWater.nextFeatureId = highWater.logs[0].featureId;
    assert(encodeSolidWorksDocumentHeader(highWater, encoded, error));
    assert(decodeSolidWorksDocumentHeader(encoded, header, error));
    assert(header.nextFeatureId == header.logs[0].featureId);
    for (const auto layout : {SolidWorksDocumentHeaderLayout::Classic, SolidWorksDocumentHeaderLayout::Extended,
                             SolidWorksDocumentHeaderLayout::ExtendedByte, SolidWorksDocumentHeaderLayout::StandardCompact,
                             SolidWorksDocumentHeaderLayout::ExtendedByteModern, SolidWorksDocumentHeaderLayout::StandardLegacy}) {
        auto varied = source; varied.layout = layout;
        const bool classic = layout == SolidWorksDocumentHeaderLayout::Classic;
        const bool compact = layout == SolidWorksDocumentHeaderLayout::StandardCompact;
        const bool modern = layout == SolidWorksDocumentHeaderLayout::ExtendedByteModern;
        const bool legacy = layout == SolidWorksDocumentHeaderLayout::StandardLegacy;
        const bool extra = layout == SolidWorksDocumentHeaderLayout::ExtendedByte || modern;
        if (extra) varied.nativePrefixWord = 1;
        for (auto* ref : {&varied.references[0], &varied.currentDocument}) {
            ref->auxiliaryStrings.resize(classic ? 1 : compact || legacy ? 2 : 3);
            ref->extendedByte = extra ? 1 : 0;
            if (modern) ref->nativeField3 = 0x12345678;
        }
        if (modern) varied.references[0].documentType = 5;
        if (classic || compact) varied.nativeTrailer.reset();
        if (legacy) (*varied.nativeTrailer)[3] = 0;
        varied.nativeExtension.assign(classic || compact || legacy ? 0 : modern ? 16 : extra ? 7 : 6, 0);
        varied.allocatedEmptyList = false;
        varied.nativeBounds.reset();
        varied.authors[0].text = QString(300, QChar(u'Ж')); varied.authors[0].unicode = true;
        assert(encodeSolidWorksDocumentHeader(varied, encoded, error));
        assert(decodeSolidWorksDocumentHeader(encoded, header, error));
        assert(header.layout == layout && !header.allocatedEmptyList && !header.nativeBounds);
        assert(header.authors[0].text == varied.authors[0].text && header.nativeExtension.size() == varied.nativeExtension.size());
        assert(header.currentDocument.extendedByte == (extra ? 1 : 0));
        assert(header.references[0].title == header.currentDocument.title);
        assert(header.currentDocument.nativeField3 == varied.currentDocument.nativeField3);
        QByteArray repeated;
        assert(encodeSolidWorksDocumentHeader(header, repeated, error) && repeated == encoded);
        if (modern) {
            varied.references[0].nativeField3.reset();
            assert(!encodeSolidWorksDocumentHeader(varied, repeated, error) && repeated.isEmpty());
        }
        if (legacy) {
            (*varied.nativeTrailer)[3] = 1;
            assert(!encodeSolidWorksDocumentHeader(varied, repeated, error) && repeated.isEmpty());
        }
    }
}

cadnext::kernel::ShapeHandle verifyNativeC3dBody(cadnext::kernel::OcctKernel& kernel, const char* name,
                 const cadnext::kernel::ShapeHandle& source) {
    using namespace cadnext::gui;
    const std::pair<const char*,cadnext::kernel::ShapeHandle> item{name,source};
    // Geometry, storage and the named record catalog are authored from scratch.
    // Application objects are absent; this is not a complete CAD document.
    std::vector<QByteArray> records; QString error;quint32 lastObjectId=0;
    if (!encodeKompasBodyRecords(kernel,{item.second},records,error,&lastObjectId))
        qFatal("Native C3D write %s: %s",item.first,qPrintable(error));
    assert(lastObjectId>0 && lastObjectId<=65535);
    KompasStoragePrefix prefix; KompasStorageImage storage;
    assert(prepareKompasStorageRecords(records,prefix,error));
    KompasCatalog catalog;
    catalog.lastObjectId=lastObjectId;
    KompasCatalogEntry directory;directory.numericName=170;directory.directory=true;
    KompasCatalogEntry bodies;bodies.numericName=300;bodies.directory=true;
    KompasCatalogEntry bodyStream;bodyStream.textName=QStringLiteral("1");bodyStream.recordIndex=0;
    bodies.children.push_back(bodyStream);directory.children.push_back(bodies);catalog.entries.push_back(directory);
    QByteArray catalogBytes;
    assert(encodeKompasCatalog(catalog,prefix,catalogBytes,error));
    assert(finishKompasStorage(prefix,catalogBytes,storage,error));
    QTemporaryDir dir; assert(dir.isValid());
    const auto path=dir.filePath(QString::fromLatin1(item.first)+".m3d");
    const auto fixture=zip({{"Contents",storage.contents},{"SysInfo",storage.sysInfo}});
    QFile out(path); assert(out.open(QIODevice::WriteOnly)); assert(out.write(fixture)==fixture.size()); out.close();
    KompasC3dResult restored;
    if (!readKompasC3dSolids(path,kernel,restored,error))
        qFatal("Native C3D read %s: %s",item.first,qPrintable(error));
    assert(restored.solids.size()==1 && kernel.isShapeValid(restored.solids[0].shape));
    GProp_GProps v1,v2,a1,a2;
    BRepGProp::VolumePropertiesGK(*kernel.findShape(item.second),v1,1e-12,true,false,true);
    BRepGProp::VolumePropertiesGK(*kernel.findShape(restored.solids[0].shape),v2,1e-12,true,false,true);
    BRepGProp::SurfaceProperties(*kernel.findShape(item.second),a1,1e-14,true);
    BRepGProp::SurfaceProperties(*kernel.findShape(restored.solids[0].shape),a2,1e-14,true);
    if(std::fabs(v2.Mass()/v1.Mass()-1)>1e-9 || std::fabs(a2.Mass()/a1.Mass()-1)>1e-9)
        qFatal("Native C3D geometry %s: V %.15g/%.15g, A %.15g/%.15g",item.first,v2.Mass(),v1.Mass(),a2.Mass(),a1.Mass());
    assert(v1.CentreOfMass().Distance(v2.CentreOfMass())<1e-9);
    return restored.solids[0].shape;
}

void verifyNativeC3dSplinePeriods() {
    using namespace cadnext;
    using gui::detail::prepareKompasSplineSurface;
    // Independent OCCT surfaces: smooth rational periods in U, V and both,
    // with a nonzero parameter origin. Compare the clamped native grid to the
    // original surface and its derivatives, including several seam crossings.
    for (int directions=1;directions<=3;++directions) {
        const bool closedU=(directions&1)!=0,closedV=(directions&2)!=0;
        TColgp_Array2OfPnt poles(1,4,1,3);
        TColStd_Array2OfReal weights(1,4,1,3);
        for(int u=1;u<=4;++u)for(int v=1;v<=3;++v) {
            poles.SetValue(u,v,{.02*std::cos(u*1.7)*(1+.1*v),.03*std::sin(v*2.1)+.002*u,.01*std::sin(u+v)});
            weights.SetValue(u,v,1+.03*u+.07*v);
        }
        TColStd_Array1OfReal uk(1,closedU?5:2),vk(1,closedV?4:2);
        TColStd_Array1OfInteger um(1,uk.Length()),vm(1,vk.Length());
        for(int i=1;i<=uk.Length();++i) {uk.SetValue(i,closedU?2+i:(i==1?3:7));um.SetValue(i,closedU?1:4);}
        for(int i=1;i<=vk.Length();++i) {vk.SetValue(i,closedV?-3+i:(i==1?-2:1));vm.SetValue(i,closedV?1:3);}
        const Handle(Geom_BSplineSurface) original=new Geom_BSplineSurface(poles,weights,uk,vk,um,vm,3,2,closedU,closedV);
        const Handle(Geom_BSplineSurface) unwrapped=Handle(Geom_BSplineSurface)::DownCast(original->Copy());
        if(closedU)unwrapped->SetUNotPeriodic();
        if(closedV)unwrapped->SetVNotPeriodic();
        kernel::DescribedSurface source;source.kind=kernel::DescribedSurface::Kind::BSpline;
        source.uPeriodic=closedU;source.vPeriodic=closedV;
        auto& b=source.bspline;
        b.uDegree=3;b.vDegree=2;b.uPoleCount=unwrapped->NbUPoles();b.vPoleCount=unwrapped->NbVPoles();
        for(int u=1;u<=b.uPoleCount;++u)for(int v=1;v<=b.vPoleCount;++v) {
            const auto p=unwrapped->Pole(u,v);b.poles.push_back({p.X(),p.Y(),p.Z()});b.weights.push_back(unwrapped->Weight(u,v));
        }
        for(int i=1;i<=unwrapped->NbUKnots();++i) {b.uKnots.push_back(unwrapped->UKnot(i));b.uMultiplicities.push_back(unwrapped->UMultiplicity(i));}
        for(int i=1;i<=unwrapped->NbVKnots();++i) {b.vKnots.push_back(unwrapped->VKnot(i));b.vMultiplicities.push_back(unwrapped->VMultiplicity(i));}
        const auto native=prepareKompasSplineSurface(source);
        assert(native.closedU==closedU && native.closedV==closedV);
        const auto& g=native.grid;
        assert(native.uKnots.size()==std::size_t(g.uPoleCount+g.uDegree+1+(closedU?g.uDegree:0)));
        assert(native.vKnots.size()==std::size_t(g.vPoleCount+g.vDegree+1+(closedV?g.vDegree:0)));
        TColgp_Array2OfPnt grid(1,g.uPoleCount,1,g.vPoleCount);
        TColStd_Array2OfReal gw(1,g.uPoleCount,1,g.vPoleCount);
        for(int u=1;u<=g.uPoleCount;++u)for(int v=1;v<=g.vPoleCount;++v) {
            const auto i=std::size_t((u-1)*g.vPoleCount+v-1);const auto& p=g.poles[i];grid.SetValue(u,v,{p.x,p.y,p.z});gw.SetValue(u,v,g.weights[i]);
        }
        TColStd_Array1OfReal gu(1,int(g.uKnots.size())),gv(1,int(g.vKnots.size()));
        TColStd_Array1OfInteger gum(1,gu.Length()),gvm(1,gv.Length());
        for(int i=1;i<=gu.Length();++i){gu.SetValue(i,g.uKnots[i-1]);gum.SetValue(i,g.uMultiplicities[i-1]);}
        for(int i=1;i<=gv.Length();++i){gv.SetValue(i,g.vKnots[i-1]);gvm.SetValue(i,g.vMultiplicities[i-1]);}
        const Handle(Geom_BSplineSurface) clamped=new Geom_BSplineSurface(grid,gw,gu,gv,gum,gvm,3,2,false,false);
        for(int i=-32;i<=64;++i)for(int j=-16;j<=32;++j) {
            double u=3+4*i/32.0,v=-2+3*j/16.0;
            if(!closedU&&(u<3||u>7))continue;
            if(!closedV&&(v<-2||v>1))continue;
            gp_Pnt p,q;gp_Vec pu,pv,qu,qv;
            original->D1(u,v,p,pu,pv);
            native.support->D1(u,v,q,qu,qv);
            assert(p.Distance(q)<1e-13 && (pu-qu).Magnitude()<1e-12 && (pv-qv).Magnitude()<1e-12);
            original->PeriodicNormalization(u,v);
            clamped->D1(u,v,q,qu,qv);
            assert(p.Distance(q)<1e-13 && (pu-qu).Magnitude()<1e-12 && (pv-qv).Magnitude()<1e-12);
        }
        auto damaged=source;
        if(closedU)damaged.bspline.weights[std::size_t((b.uPoleCount-1)*b.vPoleCount)]+=1e-12;
        else damaged.bspline.weights[std::size_t(b.vPoleCount-1)]+=1e-12;
        bool rejected=false;
        try{prepareKompasSplineSurface(damaged);}catch(const std::runtime_error&){rejected=true;}
        assert(rejected);
    }
}

cadnext::kernel::ShapeHandle rationalProfileSolid(cadnext::kernel::OcctKernel& kernel) {
    // This weight is deliberately different from a circular conic. Green's
    // integral gives the profile area 1/3 + 2*pi/(9*sqrt(3)), scaled by L^2.
    constexpr double size=.02,height=.03;
    TColgp_Array1OfPnt poles(1,3);poles.SetValue(1,{size,0,0});
    poles.SetValue(2,{size,size,0});poles.SetValue(3,{0,size,0});
    TColStd_Array1OfReal weights(1,3),knots(1,2);weights.Init(1);weights.SetValue(2,.5);
    knots.SetValue(1,0);knots.SetValue(2,1);
    TColStd_Array1OfInteger multiplicities(1,2);multiplicities.Init(3);
    const Handle(Geom_BSplineCurve) curve=new Geom_BSplineCurve(poles,weights,knots,multiplicities,2,false);
    BRepBuilderAPI_MakeWire wire;
    wire.Add(BRepBuilderAPI_MakeEdge(curve).Edge());
    wire.Add(BRepBuilderAPI_MakeEdge(gp_Pnt(0,size,0),gp_Pnt(0,0,0)).Edge());
    wire.Add(BRepBuilderAPI_MakeEdge(gp_Pnt(0,0,0),gp_Pnt(size,0,0)).Edge());
    const auto face=BRepBuilderAPI_MakeFace(wire.Wire(),true).Face();
    const auto prism=BRepPrimAPI_MakePrism(face,gp_Vec(0,0,height)).Shape();
    TColgp_Array2OfPnt grid(1,3,1,2);TColStd_Array2OfReal gridWeights(1,3,1,2);
    for(int u=1;u<=3;++u)for(int v=1;v<=2;++v) {
        auto p=poles.Value(u);p.SetZ((v-1)*height);grid.SetValue(u,v,p);
        gridWeights.SetValue(u,v,weights.Value(u));
    }
    TColStd_Array1OfInteger vMult(1,2);vMult.Init(2);
    const Handle(Geom_BSplineSurface) lateral=new Geom_BSplineSurface(
        grid,gridWeights,knots,knots,multiplicities,vMult,2,1,false,false);
    BRepBuilderAPI_Sewing sewing(1e-10);
    for(TopExp_Explorer it(prism,TopAbs_FACE);it.More();it.Next()) {
        if(BRepAdaptor_Surface(TopoDS::Face(it.Current())).GetType()==GeomAbs_SurfaceOfExtrusion)
            sewing.Add(BRepBuilderAPI_MakeFace(lateral,0,1,0,1,1e-10).Face());
        else sewing.Add(it.Current());
    }
    sewing.Perform();assert(sewing.SewedShape().ShapeType()==TopAbs_SHELL);
    auto solid=BRepBuilderAPI_MakeSolid(TopoDS::Shell(sewing.SewedShape())).Solid();
    assert(BRepLib::OrientClosedSolid(solid));
    const auto handle=kernel.adoptShape(solid,"rational-profile");
    assert(kernel.isShapeValid(handle));
    GProp_GProps volume;BRepGProp::VolumePropertiesGK(solid,volume,1e-12,true);
    const double expected=size*size*height*(1.0/3+2*M_PI/(9*std::sqrt(3.)));
    if(std::fabs(volume.Mass()/expected-1)>1e-12)
        qFatal("Rational profile volume %.17g, expected %.17g",volume.Mass(),expected);
    return handle;
}

cadnext::kernel::ShapeHandle periodicSplineSolid(cadnext::kernel::OcctKernel& kernel) {
    // Two lateral faces share one smooth periodic support. Their genuine
    // common edges carry two pcurves; they are not seams of either face. One
    // face and its cap edges cross the support's period boundary at u=7.
    TColgp_Array2OfPnt poles(1,4,1,2);
    TColStd_Array2OfReal weights(1,4,1,2);
    const gp_Pnt corners[4]={{.01,.01,0},{-.01,.01,0},{-.01,-.01,0},{.01,-.01,0}};
    for(int u=1;u<=4;++u)for(int v=1;v<=2;++v) {
        poles.SetValue(u,v,{corners[u-1].X(),corners[u-1].Y(),.03*(v-1)});weights.SetValue(u,v,1);
    }
    TColStd_Array1OfReal uk(1,5),vk(1,2);
    TColStd_Array1OfInteger um(1,5),vm(1,2);
    for(int i=1;i<=5;++i){uk.SetValue(i,2+i);um.SetValue(i,1);}
    vk.SetValue(1,0);vk.SetValue(2,1);vm.Init(2);
    const Handle(Geom_BSplineSurface) surface=new Geom_BSplineSurface(poles,weights,uk,vk,um,vm,3,1,true,false);
    BRepBuilderAPI_Sewing sewing(1e-10);
    sewing.Add(BRepBuilderAPI_MakeFace(surface,3.25,5.25,0,1,1e-10).Face());
    sewing.Add(BRepBuilderAPI_MakeFace(surface,5.25,7.25,0,1,1e-10).Face());
    for(double v:{0.,1.}) {
        const auto ring=surface->VIso(v);
        BRepBuilderAPI_MakeWire wire;
        wire.Add(BRepBuilderAPI_MakeEdge(ring,3.25,5.25).Edge());
        wire.Add(BRepBuilderAPI_MakeEdge(ring,5.25,7.25).Edge());
        sewing.Add(BRepBuilderAPI_MakeFace(wire.Wire(),true).Face());
    }
    sewing.Perform();
    assert(sewing.SewedShape().ShapeType()==TopAbs_SHELL);
    auto solid=BRepBuilderAPI_MakeSolid(TopoDS::Shell(sewing.SewedShape())).Solid();
    assert(BRepLib::OrientClosedSolid(solid));
    const auto handle=kernel.adoptShape(solid,"periodic-spline");
    assert(kernel.isShapeValid(handle));
    return handle;
}

cadnext::kernel::ShapeHandle mixedUvSplineSolid(cadnext::kernel::OcctKernel& kernel,
                                              bool nonlinearParameter=false,
                                              double delta=3e-8, double nativeTolerance=1e-7) {
    using namespace cadnext;
    using namespace cadnext::kernel;
    // A triangular extrusion with a cubic side. The top cap's boundary is
    // 30 nm away from the shared spatial curve between its exact endpoints,
    // within the declared 100 nm precision. Only that curved cap edge has an
    // explicit UV boundary; two straight edges complete its wire.
    constexpr double height=.03;
    const auto spline=[nonlinearParameter](double z) {
        BSplineCurveDefinition d;
        d.degree=3;
        d.poles={{0,0,z},{.005,.01,z},{.015,.01,z},{.02,0,z}};
        if(nonlinearParameter)
            d.poles={{0,0,z},{.02/6,0,z},{.02/3,0,z},{.02,0,z}};
        d.weights={1,1,1,1};d.knots={3,7};d.multiplicities={4,4};
        return d;
    };
    const Vector3 a{0,0,0}, b{.02,0,0}, c{.01,-.01,0};
    const Vector3 ah{0,0,height}, bh{.02,0,height}, ch{.01,-.01,height};
    const auto line=[nativeTolerance](Vector3 from,Vector3 to) {
        AnalyticEdgeSegment e;e.start=from;e.end=to;e.tolerance=nativeTolerance;return e;
    };
    const auto curve=[&](double z,bool forward) {
        AnalyticEdgeSegment e;e.kind=AnalyticEdgeKind::BSpline;e.bspline=spline(z);
        e.start={forward?0:.02,0,z};e.end={forward?.02:0,0,z};e.forward=forward;
        e.curveFirst=3;e.curveLast=7;e.tolerance=nativeTolerance;
        return e;
    };
    AnalyticFacePatch bottom;
    bottom.kind=AnalyticFacePatch::Kind::Plane;bottom.normal={0,0,-1};bottom.xAxis={1,0,0};
    bottom.loops={{curve(0,true),line(b,c),line(c,a)}};
    AnalyticFacePatch top;
    top.kind=AnalyticFacePatch::Kind::Plane;top.origin={0,0,height};
    top.normal={0,0,1};top.xAxis={1,0,0};
    top.loops={{line(ah,ch),line(ch,bh),curve(height,false)}};
    auto uv=spline(0);
    if(!nonlinearParameter) {uv.poles[1].y+=delta;uv.poles[2].y+=delta;}
    top.loops[0][2].pcurve=std::move(uv);
    AnalyticFacePatch ac;
    ac.kind=AnalyticFacePatch::Kind::Plane;ac.normal={-1,-1,0};ac.xAxis={1,-1,0};
    ac.loops={{line(a,c),line(c,ch),line(ch,ah),line(ah,a)}};
    AnalyticFacePatch cb;
    cb.kind=AnalyticFacePatch::Kind::Plane;cb.origin=c;cb.normal={1,-1,0};cb.xAxis={1,1,0};
    cb.loops={{line(c,b),line(b,bh),line(bh,ch),line(ch,c)}};
    AnalyticFacePatch lateral;
    lateral.kind=AnalyticFacePatch::Kind::BSpline;lateral.reversed=true;
    lateral.normal={0,0,1};lateral.xAxis={1,0,0};
    auto& s=lateral.bspline;
    s.uDegree=nonlinearParameter?2:3;s.vDegree=1;
    s.uPoleCount=nonlinearParameter?3:4;s.vPoleCount=2;
    const std::vector<Vector3> supportPoles=nonlinearParameter
        ? std::vector<Vector3>{{0,0,0},{.01,0,0},{.02,0,0}} : spline(0).poles;
    for(const auto& p:supportPoles) {
        s.poles.push_back(p);s.poles.push_back({p.x,p.y,height});
        s.weights.push_back(1);s.weights.push_back(1);
    }
    s.uKnots={3,7};s.vKnots={0,1};
    s.uMultiplicities={s.uDegree+1,s.uDegree+1};s.vMultiplicities={2,2};
    lateral.loops={{curve(0,true),line(b,bh),curve(height,false),line(ah,a)}};
    const auto result=kernel.makeAnalyticSolid({bottom,top,ac,cb,lateral});
    if(!result.isOk())qFatal("Mixed UV solid: %s",result.error().message.c_str());
    assert(kernel.isShapeValid(result.value()));
    bool found=false;
    for(TopExp_Explorer f(*kernel.findShape(result.value()),TopAbs_FACE);f.More();f.Next()) {
        const BRepAdaptor_Surface surface(TopoDS::Face(f.Current()));
        if(surface.GetType()!=GeomAbs_Plane ||
           std::fabs(surface.Plane().Location().Z()-height)>1e-10)continue;
        GProp_GProps area;BRepGProp::SurfaceProperties(f.Current(),area,1e-14,true);
        // Green's integral of the cubic plus the two lines, evaluated
        // analytically. Projecting the cap back onto the spatial curve loses
        // .0105*delta square metres and must fail this check.
        const double expected=nonlinearParameter?.0001:.0001+.0105*(.01+delta);
        assert(std::fabs(area.Mass()/expected-1)<1e-12);
        found=true;
    }
    assert(found);
    return result.value();
}
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    cadnext::kernel::OcctKernel kernel;
    verifyNativeSolidWorksConfigurationHeader();
    verifyNativeSolidWorksDocumentHeader();
    verifyNativeC3dSplinePeriods();
    const auto box = kernel.makeBox({1000, 1000, 1000});
    assert(box.isOk());
    {
        cadnext::gui::ParasolidXtTopology topology;
        QString error;
        const auto fixture = integerAttributeBodyFixture();
        if (!cadnext::gui::readParasolidXtTransmitStream(fixture, topology, error))
            qFatal("Integer attribute fixture: %s", qPrintable(error));
        assert(topology.bodies.size() == 1 && topology.attributes.size() == 1);
        const auto& attribute = topology.attributes.front();
        assert(attribute.ownerIndex == topology.bodies.front().index);
        assert(attribute.definition == "CADNext_Test_ID");
        assert((attribute.integers == std::vector<qint32>{-1, 17, 0x7fffffff}));
        assert(attribute.strings.empty() && attribute.reals.empty());
        assert(attribute.definitionIndex == 3 && attribute.fieldIndices == std::vector<quint32>{5});
        assert(topology.bodies.front().attributeHead == 2);
        assert(topology.attributeDefinitions.size() == 1);
        const auto& definition = topology.attributeDefinitions.front();
        assert(definition.index == 3 && definition.name == "CADNext_Test_ID" && definition.typeId == 9000);
        assert(definition.fieldTypes == std::vector<quint8>{1});
        for (std::size_t i = 0; i < definition.legalOwners.size(); ++i)
            assert(definition.legalOwners[i] == (i == 2));
        for (const auto action : definition.actions) assert(action == 0);
        assert(!cadnext::gui::readParasolidXtTransmitStream(fixture + char(0), topology, error));
        assert(topology.nodeTypes.isEmpty() && topology.attributes.empty() && topology.attributeDefinitions.empty());
    }
    {
        using namespace cadnext::gui;
        // More than one native list block, both attribute-field layouts,
        // and signed extrema. The expected list structure follows XT's
        // specification independently of the writer's internal graph.
        std::vector<ParasolidXtIntegerBodyAttribute> attributes;
        for (int i = 0; i < 21; ++i)
            attributes.push_back({"CADNext_Test_" + std::to_string(i),
                {std::numeric_limits<std::int32_t>::min(), i, std::numeric_limits<std::int32_t>::max()}, i % 2 == 0});
        for (const bool partition : {false, true}) {
            const auto encoded = partition ? encodeParasolidXtPartition(kernel, box.value(), attributes)
                                           : encodeParasolidXtBodyStream(kernel, box.value(), attributes);
            if (!encoded.isOk()) qFatal("Body attributes: %s", encoded.error().message.c_str());
            ParasolidXtTopology graph;
            QString error;
            const auto bytes = QByteArray::fromStdString(encoded.value());
            assert(partition ? readParasolidXtTopology(bytes, graph, error)
                             : readParasolidXtTransmitStream(bytes, graph, error));
            assert(graph.bodies.size() == 1 && graph.attributes.size() == 21 &&
                graph.attributeDefinitions.size() == 21 && graph.attributeLists.size() == 1 &&
                graph.attributeListBlocks.size() == 2);
            const auto& body = graph.bodies.front();
            const auto& list = graph.attributeLists.front();
            assert(body.attributeHead == graph.attributes.front().index && body.attributeChains == list.index);
            assert(list.owner == body.index && list.type == 4 && list.length == 21 && list.blockLength == 20);
            assert(list.firstBlock == graph.attributeListBlocks[0].index);
            for (std::size_t i = 0; i < 21; ++i) {
                const auto& actual = graph.attributes[i];
                const auto& definition = graph.attributeDefinitions[i];
                assert(actual.ownerIndex == body.index && actual.definitionIndex == definition.index);
                assert(actual.definition.toStdString() == attributes[i].name && definition.name == actual.definition);
                assert(actual.integers == attributes[i].values && actual.strings.empty() && actual.reals.empty());
                assert(actual.previous == (i ? graph.attributes[i - 1].index : 0));
                assert(actual.next == (i + 1 < 21 ? graph.attributes[i + 1].index : 0));
                assert(actual.nextOfType == 0 && actual.previousOfType == 0);
                assert(definition.next == (i + 1 < 21 ? graph.attributeDefinitions[i + 1].index : 0));
                assert(definition.typeId == 9000);
                const std::array<quint8, 8> actions{0, 0, 0, 0, 3, 5, 0, 0};
                assert(definition.actions == actions);
                for (std::size_t owner = 0; owner < 14; ++owner)
                    assert(definition.legalOwners[owner] == (owner == 2));
                assert(definition.fieldTypes == (i % 2 == 0 ? std::vector<quint8>{9, 1} : std::vector<quint8>{1}));
                assert(actual.fieldIndices.size() == definition.fieldTypes.size());
                if (i % 2 == 0) assert(actual.fieldIndices.front() == 0);
                assert(graph.nodeTypes.value(actual.fieldIndices.back()) == 82);
            }
            for (std::size_t block = 0; block < 2; ++block) {
                const auto& actual = graph.attributeListBlocks[block];
                assert(actual.count == (block ? 1 : 20) && actual.entries.size() == 20 && actual.indexMapOffset == 0);
                assert(actual.next == (block ? 0 : graph.attributeListBlocks[1].index));
                for (std::size_t entry = 0; entry < 20; ++entry)
                    assert(actual.entries[entry] == (entry < actual.count
                        ? graph.attributes[block * 20 + entry].index : 0));
            }
            assert(graph.worldAttributeDefinitionHead == (partition ? graph.attributeDefinitions.front().index : 0));
            cadnext::kernel::ShapeHandle restored;
            assert(buildParasolidXtAnalyticSolid(graph, kernel, restored, error));
            const auto mass = kernel.volumeProperties(restored);
            assert(mass.isOk() && std::fabs(mass.value().volumeM3 / 1e9 - 1) < 1e-12);
        }
        auto invalid = attributes;
        invalid.back().name = invalid.front().name;
        assert(!encodeParasolidXtBodyStream(kernel, box.value(), invalid).isOk());
        invalid = attributes; invalid.front().values.clear();
        assert(!encodeParasolidXtPartition(kernel, box.value(), invalid).isOk());
        invalid = attributes; invalid.front().name += '\0';
        assert(!encodeParasolidXtBodyStream(kernel, box.value(), invalid).isOk());
    }
    {
        using namespace cadnext::gui;
        constexpr double angle = 1.1;
        const auto cone = kernel.adoptShape(BRepPrimAPI_MakeCone(.02, .008, .03, angle).Shape(),
            "native-cone-uv");
        const auto stream = encodeParasolidXtBodyStream(kernel, cone);
        assert(stream.isOk());
        ParasolidXtTopology topology;
        QString error;
        assert(readParasolidXtTransmitStream(QByteArray::fromStdString(stream.value()), topology, error));
        QHash<quint32, const ParasolidXtAnalyticGeometry*> nodes;
        for (const auto& node : topology.analyticGeometry) nodes[node.index] = &node;
        int coneBoundaries = 0;
        for (const auto& node : topology.analyticGeometry) {
            if (node.type != 137) continue;
            const auto* surface = nodes.value(node.links.value("surface"), nullptr);
            if (!surface || surface->type != 52) continue;
            ++coneBoundaries;
            const auto* curve = nodes.value(node.links.value("b_curve"), nullptr);
            assert(curve);
            const auto* nurbs = nodes.value(curve->links.value("nurbs"), nullptr);
            assert(nurbs && nurbs->integers.value("degree") == 1 &&
                nurbs->integers.value("n_vertices") == 2 && nurbs->integers.value("vertex_dim") == 2);
            const auto* vertices = nodes.value(nurbs->links.value("bspline_vertices"), nullptr);
            assert(vertices);
            const auto uv = vertices->realArrays.value("vertices");
            const auto origin = surface->vectors.value("pvec"), axis = surface->vectors.value("axis");
            for (int end = 0; end < 2; ++end) {
                // Independent native-coordinate check against the primitive:
                // both generator endpoints are at z=0 or .03, with the exact
                // corresponding radius. Mutually inverse writer/reader errors
                // must not be able to pass merely by cancelling one another.
                const double axial = uv.at(std::size_t(2 * end + 1));
                const double z = origin[2] + axis[2] * axial;
                assert(std::min(std::fabs(z), std::fabs(z - .03)) < 1e-12);
                const double radius = surface->reals.value("radius") + axial *
                    surface->reals.value("sin_half_angle") / surface->reals.value("cos_half_angle");
                assert(std::fabs(radius - (.02 - z * .012 / .03)) < 1e-12);
            }
        }
        assert(coneBoundaries == 2);
        cadnext::kernel::ShapeHandle restored;
        assert(buildParasolidXtAnalyticSolid(topology, kernel, restored, error));
        assert(kernel.isShapeValid(restored));
        const auto mass = kernel.volumeProperties(restored);
        const double expected = angle * .03 * (.02 * .02 + .02 * .008 + .008 * .008) / 6;
        assert(mass.isOk() && std::fabs(mass.value().volumeM3 / expected - 1) < 1e-12);
    }
    {
        using namespace cadnext::gui;
        const auto small = kernel.makeCylinder({12, 35});
        assert(small.isOk());
        const QString name = QStringLiteral("Импорт 🚀 ") + QString(255, QChar(u'я'));
        SolidWorksWriteSection section;
        QString error;
        assert(encodeSolidWorksImportedFeatureBodySection(kernel, 17, name,
            {box.value(), small.value()}, section, error, SolidWorksFeatureBodyLayout::GroupedBodies,
            {{17, 201}, {17, 202}}));
        assert(section.name == "Config-17-FeatureBodies/LocalBodies");
        std::vector<SolidWorksFeatureBodies> features;
        assert(decodeSolidWorksFeatureBodies(section.data, features, error));
        assert(features.size() == 1 && features[0].featureName == name && features[0].bodies.size() == 2);
        const std::vector<cadnext::kernel::ShapeHandle> originals{box.value(), small.value()};
        for (std::size_t i = 0; i < originals.size(); ++i) {
            ParasolidXtTopology topology;
            assert(readParasolidXtTransmitStream(features[0].bodies[i].parasolid, topology, error));
            assert(topology.bodyCount == 1);
            assert(topology.attributes.size() == 2);
            std::map<QByteArray, qint32> ids;
            for (const auto& attribute : topology.attributes) {
                assert(attribute.ownerIndex == topology.bodies.front().index && attribute.integers.size() == 1);
                assert(attribute.fieldIndices.size() == 2 && attribute.fieldIndices.front() == 0);
                ids[attribute.definition] = attribute.integers.front();
            }
            assert(ids.at("ATOM_ID_2001") == 201 + qint32(i) && ids.at("LAST_BODY_MODIFYING_FEATURE_ID") == 17);
            assert(topology.nodeTypes.value(1) == 12 && !topology.nodeTypes.values().contains(101));
            ParasolidXtTopology wrongRepresentation;
            assert(!readParasolidXtTopology(features[0].bodies[i].parasolid, wrongRepresentation, error));
            cadnext::kernel::ShapeHandle restored;
            assert(buildParasolidXtAnalyticSolid(topology, kernel, restored, error));
            const auto before = kernel.volumeProperties(originals[i]);
            const auto after = kernel.volumeProperties(restored);
            assert(before.isOk() && after.isOk());
            assert(std::fabs(after.value().volumeM3 / before.value().volumeM3 - 1) < 1e-12);
        }
        const auto partition = encodeParasolidXtPartition(kernel, box.value());
        assert(partition.isOk());
        ParasolidXtTopology wrongRepresentation;
        assert(!readParasolidXtTransmitStream(QByteArray::fromStdString(partition.value()),
            wrongRepresentation, error));
        assert(wrongRepresentation.bodyCount == 0);
        assert(!readParasolidXtTransmitStream(features[0].bodies[0].parasolid.left(100),
            wrongRepresentation, error) && wrongRepresentation.nodeTypes.isEmpty());
        // Independent fixture: two features, nested wrapper extents, an ANSI
        // name and non-default scalar metadata. No native CAD binary is stored
        // in the repository. Geometry was produced by our own XT writer above.
        QByteArray fixture; put32(fixture, 2);
        QByteArray singleFixture; put32(singleFixture, 2);
        for (unsigned i = 0; i < 2; ++i) {
            const auto entryStart = fixture.size();
            fixture += char(1); fixture += char('A' + i);
            put32(fixture, 19 + i); put32(fixture, 1);
            const auto& body = features[0].bodies[i].parasolid;
            uLongf packedSize = compressBound(body.size());
            QByteArray packed(qsizetype(packedSize), '\0');
            assert(compress2(reinterpret_cast<Bytef*>(packed.data()), &packedSize,
                reinterpret_cast<const Bytef*>(body.constData()), body.size(), Z_BEST_SPEED) == Z_OK);
            packed.resize(qsizetype(packedSize));
            put32(fixture, 27 + i); fixture += char(2);
            put32(fixture, packedSize + 37); fixture += char(3); put32(fixture, packedSize + 32);
            fixture += QByteArray::fromHex("231dd571da8148a2a85898b21b89ef99");
            put32(fixture, body.size()); put32(fixture, packedSize); fixture += packed;
            put32(fixture, 41 + i); put32(fixture, 51 + i);
            // The older layout has the same named body wrapper, without the
            // eight-byte group field and body count preceding it.
            singleFixture += fixture.mid(entryStart, 2);
            singleFixture += fixture.mid(entryStart + 10);
        }
        SolidWorksFeatureBodyLayout layout;
        assert(decodeSolidWorksFeatureBodies(fixture, features, error, &layout));
        assert(layout == SolidWorksFeatureBodyLayout::GroupedBodies);
        assert(features.size() == 2 && features[1].featureName == "B" && !features[1].unicodeName);
        assert(features[0].nativeField == 19 && features[1].bodies[0].nativeField == 28);
        assert(features[0].bodies[0].nativeByte == 2 && features[0].bodies[0].wrapperByte == 3);
        assert(features[1].bodies[0].nativeTrailer[1] == 52);
        QByteArray encoded;
        assert(encodeSolidWorksFeatureBodies(features, encoded, error));
        std::vector<SolidWorksFeatureBodies> restored;
        assert(decodeSolidWorksFeatureBodies(encoded, restored, error));
        assert(restored[1].bodies[0].parasolid == features[1].bodies[0].parasolid);
        assert(restored[0].bodies[0].nativeTrailer == features[0].bodies[0].nativeTrailer);
        std::vector<SolidWorksFeatureBodies> singles;
        assert(decodeSolidWorksFeatureBodies(singleFixture, singles, error, &layout));
        assert(layout == SolidWorksFeatureBodyLayout::SingleBodyEntries && singles.size() == 2);
        assert(singles[0].nativeField == 0 && singles[0].bodies[0].nativeField == 27);
        assert(singles[1].bodies[0].parasolid == features[1].bodies[0].parasolid);
        assert(encodeSolidWorksFeatureBodies(singles, encoded, error, layout));
        assert(decodeSolidWorksFeatureBodies(encoded, restored, error, &layout));
        assert(layout == SolidWorksFeatureBodyLayout::SingleBodyEntries);
        assert(restored[1].bodies[0].nativeTrailer == singles[1].bodies[0].nativeTrailer);
        singles[0].nativeField = 1;
        assert(!encodeSolidWorksFeatureBodies(singles, encoded, error, layout) && encoded.isEmpty());
        auto bad = fixture; bad[21] ^= 1; // first outer length
        assert(!decodeSolidWorksFeatureBodies(bad, restored, error) && restored.empty());
        bad = fixture; bad[26] ^= 1; // inner length
        assert(!decodeSolidWorksFeatureBodies(bad, restored, error));
        bad = fixture; bad[30] ^= 1; // wrapper GUID
        assert(!decodeSolidWorksFeatureBodies(bad, restored, error));
        bad = fixture; bad[fixture.size() - 9] ^= 1; // final zlib checksum
        assert(!decodeSolidWorksFeatureBodies(bad, restored, error));
        bad = fixture; bad.chop(1);
        assert(!decodeSolidWorksFeatureBodies(bad, restored, error));
        bad = fixture; bad += char(0);
        assert(!decodeSolidWorksFeatureBodies(bad, restored, error));
        features[1].featureName = features[0].featureName;
        assert(!encodeSolidWorksFeatureBodies(features, encoded, error) && encoded.isEmpty());
        assert(!encodeSolidWorksImportedFeatureBodySection(kernel, 17, name, {}, section, error));
        assert(section.name.isEmpty() && section.data.isEmpty());
        assert(!encodeSolidWorksImportedFeatureBodySection(kernel, 17, name, {{}}, section, error));
        assert(encodeSolidWorksImportedFeatureBodySection(kernel, 17, name, {small.value()}, section, error,
            SolidWorksFeatureBodyLayout::SingleBodyEntries));
        assert(decodeSolidWorksFeatureBodies(section.data, restored, error, &layout));
        assert(layout == SolidWorksFeatureBodyLayout::SingleBodyEntries);
        assert(!encodeSolidWorksImportedFeatureBodySection(kernel, 17, name,
            {box.value(), small.value()}, section, error, SolidWorksFeatureBodyLayout::SingleBodyEntries));
        for (const std::vector<SolidWorksImportedBodyIdentity> invalid : {
            std::vector<SolidWorksImportedBodyIdentity>{{17, 201}},
            {{17, 201}, {17, 201}}, {{17, 201}, {18, 202}}, {{17, 201}, {17, 0}}}) {
            assert(!encodeSolidWorksImportedFeatureBodySection(kernel, 17, name,
                {box.value(), small.value()}, section, error, SolidWorksFeatureBodyLayout::GroupedBodies, invalid));
            assert(section.name.isEmpty() && section.data.isEmpty());
        }
    }
    // The native writer builds every configuration's own current geometry and
    // CMgrHdr2, including MFC string lengths that cannot fit into one byte.
    // This deliberately synthetic envelope tests the sections; it does not
    // stand in for a complete native SOLIDWORKS document.
    {
        using namespace cadnext::gui;
        const auto small = kernel.makeBox({20, 30, 40});
        assert(small.isOk());
        const QString name = QStringLiteral("Конфигурация 🚀 ") + QString(255, QChar(u'я'));
        const QString longName(4096, QChar(u'ж'));
        std::vector<SolidWorksWriteSection> sections;
        QString error;
        const std::vector<SolidWorksWriteConfiguration> configs{
            {17, name, box.value(), SolidWorksImportedBodyIdentity{17, 201}},
            {29, longName, small.value(), SolidWorksImportedBodyIdentity{18, 202}}};
        assert(encodeSolidWorksConfigurationSections(kernel, configs, sections, error));
        assert(sections.size() == 3 && sections.front().name == "Contents/CMgrHdr2");
        assert(sections[1].data.mid(4, 16) == QByteArray::fromHex("231dd571da8148a2a85898b21b89ef99"));
        QByteArray fixture(16, '\0');
        fixture[7] = 4;
        for (const auto& section : sections) fixture += solidWorksMember(section.name, section.data);
        QTemporaryDir dir;
        assert(dir.isValid());
        const QString path = dir.filePath(QStringLiteral("native-sections.SLDPRT"));
        QFile out(path);
        assert(out.open(QIODevice::WriteOnly) && out.write(fixture) == fixture.size());
        out.close();
        std::vector<SolidWorksConfiguration> readConfigs;
        assert(readSolidWorksPartConfigurations(path, readConfigs, error));
        assert(readConfigs.size() == 2 && readConfigs[0].id == "17" && readConfigs[0].name == name);
        assert(readConfigs[1].id == "29" && readConfigs[1].name == longName);
        std::vector<SolidWorksBodyStream> streams;
        assert(readSolidWorksPartBodyStreams(path, streams, error));
        assert(streams.size() == 2);
        for (std::size_t i = 0; i < streams.size(); ++i) {
            ParasolidXtTopology graph;
            assert(readParasolidXtTopology(streams[i].parasolid, graph, error));
            std::map<QByteArray, qint32> ids;
            for (const auto& attribute : graph.attributes) {
                assert(attribute.ownerIndex == graph.bodies.front().index && attribute.integers.size() == 1);
                ids[attribute.definition] = attribute.integers.front();
            }
            assert(ids.at("ATOM_ID_2001") == 201 + qint32(i) && ids.at("LAST_BODY_MODIFYING_FEATURE_ID") == 17 + qint32(i));
        }
        for (const auto& config : configs) {
            cadnext::kernel::ShapeHandle restored;
            assert(readSolidWorksAnalyticPart(path, kernel, restored, error, nullptr, config.name));
            assert(kernel.isShapeValid(restored));
            const auto expected = kernel.volumeProperties(config.shape);
            const auto actual = kernel.volumeProperties(restored);
            assert(expected.isOk() && actual.isOk());
            assert(std::fabs(actual.value().volumeM3 / expected.value().volumeM3 - 1.0) < 1e-12);
        }
        // The same own sections in a complete CFB storage container. Its
        // application graph remains a component fixture, not a native document.
        CompoundFile compound;
        compound.entries.push_back({"Contents",CompoundFileEntry::Kind::Storage});
        for(const auto& section:sections)
            compound.entries.push_back({QString::fromUtf8(section.name),CompoundFileEntry::Kind::Stream,section.data});
        QByteArray compoundBytes;assert(encodeCompoundFile(compound,compoundBytes,error));
        const auto compoundPath=dir.filePath("compound-sections.SLDPRT");QFile compoundOut(compoundPath);
        assert(compoundOut.open(QIODevice::WriteOnly) && compoundOut.write(compoundBytes)==compoundBytes.size());compoundOut.close();
        assert(readSolidWorksPartConfigurations(compoundPath,readConfigs,error) && readConfigs.size()==2);
        for(std::size_t i=0;i<configs.size();++i) {
            assert(readConfigs[i].id==QString::number(configs[i].id) && readConfigs[i].name==configs[i].name);
            cadnext::kernel::ShapeHandle restored;
            assert(readSolidWorksAnalyticPart(compoundPath,kernel,restored,error,nullptr,configs[i].name));
            const auto expected=kernel.volumeProperties(configs[i].shape),actual=kernel.volumeProperties(restored);
            assert(kernel.isShapeValid(restored) && expected.isOk() && actual.isOk());
            assert(std::fabs(actual.value().volumeM3/expected.value().volumeM3-1)<1e-12);
        }
        const QString authoredPath=dir.filePath("authored-configuration-container.SLDPRT");
        assert(writeSolidWorksConfigurationContainer(kernel,configs,authoredPath,error));
        QFile authored(authoredPath);assert(authored.open(QIODevice::ReadOnly));
        assert(authored.read(8)==QByteArray::fromHex("d0cf11e0a1b11ae1"));authored.close();
        assert(readSolidWorksPartConfigurations(authoredPath,readConfigs,error) && readConfigs.size()==2);
        auto invalid = configs;
        invalid[1].id = invalid[0].id;
        assert(!encodeSolidWorksConfigurationSections(kernel, invalid, sections, error));
        assert(sections.empty() && !error.isEmpty());
        invalid = configs; invalid[1].name = invalid[0].name;
        assert(!encodeSolidWorksConfigurationSections(kernel, invalid, sections, error));
        invalid = configs; invalid[1].name.append(QChar(u'\0'));
        assert(!encodeSolidWorksConfigurationSections(kernel, invalid, sections, error));
        invalid = configs; invalid[1].name += QChar(u'ж');
        assert(!encodeSolidWorksConfigurationSections(kernel, invalid, sections, error));
        invalid = configs; invalid[1].shape = {};
        assert(!encodeSolidWorksConfigurationSections(kernel, invalid, sections, error));
        assert(sections.empty());
        invalid = configs; invalid[0].importedBody = SolidWorksImportedBodyIdentity{0, 201};
        assert(!encodeSolidWorksConfigurationSections(kernel, invalid, sections, error));
        assert(sections.empty());
        assert(!encodeSolidWorksConfigurationSections(kernel, {}, sections, error));
    }
    {
        using namespace cadnext::gui;
        const auto outer = kernel.makeBox({20, 30, 40});
        const auto tool = kernel.makeBox({10, 10, 50});
        assert(outer.isOk() && tool.isOk());
        const auto placedTool = kernel.transformShape(tool.value(),
            {1,0,0,0, 0,1,0,0, 0,0,1,0, .005,.01,-.005,1});
        assert(placedTool.isOk());
        const auto hole = kernel.booleanCut(outer.value(), placedTool.value());
        assert(hole.isOk());
        const double angle = .37, c = std::cos(angle), s = std::sin(angle);
        const auto placed = kernel.transformShape(hole.value(),
            {c,s,0,0, -s,c,0,0, 0,0,1,0, .01,-.02,.03,1});
        assert(placed.isOk());
        const std::vector<cadnext::kernel::ShapeHandle> source{outer.value(), placed.value()};
        std::vector<QByteArray> records;
        QString error;
        assert(encodeKompasPlanarBodyRecords(kernel, source, records, error));
        assert(records.size() == 2);
        KompasStoragePrefix prefix;
        assert(prepareKompasStorageRecords(records, prefix, error));
        KompasStorageImage storage;
        // Opaque placeholder for a document catalog: this fixture tests native
        // storage addressing plus BRep, not document object ownership.
        assert(finishKompasStorage(prefix, QByteArray(17, char(0x80)), storage, error));
        KompasStorageIndex index;
        assert(decodeKompasStorageIndex(storage.contents, storage.sysInfo, index, error));
        assert(index.records.size() == source.size());
        // Synthetic test envelope only: no claim of a complete KOMPAS document.
        const QByteArray fixture = zip({{"Contents", storage.contents},
                                       {"SysInfo", storage.sysInfo},
                                       {"MetaInfo", "<document><part name=\"synthetic\"/></document>"}});
        QTemporaryDir dir;
        assert(dir.isValid());
        const QString path = dir.filePath(QStringLiteral("native-c3d-records.m3d"));
        QFile out(path);
        assert(out.open(QIODevice::WriteOnly) && out.write(fixture) == fixture.size());
        out.close();
        KompasC3dResult restored;
        if (!readKompasC3dSolids(path, kernel, restored, error)) qFatal("Native C3D records: %s", qPrintable(error));
        assert(restored.solids.size() == source.size());
        for (std::size_t i = 0; i < source.size(); ++i) {
            assert(kernel.isShapeValid(restored.solids[i].shape));
            const auto* before = kernel.findShape(source[i]);
            const auto* after = kernel.findShape(restored.solids[i].shape);
            assert(before && after);
            GProp_GProps v1, v2, a1, a2;
            BRepGProp::VolumeProperties(*before, v1); BRepGProp::VolumeProperties(*after, v2);
            BRepGProp::SurfaceProperties(*before, a1); BRepGProp::SurfaceProperties(*after, a2);
            assert(std::fabs(v2.Mass() / v1.Mass() - 1.0) < 1e-12);
            assert(std::fabs(a2.Mass() / a1.Mass() - 1.0) < 1e-12);
            assert(v1.CentreOfMass().Distance(v2.CentreOfMass()) < 1e-12);
        }
        const auto cylinder = kernel.makeCylinder({10, 20});
        assert(cylinder.isOk());
        assert(!encodeKompasPlanarBodyRecords(kernel, {source[0], cylinder.value()}, records, error));
        assert(records.empty() && !error.isEmpty());
        assert(!encodeKompasPlanarBodyRecords(kernel, {{}}, records, error));
        assert(records.empty());
        assert(!encodeKompasPlanarBodyRecords(kernel, {}, records, error));
    }
    {
        using namespace cadnext::gui;
        const auto duplicate = kernel.makeBox({20,30,40});
        const auto history = kernel.makeCylinder({10,30});
        assert(duplicate.isOk() && history.isOk());
        std::vector<QByteArray> records;
        QString error;
        quint32 lastObjectId = 0;
        KompasBodyOwnership ownership;
        assert(encodeKompasBodyRecords(kernel,{history.value(),duplicate.value(),duplicate.value()},
                                      records,error,&lastObjectId,&ownership));
        assert(ownership.records.size()==3);
        std::map<quint16,quint16> mathRegistry;
        for(const auto& [id,cls]:ownership.registry) {
            assert(id<=lastObjectId);
            if(cls!=0x7c69 && cls!=0x1408 && cls!=0x110f)mathRegistry.emplace(id,cls);
        }
        std::set<quint16> proxyIds, mathIds;
        for(std::size_t i=0;i<ownership.records.size();++i) {
            KompasTopologyTables tables;qsizetype consumed=0;
            assert(decodeKompasTopologyTables(ownership.records[i],0,mathRegistry,tables,consumed,error));
            assert(consumed==ownership.records[i].size());
            std::array<std::size_t,3> counts{};
            for(std::size_t kind=0;kind<3;++kind)
                for(const auto& group:tables.groups[kind])
                    for(const auto& proxy:group.proxies) {
                        ++counts[kind];
                        assert(proxy.bodyNumber==i+1 && proxy.mathId);
                        assert(proxyIds.insert(proxy.id).second && mathIds.insert(*proxy.mathId).second);
                        assert(proxy.name.words.size()==1 && proxy.name.words[0]==group.mainName);
                    }
            if(i>0)assert((counts==std::array<std::size_t,3>{8,12,6}));
        }
        assert(ownership.registry.rbegin()->first==lastObjectId);
        // Whole body records now carry their own application state around the
        // ownership tables. The enclosing fixture still omits model and
        // operation/controller records and is not a complete native document.
        std::vector<KompasBodyApplicationState> states(3);
        states[0].nativeName=101;states[1].nativeName=202;states[2].nativeName=303;
        states[1].nativeFlags[1]=1;states[2].nativeFooterFlags1={1,1,0,0};
        std::vector<QByteArray> applicationRecords;
        std::vector<QByteArray> applicationLinks;
        quint32 applicationLastId=0;
        assert(encodeKompasApplicationBodyRecords(kernel,
            {history.value(),duplicate.value(),duplicate.value()},states,
            applicationRecords,error,&applicationLastId,&applicationLinks));
        assert(applicationRecords.size()==records.size() && applicationLastId==lastObjectId);
        assert(applicationLinks.size()==records.size());
        for(std::size_t i=0;i<records.size();++i) {
            assert(applicationRecords[i].startsWith(records[i]));
            KompasBodyApplication application;qsizetype consumed=0;
            assert(decodeKompasBodyApplication(applicationRecords[i],records[i].size(),
                                               mathRegistry,application,consumed,error));
            assert(consumed==applicationRecords[i].size()-records[i].size());
            assert(application.state.nativeName==states[i].nativeName);
            quint32 linkedName=0;
            assert(decodeKompasBodyApplicationLink(applicationLinks[i],linkedName,error));
            assert(linkedName==application.state.nativeName);
            assert(application.state.nativeFlags==states[i].nativeFlags);
            assert(application.state.nativeFooterFlags1==states[i].nativeFooterFlags1);
            QByteArray encoded;
            assert(encodeKompasBodyApplication(application,mathRegistry,encoded,error));
            assert(encoded==applicationRecords[i].mid(records[i].size()));
            for(const auto& groups:application.topology.groups)
                for(const auto& group:groups) for(const auto& proxy:group.proxies)
                    assert(proxy.bodyNumber==i+1 && proxy.mathId);
        }
        const auto verifyApplicationFailure=[&](auto invalidStates) {
            std::vector<QByteArray> output{QByteArray("stale")},links{QByteArray("stale")};quint32 id=999;
            assert(!encodeKompasApplicationBodyRecords(kernel,
                {history.value(),duplicate.value(),duplicate.value()},invalidStates,output,error,&id,&links));
            assert(output.empty() && links.empty() && id==0 && !error.isEmpty());
        };
        auto invalidStates=states;invalidStates.pop_back();verifyApplicationFailure(invalidStates);
        invalidStates=states;invalidStates[2].nativeName=101;verifyApplicationFailure(invalidStates);
        invalidStates=states;invalidStates[1].nativeFlags[0]=2;verifyApplicationFailure(invalidStates);
        invalidStates=states;invalidStates[2].nativeName=0;verifyApplicationFailure(invalidStates);
        std::vector<QByteArray> aliased{QByteArray("stale")};quint32 aliasedId=999;
        assert(!encodeKompasApplicationBodyRecords(kernel,{duplicate.value()},{states[0]},
            aliased,error,&aliasedId,&aliased));
        assert(aliased.empty() && aliasedId==0);
        // A document can serialize model/controller objects before the body.
        // Every new math/proxy ID continues after that existing registry.
        std::vector<QByteArray> continuedRecords;
        KompasBodyOwnership continuedOwnership;quint32 continuedLastId=0;
        assert(encodeKompasBodyRecords(kernel,
            {history.value(),duplicate.value(),duplicate.value()},continuedRecords,error,
            &continuedLastId,&continuedOwnership,42));
        assert(continuedLastId==lastObjectId+41);
        assert(continuedOwnership.registry.size()==ownership.registry.size());
        for(const auto& [id,cls]:ownership.registry)
            assert(continuedOwnership.registry.at(quint16(id+41))==cls);
        assert((quint16(uchar(continuedRecords[0][14])) |
                (quint16(uchar(continuedRecords[0][15]))<<8))==42);
        std::vector<QByteArray> continuedApplications,continuedLinks;
        assert(encodeKompasApplicationBodyRecords(kernel,
            {history.value(),duplicate.value(),duplicate.value()},states,
            continuedApplications,error,&continuedLastId,&continuedLinks,42));
        assert(continuedLastId==applicationLastId+41 && continuedLinks==applicationLinks);
        std::map<quint16,quint16> continuedMath;
        for(const auto& [id,cls]:continuedOwnership.registry)
            if(cls!=0x7c69 && cls!=0x1408 && cls!=0x110f)continuedMath.emplace(id,cls);
        for(std::size_t i=0;i<continuedRecords.size();++i) {
            assert(continuedApplications[i].startsWith(continuedRecords[i]));
            KompasBodyApplication application;qsizetype consumed=0;
            assert(decodeKompasBodyApplication(continuedApplications[i],continuedRecords[i].size(),
                                               continuedMath,application,consumed,error));
            assert(consumed==continuedApplications[i].size()-continuedRecords[i].size());
            for(const auto& groups:application.topology.groups)
                for(const auto& group:groups)for(const auto& proxy:group.proxies)
                    assert(proxy.id>=42 && proxy.mathId && *proxy.mathId>=42);
        }
        for(const quint32 firstId:{0u,65535u,65536u}) {
            continuedApplications={QByteArray("stale")};continuedLinks={QByteArray("stale")};continuedLastId=999;
            assert(!encodeKompasApplicationBodyRecords(kernel,
                {history.value(),duplicate.value(),duplicate.value()},states,
                continuedApplications,error,&continuedLastId,&continuedLinks,firstId));
            assert(continuedApplications.empty() && continuedLinks.empty() && continuedLastId==0);
        }
        KompasStoragePrefix prefix;
        assert(prepareKompasStorageRecords(applicationRecords,prefix,error));
        KompasCatalog catalog;
        catalog.lastObjectId=lastObjectId;
        KompasCatalogEntry model;model.numericName=170;model.directory=true;
        KompasCatalogEntry historyStream;historyStream.numericName=130;historyStream.recordIndex=0;
        model.children.push_back(historyStream);
        KompasCatalogEntry bodies;bodies.numericName=300;bodies.directory=true;
        for(std::size_t i=1;i<3;++i) {
            KompasCatalogEntry body;body.textName=QString::number(i+1);body.recordIndex=i;
            bodies.children.push_back(body);
        }
        model.children.push_back(bodies);catalog.entries.push_back(model);
        QByteArray catalogBytes;
        assert(encodeKompasCatalog(catalog,prefix,catalogBytes,error));
        QTemporaryDir folder;assert(folder.isValid());
        const auto path=folder.filePath(QStringLiteral("named-bodies.m3d"));
        const auto saveFixture=[&](const QByteArray& directory) {
            KompasStorageImage storage;
            assert(finishKompasStorage(prefix,directory,storage,error));
            const auto fixture=zip({{"Contents",storage.contents},{"SysInfo",storage.sysInfo}});
            QFile file(path);assert(file.open(QIODevice::WriteOnly));
            assert(file.write(fixture)==fixture.size());
        };
        // Geometry/catalog fixture only. Equal bodies have distinct named
        // owners; an operation-history shell must not become a third body.
        saveFixture(catalogBytes);
        KompasC3dResult restored;
        assert(readKompasC3dSolids(path,kernel,restored,error));
        assert(restored.solids.size()==2 && restored.notes.isEmpty());
        const auto expected=kernel.volumeProperties(duplicate.value());
        assert(expected.isOk());
        for(const auto& body:restored.solids) {
            const auto actual=kernel.volumeProperties(body.shape);
            assert(actual.isOk() && kernel.isShapeValid(body.shape));
            assert(std::fabs(actual.value().volumeM3/expected.value().volumeM3-1)<1e-12);
        }
        // A recognized native catalog must validate completely: corrupt
        // ownership cannot fall back to scanning every shell in the stream.
        catalogBytes.chop(1);saveFixture(catalogBytes);
        assert(!readKompasC3dSolids(path,kernel,restored,error));
        assert(restored.solids.empty() && !error.isEmpty());
        catalog.entries[0].children[1].enabled=false;
        assert(encodeKompasCatalog(catalog,prefix,catalogBytes,error));
        saveFixture(catalogBytes);
        assert(!readKompasC3dSolids(path,kernel,restored,error));
        assert(restored.solids.empty() && !error.isEmpty());
    }
    {
        using namespace cadnext::gui;
        const auto box=kernel.makeBox({.02,.03,.04});
        assert(box.isOk());
        KompasImportedOperationPrefix settings;
        settings.objectId=42;settings.applicationName=100;settings.mainName=1003;
        settings.frameName=99;settings.title="Imported box";settings.bodyNumber=4;
        KompasImportedOperationSuffix suffix;suffix.bodyNumber=4;
        KompasOperationAttribute color;color.color=0x123456;
        KompasOperationAttribute flag;flag.kind=KompasOperationAttribute::Boolean;
        suffix.attributes={color,flag};
        KompasBodyApplicationState state;state.nativeName=100;
        QString error;
        QByteArray datums;
        std::map<quint16,quint16> datumRegistry;
        for(int i=0;i<7;++i) {
            KompasDatum datum;
            datum.objectId=quint16(35+i);datum.mainName=quint32(93+i);datum.nativeName=quint32(i+1);
            datum.kind=i<3?KompasDatum::Plane:i<6?KompasDatum::Axis:KompasDatum::Origin;
            datum.title="Datum "+QString::number(i+1);
            if(i==1)datum.placement={0,0,0,1,0,0,0,0,-1,0,1,0};
            if(i==2)datum.placement={0,0,0,0,0,1,0,1,0,-1,0,0};
            if(i>=3 && i<6) {
                datum.placement[3]=datum.placement[4]=datum.placement[5]=0;
                datum.placement[i]=1;
            }
            if(i==6)datum.datumIds={35,36,37,38,39,40};
            QByteArray bytes;
            assert(encodeKompasDatum(datum,datumRegistry,bytes,error));
            KompasDatum read;qsizetype size=0;
            assert(decodeKompasDatum(bytes,0,datumRegistry,read,size,error) && size==bytes.size());
            if(i==6)assert(read.mainName==settings.frameName && read.datumIds==datum.datumIds);
            datums+=bytes;
            datumRegistry.emplace(datum.objectId,i<3?0x507a:i<6?0x2c70:0x4170);
        }
        KompasImportedBodyOperation first;
        assert(encodeKompasImportedBodyOperation(kernel,box.value(),settings,suffix,state,first,error));
        assert(first.registry.at(42)==0x2801 && first.registry.at(43)==0x6239);
        KompasImportedOperationPrefix decoded;qsizetype consumed=0;
        assert(decodeKompasImportedOperationPrefix(first.operation,0,decoded,consumed,error));
        assert(decoded.bodyNumber==4 && decoded.applicationName==100 && decoded.mainName==1003);
        assert(first.operation.mid(consumed,7)==QByteArray::fromHex("02803962012b00"));
        // The current body's shell is numbered with a fresh ID, registered as a
        // shell (KOMPAS numbers the shells of its bodies; /#170/#110 names the
        // first), and holds exactly six pointers to the faces defined inside
        // its operation; there is no second math definition of those faces
        // and no copied operation geometry.
        const auto number=[&](qsizetype at,int width) {
            quint64 value=0;for(int i=0;i<width;++i)value|=quint64(uchar(first.body[at+i]))<<(8*i);
            return value;
        };
        assert(first.body.left(13)==QByteArray::fromHex("0104000000ffffffff02803962") && uchar(first.body[13])==1);
        assert(number(14,2)==first.shellId && first.registry.at(first.shellId)==0x6239 && first.shellId!=43);
        assert(number(16,8)==6);
        std::set<quint16> referencedFaces,mathFaces;
        for(int f=0;f<6;++f) {
            assert(uchar(first.body[24+3*f])==1);
            const auto id=quint16(number(25+3*f,2));
            assert(first.registry.at(id)==0x666e && referencedFaces.insert(id).second);
        }
        std::map<quint16,quint16> mathRegistry;
        for(const auto& [id,cls]:first.registry) {
            if(cls==0x666e)mathFaces.insert(id);
            if(cls!=0x7c69 && cls!=0x1408 && cls!=0x110f)mathRegistry.emplace(id,cls);
        }
        assert(referencedFaces==mathFaces);
        KompasBodyApplication application;
        assert(decodeKompasBodyApplication(first.body,42,mathRegistry,application,consumed,error));
        assert(consumed==first.body.size()-42 && application.state.nativeName==100);
        const std::array<std::size_t,3> counts{8,12,6};
        for(std::size_t kind=0;kind<3;++kind) {
            const auto& groups=application.topology.groups[kind];
            assert(groups.size()==1 && groups[0].mainName==1003 && groups[0].proxies.size()==counts[kind]);
            for(const auto& proxy:groups[0].proxies)
                assert(proxy.bodyNumber==4 && proxy.name.words.size()==2 && proxy.name.words[0]==1003 && proxy.mathId);
        }
        quint32 linked=0;assert(decodeKompasBodyApplicationLink(first.applicationLink,linked,error) && linked==100);
        auto secondSettings=settings;
        secondSettings.objectId=quint16(first.lastObjectId+1);
        secondSettings.applicationName=200;secondSettings.mainName=2003;secondSettings.bodyNumber=5;
        auto secondSuffix=suffix;secondSuffix.bodyNumber=5;
        auto secondState=state;secondState.nativeName=200;
        KompasImportedBodyOperation second;
        assert(encodeKompasImportedBodyOperation(kernel,box.value(),secondSettings,secondSuffix,secondState,second,error));
        for(const auto& [id,cls]:second.registry)assert(!first.registry.count(id));
        KompasModelHeader modelHeader;modelHeader.controllerCount=9;
        for(auto& bounds:modelHeader.boxes)bounds={0,0,0,20,30,40};
        QByteArray modelStart,modelEnd;
        assert(encodeKompasModelHeader(modelHeader,modelStart,error));
        KompasModelFooter modelFooter;
        modelFooter.originId=41;modelFooter.nativeCounters={201,5,3,6};modelFooter.nextMainName=2004;
        auto modelRegistry=datumRegistry;
        modelRegistry.insert(first.registry.begin(),first.registry.end());
        modelRegistry.insert(second.registry.begin(),second.registry.end());
        assert(encodeKompasModelFooter(modelFooter,modelRegistry,modelEnd,error));
        const auto modelBytes=modelStart+datums+first.operation+second.operation+modelEnd;
        KompasModelHeader headerRead;KompasModelFooter footerRead;qsizetype envelopeSize=0;
        assert(decodeKompasModelHeader(modelBytes,0,headerRead,envelopeSize,error) && envelopeSize==283);
        assert(headerRead.controllerCount==9 && headerRead.boxes[0][5]==40);
        assert(decodeKompasModelFooter(modelBytes,modelBytes.size()-modelEnd.size(),modelRegistry,footerRead,envelopeSize,error));
        assert(envelopeSize==modelEnd.size() && footerRead.originId==41 && footerRead.nextMainName>secondSettings.mainName);
        assert(footerRead.nativeCounters[0]>headerRead.controllerCount);
        KompasModelProperties modelProperties;
        modelProperties.name="Two bodies";modelProperties.materialName="Steel";
        QByteArray propertyBytes;
        assert(encodeKompasModelProperties(modelProperties,propertyBytes,error));
        KompasModelProperties propertyRead;
        assert(decodeKompasModelProperties(propertyBytes,0,propertyRead,envelopeSize,error));
        assert(envelopeSize==propertyBytes.size() && propertyRead.name==modelProperties.name);
        KompasDeferredMassProperties massCache;
        massCache.nativeDensity=modelProperties.nativeDensity/1000;
        QByteArray massBytes;
        assert(encodeKompasDeferredMassProperties(massCache,massBytes,error));
        std::array<QByteArray,2> bodyPropertyBytes;
        for(std::size_t i=0;i<2;++i) {
            KompasBodyProperties bodyProperties;
            bodyProperties.properties=modelProperties;
            bodyProperties.properties.name="Body "+QString::number(i+1);
            bodyProperties.massCache=massCache;
            assert(encodeKompasBodyProperties(bodyProperties,bodyPropertyBytes[i],error));
            KompasBodyProperties decoded;
            assert(decodeKompasBodyProperties(bodyPropertyBytes[i],0,decoded,envelopeSize,error));
            assert(envelopeSize==bodyPropertyBytes[i].size() && decoded.properties.name==bodyProperties.properties.name);
            assert(decoded.massCache.nativeDensity==massCache.nativeDensity);
        }
        KompasPropertyDefinitions definitions;
        KompasPropertyDefinition definition;definition.id=100;definition.nativeRule=2;
        definition.sourceKey="CADNext";definition.valueKey="Title";definition.displayName="Title";
        definitions.entries.push_back(definition);
        definition.id=37;definition.valueKey="Profile";definition.displayName="Profile";
        definition.choices=std::vector<QString>{"A","B"};definitions.entries.push_back(definition);
        KompasPropertyTuning tuning;
        tuning.lists[0]={{100,true},{37,false}};tuning.lists[1]={{37,true},{100,false}};
        assert(validateKompasPropertyReferences(definitions,tuning,error));
        QByteArray definitionsBytes,tuningBytes;
        assert(encodeKompasPropertyDefinitions(definitions,definitionsBytes,error));
        assert(encodeKompasPropertyTuning(tuning,tuningBytes,error));
        KompasDocumentSettings documentSettings;
        documentSettings.title=modelProperties.name;
        for(std::size_t i=0;i<KompasDocumentSettings::styleCount;++i) {
            KompasDocumentStyle style;style.name="CADNext style "+QString::number(i);
            documentSettings.styles.push_back(style);
        }
        QByteArray settingsBytes;
        assert(encodeKompasDocumentSettings(documentSettings,settingsBytes,error));
        // Component fixture: the model root, datums, operation packets,
        // model/body properties, deferred mass cache, property definitions,
        // tuning lists, document settings and current bodies have native named owners.
        // Document services and complete property-index
        // ownership remain absent; this is not a complete native export.
        KompasStoragePrefix storagePrefix;
        assert(prepareKompasStorageRecords({modelBytes,first.body,second.body,
            first.applicationLink,second.applicationLink,propertyBytes,
            bodyPropertyBytes[0],bodyPropertyBytes[1],massBytes,definitionsBytes,tuningBytes,settingsBytes},storagePrefix,error));
        KompasCatalog catalog;catalog.lastObjectId=second.lastObjectId;
        KompasCatalogEntry model;model.directory=true;model.numericName=170;
        KompasCatalogEntry operations;operations.numericName=130;operations.recordIndex=0;
        KompasCatalogEntry bodies;bodies.directory=true;bodies.numericName=300;
        KompasCatalogEntry links;links.directory=true;links.numericName=302;
        KompasCatalogEntry bodyProperties;bodyProperties.directory=true;bodyProperties.numericName=301;
        for(std::size_t i=0;i<2;++i) {
            KompasCatalogEntry body;body.textName=QString::number(i+4);body.recordIndex=i+1;
            bodies.children.push_back(body);body.recordIndex=i+3;links.children.push_back(body);
            body.recordIndex=i+6;bodyProperties.children.push_back(body);
        }
        KompasCatalogEntry propertiesEntry;propertiesEntry.numericName=100;propertiesEntry.recordIndex=5;
        KompasCatalogEntry massFolder;massFolder.directory=true;massFolder.numericName=240;
        KompasCatalogEntry massEntry;massEntry.numericName=100;massEntry.recordIndex=8;
        massFolder.children.push_back(massEntry);
        model.children={operations,bodies,links,bodyProperties,massFolder,propertiesEntry};catalog.entries.push_back(model);
        for(std::size_t i=0;i<2;++i) {
            KompasCatalogEntry propertyFolder;propertyFolder.directory=true;
            propertyFolder.textName=i ? "_ADDPROP_TUNING_D" : "_ADDPROP_D";
            KompasCatalogEntry propertyStream;propertyStream.textName=i ? "_ADDPROP_TUNING_F" : "_ADDPROP_F";
            propertyStream.recordIndex=9+i;propertyFolder.children.push_back(propertyStream);
            catalog.entries.push_back(propertyFolder);
        }
        KompasCatalogEntry settingsEntry;settingsEntry.numericName=100;settingsEntry.recordIndex=11;
        catalog.entries.push_back(settingsEntry);
        QByteArray catalogBytes;
        assert(encodeKompasCatalog(catalog,storagePrefix,catalogBytes,error));
        KompasStorageImage storage;assert(finishKompasStorage(storagePrefix,catalogBytes,storage,error));
        KompasContentsRecords storageRead;
        assert(decodeKompasContentsRecords(storage.contents,storageRead,error) && storageRead.records.size()==12);
        KompasDocumentSettings settingsRead;
        assert(decodeKompasDocumentSettings(storageRead.records[11].decoded,settingsRead,error));
        assert(settingsRead.title==modelProperties.name && !settingsRead.assembly && settingsRead.styles.size()==220);
        assert(settingsRead.styles[219].name=="CADNext style 219");
        QTemporaryDir folder;assert(folder.isValid());
        const auto path=folder.filePath("operation-components.m3d");
        QFile file(path);assert(file.open(QIODevice::WriteOnly));
        const auto fixture=zip({{"Contents",storage.contents},{"SysInfo",storage.sysInfo}});
        assert(file.write(fixture)==fixture.size());file.close();
        KompasC3dResult restored;
        assert(readKompasC3dSolids(path,kernel,restored,error));
        assert(restored.solids.size()==2 && restored.notes.isEmpty());
        for(const auto& body:restored.solids) {
            const auto mass=kernel.volumeProperties(body.shape);
            assert(mass.isOk() && kernel.isShapeValid(body.shape));
            assert(std::fabs(mass.value().volumeM3/.000024-1)<1e-12);
            GProp_GProps area;
            BRepGProp::SurfaceProperties(*kernel.findShape(body.shape),area,1e-14,true);
            assert(std::fabs(area.Mass()/.0052-1)<1e-12);
        }
        for(int change=0;change<5;++change) {
            auto badSettings=settings;auto badSuffix=suffix;auto badState=state;
            switch(change) {
            case 0:badState.nativeName=200;break;
            case 1:badSuffix.bodyNumber=5;break;
            case 2:badSettings.objectId=65535;break;
            case 3:badState.nativeFlags[0]=2;break;
            case 4:badSettings.placement[0]=1;break;
            }
            auto output=first;
            assert(!encodeKompasImportedBodyOperation(kernel,box.value(),badSettings,badSuffix,badState,output,error));
            assert(output.operation.isEmpty() && output.body.isEmpty() && output.applicationLink.isEmpty());
            assert(output.registry.empty() && output.lastObjectId==0 && !error.isEmpty());
        }
    }
    {
        using namespace cadnext::gui;
        // Independently authored FileInfo: big-endian UTF-16, fixed key order,
        // declared record versions and application identity, without CAD SDKs.
        const QString fixture = QStringLiteral(
            "[FileInfo]\nAppName=CADNext\nAppVersion=CADNext_1.0\nBuildNum=1\n"
            "AppPlatform=x64\nMathFileVersion=0x11001001\nAppFileVersion=0x11001011\n"
            "FileTypeName=Kompas.m3d\nFileType=4\nCreateAppVersion=0x11001011\n"
            "CreateData=10/2/2026 9:08:07\nModifyData=10/2/2026 12:34:56\n"
            "Author=Разработчик\nOrgName=\nComment=Собственная запись\nAutoSave=false\n");
        QByteArray bytes = QByteArray::fromHex("feff");
        for (const auto c : fixture) {
            bytes.append(char(c.unicode() >> 8)); bytes.append(char(c.unicode() & 0xff));
        }
        KompasFileInfo info;
        QString error;
        QByteArray encoded;
        assert(decodeKompasFileInfo(bytes, info, error));
        assert(info.author && *info.author == QStringLiteral("Разработчик"));
        assert(info.mathVersion == 0x11001001 && info.fileType == 4);
        assert(encodeKompasFileInfo(info, encoded, error) && encoded == bytes);
        for (qsizetype size = 0; size < bytes.size(); ++size) {
            auto decoded = info;
            assert(!decodeKompasFileInfo(bytes.left(size), decoded, error));
            assert(decoded.author == std::nullopt && !error.isEmpty());
        }
        info.comment = QStringLiteral("Comment\nInjected=true");
        assert(!encodeKompasFileInfo(info, encoded, error) && encoded.isEmpty());
        info.comment = QStringLiteral("Comment"); info.fileType = 6;
        assert(!encodeKompasFileInfo(info, encoded, error) && encoded.isEmpty());
    }
    {
        using namespace cadnext::gui;
        const auto first = kernel.makeBox({.02, .03, .04});
        const auto second = kernel.makeCylinder({.005, .012});
        assert(first.isOk() && second.isOk());
        QTemporaryDir folder;
        assert(folder.isValid());
        const QString path = folder.filePath(QStringLiteral("cadnext-native.m3d"));
        QString error;
        KompasNativeWriteOptions options;
        options.title = QStringLiteral("CADNext native document");
        options.color = 0x123456;
        options.material = {50, 60, 70, 80, 90, 100};
        cadnext::Transform placement;
        placement.scale = {2, 3, 4};
        placement.rotationEuler = {0, 0, 90};
        placement.position = {.11, -.04, .05};
        assert(writeKompasNativeDocument(kernel,
            {{first.value(), 0, QStringLiteral("Box"), placement},
             {second.value(), 1, QStringLiteral("Cylinder")}},
            path, error, options));
        KompasC3dResult restored;
        assert(readKompasC3dSolids(path, kernel, restored, error));
        assert(restored.solids.size() == 2 && restored.notes.empty());
        assert(kernel.isShapeValid(restored.solids[0].shape));
        assert(kernel.isShapeValid(restored.solids[1].shape));
        const auto boxMass = kernel.volumeProperties(restored.solids[0].shape);
        const auto cylinderMass = kernel.volumeProperties(restored.solids[1].shape);
        assert(boxMass.isOk() && cylinderMass.isOk());
        assert(std::fabs(boxMass.value().volumeM3 / (.02 * .03 * .04 * 24) - 1) < 1e-12);
        assert(std::fabs(boxMass.value().centerOfMass.x - .11) < 1e-12);
        assert(std::fabs(boxMass.value().centerOfMass.y + .04) < 1e-12);
        assert(std::fabs(boxMass.value().centerOfMass.z - .05) < 1e-12);
        assert(std::fabs(cylinderMass.value().volumeM3 / (M_PI * .005 * .005 * .012) - 1) < 1e-12);
        GProp_GProps boxArea, cylinderArea;
        BRepGProp::SurfaceProperties(*kernel.findShape(restored.solids[0].shape), boxArea, 1e-14, true);
        BRepGProp::SurfaceProperties(*kernel.findShape(restored.solids[1].shape), cylinderArea, 1e-14, true);
        const double expectedBoxArea = 2 * (.04 * .12 + .04 * .12 + .12 * .12);
        assert(std::fabs(boxArea.Mass() / expectedBoxArea - 1) < 1e-12);
        assert(std::fabs(cylinderArea.Mass() / (2 * M_PI * .005 * (.005 + .012)) - 1) < 1e-12);
        const auto boxBounds = kernel.boundingBox(restored.solids[0].shape);
        assert(boxBounds.isOk());
        assert(std::fabs(boxBounds.value().min.x - .05) < 1e-6);
        assert(std::fabs(boxBounds.value().max.y + .02) < 1e-6);
        KompasModelInfo modelInfo;
        assert(readKompasModelInfo(path, modelInfo, error));
        const QStringList expectedObjects{QStringLiteral("Box"), QStringLiteral("Cylinder")};
        assert(modelInfo.name == options.title && modelInfo.objects == expectedObjects);
        KompasStorageImage storageImage;
        assert(readKompasStorageImage(path, storageImage, error));
        assert(storageImage.contents.startsWith("KF") && storageImage.sysInfo.startsWith("KF"));
        KompasFileInfo fileInfo;
        assert(readKompasFileInfo(path, fileInfo, error));
        assert(fileInfo.fileType == 4 && fileInfo.applicationName == QStringLiteral("CADNext"));
        assert(fileInfo.mathVersion == 0x11001001 && fileInfo.applicationFileVersion == 0x11001011);
        KompasContentsRecords records;
        assert(decodeKompasContentsRecords(storageImage.contents, records, error));
        KompasStorageIndex storageIndex;
        assert(decodeKompasStorageIndex(storageImage.contents, storageImage.sysInfo, storageIndex, error));
        KompasCatalog catalog;
        assert(decodeKompasCatalog(records.tail, storageIndex.records, catalog, error));
        bool settingsFound = false, linksFound = false;
        for (const auto& entry : catalog.entries) {
            if (!entry.directory && entry.numericName == 100) {
                KompasDocumentSettings settings;
                assert(decodeKompasDocumentSettings(records.records[entry.recordIndex].decoded, settings, error));
                assert(!settings.assembly); settingsFound = true;
            }
            if (entry.directory && entry.numericName == 170) {
                for (const auto& child : entry.children) {
                    if (child.directory && child.numericName == 302) {
                        assert(child.children.size() == 2);
                        assert(child.children[0].textName == QStringLiteral("2"));
                        assert(child.children[1].textName == QStringLiteral("1"));
                        linksFound = true;
                    }
                }
            }
        }
        assert(settingsFound && linksFound);
        const auto before = [&] {
            QFile file(path); assert(file.open(QIODevice::ReadOnly)); return file.readAll();
        }();
        assert(!writeKompasNativeDocument(kernel,
            {{cadnext::kernel::ShapeHandle{}, 1, QStringLiteral("Broken")}},
            path, error, options));
        const auto after = [&] {
            QFile file(path); assert(file.open(QIODevice::ReadOnly)); return file.readAll();
        }();
        assert(after == before);
    }
    {
        using namespace cadnext::gui;
        const auto cylinder=kernel.makeCylinder({10,30});
        const auto sphere=kernel.makeSphere({15});
        const auto cone=kernel.adoptShape(BRepPrimAPI_MakeCone(.02,.008,.03).Shape(),"native-cone");
        const auto torus=kernel.adoptShape(BRepPrimAPI_MakeTorus(.03,.008).Shape(),"native-torus");
        const auto cavity=kernel.adoptShape(BRepAlgoAPI_Cut(
            BRepPrimAPI_MakeBox(.04,.04,.04).Shape(),
            BRepPrimAPI_MakeBox(gp_Pnt(.01,.01,.01),.02,.02,.02).Shape()).Shape(),"native-cavity");
        const auto nurbsCylinder=kernel.adoptShape(BRepBuilderAPI_NurbsConvert(*kernel.findShape(cylinder.value())).Shape(),"native-nurbs-cylinder");
        const auto nurbsTorus=kernel.adoptShape(BRepBuilderAPI_NurbsConvert(*kernel.findShape(torus)).Shape(),"native-nurbs-torus");
        const auto polynomial=kernel.adoptShape(BRepBuilderAPI_NurbsConvert(*kernel.findShape(box.value())).Shape(),"native-nurbs-box");
        assert(cylinder.isOk() && sphere.isOk());
        const std::vector<std::pair<const char*,cadnext::kernel::ShapeHandle>> cases{
            {"cylinder",cylinder.value()}, {"sphere",sphere.value()}, {"cone",cone}, {"torus",torus}, {"cavity",cavity},
            {"nurbs-box",polynomial}, {"periodic-nurbs",periodicSplineSolid(kernel)},
            {"mixed-uv-boundaries",mixedUvSplineSolid(kernel)},
            {"rational-profile",rationalProfileSolid(kernel)}};
        for (const auto& item:cases) verifyNativeC3dBody(kernel,item.first,item.second);
        {
            // Native coordinates converted to metres lie at rounding boundaries.
            // Repeated native saves must retain these vertex coordinates exactly.
            const auto stableBox = kernel.makeBox({10.05 * .001, 10.13 * .001, 10.22 * .001});
            assert(stableBox.isOk());
            const auto vertices = [&](cadnext::kernel::ShapeHandle handle) {
                std::set<std::array<double, 3>> points;
                for (TopExp_Explorer it(*kernel.findShape(handle), TopAbs_VERTEX); it.More(); it.Next()) {
                    const auto p = BRep_Tool::Pnt(TopoDS::Vertex(it.Current()));
                    points.insert({p.X(), p.Y(), p.Z()});
                }
                return points;
            };
            const auto expected = vertices(stableBox.value());
            assert(expected.size() == 8);
            auto current = stableBox.value();
            for (int cycle = 0; cycle < 3; ++cycle) {
                current = verifyNativeC3dBody(kernel, "native-unit-stability", current);
                assert(vertices(current) == expected);
            }
        }
        // A narrowing cone has a signed angle and a reference circle at its
        // lower cap. Moving that circle or reversing its axis changes the UV
        // frame and forces periodic seam reconstruction. Preserve the source
        // frame through C3D, including six hyperbolic sections and an offset
        // axis. These checks fail when C3D uses XT's positive-angle frame.
        for (int offset = 0; offset < 3; ++offset) {
            BRepBuilderAPI_MakePolygon polygon;
            for (int corner = 0; corner < 6; ++corner) {
                const double angle = corner * M_PI / 3 + .2;
                polygon.Add(gp_Pnt(.014 * std::cos(angle), .014 * std::sin(angle), 0));
            }
            polygon.Close();
            const auto bar = BRepPrimAPI_MakePrism(
                BRepBuilderAPI_MakeFace(polygon.Wire()).Face(), gp_Vec(0, 0, .03)).Shape();
            gp_Trsf translation;
            translation.SetTranslation(gp_Vec(.0002 * offset, -.00015 * offset, 0));
            const auto cone = BRepBuilderAPI_Transform(
                BRepPrimAPI_MakeCone(.015, .008, .03).Shape(), translation, true).Shape();
            const auto solid = kernel.adoptShape(BRepAlgoAPI_Common(bar, cone).Shape(), "hex-cone");
            assert(kernel.isShapeValid(solid));
            verifyNativeC3dBody(kernel, "offset-hyperbolic-cone", solid);
        }
        // Exact endpoints still carry their declared precision. This cap's
        // interior deviation exceeds the modeller's default tolerance.
        verifyNativeC3dBody(kernel,"declared-vertex-precision",
                           mixedUvSplineSolid(kernel,false,3e-6,1e-5));
        // Straight geometric locus, nonlinear common parameter f(t)=(t+t^3)/2.
        // Extracting the support's iso curve keeps the locus but loses that
        // law. Native paired UV curves must retain the prescribed midpoint.
        const auto nonlinear=verifyNativeC3dBody(kernel,"nonlinear-uv-parameter",
                                                 mixedUvSplineSolid(kernel,true));
        bool foundNonlinear=false;
        for(TopExp_Explorer e(*kernel.findShape(nonlinear),TopAbs_EDGE);e.More();e.Next()) {
            const BRepAdaptor_Curve curve(TopoDS::Edge(e.Current()));
            const auto a=curve.Value(curve.FirstParameter()),b=curve.Value(curve.LastParameter());
            if(std::fabs(a.Y())>1e-12 || std::fabs(b.Y())>1e-12 ||
               std::fabs(a.Z()-b.Z())>1e-12 || std::fabs(std::fabs(a.X()-b.X())-.02)>1e-12)continue;
            const auto middle=curve.Value((curve.FirstParameter()+curve.LastParameter())/2);
            assert(std::fabs(middle.X()-.00625)<1e-12);
            foundNonlinear=true;
        }
        assert(foundNonlinear);
        verifyNativeC3dBody(kernel,"rational-nurbs-cylinder",nurbsCylinder);
        verifyNativeC3dBody(kernel,"rational-nurbs-torus",nurbsTorus);
        {
            // The common 3D edge is a circle, but its planar cap stores a
            // slightly different UV boundary within the native edge precision.
            // Recognizing the circle must preserve that face-specific curve.
            const auto cylinder=kernel.makeCylinder({.01,.02});assert(cylinder.isOk());
            const auto shape=*kernel.findShape(cylinder.value());
            TopoDS_Face cap;
            for(TopExp_Explorer it(shape,TopAbs_FACE);it.More();it.Next()) {
                const auto face=TopoDS::Face(it.Current());const BRepAdaptor_Surface surface(face);
                if(surface.GetType()==GeomAbs_Plane && surface.Plane().Location().Z()>.009)cap=face;
            }
            assert(!cap.IsNull());
            const auto edge=TopoDS::Edge(TopExp_Explorer(cap,TopAbs_EDGE).Current());
            double first,last;const auto circle=BRep_Tool::CurveOnSurface(edge,cap,first,last);
            constexpr int count=128;
            TColgp_Array1OfPnt2d poles(1,3*count+1);
            TColStd_Array1OfReal knots(1,count+1);
            TColStd_Array1OfInteger multiplicities(1,count+1);
            for(int part=0;part<count;++part) {
                const double a=part==0 ? first : first+(last-first)*part/count;
                const double b=part+1==count ? last : first+(last-first)*(part+1)/count;
                gp_Pnt2d from,to;gp_Vec2d atFrom,atTo;
                circle->D1(a,from,atFrom);circle->D1(b,to,atTo);
                if(part==0)poles.SetValue(1,from);
                poles.SetValue(3*part+2,from.Translated(atFrom*(b-a)/3));
                poles.SetValue(3*part+3,to.Translated(atTo*(-(b-a)/3)));
                poles.SetValue(3*part+4,to);
                knots.SetValue(part+1,a);multiplicities.SetValue(part+1,part==0 ? 4 : 3);
            }
            knots.SetValue(count+1,last);multiplicities.SetValue(count+1,4);
            const Handle(Geom2d_BSplineCurve) boundary=new Geom2d_BSplineCurve(poles,knots,multiplicities,3);
            BRep_Builder builder;builder.UpdateEdge(edge,boundary,cap,1e-7);
            builder.SameRange(edge,true);builder.SameParameter(edge,true);
            GProp_GProps area;BRepGProp::SurfaceProperties(cap,area,1e-14,true);
            constexpr double idealArea=.0001*3.14159265358979323846;
            const double deviation=std::fabs(area.Mass()/idealArea-1);
            assert(deviation>1e-9 && deviation<1e-7);
            assert(kernel.isShapeValid(cylinder.value()));
            verifyNativeC3dBody(kernel,"circle-with-tolerant-cap",cylinder.value());
        }
        {
            // Six hyperbolic sections on one cone. Their native UV curves
            // share the spatial parameter within the declared precision;
            // re-fitting them during sewing changes volume and area.
            constexpr double radius=.014, lowerRadius=.008, upperRadius=.015, height=.03;
            constexpr double pi=3.14159265358979323846;
            BRepBuilderAPI_MakePolygon polygon;
            for(int side=0;side<6;++side) {
                const double angle=side*pi/3+.2;
                polygon.Add(gp_Pnt(radius*std::cos(angle),radius*std::sin(angle),0));
            }
            polygon.Close();
            const auto cap=BRepBuilderAPI_MakeFace(polygon.Wire()).Face();
            const auto prism=BRepPrimAPI_MakePrism(cap,gp_Vec(0,0,height)).Shape();
            const auto section=BRepAlgoAPI_Common(prism,
                BRepPrimAPI_MakeCone(upperRadius,lowerRadius,height).Shape()).Shape();
            const auto original=kernel.adoptShape(section,"six-hyperbolic-sections");
            assert(kernel.isShapeValid(original));
            const auto restored=verifyNativeC3dBody(kernel,"six-hyperbolic-sections",original);
            // Independent volume: integrate the circle clipped by a regular
            // hexagon. In the transition interval subtract six circular caps.
            const double apothem=radius*std::cos(pi/6);
            const double root=std::sqrt(radius*radius-apothem*apothem);
            const double capIntegral=(radius*radius*radius*std::acos(apothem/radius)-
                2*apothem*radius*root+apothem*apothem*apothem*std::acosh(radius/apothem))/3;
            const double hexArea=3*std::sqrt(3.)*radius*radius/2;
            const double slope=(upperRadius-lowerRadius)/height;
            const double volume=(hexArea*(upperRadius-radius)+
                pi*(radius*radius*radius-lowerRadius*lowerRadius*lowerRadius)/3-6*capIntegral)/slope;
            // OCCT fits the original cone's UV intersection curves. Anchor
            // both results to the ideal analytic volume at 1e-8; the separate
            // boundary-preserving round-trip assertion above remains 1e-9.
            for(const auto shape:{original,restored}) {
                GProp_GProps mass;
                BRepGProp::VolumePropertiesGK(*kernel.findShape(shape),mass,1e-12,true,false,true);
                assert(std::fabs(mass.Mass()/volume-1)<1e-8);
            }
        }
        // Hyperbolic and parabolic cone sections exercise the original
        // analytic UV law independently of rational spatial conversion.
        for(const bool parabola:{false,true}) {
            auto tool=BRepPrimAPI_MakeBox(gp_Pnt(.01,-.04,-.03),.05,.08,.10).Shape();
            if(parabola) {
                gp_Trsf transform;
                transform.SetRotation(gp_Ax1(gp_Pnt(.01,0,0),gp_Dir(0,1,0)),-std::atan(.4));
                tool=BRepBuilderAPI_Transform(tool,transform,true).Shape();
            }
            const auto section=BRepAlgoAPI_Cut(BRepPrimAPI_MakeCone(.02,.008,.03,1.3).Shape(),tool).Shape();
            const auto originalSection=kernel.adoptShape(section,"native-conic-section");
            assert(kernel.isShapeValid(originalSection));
            const auto description=cadnext::kernel::describeExactBRep(kernel,originalSection);
            assert(description.isOk());int analyticUvCount=0;
            for(const auto& face:description.value().faces)for(const auto& loop:face.loops)
                for(const auto& coedge:loop)if(coedge.analyticPcurve) {
                    assert(coedge.analyticPcurve->kind==(parabola ?
                        cadnext::kernel::AnalyticPcurveDefinition::Kind::Parabola :
                        cadnext::kernel::AnalyticPcurveDefinition::Kind::Hyperbola));
                    ++analyticUvCount;
                }
            assert(analyticUvCount>0);
            const auto restoredSection=verifyNativeC3dBody(kernel,parabola ? "parabolic-section" : "hyperbolic-section",originalSection);
            int checkedConics=0;
            for(TopExp_Explorer e(section,TopAbs_EDGE);e.More();e.Next()) {
                const auto edge=TopoDS::Edge(e.Current());const BRepAdaptor_Curve original(edge);
                if(original.GetType()!=(parabola ? GeomAbs_Parabola : GeomAbs_Hyperbola))continue;
                double first,last;const auto exact=BRep_Tool::Curve(edge,first,last);
                const auto a=exact->Value(first),b=exact->Value(last);bool checked=false;
                for(TopExp_Explorer r(*kernel.findShape(restoredSection),TopAbs_EDGE);r.More();r.Next()) {
                    const BRepAdaptor_Curve restored(TopoDS::Edge(r.Current()));
                    const auto c=restored.Value(restored.FirstParameter()),d=restored.Value(restored.LastParameter());
                    if(std::min(std::max(a.Distance(c),b.Distance(d)),std::max(a.Distance(d),b.Distance(c)))>1e-10)continue;
                    for(int sample=0;sample<=64;++sample) {
                        const auto p=restored.Value(restored.FirstParameter()+
                            (restored.LastParameter()-restored.FirstParameter())*sample/64);
                        const GeomAPI_ProjectPointOnCurve projection(p,exact,first,last);
                        double distance=std::min(p.Distance(a),p.Distance(b));
                        if(projection.NbPoints()>0)distance=std::min(distance,projection.LowerDistance());
                        assert(distance<1e-11);
                    }
                    checked=true;break;
                }
                assert(checked);++checkedConics;
            }
            assert(checkedConics>=2);
        }
    }
    const auto facePatch = [](std::vector<cadnext::Vector3> outline,
                              cadnext::Vector3 normal) {
        cadnext::kernel::PlanarFacePatch patch;
        patch.planeOrigin = outline.front();
        patch.planeNormal = normal;
        patch.outline = std::move(outline);
        return patch;
    };
    std::vector<cadnext::kernel::PlanarFacePatch> cubeFaces{
        facePatch({{0,0,0}, {0,0,1}, {0,1,1}, {0,1,0}}, {-1,0,0}),
        facePatch({{1,0,0}, {1,1,0}, {1,1,1}, {1,0,1}}, {1,0,0}),
        facePatch({{0,0,0}, {1,0,0}, {1,0,1}, {0,0,1}}, {0,-1,0}),
        facePatch({{0,1,0}, {0,1,1}, {1,1,1}, {1,1,0}}, {0,1,0}),
        facePatch({{0,0,0}, {0,1,0}, {1,1,0}, {1,0,0}}, {0,0,-1}),
        facePatch({{0,0,1}, {1,0,1}, {1,1,1}, {0,1,1}}, {0,0,1}),
    };
    const auto sewnCube = kernel.makePlanarSolid(cubeFaces);
    assert(sewnCube.isOk() && kernel.isShapeValid(sewnCube.value()));
    const auto sewnVolume = kernel.volumeProperties(sewnCube.value());
    assert(sewnVolume.isOk() && std::fabs(sewnVolume.value().volumeM3 - 1.0) < 1e-9);
    cubeFaces.pop_back();
    assert(!kernel.makePlanarSolid(cubeFaces).isOk());

    // Exact degree-one XT B-spline curves and surfaces must sew into the
    // same watertight cube as their analytic counterparts.
    const auto analyticPolygon = [](const cadnext::kernel::PlanarFacePatch& planar) {
        cadnext::kernel::AnalyticFacePatch patch;
        patch.origin = planar.planeOrigin;
        patch.normal = planar.planeNormal;
        patch.xAxis = std::fabs(planar.planeNormal.x) > 0.5
            ? cadnext::Vector3{0, 1, 0} : cadnext::Vector3{1, 0, 0};
        std::vector<cadnext::kernel::AnalyticEdgeSegment> loop;
        for (std::size_t i = 0; i < planar.outline.size(); ++i) {
            cadnext::kernel::AnalyticEdgeSegment segment;
            segment.start = planar.outline[i];
            segment.end = planar.outline[(i + 1) % planar.outline.size()];
            loop.push_back(segment);
        }
        patch.loops.push_back(std::move(loop));
        return patch;
    };
    std::vector<cadnext::kernel::AnalyticFacePatch> splineCube;
    for (const auto& planar : cubeFaces)
        splineCube.push_back(analyticPolygon(planar));
    auto splineTop = analyticPolygon(facePatch(
        {{0,0,1}, {1,0,1}, {1,1,1}, {0,1,1}}, {0,0,1}));
    splineTop.kind = cadnext::kernel::AnalyticFacePatch::Kind::BSpline;
    splineTop.bspline.uDegree = 1;
    splineTop.bspline.vDegree = 1;
    splineTop.bspline.uPoleCount = 2;
    splineTop.bspline.vPoleCount = 2;
    splineTop.bspline.poles = {{0,0,1}, {0,1,1}, {1,0,1}, {1,1,1}};
    splineTop.bspline.weights = {1,1,1,1};
    splineTop.bspline.uKnots = {0,1};
    splineTop.bspline.vKnots = {0,1};
    splineTop.bspline.uMultiplicities = {2,2};
    splineTop.bspline.vMultiplicities = {2,2};
    auto& splineEdge = splineTop.loops.front().front();
    splineEdge.kind = cadnext::kernel::AnalyticEdgeKind::BSpline;
    splineEdge.bspline.degree = 1;
    splineEdge.bspline.poles = {{0,0,1}, {1,0,1}};
    splineEdge.bspline.weights = {1,1};
    splineEdge.bspline.knots = {0,1};
    splineEdge.bspline.multiplicities = {2,2};
    splineCube.push_back(std::move(splineTop));
    const auto splineSolid = kernel.makeAnalyticSolid(splineCube);
    if (!splineSolid.isOk())
        qFatal("B-spline cube: %s", splineSolid.error().message.c_str());
    assert(kernel.isShapeValid(splineSolid.value()));
    assert(surfaceCounts(kernel, splineSolid.value()).splines == 1);
    const auto splineVolume = kernel.volumeProperties(splineSolid.value());
    assert(splineVolume.isOk() &&
           std::fabs(splineVolume.value().volumeM3 - 1.0) < 1e-9);
    QTemporaryDir splineDirectory;
    assert(splineDirectory.isValid());
    const auto splineStepPath = splineDirectory.filePath(
        QStringLiteral("spline-face.step")).toStdString();
    assert(kernel.exportExchangeFile({{splineSolid.value(), {}}},
                                     splineStepPath).isOk());
    const auto splineRoundTrip = kernel.importExchangeFile(splineStepPath);
    assert(splineRoundTrip.isOk());
    assert(surfaceCounts(kernel, splineRoundTrip.value()).splines == 1);
    const auto splineRoundTripVolume = kernel.volumeProperties(splineRoundTrip.value());
    assert(splineRoundTripVolume.isOk() &&
           std::fabs(splineRoundTripVolume.value().volumeM3 - 1.0) < 1e-9);

    // A native cone patch is reconstructed from its exact Parasolid cone
    // surface and two circular boundary curves, then sewn to planar caps.
    const auto fullCircle = [](cadnext::Vector3 center, cadnext::Vector3 normal,
                               double radius) {
        cadnext::kernel::AnalyticEdgeSegment edge;
        edge.kind = cadnext::kernel::AnalyticEdgeKind::Circle;
        edge.hasEndpoints = false;
        edge.center = center;
        edge.normal = normal;
        edge.xAxis = {1, 0, 0};
        edge.radius = radius;
        return std::vector<cadnext::kernel::AnalyticEdgeSegment>{edge};
    };
    const double lowerRadius = 0.02;
    const double upperRadius = 0.03;
    const double height = 0.1;
    const double semiAngle = std::atan2(upperRadius - lowerRadius, height);
    cadnext::kernel::AnalyticFacePatch conePatch;
    conePatch.kind = cadnext::kernel::AnalyticFacePatch::Kind::Cone;
    conePatch.origin = {0, 0, 0};
    conePatch.normal = {0, 0, 1};
    conePatch.xAxis = {1, 0, 0};
    conePatch.radius = lowerRadius;
    conePatch.semiAngle = semiAngle;
    conePatch.loops = {fullCircle({0, 0, 0}, {0, 0, 1}, lowerRadius),
                       fullCircle({0, 0, height}, {0, 0, 1}, upperRadius)};
    cadnext::kernel::AnalyticFacePatch lowerCap;
    lowerCap.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    lowerCap.origin = {0, 0, 0};
    lowerCap.normal = {0, 0, -1};
    lowerCap.xAxis = {1, 0, 0};
    lowerCap.loops = {fullCircle({0, 0, 0}, {0, 0, 1}, lowerRadius)};
    cadnext::kernel::AnalyticFacePatch upperCap;
    upperCap.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    upperCap.origin = {0, 0, height};
    upperCap.normal = {0, 0, 1};
    upperCap.xAxis = {1, 0, 0};
    upperCap.loops = {fullCircle({0, 0, height}, {0, 0, 1}, upperRadius)};
    const auto coneSolid = kernel.makeAnalyticSolid({conePatch, lowerCap, upperCap});
    assert(coneSolid.isOk() && kernel.isShapeValid(coneSolid.value()));
    const auto coneVolume = kernel.volumeProperties(coneSolid.value());
    assert(coneVolume.isOk());
    const double expectedConeVolume = 3.14159265358979323846 * height / 3.0 *
        (lowerRadius * lowerRadius + lowerRadius * upperRadius +
         upperRadius * upperRadius);
    assert(std::fabs(coneVolume.value().volumeM3 - expectedConeVolume) < 1e-9);

    cadnext::kernel::AnalyticFacePatch torusPatch;
    torusPatch.kind = cadnext::kernel::AnalyticFacePatch::Kind::Torus;
    torusPatch.origin = {0, 0, 0};
    torusPatch.normal = {0, 0, 1};
    torusPatch.xAxis = {1, 0, 0};
    torusPatch.majorRadius = 0.03;
    torusPatch.minorRadius = 0.005;
    torusPatch.loops = {fullCircle({0, 0, 0}, {0, 0, 1}, 0.035),
                        fullCircle({0, 0, 0.005}, {0, 0, 1}, 0.03)};
    cadnext::kernel::AnalyticFacePatch torusLowerCap;
    torusLowerCap.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    torusLowerCap.origin = {0, 0, 0};
    torusLowerCap.normal = {0, 0, -1};
    torusLowerCap.xAxis = {1, 0, 0};
    torusLowerCap.loops = {fullCircle({0, 0, 0}, {0, 0, 1}, 0.035)};
    cadnext::kernel::AnalyticFacePatch torusUpperCap;
    torusUpperCap.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    torusUpperCap.origin = {0, 0, 0.005};
    torusUpperCap.normal = {0, 0, 1};
    torusUpperCap.xAxis = {1, 0, 0};
    torusUpperCap.loops = {fullCircle({0, 0, 0.005}, {0, 0, 1}, 0.03)};
    const auto torusSolid = kernel.makeAnalyticSolid(
        {torusPatch, torusLowerCap, torusUpperCap});
    assert(torusSolid.isOk() && kernel.isShapeValid(torusSolid.value()));
    const auto torusVolume = kernel.volumeProperties(torusSolid.value());
    assert(torusVolume.isOk() && torusVolume.value().volumeM3 > 0.0);

    // A quarter of a toroidal tube has rectangular torus patches bounded by
    // two meridian semicircles and two parallel quarter circles.
    constexpr double pi = 3.14159265358979323846;
    const double major = 0.03;
    const double minor = 0.005;
    const auto torusPoint = [&](double u, double v) -> cadnext::Vector3 {
        const double radial = major + minor * std::cos(v);
        return {radial * std::cos(u), radial * std::sin(u), minor * std::sin(v)};
    };
    const auto torusArc = [](cadnext::Vector3 center, cadnext::Vector3 normal,
                             cadnext::Vector3 xAxis, double radius,
                             cadnext::Vector3 start, cadnext::Vector3 end,
                             bool forward) {
        cadnext::kernel::AnalyticEdgeSegment edge;
        edge.kind = cadnext::kernel::AnalyticEdgeKind::Circle;
        edge.center = center;
        edge.normal = normal;
        edge.xAxis = xAxis;
        edge.radius = radius;
        edge.start = start;
        edge.end = end;
        edge.hasEndpoints = true;
        edge.forward = forward;
        return edge;
    };
    const auto meridian = [&](double u, double v0, double v1, bool forward) {
        return torusArc({major*std::cos(u), major*std::sin(u), 0},
            {std::sin(u), -std::cos(u), 0}, {0, 0, 1}, minor,
            torusPoint(u, v0), torusPoint(u, v1), forward);
    };
    const auto parallel = [&](double v, double u0, double u1, bool forward) {
        return torusArc({0, 0, minor*std::sin(v)}, {0, 0, 1}, {1, 0, 0},
            major + minor*std::cos(v), torusPoint(u0, v),
            torusPoint(u1, v), forward);
    };
    cadnext::kernel::AnalyticFacePatch outerQuarter = torusPatch;
    outerQuarter.loops = {{meridian(0, 0, pi, true),
                           parallel(pi, 0, pi/2, true),
                           meridian(pi/2, pi, 0, false),
                           parallel(0, pi/2, 0, false)}};
    cadnext::kernel::AnalyticFacePatch innerQuarter = torusPatch;
    innerQuarter.loops = {{meridian(0, pi, 2*pi, true),
                           parallel(2*pi, 0, pi/2, true),
                           meridian(pi/2, 2*pi, pi, false),
                           parallel(pi, pi/2, 0, false)}};
    cadnext::kernel::AnalyticFacePatch firstSection;
    firstSection.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    firstSection.origin = {major, 0, 0};
    firstSection.normal = {0, -1, 0};
    firstSection.xAxis = {0, 0, 1};
    firstSection.loops = {{meridian(0, 0, pi, true),
                           meridian(0, pi, 2*pi, true)}};
    cadnext::kernel::AnalyticFacePatch lastSection;
    lastSection.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    lastSection.origin = {0, major, 0};
    lastSection.normal = {1, 0, 0};
    lastSection.xAxis = {0, 0, 1};
    lastSection.loops = {{meridian(pi/2, 0, pi, true),
                          meridian(pi/2, pi, 2*pi, true)}};
    const auto quarterTorus = kernel.makeAnalyticSolid(
        {outerQuarter, innerQuarter, firstSection, lastSection});
    if (!quarterTorus.isOk())
        qInfo("quarter torus: %s",
              qPrintable(QString::fromStdString(quarterTorus.error().message)));
    assert(quarterTorus.isOk() && kernel.isShapeValid(quarterTorus.value()));
    const auto quarterVolume = kernel.volumeProperties(quarterTorus.value());
    assert(quarterVolume.isOk());
    assert(std::fabs(quarterVolume.value().volumeM3 -
                     pi*pi*major*minor*minor/2) < 1e-8);

    // A whole meridian can be split into arcs. It still bounds the same
    // toroidal band and must not enter the latitude-circle builder.
    auto band=torusPatch;
    band.loops={{meridian(0,pi,0,false),meridian(0,2*pi,pi,false)},
                {meridian(pi/2,0,pi,true),meridian(pi/2,pi,2*pi,true)}};
    const auto splitBand=kernel.makeAnalyticSolid({band,firstSection,lastSection});
    if(!splitBand.isOk()) qFatal("Split meridians: %s",splitBand.error().message.c_str());
    assert(kernel.isShapeValid(splitBand.value()));
    GProp_GProps bandVolume;
    BRepGProp::VolumeProperties(*kernel.findShape(splitBand.value()),bandVolume,1e-10,true);
    assert(std::fabs(bandVolume.Mass()/(pi*pi*major*minor*minor/2)-1)<1e-9);
    verifyNativeC3dBody(kernel,"split-meridians",splitBand.value());

    const double sphereRadius = 0.04;
    const double spherePlaneZ = 0.02;
    const double sphereCircleRadius = std::sqrt(
        sphereRadius * sphereRadius - spherePlaneZ * spherePlaneZ);
    cadnext::kernel::AnalyticFacePatch spherePatch;
    spherePatch.kind = cadnext::kernel::AnalyticFacePatch::Kind::Sphere;
    spherePatch.origin = {0, 0, 0};
    spherePatch.normal = {0, 0, 1};
    spherePatch.xAxis = {1, 0, 0};
    spherePatch.radius = sphereRadius;
    spherePatch.loops = {fullCircle({0, 0, spherePlaneZ}, {0, 0, 1},
                                    sphereCircleRadius)};
    cadnext::kernel::AnalyticFacePatch sphereCap;
    sphereCap.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    sphereCap.origin = {0, 0, spherePlaneZ};
    sphereCap.normal = {0, 0, 1};
    sphereCap.xAxis = {1, 0, 0};
    sphereCap.loops = {fullCircle({0, 0, spherePlaneZ}, {0, 0, 1},
                                  sphereCircleRadius)};
    const auto sphereSolid = kernel.makeAnalyticSolid({spherePatch, sphereCap});
    assert(sphereSolid.isOk() && kernel.isShapeValid(sphereSolid.value()));
    const auto sphereVolume = kernel.volumeProperties(sphereSolid.value());
    assert(sphereVolume.isOk() && sphereVolume.value().volumeM3 > 0.0);
    auto intersectedCap = sphereCap;
    cadnext::kernel::AnalyticEdgeSegment intersectionCircle;
    intersectionCircle.kind = cadnext::kernel::AnalyticEdgeKind::SurfaceIntersection;
    intersectionCircle.hasEndpoints = false;
    intersectionCircle.intersectionSurfaces[0].kind =
        cadnext::kernel::AnalyticSurfaceSupport::Kind::Plane;
    intersectionCircle.intersectionSurfaces[0].origin = {0, 0, spherePlaneZ};
    intersectionCircle.intersectionSurfaces[0].normal = {0, 0, 1};
    intersectionCircle.intersectionSurfaces[0].xAxis = {1, 0, 0};
    intersectionCircle.intersectionSurfaces[1].kind =
        cadnext::kernel::AnalyticSurfaceSupport::Kind::Sphere;
    intersectionCircle.intersectionSurfaces[1].origin = {0, 0, 0};
    intersectionCircle.intersectionSurfaces[1].normal = {0, 0, 1};
    intersectionCircle.intersectionSurfaces[1].xAxis = {1, 0, 0};
    intersectionCircle.intersectionSurfaces[1].radius = sphereRadius;
    intersectedCap.loops = {{intersectionCircle}};
    const auto intersectionSolid = kernel.makeAnalyticSolid(
        {spherePatch, intersectedCap});
    if (!intersectionSolid.isOk())
        qFatal("plane/sphere intersection: %s",
               intersectionSolid.error().message.c_str());
    const auto intersectionVolume = kernel.volumeProperties(intersectionSolid.value());
    assert(intersectionVolume.isOk());
    assert(std::fabs(intersectionVolume.value().volumeM3 -
                     sphereVolume.value().volumeM3) < 1e-10);
    auto offsetCap = sphereCap;
    auto offsetCircle = intersectionCircle;
    auto& offsetSupport = offsetCircle.intersectionSurfaces[0];
    offsetSupport.kind =
        cadnext::kernel::AnalyticSurfaceSupport::Kind::BSplineOffset;
    offsetSupport.offsetDistance = spherePlaneZ;
    offsetSupport.bspline.uDegree = 1;
    offsetSupport.bspline.vDegree = 1;
    offsetSupport.bspline.uPoleCount = 2;
    offsetSupport.bspline.vPoleCount = 2;
    offsetSupport.bspline.poles = {{-0.1,-0.1,0}, {-0.1,0.1,0},
                                   {0.1,-0.1,0}, {0.1,0.1,0}};
    offsetSupport.bspline.weights = {1,1,1,1};
    offsetSupport.bspline.uKnots = {0,1};
    offsetSupport.bspline.vKnots = {0,1};
    offsetSupport.bspline.uMultiplicities = {2,2};
    offsetSupport.bspline.vMultiplicities = {2,2};
    const double diagonal = sphereCircleRadius / std::sqrt(2.0);
    const cadnext::Vector3 splitA{-diagonal, -diagonal, spherePlaneZ};
    const cadnext::Vector3 splitB{sphereCircleRadius, 0, spherePlaneZ};
    const cadnext::Vector3 lowerMiddle{0, -sphereCircleRadius, spherePlaneZ};
    const cadnext::Vector3 upperMiddle{-sphereCircleRadius, 0, spherePlaneZ};
    const auto offsetArc = [&](cadnext::Vector3 start, cadnext::Vector3 end) {
        auto arc = offsetCircle;
        arc.hasEndpoints = true;
        arc.start = start;
        arc.end = end;
        return arc;
    };
    offsetCap.loops = {{offsetArc(splitA, lowerMiddle),
                        offsetArc(lowerMiddle, splitB),
                        offsetArc(splitB, upperMiddle),
                        offsetArc(upperMiddle, splitA)}};
    const auto offsetIntersectionSolid = kernel.makeAnalyticSolid(
        {spherePatch, offsetCap});
    if (!offsetIntersectionSolid.isOk())
        qFatal("B-spline offset/sphere intersection: %s",
               offsetIntersectionSolid.error().message.c_str());
    const auto offsetIntersectionVolume =
        kernel.volumeProperties(offsetIntersectionSolid.value());
    assert(offsetIntersectionVolume.isOk());
    assert(std::fabs(offsetIntersectionVolume.value().volumeM3 -
                     sphereVolume.value().volumeM3) < 1e-10);
    auto wrongOffsetCap = offsetCap;
    for (auto& edge : wrongOffsetCap.loops.front())
        edge.intersectionSurfaces[0].offsetDistance = -spherePlaneZ;
    assert(!kernel.makeAnalyticSolid({spherePatch, wrongOffsetCap}).isOk());
    auto offsetFace = sphereCap;
    offsetFace.kind = cadnext::kernel::AnalyticFacePatch::Kind::BSplineOffset;
    offsetFace.bspline = offsetSupport.bspline;
    offsetFace.offsetDistance = spherePlaneZ;
    const auto offsetFaceSolid = kernel.makeAnalyticSolid({spherePatch, offsetFace});
    if (!offsetFaceSolid.isOk())
        qFatal("B-spline offset face: %s",
               offsetFaceSolid.error().message.c_str());
    const auto offsetFaceVolume = kernel.volumeProperties(offsetFaceSolid.value());
    assert(offsetFaceVolume.isOk());
    assert(std::fabs(offsetFaceVolume.value().volumeM3 -
                     sphereVolume.value().volumeM3) < 1e-10);
    offsetFace.offsetDistance = -spherePlaneZ;
    assert(!kernel.makeAnalyticSolid({spherePatch, offsetFace}).isOk());

    // The sphere's XT frame may use Z while a trimmed cap is Y-normal.
    cadnext::kernel::AnalyticFacePatch transverseSphere = spherePatch;
    transverseSphere.loops = {fullCircle({0, spherePlaneZ, 0}, {0, 1, 0},
                                         sphereCircleRadius)};
    cadnext::kernel::AnalyticFacePatch transverseCap = sphereCap;
    transverseCap.origin = {0, spherePlaneZ, 0};
    transverseCap.normal = {0, 1, 0};
    transverseCap.xAxis = {1, 0, 0};
    transverseCap.loops = transverseSphere.loops;
    const auto transverseSolid = kernel.makeAnalyticSolid(
        {transverseSphere, transverseCap});
    assert(transverseSolid.isOk() && kernel.isShapeValid(transverseSolid.value()));
    const auto transverseVolume = kernel.volumeProperties(transverseSolid.value());
    assert(transverseVolume.isOk());
    assert(std::fabs(transverseVolume.value().volumeM3 -
                     sphereVolume.value().volumeM3) < 1e-8);

    // Three great-circle arcs bound one spherical octant. The complementary
    // region has the same edges, so this also tests the chosen surface side.
    constexpr double octantRadius = 0.02;
    const cadnext::Vector3 o{0, 0, 0};
    const cadnext::Vector3 a{octantRadius, 0, 0};
    const cadnext::Vector3 b{0, octantRadius, 0};
    const cadnext::Vector3 c{0, 0, octantRadius};
    const auto octantLine = [](cadnext::Vector3 start, cadnext::Vector3 end) {
        cadnext::kernel::AnalyticEdgeSegment edge;
        edge.kind = cadnext::kernel::AnalyticEdgeKind::Line;
        edge.start = start;
        edge.end = end;
        return edge;
    };
    const auto arcAB = torusArc(o, {0,0,1}, {1,0,0}, octantRadius, a, b, true);
    const auto arcBC = torusArc(o, {1,0,0}, {0,1,0}, octantRadius, b, c, true);
    const auto arcCA = torusArc(o, {0,1,0}, {0,0,1}, octantRadius, c, a, true);
    cadnext::kernel::AnalyticFacePatch octantSphere = spherePatch;
    octantSphere.radius = octantRadius;
    octantSphere.loops = {{arcAB, arcBC, arcCA}};
    cadnext::kernel::AnalyticFacePatch octantXY;
    octantXY.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    octantXY.origin = o;
    octantXY.normal = {0,0,-1};
    octantXY.xAxis = {1,0,0};
    octantXY.loops = {{octantLine(o,a), arcAB, octantLine(b,o)}};
    cadnext::kernel::AnalyticFacePatch octantYZ;
    octantYZ.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    octantYZ.origin = o;
    octantYZ.normal = {-1,0,0};
    octantYZ.xAxis = {0,1,0};
    octantYZ.loops = {{octantLine(o,b), arcBC, octantLine(c,o)}};
    cadnext::kernel::AnalyticFacePatch octantXZ;
    octantXZ.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    octantXZ.origin = o;
    octantXZ.normal = {0,-1,0};
    octantXZ.xAxis = {0,0,1};
    octantXZ.loops = {{octantLine(o,c), arcCA, octantLine(a,o)}};
    const auto sphereOctant = kernel.makeAnalyticSolid(
        {octantSphere, octantXY, octantYZ, octantXZ});
    if (!sphereOctant.isOk())
        qInfo("sphere octant: %s",
              qPrintable(QString::fromStdString(sphereOctant.error().message)));
    assert(sphereOctant.isOk() && kernel.isShapeValid(sphereOctant.value()));
    const auto octantVolume = kernel.volumeProperties(sphereOctant.value());
    assert(octantVolume.isOk());
    assert(std::fabs(octantVolume.value().volumeM3 -
                     pi * octantRadius * octantRadius * octantRadius / 6.0) < 1e-10);

    // A cylinder cut by two parallel inclined planes has exact elliptical
    // edges. Its 3D curves must be projected onto the cylindrical support.
    constexpr double trimmedRadius = 0.01;
    constexpr double trimmedLength = 0.04;
    constexpr double slope = 0.5;
    const auto cylinderPoint = [&](double x, double angle) -> cadnext::Vector3 {
        return {x + slope * trimmedRadius * std::cos(angle),
                trimmedRadius * std::cos(angle),
                trimmedRadius * std::sin(angle)};
    };
    const auto lineSegment = [](cadnext::Vector3 start, cadnext::Vector3 end) {
        cadnext::kernel::AnalyticEdgeSegment edge;
        edge.kind = cadnext::kernel::AnalyticEdgeKind::Line;
        edge.start = start;
        edge.end = end;
        edge.hasEndpoints = true;
        return edge;
    };
    const auto ellipseSegment = [&](double x, bool forward) {
        cadnext::kernel::AnalyticEdgeSegment edge;
        edge.kind = cadnext::kernel::AnalyticEdgeKind::Ellipse;
        edge.center = {x, 0, 0};
        edge.normal = {1, -slope, 0};
        edge.xAxis = {slope, 1, 0};
        edge.majorRadius = trimmedRadius * std::sqrt(1 + slope * slope);
        edge.minorRadius = trimmedRadius;
        edge.start = cylinderPoint(x, forward ? 0.0 : 3.14159265358979323846);
        edge.end = cylinderPoint(x, forward ? 3.14159265358979323846 : 0.0);
        edge.forward = forward;
        return edge;
    };
    const auto lo0 = cylinderPoint(0.0, 0.0);
    const auto lo1 = cylinderPoint(0.0, 3.14159265358979323846);
    const auto hi0 = cylinderPoint(trimmedLength, 0.0);
    const auto hi1 = cylinderPoint(trimmedLength, 3.14159265358979323846);
    cadnext::kernel::AnalyticFacePatch trimmedCylinder;
    trimmedCylinder.kind = cadnext::kernel::AnalyticFacePatch::Kind::Cylinder;
    trimmedCylinder.origin = {0, 0, 0};
    trimmedCylinder.normal = {1, 0, 0};
    trimmedCylinder.xAxis = {0, 1, 0};
    trimmedCylinder.radius = trimmedRadius;
    trimmedCylinder.loops = {{ellipseSegment(0.0, true), lineSegment(lo1, hi1),
                              ellipseSegment(trimmedLength, false), lineSegment(hi0, lo0)}};
    cadnext::kernel::AnalyticFacePatch slopedLower;
    slopedLower.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    slopedLower.origin = {0, 0, 0};
    slopedLower.normal = {-1, slope, 0};
    slopedLower.xAxis = {slope, 1, 0};
    slopedLower.loops = {{ellipseSegment(0.0, true), lineSegment(lo1, lo0)}};
    cadnext::kernel::AnalyticFacePatch slopedUpper;
    slopedUpper.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    slopedUpper.origin = {trimmedLength, 0, 0};
    slopedUpper.normal = {1, -slope, 0};
    slopedUpper.xAxis = {slope, 1, 0};
    slopedUpper.loops = {{ellipseSegment(trimmedLength, true), lineSegment(hi1, hi0)}};
    cadnext::kernel::AnalyticFacePatch flatSide;
    flatSide.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    flatSide.origin = {0, 0, 0};
    flatSide.normal = {0, 0, -1};
    flatSide.xAxis = {1, 0, 0};
    flatSide.loops = {{lineSegment(lo0, hi0), lineSegment(hi0, hi1),
                       lineSegment(hi1, lo1), lineSegment(lo1, lo0)}};
    const auto trimmedSolid = kernel.makeAnalyticSolid(
        {trimmedCylinder, slopedLower, slopedUpper, flatSide});
    if (!trimmedSolid.isOk())
        qInfo("trimmed cylinder: %s",
              qPrintable(QString::fromStdString(trimmedSolid.error().message)));
    assert(trimmedSolid.isOk() && kernel.isShapeValid(trimmedSolid.value()));
    const auto trimmedVolume = kernel.volumeProperties(trimmedSolid.value());
    assert(trimmedVolume.isOk());
    assert(std::fabs(trimmedVolume.value().volumeM3 -
                     0.5 * 3.14159265358979323846 * trimmedRadius *
                         trimmedRadius * trimmedLength) < 1e-8);

    const cadnext::Vector3 coneAxisLow{0, 0, 0};
    const cadnext::Vector3 coneAxisHigh{0, 0, height};
    const cadnext::Vector3 coneLowX{lowerRadius, 0, 0};
    const cadnext::Vector3 coneLowY{0, lowerRadius, 0};
    const cadnext::Vector3 coneHighX{upperRadius, 0, height};
    const cadnext::Vector3 coneHighY{0, upperRadius, height};
    const auto lowArc = torusArc(coneAxisLow, {0, 0, 1}, {1, 0, 0},
                                 lowerRadius, coneLowX, coneLowY, true);
    const auto highArc = torusArc(coneAxisHigh, {0, 0, 1}, {1, 0, 0},
                                  upperRadius, coneHighX, coneHighY, true);
    auto reverseArc = [](cadnext::kernel::AnalyticEdgeSegment edge) {
        std::swap(edge.start, edge.end);
        edge.forward = !edge.forward;
        return edge;
    };
    cadnext::kernel::AnalyticFacePatch coneQuarter = conePatch;
    coneQuarter.loops = {{lowArc, lineSegment(coneLowY, coneHighY),
                          reverseArc(highArc), lineSegment(coneHighX, coneLowX)}};
    cadnext::kernel::AnalyticFacePatch coneQuarterLow = lowerCap;
    coneQuarterLow.loops = {{lowArc, lineSegment(coneLowY, coneAxisLow),
                             lineSegment(coneAxisLow, coneLowX)}};
    cadnext::kernel::AnalyticFacePatch coneQuarterHigh = upperCap;
    coneQuarterHigh.loops = {{highArc, lineSegment(coneHighY, coneAxisHigh),
                              lineSegment(coneAxisHigh, coneHighX)}};
    cadnext::kernel::AnalyticFacePatch coneSideX;
    coneSideX.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    coneSideX.origin = coneAxisLow;
    coneSideX.normal = {0, -1, 0};
    coneSideX.xAxis = {1, 0, 0};
    coneSideX.loops = {{lineSegment(coneAxisLow, coneLowX),
                        lineSegment(coneLowX, coneHighX),
                        lineSegment(coneHighX, coneAxisHigh),
                        lineSegment(coneAxisHigh, coneAxisLow)}};
    cadnext::kernel::AnalyticFacePatch coneSideY;
    coneSideY.kind = cadnext::kernel::AnalyticFacePatch::Kind::Plane;
    coneSideY.origin = coneAxisLow;
    coneSideY.normal = {-1, 0, 0};
    coneSideY.xAxis = {0, 1, 0};
    coneSideY.loops = {{lineSegment(coneAxisLow, coneAxisHigh),
                        lineSegment(coneAxisHigh, coneHighY),
                        lineSegment(coneHighY, coneLowY),
                        lineSegment(coneLowY, coneAxisLow)}};
    const auto coneSector = kernel.makeAnalyticSolid(
        {coneQuarter, coneQuarterLow, coneQuarterHigh, coneSideX, coneSideY});
    if (!coneSector.isOk())
        qInfo("cone sector: %s",
              qPrintable(QString::fromStdString(coneSector.error().message)));
    assert(coneSector.isOk() && kernel.isShapeValid(coneSector.value()));
    const auto coneSectorVolume = kernel.volumeProperties(coneSector.value());
    assert(coneSectorVolume.isOk());
    assert(std::fabs(coneSectorVolume.value().volumeM3 -
                     expectedConeVolume/4) < 1e-8);

    const auto brep = kernel.exportBRepGeometry(box.value());
    assert(brep.isOk());
    const QByteArray shape(reinterpret_cast<const char*>(brep.value().data()),
                           brep.value().size());
    const QByteArray xml = R"(<Document SchemaVersion="4"><Objects Count="3">
<Object type="PartDesign::Body" name="Body"/>
<Object type="PartDesign::Pad" name="Pad"/>
<Object type="Part::Feature" name="Other"/>
</Objects><ObjectData Count="3">
<Object name="Body"><Properties>
<Property name="Label" type="App::PropertyString"><String value="Main body"/></Property>
<Property name="Group" type="App::PropertyLinkList"><LinkList><Link value="Pad"/></LinkList></Property>
<Property name="Shape" type="Part::PropertyPartShape"><Part file="Body.brp"/></Property>
</Properties></Object>
<Object name="Pad"><Properties>
<Property name="Shape" type="Part::PropertyPartShape"><Part file="Pad.brp"/></Property>
</Properties></Object>
<Object name="Other"><Properties>
<Property name="Label" type="App::PropertyString"><String value="Loose part"/></Property>
<Property name="Shape" type="Part::PropertyPartShape"><Part file="Other.brp"/></Property>
</Properties></Object>
</ObjectData></Document>)";
    QTemporaryDir directory;
    assert(directory.isValid());
    const QString path = directory.filePath(QStringLiteral("sample.FCStd"));
    QFile file(path);
    assert(file.open(QIODevice::WriteOnly));
    const QByteArray archive = zip({{"Document.xml", xml, true},
                                    {"Body.brp", shape, false},
                                    {"Pad.brp", shape, false},
                                    {"Other.brp", shape, false}});
    assert(file.write(archive) == archive.size());
    file.close();

    std::vector<cadnext::gui::FreeCadShape> shapes;
    QString error;
    assert(cadnext::gui::readFreeCadShapes(path, shapes, error));
    assert(shapes.size() == 2);
    assert(shapes[0].name == QStringLiteral("Main body"));
    assert(shapes[1].name == QStringLiteral("Loose part"));
    const auto* begin = reinterpret_cast<const std::uint8_t*>(shapes[0].brep.constData());
    const auto imported = kernel.importFreeCadBRep(
        std::vector<std::uint8_t>(begin, begin + shapes[0].brep.size()));
    assert(imported.isOk());
    const auto volume = kernel.volumeProperties(imported.value());
    assert(volume.isOk());
    assert(std::fabs(volume.value().volumeM3 - 1.0) < 1e-6);

    cadnext::Transform placement;
    placement.position = {0.125, -0.25, 0.5};
    const auto metreBox = kernel.makeBox({1, 1, 1});
    assert(metreBox.isOk());
    const auto freeCadBrep = kernel.exportFreeCadBRep({metreBox.value(), placement});
    assert(freeCadBrep.isOk());
    const auto& freeCadBytes = freeCadBrep.value();
    const QString exportedPath = directory.filePath(QStringLiteral("exported.FCStd"));
    assert(cadnext::gui::writeFreeCadShapes(exportedPath,
        {{QStringLiteral("Тело & 1"),
          QByteArray(reinterpret_cast<const char*>(freeCadBytes.data()),
                     qsizetype(freeCadBytes.size())), false}}, error));
    std::vector<cadnext::gui::FreeCadShape> exportedShapes;
    assert(cadnext::gui::readFreeCadShapes(exportedPath, exportedShapes, error));
    assert(exportedShapes.size() == 1);
    assert(exportedShapes[0].name == QStringLiteral("Тело & 1"));
    const auto* exportedBegin =
        reinterpret_cast<const std::uint8_t*>(exportedShapes[0].brep.constData());
    const auto exportedGeometry = kernel.importFreeCadBRep(
        std::vector<std::uint8_t>(exportedBegin,
                                  exportedBegin + exportedShapes[0].brep.size()));
    assert(exportedGeometry.isOk());
    const auto exportedBounds = kernel.boundingBox(exportedGeometry.value());
    assert(exportedBounds.isOk());
    assert(std::fabs(exportedBounds.value().min.x + 0.375) < 1e-6);
    assert(std::fabs(exportedBounds.value().min.y + 0.75) < 1e-6);
    assert(std::fabs(exportedBounds.value().min.z) < 1e-6);
    const auto exportedVolume = kernel.volumeProperties(exportedGeometry.value());
    assert(exportedVolume.isOk());
    assert(std::fabs(exportedVolume.value().volumeM3 - 1.0) < 1e-6);

    const QString assemblyPath = directory.filePath(QStringLiteral("sample.SLDASM"));
    QFile assembly(assemblyPath);
    assert(assembly.open(QIODevice::WriteOnly));
    const QByteArray manifest = R"(<swSolidWorks><swHeader>
<swFile id="1" swDocType="ASSEMBLY" swPath="C:\models\sample.SLDASM"/>
<swFile id="2" swDocType="PART" swPath="C:\models\Missing part.SLDPRT"/>
<swFile id="3" swDocType="PART" swPath="C:\models\Embedded.SLDPRT"/>
</swHeader><swModelList>
<swModel id="10" swFileRef="2"/><swModel id="11" swFileRef="3"/>
<swReference swModelRef="10" swName="Missing part" swIsVirtualComponent="NO"
 swTransform="1 0 0 0 0 1 0 0 0 0 1 0 2 3 4 1"/>
<swReference swModelRef="11" swName="Embedded" swIsVirtualComponent="YES"
 swTransform="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>
</swModelList></swSolidWorks>)";
    const QByteArray nativeAssembly = solidWorksAssembly(manifest);
    assert(assembly.write(nativeAssembly) == nativeAssembly.size());
    assembly.close();
    QStringList references;
    error.clear();
    assert(cadnext::gui::readSolidWorksAssemblyReferences(assemblyPath, references, error));
    assert(references == QStringList{QStringLiteral("C:\\models\\Missing part.SLDPRT")});
    std::vector<cadnext::gui::SolidWorksAssemblyComponent> components;
    assert(cadnext::gui::readSolidWorksAssemblyComponents(assemblyPath, components, error));
    assert(components.size() == 2);
    assert(components[0].name == QStringLiteral("Missing part"));
    assert(components[0].transform[12] == 2.0);
    assert(components[0].transform[13] == 3.0);
    assert(components[0].transform[14] == 4.0);
    assert(components[1].virtualComponent);
    assert(cadnext::gui::nativeCadImportDiagnostic(assemblyPath)
               .contains(QStringLiteral("Missing part.SLDPRT")));
    QByteArray badAssembly = nativeAssembly;
    badAssembly[30] = char(badAssembly[30] ^ 1);
    assert(assembly.open(QIODevice::WriteOnly | QIODevice::Truncate));
    assert(assembly.write(badAssembly) == badAssembly.size());
    assembly.close();
    components.clear();
    error.clear();
    assert(!cadnext::gui::readSolidWorksAssemblyComponents(
        assemblyPath, components, error));
    assert(error.contains(QStringLiteral("Контрольная сумма")));

    QByteArray nativeBody("PS\0\0", 4);
    const QByteArray model(": TRANSMIT FILE (partition) created by modeller version 3000269");
    const QByteArray schema("SCH_3000269_30000_13006");
    put16be(nativeBody, model.size());
    nativeBody.append(model);
    put32be(nativeBody, schema.size());
    nativeBody.append(schema);
    put16be(nativeBody, 205);
    put32be(nativeBody, 0);
    put16be(nativeBody, 101);
    const QString partPath = directory.filePath(QStringLiteral("sample.SLDPRT"));
    QFile part(partPath);
    assert(part.open(QIODevice::WriteOnly));
    assert(part.write(solidWorksPart(nativeBody)) > 0);
    part.close();
    std::vector<cadnext::gui::SolidWorksBodyStream> bodyStreams;
    error.clear();
    assert(cadnext::gui::readSolidWorksPartBodyStreams(partPath, bodyStreams, error));
    assert(bodyStreams.size() == 1);
    assert(bodyStreams[0].configuration == QStringLiteral("0"));
    assert(bodyStreams[0].kind == QStringLiteral("partition"));
    assert(bodyStreams[0].schemaKey == QStringLiteral("SCH_3000269_30000_13006"));
    assert(bodyStreams[0].maxNodeType == 205);
    assert(bodyStreams[0].userFieldSize == 0);
    assert(bodyStreams[0].rootNodeType == 101);
    assert(bodyStreams[0].nodeDataOffset == nativeBody.size() - 2);
    assert(bodyStreams[0].parasolid == nativeBody);
    assert(cadnext::gui::nativeCadImportDiagnostic(partPath)
               .contains(QStringLiteral("Parasolid")));
    assert(part.open(QIODevice::WriteOnly | QIODevice::Truncate));
    assert(part.write(solidWorksPart(nativeBody, true)) > 0);
    part.close();
    bodyStreams.clear();
    error.clear();
    assert(!cadnext::gui::readSolidWorksPartBodyStreams(partPath, bodyStreams, error));
    assert(bodyStreams.empty());

    // Two configurations of one part, with non-ordinal storage ids and Unicode names.
    // Delta streams contain rollback history: selecting a configuration uses its current partition.
    const auto configuredBox = kernel.makeBox({1, 1, 1});
    const auto longer = kernel.makeBox({2, 1, 1});
    assert(configuredBox.isOk() && longer.isOk());
    const auto firstPartition = cadnext::gui::encodeParasolidXtPartition(kernel, configuredBox.value());
    const auto secondPartition = cadnext::gui::encodeParasolidXtPartition(kernel, longer.value());
    assert(firstPartition.isOk() && secondPartition.isOk());
    QByteArray history = nativeBody;
    const int modelLength = model.size();
    const QByteArray historyModel = QByteArray(model).replace("(partition)", "(deltas)");
    history.replace(4, 2 + modelLength, QByteArray());
    QByteArray historyHeader;
    put16be(historyHeader, historyModel.size()); historyHeader += historyModel;
    history.insert(4, historyHeader);
    history[history.size() - 1] = 3; // opaque delta root; it is not a BODY or a current WORLD
    const QByteArray names = configurationNames({{17, QStringLiteral("Основная")},
                                                 {29, QStringLiteral("Длинная")}});
    QByteArray configurationsFile = solidWorksPart(QByteArray::fromStdString(firstPartition.value()), false, "17", history);
    configurationsFile += solidWorksPart(QByteArray::fromStdString(secondPartition.value()), false, "29").mid(16);
    configurationsFile += solidWorksMember("Contents/CMgrHdr2", names);
    const QString configuredPath = directory.filePath(QStringLiteral("configured.SLDPRT"));
    const auto save = [&](const QString& path, const QByteArray& bytes) {
        QFile file(path);
        assert(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        assert(file.write(bytes) == bytes.size());
    };
    save(configuredPath, configurationsFile);
    std::vector<cadnext::gui::SolidWorksConfiguration> configurations;
    assert(cadnext::gui::readSolidWorksPartConfigurations(configuredPath, configurations, error));
    assert(configurations.size() == 2 && configurations[0].id == QStringLiteral("17") &&
           configurations[0].name == QStringLiteral("Основная") && configurations[1].id == QStringLiteral("29") &&
           configurations[1].name == QStringLiteral("Длинная"));
    assert(cadnext::gui::readSolidWorksPartBodyStreams(configuredPath, bodyStreams, error));
    assert(bodyStreams.size() == 3 && bodyStreams[1].kind == QStringLiteral("deltas"));
    cadnext::kernel::ShapeHandle configuredShape;
    assert(!cadnext::gui::readSolidWorksAnalyticPart(configuredPath, kernel, configuredShape, error));
    assert(error.contains(QStringLiteral("выберите")));
    assert(!cadnext::gui::readSolidWorksAnalyticPart(configuredPath, kernel, configuredShape, error, nullptr,
                                                   QStringLiteral("Несуществующая")));
    const auto volumeIs = [&](const cadnext::kernel::ShapeHandle& shape, double expected) {
        const auto mass = kernel.volumeProperties(shape);
        if (!mass.isOk() || std::fabs(mass.value().volumeM3 - expected) >= 1e-9)
            qFatal("Configuration volume: expected %.17g, actual %.17g", expected,
                   mass.isOk() ? mass.value().volumeM3 : -1.0);
        assert(kernel.isShapeValid(shape));
    };
    for (const auto& [configuration, expected] : std::vector<std::pair<QString, double>>{
             {QStringLiteral("Основная"), 1}, {QStringLiteral("Длинная"), 2},
             {QStringLiteral("Config-17"), 1}, {QStringLiteral("29"), 2}}) {
        assert(cadnext::gui::readSolidWorksAnalyticPart(configuredPath, kernel, configuredShape, error, nullptr, configuration));
        volumeIs(configuredShape, expected);
        assert(cadnext::gui::readSolidWorksPlanarPart(configuredPath, kernel, configuredShape, error, configuration));
        volumeIs(configuredShape, expected);
    }
    const QByteArray twoConfigurations = QStringLiteral(R"(<swSolidWorks><swHeader>
<swFile id="1" swDocType="PART" swPath="C:\models\configured.SLDPRT"/>
</swHeader><swModelList><swModel id="10" swFileRef="1"/>
<swReference swModelRef="10" swName="Первый" swConfigurationName="Основная" swIsVirtualComponent="NO"
 swTransform="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>
<swReference swModelRef="10" swName="Длинный" swConfigurationName="Длинная" swIsVirtualComponent="NO"
 swTransform="1 0 0 0 0 1 0 0 0 0 1 0 3 0 0 1"/>
<swReference swModelRef="10" swName="Повтор" swConfigurationName="Основная" swIsVirtualComponent="NO"
 swTransform="1 0 0 0 0 1 0 0 0 0 1 0 6 0 0 1"/>
</swModelList></swSolidWorks>)").toUtf8();
    const QString configuredAssembly = directory.filePath(QStringLiteral("configured.SLDASM"));
    save(configuredAssembly, solidWorksAssembly(twoConfigurations));
    std::vector<cadnext::gui::SolidWorksImportedBody> configuredBodies;
    for (bool planar : {false, true}) {
        const bool read = planar
            ? cadnext::gui::readSolidWorksPlanarAssembly(configuredAssembly, kernel, configuredBodies, error)
            : cadnext::gui::readSolidWorksAnalyticAssembly(configuredAssembly, kernel, configuredBodies, error);
        if (!read) qFatal("Configuration assembly: %s", qPrintable(error));
        assert(configuredBodies.size() == 3);
        for (int i = 0; i < 3; ++i) {
            volumeIs(configuredBodies[i].shape, i == 1 ? 2 : 1);
            const auto bounds = kernel.boundingBox(configuredBodies[i].shape);
            const auto mass = kernel.volumeProperties(configuredBodies[i].shape);
            assert(bounds.isOk() && mass.isOk() && std::fabs(mass.value().centerOfMass.x - 3.0 * i) < 1e-9);
        }
    }
    cadnext::kernel::ProductStructure configuredProduct;
    assert(cadnext::gui::readSolidWorksAssemblyProduct(configuredAssembly, kernel, configuredProduct, error));
    assert(configuredProduct.parts.size() == 2 && configuredProduct.assemblies.size() == 1);
    const auto& instances = configuredProduct.assemblies[0].instances;
    assert(instances.size() == 3 && instances[0].definition == instances[2].definition &&
           instances[0].definition != instances[1].definition);
    volumeIs(configuredProduct.parts[instances[0].definition].shape, 1);
    volumeIs(configuredProduct.parts[instances[1].definition].shape, 2);

    // A corrupt or duplicate-name directory must not silently select the first configuration.
    const QByteArray geometryOnly = configurationsFile.left(configurationsFile.size() -
        solidWorksMember("Contents/CMgrHdr2", names).size());
    for (const QByteArray& directoryEntry : {
             solidWorksMember("Contents/CMgrHdr2", names, true),
             solidWorksMember("Contents/CMgrHdr2", names.left(names.size() - 1)),
             solidWorksMember("Contents/CMgrHdr2", configurationNames({{17, QStringLiteral("Одна")},
                                                                      {29, QStringLiteral("Одна")}}))}) {
        save(configuredPath, geometryOnly + directoryEntry);
        assert(!cadnext::gui::readSolidWorksPartConfigurations(configuredPath, configurations, error));
        assert(configurations.empty());
    }

    const QDir mtc(QDir(qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + QStringLiteral("/cadnext-samples")))
                       .filePath(QStringLiteral("nist/NIST-MTC-Assembly/SolidWorks")));
    if (mtc.exists()) {
        const QStringList parts = mtc.entryList({QStringLiteral("*.SLDPRT")}, QDir::Files);
        assert(parts.size() == 8);
        for (const QString& file : parts) {
            assert(cadnext::gui::readSolidWorksPartConfigurations(mtc.filePath(file), configurations, error));
            const QString name = file.startsWith(QStringLiteral("nist_")) ? QStringLiteral("Default") : file.left(9);
            const QString id = name == QStringLiteral("90591A141") ? QStringLiteral("809") :
                               name == QStringLiteral("91274A118") ? QStringLiteral("4455") :
                               name == QStringLiteral("91274A141") ? QStringLiteral("4470") :
                               name == QStringLiteral("91304A112") ? QStringLiteral("1644") : QStringLiteral("0");
            assert(configurations.size() == 1 && configurations[0].name == name && configurations[0].id == id);
        }
    }

    const QString nistDirectory = qEnvironmentVariable("CADNEXT_TEST_NIST_DIR");
    if (!nistDirectory.isEmpty()) {
        const QDir nist(nistDirectory);
        const QStringList files = nist.entryList({QStringLiteral("*.SLDPRT")}, QDir::Files);
        assert(files.size() >= 2);
        for (const QString& name : files) {
            bodyStreams.clear();
            error.clear();
            assert(cadnext::gui::readSolidWorksPartBodyStreams(
                nist.filePath(name), bodyStreams, error));
            assert(bodyStreams.size() >= 2);
            assert(bodyStreams[0].kind == QStringLiteral("partition"));
            assert(bodyStreams[1].kind == QStringLiteral("deltas"));
            assert(bodyStreams[0].rootNodeType == 101);
            assert(bodyStreams[0].rootNodeIndex == 1);
            assert(bodyStreams[0].firstBodyNodeIndex > 0);
            assert(bodyStreams[0].nextNodeType == 12);
            assert(bodyStreams[0].firstBodyKind == 1);
            assert(bodyStreams[0].firstRegionNodeIndex > 0);
            assert(bodyStreams[0].firstShellNodeIndex > 0);
            assert(bodyStreams[1].rootNodeType == 3);
            cadnext::gui::ParasolidXtTopology topology;
            if (!cadnext::gui::readParasolidXtTopology(
                    bodyStreams[0].parasolid, topology, error)) {
                qFatal("XT topology in %s: %s", qPrintable(name), qPrintable(error));
            }
            assert(topology.nodeCount > 100);
            std::map<quint16, int> surfaces, curves;
            for (const auto& face : topology.faces)
                ++surfaces[topology.nodeTypes.value(face.surfaceIndex)];
            for (const auto& edge : topology.edges)
                ++curves[topology.nodeTypes.value(edge.curveIndex)];
            qInfo("NIST %s: faces=%d plane=%d cylinder=%d cone=%d sphere=%d torus=%d; edges=%d line=%d circle=%d ellipse=%d intersection=%d",
                  qPrintable(name), int(topology.faces.size()), surfaces[50],
                  surfaces[51], surfaces[52], surfaces[53], surfaces[54],
                  int(topology.edges.size()),
                  curves[30], curves[31], curves[32], curves[38]);
            QHash<quint32, const cadnext::gui::ParasolidXtAnalyticGeometry*> geometryNodes;
            for (const auto& item : topology.analyticGeometry)
                geometryNodes.insert(item.index, &item);
            for (const auto& item : topology.analyticGeometry) {
                if (item.type == 59) {
                    assert(item.integers.value("boundary") <= 1);
                    assert(topology.nodeTypes.value(item.links.value("blend")) == 56);
                } else if (item.type == 60) {
                    const auto* base = geometryNodes.value(
                        item.links.value("surface"), nullptr);
                    assert(base && base->type == 124);
                    assert(item.sense == base->sense);
                    assert(std::isfinite(item.reals.value("offset")));
                    assert(std::fabs(item.reals.value("offset")) > 1e-12);
                }
            }
            int splineDefinitions = 0;
            for (const auto& item : topology.analyticGeometry) {
                if (item.type != 126 && item.type != 136) continue;
                const bool surface = item.type == 126;
                const quint32 uCount = item.integers.value(
                    surface ? "n_u_vertices" : "n_vertices");
                const quint32 vCount = surface ? item.integers.value("n_v_vertices") : 1;
                const quint32 dimension = item.integers.value("vertex_dim");
                const auto* poles = geometryNodes.value(
                    item.links.value("bspline_vertices"), nullptr);
                assert(poles && poles->type == 45);
                assert(dimension == (item.bytes.value("rational") ? 4u : 3u));
                assert(poles->realArrays.value("vertices").size() >=
                       uCount * vCount * dimension);
                const auto checkKnots = [&](const char* multName, const char* knotName,
                                            quint32 expected) {
                    const auto* mult = geometryNodes.value(item.links.value(multName), nullptr);
                    const auto* knots = geometryNodes.value(item.links.value(knotName), nullptr);
                    assert(mult && mult->type == 127 && knots && knots->type == 128);
                    // Real XT array nodes can carry trailing reserved values;
                    // the NURBS definition supplies the effective count.
                    assert(mult->integerArrays.value("mult").size() >= expected);
                    assert(knots->realArrays.value("knots").size() >= expected);
                };
                checkKnots(surface ? "u_knot_mult" : "knot_mult",
                           surface ? "u_knots" : "knots",
                           item.integers.value(surface ? "n_u_knots" : "n_knots"));
                if (surface)
                    checkKnots("v_knot_mult", "v_knots",
                               item.integers.value("n_v_knots"));
                ++splineDefinitions;
            }
            if (name == QStringLiteral("nist_ctc_02_asme1_rc_sw1802.SLDPRT") ||
                name == QStringLiteral("nist_ftc_07_asme1_rd_sw1802.SLDPRT"))
                assert(splineDefinitions > 0);
            if (name == QStringLiteral("nist_ctc_01_asme1_rd_sw1802.SLDPRT")) {
                int intersectionCount = 0;
                for (const auto& geometry : topology.analyticGeometry) {
                    if (geometry.type != 38) continue;
                    const auto pair = geometry.linkArrays.value("surface");
                    assert(pair.size() == 2);
                    assert(topology.nodeTypes.value(pair[0]) == 51);
                    assert(topology.nodeTypes.value(pair[1]) == 51);
                    ++intersectionCount;
                }
                assert(intersectionCount == 4);
            }
            if (surfaces[50] + surfaces[51] + surfaces[52] + surfaces[53] +
                surfaces[54] == int(topology.faces.size()) &&
                curves[30] + curves[31] + curves[32] + curves[38] ==
                    int(topology.edges.size())) {
                cadnext::kernel::ShapeHandle analyticShape;
                QString analyticError;
                const bool analyticOk = cadnext::gui::readSolidWorksAnalyticPart(
                    nist.filePath(name), kernel, analyticShape, analyticError);
                qInfo("NIST %s analytic solid: %d %s", qPrintable(name),
                      int(analyticOk), qPrintable(analyticError));
                if (name == QStringLiteral("nist_ctc_01_asme1_rd_sw1802.SLDPRT"))
                    assert(analyticOk);
                if (name == QStringLiteral("nist_ctc_03_asme1_rc_sw1802.SLDPRT"))
                    assert(analyticOk);
                if (name == QStringLiteral("nist_ctc_04_asme1_rd_sw1802.SLDPRT"))
                    assert(analyticOk);
                if (name == QStringLiteral("nist_ftc_06_asme1_rd_sw1802.SLDPRT"))
                    assert(analyticOk);
                if (name == QStringLiteral("nist_ftc_08_asme1_rc_sw1802.SLDPRT"))
                    assert(analyticOk);
                if (name == QStringLiteral("nist_ftc_11_asme1_rb_sw1802.SLDPRT"))
                    assert(analyticOk);
                if (name == QStringLiteral("nist_ftc_09_asme1_rd_sw1802.SLDPRT"))
                    assert(analyticOk);
                if (analyticOk) {
                    const auto volume = kernel.volumeProperties(analyticShape);
                    assert(volume.isOk());
                    assert(kernel.isShapeValid(analyticShape));
                    const auto surfaces = surfaceCounts(kernel, analyticShape);
                    assert(surfaces.faces == int(topology.faces.size()));
                    if (name == QStringLiteral("nist_ctc_03_asme1_rc_sw1802.SLDPRT"))
                        assert(surfaces.planes == 86 && surfaces.cylinders == 53 &&
                               surfaces.tori == 0);
                    if (name == QStringLiteral("nist_ftc_11_asme1_rb_sw1802.SLDPRT"))
                        assert(surfaces.planes == 2 && surfaces.cylinders == 2 &&
                               surfaces.cones == 0 && surfaces.tori == 2);
                    if (name == QStringLiteral("nist_ftc_09_asme1_rd_sw1802.SLDPRT"))
                        assert(surfaces.planes == 62 && surfaces.cylinders == 59 &&
                               surfaces.cones == 4 && surfaces.tori == 0);
                    qInfo("NIST %s analytic volume %.12g", qPrintable(name),
                          volume.value().volumeM3);
                    const QString exportPath = directory.filePath(
                        name + QStringLiteral("-analytic.step"));
                    assert(kernel.exportExchangeFile({{analyticShape, {}}},
                                                     exportPath.toStdString()).isOk());
                    const auto roundTrip = kernel.importExchangeFile(
                        exportPath.toStdString());
                    assert(roundTrip.isOk());
                    const auto roundTripVolume = kernel.volumeProperties(roundTrip.value());
                    assert(roundTripVolume.isOk());
                    assert(std::fabs(roundTripVolume.value().volumeM3 -
                                     volume.value().volumeM3) <
                           volume.value().volumeM3 * 1e-7);
                    QString referenceName = name;
                    referenceName.replace(QStringLiteral("_sw1802.SLDPRT"),
                                          QStringLiteral(".stp"));
                    const QString referencePath = nist.filePath(referenceName);
                    if (QFile::exists(referencePath)) {
                        const auto reference = kernel.importExchangeFile(
                            referencePath.toStdString());
                        assert(reference.isOk());
                        const auto expected = kernel.volumeProperties(reference.value());
                        assert(expected.isOk());
                        if (name == QStringLiteral("nist_ftc_08_asme1_rc_sw1802.SLDPRT")) {
                            const auto sphereArea = [](const TopoDS_Shape& shape) {
                                double area = 0.0;
                                for (TopExp_Explorer it(shape, TopAbs_FACE); it.More(); it.Next()) {
                                    const auto face = TopoDS::Face(it.Current());
                                    if (BRepAdaptor_Surface(face).GetType() != GeomAbs_Sphere)
                                        continue;
                                    GProp_GProps properties;
                                    BRepGProp::SurfaceProperties(face, properties);
                                    area += properties.Mass();
                                }
                                return area;
                            };
                            const auto* nativeShape = kernel.findShape(analyticShape);
                            const auto* stepShape = kernel.findShape(reference.value());
                            assert(nativeShape && stepShape);
                            // The reference CAD varies by a few micrometres in
                            // overall size; the spherical patches retain the
                            // same exact radius and area. This catches the
                            // complementary-patch ambiguity on a sphere.
                            assert(std::fabs(sphereArea(*nativeShape) -
                                             sphereArea(*stepShape)) < 1e-8);
                        }
                        qInfo("NIST %s STEP reference volume %.12g relerr %.12g",
                              qPrintable(name), expected.value().volumeM3,
                              std::fabs(volume.value().volumeM3 - expected.value().volumeM3) /
                                  expected.value().volumeM3);
                        if (name == QStringLiteral("nist_ctc_01_asme1_rd_sw1802.SLDPRT"))
                            assert(std::fabs(volume.value().volumeM3 -
                                             expected.value().volumeM3) <
                                   expected.value().volumeM3 * 1e-5);
                    }
                }
            } else {
                cadnext::kernel::ShapeHandle unsupportedShape;
                QString unsupportedError;
                const bool imported = cadnext::gui::readSolidWorksAnalyticPart(
                    nist.filePath(name), kernel, unsupportedShape, unsupportedError);
                if (imported) {
                    assert(kernel.isShapeValid(unsupportedShape));
                    assert(surfaceCounts(kernel, unsupportedShape).faces ==
                           int(topology.faces.size()));
                    const auto volume = kernel.volumeProperties(unsupportedShape);
                    assert(volume.isOk() && volume.value().volumeM3 > 0.0);
                    const QString exportPath = directory.filePath(
                        name + QStringLiteral("-analytic.step"));
                    assert(kernel.exportExchangeFile({{unsupportedShape, {}}},
                                                     exportPath.toStdString()).isOk());
                    const auto roundTrip = kernel.importExchangeFile(
                        exportPath.toStdString());
                    assert(roundTrip.isOk());
                    const auto roundTripVolume = kernel.volumeProperties(roundTrip.value());
                    assert(roundTripVolume.isOk());
                    assert(std::fabs(roundTripVolume.value().volumeM3 -
                                     volume.value().volumeM3) <
                           volume.value().volumeM3 * 1e-7);
                    qInfo("NIST %s analytic solid: faces=%d volume=%.12g",
                          qPrintable(name), int(topology.faces.size()),
                          volume.value().volumeM3);
                } else {
                    assert(!unsupportedError.isEmpty());
                    assert(!unsupportedError.contains(
                        QStringLiteral("Некорректное определение B-сплайн")));
                    qInfo("NIST %s unsupported: %s", qPrintable(name),
                          qPrintable(unsupportedError));
                }
            }
            assert(topology.bodyCount == 1);
            assert(topology.shellCount >= 1);
            assert(topology.regionCount >= 1);
            assert(!topology.edges.empty());
            assert(!topology.faces.empty());
            assert(!topology.loops.empty());
            assert(!topology.fins.empty());
            assert(!topology.analyticGeometry.empty());
            const auto planarFaces = cadnext::gui::parasolidXtPlanarFaces(topology);
            std::vector<cadnext::gui::ParasolidXtFaceWire> wires;
            if (!cadnext::gui::parasolidXtFaceWires(topology, wires, error)) {
                qFatal("XT face wires in %s: %s", qPrintable(name), qPrintable(error));
            }
            assert(wires.size() == topology.loops.size());
            std::size_t segmentCount = 0;
            for (const auto& wire : wires) {
                assert(!wire.segments.empty());
                for (const auto& segment : wire.segments) {
                    if (segment.edgeIndex == 0) {
                        assert(segment.curveIndex == 0 && segment.curveType == 0);
                        assert(segment.hasEndpoints);
                        assert(segment.start == segment.end);
                    } else {
                        assert(segment.curveType > 0);
                    }
                    segmentCount++;
                }
            }
            assert(segmentCount == topology.fins.size());
            std::map<quint32, const cadnext::gui::ParasolidXtAnalyticGeometry*> ellipses;
            for (const auto& geometry : topology.analyticGeometry) {
                if (geometry.type == 53) {
                    assert(geometry.vectors.contains("axis"));
                    assert(geometry.vectors.contains("x_axis"));
                }
                if (geometry.type != 32) continue;
                assert(geometry.sense == '+' || geometry.sense == '-');
                assert(geometry.reals.value("major_radius") >=
                       geometry.reals.value("minor_radius"));
                assert(geometry.reals.value("minor_radius") > 0.0);
                ellipses[geometry.index] = &geometry;
            }
            for (const auto& wire : wires) {
                for (const auto& segment : wire.segments) {
                    if (segment.curveType != 32 || !segment.hasEndpoints) continue;
                    const auto found = ellipses.find(segment.curveIndex);
                    assert(found != ellipses.end());
                    const auto center = found->second->vectors.value("centre");
                    const double minor = found->second->reals.value("minor_radius");
                    const double major = found->second->reals.value("major_radius");
                    for (const auto& endpoint : {segment.start, segment.end}) {
                        const double distance = std::hypot(endpoint[0] - center[0],
                            endpoint[1] - center[1], endpoint[2] - center[2]);
                        assert(std::isfinite(distance));
                        assert(distance >= minor - 1e-7 && distance <= major + 1e-7);
                    }
                }
            }
            for (const auto& vertex : topology.vertices) {
                assert(vertex.pointIndex > 0);
                for (double coordinate : vertex.position)
                    assert(std::isfinite(coordinate));
            }
            if (!planarFaces.empty()) {
                std::vector<cadnext::kernel::PlanarFacePatch> patches;
                for (const auto& face : planarFaces) {
                    cadnext::kernel::PlanarFacePatch patch;
                    for (const auto& point : face.outline)
                        patch.outline.push_back({point[0], point[1], point[2]});
                    patch.planeOrigin = {face.planeOrigin[0], face.planeOrigin[1],
                                         face.planeOrigin[2]};
                    patch.planeNormal = {face.planeNormal[0], face.planeNormal[1],
                                         face.planeNormal[2]};
                    patches.push_back(std::move(patch));
                }
                const auto exactFaces = kernel.makePlanarFaceCompound(patches);
                if (!exactFaces.isOk()) {
                    qFatal("OCCT planar faces in %s: %s", qPrintable(name),
                           exactFaces.error().message.c_str());
                }
                assert(kernel.isShapeValid(exactFaces.value()));
                if (name == QStringLiteral("nist_ctc_01_asme1_rd_sw1802.SLDPRT")) {
                    const auto faceBounds = kernel.boundingBox(exactFaces.value());
                    assert(faceBounds.isOk());
                    assert(faceBounds.value().min.x >= -0.401);
                    assert(faceBounds.value().max.x <= 0.401);
                }
            }
            if (name == QStringLiteral("nist_ctc_01_asme1_rd_sw1802.SLDPRT")) {
                assert(planarFaces.size() == 69);
                auto brokenTopology = topology;
                brokenTopology.fins.front().forwardIndex = 0;
                assert(!cadnext::gui::parasolidXtFaceWires(
                    brokenTopology, wires, error));
                assert(wires.empty());
                assert(cadnext::gui::nativeCadImportDiagnostic(nist.filePath(name))
                           .contains(QStringLiteral("139 граней")));
                assert(topology.nodeCount == 3761);
                assert(topology.pointCount == 230);
                assert(topology.vertices.size() == 230);
                assert(topology.faces.size() == 139);
                assert(topology.loops.size() == 176);
                assert(topology.fins.size() == 742);
                bool foundCylinder = false;
                for (const auto& geometry : topology.analyticGeometry) {
                    if (geometry.type != 51) continue;
                    assert(geometry.vectors.contains("axis"));
                    assert(geometry.reals.value("radius") > 0.0);
                    foundCylinder = true;
                    break;
                }
                assert(foundCylinder);
                assert(std::fabs(topology.pointMin[0] + 0.4) < 1e-10);
                assert(std::fabs(topology.pointMax[0] - 0.4) < 1e-10);
                assert(std::fabs(topology.pointMin[2] + 0.1) < 1e-10);
                assert(std::fabs(topology.pointMax[2] - 0.05) < 1e-10);
                QByteArray truncated = bodyStreams[0].parasolid;
                truncated.chop(4); // Removes the required XT terminator.
                cadnext::gui::ParasolidXtTopology incomplete;
                assert(!cadnext::gui::readParasolidXtTopology(
                    truncated, incomplete, error));
            }
            if (name == QStringLiteral("nist_ftc_11_asme1_rb_sw1802.SLDPRT")) {
                assert(topology.vertices.empty());
                assert(topology.faces.size() == 6);
            }
            for (const auto& item : bodyStreams) {
                assert(item.parasolid.startsWith(QByteArray("PS\0\0", 4)));
                assert(item.schemaKey.startsWith(QStringLiteral("SCH_")));
            }
        }
    }

    const QString planarPart = qEnvironmentVariable("CADNEXT_TEST_PLANAR_SLDPRT");
    if (!planarPart.isEmpty()) {
        cadnext::kernel::ShapeHandle directShape;
        error.clear();
        assert(cadnext::gui::readSolidWorksPlanarPart(
            planarPart, kernel, directShape, error));
        const auto directVolume = kernel.volumeProperties(directShape);
        assert(directVolume.isOk());
        assert(std::fabs(directVolume.value().volumeM3 - 0.02 * 0.08 * 0.25) < 1e-10);
        cadnext::kernel::ShapeHandle analyticBox;
        QString analyticError;
        const bool analyticBoxOk = cadnext::gui::readSolidWorksAnalyticPart(
            planarPart, kernel, analyticBox, analyticError);
        if (!analyticBoxOk)
            qFatal("Analytic SolidWorks box: %s", qPrintable(analyticError));
        const auto analyticBoxVolume = kernel.volumeProperties(analyticBox);
        assert(analyticBoxVolume.isOk());
        assert(std::fabs(analyticBoxVolume.value().volumeM3 -
                         directVolume.value().volumeM3) < 1e-10);
        bodyStreams.clear();
        error.clear();
        assert(cadnext::gui::readSolidWorksPartBodyStreams(
            planarPart, bodyStreams, error));
        assert(bodyStreams.size() == 2);
        cadnext::gui::ParasolidXtTopology topology;
        assert(cadnext::gui::readParasolidXtTopology(
            bodyStreams.front().parasolid, topology, error));
        assert(topology.bodyCount == 1);
        assert(topology.faces.size() == 6);
        const auto planarFaces = cadnext::gui::parasolidXtPlanarFaces(topology);
        assert(planarFaces.size() == topology.faces.size());
        std::vector<cadnext::kernel::PlanarFacePatch> patches;
        for (const auto& face : planarFaces) {
            cadnext::kernel::PlanarFacePatch patch;
            for (const auto& point : face.outline)
                patch.outline.push_back({point[0], point[1], point[2]});
            patch.planeOrigin = {face.planeOrigin[0], face.planeOrigin[1],
                                 face.planeOrigin[2]};
            patch.planeNormal = {face.planeNormal[0], face.planeNormal[1],
                                 face.planeNormal[2]};
            patches.push_back(std::move(patch));
        }
        const auto solid = kernel.makePlanarSolid(patches);
        if (!solid.isOk()) qFatal("Native box solid: %s", solid.error().message.c_str());
        assert(kernel.isShapeValid(solid.value()));
        cadnext::kernel::GeometryEvaluator evaluator(kernel);
        const auto rendered = evaluator.evaluateShape(solid.value());
        assert(rendered.isOk() && rendered.value().isValid &&
               !rendered.value().previewMesh.isEmpty());
        const auto volume = kernel.volumeProperties(solid.value());
        assert(volume.isOk());
        assert(std::fabs(volume.value().volumeM3 - 0.02 * 0.08 * 0.25) < 1e-10);
        const auto brep = kernel.exportBRepGeometry(solid.value());
        assert(brep.isOk() && !brep.value().empty());
        const auto restored = kernel.importBRep(brep.value());
        assert(restored.isOk() && kernel.isShapeValid(restored.value()));
        const QString stepPath = directory.filePath(QStringLiteral("native-box.step"));
        assert(kernel.exportExchangeFile({{solid.value(), {}}},
                                         stepPath.toStdString()).isOk());
        const auto fromStep = kernel.importExchangeFile(stepPath.toStdString());
        assert(fromStep.isOk());
        const auto stepVolume = kernel.volumeProperties(fromStep.value());
        assert(stepVolume.isOk());
        assert(std::fabs(stepVolume.value().volumeM3 - volume.value().volumeM3) < 1e-10);
        patches.pop_back();
        assert(!kernel.makePlanarSolid(patches).isOk());

        const QString assemblyPart = directory.filePath(QStringLiteral("native-box.SLDPRT"));
        assert(QFile::copy(planarPart, assemblyPart));
        const QString planarAssembly = directory.filePath(QStringLiteral("native-box.SLDASM"));
        QFile assemblyFile(planarAssembly);
        assert(assemblyFile.open(QIODevice::WriteOnly));
        const QByteArray assemblyManifest = R"(<swSolidWorks><swHeader>
<swFile id="1" swDocType="PART" swPath="C:\models\native-box.SLDPRT"/>
</swHeader><swModelList><swModel id="10" swFileRef="1"/>
<swReference swModelRef="10" swName="Первый" swIsVirtualComponent="NO"
 swTransform="1 0 0 0 0 1 0 0 0 0 1 0 2 3 4 1"/>
<swReference swModelRef="10" swName="Повернутый" swIsVirtualComponent="NO"
 swTransform="0 1 0 0 -1 0 0 0 0 0 1 0 -1 0 0 1"/>
</swModelList></swSolidWorks>)";
        const QByteArray assemblyBytes = solidWorksAssembly(assemblyManifest);
        assert(assemblyFile.write(assemblyBytes) == assemblyBytes.size());
        assemblyFile.close();
        std::vector<cadnext::gui::SolidWorksImportedBody> analyticAssembly;
        QString analyticAssemblyError;
        if (!cadnext::gui::readSolidWorksAnalyticAssembly(
                planarAssembly, kernel, analyticAssembly, analyticAssemblyError))
            qFatal("Analytic SolidWorks assembly: %s", qPrintable(analyticAssemblyError));
        assert(analyticAssembly.size() == 2);
        for (const auto& component : analyticAssembly) {
            const auto componentVolume = kernel.volumeProperties(component.shape);
            assert(componentVolume.isOk());
            assert(std::fabs(componentVolume.value().volumeM3 -
                             directVolume.value().volumeM3) < 1e-10);
        }
        std::vector<cadnext::gui::SolidWorksImportedBody> importedAssembly;
        error.clear();
        assert(cadnext::gui::readSolidWorksPlanarAssembly(
            planarAssembly, kernel, importedAssembly, error));
        assert(importedAssembly.size() == 2);
        assert(importedAssembly[0].name == QStringLiteral("Первый"));
        assert(importedAssembly[1].name == QStringLiteral("Повернутый"));
        for (const auto& component : importedAssembly) {
            const auto componentVolume = kernel.volumeProperties(component.shape);
            assert(componentVolume.isOk());
            assert(std::fabs(componentVolume.value().volumeM3 -
                             directVolume.value().volumeM3) < 1e-10);
        }
        const auto firstBounds = kernel.boundingBox(importedAssembly[0].shape);
        const auto rotatedBounds = kernel.boundingBox(importedAssembly[1].shape);
        assert(firstBounds.isOk() && rotatedBounds.isOk());
        for (std::size_t i = 0; i < analyticAssembly.size(); ++i) {
            const auto analyticBounds = kernel.boundingBox(analyticAssembly[i].shape);
            const auto planarBounds = kernel.boundingBox(importedAssembly[i].shape);
            assert(analyticBounds.isOk() && planarBounds.isOk());
            assert(std::fabs(analyticBounds.value().min.x -
                             planarBounds.value().min.x) < 1e-7);
            assert(std::fabs(analyticBounds.value().max.z -
                             planarBounds.value().max.z) < 1e-7);
        }
        assert(std::fabs(firstBounds.value().max.x - firstBounds.value().min.x - 0.02) < 1e-6);
        assert(std::fabs(rotatedBounds.value().max.x - rotatedBounds.value().min.x - 0.08) < 1e-6);
        assert(firstBounds.value().min.x > 1.9);
        assert(rotatedBounds.value().max.x < -0.9);
        std::vector<cadnext::kernel::NamedExchangeBody> stepBodies;
        for (const auto& component : importedAssembly) {
            stepBodies.push_back({component.name.toUtf8().toStdString(),
                                  {component.shape, {}}});
        }
        const QString assemblyStep = directory.filePath(QStringLiteral("native-assembly.step"));
        assert(kernel.exportStepAssembly(stepBodies, assemblyStep.toStdString()).isOk());
        const auto stepAssembly = kernel.importStepAssembly(assemblyStep.toStdString());
        assert(stepAssembly.isOk() && stepAssembly.value().size() == 2);
        assert(stepAssembly.value()[0].name == "Первый");
        assert(stepAssembly.value()[1].name == "Повернутый");
        for (std::size_t i = 0; i < stepAssembly.value().size(); ++i) {
            const auto& part = stepAssembly.value()[i];
            const auto mass = kernel.volumeProperties(part.shape);
            assert(mass.isOk());
            assert(std::fabs(mass.value().volumeM3 -
                             directVolume.value().volumeM3) < 1e-10);
            const auto bounds = kernel.boundingBox(part.shape);
            assert(bounds.isOk());
            const auto original = kernel.boundingBox(importedAssembly[i].shape);
            assert(original.isOk());
            assert(std::fabs(bounds.value().min.x - original.value().min.x) < 1e-6);
            assert(std::fabs(bounds.value().min.y - original.value().min.y) < 1e-6);
            assert(std::fabs(bounds.value().min.z - original.value().min.z) < 1e-6);
        }
    }

    const QString freeCadFixture = qEnvironmentVariable("CADNEXT_TEST_FREECAD_FILE");
    if (!freeCadFixture.isEmpty()) {
        std::vector<cadnext::gui::FreeCadShape> fixtureShapes;
        error.clear();
        assert(cadnext::gui::readFreeCadShapes(freeCadFixture, fixtureShapes, error));
        assert(!fixtureShapes.empty());
        for (const auto& fixture : fixtureShapes) {
            const auto* start = reinterpret_cast<const std::uint8_t*>(fixture.brep.constData());
            const auto importedFixture = kernel.importFreeCadBRep(
                std::vector<std::uint8_t>(start, start + fixture.brep.size()),
                fixture.binary);
            assert(importedFixture.isOk());
            assert(kernel.isShapeValid(importedFixture.value()));
            const auto properties = kernel.volumeProperties(importedFixture.value());
            assert(properties.isOk());
            assert(properties.value().volumeM3 > 0.0);
            const SurfaceCounts originalSurfaces =
                surfaceCounts(kernel, importedFixture.value());
            assert(originalSurfaces.faces > 0);
            for (const QString suffix : {QStringLiteral("step"), QStringLiteral("iges")}) {
                const QString exchangePath =
                    directory.filePath(QStringLiteral("freecad-fixture.") + suffix);
                assert(kernel.exportExchangeFile({{importedFixture.value(), {}}},
                                                 exchangePath.toStdString()).isOk());
                const auto roundTrip = kernel.importExchangeFile(exchangePath.toStdString());
                assert(roundTrip.isOk());
                assert(kernel.isShapeValid(roundTrip.value()));
                const auto roundTripProperties = kernel.volumeProperties(roundTrip.value());
                assert(roundTripProperties.isOk());
                assert(std::fabs(roundTripProperties.value().volumeM3 -
                                 properties.value().volumeM3) <
                       properties.value().volumeM3 * 1e-6);
                const SurfaceCounts roundTripSurfaces =
                    surfaceCounts(kernel, roundTrip.value());
                qInfo("FreeCAD %s: original faces=%d planes=%d cylinders=%d splines=%d revolutions=%d line-revolutions=%d other=%d; round-trip faces=%d planes=%d cylinders=%d splines=%d revolutions=%d line-revolutions=%d other=%d",
                      qPrintable(suffix), originalSurfaces.faces, originalSurfaces.planes,
                      originalSurfaces.cylinders, originalSurfaces.splines,
                      originalSurfaces.revolutions, originalSurfaces.lineRevolutions,
                      originalSurfaces.other,
                      roundTripSurfaces.faces, roundTripSurfaces.planes,
                      roundTripSurfaces.cylinders, roundTripSurfaces.splines,
                      roundTripSurfaces.revolutions, roundTripSurfaces.lineRevolutions,
                      roundTripSurfaces.other);
                assert(roundTripSurfaces.faces == originalSurfaces.faces);
                assert(roundTripSurfaces.planes == originalSurfaces.planes);
                assert(roundTripSurfaces.cylinders +
                           roundTripSurfaces.lineRevolutions ==
                       originalSurfaces.cylinders +
                           originalSurfaces.lineRevolutions);
                assert(roundTripSurfaces.splines == originalSurfaces.splines);
                assert(roundTripSurfaces.other == originalSurfaces.other);
                if (suffix == QStringLiteral("step")) {
                    assert(roundTripSurfaces.cylinders == originalSurfaces.cylinders);
                }
            }
        }
    }

    const QString dwgFixture = qEnvironmentVariable("CADNEXT_TEST_DWG_FILE");
    if (!dwgFixture.isEmpty()) {
        QFile dwg(dwgFixture);
        assert(dwg.open(QIODevice::ReadOnly));
        assert(dwg.read(6).startsWith("AC10"));
        assert(cadnext::gui::nativeCadImportDiagnostic(dwgFixture)
                   .contains(QStringLiteral("AcDb bit-stream")));
    }

    const QString kompasFixture = qEnvironmentVariable("CADNEXT_TEST_KOMPAS_FILE");
    if (!kompasFixture.isEmpty()) {
        cadnext::gui::KompasModelInfo info;
        error.clear();
        assert(cadnext::gui::readKompasModelInfo(kompasFixture, info, error));
        assert(!info.name.isEmpty());
        assert(!info.objects.empty());
        assert(info.compressedRecords > 100);
        assert(info.decodedRecordBytes > 100000);
        assert(cadnext::gui::nativeCadImportDiagnostic(kompasFixture)
                   .contains(QStringLiteral("Contents")));
    }

    const QString aircraftDirectory = qEnvironmentVariable("CADNEXT_TEST_AIRCRAFT_DIR");
    if (!aircraftDirectory.isEmpty()) {
        const QDir aircraft(aircraftDirectory);
        QStringList first;
        QStringList second;
        error.clear();
        assert(cadnext::gui::readSolidWorksAssemblyReferences(
            aircraft.filePath(QStringLiteral("alpha 1 ELect.SLDASM")), first, error));
        assert(first.size() == 4);
        assert(first.join(QLatin1Char(' ')).contains(QStringLiteral("sens.SLDPRT")));
        components.clear();
        assert(cadnext::gui::readSolidWorksAssemblyComponents(
            aircraft.filePath(QStringLiteral("alpha 1 ELect.SLDASM")), components, error));
        assert(components.size() == 4);
        for (const auto& component : components) {
            assert(!component.virtualComponent);
            assert(std::fabs(component.transform[3]) < 1e-9);
            assert(std::fabs(component.transform[7]) < 1e-9);
            assert(std::fabs(component.transform[11]) < 1e-9);
            assert(component.transform[15] == 1.0);
        }
        std::vector<cadnext::gui::SolidWorksImportedBody> missingBodies;
        error.clear();
        assert(!cadnext::gui::readSolidWorksPlanarAssembly(
            aircraft.filePath(QStringLiteral("alpha 1 ELect.SLDASM")),
            kernel, missingBodies, error));
        assert(error.contains(QStringLiteral(".SLDPRT")));
        assert(cadnext::gui::readSolidWorksAssemblyReferences(
            aircraft.filePath(QStringLiteral("alpha 2 rocket.SLDASM")), second, error));
        assert(second.size() == 4);
        assert(second.join(QLatin1Char(' ')).contains(QStringLiteral("puujin1.SLDPRT")));
    }

}
