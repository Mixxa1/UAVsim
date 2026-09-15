#pragma once

#include "cadnext/fea/FeaTypes.hpp"
#include "cadnext/fea/TetMesh.hpp"

#include <array>
#include <vector>

namespace cadnext::fea {

struct QuadraturePoint {
    // Reference coordinates (ξ, η, ζ) = (L1, L2, L3); L0 = 1 − ξ − η − ζ.
    Vec3 xi;
    double weight = 0.0; // weights sum to the reference volume 1/6
};

// Degree-2 rule, 4 points: exact for the stiffness integrand of a straight-sided TET10.
const std::vector<QuadraturePoint>& tetQuadratureDegree2();

// Degree-5 rule, 14 points, all weights positive (Walkington, "Quadrature on simplices of
// arbitrary dimension", 2000). Used for curved TET10: once midside nodes leave their edges the
// stiffness integrand is no longer quadratic, and the 4-point rule fails the patch test.
const std::vector<QuadraturePoint>& tetQuadratureDegree5();

// A quadratic element whose midside nodes are off their straight edges.
bool tetIsCurved(const TetMesh& mesh, int element);

// Smallest det J over the ten nodal points and the quadrature points. Sampling only the
// quadrature points lets a folded element through: its Jacobian can be positive there and
// negative at a corner.
double tetMinimumJacobian(const TetMesh& mesh, int element);

// Shape function values and reference derivatives. Size 4 or 10.
void tetShapeFunctions(ElementOrder order, const Vec3& xi, double* values, Vec3* referenceGradients);

// 6×6 isotropic elasticity matrix, Voigt order xx yy zz yz xz xy, engineering shear strain.
std::array<std::array<double, 6>, 6> isotropicElasticity(double youngsModulus, double poissonRatio);

struct ElementGeometryError {
    bool invalid = false;
    double minimumJacobian = 0.0;
};

// Dense element stiffness, row-major n×n with n = 3·nodesPerElement, DOFs ordered
// (u_x, u_y, u_z) per node. Returns invalid if any quadrature point has det J ≤ 0.
ElementGeometryError tetStiffness(const TetMesh& mesh, int element,
                                  const std::array<std::array<double, 6>, 6>& elasticity,
                                  std::vector<double>& stiffness);

// Volume of one element from its mapping (degree-5 rule: exact for straight elements, close for
// curved ones).
double tetVolume(const TetMesh& mesh, int element);

// Consistent mass ∫ρ NᵀN dV, row-major n×n with n = 3·nodesPerElement. Degree-5 rule: exact for
// straight elements (the integrand is degree 4).
void tetMass(const TetMesh& mesh, int element, double density, std::vector<double>& mass);

// Consistent nodal forces of a uniform body force density (N/m³).
void tetBodyForce(const TetMesh& mesh, int element, const Vec3& forcePerVolume, std::vector<double>& nodalForces);

// Stress at each of the four points of the degree-2 rule (identical for TET4). Point q is
// the one nearest corner q, which is what the corner extrapolation relies on.
std::vector<Voigt> tetQuadratureStress(const TetMesh& mesh, int element,
                                       const std::array<std::array<double, 6>, 6>& elasticity,
                                       const std::vector<Vec3>& displacement);

// Degree-4 triangle rule, 6 points (Dunavant): reference coordinates (s, t), weights sum to 1/2.
struct TriangleQuadraturePoint {
    double s = 0.0;
    double t = 0.0;
    double weight = 0.0;
};
const std::vector<TriangleQuadraturePoint>& triangleQuadratureDegree4();

// T3/T6 face shape functions in the node order of TetMesh::faceNodes.
void triangleShapeFunctions(ElementOrder order, double s, double t, double* values, double* dS, double* dT);

} // namespace cadnext::fea
