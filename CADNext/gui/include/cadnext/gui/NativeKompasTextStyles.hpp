#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <vector>

namespace cadnext::gui {

// The text style table of a part document (/#250): KOMPAS 17.1's built-in
// styles, the same in all 21 v17 parts of the samples but for one flag. Each
// style: its name, four text levels, the font, a kind, a flag, and an
// extension of style-specific data — letter sets for axis and node marks,
// visibility lists written as text ("51 1 71 0 ..."), the XML template of the
// section line. The style-level fields are named; an extension, and the table's
// header, are kept as the typed values KOMPAS writes, their roles not decoded.
struct KompasTextLevel {
    bool first = false; // set on the first level only, in the defaults
    float height = 3.5f;
    float width = 3.5f;
    float factor = 1.0f;
    float step = 7.0f;
    quint32 language = 0x0419; // Russian
};

struct KompasStyleField {
    enum Kind : quint8 { Byte, Half, Word, Real, Zeros, Text } kind = Zeros;
    quint32 number = 0; // a Byte/Half/Word value, or the count of Zeros
    float real = 0;
    QString text;
};

struct KompasTextStyle {
    QString name;
    std::array<KompasTextLevel, 4> levels;
    QString font;
    quint32 kind = 8;
    bool flag = false;
    std::vector<KompasStyleField> extension;
};

struct KompasTextStyleTable {
    std::vector<KompasStyleField> header;
    std::vector<KompasTextStyle> styles;
};

KompasTextStyleTable kompasDefaultTextStyles();

// Outputs are reset on failure. A table is read with the default one as its
// layout: the same number of styles, each extension's fields of the same kinds
// (their values, and the names, levels, fonts, kinds and flags, as written).
bool encodeKompasTextStyles(const KompasTextStyleTable& table, QByteArray& bytes, QString& error);
bool decodeKompasTextStyles(const QByteArray& bytes, KompasTextStyleTable& table, QString& error);

} // namespace cadnext::gui
