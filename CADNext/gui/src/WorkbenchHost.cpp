#include "cadnext/gui/WorkbenchHost.hpp"

#include <utility>

namespace cadnext::gui {

void WorkbenchHost::activateWorkbench(std::string workbenchId) {
    activeWorkbenchId_ = std::move(workbenchId);
}

const std::string& WorkbenchHost::activeWorkbenchId() const {
    return activeWorkbenchId_;
}

} // namespace cadnext::gui
