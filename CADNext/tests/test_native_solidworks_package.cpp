// The container of SOLIDWORKS 2015+ documents (NativeSolidWorksPackage) against the samples
// (CADNEXT_TEST_SAMPLES, ~/cadnext-samples by default): nist/NIST-MTC-Assembly/SolidWorks (SOLIDWORKS
// 2015: eight parts and an assembly) and sw-imported (SOLIDWORKS 2020, 2022, 2023: ten parts made by
// opening a STEP file). Every record and directory entry of every file must encode back to the
// file's own bytes — the deflated data too.

#include "cadnext/gui/NativeSolidWorksPackage.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>

#include <cstdio>
#include <string>

using namespace cadnext::gui;

namespace {
int failures = 0;
void check(bool ok, const std::string& what) {
    std::printf("%s: %s\n", ok ? "PASS" : "FAIL", what.c_str());
    failures += ok ? 0 : 1;
}
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples");
    QStringList files;
    for (const QString& folder : {root + "/nist/NIST-MTC-Assembly/SolidWorks", root + "/sw-imported"}) {
        QDirIterator it(folder, {"*.SLDPRT", "*.SLDASM"}, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) files << it.next();
    }
    files.sort();
    if (files.isEmpty()) {
        std::printf("SKIP: нет образцов SOLIDWORKS в %s\n", qPrintable(root));
    } else {
        int read = 0, recordsSame = 0, records = 0, directoriesSame = 0, textSame = 0, importedRecords = 0, importedTextSame = 0;
        for (const QString& path : files) {
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly)) continue;
            const QByteArray file = f.readAll();
            SolidWorksPackage package;
            SolidWorksPackageLayout layout;
            QString error;
            if (!decodeSolidWorksPackage(file, package, error, &layout)) {
                std::printf("  %s: %s\n", qPrintable(QFileInfo(path).fileName()), qPrintable(error));
                continue;
            }
            ++read;
            QByteArray directory;
            for (std::size_t i = 0; i < package.entries.size(); ++i) {
                bool text = false;
                const QByteArray record = encodeSolidWorksPackageRecord(package, package.entries[i], &text);
                ++records;
                recordsSame += !record.isEmpty() && file.mid(layout.records[i], record.size()) == record ? 1 : 0;
                const bool sameText = text == package.entries[i].text || package.entries[i].data.isEmpty();
                textSame += sameText ? 1 : 0;
                if (path.contains("/sw-imported/")) { ++importedRecords; importedTextSame += sameText ? 1 : 0; }
                directory += encodeSolidWorksPackageDirectoryEntry(package, package.entries[i], quint32(layout.records[i] - 8));
            }
            directoriesSame += directory == file.mid(layout.directory, layout.directoryEnd - layout.directory) ? 1 : 0;
        }
        check(read == files.size(), "пакеты прочитаны по своему каталогу: " + std::to_string(read) + " из " + std::to_string(files.size()));
        check(records > 0 && recordsSame == records, "записи потоков кодируются обратно байт в байт, со сжатыми данными: " +
                                                     std::to_string(recordsSame) + " из " + std::to_string(records));
        check(directoriesSame == read, "каталоги кодируются обратно байт в байт: " + std::to_string(directoriesSame) + " из " + std::to_string(read));
        // SOLIDWORKS 2015 marks a few binary streams (Preview, PreviewPNG, ThirdPtySTGStore) as text; in the
        // 2020–2023 documents the mark is zlib's own everywhere.
        check(importedTextSame == importedRecords, "признак текста в каталоге — тот, что даёт zlib, в документах SOLIDWORKS 2020–2023: " +
                                                   std::to_string(importedTextSame) + " из " + std::to_string(importedRecords) +
                                                   " (во всех образцах " + std::to_string(textSame) + " из " + std::to_string(records) + ")");
    }

    // Our own package: written, read back the same.
    SolidWorksPackage ours;
    ours.entries = {{"Contents/Definition", QByteArray(3000, 'x') + QByteArray::fromHex("00ff10"), 0x7FEE3FDF, false},
                    {"Contents/User Units Table", QByteArray(), 0x7FEE3FDF, false},
                    {"docProps/app.xml", "<?xml version=\"1.0\"?><Properties/>", 0x7FEE3FDF, true}};
    QByteArray file;
    QString error;
    SolidWorksPackage back;
    SolidWorksPackageLayout layout;
    const bool written = encodeSolidWorksPackage(ours, file, error);
    const bool same = written && decodeSolidWorksPackage(file, back, error, &layout) && back.entries == ours.entries && back.key == ours.key &&
                      back.localSignature == ours.localSignature && back.directorySignature == ours.directorySignature &&
                      back.endSignature == ours.endSignature && layout.records.front() == 8 && layout.endRecord + 22 == file.size();
    check(same, "наш пакет: записан без обманок и прочитан обратно тем же" + (error.isEmpty() ? std::string() : " — " + error.toStdString()));
    QByteArray broken = file;
    broken[40] = char(broken[40] ^ 0x55);
    check(written && !decodeSolidWorksPackage(broken, back, error) && back.entries.empty(), "испорченный поток отклонён, результат пуст");

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
