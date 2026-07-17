#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "cadnext/Result.hpp"
#include "cadnext/Vector3.hpp"

namespace cadnext::bridge {

// Construction export (`.uavframe`): a whole assembled airframe flattened
// into one self-contained bundle the Swift Workbench imports. Unlike
// `.uavpart` (one BRep body) this carries a merged visual mesh + aggregated
// mass/CoM/bounds + all mount points, as plain JSON so the simulator reads
// it with Codable — no BRep, no binary sections.

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
};

class ConstructionExport {
public:
    static constexpr int kFormatVersion = 1;

    static std::string toJson(const ConstructionDescriptor& descriptor);
    static Result<ConstructionDescriptor> fromJson(const std::string& json);

    static Result<bool> saveToFile(const ConstructionDescriptor& descriptor,
                                   const std::string& path);
    static Result<ConstructionDescriptor> loadFromFile(const std::string& path);
};

} // namespace cadnext::bridge
