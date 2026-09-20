// Flow animation core: particles carried by a planar field, a section whose velocity can be replaced
// without re-reading the mesh, and time frames reduced to that section.
//
// Everything is checked against fields with a known answer: particles in a uniform stream move by
// exactly U·t (the midpoint rule is exact for it), particles in solid-body rotation keep their radius
// (second order: the drift after a full turn is bounded by the step), no particle is ever inside a
// body, particles keep their positions when the field is swapped, and a frame read back equals the
// frame written.

#include "fea_test_support.hpp"

#include "cadnext/cfd/FlowSection.hpp"
#include "cadnext/cfd/FlowVolume.hpp"
#include "cadnext/cfd/ParticleTracer.hpp"
#include "cadnext/cfd/SectionFrames.hpp"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <random>
#include <sstream>
#include <unistd.h>

using namespace cadnext::cfd;
using fea_test::check;

namespace {

// A box [0, 2] × [0, 1] × [0, 1] of n × n × n hexahedra, each split into two prisms (the fluid mesh
// type nearest a wall), minus the hexahedra whose centre lies in `hole`; the hole's faces are a wall.
std::string boxMesh(int n, std::array<double, 6> hole) {
    auto id = [n](int i, int j, int k) { return (k * (n + 1) + j) * (n + 1) + i; };
    auto centreIn = [&](int i, int j, int k) {
        const double x = 2.0 * (i + 0.5) / n, y = (j + 0.5) / n, z = (k + 0.5) / n;
        return x > hole[0] && x < hole[1] && y > hole[2] && y < hole[3] && z > hole[4] && z < hole[5];
    };
    std::ostringstream cells, wall;
    int cellCount = 0, wallCount = 0;
    for (int k = 0; k < n; ++k) for (int j = 0; j < n; ++j) for (int i = 0; i < n; ++i) {
        if (centreIn(i, j, k)) {
            // Faces towards fluid neighbours become wall quads.
            const int d[6][3] = {{-1,0,0},{1,0,0},{0,-1,0},{0,1,0},{0,0,-1},{0,0,1}};
            for (auto& o : d) {
                const int a = i + o[0], b = j + o[1], c = k + o[2];
                if (a < 0 || b < 0 || c < 0 || a >= n || b >= n || c >= n || centreIn(a, b, c)) continue;
                ++wallCount;
                wall << "9 " << id(i, j, k) << " " << id(i + 1, j, k) << " " << id(i + 1, j + 1, k) << " " << id(i, j + 1, k) << "\n";
            }
            continue;
        }
        const int a = id(i, j, k), b = id(i + 1, j, k), c = id(i + 1, j + 1, k), d = id(i, j + 1, k);
        const int up = (n + 1) * (n + 1);
        cells << "13 " << a << " " << b << " " << c << " " << a + up << " " << b + up << " " << c + up << " " << cellCount++ << "\n";
        cells << "13 " << a << " " << c << " " << d << " " << a + up << " " << c + up << " " << d + up << " " << cellCount++ << "\n";
    }
    std::ostringstream mesh;
    mesh << "NDIME= 3\nNELEM= " << cellCount << "\n" << cells.str() << "NPOIN= " << (n + 1) * (n + 1) * (n + 1) << "\n";
    for (int k = 0; k <= n; ++k) for (int j = 0; j <= n; ++j) for (int i = 0; i <= n; ++i)
        mesh << 2.0 * i / n << " " << double(j) / n << " " << double(k) / n << " " << id(i, j, k) << "\n";
    mesh << "NMARK= 1\nMARKER_TAG= body_0\nMARKER_ELEMS= " << wallCount << "\n" << wall.str();
    return mesh.str();
}

} // namespace

int main() {
    // Uniform stream: every particle that was not recycled moved by exactly (U·t, 0).
    {
        ParticleTracerSettings settings;
        settings.region = {0.0, 10.0, 0.0, 1.0};
        settings.particles = 200;
        settings.referenceSpeed = 2.0;
        ParticleTracer tracer(settings);
        tracer.setSampler([](double, double, double& u, double& w, double& speed) { u = 2.0; w = 0.0; speed = 2.0; return true; });
        const auto before = tracer.particles();
        tracer.advance(0.1);
        int moved = 0, exact = 0;
        for (std::size_t i = 0; i < before.size(); ++i) {
            const auto& after = tracer.particles()[i];
            if (after.age < 0.1 - 1e-12) continue; // recycled during this step
            ++moved;
            if (std::fabs(after.position[0] - before[i].position[0] - 0.2) < 1e-12 && std::fabs(after.position[1] - before[i].position[1]) < 1e-15) ++exact;
        }
        check(moved > 100 && exact == moved, "uniform stream: displacement is exactly U·t", std::to_string(exact) + "/" + std::to_string(moved));
        for (int i = 0; i < 200; ++i) tracer.advance(0.05);
        check(tracer.recycled() > 0, "particles leaving the outlet are recycled");
        bool entered = true;
        for (const auto& p : tracer.particles()) entered = entered && p.position[0] >= 0.0 && p.position[0] <= 10.0;
        check(entered, "recycled particles re-enter inside the region");
    }

    // Solid-body rotation about (0, 0): the radius is an invariant.
    {
        ParticleTracerSettings settings;
        settings.region = {-1.0, 1.0, -1.0, 1.0};
        settings.particles = 50;
        settings.maxStepFraction = 0.002;
        settings.lifetimeTransits = 1e9; // keep every particle for the whole turn
        ParticleTracer tracer(settings);
        const double omega = 2.0 * M_PI;
        tracer.setSampler([omega](double x, double z, double& u, double& w, double& speed) {
            if (x * x + z * z > 0.81) return false; // stay clear of the corners
            u = -omega * z; w = omega * x; speed = omega * std::hypot(x, z);
            return true;
        });
        std::vector<double> radius;
        for (const auto& p : tracer.particles()) radius.push_back(std::hypot(p.position[0], p.position[1]));
        tracer.advance(1.0); // one full turn
        double worst = 0.0;
        for (std::size_t i = 0; i < radius.size(); ++i) {
            worst = std::max(worst, std::fabs(std::hypot(tracer.particles()[i].position[0], tracer.particles()[i].position[1]) - radius[i]));
        }
        std::printf("  rotation: worst radius drift after one turn %.2e\n", worst);
        check(worst < 2e-3, "rotation: radius kept to the step size over a full turn");
    }

    // A disc of solid in a stream: no particle is ever inside it, and the ones that hit it are recycled.
    {
        ParticleTracerSettings settings;
        settings.region = {0.0, 4.0, -1.0, 1.0};
        settings.particles = 400;
        settings.trailSeconds = 0.2;
        settings.trailSamples = 8;
        ParticleTracer tracer(settings);
        auto solid = [](double x, double z) { return std::hypot(x - 2.0, z) < 0.3; };
        tracer.setSampler([&](double x, double z, double& u, double& w, double& speed) {
            if (solid(x, z)) return false;
            u = 1.0; w = 0.0; speed = 1.0;
            return true;
        });
        bool clear = true;
        for (int i = 0; i < 400; ++i) {
            tracer.advance(0.02);
            for (const auto& p : tracer.particles()) {
                clear = clear && !solid(p.position[0], p.position[1]);
                for (const auto& t : p.trail) clear = clear && !solid(t[0], t[1]);
            }
        }
        check(clear, "no particle or trail point is ever inside the body");
        std::size_t trails = 0;
        for (const auto& p : tracer.particles()) trails = std::max(trails, p.trail.size());
        check(trails == 8, "trails hold the requested number of past positions");

        // A new field keeps every particle where it is.
        const auto before = tracer.particles();
        tracer.setSampler([](double, double, double& u, double& w, double& speed) { u = -1.0; w = 0.0; speed = 1.0; return true; });
        bool kept = true;
        for (std::size_t i = 0; i < before.size(); ++i) kept = kept && before[i].position == tracer.particles()[i].position;
        check(kept, "swapping the field does not restart the particles");
        // The stream now runs towards −x: fresh particles must come in from the +x edge.
        for (int i = 0; i < 400; ++i) tracer.advance(0.02);
        int nearOutletEdge = 0, young = 0;
        for (const auto& p : tracer.particles()) {
            if (p.age > 0.05) continue;
            ++young;
            if (p.position[0] > 3.8) ++nearOutletEdge;
        }
        check(young > 0 && nearOutletEdge == young, "fresh particles enter through the upstream edge of the new field");
    }

    // A section's velocity refreshed from its nodes equals a section read with that velocity.
    {
        const std::string meshText = "NDIME= 3\nNELEM= 1\n10 0 1 2 3 0\nNPOIN= 4\n0 -1 0 0\n2 -1 0 1\n0 -1 2 2\n0 1 0 3\nNMARK= 0\n";
        std::istringstream first(meshText), second(meshText);
        auto section = FlowSection::read(first, {{-1, 0, 0}, {-1, 0, 1}, {-1, 0, 2}, {0, 0, 0}}, 0, {-1, 3, -1, 3});
        const std::vector<FlowSection::Vector> field{{2, 0, 0}, {4, 0, 1}, {2, 0, 3}, {0, 0, 5}};
        const auto direct = FlowSection::read(second, field, 0, {-1, 3, -1, 3});
        std::vector<FlowSection::Vector> compact;
        for (auto node : section.referencedNodes()) compact.push_back(field[node]);
        section.refresh(compact);
        FlowSection::Vector a{}, b{};
        check(section.sample(0.4, 0.3, a) && direct.sample(0.4, 0.3, b) && a == b, "refresh gives the same field as reading with it");
        std::istringstream third(meshText);
        std::vector<FlowSection::Vector> sparse(4, {NAN, NAN, NAN});
        for (auto node : section.referencedNodes()) sparse[node] = field[node];
        bool readSparse = true;
        try { FlowSection::read(third, sparse, 0, {-1, 3, -1, 3}); } catch (const std::exception&) { readSparse = false; }
        check(readSparse, "nodes the cut does not use may be missing from the field");
        bool refused = false;
        try { section.refresh({{1, 0, 0}}); } catch (const std::exception&) { refused = true; }
        check(refused, "a frame of the wrong size is refused");
    }

    // A volume frame reduced to a section and read back.
    {
        namespace fs = std::filesystem;
        const auto root = fs::temp_directory_path() / ("cfd-frames-" + std::to_string(getpid()));
        fs::create_directories(root);
        {
            std::ofstream volume(root / "volume_00007.csv");
            volume << "\"PointID\",\"x\",\"y\",\"z\",\"Pressure\",\"Velocity_x\",\"Velocity_y\",\"Velocity_z\"\n";
            for (int id = 0; id < 10; ++id) volume << id << ",0,0,0,1," << id + 0.5 << "," << -id << "," << 2 * id << "\n";
        }
        // The solver reduces its frames to sectionNodes() over the whole mesh; the window cuts only its
        // region. Both must name the same nodes, or no frame could ever be played.
        {
            const std::string meshText = "NDIME= 3\nNELEM= 2\n10 0 1 2 3 0\n10 1 2 3 4 1\nNPOIN= 5\n0 -1 0 0\n2 -1 0 1\n0 -1 2 2\n0 1 0 3\n40 1 30 4\nNMARK= 0\n";
            { std::ofstream mesh(root / "mesh.su2"); mesh << meshText; }
            const auto solverNodes = sectionNodes((root / "mesh.su2").string(), 0.0);
            std::istringstream stream(meshText);
            const auto windowCut = FlowSection::read(stream, std::vector<FlowSection::Vector>(5, {1, 0, 0}), 0.0, {-0.5, 1.5, -0.5, 1.5});
            check(solverNodes.isOk() && solverNodes.value() == windowCut.referencedNodes(),
                  "the solver and the window cut the same nodes whatever region the window shows");
        }
        const std::vector<std::size_t> nodes{7, 2, 5};
        check(writeSectionFrame((root / "volume_00007.csv").string(), nodes, (root / "section_00007.csv").string()).isOk(), "frame reduced to the section");
        const auto frame = readSectionFrame((root / "section_00007.csv").string(), nodes);
        check(frame.isOk() && frame.value()[0] == FlowSection::Vector{7.5, -7, 14} && frame.value()[1] == FlowSection::Vector{2.5, -2, 4},
              "section frame reads back in the section's node order");
        check(!readSectionFrame((root / "section_00007.csv").string(), {7, 2, 11}).isOk(), "a frame that misses a node of the section is refused");
        check(!writeSectionFrame((root / "volume_00007.csv").string(), {3, 42}, (root / "bad.csv").string()).isOk(),
              "a volume frame without a section node (still being written) is refused");
        fs::remove_all(root);
    }
    // The volume field: a linear velocity is reproduced exactly inside every cell, a uniform stream
    // gives straight trajectories timed at U, and nothing is ever sampled inside a body.
    {
        const int n = 8;
        const std::array<double, 6> hole{0.75, 1.25, 0.375, 0.625, 0.375, 0.625};
        const std::string text = boxMesh(n, hole);
        std::vector<FlowVolume::Point> linear;
        for (int k = 0; k <= n; ++k) for (int j = 0; j <= n; ++j) for (int i = 0; i <= n; ++i) {
            const double x = 2.0 * i / n, y = double(j) / n, z = double(k) / n;
            linear.push_back({1.0 + 0.5 * x, 0.2 * y, -0.1 * z});
        }
        std::istringstream mesh(text);
        const auto volume = FlowVolume::read(mesh, linear, {0, 2, 0, 1, 0, 1});
        std::mt19937 random(3);
        std::uniform_real_distribution<double> u(0.0, 1.0);
        int sampled = 0, exact = 0, insideBody = 0;
        for (int i = 0; i < 2000; ++i) {
            const FlowVolume::Point p{2.0 * u(random), u(random), u(random)};
            FlowVolume::Point v{};
            const bool inHole = p[0] > hole[0] && p[0] < hole[1] && p[1] > hole[2] && p[1] < hole[3] && p[2] > hole[4] && p[2] < hole[5];
            if (!volume.sample(p, v)) continue;
            if (inHole) ++insideBody;
            ++sampled;
            if (std::fabs(v[0] - (1.0 + 0.5 * p[0])) < 1e-12 && std::fabs(v[1] - 0.2 * p[1]) < 1e-12 && std::fabs(v[2] + 0.1 * p[2]) < 1e-12) ++exact;
        }
        check(sampled > 1800 && exact == sampled, "volume: a linear field is reproduced exactly", std::to_string(exact) + "/" + std::to_string(sampled));
        check(insideBody == 0, "volume: no value inside the body");
        // The hole is 2 × 2 × 2 hexahedra: 24 exposed quads, two triangles each.
        check(volume.walls().size() == 48u, "volume: the body's faces are kept as wall triangles (two per quad)");

        std::vector<FlowVolume::Point> uniform(linear.size(), {2.0, 0.0, 0.0});
        std::istringstream again(text);
        const auto stream = FlowVolume::read(again, uniform, {0, 2, 0, 1, 0, 1});
        TrajectorySettings rake;
        rake.rakeX = 0.05;
        rake.rakeSpan = {0.05, 0.95, 0.05, 0.95};
        rake.columns = 6;
        rake.rows = 6;
        const auto lines = traceTrajectories(stream, rake);
        bool straight = true, timed = true, clear = true;
        int blocked = 0;
        for (const auto& line : lines) {
            const auto& first = line.points.front();
            const auto& last = line.points.back();
            for (const auto& p : line.points) {
                straight = straight && std::fabs(p[1] - first[1]) < 1e-12 && std::fabs(p[2] - first[2]) < 1e-12;
                clear = clear && !(p[0] > hole[0] && p[0] < hole[1] && p[1] > hole[2] && p[1] < hole[3] && p[2] > hole[4] && p[2] < hole[5]);
            }
            timed = timed && std::fabs(line.time.back() - (last[0] - first[0]) / 2.0) < 1e-9;
            if (last[0] < 1.9) ++blocked;
        }
        check(lines.size() == 36 && straight, "uniform stream: every trajectory is a straight line");
        check(timed, "trajectory time is distance over speed");
        check(clear && blocked > 0, "trajectories stop at the body instead of passing through it");
    }
    // A stream-wise vortex: its core is found where it is, and a trajectory through a point beside it
    // runs the whole box and turns about the core at the rate the field says. The field is only known
    // at the nodes and interpolated linearly in between, so on a coarse mesh the swirl is slightly
    // off; the check is that this error falls at the second order of the interpolation when the mesh
    // is halved, not a tolerance picked to pass.
    {
        const double yc = 0.5, zc = 0.5, rc = 0.12, circulation = 1.0, axial = 2.0, radius = 0.15;
        auto swirlOver = [&](double r2) { return r2 > 0 ? circulation / (2 * M_PI * r2) * (1 - std::exp(-r2 / (rc * rc))) : 0.0; };
        std::vector<double> errors;
        bool found = true, whole = true, monotonic = true;
        for (int n : {16, 32}) {
            std::vector<FlowVolume::Point> vortex;
            for (int k = 0; k <= n; ++k) for (int j = 0; j <= n; ++j) for (int i = 0; i <= n; ++i) {
                const double y = double(j) / n - yc, z = double(k) / n - zc, swirl = swirlOver(y * y + z * z);
                vortex.push_back({axial, -swirl * z, swirl * y});
            }
            std::istringstream mesh(boxMesh(n, {9, 9, 9, 9, 9, 9}));
            const auto volume = FlowVolume::read(mesh, vortex, {0, 2, 0, 1, 0, 1});
            const auto cores = findVortexCores(volume, 1.0, {0.05, 0.95, 0.05, 0.95});
            found = found && !cores.empty() && std::hypot(cores[0].position[1] - yc, cores[0].position[2] - zc) < 1.5 / n && cores[0].vorticity > 0;
            const auto lines = traceThrough(volume, {{1.0, yc + radius, zc}});
            if (lines.size() != 1) { whole = false; continue; }
            const auto& line = lines[0];
            whole = whole && line.points.front()[0] < 0.05 && line.points.back()[0] > 1.95;
            for (std::size_t i = 1; i < line.time.size(); ++i) monotonic = monotonic && line.time[i] > line.time[i - 1];
            const auto& a = line.points.front();
            const auto& b = line.points.back();
            double turned = std::atan2(b[2] - zc, b[1] - yc) - std::atan2(a[2] - zc, a[1] - yc);
            while (turned < 0) turned += 2 * M_PI;
            const double expected = std::fmod(swirlOver(radius * radius) * line.time.back(), 2 * M_PI);
            std::printf("  vortex, %d cells across: turned %.4f rad, field says %.4f rad\n", n, turned, expected);
            errors.push_back(std::fabs(turned - expected));
        }
        check(found, "vortex core found within a cell of where it is, with the right sense of rotation");
        check(whole && monotonic, "a trajectory through a point spans the box and runs forward in time");
        check(errors.size() == 2 && errors[1] < errors[0] / 2.5, "the swirl error falls with the mesh at the interpolation's order");
    }
    return fea_test::finish("test_cfd_particles");
}
