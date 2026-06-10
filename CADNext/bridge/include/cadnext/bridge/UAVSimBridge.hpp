#pragma once

#include "cadnext/Document.hpp"
#include "cadnext/bridge/ExportPackage.hpp"

namespace cadnext::bridge {

class UAVSimBridge {
public:
    ExportPackage makeExportPackage(const Document& document) const;
};

} // namespace cadnext::bridge
