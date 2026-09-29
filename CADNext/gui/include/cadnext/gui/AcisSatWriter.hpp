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

// ASCII DXF with one 3DSOLID per body, encoded SAT in groups 1/3, INSUNITS=4 (millimetres).
cadnext::Result<AcisSatWriteReport> writeDxfSolids(kernel::OcctKernel& kernel,
                                                  const std::vector<kernel::NamedExchangeBody>& bodies,
                                                  const QString& path);

} // namespace cadnext::gui
