#include "cadnext/gui/DwgWriter.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTemporaryDir>

#ifdef CADNEXT_WITH_OCCT
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#endif

#include <algorithm>
#include <array>

namespace cadnext::gui {
namespace {
QString writerExecutable() {
    const QString configured = qEnvironmentVariable("CADNEXT_DWG_WRITER");
    if (!configured.isEmpty()) {
        const QFileInfo file(configured);
        return file.isFile() && file.isExecutable() ? file.absoluteFilePath() : QString();
    }
    const QString local = QDir(QCoreApplication::applicationDirPath()).filePath("cadnext_dwg_writer");
    if (QFileInfo(local).isFile() && QFileInfo(local).isExecutable()) return local;
    return QStandardPaths::findExecutable("cadnext_dwg_writer");
}
}

bool dwgSolidWriterAvailable() { return !writerExecutable().isEmpty(); }

cadnext::Result<AcisSatWriteReport> writeDwgSolids(
    kernel::OcctKernel& kernel, const std::vector<kernel::NamedExchangeBody>& bodies,
    const QString& path) {
    using R = cadnext::Result<AcisSatWriteReport>;
    if (bodies.empty()) return R::fail({ErrorCode::InvalidArgument, "No bodies for DWG export"});
    const QString executable = writerExecutable();
    if (executable.isEmpty())
        return R::fail({ErrorCode::KernelUnavailable,
                       "DWG export requires cadnext_dwg_writer built with LibreDWG"});
#ifndef CADNEXT_WITH_OCCT
    return R::fail({ErrorCode::KernelUnavailable, "DWG export requires OCCT"});
#else
    QTemporaryDir temporary;
    if (!temporary.isValid()) return R::fail({ErrorCode::SerializationFailed, "Cannot create DWG staging directory"});
    const QString output = temporary.filePath("model.dwg");
    QStringList inputs;
    std::vector<QByteArray> payloads;
    AcisSatWriteReport report;
    Bnd_Box bounds;
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        AcisSatWriteReport part;
        const auto sat = encodeAcisSat(kernel, {bodies[i]}, part);
        if (!sat.isOk()) return R::fail(sat.error());
        const QString input = temporary.filePath(QString("body_%1.sat").arg(i));
        QFile file(input);
        if (!file.open(QIODevice::WriteOnly) || file.write(sat.value()) != sat.value().size())
            return R::fail({ErrorCode::SerializationFailed, "Cannot stage ACIS body for DWG export"});
        file.close();
        inputs.push_back(input);
        payloads.push_back(sat.value());
        report.bodies += part.bodies;
        report.largestVertexGap = std::max(report.largestVertexGap, part.largestVertexGap);
        report.largestBoundaryTolerance = std::max(report.largestBoundaryTolerance, part.largestBoundaryTolerance);
        const auto placed = kernel.placeExchangeBody(bodies[i].body);
        if (!placed.isOk()) return R::fail(placed.error());
        BRepBndLib::AddOptimal(*kernel.findShape(placed.value()), bounds, false, false);
    }
    std::array<double, 6> extents{};
    bounds.Get(extents[0], extents[1], extents[2], extents[3], extents[4], extents[5]);
    QStringList arguments{output};
    for (const double coordinate : extents) arguments.push_back(QString::number(coordinate * 1000.0, 'g', 17));
    arguments.append(inputs);
    QProcess process;
    process.start(executable, arguments);
    if (!process.waitForStarted(10000))
        return R::fail({ErrorCode::SerializationFailed, "Cannot start DWG writer: " + process.errorString().toStdString()});
    if (!process.waitForFinished(300000)) {
        process.kill();
        process.waitForFinished(5000);
        return R::fail({ErrorCode::SerializationFailed, "DWG writer timed out"});
    }
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0)
        return R::fail({ErrorCode::SerializationFailed,
                       "DWG writer failed: " + QString::fromUtf8(process.readAllStandardError()).right(2000).toStdString()});
    DwgModel restored;
    QString error;
    if (!readDwgModel(output, restored, error) || restored.version != "AC1015" || restored.bodies.size() != payloads.size())
        return R::fail({ErrorCode::SerializationFailed, "DWG export readback: " + error.toStdString()});
    constexpr std::array<double, 16> identity{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    for (std::size_t i = 0; i < payloads.size(); ++i) {
        const auto& body = restored.bodies[i];
        // Only trailing line endings may differ. Whitespace inside length-prefixed SAT
        // strings matters, and must not be normalised by the verification.
        if (body.acis.trimmed() != payloads[i].trimmed() || body.millimetresPerUnit != 1.0 || body.placement != identity)
            return R::fail({ErrorCode::SerializationFailed, "DWG writer changed the ACIS payload, units or placement"});
    }
    QFile file(output);
    if (!file.open(QIODevice::ReadOnly) || file.size() > 256ll * 1024 * 1024)
        return R::fail({ErrorCode::SerializationFailed, "Cannot read DWG output, or it exceeds 256 MiB"});
    const QByteArray bytes = file.readAll();
    if (bytes.size() != file.size()) return R::fail({ErrorCode::SerializationFailed, "Incomplete DWG output"});
    QSaveFile destination(path);
    if (!destination.open(QIODevice::WriteOnly) || destination.write(bytes) != bytes.size() || !destination.commit())
        return R::fail({ErrorCode::SerializationFailed, "Cannot save DWG: " + destination.errorString().toStdString()});
    return R::ok(report);
#endif
}
} // namespace cadnext::gui
