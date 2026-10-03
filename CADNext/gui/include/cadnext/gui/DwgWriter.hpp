#pragma once

#include "cadnext/gui/AcisSatWriter.hpp"

namespace cadnext::gui {

// An AutoCAD 2000 drawing (AC1015) of the bodies as 3DSOLID entities in model space, millimetres,
// written by CADNext's own codecs (NativeDwgR2000): AutoCAD 2000's template tables, dictionaries and
// layouts, a picture of the bodies. Its ACIS payload is read back with the independent native reader
// before the destination is replaced.
bool dwgSolidWriterAvailable(); // always: nothing outside CADNext is needed
cadnext::Result<AcisSatWriteReport> writeDwgSolids(
    kernel::OcctKernel& kernel, const std::vector<kernel::NamedExchangeBody>& bodies,
    const QString& path);

} // namespace cadnext::gui
