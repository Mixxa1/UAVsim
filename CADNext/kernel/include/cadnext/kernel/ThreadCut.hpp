#pragma once

#include "cadnext/Vector3.hpp"

// A screw thread cut into a body with real turns: the thread's groove — its basic profile in an
// axial half-plane — swept by screw motion and taken away from the body. Geometry only; which
// standard, size and pitch is the caller's (cadnext/Thread.hpp).
//
// The sweep follows a helix with a fixed binormal (the axis): along a helix those frames differ by the
// screw motion itself, so the axial profile is carried without distortion. Its B-spline surfaces are
// built to 1e-8 m and measured afterwards against the profile (every sampled point carried back by the
// screw motion to the start plane): refused beyond 1e-6 m, as the approximated blends of an import are.

namespace cadnext::kernel {

enum class ThreadProfileKind {
    // ISO 68-1 / ASME B1.1 basic profile: 60°, flat crest P/8 and root P/4 (metric, UNC/UNF).
    Metric60,
    // ISO 228-1 / ISO 7-1 (Whitworth): 55°, h = 0.640327P, crest and root rounded r = 0.137329P
    // (parallel) or 0.137278P (taper, ISO 7-1: tangent to its cones).
    Whitworth55,
    // ASME B1.20.1 (NPT): 60°, h = 0.8P, flats at crest and root.
    Npt60,
};

struct ThreadCutParameters {
    cadnext::Vector3 axisOrigin;    // a point of the thread axis, m
    cadnext::Vector3 axisDirection; // the way the thread runs from its start
    double start = 0.0;             // axial position of the thread's start, m, measured along the direction
    double length = 0.0;            // axial length of the full thread, m
    double majorDiameter = 0.0;     // m; of a taper thread, at the start
    double pitch = 0.0;             // m
    ThreadProfileKind profile = ThreadProfileKind::Metric60;
    bool internal = false;          // in a hole's wall (cut outward) or on a shaft (cut inward)
    bool rightHanded = true;
    // Diameter change per unit of axial length, growing along the direction (1/16 for NPT and R);
    // 0 for a parallel thread.
    double taper = 0.0;
    // The groove runs a pitch past the start / the end, so that the thread leaves the body through its
    // end face cleanly rather than stopping at a profile plane inside it.
    bool runOutAtStart = false;
    bool runOutAtEnd = false;
    // Run out through whichever end has air beyond it: a point half a pitch past the end, midway down the
    // thread, outside the body at four angles (a shaft's free end, a through hole's mouth; not a shoulder
    // or a blind hole's bottom).
    bool runOutWhereFree = false;
    // The face the thread is cut on, a cylinder (parallel thread) or a cone of the thread's own taper
    // about its axis: its diameter at the start; 0 if unknown, the body then taken as it is. Given:
    //   - standing proud of the thread's crest (external: its major; internal: its minor) by more than
    //     1 µm, the zone is first turned (bored) to it — the standard's crest, and no thin fin between
    //     a rounded crest's turns;
    //   - lying just inside a rounded crest, the crest stops 1e-8 m inside it and the groove leaves it
    //     square, rather than crossing it at a glancing angle: OCCT's cut gets that wrong while the
    //     result passes BRepCheck (R1/2 on a blank 1 µm under its crests: a chunk left in the groove,
    //     0.2 % of it; Rc1/2: 0.2 %).
    double surfaceDiameter = 0.0;
};

// What the cut reports.
struct ThreadCutReport {
    double deviation = 0.0; // how far the built thread faces are from the profile (sampled), m
    int turns = 0;
    int attempts = 0;       // angles at which the turns begin tried before OCCT's cut came out valid
    double trimmed = 0.0;   // how far the face stood proud of the crest and was turned (bored) away, m
};

} // namespace cadnext::kernel
