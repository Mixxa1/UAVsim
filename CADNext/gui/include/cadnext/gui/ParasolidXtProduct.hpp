#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <string>

// A Parasolid transmit file (.x_t text, .x_b neutral binary) as a product: the format SOLIDWORKS,
// Solid Edge, NX and Onshape write natively and AutoCAD and KOMPAS-3D import.
//
// Every BODY becomes an exact part through the same BRep builder as a SOLIDWORKS partition; an
// ASSEMBLY with its INSTANCEs becomes the product structure of the STEP exchange, so a part placed
// twice stays one part with two occurrences, and the Assembly workbench opens it the same way.
//
//   XT                        here
//   BODY                      ProductPart (named by its SDL/TYSA_NAME attribute)
//   ASSEMBLY                  ProductAssembly
//   INSTANCE + TRANSFORM      ProductInstance with its placement
//
// Parasolid works in metres, so do the structure and the kernel registry: nothing is scaled.
// A mirrored instance of a body is baked into a part of its own, as the STEP import does; a scaled
// or negative instance, and a mirrored subassembly, are refused with the reason.

namespace cadnext::kernel {
class OcctKernel;
}

namespace cadnext::gui {

class ImportProgress;
struct ParasolidXtBuildReport;

// A file with no assembly gives one root assembly (named after the file) with every body at the
// identity. The shapes are registered in `kernel`. `progress`, when given, hears of each body before it
// is built and can stop the reading between bodies. With `geometry` the builder's reports (blends,
// tolerant edges, faces split per turn) go there, for the caller to summarise; without it they go into
// the warnings as text.
cadnext::Result<kernel::ProductStructure> readParasolidXtProduct(kernel::OcctKernel& kernel, const std::string& path,
                                                                 const ImportProgress* progress = nullptr,
                                                                 ParasolidXtBuildReport* geometry = nullptr);

// Whether a file holds an assembly rather than loose bodies: the question the import asks before
// choosing between the Assembly workbench and bodies in the open document.
bool parasolidXtProductIsAssembly(const kernel::ProductStructure& product);

} // namespace cadnext::gui
