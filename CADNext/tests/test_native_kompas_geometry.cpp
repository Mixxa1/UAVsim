#include "cadnext/gui/NativeKompasGeometry.hpp"

#include <QByteArray>
#include <QFile>
#include <QString>

#include <cassert>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

#include <zlib.h>

namespace {

QByteArray deflate(const QByteArray& data) {
    uLongf size = compressBound(static_cast<uLong>(data.size()));
    QByteArray compressed(qsizetype(size), Qt::Uninitialized);
    const int status = compress2(reinterpret_cast<Bytef*>(compressed.data()), &size,
                                 reinterpret_cast<const Bytef*>(data.constData()),
                                 static_cast<uLong>(data.size()), Z_BEST_COMPRESSION);
    assert(status == Z_OK);
    compressed.resize(qsizetype(size));
    return compressed;
}

} // namespace

int main() {
    using namespace cadnext::gui;
    const QByteArray first("\0\1\2\xff", 4);
    const QByteArray second("exact record boundaries");
    QByteArray contents("KF", 2);
    contents += deflate(first);
    contents += deflate(second);
    const qsizetype tailOffset = contents.size();
    contents += QByteArray("\x80\x43\x30\x00", 4);

    KompasContentsRecords records;
    QString error;
    assert(decodeKompasContentsRecords(contents, records, error));
    assert(error.isEmpty());
    assert(records.records.size() == 2);
    assert(records.records[0].offset == 2);
    assert(records.records[0].decoded == first);
    assert(records.records[1].offset ==
           2 + records.records[0].compressedSize);
    assert(records.records[1].decoded == second);
    assert(records.decodedBytes == quint64(first.size() + second.size()));
    assert(records.tailOffset == tailOffset);
    assert(records.tail == QByteArray("\x80\x43\x30\x00", 4));

    QByteArray corrupt = contents;
    corrupt[2 + records.records[0].compressedSize - 1] ^= char(1);
    assert(!decodeKompasContentsRecords(corrupt, records, error));
    assert(records.records.empty());
    assert(!error.isEmpty());
    assert(!decodeKompasContentsRecords(QByteArray("KF\x78\x9c", 4), records, error));
    assert(!decodeKompasContentsRecords(QByteArray("KF", 2), records, error));
    assert(!decodeKompasContentsRecords(QByteArray("XX", 2), records, error));

    // The public sample supplies a regression check for the actual record
    // boundary layer. It is optional because it is not redistributed here.
    QFile sample(QStringLiteral("/private/tmp/cadnext-kompas-sample.m3d"));
    if (sample.exists()) {
        // The ZIP entry extraction is exercised by readKompasModelInfo; this
        // test passes its known stored Contents member to the record decoder.
        assert(sample.open(QIODevice::ReadOnly));
        const QByteArray archive = sample.readAll();
        const qsizetype contentsName = archive.indexOf("Contents");
        assert(contentsName > 0);
        const qsizetype localHeader = contentsName - 30;
        assert(localHeader >= 0);
        assert(archive.mid(localHeader, 4) == QByteArray("PK\x03\x04", 4));
        const auto u16 = [&](qsizetype at) -> quint16 {
            return quint16(quint8(archive[at])) |
                   (quint16(quint8(archive[at + 1])) << 8);
        };
        const auto u32 = [&](qsizetype at) -> quint32 {
            return quint32(u16(at)) | (quint32(u16(at + 2)) << 16);
        };
        assert(u16(localHeader + 8) == 0);
        const qsizetype dataAt = localHeader + 30 + u16(localHeader + 26) +
                                 u16(localHeader + 28);
        const QByteArray realContents = archive.mid(dataAt, u32(localHeader + 18));
        assert(realContents.size() == 101182);
        assert(decodeKompasContentsRecords(realContents, records, error));
        assert(records.records.size() == 484);
        assert(records.decodedBytes == 250584);
        assert(records.tailOffset == 62389);
        assert(records.tail.size() == 38793);
        assert(records.records[442].decoded.size() == 77948);
        assert(records.records[452].decoded.size() == 36557);

        std::vector<KompasCylindricalFace> faces;
        assert(readKompasCylindricalFaces(records, faces, error));
        assert(faces.size() == 5);
        const quint16 expectedSurfaceIds[] = {0x53f, 0x542, 0x545, 0x548, 0x54b};
        const quint16 expectedFaceIds[] = {0x6c7, 0x6c6, 0x6d7, 0x6d8, 0x6d6};
        const double expectedRadii[] = {1, 1, 2.5, 2.5, 2.5};
        for (std::size_t i = 0; i < faces.size(); ++i) {
            assert(faces[i].surfaceNodeId == expectedSurfaceIds[i]);
            assert(faces[i].faceNodeId == expectedFaceIds[i]);
            assert(std::fabs(faces[i].radius - expectedRadii[i]) < 1e-12);
            assert(std::fabs(faces[i].length - 10) < 1e-12);
        }
        assert(std::fabs(faces[0].origin[1] - 11.248967635572484) < 1e-12);
        assert(std::fabs(faces[0].origin[2] - 14.99633679023703) < 1e-12);

        std::vector<KompasCylindricalFace> fileFaces;
        assert(readKompasCylindricalFacesFromFile(
            QStringLiteral("/private/tmp/cadnext-kompas-sample.m3d"), fileFaces, error));
        assert(fileFaces.size() == faces.size());
        assert(fileFaces.front().surfaceNodeId == faces.front().surfaceNodeId);

        KompasContentsRecords changed = records;
        QByteArray& graph = changed.records[452].decoded;
        const qsizetype cylinder = graph.indexOf(
            QByteArray("\x02\x80\x5d\x14\x01\x3f\x05", 7));
        assert(cylinder >= 0);
        graph.replace(cylinder + 151, 8,
                      QByteArray("\0\0\0\0\0\0\0\x40", 8)); // r = 2
        std::vector<KompasCylindricalFace> changedFaces;
        assert(readKompasCylindricalFaces(changed, changedFaces, error));
        assert(changedFaces.size() == 4);

#ifdef CADNEXT_WITH_OCCT
        cadnext::kernel::OcctKernel kernel;
        std::vector<cadnext::kernel::ShapeHandle> shapes;
        assert(makeKompasCylindricalFaces(faces, kernel, shapes, error));
        assert(shapes.size() == faces.size());
        for (const auto& shape : shapes) {
            assert(kernel.isShapeValid(shape));
            const auto brep = kernel.exportBRep(shape);
            assert(brep.isOk() && !brep.value().empty());
        }
#endif
    }
}
