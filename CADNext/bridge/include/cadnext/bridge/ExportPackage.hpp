#pragma once

#include <string>
#include <vector>

#include "cadnext/bridge/AttachmentExport.hpp"
#include "cadnext/bridge/MassPropertiesExport.hpp"

namespace cadnext::bridge {

struct MeshReference {
    std::string visualMeshPath;
    std::string collisionMeshPath;
};

struct ExportPackage {
    std::string id;
    std::string name;
    MeshReference mesh;
    MassPropertiesExport mass;
    std::vector<AttachmentExport> attachments;
    std::vector<std::string> materialTags;
};

} // namespace cadnext::bridge
