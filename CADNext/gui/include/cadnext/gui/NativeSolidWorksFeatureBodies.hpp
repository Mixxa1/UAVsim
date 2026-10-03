#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <vector>

namespace cadnext::gui {

enum class SolidWorksFeatureBodyLayout { SingleBodyEntries, GroupedBodies };

struct SolidWorksFeatureBody {
    // BODY-rooted transmit payload, not a WORLD-rooted current-state partition.
    QByteArray parasolid;
    // Native scalar fields in the body and compression wrappers. Their meaning
    // is not established; geometry and compression lengths are authored anew.
    quint32 nativeField = 0;
    quint8 nativeByte = 0;
    quint8 wrapperByte = 0;
    std::array<quint32, 2> nativeTrailer{}; // the words that close the chain of pieces: zero in every document read
};

struct SolidWorksFeatureBodies {
    QString featureName;
    bool unicodeName = true;
    quint32 nativeField = 0;
    std::vector<SolidWorksFeatureBody> bodies;
};

// Own codec for Config-N-FeatureBodies/LocalBodies. Supports the older named
// single-body entries and newer named groups of bodies. Encoding recomputes both nested
// lengths and zlib data from the geometry; it does not copy compressed blocks.
// A body's transmit is stored as pieces deflated one by one (lengths before each) and two closing
// words: one piece up to 1 MiB, and past that a first piece of 1 MiB with 4096-byte ones after it.
// Any chain of pieces is read; the split written is the one SOLIDWORKS made of the only body of
// the samples that is longer than 1 MiB.
// This is one document section, not a complete imported-feature object graph
// or native CAD file. Limits: 4096 features/bodies/name units, 256 MiB per body,
// 512 MiB in total. Outputs are cleared on every failure.
bool decodeSolidWorksFeatureBodies(const QByteArray& bytes,
    std::vector<SolidWorksFeatureBodies>& features, QString& error,
    SolidWorksFeatureBodyLayout* layout = nullptr);
// The body records found inside another stream. SOLIDWORKS 2020 keeps an imported body with its
// feature, inside Contents/Config-N-ResolvedFeatures, in the record LocalBodies has for a body
// (one witness). A record counts when its lengths agree, its pieces inflate and give a transmit.
std::vector<SolidWorksFeatureBody> findSolidWorksStoredBodies(const QByteArray& stream);
bool encodeSolidWorksFeatureBodies(const std::vector<SolidWorksFeatureBodies>& features,
    QByteArray& bytes, QString& error,
    SolidWorksFeatureBodyLayout layout = SolidWorksFeatureBodyLayout::GroupedBodies);

} // namespace cadnext::gui
