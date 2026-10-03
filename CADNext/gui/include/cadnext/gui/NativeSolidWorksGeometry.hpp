#pragma once

#include "cadnext/gui/ImportProgress.hpp"
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <QString>
#include <QStringList>

#include <vector>

namespace cadnext::gui {

struct SolidWorksImportedBody {
    QString name;
    kernel::ShapeHandle shape;
};

// A face built approximately (a rolling-ball blend): its XT FACE node, and how far the built surface
// may be from the blend's definition (deviation) and the file's spine from its supports (contactGap), m.
struct ParasolidXtApproximatedFace {
    quint32 faceIndex = 0;
    double deviation = 0.0;
    double contactGap = 0.0;
    QString body; // the component, when the report covers an assembly
};

struct ParasolidXtBuildReport {
    std::vector<ParasolidXtApproximatedFace> approximated;
    // Tolerant edges: an EDGE with a tolerance of its own, its faces meeting only within it (each
    // on its own SP-curve, or on a curve its vertices are off). Their count and the largest
    // tolerance of such an edge or of a tolerant vertex, m.
    int tolerantEdges = 0;
    double largestEdgeTolerance = 0.0;
    // Faces winding round a cylinder or cone more than once (a thread's root): OCCT holds each only
    // as one face per turn. The XT FACE node and how many faces it became.
    struct SplitFace {
        quint32 faceIndex = 0;
        int faces = 0;
        QString body; // the component, when the report covers an assembly
    };
    std::vector<SplitFace> split;
};

// What an import report says about the faces built approximately, the tolerant edges and the faces
// held one per turn; empty when there are none.
QString describeApproximatedFaces(const ParasolidXtBuildReport& report);

// The same, one short line each, for an import's outcome window: counts and bounds, no explanation.
QStringList summarizeBuildReport(const ParasolidXtBuildReport& report);

// Adds `part` to `whole`, the faces named after `body` (a component's file) when given.
void mergeBuildReport(ParasolidXtBuildReport& whole, const ParasolidXtBuildReport& part, const QString& body = {});

// Reconstructs exact BRep solids for the planar, polygonal subset of modern
// SOLIDWORKS files. Unsupported geometry returns an error.
bool readSolidWorksPlanarPart(const QString& path, kernel::OcctKernel& kernel,
                             kernel::ShapeHandle& shape, QString& error,
                             const QString& configuration = {});

// Reconstructs exact supported analytic BRep solids (planes, cylinders,
// cones, sphere patches, and torus patches) with line/circle/ellipse boundaries.
// Rejects unsupported surfaces and curves before presenting any partial body.
bool readSolidWorksAnalyticPart(const QString& path, kernel::OcctKernel& kernel,
                               kernel::ShapeHandle& shape, QString& error,
                               ParasolidXtBuildReport* report = nullptr,
                               const QString& configuration = {});

// The exact BRep builder behind readSolidWorksAnalyticPart, for a decoded
// Parasolid node graph from any source: a SLDPRT partition or a standalone
// .x_t / .x_b file. Same supported geometry, same refusals. Blends are built to
// within 1e-6 m and listed in `report`.
bool buildParasolidXtAnalyticSolid(const ParasolidXtTopology& topology,
                                   kernel::OcctKernel& kernel,
                                   kernel::ShapeHandle& shape, QString& error,
                                   ParasolidXtBuildReport* report = nullptr);

// A standalone Parasolid transmit file (.x_t text or .x_b neutral binary)
// with one body, through readParasolidXtFile and the builder above.
// Coordinates stay in metres, the unit of every Parasolid file.
bool readParasolidXtAnalyticFile(const QString& path, kernel::OcctKernel& kernel,
                                 kernel::ShapeHandle& shape, QString& error,
                                 ParasolidXtBuildReport* report = nullptr);

// The parts an assembly places, down through its sub-assemblies: swXmlContents/COMPINSTANCETREE
// holds, in the model of each assembly file, the references to its components in that assembly's
// frame; the configuration names the top model. Each part instance comes with the product of the
// matrices from the top and is named by the path of component names ("Wheel/Hub"). A virtual
// component is a part or a sub-assembly like any other.
bool readSolidWorksAssemblyParts(const QString& path, std::vector<SolidWorksAssemblyComponent>& parts,
                                 QString& error);

// Loads the parts of an assembly (readSolidWorksAssemblyParts) and applies each instance matrix. A
// part is the file next to the assembly, or else the copy SOLIDWORKS keeps inside it: a part made
// from a foreign file under ImportedComp/<file>, a virtual one under VirtualComp/<name>.
// Every component must be supported by readSolidWorksPlanarPart.
bool readSolidWorksPlanarAssembly(const QString& path, kernel::OcctKernel& kernel,
                                 std::vector<SolidWorksImportedBody>& bodies,
                                 QString& error);

bool readSolidWorksAnalyticAssembly(const QString& path, kernel::OcctKernel& kernel,
                                   std::vector<SolidWorksImportedBody>& bodies,
                                   QString& error, ParasolidXtBuildReport* report = nullptr);

// The same assembly as a product structure, for the Assembly workbench: each SLDPRT built once as a
// part in its own coordinates, each component an instance placed by its matrix. A component whose
// matrix is not a rigid placement (mirrored or scaled) becomes a part of its own, baked, and is
// named in the warnings — as a STEP import does.
// `progress`, when given, hears of each part before it is built and can stop the reading between parts.
bool readSolidWorksAssemblyProduct(const QString& path, kernel::OcctKernel& kernel,
                                   kernel::ProductStructure& product, QString& error,
                                   ParasolidXtBuildReport* report = nullptr,
                                   const ImportProgress* progress = nullptr);

} // namespace cadnext::gui
