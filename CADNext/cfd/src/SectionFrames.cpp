#include "cadnext/cfd/SectionFrames.hpp"

#include "cadnext/cfd/Su2Case.hpp"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <limits>
#include <locale>
#include <sstream>
#include <unordered_map>

namespace cadnext::cfd {

namespace {

template <typename T>
Result<T> failure(const std::string& message) {
    return Result<T>::fail({ErrorCode::InvalidArgument, message});
}

std::size_t meshPointCount(const std::string& meshPath) {
    std::ifstream mesh(meshPath);
    std::string line;
    while (std::getline(mesh, line)) {
        if (line.rfind("NPOIN=", 0) == 0) {
            std::size_t count = 0;
            std::istringstream(line.substr(6)) >> count;
            return count;
        }
    }
    return 0;
}

// Column index of a quoted CSV header name ("Velocity_x" or " "Velocity_x" "), −1 when absent.
int columnOf(const std::vector<std::string>& names, const std::string& wanted) {
    for (std::size_t i = 0; i < names.size(); ++i) {
        std::string name;
        for (char c : names[i]) if (c != '"' && c != ' ' && c != '\r') name += c;
        if (name == wanted) return static_cast<int>(i);
    }
    return -1;
}

std::vector<std::string> split(const std::string& line) {
    std::vector<std::string> out;
    std::string field;
    std::istringstream stream(line);
    while (std::getline(stream, field, ',')) out.push_back(field);
    return out;
}

} // namespace

Result<double> midSpanPlane(const std::string& meshPath) {
    std::ifstream mesh(meshPath);
    if (!mesh) return failure<double>("нет сетки " + meshPath);
    std::string line;
    std::vector<double> ys;
    double low = std::numeric_limits<double>::infinity(), high = -low;
    while (std::getline(mesh, line)) {
        if (line.rfind("NPOIN=", 0) == 0) {
            std::size_t count = 0;
            std::istringstream(line.substr(6)) >> count;
            ys.resize(count);
            for (std::size_t i = 0; i < count && std::getline(mesh, line); ++i) {
                std::istringstream row(line);
                double x = 0, y = 0, z = 0;
                std::size_t id = 0;
                if (!(row >> x >> y >> z >> id) || id >= count) return failure<double>("неверная точка сетки");
                ys[id] = y;
            }
        } else if (line.rfind("MARKER_TAG=", 0) == 0) {
            const bool farfield = line.find("farfield") != std::string::npos;
            if (!std::getline(mesh, line)) break;
            std::size_t faces = 0;
            std::istringstream(line.substr(line.find('=') + 1)) >> faces;
            for (std::size_t f = 0; f < faces && std::getline(mesh, line); ++f) {
                if (farfield) continue;
                std::istringstream row(line);
                int type = 0;
                row >> type;
                std::size_t id = 0;
                while (row >> id) {
                    if (id < ys.size()) { low = std::min(low, ys[id]); high = std::max(high, ys[id]); }
                }
            }
        }
    }
    if (!(high >= low)) return failure<double>("в сетке нет стенок");
    return Result<double>::ok(0.5 * (low + high));
}

Result<std::vector<std::size_t>> sectionNodes(const std::string& meshPath, double planeY) {
    const std::size_t count = meshPointCount(meshPath);
    if (count == 0) return failure<std::vector<std::size_t>>("нет точек в сетке " + meshPath);
    std::ifstream mesh(meshPath);
    try {
        const double far = 1e9;
        const auto section = FlowSection::read(mesh, std::vector<FlowSection::Vector>(count, {0, 0, 0}), planeY, {-far, far, -far, far});
        return Result<std::vector<std::size_t>>::ok(section.referencedNodes());
    } catch (const std::exception& error) {
        return failure<std::vector<std::size_t>>(std::string("сечение сетки: ") + error.what());
    }
}

Result<bool> writeSectionFrame(const std::string& volumePath, const std::vector<std::size_t>& nodes, const std::string& sectionPath) {
    std::ifstream volume(volumePath);
    if (!volume) return failure<bool>("нет поля " + volumePath);
    std::string line;
    if (!std::getline(volume, line)) return failure<bool>("пустое поле " + volumePath);
    const auto names = split(line);
    const int id = columnOf(names, "PointID"), vx = columnOf(names, "Velocity_x"), vy = columnOf(names, "Velocity_y"),
              vz = columnOf(names, "Velocity_z");
    if (id < 0 || vx < 0 || vy < 0 || vz < 0) return failure<bool>("в поле нет номеров узлов или скорости");
    std::size_t largest = 0;
    for (auto node : nodes) largest = std::max(largest, node);
    std::vector<std::array<double, 3>> found(largest + 1, {NAN, NAN, NAN});
    std::vector<char> wanted(largest + 1, 0);
    for (auto node : nodes) wanted[node] = 1;
    const int last = std::max({id, vx, vy, vz});
    while (std::getline(volume, line)) {
        // Only four columns matter; walk the commas instead of splitting the whole row.
        std::array<const char*, 64> starts{};
        int column = 0;
        starts[0] = line.c_str();
        for (const char* c = line.c_str(); *c && column < last; ++c)
            if (*c == ',') starts[++column] = c + 1;
        if (column < last) continue;
        const auto node = static_cast<std::size_t>(std::strtod(starts[id], nullptr));
        if (node > largest || !wanted[node]) continue;
        found[node] = {std::strtod(starts[vx], nullptr), std::strtod(starts[vy], nullptr), std::strtod(starts[vz], nullptr)};
    }
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::setprecision(9) << "\"PointID\",\"Velocity_x\",\"Velocity_y\",\"Velocity_z\"\n";
    for (auto node : nodes) {
        const auto& v = found[node];
        if (!std::isfinite(v[0]) || !std::isfinite(v[1]) || !std::isfinite(v[2])) {
            return failure<bool>("в поле " + volumePath + " нет узла " + std::to_string(node) + " сечения");
        }
        out << node << ',' << v[0] << ',' << v[1] << ',' << v[2] << '\n';
    }
    const std::string temporary = sectionPath + ".partial";
    {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (!(file << out.str())) return failure<bool>("не удалось записать " + sectionPath);
    }
    if (std::rename(temporary.c_str(), sectionPath.c_str()) != 0) return failure<bool>("не удалось записать " + sectionPath);
    return Result<bool>::ok(true);
}

Result<std::vector<FlowSection::Vector>> readSectionFrame(const std::string& sectionPath, const std::vector<std::size_t>& nodes) {
    std::ifstream file(sectionPath);
    if (!file) return failure<std::vector<FlowSection::Vector>>("нет кадра " + sectionPath);
    const auto table = parseSu2History({std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()});
    if (!table.isOk()) return failure<std::vector<FlowSection::Vector>>(table.error().message);
    const auto& t = table.value();
    const int id = t.column("PointID"), vx = t.column("Velocity_x"), vy = t.column("Velocity_y"), vz = t.column("Velocity_z");
    if (id < 0 || vx < 0 || vy < 0 || vz < 0) return failure<std::vector<FlowSection::Vector>>("неверный кадр " + sectionPath);
    std::unordered_map<std::size_t, std::size_t> position;
    position.reserve(nodes.size());
    for (std::size_t i = 0; i < nodes.size(); ++i) position.emplace(nodes[i], i);
    std::vector<FlowSection::Vector> velocity(nodes.size(), {NAN, NAN, NAN});
    std::size_t filled = 0;
    for (const auto& row : t.rows) {
        const auto it = position.find(static_cast<std::size_t>(row[id]));
        if (it == position.end()) continue;
        if (!std::isfinite(velocity[it->second][0])) ++filled;
        velocity[it->second] = {row[vx], row[vy], row[vz]};
    }
    if (filled != nodes.size()) return failure<std::vector<FlowSection::Vector>>("кадр " + sectionPath + " не покрывает сечение");
    return Result<std::vector<FlowSection::Vector>>::ok(std::move(velocity));
}

} // namespace cadnext::cfd
