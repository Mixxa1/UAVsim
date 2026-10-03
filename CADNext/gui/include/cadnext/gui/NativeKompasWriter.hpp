#pragma once

#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"
#include "cadnext/gui/NativeKompasTopology.hpp"
#include "cadnext/gui/NativeKompasBodyApplication.hpp"
#include "cadnext/gui/NativeKompasOperation.hpp"

#include <QByteArray>
#include <QString>

#include <array>
#include <optional>
#include <vector>

namespace cadnext::gui {

struct KompasBodyOwnership {
    // One set of native vertex/edge/face ownership tables per geometry record.
    // These belong after the body's application header. The application-body
    // writer below assembles that envelope; do not append tables to the shell.
    std::vector<QByteArray> records;
    std::map<quint16, quint16> registry;
};

// Experimental geometry component of a native document writer: C3D body
// records, each with a numbered face shell and shared edges/surfaces/vertices.
// Exact planar bodies with straight edges only; unsupported input is rejected
// as a whole. Metres in the kernel become millimetres in the native stream.
// These records are NOT a complete M3D document or a complete Contents section:
// application objects, operation ownership and version information remain to
// be authored. Nothing is published under an M3D extension.
bool encodeKompasPlanarBodyRecords(kernel::OcctKernel& kernel,
                                  const std::vector<kernel::ShapeHandle>& bodies,
                                  std::vector<QByteArray>& records, QString& error);

// Exact analytic/NURBS surfaces, including periodic U/V directions, with
// conic, polynomial or rational NURBS UV boundaries through degree 25.
// Paired boundaries must preserve a common parameter law within their
// measured native tolerance. Same staged-output and
// document-component contract as above.
// Plane hyperbolas retain their analytic parameter through cubic UV helpers
// with an analytic error bound <=1e-13 m, inside cbt_Specific intersections;
// planar parabola helpers preserve their quadratic law exactly.
// Swept surfaces remain unsupported.
// Optionally returns the final geometry registry ID for the archive catalog;
// this number is reset to zero on failure, together with the records.
// When ownership is requested, also authors matching native topology tables
// and allocates their proxy IDs in the same global registry as the geometry.
// firstObjectId continues a registry whose model/controller objects have
// already been authored. It must be a free ID in [1,65535]; the caller owns
// the preceding registry and can merge the returned new definitions into it.
bool encodeKompasBodyRecords(kernel::OcctKernel& kernel,
                            const std::vector<kernel::ShapeHandle>& bodies,
                            std::vector<QByteArray>& records, QString& error,
                            quint32* lastObjectId = nullptr,
                            KompasBodyOwnership* ownership = nullptr,
                            quint32 firstObjectId = 1);

// Authors complete body records in the supported application-state layout:
// math shell, application state, topology ownership, native footer. Native
// names/flags come from the document writer, not a borrowed file template.
// Model/controller/operation records are still required for a complete M3D.
// Optionally authors the matching separate application link record per body.
// All outputs are cleared on any failure.
bool encodeKompasApplicationBodyRecords(
    kernel::OcctKernel& kernel, const std::vector<kernel::ShapeHandle>& bodies,
    const std::vector<KompasBodyApplicationState>& states,
    std::vector<QByteArray>& records, QString& error,
    quint32* lastObjectId = nullptr,
    std::vector<QByteArray>* applicationLinks = nullptr,
    quint32 firstObjectId = 1);

struct KompasImportedBodyOperation {
    QByteArray operation; // native controller envelope with the authored shell
    QByteArray body;      // current shell naming that operation's math faces
    QByteArray applicationLink;
    std::map<quint16, quint16> registry; // new controller/math/proxy definitions
    quint32 lastObjectId = 0;
    quint16 shellId = 0; // the body record's shell, numbered as KOMPAS numbers its bodies' shells
};

// Authors one imported operation and its current body as matching components.
// Geometry is defined inside the operation; the body names those same faces.
// Topology names share the operation's main name; applicationName is separate.
// objectId must be the next free registry ID after the document's controllers.
// This stage supports the identity operation placement; a nonidentity frame
// needs a verified transform law before world-coordinate geometry can use it.
// The caller separately authors the model root, datums and document properties.
bool encodeKompasImportedBodyOperation(
    kernel::OcctKernel& kernel, kernel::ShapeHandle body,
    const KompasImportedOperationPrefix& prefix,
    const KompasImportedOperationSuffix& suffix,
    const KompasBodyApplicationState& state,
    KompasImportedBodyOperation& operation, QString& error);

// A complete CADNext-authored component document: model header/footer,
// default datum controllers, imported-operation records, current-body links,
// typed model/body properties, property lists, document settings, catalog,
// cluster SysInfo and atomic ZIP packaging. The physical archive is fully
// authored for this supported graph; application-specific layouts outside the
// codecs above are rejected rather than copied from a source file.
struct KompasNativeWriteBody {
    kernel::ShapeHandle shape;
    quint32 bodyNumber = 0; // zero assigns the next unused positive number
    QString name;
    cadnext::Transform placement;
};

struct KompasNativeWriteOptions {
    QString title = QStringLiteral("CADNext document");
    quint32 color = 0x00909090;
    std::array<quint8, 6> material{50, 60, 80, 80, 100, 50};
    double nativeDensity = 7.82; // g/cm^3
    QString materialName = QStringLiteral("CADNext material");
    // The designation (MetaInfo's property 4 and /#204), written when given.
    std::optional<QString> designation;
    // MetaInfo's author (property 11) and organization (12), written when given.
    std::optional<QString> author;
    std::optional<QString> organization;
};

bool writeKompasNativeDocument(
    kernel::OcctKernel& kernel,
    const std::vector<KompasNativeWriteBody>& bodies,
    const QString& path, QString& error,
    const KompasNativeWriteOptions& options = {});

// A part of an assembly: written as its own document (writeKompasNativeDocument)
// under `fileName` in the assembly's folder.
struct KompasAssemblyPart {
    QString fileName; // a file name ending in .m3d, no folders
    std::vector<KompasNativeWriteBody> bodies;
    KompasNativeWriteOptions options;
};

// A placement of a part: the part's coordinates into the assembly's (metres).
struct KompasAssemblyComponent {
    std::size_t part = 0;
    kernel::ProductPlacement placement;
};

// A KOMPAS 17.1 assembly (.a3d) placing its parts, each written beside it first:
// the records of the samples' assemblies in their order — file links, one
// component record per placement, the model's datums, MetaInfo naming the part
// files — and the part documents' own. At most kKompasAssemblyLinkKeys (21)
// components: the MetaInfo link keys of more are not known. A file link's native
// mark is the CRC-32 of the part file written (KOMPAS's own rule is not known).
bool writeKompasNativeAssembly(
    kernel::OcctKernel& kernel,
    const std::vector<KompasAssemblyPart>& parts,
    const std::vector<KompasAssemblyComponent>& components,
    const QString& path, QString& error,
    const KompasNativeWriteOptions& options = {});

} // namespace cadnext::gui
