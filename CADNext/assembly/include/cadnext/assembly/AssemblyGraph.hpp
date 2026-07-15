#pragma once

#include <string>
#include <vector>

#include "cadnext/assembly/AssemblyModel.hpp"

namespace cadnext::assembly {

// Connectivity view of the assembly: components are nodes, enabled
// non-broken joints are edges. Suppressed components stay out of the
// graph entirely.
class AssemblyGraph {
public:
    struct Edge {
        std::string jointId;
        std::string firstComponentId;
        std::string secondComponentId;
    };

    struct Group {
        std::vector<std::string> componentIds;
        std::vector<std::string> jointIds;
        std::vector<std::string> groundedComponentIds;
        bool hasCycle = false;
    };

    // jointUsable filters edges (the recompute engine excludes broken /
    // disabled joints before building the graph).
    static AssemblyGraph build(const AssemblyDocument& document,
                               const std::vector<const AssemblyJoint*>& usableJoints);

    const std::vector<Group>& groups() const;
    const std::vector<Edge>& edges() const;

    // Joints connected to the component (graph edges only).
    std::vector<std::string> jointIdsForComponent(const std::string& componentId) const;

private:
    std::vector<Group> groups_;
    std::vector<Edge> edges_;
};

} // namespace cadnext::assembly
