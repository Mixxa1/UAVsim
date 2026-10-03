#pragma once

#include "cadnext/kernel/OcctKernel.hpp"

#include <QByteArray>
#include <QString>

#include <array>
#include <vector>

namespace cadnext::gui {

// A body's display mesh as KOMPAS 17.1 stores it (/#170/#157/#303/<body>/Triangle),
// read from the 35 meshes of the 21 v17 parts of the samples: one grid per face —
// the face's name as its topology header has it, the extent of the grid, for a
// planar face its normal, the points (mm) and normals as 32-bit floats, the
// triangles (counter-clockwise seen from outside), the triangulation's step (sag,
// angle, length) and each boundary of the triangulation as an open polyline —
// the grids of curved faces in one list, those of planar faces in another,
// grouped by colour and material; then the body's box.
struct KompasMeshGrid {
    std::vector<quint32> names;
    quint32 nameTail = 0; // the three bytes after the names, as the face's header has them
    std::array<double, 3> extent{};
    std::array<double, 3> normal{}; // a planar face's; zero otherwise
    bool planar = false;
    std::vector<std::array<float, 3>> points;
    std::vector<std::array<float, 3>> normals;
    std::vector<std::array<quint32, 3>> triangles;
    std::vector<std::array<quint32, 4>> quadrangles;
    std::array<double, 3> step{}; // sag (mm), angle (rad), length (mm)
    std::vector<std::vector<quint32>> boundaries;
};

struct KompasMeshGroup {
    quint32 color = 0x00909090;
    std::array<quint8, 6> material{50, 60, 80, 80, 100, 50};
    quint8 flags = 1;
    quint32 key = 0;
    std::vector<KompasMeshGrid> grids;
};

struct KompasMesh {
    std::vector<KompasMeshGroup> curved;
    std::vector<KompasMeshGroup> planar;
    std::array<double, 9> box{}; // minimum, maximum and size, mm
};

// Outputs are reset on failure; a record that does not end where its last field
// ends is refused.
bool encodeKompasMesh(const KompasMesh& mesh, QByteArray& bytes, QString& error);
bool decodeKompasMesh(const QByteArray& bytes, KompasMesh& mesh, QString& error);

// The triangulation step KOMPAS 17.1 uses: a sag of 0.001472 of the diagonal of
// the whole model's box (so in every sample), an angle of 2π/50, no length limit.
std::array<double, 3> kompasMeshStep(double modelDiagonalMm);

// The display mesh of a body (metres) whose faces are named, in the order
// describeExactBRep gives them, [mainName, index + 1] with no further header
// bytes — as the native writer names them. Triangulated by OCCT with `step`, on
// a copy of the body.
bool kompasBodyMesh(kernel::OcctKernel& kernel, kernel::ShapeHandle body, quint32 mainName,
                    const std::array<double, 3>& step, quint32 color, const std::array<quint8, 6>& material,
                    KompasMesh& mesh, QString& error);

} // namespace cadnext::gui
