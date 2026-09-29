#pragma once

#include <QByteArray>
#include <QHash>
#include <QString>
#include <QtGlobal>

#include <array>
#include <limits>
#include <vector>

namespace cadnext::gui {

struct ParasolidXtVertex {
    quint32 index = 0;
    quint32 pointIndex = 0;
    std::array<double, 3> position{}; // Raw transmitted coordinates.
    // A tolerant vertex's tolerance, m (NaN when exact): the edges meeting there reach it within this.
    double tolerance = std::numeric_limits<double>::quiet_NaN();
};

struct ParasolidXtEdge {
    quint32 index = 0;
    quint32 finIndex = 0;
    quint32 curveIndex = 0;
    // A tolerant edge's own tolerance, m (NaN when unset: the edge is exact). Such an edge may have
    // no curve; each of its fins then carries one (an SP-curve on its face's surface).
    double tolerance = std::numeric_limits<double>::quiet_NaN();
};

struct ParasolidXtFace {
    quint32 index = 0;
    quint32 shellIndex = 0;
    quint32 loopIndex = 0;
    quint32 surfaceIndex = 0;
    char sense = 0;
    // The shells on either side as transmitted: `shell` behind the face (against its normal),
    // `front_shell` in front of it. shellIndex above is whichever of the two is set, back first.
    quint32 backShellIndex = 0;
    quint32 frontShellIndex = 0;
};

struct ParasolidXtLoop {
    quint32 index = 0;
    quint32 finIndex = 0;
    quint32 faceIndex = 0;
    quint32 nextIndex = 0;
};

struct ParasolidXtFin {
    quint32 index = 0;
    quint32 loopIndex = 0;
    quint32 forwardIndex = 0;
    quint32 backwardIndex = 0;
    quint32 vertexIndex = 0;
    quint32 otherIndex = 0;
    quint32 edgeIndex = 0;
    quint32 curveIndex = 0;
    char sense = 0;
};

struct ParasolidXtAnalyticGeometry {
    quint32 index = 0;
    quint16 type = 0;
    char sense = 0;
    QHash<QByteArray, quint32> links;
    QHash<QByteArray, std::vector<quint32>> linkArrays;
    QHash<QByteArray, std::array<double, 3>> vectors;
    QHash<QByteArray, double> reals;
    QHash<QByteArray, quint32> integers;
    QHash<QByteArray, char> bytes;
    QHash<QByteArray, std::vector<double>> realArrays;
    QHash<QByteArray, std::vector<quint32>> integerArrays;
};

struct ParasolidXtPlanarFace {
    quint32 faceIndex = 0;
    std::array<double, 3> planeOrigin{};
    std::array<double, 3> planeNormal{};
    std::vector<std::array<double, 3>> outline;
};

// Product structure of a transmit file (XT Format Reference, "Assemblies"): a
// part file holds one body, or an assembly with instances of bodies and of
// further assemblies, each placed by a transform.
struct ParasolidXtBody {
    quint32 index = 0;
    quint8 bodyType = 0; // SCH_body_type: 1 solid, 2 wire, 3 sheet, 6 general
};

struct ParasolidXtTransform {
    quint32 index = 0;
    // As transmitted: x' = (rotation_matrix . x + translation_vector) * scale.
    std::array<double, 9> rotation{};
    std::array<double, 3> translation{};
    double scale = 1.0;
    quint32 flag = 0;
};

struct ParasolidXtInstance {
    quint32 index = 0;
    quint32 partIndex = 0;      // a BODY or an ASSEMBLY node
    quint32 transformIndex = 0; // 0 for the identity
    quint32 assemblyIndex = 0;  // the assembly the instance lies in
    quint32 nextInAssembly = 0;
    quint8 type = 1;            // 1 positive, 2 negative
};

struct ParasolidXtAssembly {
    quint32 index = 0;
    quint32 firstInstance = 0;
};

// An attribute resolved to its definition's name and its values, e.g.
// "SDL/TYSA_NAME" with one string, "SDL/TYSA_COLOUR" with three reals.
struct ParasolidXtAttribute {
    quint32 index = 0;
    quint32 ownerIndex = 0;
    QByteArray definition;
    std::vector<QByteArray> strings;
    std::vector<double> reals;
};

struct ParasolidXtTopology {
    quint32 nodeCount = 0;
    quint32 bodyCount = 0;
    quint32 shellCount = 0;
    quint32 regionCount = 0;
    quint32 pointCount = 0;
    std::array<double, 3> pointMin{};
    std::array<double, 3> pointMax{};
    std::vector<ParasolidXtVertex> vertices;
    std::vector<ParasolidXtEdge> edges;
    std::vector<ParasolidXtFace> faces;
    std::vector<ParasolidXtLoop> loops;
    std::vector<ParasolidXtFin> fins;
    std::vector<ParasolidXtAnalyticGeometry> analyticGeometry;
    std::vector<ParasolidXtBody> bodies;
    // SHELL index -> BODY index, as transmitted: null for the void shells of a solid body and for
    // every shell of a general body (XT Format Reference, SHELL), so ownership goes by region.
    QHash<quint32, quint32> shellBodies;
    QHash<quint32, quint32> shellRegions;  // SHELL index -> REGION index
    QHash<quint32, quint32> regionBodies;  // REGION index -> BODY index
    QHash<quint32, char> regionTypes;      // REGION index -> 'S' solid, 'V' void
    std::vector<ParasolidXtTransform> transforms;
    std::vector<ParasolidXtInstance> instances;
    std::vector<ParasolidXtAssembly> assemblies;
    std::vector<ParasolidXtAttribute> attributes;
    QHash<quint32, quint16> nodeTypes;
};

struct ParasolidXtWireSegment {
    quint32 finIndex = 0;
    quint32 edgeIndex = 0;
    quint32 curveIndex = 0;
    quint16 curveType = 0;
    char sense = 0;
    bool hasEndpoints = false; // False for an untrimmed closed curve.
    std::array<double, 3> start{};
    std::array<double, 3> end{};
    // A tolerant edge without a curve of its own: `curveIndex` is then the fin's (an SP-curve on
    // this face's surface), and `tolerance` the edge's.
    bool finCurve = false;
    double tolerance = std::numeric_limits<double>::quiet_NaN();
};

struct ParasolidXtFaceWire {
    quint32 faceIndex = 0;
    quint32 loopIndex = 0;
    std::vector<ParasolidXtWireSegment> segments;
};

// Decodes the node graph and exact coordinates in a neutral-binary XT
// partition, including embedded schema changes. This does not turn faces
// and analytic surfaces into a CADNext BRep yet.
bool readParasolidXtTopology(const QByteArray& partition,
                            ParasolidXtTopology& topology, QString& error);

// Decodes a standalone Parasolid transmit file: text (.x_t) or neutral binary
// (.x_b), written by Parasolid V14 or later (embedded schema). Both encodings
// go through the same schema-driven node loop as the partition above. Files
// with an older schema, user fields or in machine-dependent "bare" binary are
// refused with the reason in `error`.
bool readParasolidXtFile(const QByteArray& file,
                         ParasolidXtTopology& topology, QString& error);

// One field of a node type in the XT base schema 13006: the table the reader
// decodes by and a writer lays nodes out by, so the two cannot drift apart.
struct ParasolidXtFieldSpec {
    QByteArray name;
    char type = 0;       // p pointer, d int, n/w short, u byte, f real, v vector, c char, l logical, …
    quint32 count = 1;   // fixed number of elements
    bool variable = false; // a variable-length array, the node's last field
};

// Empty for a node type the base table does not know.
std::vector<ParasolidXtFieldSpec> parasolidXtBaseSchema(quint16 type);

// The part of a decoded graph that belongs to one BODY node: its faces (by
// shell ownership) and the loops, fins, edges and vertices under them.
// Geometry nodes stay shared, looked up by index as before.
ParasolidXtTopology parasolidXtBodyTopology(const ParasolidXtTopology& topology,
                                            quint32 bodyIndex);

// Resolves exact polygonal planar faces whose boundary consists entirely of
// line edges and one loop. Other faces remain in the topology for later BRep
// conversion and are not approximated here.
std::vector<ParasolidXtPlanarFace> parasolidXtPlanarFaces(
    const ParasolidXtTopology& topology);

// Resolves every FACE→LOOP→FIN→EDGE chain to ordered exact endpoints and
// curve node types. Used before constructing trimmed analytic BRep faces.
bool parasolidXtFaceWires(const ParasolidXtTopology& topology,
                         std::vector<ParasolidXtFaceWire>& wires, QString& error);

} // namespace cadnext::gui
