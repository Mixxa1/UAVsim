#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <optional>
#include <vector>

namespace cadnext::gui {

// Definitions in the document's _ADDPROP_F stream. These are independent of
// the model/body material records and of the document's stored property values.
// Only the verified by-value definition layout and empty secondary list are
// supported; other object/variant layouts are rejected without copying bytes.
struct KompasPropertyDefinition {
    quint64 nativeType = 2;
    double nativeLimit = 260;
    double id = 0;
    QString sourceKey;
    QString valueKey;
    QString displayName;
    // Empty variant and an allocated, empty string array are distinct states.
    std::optional<std::vector<QString>> choices;
    quint32 nativeRule = 0;
};

struct KompasPropertyDefinitions {
    std::vector<KompasPropertyDefinition> entries;
};

struct KompasPropertyTuningEntry {
    double id = 0;
    bool enabled = false;
};

// Two separately ordered lists in _ADDPROP_TUNING_F. Their native roles are
// not inferred from their current order; the lists can contain different IDs.
struct KompasPropertyTuning {
    std::array<std::vector<KompasPropertyTuningEntry>, 2> lists;
};

// Complete records: trailing bytes are rejected and outputs reset on failure.
bool decodeKompasPropertyDefinitions(const QByteArray& bytes,
                                     KompasPropertyDefinitions& definitions,
                                     QString& error);
bool encodeKompasPropertyDefinitions(const KompasPropertyDefinitions& definitions,
                                     QByteArray& bytes, QString& error);
bool decodeKompasPropertyTuning(const QByteArray& bytes, KompasPropertyTuning& tuning,
                                QString& error);
bool encodeKompasPropertyTuning(const KompasPropertyTuning& tuning,
                                QByteArray& bytes, QString& error);

// A document composer must also validate references between the two records.
bool validateKompasPropertyReferences(const KompasPropertyDefinitions& definitions,
                                      const KompasPropertyTuning& tuning,
                                      QString& error);

} // namespace cadnext::gui
