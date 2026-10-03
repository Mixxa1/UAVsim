#pragma once

#include "cadnext/gui/NativeKompasStorage.hpp"
#include "cadnext/gui/NativeKompasDocument.hpp"

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QtGlobal>
#include <array>
#include <vector>

namespace cadnext::gui {

struct FreeCadShape {
    QString name;
    QByteArray brep;
    bool binary = false;
};

// Reads the cached exact shapes in a FreeCAD document. History is not replayed.
bool readFreeCadShapes(const QString& path, std::vector<FreeCadShape>& shapes,
                       QString& error);

// Writes visible exact bodies as a FreeCAD document with independent
// Part::Feature objects. The BRep coordinates must already be millimetres.
bool writeFreeCadShapes(const QString& path, const std::vector<FreeCadShape>& shapes,
                        QString& error);

struct KompasModelInfo {
    QString name;
    QStringList objects;
    QStringList externalFiles;
    quint32 compressedRecords = 0;
    quint64 decodedRecordBytes = 0;
    quint64 undecodedContentBytes = 0;
};

// Inspects the ZIP-based KOMPAS-3D document and its MetaInfo hierarchy.
// Exact C3D geometry in Contents is not decoded by this function.
bool readKompasModelInfo(const QString& path, KompasModelInfo& info, QString& error);

// Extracts the exact Contents member from a modern ZIP-based KOMPAS document.
// The caller owns the following C3D record decoding step.
bool readKompasContents(const QString& path, QByteArray& contents, QString& error);

// Extracts one named member (MetaInfo, FileInfo, Preview...) of a modern ZIP-based
// KOMPAS document exactly as stored.
bool readKompasArchiveMember(const QString& path, const QString& member, QByteArray& bytes, QString& error);

// Reads both physical storage members of a modern KOMPAS archive and validates
// the supported cluster index. Newer application versions are left to their
// dedicated storage codec; this endpoint is for the image emitted by the
// native writer above.
bool readKompasStorageImage(const QString& path, KompasStorageImage& image,
                            QString& error);

// Reads and validates the native archive's FileInfo version/type declaration.
bool readKompasFileInfo(const QString& path, KompasFileInfo& info, QString& error);

struct SolidWorksAssemblyComponent {
    QString name;
    QString sourcePath;
    QString configuration;
    std::array<double, 16> transform{};
    bool virtualComponent = false;
};

// The component tree of a modern SOLIDWORKS assembly (swXmlContents/COMPINSTANCETREE, XML), found
// by its local record.
bool readSolidWorksAssemblyManifest(const QString& path, QByteArray& manifest, QString& error);

// Reads component instances and transforms from a modern SOLIDWORKS assembly.
// This does not decode exact part geometry.
bool readSolidWorksAssemblyComponents(const QString& path,
                                      std::vector<SolidWorksAssemblyComponent>& components,
                                      QString& error);

// Lists distinct external files needed by the assembly.
bool readSolidWorksAssemblyReferences(const QString& path, QStringList& paths,
                                      QString& error);

struct SolidWorksBodyStream {
    QString configuration;
    QString configurationName; // display name from CMgrHdr2, empty if the metadata is absent
    QString kind;
    QString schemaKey;
    quint16 maxNodeType = 0;
    quint32 userFieldSize = 0;
    quint16 rootNodeType = 0;
    qsizetype nodeDataOffset = 0;
    quint32 rootNodeIndex = 0;
    quint32 firstBodyNodeIndex = 0;
    quint16 nextNodeType = 0;
    qsizetype firstBodyNodeOffset = 0;
    quint8 firstBodyKind = 0;
    quint32 firstShellNodeIndex = 0;
    quint32 firstRegionNodeIndex = 0;
    QByteArray parasolid;
};

struct SolidWorksConfiguration {
    QString id; // the N in Contents/Config-N-Partition
    QString name;
};

// Configurations with a saved exact geometry partition. Selecting an uncached
// configuration would require replaying the original application's features.
bool readSolidWorksPartConfigurations(const QString& path,
                                     std::vector<SolidWorksConfiguration>& configurations,
                                     QString& error);

// Extracts exact native Parasolid streams from supported modern and CFB parts.
// A partition is the saved current state; following deltas are rollback history,
// not geometry updates to be applied to that state.
bool readSolidWorksPartBodyStreams(const QString& path,
                                   std::vector<SolidWorksBodyStream>& streams,
                                   QString& error);

// Explains which native-format data CADNext can currently inspect and which
// exact-geometry data is still unavailable to the in-house importer.
QString nativeCadImportDiagnostic(const QString& sourcePath);

} // namespace cadnext::gui
