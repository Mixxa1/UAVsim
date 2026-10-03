#pragma once

#include "cadnext/kernel/OcctKernel.hpp"

#include <QByteArray>
#include <QDateTime>
#include <QList>
#include <QString>
#include <QStringList>

#include <array>
#include <vector>

namespace cadnext::gui {

// A SOLIDWORKS assembly (.SLDASM, 2015+ container) of parts with imported bodies, laid out as
// SOLIDWORKS 2022 lays out an assembly it made from a STEP file: every component a part of its own
// with its body already where it belongs, every placement the identity, no mates. The parts are
// written next to the assembly (writeSolidWorksImportedPart).
//
// How it is built. The three such assemblies of the samples (sw-assemblies/step-made: 2, 5 and 7
// components) were cut, stream by stream, into what comes before the components, each component's
// block and what comes after; what they share is SOLIDWORKS's, what differs is a slot — names and
// paths, times, integers linear in the number of components and the component's index, the parts'
// boxes, the assembly's sphere and box, the document's GUID. The blueprint
// (NativeSolidWorksAssemblyBlueprint.cpp, generated) holds the binary streams; Header2 is built
// with the document header codec, the component tree and keywords as XML.
//
// Limits, all stated in the README:
//   - No SOLIDWORKS has opened a document written here.
//   - The container's signatures are those of one sample (NativeSolidWorksPackage.hpp).
//   - Contents/3DExperienceExchange2 is not written (as for the part).
//   - The assembly's bounding sphere is that of the parts' spheres merged in tree order; SOLIDWORKS's
//     own is tighter in one sample of three (52.57 mm against 52.71 mm).
//   - Fields of unknown meaning hold one sample's value (19 small fields; the save history's as 0).

struct SolidWorksAssemblyPartValues {
    QString name;                              // the part's title; its file is <name>.SLDPRT beside the assembly
    std::array<double, 3> boxMin{}, boxMax{};  // its body's box, metres (as its own Header2 holds it)
};

struct SolidWorksAssemblyValues {
    QString title;                             // the assembly's name
    QString folder = QStringLiteral("C:\\CADNext");
    QString author = QStringLiteral("CADNext");
    QString configuration = QStringLiteral("Default");
    quint32 saved = 0;                         // Unix time of every save and creation stamp
    quint64 filetime = 0;                      // the same as a FILETIME
    std::array<quint8, 16> guid{};             // the document's
    std::vector<SolidWorksAssemblyPartValues> parts;   // in tree order
};

// What Header2 (and Contents/Config-0-ModelHeader, the same bytes) of such an assembly holds. The
// writer fills it from the values; the test fills it from a sample's own header, so that one header
// built here is checked against SOLIDWORKS's byte for byte.
struct SolidWorksAssemblyHeaderFields {
    struct Component {
        QString log;                 // the component's feature log name ("<name>-1")
        QString path, title;         // its part's file and title
        quint32 modifiedAt = 0, referenceTime = 0;
    };
    QString author;
    QStringList features;            // the 23 standing feature logs (ids 0, 2–23), in order
    quint32 templateTime = 0;        // the creation of the first 17 logs and of the document
    quint32 importTime = 0;          // the creation of the others and the counters' time
    QString path, title, source, configuration;
    quint32 modifiedAt = 0, referenceTime = 0;
    std::vector<Component> components;
    std::array<double, 10> bounds{};
};

// The English names of the standing feature logs, as an English SOLIDWORKS assembly has them.
QStringList solidWorksAssemblyFeatureNames();
// The header's fields for `values` (every time the saved one, the paths beside each other).
SolidWorksAssemblyHeaderFields solidWorksAssemblyHeaderFields(const SolidWorksAssemblyValues& values);
bool encodeSolidWorksAssemblyHeader(const SolidWorksAssemblyHeaderFields& fields, QByteArray& bytes, QString& error);

// swXmlContents/COMPINSTANCETREE: the files, their models (each with its box) and the components,
// every placement the identity. Built from these fields; the test fills them from the samples.
struct SolidWorksAssemblyTreeFields {
    struct Part {
        QString name;                  // the component's name (swName, swComponentName)
        QString path;                  // its part's file
        quint32 created = 0;
        std::array<double, 6> box{};   // min x y z, max x y z (metres)
    };
    QString modelName, importedName;   // every model's swName and swImportedName
    QString path, source, configuration, displayState;
    quint32 created = 0;
    std::array<double, 6> box{};       // the parts' boxes together
    std::vector<Part> parts;
};
SolidWorksAssemblyTreeFields solidWorksAssemblyTreeFields(const SolidWorksAssemblyValues& values);
QByteArray encodeSolidWorksAssemblyTree(const SolidWorksAssemblyTreeFields& fields);

// swXmlContents/KeyWords: the byte 0x86, then the feature tree's names as XML.
struct SolidWorksAssemblyKeyWordsFields {
    struct Item {
        QString element;               // Feature, Reference, Sketch
        quint32 id = 0;
        QString name, description, type;
    };
    quint32 created = 0;
    QString name, configuration;
    std::vector<Item> items;           // written grouped by element, by id as text, as SOLIDWORKS does
};
SolidWorksAssemblyKeyWordsFields solidWorksAssemblyKeyWordsFields(const SolidWorksAssemblyValues& values);
QByteArray encodeSolidWorksAssemblyKeyWords(const SolidWorksAssemblyKeyWordsFields& fields);

// docProps/ISolidWorksInformation.xml, in English: SOLIDWORKS 2022's properties (ids 1, 3–19, as the
// samples have them) under the English names the samples' own dictionary gives, the dictionary as
// the English NIST assembly writes it (each name, and each with its alias).
QByteArray encodeSolidWorksAssemblyInformation(const SolidWorksAssemblyValues& values);

// The names of the streams the blueprint describes (binary ones; Header2 and the XML streams are
// built separately).
QList<QByteArray> solidWorksAssemblyBlueprintStreams();

// The assembly's sphere and box as SOLIDWORKS stores them: sphere centre, box max, box min, sphere
// radius (metres) — the box the parts' boxes together, the sphere their spheres merged in order.
std::array<double, 10> solidWorksAssemblyBlock(const SolidWorksAssemblyValues& values);

// A blueprint stream filled with `values`.
bool encodeSolidWorksAssemblyStream(const QByteArray& name, const SolidWorksAssemblyValues& values,
                                    QByteArray& bytes, QString& error);

// The same stream of a document of `components` components checked against the blueprint: false when
// it differs outside the slots (literal bytes and strings, the linear integers) or its sections do
// not add up to the stream.
bool matchSolidWorksAssemblyStream(const QByteArray& name, const QByteArray& bytes, std::size_t components,
                                   QString& error);

struct SolidWorksAssemblyWriteOptions {
    QString title;        // the assembly's name; empty: the file's base name
    QString author = QStringLiteral("CADNext");
    QDateTime saved;      // invalid: now
    QString folder = QStringLiteral("C:\\CADNext"); // the Windows folder the documents say they were saved in
};

struct SolidWorksAssemblyBody {
    QString name;                 // the component's name; the part is written as <name>.SLDPRT beside the assembly
    kernel::ShapeHandle shape;    // one solid, already where it belongs in the assembly
};

// Writes every body as a part (writeSolidWorksImportedPart) beside `path` and the assembly placing them
// all at the identity. Names that are not valid file names are made so, repeated ones numbered. At least
// two bodies (one is a part). The assembly is replaced only after its package was read back and every
// blueprint stream checked against the blueprint; parts written before a failure stay.
bool writeSolidWorksImportedAssembly(kernel::OcctKernel& kernel, const std::vector<SolidWorksAssemblyBody>& bodies,
                                     const QString& path, QString& error, const SolidWorksAssemblyWriteOptions& options = {});

} // namespace cadnext::gui
