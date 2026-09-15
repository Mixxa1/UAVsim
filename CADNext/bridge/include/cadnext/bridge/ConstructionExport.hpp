#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "cadnext/Result.hpp"
#include "cadnext/Vector3.hpp"

namespace cadnext::bridge {

// Construction export (`.uavframe`): a whole assembled airframe flattened
// into one self-contained bundle the Swift Workbench imports, as plain JSON so
// the simulator reads it with Codable.
//
// Version 1 carried only a merged visual mesh, aggregated mass/CoM/bounds and
// mount points. Version 2 adds, per body, the exact BRep the Workbench hands to
// the structural solver, its material, and which display triangles belong to
// which CAD face — so a support picked on the Workbench model lands on the face
// the solver meshes ("face-<index>", the kernel's face order).
//
// Frames. Bodies' BRep stay in the CAD frame (metres, as modelled). Everything
// the Workbench draws or places — mesh, bounds, centres of mass, attachment
// points — is written in the *export frame* every `.uavframe` has always used:
// Z up, aircraft nose along −Y, X to the aircraft's left. The Workbench importer
// turns it into its model space with (x, y, z) → (x, z, −y) (+Y up, +Z forward).
// `cadAxes` records which CAD axes were declared forward and up; with the
// defaults (−y, +z) the export frame is the CAD frame itself.

struct ConstructionMesh {
    // Packed float triples [x0,y0,z0, x1,y1,z1, ...] and triangle index
    // triples [a0,b0,c0, ...].
    std::vector<float> vertices;
    std::vector<std::uint32_t> indices;
};

struct ConstructionAttachmentPoint {
    std::string id;
    std::string name;
    std::string role;
    Vector3 position; // airframe frame, metres
    Vector3 rotation; // Euler degrees
};

// A signed CAD axis: "+x", "-x", "+y", "-y", "+z", "-z".
struct ConstructionAxes {
    std::string forward;
    std::string up;
};

struct ConstructionFaceRange {
    std::string faceId; // "face-<index>"
    std::uint32_t firstTriangle = 0;
    std::uint32_t triangleCount = 0;
};

struct ConstructionBody {
    std::string id;
    std::string name;
    std::string materialId;
    double densityKgPerM3 = 0.0;
    double volumeM3 = 0.0;
    double massKg = 0.0;
    Vector3 centerOfMass; // export frame
    // BRep ASCII without triangulation, CAD frame, and the SHA-256 of exactly these bytes.
    std::string brep;
    std::string brepSha256;
    // Range of this body's triangles in the merged mesh, and within it, per CAD face.
    std::uint32_t firstTriangle = 0;
    std::uint32_t triangleCount = 0;
    std::vector<ConstructionFaceRange> faces;
};

struct ConstructionDescriptor {
    std::string id;
    std::string name;

    double massKg = 0.0;
    Vector3 centerOfMass;
    Vector3 boundingBoxMin;
    Vector3 boundingBoxMax;

    ConstructionMesh mesh;
    std::vector<ConstructionAttachmentPoint> attachmentPoints;

    // Bounding-box collision proxy (center + full size), matching the
    // `.uavpart` simulation-proxy shape the runtime already understands.
    Vector3 collisionCenter;
    Vector3 collisionSize;

    // Version 2. Empty `bodies` (a version-1 file) means no exact geometry.
    ConstructionAxes cadAxes;
    std::vector<ConstructionBody> bodies;
};

class ConstructionExport {
public:
    static constexpr int kFormatVersion = 2;

    static std::string toJson(const ConstructionDescriptor& descriptor);
    static Result<ConstructionDescriptor> fromJson(const std::string& json);

    static Result<bool> saveToFile(const ConstructionDescriptor& descriptor,
                                   const std::string& path);
    static Result<ConstructionDescriptor> loadFromFile(const std::string& path);
};

} // namespace cadnext::bridge
