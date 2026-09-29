#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>

#include <map>

namespace cadnext::gui {

// The container of DWG 2007–2009 (AC1021), read as the Open Design Specification for .dwg files describes it
// (chapter 5): the file header at 0x80, Reed-Solomon (255, 239) encoded three times interleaved, its data
// compressed; the page map and the section map, system pages (RS (255, 239), interleaved, the data repeated
// "correction factor" times); the data pages, RS (255, 251), interleaved (encoding 4) or not (1), each
// compressed where it is shorter so. The compression is R21's LZ77 variant (5.10). No error correction:
// the codewords' data bytes are taken as they are.
//
// Each wanted section (all when `wanted` is empty) as its logical bytes, its pages placed at their offsets,
// zero where a page of zeroes was left out.
bool readDwgR2007Sections(const QString& path, std::map<QString, QByteArray>& sections, QString& error,
                          const QStringList& wanted = {});

} // namespace cadnext::gui
