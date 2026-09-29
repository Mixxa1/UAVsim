#pragma once

#include "cadnext/Sketch.hpp"

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QtGlobal>

#include <array>
#include <map>
#include <vector>

namespace cadnext::gui {

// DWG objects read from their bit streams, after the Open Design Specification for .dwg files:
// R13–R2000 (AC1012, AC1014, AC1015) from their own sections, AutoCAD 2013–2018 (AC1027, AC1032) from the
// sections NativeDwgImport extracts. What is decoded of an object: its type, handle, space and owner; the
// ACIS body of 3DSOLID, REGION and BODY (R13–R2000: SAT text, decrypted); plane geometry (LINE, CIRCLE,
// ARC, ELLIPSE, LWPOLYLINE); INSERT and block headers. Everything else is listed by type only.
struct DwgClass {
    int number = 0;       // the object type objects of this class carry
    QString dxfName;      // "LWPOLYLINE", "ACAD_PROXY_ENTITY", …
    QString cplusplus;
    bool entity = false;  // item class id 0x1F2 (else 0x1F3: an object)
    int objects = -1;     // how many objects of the class the file holds, where it says (2004 on)
};

struct DwgObject {
    quint64 handle = 0;
    quint32 offset = 0;   // in the file
    int type = 0;
    bool entity = false;
    // An entity's space: 0 inside a block (its owner is that block's header), 1 paper space, 2 model space.
    int entityMode = -1;
    quint64 owner = 0;
    QByteArray acis;      // a solid's SAT text (decrypted), where it has one
};

// An INSERT: the block it places and how. A point p of the block lands at
// insertion + E·Rz(rotation)·S·(p − base), E the arbitrary-axis frame of the extrusion direction.
struct DwgInsert {
    quint64 handle = 0;
    quint64 owner = 0;    // the block holding the INSERT, 0 in model or paper space
    int entityMode = -1;
    quint64 block = 0;    // the placed block's header
    double point[3] = {0, 0, 0};
    double scale[3] = {1, 1, 1};
    double rotation = 0;  // radians
    double extrusion[3] = {0, 0, 1};
};

struct DwgBlock {
    quint64 handle = 0;   // the block header's
    int owned = -1;       // entities it owns, where the file says (2004 on)
    QString name;
    double base[3] = {0, 0, 0};
    bool anonymous = false;
    bool xref = false;    // an external reference: its contents are in the file `xrefPath` names
    QString xrefPath;
};

// Plane geometry as the file holds it: LINE points in world coordinates; CIRCLE, ARC and LWPOLYLINE in
// the object coordinate system of `extrusion` (the arbitrary axis rule), at elevation `center[2]` (a
// polyline's `elevation`); ELLIPSE centre and major axis in world coordinates. Angles in radians.
struct DwgPlanar {
    enum class Kind { Line, Circle, Arc, Ellipse, Polyline } kind = Kind::Line;
    quint64 handle = 0;
    quint64 owner = 0;
    int entityMode = -1;
    double start[3] = {0, 0, 0}, end[3] = {0, 0, 0};    // Line
    double center[3] = {0, 0, 0};                        // Circle, Arc, Ellipse
    double radius = 0;
    double startAngle = 0, endAngle = 0;                 // Arc; Ellipse: its parameters
    double majorAxis[3] = {0, 0, 0};                     // Ellipse
    double ratio = 1;                                    // Ellipse: minor / major
    std::vector<std::array<double, 2>> points;           // Polyline
    std::vector<double> bulges;                          // Polyline: per vertex, 0 where none
    bool closed = false;                                 // Polyline
    double elevation = 0;                                // Polyline
    bool widths = false;                                 // Polyline: a constant or per-vertex width
    double thickness = 0;
    double extrusion[3] = {0, 0, 1};
};

// The header variables read here (R2000 and later: earlier versions have no INSUNITS).
struct DwgHeader {
    bool read = false;
    int insunits = -1;    // 0 unitless, 1 inches, 2 feet, 4 millimetres, 5 centimetres, 6 metres, …
    double extentsMin[3] = {0, 0, 0};
    double extentsMax[3] = {0, 0, 0};
};

struct DwgFile {
    QString version;      // AC1015, AC1032, …
    std::vector<DwgClass> classes;
    DwgHeader header;
    std::vector<DwgObject> objects; // in handle order
    std::vector<DwgInsert> inserts;
    std::vector<DwgBlock> blocks;
    std::vector<DwgPlanar> planar;
    // Plane entities, inserts and block headers whose data did not end where the file says it does
    // (the handles' start, R2000; the string stream's, 2007 on): each misread, left out.
    int misread = 0;
    std::vector<QString> insertNames; // DXF: the block each insert names, upper case
    QStringList notes;                // what the reader left out
};
using DwgR2000File = DwgFile;

// Millimetres per drawing unit for an INSUNITS value, 0 for unitless or a value not known here.
double dwgMillimetresPerUnit(int insunits);

// The name of an object type: a fixed one ("3DSOLID", "INSERT", …) or the class's DXF name.
QString dwgTypeName(const DwgR2000File& file, int type);

bool readDwgR2000(const QString& path, DwgFile& file, QString& error);

// AutoCAD 2013–2018 (AC1027, AC1032): the same, from the file's decompressed sections. Its solids' ACIS
// data lives apart (binary, in the AcDs section) and is not read: `notes` says how many were left.
bool readDwgR2013(const QString& path, DwgFile& file, QString& error);

// Either reader, by the file's version; the reason when neither applies.
bool readDwgFile(const QString& path, DwgFile& file, QString& error);

// A DXF's blocks, inserts and ACIS entities (3DSOLID, BODY, REGION: their SAT text, the groups 1 and 3
// joined and decrypted as in DWG) in the same shape, for the same walk: handles are the DXF's where it
// writes them, blocks numbered past them. DXF 2013 on keeps the bodies binary elsewhere: said so.
bool readDxfObjects(const QString& path, DwgR2000File& file, QString& error);

// Whether a DXF holds solids (3DSOLID or BODY entities) — read as bodies then, not as a sketch.
bool dxfHasAcisBodies(const QString& path);

// A solid of the drawing's model as it shows: an ACIS body in model space, or in a block model space
// inserts — nested inserts and external references (other DWG files, looked for by name next to the
// drawing) followed. Bodies of blocks nothing inserts (a Mechanical Desktop assembly's tool bodies,
// already combined into others) are not; `notes` counts them.
struct DwgModelBody {
    QString name;        // the named block it came through, else the drawing's name; numbered when repeated
    QByteArray acis;
    // Of the file the body is in: from its INSUNITS, or inherited from the drawing inserting it where
    // that says nothing (AutoCAD does not scale a unitless reference); 0 where no file on the way says.
    double millimetresPerUnit = 0.0;
    // Where the body lands, column-major: from the body built in metres (at `millimetresPerUnit`, or
    // at a millimetre a unit where that is 0) to the top drawing's model space in metres. Rigid.
    std::array<double, 16> placement{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
};

// Plane geometry of the model, through the same blocks and references as the bodies: `placement` takes
// the entity's coordinates, in its file's units turned to metres (`millimetresPerUnit`, a millimetre
// where 0), to the model in metres. Inserts may scale and mirror here: what that does to a circle is
// the sketch's to judge.
struct DwgModelPlanar {
    DwgPlanar entity;
    double millimetresPerUnit = 0.0;
    std::array<double, 16> placement{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
};

struct DwgModel {
    QString version;
    std::vector<DwgModelBody> bodies;
    std::vector<DwgModelPlanar> planar;
    // Entities of the model the import does not take, by type: annotation, hatches, ellipses and splines
    // a sketch cannot hold yet, …; and those of the layouts (paper space).
    std::map<QString, int> otherEntities;
    int paperSpaceEntities = 0;
    QStringList notes;   // what was left out, and why
};

// `path`: a .dwg (R13–R2000, 2013–2018) or a .dxf; references are followed into either.
bool readDwgModel(const QString& path, DwgModel& model, QString& error);

// The model's plane geometry as sketch lines, circles and arcs in the XY plane, in metres (the model's
// units). What cannot become one is counted in `left` by reason: off the XY plane (beyond 1e-9 of a
// drawing unit), with a thickness or a width, a circle an insert turns into an ellipse, an ellipse.
void dwgSketchEntities(const DwgModel& model, std::vector<SketchEntity>& entities, std::map<QString, int>& left);

} // namespace cadnext::gui
