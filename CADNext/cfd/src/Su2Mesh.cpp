#include "cadnext/cfd/Su2Mesh.hpp"

#include <cstdio>
#include <fstream>

namespace cadnext::cfd {

std::string Su2Mesh::text() const {
    std::string out;
    out.reserve(points.size() * 64 + elements.size() * 40);
    char buffer[128];
    auto line = [&](const char* format, auto... args) {
        std::snprintf(buffer, sizeof(buffer), format, args...);
        out += buffer;
    };
    line("NDIME= %d\n", dimension);
    line("NELEM= %zu\n", elements.size());
    for (std::size_t e = 0; e < elements.size(); ++e) {
        line("%d", static_cast<int>(elements[e].type));
        for (int node : elements[e].nodes) line(" %d", node);
        line(" %zu\n", e);
    }
    line("NPOIN= %zu\n", points.size());
    for (std::size_t p = 0; p < points.size(); ++p) {
        if (dimension == 2) {
            line("%.17g %.17g %zu\n", points[p][0], points[p][1], p);
        } else {
            line("%.17g %.17g %.17g %zu\n", points[p][0], points[p][1], points[p][2], p);
        }
    }
    line("NMARK= %zu\n", markers.size());
    for (const auto& [name, boundary] : markers) {
        out += "MARKER_TAG= " + name + "\n";
        line("MARKER_ELEMS= %zu\n", boundary.size());
        for (const auto& element : boundary) {
            line("%d", static_cast<int>(element.type));
            for (int node : element.nodes) line(" %d", node);
            out += "\n";
        }
    }
    return out;
}

bool Su2Mesh::write(const std::string& path) const {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) return false;
    stream << text();
    return static_cast<bool>(stream);
}

} // namespace cadnext::cfd
