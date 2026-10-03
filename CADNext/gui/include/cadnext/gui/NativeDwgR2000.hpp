#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <optional>
#include <utility>
#include <variant>
#include <vector>

namespace cadnext::gui {

// Codecs of the parts of an AutoCAD 2000 drawing (AC1015), after the Open Design Specification for .dwg
// files and checked against the eleven AutoCAD 2000 (Mechanical Desktop) drawings and the AutoCAD 2020
// one saved as 2000 of the samples (cadnext_test_native_dwg_writer): each part decodes and encodes back
// bit for bit, but for the bits AutoCAD pads with whatever its buffer held (classes, objects) and the
// eight junk bytes of the second file header. Decoders refuse data that does not end where the file
// says; outputs are cleared on failure.

// A handle reference: its code and value. Its length is the value's own (no leading zero bytes), as
// AutoCAD writes every reference of the samples.
struct DwgHandleRef {
    quint8 code = 0;
    quint64 value = 0;
    bool operator==(const DwgHandleRef&) const = default;
};

// The 16-bit CRC of DWG R13–R2000 sections and objects.
quint16 dwgCrc16(quint16 seed, const char* data, qsizetype size);

// The file header: version, the image seeker, codepage and the section locators. AutoCAD 2000
// writes six locators: header variables, classes, object map, the free-space table, the template,
// the auxiliary header.
struct DwgSectionLocator {
    quint8 number = 0;
    quint32 seeker = 0;
    quint32 size = 0;
    bool operator==(const DwgSectionLocator&) const = default;
};
struct DwgR2000FileHeader {
    quint8 maintenance = 6;
    quint8 byte0C = 1;
    quint32 imageSeeker = 0;
    quint8 applicationVersion = 0x17;     // 0x11–0x12: AutoCAD 2000 writes 0x17, 6
    quint8 applicationMaintenance = 6;
    quint16 codepage = 30;                // ANSI 1252
    std::vector<DwgSectionLocator> locators;
};
QByteArray encodeDwgR2000FileHeader(const DwgR2000FileHeader& header);
bool decodeDwgR2000FileHeader(const QByteArray& file, DwgR2000FileHeader& header, QString& error);

// The header variables (section locator 0), all of them in the file's order. The defaults are those of
// AutoCAD 2000's imperial template (acad.dwt): what all eleven AutoCAD 2000 drawings of the samples
// hold where they agree, AutoCAD's documented default where they do not (user settings: dimension
// sizes, chamfers, fillet radius).
struct DwgR2000HeaderVariables {
    double unk1 = 412148564080.0;
    double unk2 = 1.0;
    double unk3 = 1.0;
    double unk4 = 1.0;
    QByteArray unk5 = QByteArrayLiteral("m");
    QByteArray unk6;
    QByteArray unk7;
    QByteArray unk8;
    qint32 unk9 = 0;
    qint32 unk10 = 0;
    DwgHandleRef VIEWPORTENTHDR = {5, 0x0};
    bool DIMASO = true;
    bool DIMSHO = true;
    bool PLINEGEN = false;
    bool ORTHOMODE = false;
    bool REGENMODE = true;
    bool FILLMODE = true;
    bool QTEXTMODE = false;
    bool PSLTSCALE = true;
    bool LIMCHECK = false;
    bool USRTIMER = true;
    bool SKPOLY = false;
    bool ANGDIR = false;
    bool SPLFRAME = false;
    bool MIRRTEXT = true;
    bool WORLDVIEW = true;
    bool TILEMODE = true;
    bool PLIMCHECK = false;
    bool VISRETAIN = true;
    bool DISPSILH = false;
    bool PELLIPSE = false;
    int PROXYGRAPHICS = 1;
    int TREEDEPTH = 3020;
    int LUNITS = 2;
    int LUPREC = 4;
    int AUNITS = 0;
    int AUPREC = 0;
    int ATTMODE = 1;
    int PDMODE = 0;
    int USERI1 = 0;
    int USERI2 = 0;
    int USERI3 = 0;
    int USERI4 = 0;
    int USERI5 = 0;
    int SPLINESEGS = 8;
    int SURFU = 6;
    int SURFV = 6;
    int SURFTYPE = 6;
    int SURFTAB1 = 6;
    int SURFTAB2 = 6;
    int SPLINETYPE = 6;
    int SHADEDGE = 3;
    int SHADEDIF = 70;
    int UNITMODE = 0;
    int MAXACTVP = 64;
    int ISOLINES = 4;
    int CMLJUST = 0;
    int TEXTQLTY = 50;
    double LTSCALE = 1.0;
    double TEXTSIZE = 0.2;
    double TRACEWID = 0.05;
    double SKETCHINC = 0.1;
    double FILLETRAD = 0.5;
    double THICKNESS = 0.0;
    double ANGBASE = 0.0;
    double PDSIZE = 0.0;
    double PLINEWID = 0.0;
    double USERR1 = 0.0;
    double USERR2 = 0.0;
    double USERR3 = 0.0;
    double USERR4 = 0.0;
    double USERR5 = 0.0;
    double CHAMFERA = 0.5;
    double CHAMFERB = 0.5;
    double CHAMFERC = 1.0;
    double CHAMFERD = 0.0;
    double FACETRES = 0.5;
    double CMLSCALE = 1.0;
    double CELTSCALE = 1.0;
    QByteArray MENUNAME = QByteArrayLiteral(".");
    qint32 TDCREATED = 0;
    qint32 TDCREATEMS = 0;
    qint32 TDUPDATED = 0;
    qint32 TDUPDATEMS = 0;
    qint32 TDINDWGD = 0;
    qint32 TDINDWGMS = 0;
    qint32 TDUSRTIMERD = 0;
    qint32 TDUSRTIMERMS = 0;
    int CECOLOR = 256;
    DwgHandleRef HANDSEED = {0, 0x0};
    DwgHandleRef CLAYER = {5, 0x10};
    DwgHandleRef TEXTSTYLE = {5, 0x11};
    DwgHandleRef CELTYPE = {5, 0x15};
    DwgHandleRef DIMSTYLE = {5, 0x27};
    DwgHandleRef CMLSTYLE = {5, 0x18};
    double PSVPSCALE = 0.0;
    std::array<double, 3> PINSBASE = {0.0, 0.0, 0.0};
    std::array<double, 3> PEXTMIN = {1e+20, 1e+20, 1e+20};
    std::array<double, 3> PEXTMAX = {-1e+20, -1e+20, -1e+20};
    std::array<double, 2> PLIMMIN = {0.0, 0.0};
    std::array<double, 2> PLIMMAX = {12.0, 9.0};
    double PELEVATION = 0.0;
    std::array<double, 3> PUCSORG = {0.0, 0.0, 0.0};
    std::array<double, 3> PUCSXDIR = {1.0, 0.0, 0.0};
    std::array<double, 3> PUCSYDIR = {0.0, 1.0, 0.0};
    DwgHandleRef PUCSNAME = {5, 0x0};
    DwgHandleRef PUCSORTHOREF = {5, 0x0};
    int PUCSORTHOVIEW = 0;
    DwgHandleRef PUCSBASE = {5, 0x0};
    std::array<double, 3> PORGTOP = {0.0, 0.0, 0.0};
    std::array<double, 3> PORGBOTTOM = {0.0, 0.0, 0.0};
    std::array<double, 3> PORGLEFT = {0.0, 0.0, 0.0};
    std::array<double, 3> PORGRIGHT = {0.0, 0.0, 0.0};
    std::array<double, 3> PORGFRONT = {0.0, 0.0, 0.0};
    std::array<double, 3> PORGBACK = {0.0, 0.0, 0.0};
    std::array<double, 3> MINSBASE = {0.0, 0.0, 0.0};
    std::array<double, 3> MEXTMIN = {1e+20, 1e+20, 1e+20};
    std::array<double, 3> MEXTMAX = {-1e+20, -1e+20, -1e+20};
    std::array<double, 2> MLIMMIN = {0.0, 0.0};
    std::array<double, 2> MLIMMAX = {12.0, 9.0};
    double MELEVATION = 0.0;
    std::array<double, 3> MUCSORG = {0.0, 0.0, 0.0};
    std::array<double, 3> MUCSXDIR = {1.0, 0.0, 0.0};
    std::array<double, 3> MUCSYDIR = {0.0, 1.0, 0.0};
    DwgHandleRef MUCSNAME = {5, 0x0};
    DwgHandleRef MUCSORTHOREF = {5, 0x0};
    int MUCSORTHOVIEW = 0;
    DwgHandleRef MUCSBASE = {5, 0x0};
    std::array<double, 3> MORGTOP = {0.0, 0.0, 0.0};
    std::array<double, 3> MORGBOTTOM = {0.0, 0.0, 0.0};
    std::array<double, 3> MORGLEFT = {0.0, 0.0, 0.0};
    std::array<double, 3> MORGRIGHT = {0.0, 0.0, 0.0};
    std::array<double, 3> MORGFRONT = {0.0, 0.0, 0.0};
    std::array<double, 3> MORGBACK = {0.0, 0.0, 0.0};
    QByteArray DIMPOST;
    QByteArray DIMAPOST;
    double DIMSCALE = 1.0;
    double DIMASZ = 0.18;
    double DIMEXO = 0.0625;
    double DIMDLI = 0.38;
    double DIMEXE = 0.18;
    double DIMRND = 0.0;
    double DIMDLE = 0.0;
    double DIMTP = 0.0;
    double DIMTM = 0.0;
    bool DIMTOL = false;
    bool DIMLIM = false;
    bool DIMTIH = true;
    bool DIMTOH = true;
    bool DIMSE1 = false;
    bool DIMSE2 = false;
    int DIMTAD = 0;
    int DIMZIN = 0;
    int DIMAZIN = 0;
    double DIMTXT = 0.18;
    double DIMCEN = 0.09;
    double DIMTSZ = 0.0;
    double DIMALTF = 25.4;
    double DIMLFAC = 1.0;
    double DIMTVP = 0.0;
    double DIMTFAC = 1.0;
    double DIMGAP = 0.09;
    double DIMALTRND = 0.0;
    bool DIMALT = false;
    int DIMALTD = 2;
    bool DIMTOFL = false;
    bool DIMSAH = false;
    bool DIMTIX = false;
    bool DIMSOXD = false;
    int DIMCLRD = 0;
    int DIMCLRE = 0;
    int DIMCLRT = 0;
    int DIMADEC = 0;
    int DIMDEC = 4;
    int DIMTDEC = 4;
    int DIMALTU = 2;
    int DIMALTTD = 2;
    int DIMAUNIT = 0;
    int DIMFRAC = 0;
    int DIMLUNIT = 2;
    int DIMDSEP = 46;
    int DIMTMOVE = 0;
    int DIMJUST = 0;
    bool DIMSD1 = false;
    bool DIMSD2 = false;
    int DIMTOLJ = 1;
    int DIMTZIN = 0;
    int DIMALTZ = 0;
    int DIMALTTZ = 0;
    bool DIMUPT = false;
    int DIMATFIT = 3;
    DwgHandleRef DIMTXSTY = {5, 0x11};
    DwgHandleRef DIMLDRBLK = {5, 0x0};
    DwgHandleRef DIMBLK = {5, 0x0};
    DwgHandleRef DIMBLK1 = {5, 0x0};
    DwgHandleRef DIMBLK2 = {5, 0x0};
    int DIMLWD = -2;
    int DIMLWE = -2;
    DwgHandleRef BLOCKCONTROL = {3, 0x1};
    DwgHandleRef LAYERCONTROL = {3, 0x2};
    DwgHandleRef STYLECONTROL = {3, 0x3};
    DwgHandleRef LTYPECONTROL = {3, 0x5};
    DwgHandleRef VIEWCONTROL = {3, 0x6};
    DwgHandleRef UCSCONTROL = {3, 0x7};
    DwgHandleRef VPORTCONTROL = {3, 0x8};
    DwgHandleRef APPIDCONTROL = {3, 0x9};
    DwgHandleRef DIMSTYLECONTROL = {3, 0xa};
    DwgHandleRef VXCONTROL = {3, 0xb};
    DwgHandleRef DICTGROUP = {5, 0xd};
    DwgHandleRef DICTMLINESTYLE = {5, 0x17};
    DwgHandleRef DICTNAMED = {3, 0xc};
    int TSTACKALIGN = 1;
    int TSTACKSIZE = 70;
    QByteArray HYPERLINKBASE;
    QByteArray STYLESHEET;
    DwgHandleRef DICTLAYOUTS = {5, 0x1a};
    DwgHandleRef DICTPLOTSETTINGS = {5, 0x19};
    DwgHandleRef DICTPLOTSTYLES = {5, 0xe};
    qint32 FLAGS = 10781;
    int INSUNITS = 1;
    int CEPSNTYPE = 0;
    DwgHandleRef CPSNID = {5, 0x0};          // only when CEPSNTYPE is 3
    QByteArray FINGERPRINTGUID;
    QByteArray VERSIONGUID;
    DwgHandleRef BRPAPER = {5, 0x1b};
    DwgHandleRef BRMODEL = {5, 0x1f};
    DwgHandleRef LTBYLAYER = {5, 0x15};
    DwgHandleRef LTBYBLOCK = {5, 0x14};
    DwgHandleRef LTCONTINUOUS = {5, 0x16};
    // Four shorts after them, each written whole (a raw short after its 00 code) in all the samples;
    // their values look like what AutoCAD's buffer held.
    std::array<quint16, 4> trailing{};
};
// The whole section: its sentinel, size, the variables, CRC and end sentinel.
QByteArray encodeDwgR2000HeaderVariables(const DwgR2000HeaderVariables& variables);
bool decodeDwgR2000HeaderVariables(const QByteArray& file, quint32 seeker, DwgR2000HeaderVariables& variables,
                                   QString& error);

// The classes section (locator 1).
struct DwgClassRecord {
    int number = 500;
    int version = 0;
    QByteArray application;
    QByteArray cplusplus;
    QByteArray dxfName;
    bool zombie = false;
    int itemClassId = 0x1F3; // 0x1F2 for entities
    bool operator==(const DwgClassRecord&) const = default;
};
QByteArray encodeDwgR2000Classes(const std::vector<DwgClassRecord>& classes);
// `paddingBits`: how many bits after the last class the section's size leaves.
bool decodeDwgR2000Classes(const QByteArray& file, quint32 seeker, std::vector<DwgClassRecord>& classes,
                           QString& error, int* paddingBits = nullptr);

// The object map (locator 2): handles and file offsets, in runs as AutoCAD cuts them (a run closes
// once it reaches 2032 bytes with its size), each with its CRC, then the empty run.
QByteArray encodeDwgR2000ObjectMap(const std::vector<std::pair<quint64, quint32>>& offsets);
bool decodeDwgR2000ObjectMap(const QByteArray& file, quint32 seeker, quint32 size,
                             std::vector<std::pair<quint64, quint32>>& offsets, QString& error);

// The auxiliary file header (locator 5), 123 bytes, mostly what the other headers say again.
struct DwgR2000AuxHeader {
    quint16 version = 23;
    quint16 maintenance = 6;
    quint32 saves = 1;
    qint32 unknown = -1;       // AutoCAD 2000 writes a count here (90739 … 4034145); the spec says -1
    quint16 savesPart1 = 1;
    quint16 savesPart2 = 0;
    std::array<quint16, 4> versions{23, 6, 23, 6};
    std::array<quint16, 4> constants{4, 1381, 4, 1381};
    std::array<quint16, 2> constants2{0, 1};
    std::array<quint32, 2> created{};  // Julian day, milliseconds
    std::array<quint32, 2> updated{};
    quint32 handseed = 0;
    quint32 educational = 0;
    quint16 savesDifference = 1;
    quint32 savesAgain = 1;
};
QByteArray encodeDwgR2000AuxHeader(const DwgR2000AuxHeader& header);
bool decodeDwgR2000AuxHeader(const QByteArray& file, quint32 seeker, DwgR2000AuxHeader& header, QString& error);

// The free-space table (locator 3), 53 bytes.
struct DwgR2000FreeSpace {
    quint32 handles = 0;               // "approximate number of objects"
    std::array<quint32, 2> updated{};  // TDUPDATE
    quint32 objectsOffset = 0;
};
QByteArray encodeDwgR2000FreeSpace(const DwgR2000FreeSpace& freeSpace);
bool decodeDwgR2000FreeSpace(const QByteArray& file, quint32 seeker, DwgR2000FreeSpace& freeSpace, QString& error);

// The template (locator 4): an empty description and MEASUREMENT (0 English, 1 metric).
QByteArray encodeDwgR2000Template(quint16 measurement);

// The second file header, after the free space: the locators again (as of the last save but one,
// AutoCAD's own sometimes stale) and the handles of the control objects and dictionaries.
struct DwgR2000SecondHeader {
    quint32 location = 0;
    quint8 maintenance = 6;
    quint16 unknown12 = 0x5C;                            // 12 bits after the version: AutoCAD 2000's, all 11 files
    std::array<quint8, 4> magic{0x18, 0x78, 0x01, 0x06}; // AutoCAD 2020 writes 0x74 for the first
    std::array<DwgSectionLocator, 6> locators{};
    std::vector<std::pair<quint8, QByteArray>> handles; // index, the handle's bytes, most significant first
};
QByteArray encodeDwgR2000SecondHeader(const DwgR2000SecondHeader& header); // eight zero junk bytes
bool decodeDwgR2000SecondHeader(const QByteArray& file, quint32 location, DwgR2000SecondHeader& header,
                                QString& error);

// The preview (image seeker): an 80-byte header block and a Windows DIB (8 bits a pixel, 256 colours),
// as AutoCAD 2000 stores the picture of the drawing.
struct DwgR2000Preview {
    QByteArray header = QByteArray(80, '\0');
    QByteArray bitmap; // BITMAPINFOHEADER, palette, rows bottom up; empty: none
};
QByteArray encodeDwgR2000Preview(const DwgR2000Preview& preview, quint32 seeker);
bool decodeDwgR2000Preview(const QByteArray& file, quint32 seeker, DwgR2000Preview& preview, QString& error);
// An 8-bit DIB of an RGB picture (rows top down): its palette the picture's own colours, nearest
// where it has more than 256.
QByteArray dwgPreviewBitmap(int width, int height, const std::vector<quint8>& rgb);

// ---- objects ----

struct DwgEedItem {
    DwgHandleRef application;
    QByteArray data;
    bool operator==(const DwgEedItem&) const = default;
};

// What every object of the file holds before and after its own data.
struct DwgObjectFrame {
    int type = 0;
    quint64 handle = 0;
    std::vector<DwgEedItem> eed;
    bool entity = false;
    // An entity's common data.
    bool graphicPresent = false;
    QByteArray graphic;
    int entityMode = 2;          // 0 inside a block, 1 paper space, 2 model space
    bool noLinks = true;
    int color = 256;
    double linetypeScale = 1.0;
    int linetypeFlags = 0;
    int plotStyleFlags = 0;
    int invisibility = 0;
    int lineweight = 29;
    // The handle stream's common part.
    // Objects: the owner (a table's control, a dictionary's parent; the NULL of controls); entities
    // only inside a block. Then the reactors and the extension dictionary; for an entity its
    // previous and next entity (unless noLinks), layer, linetype and plot style (when their flags
    // are 3), in R2000's order.
    DwgHandleRef owner{4, 0};
    std::vector<DwgHandleRef> reactors;
    DwgHandleRef xdictionary{3, 0};
    DwgHandleRef previous{4, 0}, next{4, 0}, layer{5, 0}, linetype{5, 0}, plotStyle{5, 0};
};

struct DwgTableEntry {
    QByteArray name;
    bool flag64 = true;
    int xrefIndexPlusOne = 0;   // 0: not from an external reference
    bool xrefDependent = false;
    DwgHandleRef xrefBlock{5, 0};
};

// BLOCK_CONTROL, LAYER_CONTROL, … VX_CONTROL: the entries. The block and linetype tables keep two
// more, *Model_Space and *Paper_Space, ByLayer and ByBlock; the dimension style table a list of its own.
struct DwgControlData {
    qint32 entries = 0;
    std::vector<DwgHandleRef> handles;
    std::vector<DwgHandleRef> more;   // DIMSTYLE_CONTROL
};
struct DwgBlockHeaderData {
    DwgTableEntry entry;
    bool anonymous = false, hasAttributes = false, xref = false, overlaid = false, loaded = false;
    std::array<double, 3> base{};
    QByteArray xrefPath;
    std::vector<quint8> insertRun;    // non-zero counts, one a placing INSERT (the closing 0 is written)
    QByteArray description;
    QByteArray preview;
    DwgHandleRef block{3, 0}, first{4, 0}, last{4, 0}, endBlock{3, 0}, layout{5, 0}; // entry.xrefBlock: its NULL
    std::vector<DwgHandleRef> inserts;
};
struct DwgLayerData {
    DwgTableEntry entry;
    int values = 1008;
    int color = 7;
    DwgHandleRef plotStyle{5, 0}, linetype{5, 0};
};
struct DwgTextStyleData {
    DwgTableEntry entry;
    bool vertical = false, shapeFile = false;
    double height = 0.0, width = 1.0, oblique = 0.0;
    quint8 generation = 0;
    double lastHeight = 0.2;
    QByteArray font = QByteArrayLiteral("txt"), bigFont;
};
struct DwgLinetypeDash {
    double length = 0.0;
    int shapeCode = 0;
    double xOffset = 0.0, yOffset = 0.0, scale = 1.0, rotation = 0.0;
    int shapeFlag = 0;
    DwgHandleRef shapeFile{5, 0};
};
struct DwgLinetypeData {
    DwgTableEntry entry;
    QByteArray description;
    double patternLength = 0.0;
    quint8 alignment = 'A';
    std::vector<DwgLinetypeDash> dashes;
    QByteArray strings = QByteArray(256, '\0');
};
struct DwgAppIdData {
    DwgTableEntry entry;
    quint8 unknown = 0;
};
struct DwgViewportData {
    DwgTableEntry entry;
    double height = 9.0, aspect = 13.0;
    std::array<double, 2> center{6.0, 4.5};
    std::array<double, 3> target{}, direction{0, 0, 1};
    double twist = 0.0, lens = 50.0, front = 0.0, back = 0.0;
    std::array<bool, 4> viewMode{false, false, false, true};
    quint8 renderMode = 0;
    std::array<double, 2> lowerLeft{0, 0}, upperRight{1, 1};
    bool ucsFollow = false;
    int circleZoom = 100;
    bool fastZoom = true;
    std::array<bool, 2> ucsIcon{true, false};
    bool grid = false;
    std::array<double, 2> gridSpacing{0.5, 0.5};
    bool snap = false, snapStyle = false;
    int isoPair = 0;
    double snapRotation = 0.0;
    std::array<double, 2> snapBase{0, 0}, snapSpacing{0.5, 0.5};
    bool unknown = false, ucsPerViewport = true;
    std::array<double, 3> ucsOrigin{}, ucsX{1, 0, 0}, ucsY{0, 1, 0};
    double ucsElevation = 0.0;
    int ucsOrthographic = 0;
    DwgHandleRef namedUcs{5, 0}, baseUcs{5, 0};
};
struct DwgDimStyleData {
    DwgTableEntry entry;
    QByteArray DIMPOST, DIMAPOST;
    std::array<double, 9> real1{1.0, 0.18, 0.0625, 0.38, 0.18, 0, 0, 0, 0};          // DIMSCALE … DIMTM
    std::array<bool, 6> flags1{false, false, true, true, false, false};             // DIMTOL … DIMSE2
    std::array<int, 3> short1{0, 0, 0};                                             // DIMTAD, DIMZIN, DIMAZIN
    std::array<double, 9> real2{0.18, 0.09, 0, 25.4, 1.0, 0, 1.0, 0.09, 0};         // DIMTXT … DIMALTRND
    bool DIMALT = false;
    int DIMALTD = 2;
    std::array<bool, 4> flags2{};                                                   // DIMTOFL … DIMSOXD
    std::array<int, 14> short2{0, 0, 0, 0, 4, 4, 2, 2, 0, 0, 2, 46, 0, 0};          // DIMCLRD … DIMJUST
    bool DIMSD1 = false, DIMSD2 = false;
    std::array<int, 4> short3{1, 0, 0, 0};                                          // DIMTOLJ … DIMALTTZ
    bool DIMUPT = false;
    int DIMFIT = 3;
    int DIMLWD = -2, DIMLWE = -2;
    bool unknown = false;
    DwgHandleRef DIMTXSTY{5, 0}, DIMLDRBLK{5, 0}, DIMBLK{5, 0}, DIMBLK1{5, 0}, DIMBLK2{5, 0};
};
struct DwgDictionaryData {
    int cloning = 1;
    quint8 hardOwner = 0;
    std::vector<QByteArray> names;
    std::vector<DwgHandleRef> items;
    std::optional<DwgHandleRef> defaultEntry; // ACDBDICTIONARYWDFLT
};
struct DwgPlaceholderData {};
struct DwgMlineLine {
    double offset = 0.0;
    int color = 256;
    int linetypeIndex = 32767;
};
struct DwgMlineStyleData {
    QByteArray name, description;
    int flags = 0;
    int fillColor = 256;
    double startAngle = 1.5707963267948966, endAngle = 1.5707963267948966;
    std::vector<DwgMlineLine> lines;
};
struct DwgLayoutData {
    QByteArray pageSetup, printer, paperSize, plotView, styleSheet, layoutName;
    int plotFlags = 688;
    std::array<double, 4> margins{};             // left, bottom, right, top
    double paperWidth = 0.0, paperHeight = 0.0;
    std::array<double, 2> plotOrigin{};
    int paperUnits = 0, rotation = 0, plotType = 5;
    std::array<double, 2> windowMin{}, windowMax{};
    double realUnits = 1.0, drawingUnits = 1.0;
    int scaleType = 16;
    double scaleFactor = 1.0;
    std::array<double, 2> imageOrigin{};
    qint32 tabOrder = 1;
    int flag = 1;
    std::array<double, 3> ucsOrigin{};
    std::array<double, 2> limitsMin{0, 0}, limitsMax{12, 9};
    std::array<double, 3> insertionBase{}, ucsX{1, 0, 0}, ucsY{0, 1, 0};
    double elevation = 0.0;
    int orthographicView = 0;
    std::array<double, 3> extentsMin{1e20, 1e20, 1e20}, extentsMax{-1e20, -1e20, -1e20};
    DwgHandleRef block{4, 0}, lastViewport{4, 0}, baseUcs{5, 0}, namedUcs{5, 0};
};
struct DwgBlockData {
    QByteArray name;
};
struct DwgEndBlockData {};
// REGION, 3DSOLID, BODY: the ACIS body (version 1: SAT text in blocks, decrypted here) and the
// wireframe AutoCAD keeps for display.
struct DwgWire {
    quint8 type = 1;
    qint32 selectionMarker = -1;
    int color = 256;
    qint32 acisIndex = -1;
    std::vector<std::array<double, 3>> points;
    bool transformPresent = false;
    std::array<double, 12> transform{};       // X, Y, Z axes, translation
    double scale = 1.0;
    bool rotation = false, reflection = false, shear = false;
};
struct DwgSilhouette {
    qint32 viewportId = 0;
    std::array<double, 3> target{}, direction{}, up{};
    bool perspective = false;
    std::vector<DwgWire> wires;
};
struct DwgSolidData {
    bool empty = false;
    bool unknownBit = true;
    int version = 1;
    QByteArray sat;                           // decrypted text
    std::vector<qint32> blockSizes;           // how the file cut it (AutoCAD: 4096 bytes a block)
    bool wireframe = true;
    bool pointPresent = true;
    std::array<double, 3> point{};
    qint32 isolines = 4;
    bool isolinesPresent = true;
    std::vector<DwgWire> wires;
    std::vector<DwgSilhouette> silhouettes;
    bool acisEmpty2 = true;
};

enum class DwgObjectKind {
    BlockControl, LayerControl, StyleControl, LinetypeControl, ViewControl, UcsControl, ViewportControl,
    AppIdControl, DimStyleControl, ViewportEntityControl, BlockHeader, Layer, TextStyle, Linetype, AppId,
    Viewport, DimStyle, Dictionary, DictionaryWithDefault, Placeholder, MlineStyle, Layout, Block, EndBlock,
    Region, Solid3d, Body
};
// The kind for a type name of NativeDwgObjects (dwgTypeName): "LAYER", "ACDBDICTIONARYWDFLT", …
std::optional<DwgObjectKind> dwgObjectKind(const QString& typeName);

using DwgObjectData = std::variant<DwgControlData, DwgBlockHeaderData, DwgLayerData, DwgTextStyleData,
    DwgLinetypeData, DwgAppIdData, DwgViewportData, DwgDimStyleData, DwgDictionaryData, DwgPlaceholderData,
    DwgMlineStyleData, DwgLayoutData, DwgBlockData, DwgEndBlockData, DwgSolidData>;

struct DwgR2000Object {
    DwgObjectKind kind = DwgObjectKind::Placeholder;
    DwgObjectFrame frame;
    DwgObjectData data;
};

// Where an object's parts end, in bits from the start of its data (after the MS size).
struct DwgObjectExtent {
    quint64 dataBits = 0;     // the size of object data the file gives (where the handles start)
    quint64 handlesEnd = 0;   // where the handle stream's last reference ends
    quint32 bytes = 0;        // the object's size (MS), CRC not counted
    quint32 sizeBytes = 0;    // the MS itself
};

// An object at `offset` of the file, read as `kind`; its data must end where the file's bit count says.
bool decodeDwgR2000Object(const QByteArray& file, quint32 offset, DwgObjectKind kind, DwgR2000Object& object,
                          QString& error, DwgObjectExtent* extent = nullptr);
// MS size, data, handle stream (padded with zero bits), CRC.
bool encodeDwgR2000Object(const DwgR2000Object& object, QByteArray& bytes, QString& error,
                          DwgObjectExtent* extent = nullptr);

// ---- the document ----

// A drawing of ACIS solids in model space, as AutoCAD 2000 lays out a new drawing (its template's
// tables, dictionaries and layouts, handles 1–0x27), in millimetres; one 3DSOLID a SAT text.
struct DwgR2000SolidsDocument {
    std::vector<QByteArray> solids;           // SAT text, as AutoCAD reads it (version 400 on)
    std::array<double, 6> extents{};          // model space, mm: minimum, maximum
    std::array<quint32, 2> created{};         // Julian day, milliseconds
    QByteArray fingerprint, version;          // "{…}" GUIDs
    DwgR2000Preview preview;
};
bool encodeDwgR2000SolidsDocument(const DwgR2000SolidsDocument& document, QByteArray& file, QString& error);

} // namespace cadnext::gui
