#pragma once

#include "cadnext/gui/AcisSatWriter.hpp"

namespace cadnext::gui {

// The optional cadnext_dwg_writer executable uses LibreDWG to write a genuine R2000
// document. The GUI validates its ACIS payload with the independent native reader.
bool dwgSolidWriterAvailable();
cadnext::Result<AcisSatWriteReport> writeDwgSolids(
    kernel::OcctKernel& kernel, const std::vector<kernel::NamedExchangeBody>& bodies,
    const QString& path);

} // namespace cadnext::gui
