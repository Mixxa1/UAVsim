#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <memory>
#include <optional>
#include <vector>

namespace cadnext::gui {

struct SolidWorksArchiveString {
    QString text;
    bool unicode = true;
};

struct SolidWorksDocumentStamp {
    quint32 nativeAction = 0;
    quint16 authorIndex = 0;
    quint32 time = 0;
    SolidWorksArchiveString text;
};

struct SolidWorksDocumentLog {
    std::vector<SolidWorksDocumentStamp> stamps;
    quint32 featureId = 0;
    SolidWorksArchiveString featureName;
};

struct SolidWorksDocumentReference {
    // Shared pointers represent actual MFC object identity. Equal text does
    // not imply a shared handle; references may reuse either handle explicitly.
    std::shared_ptr<SolidWorksArchiveString> path;
    std::shared_ptr<SolidWorksArchiveString> title;
    quint16 documentType = 2; // part 2, assembly 3, drawing 4, imported source 5
    bool virtualDocument = false;
    quint32 modifiedAt = 0;
    std::vector<SolidWorksArchiveString> auxiliaryStrings;
    quint8 extendedByte = 0;
    quint8 nativeByte = 0;
    std::array<quint32, 4> nativeFields{};
    SolidWorksArchiveString configurationName;
    quint32 configurationId = 0;
    std::array<quint32, 2> nativeFields2{};
    std::optional<quint32> nativeField3;
};

enum class SolidWorksDocumentHeaderLayout {
    Classic,       // one auxiliary string; no final four native words
    Standard,      // two auxiliary strings and four final native words
    Extended,      // three auxiliary strings; six extra final words
    ExtendedByte,  // three auxiliary strings, extra byte, seven final words
    StandardCompact, // two auxiliary strings; no final trailer
    ExtendedByteModern, // extra reference word and sixteen extension words
    StandardLegacy // two auxiliary strings and three final native words
};

struct SolidWorksDocumentHeader {
    SolidWorksDocumentHeaderLayout layout = SolidWorksDocumentHeaderLayout::Standard;
    // Newer archives may add the native word 1 before the author arrays.
    // Its semantics are not established; its presence does not allocate an
    // MFC object or change any of the class/object reference indices.
    std::optional<quint32> nativePrefixWord;
    std::vector<SolidWorksArchiveString> authors;
    std::vector<SolidWorksArchiveString> secondaryStrings;
    std::vector<SolidWorksDocumentLog> logs;
    quint32 createdAt = 0;
    // Native feature counter: some archives retain the highest saved ID here,
    // so a log may have an ID equal to this value.
    quint32 nextFeatureId = 0;
    std::vector<SolidWorksDocumentReference> references;
    quint32 modifiedStamp = 0;
    SolidWorksDocumentReference currentDocument;
    // Fields whose meaning is not established remain typed native scalars.
    // They are never replaced with copied, opaque document bytes.
    std::array<quint32, 7> nativeFields{};
    quint16 nativeWord = 0;
    std::array<quint32, 3> nativeCounters{};
    bool allocatedEmptyList = true;
    std::array<quint32, 2> nativeFields2{};
    std::optional<std::array<double, 10>> nativeBounds;
    // StandardLegacy stores three words; its unused fourth slot must be zero.
    std::optional<std::array<quint32, 4>> nativeTrailer;
    std::vector<quint32> nativeExtension;
};

// Own codec for the complete Header2/Config-N-ModelHeader MFC archive, schema 1. Preserves author
// and feature logs, external document records, shared string handles, current
// configuration, native scalar fields, bounds, all seven body layouts and the
// optional native prefix word.
// This section alone is not a complete SLDPRT/SLDASM document.
// Output is cleared on failure. Limits: 64 MiB, 4096 items/UTF-16 units per
// string, 8192 stamps in total. Unsupported graphs/layouts are rejected.
bool decodeSolidWorksDocumentHeader(const QByteArray& bytes,
    SolidWorksDocumentHeader& header, QString& error);
bool encodeSolidWorksDocumentHeader(const SolidWorksDocumentHeader& header,
    QByteArray& bytes, QString& error);

} // namespace cadnext::gui
