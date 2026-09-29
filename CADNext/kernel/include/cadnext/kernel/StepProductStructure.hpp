#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/kernel/Kernel.hpp"

#include <array>
#include <optional>
#include <string>
#include <vector>

// Product structure through STEP, both ways: which distinct parts an assembly is made of, and where
// each occurrence of each part sits. This is what makes a model open *as an assembly* in SOLIDWORKS,
// KOMPAS-3D, FreeCAD and AutoCAD (IMPORT turns it into nested blocks) rather than as a heap of
// separate bodies, and what lets their assemblies arrive in CADNext the same way.
//
// The structure is a graph of definitions, exactly as STEP and OCCT's XDE hold it: a part's geometry
// is stored once, however many times it is placed, and a subassembly is defined once, however many
// times it is inserted. Reuse is explicit in the data, never reconstructed by comparing shapes.
//
//   STEP Part 21                          here
//   PRODUCT_DEFINITION (a part)          ProductPart
//   PRODUCT_DEFINITION (an assembly)     ProductAssembly
//   NEXT_ASSEMBLY_USAGE_OCCURRENCE       ProductInstance (with its placement)
//
// Units: the files are written in millimetres (the unit every target system expects by default);
// the structure and the kernel's registry are in metres, as the CADNext document is.
//
// What this is not: no feature history, no parametric constraints, no mates — STEP AP214/AP242
// carries shapes and placements, and a receiving system rebuilds its own constraints if it wants
// them. Mirrored or scaled occurrences are not rigid placements; on import they are baked into a
// separate part definition and said so in the warnings.

namespace cadnext::kernel {

class OcctKernel;

// Rotation as a unit quaternion (w, x, y, z), applied first; then the translation, in metres.
struct ProductPlacement {
    std::array<double, 4> rotation{1.0, 0.0, 0.0, 0.0};
    std::array<double, 3> translation{0.0, 0.0, 0.0};
};

struct ProductPart {
    std::string name;
    ShapeHandle shape; // metres, in the part's own coordinates
    std::optional<std::array<double, 3>> colour; // surface colour, linear RGB in 0…1
};

struct ProductInstance {
    std::string name;
    ProductPlacement placement; // relative to the assembly that owns the instance
    bool isAssembly = false;    // definition indexes assemblies when true, parts when false
    int definition = -1;
};

struct ProductAssembly {
    std::string name;
    std::vector<ProductInstance> instances;
};

struct ProductStructure {
    std::vector<ProductPart> parts;
    std::vector<ProductAssembly> assemblies;
    int root = 0; // index of the top assembly
    std::vector<std::string> warnings;
};

enum class StepSchema {
    AP214, // the widest accepted: every one of the four target systems reads it
    AP242, // the current standard; newer systems prefer it
};

// `child` expressed in the frame `parent` is expressed in: parent ∘ child.
ProductPlacement composePlacements(const ProductPlacement& parent, const ProductPlacement& child);

// The placement as the kernel's instance matrix (OcctKernel::transformShape): columns are the
// images of the axes, the translation at 12..14.
std::array<double, 16> placementMatrix(const ProductPlacement& placement);

// Checks that every instance points at an existing definition and that no assembly contains itself,
// directly or through others. Empty when the structure is sound, otherwise the reason.
std::string validateProductStructure(const ProductStructure& structure);

cadnext::Result<ProductStructure> readStepProductStructure(OcctKernel& kernel, const std::string& path);

cadnext::Result<bool> writeStepProductStructure(OcctKernel& kernel, const ProductStructure& structure,
                                                const std::string& path, StepSchema schema = StepSchema::AP214);

} // namespace cadnext::kernel
