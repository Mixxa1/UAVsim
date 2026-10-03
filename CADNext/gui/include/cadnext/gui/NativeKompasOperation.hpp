#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <map>
#include <vector>

namespace cadnext::gui {

// Application and math IDs are different namespaces. This is the supported
// v17 imported-operation envelope (native class 0x2801), not a whole model.
// The prefix precedes shellCount math shell pointers; the suffix follows them.
// The document writer must supply those shells and the surrounding controllers.
struct KompasImportedOperationPrefix {
    quint16 objectId = 0;
    quint8 nativeType = 9;
    quint32 mainName = 0;
    QString title;
    QString variableName;
    QString exclusionPrompt;
    quint32 applicationName = 0;
    quint32 bodyNumber = 0;
    quint32 color = 0x00909090;
    std::array<quint8, 6> material{50, 60, 80, 80, 100, 50};
    // Native frame link and placement, retained as typed fields. The exact
    // ownership semantics of the frame link still belong to the model codec.
    quint32 frameName = 0;
    std::array<double, 12> placement{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
    quint64 shellCount = 1;
};

struct KompasOperationAttribute {
    // Native classes 0x6217, 0x0165 and 0x387f. Preserve the latter two
    // payloads without assigning unverified application semantics.
    enum Kind { Color, Boolean, Strings } kind = Color;
    quint32 color = 0x00909090;
    bool boolean = true;
    std::array<QString, 3> strings;
};

struct KompasImportedOperationSuffix {
    std::array<quint8, 3> nativeFlags{1, 0, 1};
    // Attribute order is significant for an exact rewrite; no opaque payloads.
    std::vector<KompasOperationAttribute> attributes;
    quint32 bodyNumber = 0;
};

// Outputs are cleared on failure. Decoding reports only the envelope extent,
// leaving the math shells / next controller / model footer to the caller.
// Unsupported versioned layouts, attribute classes and reserved fields fail.
bool decodeKompasImportedOperationPrefix(const QByteArray& bytes, qsizetype offset,
                                        KompasImportedOperationPrefix& prefix,
                                        qsizetype& consumed, QString& error);
bool encodeKompasImportedOperationPrefix(const KompasImportedOperationPrefix& prefix,
                                        QByteArray& bytes, QString& error);
bool decodeKompasImportedOperationSuffix(const QByteArray& bytes, qsizetype offset,
                                        KompasImportedOperationSuffix& suffix,
                                        qsizetype& consumed, QString& error);
bool encodeKompasImportedOperationSuffix(const KompasImportedOperationSuffix& suffix,
                                        QByteArray& bytes, QString& error);

struct KompasDatum {
    enum Kind { Plane, Axis, Origin } kind = Plane;
    quint16 objectId = 0;
    quint8 nativeType = 9;
    quint32 mainName = 0;
    quint32 nativeName = 0;
    QString title;
    QString variableName;
    QString exclusionPrompt;
    quint32 color = 0x00909090;
    // Native coordinates are millimetres; axes are unit vectors.
    std::array<double, 12> placement{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
    std::array<double, 6> planeBox{1e300, 1e300, 1e300, -1e300, -1e300, -1e300};
    std::array<double, 4> planeBounds{-25, 25, -25, 25};
    // The supported origin names its three existing planes and three axes.
    std::vector<quint16> datumIds;
};

// Typed v17 default-datum controllers. The supplied registry contains prior
// definitions; an origin's references must resolve to the appropriate kinds.
// The caller adds the successfully encoded/decoded controller to the registry.
bool decodeKompasDatum(const QByteArray& bytes, qsizetype offset,
                       const std::map<quint16, quint16>& registry,
                       KompasDatum& datum, qsizetype& consumed, QString& error);
bool encodeKompasDatum(const KompasDatum& datum,
                       const std::map<quint16, quint16>& registry,
                       QByteArray& bytes, QString& error);

} // namespace cadnext::gui
