#include "cadnext/cfd/FlatPlate.hpp"

#include <cmath>

namespace cadnext::cfd {

namespace {

// Geometric distribution on [0, 1] with n cells, last/first cell ratio `stretch`; η = i/n.
double clustered(double eta, int n, double stretch) {
    if (stretch <= 1.0 + 1e-12) return eta;
    // Continuous exponential map, independent of n at fixed η, which keeps every level one family: the
    // local spacing grows by `stretch` from η = 0 to η = 1.
    (void)n;
    const double b = std::log(stretch);
    return (std::exp(b * eta) - 1.0) / (std::exp(b) - 1.0);
}

} // namespace

Su2Mesh flatPlateMesh(const FlatPlateMeshSpec& spec) {
    std::vector<double> xs, ys;
    // Upstream: clustered toward x = 0 (mirror of the plate distribution), plate: clustered at x = 0.
    for (int i = 0; i < spec.upstreamCells; ++i) {
        const double eta = static_cast<double>(spec.upstreamCells - i) / spec.upstreamCells;
        xs.push_back(-spec.upstream * clustered(eta, spec.upstreamCells, spec.upstreamStretch));
    }
    for (int i = 0; i <= spec.plateCells; ++i) {
        xs.push_back(spec.length * clustered(static_cast<double>(i) / spec.plateCells, spec.plateCells, spec.leadingEdgeStretch));
    }
    for (int j = 0; j <= spec.normalCells; ++j) {
        ys.push_back(spec.height * clustered(static_cast<double>(j) / spec.normalCells, spec.normalCells, spec.wallStretch));
    }
    const int nx = static_cast<int>(xs.size());
    const int ny = static_cast<int>(ys.size());
    Su2Mesh mesh;
    mesh.dimension = 2;
    auto index = [&](int i, int j) { return j * nx + i; };
    for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) mesh.points.push_back({xs[i], ys[j], 0.0});
    for (int j = 0; j + 1 < ny; ++j)
        for (int i = 0; i + 1 < nx; ++i)
            mesh.elements.push_back({Su2ElementType::Quadrilateral, {index(i, j), index(i + 1, j), index(i + 1, j + 1), index(i, j + 1)}});
    std::vector<Su2Element> inlet, outlet, symmetry, wall, farfield;
    for (int j = 0; j + 1 < ny; ++j) {
        inlet.push_back({Su2ElementType::Line, {index(0, j + 1), index(0, j)}});
        outlet.push_back({Su2ElementType::Line, {index(nx - 1, j), index(nx - 1, j + 1)}});
    }
    for (int i = 0; i + 1 < nx; ++i) {
        auto& bottom = i < spec.upstreamCells ? symmetry : wall;
        bottom.push_back({Su2ElementType::Line, {index(i, 0), index(i + 1, 0)}});
        farfield.push_back({Su2ElementType::Line, {index(i + 1, ny - 1), index(i, ny - 1)}});
    }
    mesh.markers = {{"inlet", inlet}, {"outlet", outlet}, {"symmetry", symmetry}, {"wall", wall}, {"farfield", farfield}};
    return mesh;
}

} // namespace cadnext::cfd
