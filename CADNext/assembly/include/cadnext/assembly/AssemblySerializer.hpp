#pragma once

#include <string>

#include "cadnext/Result.hpp"
#include "cadnext/assembly/AssemblyModel.hpp"

namespace cadnext::assembly {

// JSON serialization of the assembly document (.cadasm files).
//
// The format stores component links (source path relative to the assembly
// file + absolute fallback), placements (translation + quaternion),
// grounded/visible/suppressed flags, joints with both geometry references
// (persistent topology id + geometric signature + fallback frame) and the
// last solve states. Part geometry is NEVER stored — components are links
// (assembly spec §3); geometry reloads from the source files.
class AssemblySerializer {
public:
    static constexpr int kFormatVersion = 1;

    static std::string toJson(const AssemblyDocument& document,
                              const std::string& assemblyFilePath = std::string());
    static Result<AssemblyDocument> fromJson(const std::string& json,
                                             const std::string& assemblyFilePath = std::string());

    // saveToFile/loadFromFile rewrite PartReference::filePath: saving
    // stores source paths relative to the assembly file (plus the absolute
    // fallback); loading resolves them back to absolute paths, preferring
    // the relative one when it exists on disk.
    static Result<bool> saveToFile(const AssemblyDocument& document, const std::string& path);
    static Result<AssemblyDocument> loadFromFile(const std::string& path);

    // FNV-1a64 hex of the file bytes — the PartReference::contentHash used
    // for "source part changed" detection. Empty string when unreadable.
    static std::string contentHashForFile(const std::string& path);
};

} // namespace cadnext::assembly
