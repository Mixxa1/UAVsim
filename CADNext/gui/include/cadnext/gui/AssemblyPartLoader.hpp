#pragma once

#include <map>
#include <memory>
#include <set>
#include <string>

#include <QString>

#include "cadnext/assembly/AssemblyModel.hpp"
#include "cadnext/assembly/GeometryReferenceResolver.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

namespace cadnext::gui {

// Loaded geometry of one part source file, in part-local space. Shared by
// every component instance linking to the same file (assembly spec §3:
// components are links, one wing file → N placements of one geometry).
struct AssemblyPartGeometry {
    bool valid = false;
    QString error;

    std::string displayName;
    std::string contentHash;

    kernel::TriangleMesh mesh;
    assembly::PartTopology topology;
};

// Headless part loading + cache for the Assembly workbench. Owns its own
// kernel instance (shape registry) and re-extracts topology through the
// kernel analyzers; no Qt widgets, no viewer types.
class AssemblyPartLoader {
public:
    AssemblyPartLoader();
    ~AssemblyPartLoader();

    AssemblyPartLoader(const AssemblyPartLoader&) = delete;
    AssemblyPartLoader& operator=(const AssemblyPartLoader&) = delete;

    // Cached by absolute path; the entry reloads automatically when the
    // file content hash changed on disk (part edited in the CAD part
    // workbench). Never returns nullptr — failed loads come back with
    // valid=false and a user-facing error.
    const AssemblyPartGeometry& geometryForSource(const assembly::PartReference& source);

    // Drops a cache entry (recompute after an external edit).
    void invalidate(const std::string& filePath);
    void clear();

private:
    AssemblyPartGeometry loadSource(const assembly::PartReference& source,
                                    const std::string& contentHash);
    AssemblyPartGeometry loadUavPart(const std::string& path);
    // Headless replay of a .cadnext parametric document (primitives +
    // extrude + cut + chamfer + fillet) through the GeometryEvaluator.
    // bodyId picks the target body; empty means the last body created.
    AssemblyPartGeometry loadCadnextPart(const std::string& path,
                                         const std::string& bodyId);
    // Loads a .cadasm subassembly as one rigid component: recomputes its
    // internal joints, then merges every internal part's mesh + topology
    // (transformed by the solved internal placement) into a single
    // subassembly-local geometry with namespaced topology ids (spec §15).
    AssemblyPartGeometry loadSubassembly(const std::string& path);
    AssemblyPartGeometry geometryFromShape(const kernel::ShapeHandle& shape,
                                           const std::string& displayName);

    std::unique_ptr<kernel::Kernel> kernel_;
    std::unique_ptr<kernel::GeometryEvaluator> evaluator_;
    std::map<std::string, AssemblyPartGeometry> cacheByPath_;
    // Guards against cyclic subassembly references during recursive loads.
    std::set<std::string> loadingStack_;
};

} // namespace cadnext::gui
