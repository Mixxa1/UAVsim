#include "cadnext/assembly/AssemblyGraph.hpp"

#include <map>
#include <set>

namespace cadnext::assembly {

namespace {

// Union-find over component ids.
class DisjointSet {
public:
    void ensure(const std::string& id) {
        parents_.emplace(id, id);
    }

    std::string find(std::string id) {
        if (parents_.find(id) == parents_.end()) {
            parents_[id] = id;
            return id;
        }
        while (parents_[id] != id) {
            parents_[id] = parents_[parents_[id]]; // path halving
            id = parents_[id];
        }
        return id;
    }

    // Returns false when both ids already share a root (a cycle edge).
    bool unite(const std::string& a, const std::string& b) {
        const std::string rootA = find(a);
        const std::string rootB = find(b);
        if (rootA == rootB) {
            return false;
        }
        parents_[rootA] = rootB;
        return true;
    }

private:
    std::map<std::string, std::string> parents_;
};

} // namespace

AssemblyGraph AssemblyGraph::build(const AssemblyDocument& document,
                                   const std::vector<const AssemblyJoint*>& usableJoints) {
    AssemblyGraph graph;

    DisjointSet sets;
    std::set<std::string> cycleRoots;
    for (const AssemblyComponent& component : document.components()) {
        if (!component.isSuppressed) {
            sets.ensure(component.id);
        }
    }

    for (const AssemblyJoint* joint : usableJoints) {
        if (!joint || joint->first.componentPath.empty() ||
            joint->second.componentPath.empty()) {
            continue;
        }
        const std::string& first = joint->first.componentPath.front();
        const std::string& second = joint->second.componentPath.front();
        const auto firstComponent = document.componentById(first);
        const auto secondComponent = document.componentById(second);
        if (!firstComponent.isOk() || !secondComponent.isOk() ||
            firstComponent.value().isSuppressed || secondComponent.value().isSuppressed ||
            first == second) {
            continue;
        }
        Edge edge;
        edge.jointId = joint->id;
        edge.firstComponentId = first;
        edge.secondComponentId = second;
        graph.edges_.push_back(edge);
        if (!sets.unite(first, second)) {
            cycleRoots.insert(sets.find(first));
        }
    }

    std::map<std::string, Group> groupsByRoot;
    for (const AssemblyComponent& component : document.components()) {
        if (component.isSuppressed) {
            continue;
        }
        const std::string root = sets.find(component.id);
        Group& group = groupsByRoot[root];
        group.componentIds.push_back(component.id);
        if (component.isGrounded) {
            group.groundedComponentIds.push_back(component.id);
        }
        if (cycleRoots.count(root)) {
            group.hasCycle = true;
        }
    }
    for (const Edge& edge : graph.edges_) {
        groupsByRoot[sets.find(edge.firstComponentId)].jointIds.push_back(edge.jointId);
    }

    graph.groups_.reserve(groupsByRoot.size());
    for (auto& entry : groupsByRoot) {
        graph.groups_.push_back(std::move(entry.second));
    }
    return graph;
}

const std::vector<AssemblyGraph::Group>& AssemblyGraph::groups() const {
    return groups_;
}

const std::vector<AssemblyGraph::Edge>& AssemblyGraph::edges() const {
    return edges_;
}

std::vector<std::string> AssemblyGraph::jointIdsForComponent(
    const std::string& componentId) const {
    std::vector<std::string> result;
    for (const Edge& edge : edges_) {
        if (edge.firstComponentId == componentId || edge.secondComponentId == componentId) {
            result.push_back(edge.jointId);
        }
    }
    return result;
}

} // namespace cadnext::assembly
