#pragma once

#include <array>
#include <cstdint>
#include <istream>
#include <random>
#include <vector>

// The computed velocity field in three dimensions, for drawing flow trajectories around the body —
// the lines and arrows a person expects from a flow simulation, taken from the actual solution.
//
// The volume mesh SU2 solved on is kept as tetrahedra (prisms split in three, pyramids in two, which
// preserves every cell's volume), restricted to a region around the body and indexed by a uniform
// grid of bins. Velocity at a point is the linear interpolation inside the tetrahedron that contains
// it — the solver's own nodal values, nothing smoothed or invented; outside the fluid (inside a body,
// beyond the region) there is no value.
//
// Trajectories start on a rake — a grid of seeds on a plane across the stream, upstream of the body —
// and follow the steady field with the midpoint rule; each point carries the physical time at which a
// particle released at the rake arrives there, so arrows can move along the lines at the computed
// speed.
//
// Coordinates and velocities are in the solver frame (x aft, y right, z up), metres and m/s.

namespace cadnext::cfd {

class FlowVolume {
public:
    using Point = std::array<double, 3>;

    // Reads an SU2 mesh and the velocity at its nodes (m/s; nodes outside the region may be NaN),
    // keeping the cells that reach into `region` (xMin, xMax, yMin, yMax, zMin, zMax).
    static FlowVolume read(std::istream& mesh, const std::vector<Point>& velocity, const std::array<double, 6>& region);

    // Velocity at p; false outside the fluid or the region.
    bool sample(const Point& p, Point& velocity) const;

    const std::array<double, 6>& region() const { return region_; }
    std::size_t tetrahedra() const { return tets_.size(); }
    // Wall triangles of the mesh (every marker except the far field), for drawing the body.
    const std::vector<std::array<Point, 3>>& walls() const { return walls_; }

private:
    bool inside(std::uint32_t tet, const Point& p, std::array<double, 4>& weights) const;
    std::size_t bin(int ix, int iy, int iz) const { return (static_cast<std::size_t>(iz) * bins_[1] + iy) * bins_[0] + ix; }

    std::array<double, 6> region_{};
    std::vector<Point> points_;
    std::vector<Point> velocity_;
    std::vector<std::array<std::uint32_t, 4>> tets_;
    std::array<int, 3> bins_{1, 1, 1};
    std::vector<std::uint32_t> binStart_, binTets_;
    std::vector<std::array<Point, 3>> walls_;
    mutable std::uint32_t lastTet_ = 0;
};

struct Trajectory {
    std::vector<FlowVolume::Point> points;
    std::vector<double> speed; // m/s at each point
    std::vector<double> time;  // s since the seed, at each point
};

struct TrajectorySettings {
    // Rake: a rectangle on the plane x = rakeX, `columns` × `rows` seeds over [y0, y1] × [z0, z1].
    double rakeX = 0.0;
    std::array<double, 4> rakeSpan{}; // y0, y1, z0, z1
    int columns = 24, rows = 8;
    // Seeds are moved at random within their cell of the rake, so the lines are not a lattice.
    bool jitter = true;
    unsigned seed = 7;
    double step = 0.0;   // integration step, metres; 0: 1/1500 of the region's length
    int maxPoints = 4000;
};

std::vector<Trajectory> traceTrajectories(const FlowVolume& volume, const TrajectorySettings& settings);

// Trajectories through given points: integrated upstream until they leave the fluid and downstream
// likewise, joined, and timed from their upstream end — the whole path of the air that passes there.
std::vector<Trajectory> traceThrough(const FlowVolume& volume, const std::vector<FlowVolume::Point>& points, double step = 0.0,
                                     int maxPoints = 4000);

// Cores of the stream-wise vortices crossing the plane x = `x` inside [y0, y1] × [z0, z1]: local
// maxima of |ω_x| = |∂w/∂y − ∂v/∂z| on a grid of `resolution` × `resolution`, strongest first, at
// most `count`, no two closer than a tenth of the window, and none weaker than `minimumFraction` of
// the strongest. A lifting surface sheds one from each tip; this is where trajectories that show the
// roll-up have to pass.
struct VortexCore {
    FlowVolume::Point position;
    double vorticity; // 1/s, signed
};
std::vector<VortexCore> findVortexCores(const FlowVolume& volume, double x, const std::array<double, 4>& window, int resolution = 80,
                                        int count = 4, double minimumFraction = 0.25);

} // namespace cadnext::cfd
