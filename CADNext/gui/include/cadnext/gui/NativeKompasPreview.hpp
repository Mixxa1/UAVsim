#pragma once

#include "cadnext/gui/NativeKompasMesh.hpp"

#include <QByteArray>
#include <QString>

#include <vector>

namespace cadnext::gui {

// The Preview member of a KOMPAS document, as KOMPAS 17.1 writes it: "KF", two
// 32-bit sizes (152 and 163 with the 305 × 328 picture in 14 of the 21 v17 parts
// of the samples; their meaning is not known), the background colour, the length
// of the picture, the picture — a big-endian RGB TIFF, one LZW-compressed strip a
// row, its directory after the strips — then four texts: the designation, the
// name, the author and an empty one.
struct KompasPreviewImage {
    int width = 305;
    int height = 328;
    std::vector<quint8> rgb; // width × height × 3, rows top down
};

struct KompasPreview {
    quint32 sizeA = 152;
    quint32 sizeB = 163;
    quint32 background = 0x00ffffff;
    KompasPreviewImage image;
    QString designation;
    QString name;
    QString author;
    QString comment;
};

bool encodeKompasPreview(const KompasPreview& preview, QByteArray& bytes, QString& error);
bool decodeKompasPreview(const QByteArray& bytes, KompasPreview& preview, QString& error);

// A picture of the bodies' display meshes in KOMPAS 17.1's default view (/#140):
// shaded in `color`, their face boundaries in black, on white.
KompasPreviewImage renderKompasPreview(const std::vector<KompasMesh>& meshes, quint32 color, int width = 305, int height = 328);

} // namespace cadnext::gui
