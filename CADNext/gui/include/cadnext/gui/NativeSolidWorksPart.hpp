#pragma once

#include "cadnext/kernel/OcctKernel.hpp"

#include <QByteArray>
#include <QDateTime>
#include <QMap>
#include <QMultiMap>
#include <QString>

#include <array>
#include <vector>

namespace cadnext::gui {

// A SOLIDWORKS part document (.SLDPRT, 2015+ container) holding one imported body, laid out as
// SOLIDWORKS 2022 lays out a part it made from a STEP file: the body with its import feature
// (Config-0-FeatureBodies/LocalBodies), an empty current partition, the default planes, origin,
// folders and lights of the feature tree, the configuration "Default".
//
// How it is built. Seven such parts of the samples (sw-imported/fischertechnik, SOLIDWORKS 2022)
// have the same streams, and in each stream everything is the same but names, paths, times, the
// body's box with the planes' rectangles that follow from it, and the count of the body's faces.
// The blueprint (NativeSolidWorksPartBlueprint.cpp) keeps what is the same as SOLIDWORKS's defaults
// — MFC class tags, strings, native bytes — and a named slot for each thing that differs; this
// writer fills the slots. Every stream of the samples is matched against the blueprint by
// cadnext_test_native_solidworks_part: outside the slots not a byte differs.
//
// Limits, all stated in the README:
//   - No SOLIDWORKS has opened a document written here.
//   - The container's signatures are those of one sample (NativeSolidWorksPackage.hpp).
//   - Contents/3DExperienceExchange2 (an UnQLite database SOLIDWORKS 2022 adds; absent in 2020's
//     documents) is not written. Neither are previews and display lists: the seven samples have none.
//   - Values whose meaning is not known are written as one sample's: a 32-bit value of the
//     document's "atom", three partition mark bytes; the save history's disk and stamp fields as 0.
//   - The import feature names a source file ("<title>.step" next to the part) that is not written.

// The streams of the blueprint, values by slot.
struct SolidWorksPartValues {
    QMap<QString, QString> text;          // "title", "configuration", "ui.FrontPlane", "date.short", …
    QMap<QString, quint64> number;        // "time.saved", "time.source", "filetime.saved", "atom",
                                          // "import.faces", "import.lastFace", "history.*", "partition.mark*"
    std::array<double, 3> boxMin{}, boxMax{};   // the body's box, metres
    // Filled by matching only: every double read with its formula ("c0", "M2", "c1+e1", "pr01", …).
    QMultiMap<QString, double> real;
};

// The names of the streams the blueprint describes ("Contents/Config-0", "docProps/core.xml", …;
// the partition's two transmits as "Contents/Config-0-Partition#0" and "#1").
QList<QByteArray> solidWorksPartBlueprintStreams();

// A blueprint stream filled with `values`: slots without a value take their default (the English
// names) or fail, numbers default to 0 or to the blueprint's own.
bool encodeSolidWorksPartStream(const QByteArray& name, const SolidWorksPartValues& values, QByteArray& bytes, QString& error);

// The same stream of a document matched against the blueprint: false when it differs outside the
// slots, or when a text slot already in `values` reads differently. Binds what it reads.
bool matchSolidWorksPartStream(const QByteArray& name, const QByteArray& bytes, SolidWorksPartValues& values, QString& error);

// The value the blueprint's formula gives for a box: the centre c, maximum M, minimum m, the
// planes' half sizes e (the box's, a tenth larger), their sums and the radii.
bool solidWorksPartFormula(const QString& formula, const std::array<double, 3>& boxMin, const std::array<double, 3>& boxMax, double& value);

// The Contents/Config-N-Partition stream of two Parasolid transmits (the partition and its deltas),
// each deflated as SOLIDWORKS deflates it, and back.
QByteArray encodeSolidWorksPartitionStream(const std::vector<QByteArray>& transmits);
bool decodeSolidWorksPartitionStream(const QByteArray& stream, std::vector<QByteArray>& transmits);

struct SolidWorksPartWriteOptions {
    QString title;        // the part's name; empty: the file's base name
    QString author = QStringLiteral("CADNext");
    QDateTime saved;      // invalid: now
    QString folder = QStringLiteral("C:\\CADNext"); // the Windows folder the document says it was saved in
};

// The values of a document for a body with this box (metres) and count of faces.
SolidWorksPartValues solidWorksPartValues(const QString& title, const std::array<double, 3>& boxMin,
                                          const std::array<double, 3>& boxMax, int faces,
                                          const SolidWorksPartWriteOptions& options);

// Writes `shape` (one solid) as a .SLDPRT. The destination is replaced only after the package was
// read back and its body's transmit found unchanged.
bool writeSolidWorksImportedPart(kernel::OcctKernel& kernel, kernel::ShapeHandle shape, const QString& path,
                                 QString& error, const SolidWorksPartWriteOptions& options = {});

} // namespace cadnext::gui
