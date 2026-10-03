#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <map>

namespace cadnext::gui {

// Typed envelopes around the controller vector in the supported v17 model
// record. The controller objects and document properties are separate records;
// these envelopes alone do not constitute a native document.
struct KompasModelHeader {
    std::array<double, 16> transform{1, 0, 0, 0, 0, 1, 0, 0,
                                   0, 0, 1, 0, 0, 0, 0, 1};
    // Native boxes contain min XYZ followed by max XYZ, in millimetres.
    // The inverted +/-1e300 box is the native empty-cache representation.
    std::array<std::array<double, 6>, 3> boxes{{
        {1e300, 1e300, 1e300, -1e300, -1e300, -1e300},
        {1e300, 1e300, 1e300, -1e300, -1e300, -1e300},
        {1e300, 1e300, 1e300, -1e300, -1e300, -1e300}}};
    quint64 controllerCount = 0;
};

struct KompasModelFooter {
    quint16 originId = 0;
    // Four native registry counters, serialized as u32/u32/u64/u64. Their
    // aggregate precedes them in the stream. They retain historical numbering
    // and must not be replaced with the number of live controllers or bodies.
    std::array<quint64, 4> nativeCounters{};
    // Presence of the supported fixed scalar extension, not opaque bytes.
    bool extendedState = false;
    quint32 nextMainName = 0;
};

// The supported v17 model-property record (model catalog entry 100), with
// the native default scalar display profile. This is distinct from the
// document's property catalog and from each body's property record.
struct KompasModelProperties {
    QString name;
    quint32 color = 0x00909090;
    std::array<quint8, 6> material{50, 60, 80, 80, 100, 50};
    QString materialName;
    double nativeDensity = 7.82;
};

// An invalidated native mass/inertia cache, with the supported default unit
// profile. Density is g/mm^3 here, whereas material properties use g/cm^3.
// Calculated caches require their own validated codec; no stale quantities or
// borrowed cache matrices are emitted by this writer.
struct KompasDeferredMassProperties {
    double nativeDensity = 0.00782;
};

// Body-property envelope (body catalog entry 301), distinct from its math and
// topology application records. Additional trailing record data, when present,
// lies outside this envelope and is not authored until its layout is verified.
struct KompasBodyProperties {
    quint32 nativeFlags = 3; // supported native profiles: 0 and 3
    KompasModelProperties properties;
    KompasDeferredMassProperties massCache;
};

// Outputs are reset on failure. Decoders return only their envelope extent.
// The footer's origin reference must resolve to a registered origin controller.
bool decodeKompasModelHeader(const QByteArray& bytes, qsizetype offset,
                             KompasModelHeader& header, qsizetype& consumed,
                             QString& error);
bool encodeKompasModelHeader(const KompasModelHeader& header,
                             QByteArray& bytes, QString& error);
bool decodeKompasModelFooter(const QByteArray& bytes, qsizetype offset,
                             const std::map<quint16, quint16>& registry,
                             KompasModelFooter& footer, qsizetype& consumed,
                             QString& error);
bool encodeKompasModelFooter(const KompasModelFooter& footer,
                             const std::map<quint16, quint16>& registry,
                             QByteArray& bytes, QString& error);
bool decodeKompasModelProperties(const QByteArray& bytes, qsizetype offset,
                                 KompasModelProperties& properties,
                                 qsizetype& consumed, QString& error);
bool encodeKompasModelProperties(const KompasModelProperties& properties,
                                 QByteArray& bytes, QString& error);
bool decodeKompasDeferredMassProperties(const QByteArray& bytes, qsizetype offset,
                                       KompasDeferredMassProperties& properties,
                                       qsizetype& consumed, QString& error);
bool encodeKompasDeferredMassProperties(const KompasDeferredMassProperties& properties,
                                       QByteArray& bytes, QString& error);
bool decodeKompasBodyProperties(const QByteArray& bytes, qsizetype offset,
                               KompasBodyProperties& properties,
                               qsizetype& consumed, QString& error);
bool encodeKompasBodyProperties(const KompasBodyProperties& properties,
                               QByteArray& bytes, QString& error);

} // namespace cadnext::gui
