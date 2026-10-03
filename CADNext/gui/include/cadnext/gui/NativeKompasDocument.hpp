#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <cstddef>
#include <optional>
#include <vector>

namespace cadnext::gui {

// ZIP FileInfo member, UTF-16BE with a BOM and LF line endings. Application
// identity belongs to the authoring program; native format versions describe
// the serialized records, not the installed version of a vendor application.
struct KompasFileInfo {
    QString applicationName = QStringLiteral("CADNext");
    QString applicationVersion = QStringLiteral("CADNext_1.0");
    QString buildNumber = QStringLiteral("1");
    QString platform = QStringLiteral("x64");
    quint32 mathVersion = 0x11001001;
    quint32 applicationFileVersion = 0x11001011;
    QString fileTypeName = QStringLiteral("Kompas.m3d");
    quint32 fileType = 4; // 4: part, 6: assembly
    quint32 creationVersion = 0x11001011;
    // Native local-time strings are retained without assuming a timezone.
    QString createdAt;
    QString modifiedAt;
    std::optional<QString> author;
    std::optional<QString> organization;
    std::optional<QString> comment;
    bool autoSave = false;
};

bool decodeKompasFileInfo(const QByteArray& bytes, KompasFileInfo& info, QString& error);
bool encodeKompasFileInfo(const KompasFileInfo& info, QByteArray& bytes, QString& error);

struct KompasDocumentStyle {
    QString name;
    quint32 color = 0x808080;
    std::array<quint8, 6> material{80, 80, 40, 20, 100, 50};
    // Native state fields; their roles are not inferred from the style's name.
    std::array<bool, 2> nativeFlags{true, false};
};

// Complete /#100 record for the supported v17 default settings profile.
// Table positions identify native object styles; changing their order changes
// their meaning. The profile contains 220 slots, without explicit per-slot IDs.
// Other versions and non-default scalar/formatting profiles are rejected.
struct KompasDocumentSettings {
    static constexpr std::size_t styleCount = 220;
    QString title;
    bool assembly = false;
    std::vector<KompasDocumentStyle> styles;
};

bool decodeKompasDocumentSettings(const QByteArray& bytes,
                                  KompasDocumentSettings& settings, QString& error);
bool encodeKompasDocumentSettings(const KompasDocumentSettings& settings,
                                  QByteArray& bytes, QString& error);

struct KompasDocumentFileLink {
    // Zero is a valid native file-link object ID. It is not a null reference.
    quint16 objectId = 0;
    QString relativePath;
    QString absolutePath;
    // Required explicitly. Its derivation is outside this codec: no checksum
    // or revision semantics are inferred from a stored 32-bit native field.
    std::optional<quint32> nativeMark;
};

// Complete /#170/_DC_D/_DE_F list of newly defined file-link objects (0x4821).
// Aliases and other native object layouts require a separate verified codec.
bool decodeKompasDocumentFileLinks(const QByteArray& bytes,
                                   std::vector<KompasDocumentFileLink>& links, QString& error);
bool encodeKompasDocumentFileLinks(const std::vector<KompasDocumentFileLink>& links,
                                   QByteArray& bytes, QString& error);

} // namespace cadnext::gui
