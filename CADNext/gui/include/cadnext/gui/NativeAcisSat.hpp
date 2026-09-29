#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>

#include <string>
#include <vector>

#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

namespace cadnext::kernel {
class OcctKernel;
}

namespace cadnext::gui {

// ACIS SAT, Spatial's text save file — a standalone .sat (SOLIDWORKS, Inventor, SpaceClaim, AutoCAD's
// ACISOUT) and the body data of a 3DSOLID in DXF and DWG — read into exact solids by the same analytic
// builder as Parasolid: analytic and NURBS geometry, linear sum surfaces, swept profiles, rolling-ball
// blends (including variable radii), parameter, law and offset curves. Procedural geometry is rebuilt
// from its definition with a measured approximation error; the source's coarse cached splines serve
// as guides and consistency checks. The build report records approximated faces and their deviations.
//
// The layout of a record changes with the save version (ACIS 1.03 to 22 read here: the header's first
// integer, e.g. 106, 400, 2200). Where a version's field is optional, the reader tells by what follows
// (a pointer or a number, a logical word or a number) rather than by version thresholds it has no
// sample of. Cones with a negative cosine and tori with a negative minor radius have their natural
// normal turned inward (the Mechanical Desktop samples); refused with the reason: elliptical cones,
// spheres of negative radius (no sample), unsupported procedural definitions, sheet bodies and
// subshells. Wire bodies are reported and skipped.
struct AcisSatSolid {
    QString name;
    kernel::ShapeHandle shape;
};

struct AcisSatResult {
    int version = 0;
    // From the header's third line; 0 where the file does not say (versions before 4.0 have no such
    // line, or it holds -1): read as millimetres then, and `notes` says so.
    double millimetresPerUnit = 0.0;
    std::vector<AcisSatSolid> solids;
    QStringList notes;
};

// `millimetresPerUnit`: the units a container states for a SAT whose header does not (a DWG's
// INSUNITS for its solids); 0 where none does.
bool readAcisSat(const QByteArray& text, kernel::OcctKernel& kernel, AcisSatResult& result, QString& error,
                 ParasolidXtBuildReport* report = nullptr, const QString& name = {}, double millimetresPerUnit = 0.0);

bool readAcisSatFile(const QString& path, kernel::OcctKernel& kernel, AcisSatResult& result, QString& error,
                     ParasolidXtBuildReport* report = nullptr);

} // namespace cadnext::gui
