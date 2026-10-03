#pragma once

#include "cadnext/gui/NativeKompasTopology.hpp"

namespace cadnext::gui {

// Application state following a body's mathematical face shell. The supported
// layout has one inline native attribute and three topology ownership tables.
// Native flags and the attribute payload are retained without assigning them
// unverified application semantics. The document writer owns the native name
// namespace; it must supply a distinct positive name for each body.
struct KompasBodyApplicationState {
    std::array<quint8, 3> nativeFlags{1, 0, 1};
    quint32 nativeName = 0;
    std::array<quint8, 4> nativeFooterFlags0{1, 0, 1, 1};
    std::array<quint8, 4> nativeFooterFlags1{1, 1, 1, 1};
};

struct KompasBodyApplication {
    KompasBodyApplicationState state;
    KompasTopologyTables topology;
};

// This is the suffix of a body record, not a complete model/document. Decoding
// reports its extent so the caller can require the end of its owning record.
// Unknown attribute layouts are rejected, rather than copied as blob templates.
// The registry contract is the same as for the topology table codec.
bool decodeKompasBodyApplication(const QByteArray& bytes, qsizetype offset,
                                 const std::map<quint16, quint16>& registry,
                                 KompasBodyApplication& application,
                                 qsizetype& consumed, QString& error);
bool encodeKompasBodyApplication(const KompasBodyApplication& application,
                                 const std::map<quint16, quint16>& registry,
                                 QByteArray& bytes, QString& error);

// Separate single-name application link record. Its name must equal the name
// in the owning body's state. Only this verified layout is supported here.
bool decodeKompasBodyApplicationLink(const QByteArray& bytes, quint32& nativeName,
                                     QString& error);
bool encodeKompasBodyApplicationLink(quint32 nativeName, QByteArray& bytes,
                                     QString& error);

} // namespace cadnext::gui
