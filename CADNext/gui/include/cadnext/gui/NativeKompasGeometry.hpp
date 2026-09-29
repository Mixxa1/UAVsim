#pragma once

#include <QByteArray>
#include <QString>
#include <QtGlobal>

#include <array>
#include <vector>

#ifdef CADNEXT_WITH_OCCT
#include "cadnext/kernel/OcctKernel.hpp"
#endif

namespace cadnext::gui {

// One independently checksummed zlib member in the KF Contents section.
// Offsets refer to the uncompressed ZIP member, including its two-byte KF tag.
struct KompasContentsRecord {
    qsizetype offset = 0;
    qsizetype compressedSize = 0;
    QByteArray decoded;
};

struct KompasContentsRecords {
    std::vector<KompasContentsRecord> records;
    quint64 decodedBytes = 0;
    qsizetype tailOffset = 0;
    QByteArray tail;
};

// Decodes and verifies the record layer of a ZIP-based KOMPAS-3D Contents
// member. The bytes after the last zlib member are retained exactly. This
// function makes no claim that the decoded records form a BRep; their C3D
// topology and analytic surfaces require a separate decoder.
bool decodeKompasContentsRecords(const QByteArray& contents,
                                 KompasContentsRecords& result,
                                 QString& error);

// An exact cylindrical face whose analytic surface, face reference, and two
// endpoint points all agree in the serialized C3D node graph. This is a
// deliberately narrow subset: complete cylinders parallel to +X only.
struct KompasCylindricalFace {
    quint16 surfaceNodeId = 0;
    quint16 faceNodeId = 0;
    std::array<double, 3> origin{};
    std::array<double, 3> axis{};
    std::array<double, 3> radialDirection{};
    double radius = 0;
    double length = 0;
};

bool readKompasCylindricalFaces(const KompasContentsRecords& contents,
                               std::vector<KompasCylindricalFace>& faces,
                               QString& error);

bool readKompasCylindricalFacesFromFile(
    const QString& path, std::vector<KompasCylindricalFace>& faces, QString& error);

#ifdef CADNEXT_WITH_OCCT
// Builds real, trimmed TopoDS_Face objects from the verified native cylinder
// parameters, then registers them in the CADNext kernel. The result is a set
// of separate faces, not a closed BRep solid.
bool makeKompasCylindricalFaces(const std::vector<KompasCylindricalFace>& faces,
                               kernel::OcctKernel& kernel,
                               std::vector<kernel::ShapeHandle>& shapes,
                               QString& error);
#endif

} // namespace cadnext::gui
