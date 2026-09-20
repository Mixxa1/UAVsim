#include "cadnext/em/Shielding.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace cadnext::em {

double waveguideCutoffHz(double widthM, double heightM) {
    const double longer = std::max(widthM, heightM);
    return longer > 0.0 ? kSpeedOfLightMps / (2.0 * longer) : 0.0;
}

double belowCutoffAttenuationNpPerM(double frequencyHz, double cutoffHz) {
    if (!(cutoffHz > 0.0) || frequencyHz >= cutoffHz) return 0.0;
    const double ratio = frequencyHz / cutoffHz;
    return 2.0 * M_PI * cutoffHz / kSpeedOfLightMps * std::sqrt(1.0 - ratio * ratio);
}

double shieldingEffectivenessDb(double incidentVm, double insideVm) {
    if (!(incidentVm > 0.0)) return 0.0;
    // Nothing at all inside is perfect shielding, not none: a sealed perfect box really does hold
    // the field to machine zero, and reporting that as 0 dB would be the quietest wrong answer here.
    if (!(insideVm > 0.0)) return std::numeric_limits<double>::infinity();
    return 20.0 * std::log10(incidentVm / insideVm);
}

namespace {

void markCell(const YeeGrid& grid, PecEdges& pec, int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz) return;
    pec.x[grid.index(i, j, k)] = 1;
    pec.x[grid.index(i, j + 1, k)] = 1;
    pec.x[grid.index(i, j, k + 1)] = 1;
    pec.x[grid.index(i, j + 1, k + 1)] = 1;
    pec.y[grid.index(i, j, k)] = 1;
    pec.y[grid.index(i + 1, j, k)] = 1;
    pec.y[grid.index(i, j, k + 1)] = 1;
    pec.y[grid.index(i + 1, j, k + 1)] = 1;
    pec.z[grid.index(i, j, k)] = 1;
    pec.z[grid.index(i + 1, j, k)] = 1;
    pec.z[grid.index(i, j + 1, k)] = 1;
    pec.z[grid.index(i + 1, j + 1, k)] = 1;
}

} // namespace

void markMetalCells(const YeeGrid& grid, PecEdges& pec, const CellBox& box, bool hollow, const std::vector<CellBox>& openings) {
    if (pec.x.size() != grid.nodes()) pec.clear(grid);
    for (int i = box.i0; i <= box.i1; ++i)
        for (int j = box.j0; j <= box.j1; ++j)
            for (int k = box.k0; k <= box.k1; ++k) {
                if (hollow && i > box.i0 && i < box.i1 && j > box.j0 && j < box.j1 && k > box.k0 && k < box.k1) continue;
                bool open = false;
                for (const auto& opening : openings) open = open || opening.contains(i, j, k);
                if (open) continue;
                markCell(grid, pec, i, j, k);
            }
}

void markMetalCells(const YeeGrid& grid, PecEdges& pec, const std::vector<std::uint8_t>& cells) {
    if (pec.x.size() != grid.nodes()) pec.clear(grid);
    const std::size_t count = static_cast<std::size_t>(grid.nx) * grid.ny * grid.nz;
    if (cells.size() != count) return;
    for (int i = 0; i < grid.nx; ++i)
        for (int j = 0; j < grid.ny; ++j)
            for (int k = 0; k < grid.nz; ++k)
                if (cells[(static_cast<std::size_t>(i) * grid.ny + j) * grid.nz + k]) markCell(grid, pec, i, j, k);
}

std::vector<std::uint8_t> voxelizeSurface(const YeeGrid& grid, const std::vector<std::array<double, 3>>& vertices,
                                          const std::vector<std::array<int, 3>>& triangles) {
    const std::size_t count = static_cast<std::size_t>(grid.nx) * grid.ny * grid.nz;
    std::vector<std::uint8_t> cells(count, 0);
    if (triangles.empty() || grid.nx <= 0) return cells;

    // One ray per column of cells, along x. Triangles are bucketed by the columns their (y, z)
    // footprint covers, so each ray only meets the triangles that can possibly stand in its way.
    std::vector<std::vector<int>> buckets(static_cast<std::size_t>(grid.ny) * grid.nz);
    auto columnOf = [&](int j, int k) { return static_cast<std::size_t>(j) * grid.nz + k; };
    for (std::size_t t = 0; t < triangles.size(); ++t) {
        const auto& tri = triangles[t];
        if (tri[0] < 0 || tri[1] < 0 || tri[2] < 0) continue;
        double yMin = 1e300, yMax = -1e300, zMin = 1e300, zMax = -1e300;
        for (int n = 0; n < 3; ++n) {
            const auto& v = vertices[static_cast<std::size_t>(tri[n])];
            yMin = std::min(yMin, v[1]), yMax = std::max(yMax, v[1]);
            zMin = std::min(zMin, v[2]), zMax = std::max(zMax, v[2]);
        }
        const int j0 = std::max(0, static_cast<int>(std::floor((yMin - grid.originY) / grid.cellM - 0.5)));
        const int j1 = std::min(grid.ny - 1, static_cast<int>(std::ceil((yMax - grid.originY) / grid.cellM - 0.5)));
        const int k0 = std::max(0, static_cast<int>(std::floor((zMin - grid.originZ) / grid.cellM - 0.5)));
        const int k1 = std::min(grid.nz - 1, static_cast<int>(std::ceil((zMax - grid.originZ) / grid.cellM - 0.5)));
        for (int j = j0; j <= j1; ++j)
            for (int k = k0; k <= k1; ++k) buckets[columnOf(j, k)].push_back(static_cast<int>(t));
    }

    std::vector<double> crossings;
    for (int j = 0; j < grid.ny; ++j)
        for (int k = 0; k < grid.nz; ++k) {
            const auto& bucket = buckets[columnOf(j, k)];
            if (bucket.empty()) continue;
            const double y = grid.originY + (j + 0.5) * grid.cellM;
            const double z = grid.originZ + (k + 0.5) * grid.cellM;
            crossings.clear();
            for (int index : bucket) {
                const auto& tri = triangles[static_cast<std::size_t>(index)];
                const auto& a = vertices[static_cast<std::size_t>(tri[0])];
                const auto& b = vertices[static_cast<std::size_t>(tri[1])];
                const auto& c = vertices[static_cast<std::size_t>(tri[2])];
                // Möller–Trumbore with the ray along +x through (y, z).
                const double e1[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
                const double e2[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
                // direction (1,0,0) × e2
                const double p[3] = {0.0 * e2[2] - 0.0 * e2[1], 0.0 * e2[0] - 1.0 * e2[2], 1.0 * e2[1] - 0.0 * e2[0]};
                const double determinant = e1[0] * p[0] + e1[1] * p[1] + e1[2] * p[2];
                if (std::fabs(determinant) < 1e-18) continue;
                const double inverse = 1.0 / determinant;
                const double s[3] = {0.0 - a[0], y - a[1], z - a[2]};
                const double u = (s[0] * p[0] + s[1] * p[1] + s[2] * p[2]) * inverse;
                if (u < 0.0 || u > 1.0) continue;
                const double q[3] = {s[1] * e1[2] - s[2] * e1[1], s[2] * e1[0] - s[0] * e1[2], s[0] * e1[1] - s[1] * e1[0]};
                const double v = q[0] * inverse; // direction (1,0,0) · q
                if (v < 0.0 || u + v > 1.0) continue;
                const double distance = (e2[0] * q[0] + e2[1] * q[1] + e2[2] * q[2]) * inverse;
                crossings.push_back(distance);
            }
            if (crossings.size() < 2) continue;
            std::sort(crossings.begin(), crossings.end());
            for (int i = 0; i < grid.nx; ++i) {
                const double x = grid.originX + (i + 0.5) * grid.cellM;
                const std::size_t before = static_cast<std::size_t>(std::lower_bound(crossings.begin(), crossings.end(), x) - crossings.begin());
                if (before % 2 == 1) cells[(static_cast<std::size_t>(i) * grid.ny + j) * grid.nz + k] = 1;
            }
        }
    return cells;
}

std::vector<RadiatedLevel> radiatedSusceptibilityLevels() {
    // MIL-STD-461G (11 Dec 2015), RS103 "Radiated susceptibility, electric field": the test runs
    // from 2 MHz to 18 GHz and the level depends on the platform. Only the three tiers the standard
    // writes out are here; which of them applies to a given programme is the procuring activity's
    // call, not this solver's.
    //
    // RTCA DO-160G §20 sets its levels by category in tables this project does not hold: нет данных,
    // so a DO-160 case is run by giving the field in volts per metre directly.
    return {
        {"mil461g-rs103-20", "MIL-STD-461G RS103, 20 В/м (внутренние отсеки самолёта, космос), 2 МГц – 18 ГГц", 2e6, 18e9, 20.0},
        {"mil461g-rs103-50", "MIL-STD-461G RS103, 50 В/м (наземная техника), 2 МГц – 18 ГГц", 2e6, 18e9, 50.0},
        {"mil461g-rs103-200", "MIL-STD-461G RS103, 200 В/м (внешние поверхности самолёта, палуба), 2 МГц – 18 ГГц", 2e6, 18e9, 200.0},
    };
}

const RadiatedLevel* radiatedLevel(const std::string& id) {
    static const std::vector<RadiatedLevel> levels = radiatedSusceptibilityLevels();
    for (const auto& level : levels)
        if (level.id == id) return &level;
    return nullptr;
}

} // namespace cadnext::em
