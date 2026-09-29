#pragma once

#include <string>
#include <vector>

#include "cadnext/Vector3.hpp"

// Screw threads: the standards the Thread feature knows, their size tables, and the feature's recipe.
// Millimetres, as the other features' user-facing parameters; the evaluator converts once.
//
// Sources of the tables (values as published; the profiles follow from the pitch by each standard's
// formulas):
//   - metric: ISO 261 / ГОСТ 8724-2002 (diameters and pitches), ISO 724 / ГОСТ 24705-2004 (basic
//     dimensions), profile ISO 68-1 / ГОСТ 9150-2002 — the same values under both;
//   - UNC, UNF: ASME B1.1, profile as ISO 68-1;
//   - G: ISO 228-1 / ГОСТ 6357-81; R, Rc, Rp: ISO 7-1 / ГОСТ 6211-81 (Whitworth 55°);
//   - NPT: ASME B1.20.1 (60°, h = 0.8P, taper 1:16).
// ГОСТ 6111-52 (коническая дюймовая K) is not included: no checked table of its sizes at hand.

namespace cadnext {

enum class ThreadStandard {
    MetricCoarse, // M8
    MetricFine,   // M8×1
    Unc,          // 1/4-20 UNC
    Unf,          // 1/4-28 UNF
    PipeG,        // G1/2 — parallel, external and internal
    PipeR,        // R1/2 external taper; Rc1/2 internal taper
    Npt,          // 1/2-14 NPT, taper both ways
    Custom        // the metric profile at any diameter and pitch
};

enum class ThreadForm {
    Metric60,    // ISO 68-1: 60°, depth 5H/8, flat crest and root
    Whitworth55, // ISO 228-1 / ISO 7-1: 55°, h = 0.640327P, rounded r = 0.137329P (taper: 0.137278P)
    Npt60        // ASME B1.20.1: 60°, h = 0.8P, flats
};

struct ThreadSize {
    std::string designation;     // as marked on a drawing, without the hand: "M8", "G1/2", "1/2-14 NPT"
    double majorDiameterMm = 0;  // basic major diameter; of a taper thread, at its gauge plane
    double pitchMm = 0;
    // Taper threads: from the small end of the external thread to the gauge plane (ISO 7-1: the gauge
    // length; ASME B1.20.1: L1, the hand-tight engagement). An internal taper thread has its gauge plane
    // at the face it opens from.
    double gaugeLengthMm = 0;
};

ThreadForm threadForm(ThreadStandard standard);
bool threadIsTaper(ThreadStandard standard);
// Diameter change per unit of length of a taper thread (1/16), 0 for a parallel one.
double threadTaper(ThreadStandard standard);
// The standard's sizes in the order of its table; empty for Custom.
const std::vector<ThreadSize>& threadSizes(ThreadStandard standard);
// Depth of the basic profile, crest to root: 5H/8 (metric, UNC, UNF), 0.640327P (G, R), 0.8P (NPT).
double threadDepthMm(ThreadForm form, double pitchMm);
// The basic minor diameter an internal thread's hole is made to (the tap drill's size, near enough):
// the major less twice the depth.
double threadMinorDiameterMm(ThreadForm form, double majorDiameterMm, double pitchMm);
// The table's size whose surface is nearest the given diameter — its major (external) or basic minor
// (internal); -1 for an empty table. A taper thread is matched at its gauge plane.
int nearestThreadSize(ThreadStandard standard, double diameterMm, bool internal);

// Russian names for the tool's list, and stable keys for documents.
const char* threadStandardTitle(ThreadStandard standard);
const char* threadStandardKey(ThreadStandard standard);
ThreadStandard threadStandardFromKey(const std::string& key);

// The face a thread is cut on, as found when the thread was made — in the body's coordinates and model
// units (metres), like a sketch's resolved plane: kept with the recipe, so that the thread replays even
// where the face's id no longer resolves.
struct ThreadSurface {
    Vector3 axisOrigin;          // a point of the face's axis
    Vector3 axisDirection;       // unit
    double radius = 0.0;         // at axisOrigin
    double slope = 0.0;          // radius change per unit of length along axisDirection: 0 for a cylinder
    double axialStart = 0.0;     // the face's extent along axisDirection from axisOrigin
    double axialEnd = 0.0;
    bool holeWall = false;       // the material outside the surface: a hole's wall, an internal thread

    double length() const { return axialEnd - axialStart; }
    double radiusAt(double axial) const { return radius + slope * axial; }
};

// The Thread feature: real turns cut into (external) or out of (internal) a cylindrical or conical face
// of a body. A parallel thread on a cylinder starts from the face's end the user chose; a taper thread
// (R, Rc, NPT) on a cone of its taper runs from the small end — an external one from there, an internal
// one being measured from the large end, the hole's mouth, where its gauge plane is.
struct ThreadParameters {
    std::string targetBodyId;
    std::string faceId;          // the face picked, for the user; the geometry is `surface`
    ThreadSurface surface;
    ThreadStandard standard = ThreadStandard::MetricCoarse;
    std::string designation;     // the table's size ("M8", "G1/2"); Custom: made from the numbers
    double majorDiameterMm = 0;  // from the table (taper: at its gauge plane), or given (Custom)
    double pitchMm = 0;
    double gaugeLengthMm = 0;    // taper threads: ThreadSize::gaugeLengthMm
    double lengthMm = 0;         // along the axis
    bool fromFarEnd = false;     // parallel threads: start from the face's end at axialEnd
    bool internal = false;       // = surface.holeWall
    bool rightHanded = true;
};

bool threadParametersValid(const ThreadParameters& parameters);
// "M8×1LH", "G1/2", "Rc1/2": the designation with the hand and, for R, the internal form's letter.
std::string threadMarking(const ThreadParameters& parameters);

} // namespace cadnext
