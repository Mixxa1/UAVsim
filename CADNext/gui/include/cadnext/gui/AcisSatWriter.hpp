#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QByteArray>
#include <QString>
#include <vector>

namespace cadnext::gui {

struct AcisSatWriteReport {
    int bodies = 0;
    double largestVertexGap = 0.0; // metres
    double largestBoundaryTolerance = 0.0; // the source BRep's edge/vertex precision, metres
};

// ACIS SAT 7.0, the version accepted by AutoCAD ACISIN, in millimetres. The exact shared BRep
// topology is written with analytic surfaces and rational B-splines. Placements are applied to
// geometry. Unsupported geometry and invalid topology fail before the destination is replaced.
cadnext::Result<QByteArray> encodeAcisSat(kernel::OcctKernel& kernel,
                                         const std::vector<kernel::NamedExchangeBody>& bodies,
                                         AcisSatWriteReport& report);
cadnext::Result<AcisSatWriteReport> writeAcisSat(kernel::OcctKernel& kernel,
                                                const std::vector<kernel::NamedExchangeBody>& bodies,
                                                const QString& path);

// DXF with one 3DSOLID per body, encoded SAT in groups 1/3, INSUNITS=4 (millimetres): ASCII, or
// the same groups as a binary DXF. The SAT strings are the same in both, caret escapes included
// ("^ " for a caret): Autodesk's reference describes the expansion as a property of the strings
// SAVEAS writes, not of the ASCII form. A binary file is read back, group by group, before the
// destination is replaced.
cadnext::Result<AcisSatWriteReport> writeDxfSolids(kernel::OcctKernel& kernel,
                                                  const std::vector<kernel::NamedExchangeBody>& bodies,
                                                  const QString& path, bool binary = false);

} // namespace cadnext::gui
