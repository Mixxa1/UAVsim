#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/gui/ImportProgress.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/gui/ParasolidXtWriter.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <string>
#include <vector>

// A CADNext assembly (.cadasm) as a STEP product structure, and back.
//
// Export walks the assembly document the way the Assembly workbench shows it: joints are solved
// first, so every component leaves where the user sees it; a part file linked N times is one STEP
// part with N occurrences; a subassembly file is one STEP assembly however often it is inserted.
// Suppressed components are not part of the product and stay out; hidden ones are (hiding is a view
// setting, and SOLIDWORKS exports hidden components too).
//
// Import writes the structure as CADNext files in a folder: one .cadnext per distinct part — the
// exact BRep kept inside, so it opens without the STEP file — and one .cadasm per distinct assembly,
// the top one returned. A received assembly has no joints; its first component is grounded and the
// rest stay where the file put them, free to be constrained later.
//
// A part that has no exact geometry (a .uavpart carrying only a mesh) is refused with its name:
// a mesh is never written as if it were a solid.

namespace cadnext::kernel {
class OcctKernel;
}

namespace cadnext::gui {

struct AssemblyExchangeReport {
    int parts = 0;
    int assemblies = 0;
    int occurrences = 0; // leaf part occurrences, counted through every subassembly
    std::vector<std::string> warnings;
    // What the exact builder had to say (SOLIDWORKS and Parasolid imports): approximated blends,
    // tolerant edges, faces split per turn — kept apart from the warnings, for a short summary.
    ParasolidXtBuildReport geometry;
};

cadnext::Result<AssemblyExchangeReport> exportAssemblyToStep(const std::string& cadasmPath, const std::string& stepPath,
                                                             kernel::StepSchema schema = kernel::StepSchema::AP214);

// The same product as a Parasolid transmit file (writeParasolidXtProduct): one body per distinct
// part, an INSTANCE with its TRANSFORM per occurrence, subassemblies as ASSEMBLY nodes.
cadnext::Result<AssemblyExchangeReport> exportAssemblyToParasolid(const std::string& cadasmPath, const std::string& xtPath,
                                                                  ParasolidXtEncoding encoding);

// The same product as a KOMPAS-3D assembly (writeKompasNativeAssembly): each part placed a .m3d beside the
// .a3d, each leaf occurrence a component — subassemblies flattened, their placements composed. At most
// five occurrences (the KOMPAS writer's limit), refused otherwise.
cadnext::Result<AssemblyExchangeReport> exportAssemblyToKompas(const std::string& cadasmPath, const std::string& a3dPath);

// Returns the path of the top .cadasm written into `folder` (created when missing). The imports take an
// optional progress: told of each part, and able to stop between parts (the reason then is
// importCancelledReason()); they run on any thread, touching nothing but their own kernel and files.
cadnext::Result<std::string> importStepAsAssembly(const std::string& stepPath, const std::string& folder,
                                                  AssemblyExchangeReport& report,
                                                  const ImportProgress* progress = nullptr);

// The same for a Parasolid transmit file (.x_t, .x_b): its bodies and assembly instances, read by
// readParasolidXtProduct, written the same way.
cadnext::Result<std::string> importParasolidXtAsAssembly(const std::string& xtPath, const std::string& folder,
                                                         AssemblyExchangeReport& report,
                                                         const ImportProgress* progress = nullptr);

// The same for a SOLIDWORKS assembly (.SLDASM) with its SLDPRT files next to it: each part built once
// (readSolidWorksAssemblyProduct), each component an occurrence. A single .SLDPRT becomes an assembly
// of that one part.
cadnext::Result<std::string> importSolidWorksAsAssembly(const std::string& sldasmPath, const std::string& folder,
                                                        AssemblyExchangeReport& report,
                                                        const ImportProgress* progress = nullptr,
                                                        const std::string& configuration = {});

// The same for a KOMPAS-3D assembly (.a3d) with its .m3d parts next to it (readKompasAssemblyProduct): each
// part built once, each component an occurrence; parts not found are named in the warnings. A single .m3d
// becomes an assembly of its bodies, each placed where it is.
cadnext::Result<std::string> importKompasAsAssembly(const std::string& path, const std::string& folder,
                                                    AssemblyExchangeReport& report,
                                                    const ImportProgress* progress = nullptr);

// The writing half of all of them: a product structure whose shapes live in `exchange`, as .cadnext parts
// and .cadasm assemblies. `format` names the source in warnings.
cadnext::Result<std::string> writeProductAsAssembly(kernel::OcctKernel& exchange, const kernel::ProductStructure& structure,
                                                    const std::string& folder, const std::string& format,
                                                    AssemblyExchangeReport& report,
                                                    const ImportProgress* progress = nullptr);

} // namespace cadnext::gui
