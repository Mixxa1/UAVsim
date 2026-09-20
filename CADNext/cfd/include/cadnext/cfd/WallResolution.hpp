#pragma once

#include "cadnext/cfd/Su2Case.hpp"

#include <string>
#include <vector>

// What the first cell off the wall has to be, and whether the mesh that was actually run delivered it.
//
// A viscous solution is only as good as its near-wall mesh. SU2's k-ω SST integrates to the wall, so
// either the viscous sublayer is meshed (y⁺ of the first node about 1) or the first node sits in the
// logarithmic layer (y⁺ 30…300) and SU2's standard wall function supplies the wall stress and the
// turbulence variables there. Between those two — the buffer layer — neither holds: the sublayer is
// unresolved and the log law does not yet apply, so skin friction is whatever the discretisation
// happens to produce. Such a run's fields may be inspected, its coefficients may not be used.
//
// The sizing formulas are the flat-plate turbulent correlations, used as what they are: an estimate
// good to a factor of about two on a real airframe, enough to place the first layer within the right
// decade. The verdict below is not an estimate — it is measured from SU2's own Y_Plus output.

namespace cadnext::cfd {

enum class WallTreatment {
    Resolved,  // y⁺ ≈ 1, no wall function
    Functions, // y⁺ 30…300, MARKER_WALL_FUNCTIONS
};

bool parseWallTreatment(const std::string& name, WallTreatment& out); // "resolved" | "functions"
std::string wallTreatmentName(WallTreatment treatment);

// ρ U L / μ.
double reynoldsNumber(double speedMps, double lengthM, double densityKgM3, double viscosityPaS);
// Local skin friction of a turbulent flat-plate boundary layer, cf = 0.026 Re^(−1/7).
double flatPlateSkinFriction(double reynolds);
// δ₉₉ = 0.37 L Re^(−1/5) (turbulent).
double boundaryLayerThicknessM(double reynolds, double lengthM);
// Blasius: δ₉₉ = 5 L / √Re. Boundary-layer theory itself needs a thin layer, so this says nothing
// below Re ≈ 10³, where the viscous region is as large as the body.
double laminarBoundaryLayerThicknessM(double reynolds, double lengthM);
// Height of a given y⁺ above the wall, from the flat-plate friction velocity.
double heightForYPlus(double yPlus, double speedMps, double lengthM, double densityKgM3, double viscosityPaS);
// The y⁺ a first layer of this height is expected to produce — the estimate available before a run.
double yPlusForHeight(double heightM, double speedMps, double lengthM, double densityKgM3, double viscosityPaS);

struct WallLayerPlan {
    double reynolds = 0;
    double skinFriction = 0;
    double frictionVelocityMps = 0;
    double boundaryLayerM = 0;
    double firstHeightM = 0;
    double totalHeightM = 0;
    double growth = 0;
    std::vector<double> heightsM;
};

// Prism stack for the requested wall treatment: first layer at the treatment's target y⁺ (1 resolved,
// 50 with wall functions), geometric growth, enough layers to reach δ₉₉ (at most 60).
WallLayerPlan planWallLayers(WallTreatment treatment, double speedMps, double lengthM, double densityKgM3, double viscosityPaS);

struct WallResolution {
    bool measured = false;
    int nodes = 0;
    double median = 0, p95 = 0, maximum = 0, minimum = 0;
    // Share of wall nodes whose y⁺ makes the wall treatment invalid there.
    double badShare = 0;
    // Share in each band, for the report.
    double shareBelow1 = 0, shareBuffer = 0, shareLog = 0, shareAbove300 = 0;
    bool valid = false;
    std::string problem; // empty when valid
};

// Measures SU2's Y_Plus column over the wall nodes and judges the run:
//   resolved  — invalid when more than 5 % of the nodes are above y⁺ = 2 (the sublayer's u⁺ = y⁺ holds
//               to a few per cent up to y⁺ ≈ 2; a few per cent of nodes always sit at edges and
//               stagnation lines where nothing can be done about it);
//   functions — invalid when more than 10 % of the nodes are in the buffer layer 5 < y⁺ < 30 or above
//               y⁺ = 300. Nodes below y⁺ = 5 are not an error: SU2 switches its wall model off there
//               (WALLMODEL_MINYPLUS) and uses the viscous stress, which is right in the low-shear
//               regions near stagnation and separation where those nodes occur.
WallResolution assessWallResolution(const Su2History& surface, WallTreatment treatment);

} // namespace cadnext::cfd
