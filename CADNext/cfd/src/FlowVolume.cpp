#include "cadnext/cfd/FlowVolume.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>

namespace cadnext::cfd {

namespace {

// Integers of one line, parsed without allocations: a mesh of a few million cells is read line by
// line, and std::istringstream per line is the difference between one second and ten.
int readIntegers(const std::string& line, long* out, int capacity) {
    const char* c = line.c_str();
    int count = 0;
    while (*c && count < capacity) {
        char* end = nullptr;
        const long value = std::strtol(c, &end, 10);
        if (end == c) break;
        out[count++] = value;
        c = end;
    }
    return count;
}

std::size_t countAfterEquals(const std::string& line) {
    const auto equal = line.find('=');
    return equal == std::string::npos ? 0 : static_cast<std::size_t>(std::strtoull(line.c_str() + equal + 1, nullptr, 10));
}

} // namespace

FlowVolume FlowVolume::read(std::istream& input, const std::vector<Point>& velocity, const std::array<double, 6>& region) {
    for (int k = 0; k < 6; k += 2)
        if (!std::isfinite(region[k]) || !std::isfinite(region[k + 1]) || !(region[k + 1] > region[k])) throw std::runtime_error("Invalid flow region");
    FlowVolume volume;
    volume.region_ = region;
    std::vector<std::uint8_t> types;
    std::vector<std::uint32_t> cellNodes;
    std::vector<Point> meshPoints;
    std::vector<std::array<std::uint32_t, 4>> wallFaces; // node ids, [3] = UINT32_MAX for triangles
    std::string line;
    bool threeDimensional = false;
    while (std::getline(input, line)) {
        if (line.rfind("NDIME=", 0) == 0) threeDimensional = countAfterEquals(line) == 3;
        else if (line.rfind("NELEM=", 0) == 0) {
            const std::size_t count = countAfterEquals(line);
            types.reserve(count);
            cellNodes.reserve(count * 5);
            long values[8];
            for (std::size_t i = 0; i < count; ++i) {
                if (!std::getline(input, line)) throw std::runtime_error("Incomplete mesh cells");
                const int read = readIntegers(line, values, 8);
                const int nodes = read > 0 ? (values[0] == 10 ? 4 : values[0] == 13 ? 6 : values[0] == 14 ? 5 : 0) : 0;
                if (nodes == 0 || read < nodes + 1) throw std::runtime_error("Unsupported fluid cell");
                types.push_back(static_cast<std::uint8_t>(values[0]));
                for (int n = 1; n <= nodes; ++n) {
                    if (values[n] < 0) throw std::runtime_error("Invalid cell node");
                    cellNodes.push_back(static_cast<std::uint32_t>(values[n]));
                }
            }
        } else if (line.rfind("NPOIN=", 0) == 0) {
            const std::size_t count = countAfterEquals(line);
            meshPoints.assign(count, {NAN, NAN, NAN});
            for (std::size_t i = 0; i < count; ++i) {
                if (!std::getline(input, line)) throw std::runtime_error("Incomplete mesh points");
                char* end = nullptr;
                const char* c = line.c_str();
                Point p{};
                for (int k = 0; k < 3; ++k) { p[k] = std::strtod(c, &end); c = end; }
                const auto id = static_cast<std::size_t>(std::strtoull(c, &end, 10));
                if (end == c || id >= count) throw std::runtime_error("Invalid mesh point");
                meshPoints[id] = p;
            }
        } else if (line.rfind("MARKER_TAG=", 0) == 0) {
            const bool farfield = line.find("farfield") != std::string::npos;
            if (!std::getline(input, line)) throw std::runtime_error("Incomplete mesh marker");
            const std::size_t faces = countAfterEquals(line);
            long values[6];
            for (std::size_t f = 0; f < faces; ++f) {
                if (!std::getline(input, line)) throw std::runtime_error("Incomplete mesh boundary");
                if (farfield) continue;
                const int read = readIntegers(line, values, 6);
                if (read >= 4 && values[0] == 5) wallFaces.push_back({std::uint32_t(values[1]), std::uint32_t(values[2]), std::uint32_t(values[3]), UINT32_MAX});
                else if (read >= 5 && values[0] == 9) wallFaces.push_back({std::uint32_t(values[1]), std::uint32_t(values[2]), std::uint32_t(values[3]), std::uint32_t(values[4])});
            }
        }
    }
    if (!threeDimensional || meshPoints.empty() || types.empty()) throw std::runtime_error("Incomplete volume mesh");
    if (velocity.size() != meshPoints.size()) throw std::runtime_error("Velocity does not match the mesh");

    for (const auto& face : wallFaces) {
        for (auto id : face) if (id != UINT32_MAX && id >= meshPoints.size()) throw std::runtime_error("Invalid boundary node");
        volume.walls_.push_back({meshPoints[face[0]], meshPoints[face[1]], meshPoints[face[2]]});
        if (face[3] != UINT32_MAX) volume.walls_.push_back({meshPoints[face[0]], meshPoints[face[2]], meshPoints[face[3]]});
    }

    // Cells reaching into the region, as tetrahedra over compacted nodes.
    std::vector<std::uint32_t> compact(meshPoints.size(), UINT32_MAX);
    auto use = [&](std::uint32_t id) {
        if (compact[id] == UINT32_MAX) {
            compact[id] = static_cast<std::uint32_t>(volume.points_.size());
            volume.points_.push_back(meshPoints[id]);
            volume.velocity_.push_back(velocity[id]);
        }
        return compact[id];
    };
    std::size_t offset = 0;
    for (auto type : types) {
        const int nodes = type == 10 ? 4 : type == 13 ? 6 : 5;
        const std::uint32_t* n = cellNodes.data() + offset;
        offset += static_cast<std::size_t>(nodes);
        bool reaches = false, known = true;
        std::array<double, 6> box{INFINITY, -INFINITY, INFINITY, -INFINITY, INFINITY, -INFINITY};
        for (int k = 0; k < nodes; ++k) {
            if (n[k] >= meshPoints.size()) throw std::runtime_error("Cell node out of range");
            const auto& p = meshPoints[n[k]];
            for (int a = 0; a < 3; ++a) { box[2 * a] = std::min(box[2 * a], p[a]); box[2 * a + 1] = std::max(box[2 * a + 1], p[a]); }
            for (double c : velocity[n[k]]) known = known && std::isfinite(c);
        }
        reaches = box[1] >= region[0] && box[0] <= region[1] && box[3] >= region[2] && box[2] <= region[3] && box[5] >= region[4] && box[4] <= region[5];
        if (!reaches) continue;
        if (!known) throw std::runtime_error("Incomplete volume field");
        auto tet = [&](int a, int b, int c, int d) { volume.tets_.push_back({use(n[a]), use(n[b]), use(n[c]), use(n[d])}); };
        if (type == 10) tet(0, 1, 2, 3);
        else if (type == 13) { tet(0, 1, 2, 3); tet(1, 2, 3, 4); tet(2, 3, 4, 5); }
        else { tet(0, 1, 2, 4); tet(0, 2, 3, 4); }
    }
    if (volume.tets_.empty()) throw std::runtime_error("No fluid cells in the flow region");

    // Bins: about twelve tetrahedra each.
    const double lx = region[1] - region[0], ly = region[3] - region[2], lz = region[5] - region[4];
    const double h = std::cbrt(lx * ly * lz / std::max<double>(1.0, volume.tets_.size() / 12.0));
    for (int a = 0; a < 3; ++a) volume.bins_[a] = std::clamp(static_cast<int>(std::ceil((region[2 * a + 1] - region[2 * a]) / h)), 1, 256);
    const std::size_t total = static_cast<std::size_t>(volume.bins_[0]) * volume.bins_[1] * volume.bins_[2];
    auto binRange = [&](const std::array<std::uint32_t, 4>& t, std::array<int, 6>& range) {
        for (int a = 0; a < 3; ++a) {
            double low = INFINITY, high = -INFINITY;
            for (auto id : t) { low = std::min(low, volume.points_[id][a]); high = std::max(high, volume.points_[id][a]); }
            const double scale = volume.bins_[a] / (region[2 * a + 1] - region[2 * a]);
            range[2 * a] = std::clamp(static_cast<int>(std::floor((low - region[2 * a]) * scale)), 0, volume.bins_[a] - 1);
            range[2 * a + 1] = std::clamp(static_cast<int>(std::floor((high - region[2 * a]) * scale)), 0, volume.bins_[a] - 1);
        }
    };
    std::vector<std::uint32_t> counts(total + 1, 0);
    std::array<int, 6> range{};
    for (const auto& t : volume.tets_) {
        binRange(t, range);
        for (int z = range[4]; z <= range[5]; ++z)
            for (int y = range[2]; y <= range[3]; ++y)
                for (int x = range[0]; x <= range[1]; ++x) ++counts[volume.bin(x, y, z) + 1];
    }
    for (std::size_t i = 1; i < counts.size(); ++i) counts[i] += counts[i - 1];
    volume.binStart_ = counts;
    volume.binTets_.resize(counts.back());
    std::vector<std::uint32_t> fill(counts.begin(), counts.end() - 1);
    for (std::uint32_t i = 0; i < volume.tets_.size(); ++i) {
        binRange(volume.tets_[i], range);
        for (int z = range[4]; z <= range[5]; ++z)
            for (int y = range[2]; y <= range[3]; ++y)
                for (int x = range[0]; x <= range[1]; ++x) volume.binTets_[fill[volume.bin(x, y, z)]++] = i;
    }
    return volume;
}

bool FlowVolume::inside(std::uint32_t tet, const Point& p, std::array<double, 4>& weights) const {
    const auto& t = tets_[tet];
    const Point& a = points_[t[0]];
    double m[3][3], r[3];
    for (int k = 0; k < 3; ++k) {
        m[k][0] = points_[t[1]][k] - a[k];
        m[k][1] = points_[t[2]][k] - a[k];
        m[k][2] = points_[t[3]][k] - a[k];
        r[k] = p[k] - a[k];
    }
    const double det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                       + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    if (std::fabs(det) < 1e-300) return false;
    // Cramer's rule for the three barycentric coordinates beyond the first node.
    auto replaced = [&](int column) {
        double c[3][3];
        for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) c[i][j] = j == column ? r[i] : m[i][j];
        return c[0][0] * (c[1][1] * c[2][2] - c[1][2] * c[2][1]) - c[0][1] * (c[1][0] * c[2][2] - c[1][2] * c[2][0])
               + c[0][2] * (c[1][0] * c[2][1] - c[1][1] * c[2][0]);
    };
    const double l1 = replaced(0) / det, l2 = replaced(1) / det, l3 = replaced(2) / det, l0 = 1.0 - l1 - l2 - l3;
    constexpr double tolerance = -1e-9;
    if (l0 < tolerance || l1 < tolerance || l2 < tolerance || l3 < tolerance) return false;
    weights = {l0, l1, l2, l3};
    return true;
}

bool FlowVolume::sample(const Point& p, Point& v) const {
    for (int a = 0; a < 3; ++a) if (!(p[a] >= region_[2 * a] && p[a] <= region_[2 * a + 1])) return false;
    std::array<double, 4> w{};
    auto interpolate = [&](std::uint32_t tet) {
        const auto& t = tets_[tet];
        for (int k = 0; k < 3; ++k) v[k] = w[0] * velocity_[t[0]][k] + w[1] * velocity_[t[1]][k] + w[2] * velocity_[t[2]][k] + w[3] * velocity_[t[3]][k];
        lastTet_ = tet;
        return true;
    };
    // Consecutive samples along a line are almost always in the same cell.
    if (lastTet_ < tets_.size() && inside(lastTet_, p, w)) return interpolate(lastTet_);
    int index[3];
    for (int a = 0; a < 3; ++a)
        index[a] = std::clamp(static_cast<int>((p[a] - region_[2 * a]) / (region_[2 * a + 1] - region_[2 * a]) * bins_[a]), 0, bins_[a] - 1);
    const std::size_t b = bin(index[0], index[1], index[2]);
    for (std::uint32_t i = binStart_[b]; i < binStart_[b + 1]; ++i)
        if (inside(binTets_[i], p, w)) return interpolate(binTets_[i]);
    return false;
}

std::vector<Trajectory> traceTrajectories(const FlowVolume& volume, const TrajectorySettings& s) {
    const auto& r = volume.region();
    const double length = std::max({r[1] - r[0], r[3] - r[2], r[5] - r[4]});
    const double step = s.step > 0 ? s.step : length / 1500.0;
    std::mt19937 random(s.seed);
    std::uniform_real_distribution<double> unit(0.0, 1.0);
    std::vector<Trajectory> out;
    for (int row = 0; row < s.rows; ++row) {
        for (int column = 0; column < s.columns; ++column) {
            const double fy = (column + (s.jitter ? unit(random) : 0.5)) / s.columns;
            const double fz = (row + (s.jitter ? unit(random) : 0.5)) / s.rows;
            FlowVolume::Point p{s.rakeX, s.rakeSpan[0] + fy * (s.rakeSpan[1] - s.rakeSpan[0]), s.rakeSpan[2] + fz * (s.rakeSpan[3] - s.rakeSpan[2])};
            FlowVolume::Point v{};
            if (!volume.sample(p, v)) continue;
            const double seedSpeed = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
            if (!(seedSpeed > 0)) continue;
            Trajectory line;
            double time = 0.0;
            for (int n = 0; n < s.maxPoints; ++n) {
                const double speed = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
                line.points.push_back(p);
                line.speed.push_back(speed);
                line.time.push_back(time);
                // A line that runs into a stagnation point ends there instead of crawling along the wall.
                if (speed < 0.01 * seedSpeed) break;
                const double dt = step / speed;
                FlowVolume::Point mid{p[0] + 0.5 * dt * v[0], p[1] + 0.5 * dt * v[1], p[2] + 0.5 * dt * v[2]}, vm{};
                if (!volume.sample(mid, vm)) break;
                const FlowVolume::Point next{p[0] + dt * vm[0], p[1] + dt * vm[1], p[2] + dt * vm[2]};
                FlowVolume::Point vn{};
                if (!volume.sample(next, vn)) break;
                p = next;
                v = vn;
                time += dt;
            }
            if (line.points.size() >= 4) out.push_back(std::move(line));
        }
    }
    return out;
}

namespace {

// One direction of a trajectory: points and speeds, and the time to each point from the start.
void integrate(const FlowVolume& volume, FlowVolume::Point p, double direction, double step, int maxPoints, std::vector<FlowVolume::Point>& points,
               std::vector<double>& speeds, std::vector<double>& times) {
    FlowVolume::Point v{};
    if (!volume.sample(p, v)) return;
    const double seedSpeed = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    double time = 0.0;
    for (int n = 0; n < maxPoints; ++n) {
        const double speed = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        points.push_back(p);
        speeds.push_back(speed);
        times.push_back(time);
        if (!(speed > 0.01 * seedSpeed)) break;
        const double dt = direction * step / speed;
        FlowVolume::Point mid{p[0] + 0.5 * dt * v[0], p[1] + 0.5 * dt * v[1], p[2] + 0.5 * dt * v[2]}, vm{};
        if (!volume.sample(mid, vm)) break;
        const FlowVolume::Point next{p[0] + dt * vm[0], p[1] + dt * vm[1], p[2] + dt * vm[2]};
        FlowVolume::Point vn{};
        if (!volume.sample(next, vn)) break;
        p = next;
        v = vn;
        time += std::fabs(dt);
    }
}

} // namespace

std::vector<Trajectory> traceThrough(const FlowVolume& volume, const std::vector<FlowVolume::Point>& seeds, double step, int maxPoints) {
    const auto& r = volume.region();
    const double length = std::max({r[1] - r[0], r[3] - r[2], r[5] - r[4]});
    if (!(step > 0)) step = length / 1500.0;
    std::vector<Trajectory> out;
    for (const auto& seed : seeds) {
        std::vector<FlowVolume::Point> back, ahead;
        std::vector<double> backSpeed, aheadSpeed, backTime, aheadTime;
        integrate(volume, seed, -1.0, step, maxPoints, back, backSpeed, backTime);
        integrate(volume, seed, 1.0, step, maxPoints, ahead, aheadSpeed, aheadTime);
        if (back.empty() || ahead.empty() || back.size() + ahead.size() < 5) continue;
        Trajectory line;
        const double start = backTime.back();
        for (std::size_t i = back.size(); i-- > 1;) { // the seed itself comes with the forward half
            line.points.push_back(back[i]);
            line.speed.push_back(backSpeed[i]);
            line.time.push_back(start - backTime[i]);
        }
        for (std::size_t i = 0; i < ahead.size(); ++i) {
            line.points.push_back(ahead[i]);
            line.speed.push_back(aheadSpeed[i]);
            line.time.push_back(start + aheadTime[i]);
        }
        out.push_back(std::move(line));
    }
    return out;
}

std::vector<VortexCore> findVortexCores(const FlowVolume& volume, double x, const std::array<double, 4>& w, int n, int count, double minimumFraction) {
    const double dy = (w[1] - w[0]) / (n - 1), dz = (w[3] - w[2]) / (n - 1);
    std::vector<FlowVolume::Point> field(static_cast<std::size_t>(n * n), {NAN, NAN, NAN});
    for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i) {
            FlowVolume::Point v{};
            if (volume.sample({x, w[0] + i * dy, w[2] + j * dz}, v)) field[static_cast<std::size_t>(j * n + i)] = v;
        }
    auto at = [&](int i, int j) -> const FlowVolume::Point& { return field[static_cast<std::size_t>(j * n + i)]; };
    std::vector<double> omega(static_cast<std::size_t>(n * n), 0.0);
    for (int j = 1; j + 1 < n; ++j)
        for (int i = 1; i + 1 < n; ++i) {
            const auto &e = at(i + 1, j), &west = at(i - 1, j), &north = at(i, j + 1), &south = at(i, j - 1);
            if (!std::isfinite(e[2]) || !std::isfinite(west[2]) || !std::isfinite(north[1]) || !std::isfinite(south[1])) continue;
            omega[static_cast<std::size_t>(j * n + i)] = (e[2] - west[2]) / (2 * dy) - (north[1] - south[1]) / (2 * dz);
        }
    std::vector<VortexCore> peaks;
    for (int j = 2; j + 2 < n; ++j)
        for (int i = 2; i + 2 < n; ++i) {
            const double value = std::fabs(omega[static_cast<std::size_t>(j * n + i)]);
            if (!(value > 0)) continue;
            bool maximum = true;
            for (int b = -2; b <= 2 && maximum; ++b)
                for (int a = -2; a <= 2; ++a)
                    if ((a || b) && std::fabs(omega[static_cast<std::size_t>((j + b) * n + i + a)]) > value) { maximum = false; break; }
            if (maximum) peaks.push_back({{x, w[0] + i * dy, w[2] + j * dz}, omega[static_cast<std::size_t>(j * n + i)]});
        }
    std::sort(peaks.begin(), peaks.end(), [](const VortexCore& a, const VortexCore& b) { return std::fabs(a.vorticity) > std::fabs(b.vorticity); });
    std::vector<VortexCore> out;
    const double separation = 0.1 * std::max(w[1] - w[0], w[3] - w[2]);
    for (const auto& peak : peaks) {
        if (static_cast<int>(out.size()) >= count) break;
        if (!out.empty() && std::fabs(peak.vorticity) < minimumFraction * std::fabs(out.front().vorticity)) break;
        bool apart = true;
        for (const auto& kept : out) apart = apart && std::hypot(peak.position[1] - kept.position[1], peak.position[2] - kept.position[2]) > separation;
        if (apart) out.push_back(peak);
    }
    return out;
}

} // namespace cadnext::cfd
