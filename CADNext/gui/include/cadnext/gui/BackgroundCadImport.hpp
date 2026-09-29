#pragma once

#include "cadnext/gui/ImportProgress.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

#include <QString>
#include <QStringList>

#include <cstdint>
#include <vector>

// Another system's file as bodies of the open part document, read away from the UI thread. Everything
// heavy happens on the calling (worker) thread with a kernel of its own: reading, building the exact
// bodies, meshing them and working out their faces and edges for picking (the face analysis alone was
// 4.4 s of 4.9 s for the NIST MTC parts). The UI thread then only reads each body's BRep back into its
// own kernel (milliseconds) and hands over the rest.

namespace cadnext::gui {

struct ImportedBody {
    QString name;
    std::vector<std::uint8_t> brep;
    kernel::TriangleMesh mesh;
    // In the body's own frame, bodyId left empty: the document gives the id.
    std::vector<kernel::FaceReference> faces;
    std::vector<kernel::EdgeReference> edges;
};

struct BodyImportResult {
    std::vector<ImportedBody> bodies; // each occurrence of an assembly where the file places it
    QString error;                    // empty when read
    ParasolidXtBuildReport geometry;  // what the exact builder had to say (SOLIDWORKS, Parasolid)
    QStringList notes;                // anything else worth a line in the outcome
};

// The formats read here: SOLIDWORKS (.sldprt, .sldasm), Parasolid (.x_t, .x_b, .xmt_txt, .xmt_bin),
// STEP (.step, .stp), IGES (.iges, .igs), FreeCAD (.fcstd), ACIS (.sat), the solids of DWG (.dwg) and
// KOMPAS-3D parts and assemblies (.m3d, .a3d). `suffix` lower case.
bool isBackgroundCadFormat(const QString& suffix);

// Callable on any thread. Stops between bodies when `progress` is cancelled (error then
// importCancelledReason()).
BodyImportResult importBodiesFromFile(const QString& path, const ImportProgress* progress = nullptr,
                                     const QString& configuration = {});

// Whether a file holds an assembly, judged without building anything: Parasolid by its ASSEMBLY nodes,
// STEP by its NEXT_ASSEMBLY_USAGE_OCCURRENCE entities (a component placed in an assembly), a KOMPAS-3D
// .a3d always. Fast enough for the UI thread; false for other formats.
bool cadFileLooksLikeAssembly(const QString& path);

} // namespace cadnext::gui
