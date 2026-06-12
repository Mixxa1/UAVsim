#pragma once

#include <string>

#include "cadnext/Document.hpp"
#include "cadnext/Result.hpp"

namespace cadnext {

// JSON serialization of the CADNext document model (.cadnext files).
//
// The format stores only the parametric construction data (primitive
// descriptors + transforms). Evaluated geometry — ShapeHandle, OCCT
// TopoDS_Shape, preview meshes — is intentionally never serialized;
// shapes are re-evaluated from the descriptors on every load.
class DocumentSerializer {
public:
    static constexpr int kFormatVersion = 1;

    static std::string toJson(const Document& document);
    static Result<Document> fromJson(const std::string& json);

    static Result<bool> saveToFile(const Document& document, const std::string& path);
    static Result<Document> loadFromFile(const std::string& path);
};

} // namespace cadnext
