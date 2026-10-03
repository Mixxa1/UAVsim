#include "cadnext/gui/DwgWriter.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/gui/NativeDwgR2000.hpp"
#include "cadnext/gui/NativeKompasMesh.hpp"
#include "cadnext/gui/NativeKompasPreview.hpp"

#include <QDateTime>
#include <QFile>
#include <QSaveFile>
#include <QTemporaryDir>
#include <QUuid>

#ifdef CADNEXT_WITH_OCCT
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#endif

#include <algorithm>
#include <array>
#include <cmath>

namespace cadnext::gui {
bool dwgSolidWriterAvailable() { return true; }

cadnext::Result<AcisSatWriteReport> writeDwgSolids(
    kernel::OcctKernel& kernel, const std::vector<kernel::NamedExchangeBody>& bodies,
    const QString& path) {
    using R = cadnext::Result<AcisSatWriteReport>;
    if (bodies.empty()) return R::fail({ErrorCode::InvalidArgument, "No bodies for DWG export"});
#ifndef CADNEXT_WITH_OCCT
    return R::fail({ErrorCode::KernelUnavailable, "DWG export requires OCCT"});
#else
    DwgR2000SolidsDocument document;
    AcisSatWriteReport report;
    Bnd_Box bounds;
    std::vector<kernel::ShapeHandle> placedBodies;
    quint64 total = 0;
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        AcisSatWriteReport part;
        const auto sat = encodeAcisSat(kernel, {bodies[i]}, part);
        if (!sat.isOk()) return R::fail(sat.error());
        total += quint64(sat.value().size());
        if (total > 256ull * 1024 * 1024) return R::fail({ErrorCode::SerializationFailed, "ACIS data for DWG exceed 256 MiB"});
        document.solids.push_back(sat.value());
        report.bodies += part.bodies;
        report.largestVertexGap = std::max(report.largestVertexGap, part.largestVertexGap);
        report.largestBoundaryTolerance = std::max(report.largestBoundaryTolerance, part.largestBoundaryTolerance);
        const auto placed = kernel.placeExchangeBody(bodies[i].body);
        if (!placed.isOk()) return R::fail(placed.error());
        BRepBndLib::AddOptimal(*kernel.findShape(placed.value()), bounds, false, false);
        placedBodies.push_back(placed.value());
    }
    std::array<double, 6> extents{};
    bounds.Get(extents[0], extents[1], extents[2], extents[3], extents[4], extents[5]);
    for (double& coordinate : extents) coordinate *= 1000.0;
    document.extents = extents;
    // The time of saving as AutoCAD keeps it: the Julian day and the milliseconds into it (UTC).
    const QDateTime now = QDateTime::currentDateTimeUtc();
    document.created = {quint32(now.date().toJulianDay()), quint32(now.time().msecsSinceStartOfDay())};
    document.fingerprint = QUuid::createUuid().toString(QUuid::WithBraces).toUpper().toLatin1();
    document.version = QUuid::createUuid().toString(QUuid::WithBraces).toUpper().toLatin1();
    // The picture AutoCAD 2000 keeps of the drawing: ours, the bodies shaded, 220 × 140 as in its files.
    {
        const double diagonal = std::sqrt((extents[3] - extents[0]) * (extents[3] - extents[0]) +
                                          (extents[4] - extents[1]) * (extents[4] - extents[1]) +
                                          (extents[5] - extents[2]) * (extents[5] - extents[2]));
        const auto step = kompasMeshStep(diagonal);
        std::vector<KompasMesh> meshes;
        QString meshError;
        bool meshed = true;
        for (std::size_t i = 0; meshed && i < placedBodies.size(); ++i) {
            KompasMesh mesh;
            meshed = kompasBodyMesh(kernel, placedBodies[i], 1 + quint32(i), step, 0x909090, {}, mesh, meshError);
            if (meshed) meshes.push_back(std::move(mesh));
        }
        if (meshed) {
            const KompasPreviewImage image = renderKompasPreview(meshes, 0x909090, 220, 140);
            document.preview.bitmap = dwgPreviewBitmap(image.width, image.height, image.rgb);
        }
    }
    QByteArray bytes;
    QString error;
    if (!encodeDwgR2000SolidsDocument(document, bytes, error))
        return R::fail({ErrorCode::SerializationFailed, "DWG export: " + error.toStdString()});
    if (bytes.size() > 256ll * 1024 * 1024) return R::fail({ErrorCode::SerializationFailed, "DWG output exceeds 256 MiB"});
    // Read back with the independent reader before the destination is touched.
    QTemporaryDir temporary;
    if (!temporary.isValid()) return R::fail({ErrorCode::SerializationFailed, "Cannot create DWG staging directory"});
    const QString staged = temporary.filePath("model.dwg");
    {
        QFile file(staged);
        if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size())
            return R::fail({ErrorCode::SerializationFailed, "Cannot stage DWG output"});
    }
    DwgModel restored;
    if (!readDwgModel(staged, restored, error) || restored.version != "AC1015" || restored.bodies.size() != document.solids.size())
        return R::fail({ErrorCode::SerializationFailed, "DWG export readback: " + error.toStdString()});
    constexpr std::array<double, 16> identity{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    for (std::size_t i = 0; i < document.solids.size(); ++i) {
        const auto& body = restored.bodies[i];
        // Only trailing line endings may differ. Whitespace inside length-prefixed SAT
        // strings matters, and must not be normalised by the verification.
        if (body.acis.trimmed() != document.solids[i].trimmed() || body.millimetresPerUnit != 1.0 || body.placement != identity)
            return R::fail({ErrorCode::SerializationFailed, "DWG writer changed the ACIS payload, units or placement"});
    }
    QSaveFile destination(path);
    if (!destination.open(QIODevice::WriteOnly) || destination.write(bytes) != bytes.size() || !destination.commit())
        return R::fail({ErrorCode::SerializationFailed, "Cannot save DWG: " + destination.errorString().toStdString()});
    return R::ok(report);
#endif
}
} // namespace cadnext::gui
