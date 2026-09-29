#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <string>
#include <vector>

// Parasolid transmit files written by CADNext: text .x_t or neutral binary .x_b, a part or an
// assembly, the format SOLIDWORKS, Solid Edge, NX and Onshape use natively and AutoCAD and
// KOMPAS-3D import. The counterpart of readParasolidXtProduct.
//
// Layout: the data header, schema key and node table of Parasolid 19.1 (SOLIDWORKS 2009), the
// embedded-schema form of V14 and later. Every node type is transmitted as its V13 base schema
// (13006) describes it, which is how Parasolid 19.1 and 33 themselves transmit all the types written
// here; BODY carries the four fields Parasolid appends to it. Nodes are laid out by the very table
// the CADNext reader decodes by (parasolidXtBaseSchema), so a writer and a reader cannot disagree
// on a field.
//
// Geometry: exact, as ExactBRepDescription gives it (planes, cylinders, cones, spheres, tori,
// B-spline surfaces; lines, circles, ellipses, B-spline curves). Metres, as in every Parasolid file.
// Vertices, edges and faces are written as accurate; if the BRep's vertices are further from their
// curves than Parasolid's linear precision of 1e-8 m, the report says by how much.
//
// Not written yet: names and colours (attributes), tolerant edges. Every written file is decoded
// again by the CADNext reader before this returns; a file the reader cannot read is not left behind.

namespace cadnext::kernel {
class OcctKernel;
}

namespace cadnext::gui {

enum class ParasolidXtEncoding { Text, Binary };

struct ParasolidXtWriteReport {
    int bodies = 0;
    int assemblies = 0;
    int instances = 0;
    double largestVertexGap = 0.0; // metres
    std::vector<std::string> warnings;
};

// A product whose root holds one part at the identity is written as a part file (root BODY);
// anything else as an assembly (root ASSEMBLY, INSTANCE and TRANSFORM nodes, each part's body once).
cadnext::Result<ParasolidXtWriteReport> writeParasolidXtProduct(kernel::OcctKernel& kernel,
                                                                const kernel::ProductStructure& product,
                                                                const std::string& path,
                                                                ParasolidXtEncoding encoding);

// The bytes alone, for a caller that stores them elsewhere or compares them.
cadnext::Result<std::string> encodeParasolidXtProduct(kernel::OcctKernel& kernel, const kernel::ProductStructure& product,
                                                      const std::string& name, ParasolidXtEncoding encoding,
                                                      ParasolidXtWriteReport& report);

// A current-state partition stream (WORLD root), the representation cached by a SOLIDWORKS
// configuration. This is a Parasolid stream, not a complete .SLDPRT container or feature history.
cadnext::Result<std::string> encodeParasolidXtPartition(kernel::OcctKernel& kernel,
                                                       const kernel::ShapeHandle& shape);

} // namespace cadnext::gui
