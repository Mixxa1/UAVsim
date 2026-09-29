#include "cadnext/gui/NativeDwgImport.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <algorithm>
#include <cassert>

namespace {

QString fixturePath() {
    const QString override = qEnvironmentVariable("CADNEXT_TEST_DWG_FILE");
    if (!override.isEmpty())
        return override;
    const QFileInfo source(QString::fromLocal8Bit(__FILE__));
    return source.dir().absoluteFilePath(
        QStringLiteral("../build-gui-occt/format-audit/sample_AC1032.dwg"));
}

const cadnext::gui::DwgSectionInfo& section(const cadnext::gui::DwgStructure& value,
                                            const QString& name) {
    const auto found = std::find_if(value.sections.begin(), value.sections.end(),
                                    [&](const cadnext::gui::DwgSectionInfo& item) {
                                        return item.name == name;
                                    });
    assert(found != value.sections.end());
    return *found;
}

QString writeFixture(const QTemporaryDir& temporary, const QByteArray& data) {
    const QString path = temporary.filePath(QStringLiteral("probe.dwg"));
    QFile out(path);
    assert(out.open(QIODevice::WriteOnly | QIODevice::Truncate));
    assert(out.write(data) == data.size());
    return path;
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString fixture = fixturePath();
    assert(QFileInfo::exists(fixture));

    cadnext::gui::DwgStructure structure;
    QString error;
    assert(cadnext::gui::readDwgStructure(fixture, structure, error));
    assert(structure.version == QStringLiteral("AC1032"));
    assert(structure.fileSize == quint64(QFileInfo(fixture).size()));
    assert(structure.securityFlags == 0);
    assert(structure.pageMapPageId == 58);
    assert(structure.sectionMapPageId == 57);
    assert(structure.pages.size() == 56);
    assert(structure.sections.size() == 14);

    const auto& objects = section(structure, QStringLiteral("AcDb:AcDbObjects"));
    assert(objects.logicalSize == 1192851);
    assert(objects.pages.size() == 41);
    assert(objects.compression == 2 && objects.encryption == 0);
    const auto& handles = section(structure, QStringLiteral("AcDb:Handles"));
    assert(handles.logicalSize == 2642);
    assert(handles.pages.size() == 1);

    QByteArray objectBytes;
    assert(cadnext::gui::readDwgSection(fixture, structure, objects.name, objectBytes, error));
    assert(objectBytes.size() == 1192851);
    QByteArray handleBytes;
    assert(cadnext::gui::readDwgSection(fixture, structure, handles.name, handleBytes, error));
    assert(handleBytes.size() == 2642);
    assert(objectBytes != handleBytes);

    // All untrusted offsets and payloads must be validated before use.
    QFile original(fixture);
    assert(original.open(QIODevice::ReadOnly));
    const QByteArray complete = original.readAll();
    QTemporaryDir temporary;
    assert(temporary.isValid());
    QByteArray wrongSignature = complete;
    wrongSignature[0] = 'X';
    assert(!cadnext::gui::readDwgStructure(writeFixture(temporary, wrongSignature),
                                           structure, error));
    QByteArray corruptMap = complete;
    corruptMap[0x1080c0] = char(quint8(corruptMap.at(0x1080c0)) ^ 1);
    assert(!cadnext::gui::readDwgStructure(writeFixture(temporary, corruptMap),
                                           structure, error));
    assert(error.contains(QStringLiteral("checksum")));
    QByteArray corruptObjects = complete;
    corruptObjects[0x43e0] = char(quint8(corruptObjects.at(0x43e0)) ^ 1);
    assert(!cadnext::gui::readDwgStructure(writeFixture(temporary, corruptObjects),
                                           structure, error));
    assert(error.contains(QStringLiteral("checksum")));
}
