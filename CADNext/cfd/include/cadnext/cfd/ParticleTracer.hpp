#pragma once

#include <array>
#include <functional>
#include <random>
#include <vector>

// Particles carried by a planar velocity field, for showing a computed flow as flow.
//
// What a person reads from moving particles is where the air goes and how fast: slow in the wake,
// fast over the suction side, round and back in a separation bubble. That only works if the
// particles are an honest integration of the field — the same field the coefficients came from —
// and if nothing about the picture comes from the drawing: no fixed number of dots per precomputed
// line (which marches in visible diagonal bands), no restart when the field changes.
//
// So: particles are seeded at random along the inflow edge (and once over the whole region, so the
// first frame is not empty), advanced by the midpoint rule in sub-steps short enough never to jump a
// thin body, and removed when they reach a wall, leave the region or outlive a few transit times
// (air caught in a recirculation is recycled instead of piling up). The field is a function that
// may be swapped at any moment — a time-accurate run replaces it frame by frame — and particles keep
// going through the swap. Every particle carries a short trail of its own past positions.
//
// Coordinates are the section's own: x along the flow direction of the solver frame, z up, metres;
// velocities in m/s; time in physical seconds.

namespace cadnext::cfd {

struct ParticleTracerSettings {
    std::array<double, 4> region{};  // xMin, xMax, zMin, zMax
    int particles = 600;
    double trailSeconds = 0.0;       // physical time a trail spans; 0 = no trail
    int trailSamples = 10;
    // Longest distance a particle moves in one sub-step, as a fraction of the region's width. Small
    // enough that a sub-step cannot cross a thin body without the sampler seeing solid in between.
    double maxStepFraction = 0.002;
    // Particles older than this many region transits at the reference speed are recycled.
    double lifetimeTransits = 3.0;
    double referenceSpeed = 1.0;     // m/s, sets the lifetime
    unsigned seed = 1;
};

class ParticleTracer {
public:
    // Velocity (u along x, w along z, and the full speed including the out-of-plane part) at a
    // point; false where there is no fluid (inside a body, outside the mesh, off the region).
    using Sampler = std::function<bool(double x, double z, double& u, double& w, double& speed)>;

    struct Particle {
        std::array<double, 2> position{};
        std::vector<std::array<double, 2>> trail; // oldest first, the particle's own position last
        double speed = 0.0;
        double age = 0.0;
        double sinceTrailSample = 0.0;
    };

    explicit ParticleTracer(ParticleTracerSettings settings);

    // Installs a field. The first call seeds the region; later calls keep the particles moving.
    void setSampler(Sampler sampler);
    void advance(double seconds);

    const std::vector<Particle>& particles() const { return particles_; }
    const ParticleTracerSettings& settings() const { return settings_; }
    // Particles that reached a wall, left the region or aged out, since construction.
    long recycled() const { return recycled_; }

private:
    bool velocity(double x, double z, double& u, double& w, double& speed) const;
    void spawn(Particle& particle, bool anywhere);
    bool step(Particle& particle, double seconds);

    ParticleTracerSettings settings_;
    Sampler sampler_;
    std::vector<Particle> particles_;
    std::mt19937 random_;
    bool inflowAtMinX_ = true;
    long recycled_ = 0;
};

} // namespace cadnext::cfd
