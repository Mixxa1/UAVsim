#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/gui/ParasolidXtWriter.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QtGlobal>

#include <zlib.h>

#include <BRepAdaptor_Surface.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <GeomAbs_CurveType.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>

#include <cassert>
#include <cmath>
#include <map>
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
        put32(data, 1); string(names[i].second); put32(data, names[i].first);
        put32(data, 0); string(names[i].second); put32(data, 0xffffffff); put32(data, 0);
        string({}); string({}); put32(data, 0); put32(data, 0);
    }
    return data;
}
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    cadnext::kernel::OcctKernel kernel;
    const auto box = kernel.makeBox({1000, 1000, 1000});
    assert(box.isOk());
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
