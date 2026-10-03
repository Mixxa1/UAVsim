#pragma once

#include <QByteArray>
#include <QDateTime>
#include <QString>

#include "cadnext/gui/NativeKompasProperties.hpp"

#include <array>
#include <optional>
#include <vector>

namespace cadnext::gui {

// Document records of the supported v17 part profile whose content does not
// depend on the model: in every KOMPAS 17.1 part of the samples (21 files by
// several authors) each is the same, byte for byte. Fields are encoded one by
// one as observed — version tags, empty lists, a native class tag — and a
// decoder rejects any other content, which belongs to a profile not yet
// supported. Field roles are named only where the samples show them.
enum class KompasServiceRecord {
    ApplicationVersion, // /#113: the application file version, as the catalog's second version
    ModelSet100,        // /#170/#155/#100
    ModelSet500,        // /#170/#155/#500
    ModelSet700,        // /#170/#155/#700
    Model180,           // /#170/#180
    Model210,           // /#170/#210
    Document205,        // /#205
    Document230,        // /#230/#230
    Document260,        // /#260
    Document280,        // /#280
    Document290,        // /#290
    Passwords,          // /_KD_I/_PW_DN/_PW_FN
    // Of the profile most of the samples share (the role of the values not known where not named):
    Document114,        // /#114: 0 and 7 (17 of the 21 parts)
    Model109,           // /#170/#109: 0 (19 of 21; the other two hold sketch objects, /#170/#150)
    View,               // /#140: the default view — orientation 7 (isometric), origin at 0, the standard
                        // isometric rotation, scale 1, an identity frame (18 of 21; the others were turned)
    UserSettings,       // /_DUS_D/_DUS_F: eight indexed values (14 of 21)
};

bool encodeKompasServiceRecord(KompasServiceRecord record, quint32 applicationVersion,
                               QByteArray& bytes, QString& error);
bool decodeKompasServiceRecord(KompasServiceRecord record, const QByteArray& bytes,
                               quint32& applicationVersion, QString& error);

// The document's dates (/_KD_I/_DI_D): created and last modified, local time
// to two seconds (MS-DOS date and time words).
struct KompasDocumentDates {
    QDateTime created;
    QDateTime modified;
};
bool encodeKompasDocumentDates(const KompasDocumentDates& dates, QByteArray& bytes, QString& error);
bool decodeKompasDocumentDates(const QByteArray& bytes, KompasDocumentDates& dates, QString& error);

// The document's authors (/_KD_I/_DI_C), one entry per author record as KOMPAS
// keeps them (a document may repeat one author): the name, and an organization.
struct KompasDocumentAuthor {
    QString name;
    std::optional<QString> organization;
};
bool encodeKompasDocumentAuthors(const std::vector<KompasDocumentAuthor>& authors, QByteArray& bytes, QString& error);
bool decodeKompasDocumentAuthors(const QByteArray& bytes, std::vector<KompasDocumentAuthor>& authors, QString& error);

// The model's counters, four records: /#170/#110 the object id of the first
// body's shell (/#170/#300, first entry), /#170/#200/#201 the catalog's last
// object id, /#170/#202 and /#170/LayoutInstances a further counter and that
// plus 8 — so in every sample; what #202's value counts the samples do not show
// (it grows from one document of an author to the next).
struct KompasModelCounters {
    quint32 firstBodyShell = 0;
    quint32 lastObjectId = 0;
    quint32 layoutCounter = 0;
};
struct KompasModelCounterRecords {
    QByteArray firstBodyShell; // /#170/#110
    QByteArray lastObjectId;   // /#170/#200/#201
    QByteArray layout;         // /#170/#202
    QByteArray layoutInstances; // /#170/LayoutInstances
};
bool encodeKompasModelCounters(const KompasModelCounters& counters, KompasModelCounterRecords& records, QString& error);
bool decodeKompasModelCounters(const KompasModelCounterRecords& records, KompasModelCounters& counters, QString& error);

// The document's representations (/_KD_I/_SA_DN/_RR_FN): the four standard
// ones of every sample — Полный, Пустой, Упрощенный, Габарит (kinds 0, 2, 10,
// 8) — each with a unique key, a millisecond count KOMPAS gives them 100 apart.
struct KompasRepresentation {
    double key = 0;
    quint32 kind = 0;
    QString name;
};
// The standard four, keyed from `firstKey` on.
std::vector<KompasRepresentation> kompasStandardRepresentations(double firstKey);
bool encodeKompasRepresentations(const std::vector<KompasRepresentation>& list, QByteArray& bytes, QString& error);
bool decodeKompasRepresentations(const QByteArray& bytes, std::vector<KompasRepresentation>& list, QString& error);

// /#204: the document's designation (MetaInfo's property 4; empty when it has
// none), the separators of a designation ('-', '.', ' ') and the indexed values
// /_DUS_D/_DUS_F holds, in the supported profile.
bool encodeKompasDesignationRecord(const QString& designation, QByteArray& bytes, QString& error);
bool decodeKompasDesignationRecord(const QByteArray& bytes, QString& designation, QString& error);

// A document layer (/#270 holds the list). The samples hold one, the default
// "Системный слой" with the default colour and material; other field values
// of a layer are not supported.
struct KompasLayer {
    QString name = QStringLiteral("Системный слой");
    quint32 color = 0x00909090;
    std::array<quint8, 6> material{50, 60, 80, 80, 100, 50};
};

// Outputs are reset on failure.
bool encodeKompasLayers(const std::vector<KompasLayer>& layers, QByteArray& bytes, QString& error);
bool decodeKompasLayers(const QByteArray& bytes, std::vector<KompasLayer>& layers, QString& error);

// The standard property set of a v17 part document — the same in all 21 parts
// of the samples: 25 definitions (/_ADDPROP_D/_ADDPROP_F), their two display
// lists (/_ADDPROP_TUNING_D/_ADDPROP_TUNING_F) and their descriptions in the
// MetaInfo member. Property 5 is the name, 8 the mass (kg), 9 the material,
// 11 the author, 12 the organization, 14 the object type, and so on.
KompasPropertyDefinitions kompasStandardPropertyDefinitions();
KompasPropertyTuning kompasStandardPropertyTuning();

// The MetaInfo member of a part: UTF-16BE with a byte-order mark, the standard
// descriptions, the document's property values, its embodiment (object 0) with
// the same values, and one component per body (objects 1, 2, ... in order).
// A mass of 0 is written while the mass is not calculated, as KOMPAS does.
struct KompasMetaInfoBody {
    QString name;
    double massKg = 0;
    QString material;
    // A component of an assembly (KompasMetaInfo::assembly): its part's file, and
    // that part's own designation, author and organization.
    QString relativeSource;
    QString absoluteSource;
    std::optional<QString> designation;
    std::optional<QString> author;
    std::optional<QString> organization;
};

struct KompasMetaInfo {
    std::optional<QString> designation; // property 4
    QString name;                       // 5
    double massKg = 0;                  // 8
    QString material;                   // 9
    std::optional<QString> author;      // 11
    std::optional<QString> organization; // 12
    // An assembly's MetaInfo: object type 14 "Сборочная единица", and each body an
    // included component placing a part file.
    bool assembly = false;
    std::vector<KompasMetaInfoBody> bodies;
};

bool encodeKompasMetaInfo(const KompasMetaInfo& info, QByteArray& bytes, QString& error);

// /MetoInfoLinks: the body number of each MetaInfo component, in their order.
bool encodeKompasMetaInfoLinks(const std::vector<quint32>& bodyNumbers, QByteArray& bytes, QString& error);
bool decodeKompasMetaInfoLinks(const QByteArray& bytes, std::vector<quint32>& bodyNumbers, QString& error);

} // namespace cadnext::gui
