#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <vector>

namespace cadnext::gui {

// The container of SOLIDWORKS 2015 and later documents (.SLDPRT, .SLDASM, .SLDDRW), read from the
// nineteen documents of the samples (SOLIDWORKS 2015, 2020, 2022, 2023): a ZIP archive in disguise.
//
//   - Eight bytes first: four that differ in every file, then 00 00 00 and the shift (4).
//   - A local record: a four-byte signature, 14 00 06 00 08 00 (version 20, flags 6, deflate), a
//     32-bit stamp, CRC-32, packed and unpacked sizes, the name's length as 32 bits, the name with
//     every byte rotated right by the shift, the data (raw deflate; zlib level 1 gives SOLIDWORKS's
//     own bytes back).
//   - The directory: entries as a ZIP's (their signature another, "version made by" 0, the internal
//     attribute 1 where zlib took the data for text), offsets counted from byte 8.
//   - The end record: a third signature, 0, the count twice, the directory's size and offset
//     (from byte 8), 0.
//
// Between and after these SOLIDWORKS scatters decoys: records, directory entries and end records
// with signatures of their own and made-up sizes, and random bytes. The reader here finds the one
// end record whose directory ends where it starts and whose entries lead to records that inflate
// to their CRC.
//
// ⚠️ The three signatures differ from file to file, together with the first four bytes; the rule
// that ties them is not known (not a rotation, sum, CRC, common hash or generator of those bytes).
// A package written here carries four values seen together in one sample.
struct SolidWorksPackageEntry {
    QByteArray name;                 // "Contents/Config-0", "docProps/app.xml", …
    QByteArray data;                 // unpacked
    quint32 stamp = 0x7FEE3FDF;      // as in most records of the SOLIDWORKS 2020–2023 samples; meaning not known
    bool text = false;               // the directory's internal attribute
    bool operator==(const SolidWorksPackageEntry&) const = default;
};

struct SolidWorksPackage {
    // The first four bytes and the signatures that came with them (SOLIDWORKS 2022 sample
    // 2022_10_06_17_04_49_0724.stp.SLDPRT).
    std::array<quint8, 4> key{0x28, 0x17, 0x13, 0xF6};
    std::array<quint8, 4> localSignature{0x4D, 0xAD, 0x75, 0x35};
    std::array<quint8, 4> directorySignature{0x95, 0x70, 0xD5, 0x03};
    std::array<quint8, 4> endSignature{0x2F, 0x42, 0x5C, 0xB5};
    std::vector<SolidWorksPackageEntry> entries; // in the directory's order
};

// Where a decoded package's records sit in its file, for tests.
struct SolidWorksPackageLayout {
    std::vector<qint64> records;     // each entry's local record
    qint64 directory = 0;
    qint64 directoryEnd = 0;         // where its real entries end (decoy entries may follow)
    qint64 endRecord = 0;
};

// Outputs are cleared on failure. Limits: 512 MiB a file, 256 MiB an entry, 65535 entries.
bool decodeSolidWorksPackage(const QByteArray& file, SolidWorksPackage& package, QString& error,
                             SolidWorksPackageLayout* layout = nullptr);
// The eight bytes, the records one after another, the directory, the end record: no decoys.
bool encodeSolidWorksPackage(const SolidWorksPackage& package, QByteArray& file, QString& error);

// One local record or directory entry as encodeSolidWorksPackage writes it (`offset`: of the
// record, from byte 8, for a directory entry).
QByteArray encodeSolidWorksPackageRecord(const SolidWorksPackage& package, const SolidWorksPackageEntry& entry,
                                         bool* text = nullptr);
QByteArray encodeSolidWorksPackageDirectoryEntry(const SolidWorksPackage& package, const SolidWorksPackageEntry& entry,
                                                 quint32 offset);

} // namespace cadnext::gui
