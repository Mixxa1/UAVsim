#pragma once

#include <string>

namespace cadnext::gui {

class WorkbenchHost {
public:
    void activateWorkbench(std::string workbenchId);
    const std::string& activeWorkbenchId() const;

private:
    std::string activeWorkbenchId_;
};

} // namespace cadnext::gui
