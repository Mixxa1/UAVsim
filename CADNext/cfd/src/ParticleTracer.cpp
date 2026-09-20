#include "cadnext/cfd/ParticleTracer.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::cfd {

namespace {

double width(const ParticleTracerSettings& s) { return s.region[1] - s.region[0]; }
double height(const ParticleTracerSettings& s) { return s.region[3] - s.region[2]; }

} // namespace

ParticleTracer::ParticleTracer(ParticleTracerSettings settings) : settings_(settings), random_(settings.seed) {}

bool ParticleTracer::velocity(double x, double z, double& u, double& w, double& speed) const {
    const auto& r = settings_.region;
    if (!sampler_ || x < r[0] || x > r[1] || z < r[2] || z > r[3]) return false;
    return sampler_(x, z, u, w, speed) && std::isfinite(u) && std::isfinite(w);
}

void ParticleTracer::setSampler(Sampler sampler) {
    sampler_ = std::move(sampler);
    // Which edge the air comes in through: the sign of the mean streamwise velocity over a vertical
    // line just inside each end of the region.
    double upstream = 0.0;
    for (int i = 0; i <= 40; ++i) {
        const double z = settings_.region[2] + height(settings_) * i / 40.0;
        for (double x : {settings_.region[0] + 0.02 * width(settings_), settings_.region[1] - 0.02 * width(settings_)}) {
            double u = 0, w = 0, speed = 0;
            if (velocity(x, z, u, w, speed)) upstream += u;
        }
    }
    inflowAtMinX_ = upstream >= 0.0;
    if (particles_.empty()) {
        particles_.resize(static_cast<std::size_t>(std::max(settings_.particles, 0)));
        const double lifetime = settings_.lifetimeTransits * width(settings_) / std::max(settings_.referenceSpeed, 1e-9);
        std::uniform_real_distribution<double> age(0.0, lifetime);
        for (auto& particle : particles_) {
            spawn(particle, true);
            particle.age = age(random_);
        }
    }
}

void ParticleTracer::spawn(Particle& particle, bool anywhere) {
    std::uniform_real_distribution<double> unit(0.0, 1.0);
    const auto& r = settings_.region;
    const double reach = settings_.maxStepFraction * width(settings_);
    for (int attempt = 0; attempt < 40; ++attempt) {
        // Along the inflow edge the spawn depth is spread over a few steps, so fresh particles enter
        // as a scatter rather than a line that marches across the picture in step.
        const double x = anywhere ? r[0] + width(settings_) * unit(random_)
                                  : (inflowAtMinX_ ? r[0] + 8.0 * reach * unit(random_) : r[1] - 8.0 * reach * unit(random_));
        const double z = r[2] + height(settings_) * unit(random_);
        double u = 0, w = 0, speed = 0;
        if (!velocity(x, z, u, w, speed)) continue;
        particle.position = {x, z};
        particle.speed = speed;
        particle.age = 0.0;
        particle.sinceTrailSample = 0.0;
        particle.trail.clear();
        return;
    }
    // No fluid found (an empty field): park the particle; it is retried on the next advance.
    particle.position = {NAN, NAN};
    particle.trail.clear();
}

bool ParticleTracer::step(Particle& particle, double seconds) {
    if (!std::isfinite(particle.position[0])) return false;
    const double maxStep = settings_.maxStepFraction * width(settings_);
    const double trailInterval = settings_.trailSamples > 0 ? settings_.trailSeconds / settings_.trailSamples : 0.0;
    double remaining = seconds;
    for (int subStep = 0; remaining > 0.0 && subStep < 2000; ++subStep) {
        auto& p = particle.position;
        double u = 0, w = 0, speed = 0;
        if (!velocity(p[0], p[1], u, w, speed)) return false;
        const double planar = std::hypot(u, w);
        const double dt = planar > 1e-12 ? std::min(remaining, maxStep / planar) : remaining;
        // Midpoint rule: second order, and the midpoint sample is a second chance to notice a wall.
        double um = 0, wm = 0, speedMid = 0;
        if (!velocity(p[0] + 0.5 * dt * u, p[1] + 0.5 * dt * w, um, wm, speedMid)) return false;
        const std::array<double, 2> next{p[0] + dt * um, p[1] + dt * wm};
        double ue = 0, we = 0, speedEnd = 0;
        if (!velocity(next[0], next[1], ue, we, speedEnd)) return false;
        p = next;
        particle.speed = speedEnd;
        particle.age += dt;
        remaining -= dt;
        if (trailInterval > 0.0) {
            particle.sinceTrailSample += dt;
            if (particle.sinceTrailSample >= trailInterval) {
                particle.sinceTrailSample = 0.0;
                particle.trail.push_back(p);
                if (particle.trail.size() > static_cast<std::size_t>(settings_.trailSamples)) particle.trail.erase(particle.trail.begin());
            }
        }
    }
    return true;
}

void ParticleTracer::advance(double seconds) {
    if (!sampler_ || !(seconds > 0.0)) return;
    const double lifetime = settings_.lifetimeTransits * width(settings_) / std::max(settings_.referenceSpeed, 1e-9);
    for (auto& particle : particles_) {
        if (!step(particle, seconds) || particle.age > lifetime) {
            ++recycled_;
            spawn(particle, false);
        }
    }
}

} // namespace cadnext::cfd
