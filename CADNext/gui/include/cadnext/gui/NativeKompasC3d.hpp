#pragma once

#include "cadnext/gui/ImportProgress.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <QString>
#include <QStringList>

#include <array>
#include <vector>

namespace cadnext::gui {

// The solids of a KOMPAS-3D part (.m3d) as the C3D kernel's own serialisation in its Contents holds
// them — read from the bytes, no C3D or KOMPAS library.
//
// The Contents' zlib records are consecutive parts of one stream of objects: a new object is written
// 02, a flag (0x80: numbered), its class (u16), its number (01, u16); a later mention of it 01 and its
// number; none 00. Numbers run in writing order across records. A face shell (class 0x6239) holds its
// faces; a face (0x666e) its surface, whether its normal is the surface's, its loops (0x7d68) of
// edges (0x4313) with their direction; an edge its intersection curve (0x776d: a curve in the
// parameters of each of its two surfaces, the direction of the curve against the edge) and its two
// vertices (0x0b04). Surfaces read: plane, cylinder, cone, torus; curves in surface parameters: line,
// arc, trimmed, composite, Hermite spline; cached 3D curves: line, arc, NURBS.
//
// Each edge's geometry is taken exactly from its curve in a surface's parameters: a line or arc on a
// plane, a parameter line of a cylinder, cone or torus (a generator or a circle); any other edge is
// the intersection of its two surfaces, its path through the curve's points. Shells naming the same
// faces are one body; each distinct shell becomes a solid by the analytic builder.
struct KompasSolid {
    QString name;
    kernel::ShapeHandle shape;
    int faces = 0;
};

struct KompasC3dResult {
    std::vector<KompasSolid> solids;
    QStringList notes;
    // Edges taken as C3D holds them, a curve in a surface's parameters (a thread's run-out): how many, the
    // largest distance between each one's two curves (mm), Σ distance² × length / sin θ over them (mm³) and
    // the smallest sin θ, θ the angle their two surfaces meet at. The sum is the most the solid's volume can
    // differ for them: such an edge lies on one surface and within d of the other, so up to d / sin θ from
    // their true intersection along the first — a sliver of section under d² / sin θ.
    int curveEdges = 0;
    double curveEdgeGap = 0.0;
    double curveEdgeSliver = 0.0;
    double curveEdgeSine = 1.0;
};

bool readKompasC3dSolids(const QString& path, kernel::OcctKernel& kernel, KompasC3dResult& result, QString& error,
                         ParasolidXtBuildReport* report = nullptr);

// A KOMPAS-3D assembly (.a3d): its components, each a part file placed in the assembly. The parts are
// files of their own; the assembly names each (a file link, class 0x4821: the path as written relative to
// the assembly, and absolute) and places each component by a frame (a record of class 0x0416 of its own:
// its box in the assembly, then origin and axes X, Y, Z in millimetres, then its file link).
struct KompasComponent {
    int index = 0;
    QString relativePath;
    QString absolutePath;
    std::array<double, 3> origin{};
    std::array<double, 9> axes{}; // X, Y, Z, unit and at right angles, right-handed
};

struct KompasAssembly {
    std::vector<KompasComponent> components;
};

bool readKompasAssembly(const QString& path, KompasAssembly& assembly, QString& error);

// The file a component names, found next to the assembly: along its relative path, else by its file name
// (the relative path's, then the absolute path's) in the assembly's folder, case aside. Empty: not there.
QString kompasComponentFile(const QString& assemblyPath, const KompasComponent& component);

// The component's placement in the assembly (metres).
kernel::ProductPlacement kompasComponentPlacement(const KompasComponent& component);

// The assembly as a product structure: each part file found next to it read once (readKompasC3dSolids),
// each of its bodies a part, each component an occurrence of them at its frame. Parts not found or not
// built are named in `notes`; false with `error` when none is built. A component naming an assembly
// (.a3d) is not read (none in the samples) and said so.
bool readKompasAssemblyProduct(const QString& path, kernel::OcctKernel& kernel, kernel::ProductStructure& product,
                               QString& error, QStringList& notes, ParasolidXtBuildReport* report = nullptr,
                               const ImportProgress* progress = nullptr);

} // namespace cadnext::gui
