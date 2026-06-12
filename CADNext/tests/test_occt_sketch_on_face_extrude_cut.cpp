// CADNext 0.8 (OCCT only): the full face-sketch workflow at kernel level —
// a SketchReference built from an analyzed planar face drives Extrude and
// Cut Extrude through the regular GeometryEvaluator paths:
//
//   box -> top face -> rectangle sketch -> Cut Through All -> hole
//   box -> side face -> circle sketch  -> Cut Distance    -> pocket
//   box -> top face -> rectangle sketch -> Extrude         -> boss on face

#include "cadnext/Chamfer.hpp"
#include "cadnext/ExtrudeCut.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <array>
#include <cassert>
#include <cmath>
#include <vector>

namespace {

using cadnext::SketchPoint2D;
using cadnext::SketchReference;
using cadnext::Vector3;
using cadnext::kernel::EdgeReference;
using cadnext::kernel::FaceReference;

double dot(const Vector3& a, const Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

// The GUI-side adapter, replicated for the kernel-level test: a face frame
// becomes a BodyFace sketch reference verbatim.
SketchReference referenceFromFace(const FaceReference& face) {
    SketchReference reference;
    reference.type = cadnext::SketchReferenceType::BodyFace;
    reference.sourceId = face.faceId;
    reference.sourceBodyId = face.bodyId;
    reference.sourceFaceId = face.faceId;
    reference.origin = face.origin;
    reference.uAxis = face.uAxis;
    reference.vAxis = face.vAxis;
    reference.normal = face.normal;
    return reference;
}

const FaceReference* faceWithNormal(const std::vector<FaceReference>& faces,
                                    const Vector3& direction) {
    for (const FaceReference& face : faces) {
        if (face.isSketchable && dot(face.normal, direction) > 0.999) {
            return &face;
        }
    }
    return nullptr;
}

const FaceReference* chamferFace(const std::vector<FaceReference>& faces) {
    const FaceReference* best = nullptr;
    double bestArea = 0.0;
    for (const FaceReference& face : faces) {
        if (!face.isSketchable) {
            continue;
        }
        const bool diagonalInYZ = std::fabs(face.normal.y) > 0.45 &&
                                  std::fabs(face.normal.z) > 0.45 &&
                                  std::fabs(face.normal.x) < 0.1;
        if (diagonalInYZ && face.area > bestArea) {
            best = &face;
            bestArea = face.area;
        }
    }
    return best;
}

const EdgeReference* nearestEdge(const std::vector<EdgeReference>& edges,
                                 const Vector3& targetCenter) {
    const EdgeReference* best = nullptr;
    double bestDistance2 = 1.0e300;
    for (const EdgeReference& edge : edges) {
        const double dx = edge.center.x - targetCenter.x;
        const double dy = edge.center.y - targetCenter.y;
        const double dz = edge.center.z - targetCenter.z;
        const double distance2 = dx * dx + dy * dy + dz * dz;
        if (distance2 < bestDistance2) {
            best = &edge;
            bestDistance2 = distance2;
        }
    }
    return best;
}

cadnext::SketchProfile rectangleProfile(double halfU, double halfV) {
    cadnext::SketchProfile profile;
    profile.id = "profile-rect";
    profile.sketchId = "sketch-test";
    profile.kind = cadnext::SketchProfileKind::Rectangle;
    profile.outerLoop = {{-halfU, -halfV}, {halfU, -halfV}, {halfU, halfV}, {-halfU, halfV}};
    profile.area = 4.0 * halfU * halfV;
    profile.isClosed = true;
    profile.isValid = true;
    return profile;
}

cadnext::SketchProfile circleProfile(double radius,
                                     SketchPoint2D center = {0.0, 0.0}) {
    cadnext::SketchProfile profile;
    profile.id = "profile-circle";
    profile.sketchId = "sketch-test";
    profile.kind = cadnext::SketchProfileKind::Circle;
    constexpr int kSegments = 48;
    for (int i = 0; i < kSegments; ++i) {
        const double angle = 2.0 * M_PI * static_cast<double>(i) / kSegments;
        profile.outerLoop.push_back({center.u + radius * std::cos(angle),
                                     center.v + radius * std::sin(angle)});
    }
    profile.area = M_PI * radius * radius;
    profile.isClosed = true;
    profile.isValid = true;
    return profile;
}

// Target extents along the reference normal (relative to the face origin),
// from the 8 corners of the body AABB — the same projection the GUI does.
void projectedExtents(const cadnext::kernel::ShapeBounds& bounds,
                      const SketchReference& reference, cadnext::CutExtents& extents) {
    const std::array<Vector3, 8> corners = {
        Vector3{bounds.min.x, bounds.min.y, bounds.min.z},
        Vector3{bounds.max.x, bounds.min.y, bounds.min.z},
        Vector3{bounds.min.x, bounds.max.y, bounds.min.z},
        Vector3{bounds.max.x, bounds.max.y, bounds.min.z},
        Vector3{bounds.min.x, bounds.min.y, bounds.max.z},
        Vector3{bounds.max.x, bounds.min.y, bounds.max.z},
        Vector3{bounds.min.x, bounds.max.y, bounds.max.z},
        Vector3{bounds.max.x, bounds.max.y, bounds.max.z},
    };
    extents.targetMin = 1.0e300;
    extents.targetMax = -1.0e300;
    for (const Vector3& corner : corners) {
        const Vector3 delta{corner.x - reference.origin.x, corner.y - reference.origin.y,
                            corner.z - reference.origin.z};
        const double offset = dot(delta, reference.normal);
        extents.targetMin = std::min(extents.targetMin, offset);
        extents.targetMax = std::max(extents.targetMax, offset);
    }
    const double dx = bounds.max.x - bounds.min.x;
    const double dy = bounds.max.y - bounds.min.y;
    const double dz = bounds.max.z - bounds.min.z;
    extents.targetDiagonal = std::sqrt(dx * dx + dy * dy + dz * dz);
}

// Signed volume of a closed, outward-wound triangle mesh (divergence
// theorem) — strong evidence that a cut really removed material.
double meshVolume(const cadnext::kernel::TriangleMesh& mesh) {
    double volume = 0.0;
    for (const cadnext::kernel::MeshTriangle& triangle : mesh.triangles) {
        const cadnext::kernel::MeshVertex& a = mesh.vertices[triangle.a];
        const cadnext::kernel::MeshVertex& b = mesh.vertices[triangle.b];
        const cadnext::kernel::MeshVertex& c = mesh.vertices[triangle.c];
        volume += (a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
                   a.z * (b.x * c.y - b.y * c.x)) /
                  6.0;
    }
    return volume;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    assert(kernel.isAvailable());
    cadnext::kernel::GeometryEvaluator evaluator(kernel);
    cadnext::kernel::FaceAnalyzer analyzer(kernel);
    cadnext::kernel::EdgeAnalyzer edgeAnalyzer(kernel);

    // Unit box centered on the origin: x/y/z all span [-0.5, 0.5].
    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());
    const std::vector<FaceReference> faces =
        analyzer.planarFacesForBody("body-box", box.value());
    assert(faces.size() == 6);

    const FaceReference* topFace = faceWithNormal(faces, {0.0, 0.0, 1.0});
    const FaceReference* sideFace = faceWithNormal(faces, {1.0, 0.0, 0.0});
    assert(topFace && sideFace);
    assert(std::fabs(topFace->origin.z - 0.5) < 1.0e-6);
    assert(std::fabs(sideFace->origin.x - 0.5) < 1.0e-6);

    const SketchReference topReference = referenceFromFace(*topFace);
    const SketchReference sideReference = referenceFromFace(*sideFace);
    // Sketch normal is exactly the face normal.
    assert(std::fabs(topReference.normal.z - 1.0) < 1.0e-9);

    // --- Extrude from the top face sketch: boss sits on the face ---------
    {
        cadnext::ExtrudeParameters parameters;
        parameters.sketchId = "sketch-test";
        parameters.profileId = "profile-rect";
        parameters.direction = cadnext::ExtrudeDirection::Positive;
        parameters.distance = 0.4;
        const auto extruded =
            evaluator.evaluateExtrude(topReference, rectangleProfile(0.2, 0.2), parameters);
        assert(extruded.isOk());
        assert(extruded.value().isValid);
        assert(!extruded.value().previewMesh.isEmpty());
        const auto bounds = kernel.boundingBox(extruded.value().shape);
        assert(bounds.isOk());
        // Positive extrude follows the face normal: from the face plane
        // (z = 0.5) outward to z = 0.9.
        assert(std::fabs(bounds.value().min.z - 0.5) < 1.0e-6);
        assert(std::fabs(bounds.value().max.z - 0.9) < 1.0e-6);
    }

    // --- Cut Through All from the top face: hole through the box ---------
    {
        cadnext::ExtrudeCutParameters parameters;
        parameters.targetBodyId = "body-box";
        parameters.sketchId = "sketch-test";
        parameters.profileId = "profile-rect";
        parameters.depthMode = cadnext::CutDepthMode::ThroughAll;
        parameters.direction = cadnext::CutDirection::Negative; // into the body

        const auto targetBounds = kernel.boundingBox(box.value());
        assert(targetBounds.isOk());
        cadnext::CutExtents extents;
        projectedExtents(targetBounds.value(), topReference, extents);
        // The box hangs below the top-face plane: extents [-1, 0].
        assert(std::fabs(extents.targetMin + 1.0) < 1.0e-6);
        assert(std::fabs(extents.targetMax) < 1.0e-6);

        const cadnext::Result<cadnext::CutSpan> span =
            cadnext::computeCutSpan(parameters, extents);
        assert(span.isOk());
        assert(span.value().start < -1.0); // past the body bottom
        assert(span.value().end >= 0.0);

        const auto cut = evaluator.evaluateExtrudeCut(
            box.value(), topReference, rectangleProfile(0.2, 0.2), span.value());
        assert(cut.isOk());
        assert(cut.value().isValid);
        assert(!cut.value().previewMesh.isEmpty());

        // The through-hole leaves the outer bounds intact but removes
        // 0.4 x 0.4 x 1.0 of material.
        const auto cutBounds = kernel.boundingBox(cut.value().shape);
        assert(cutBounds.isOk());
        assert(std::fabs(cutBounds.value().min.z + 0.5) < 1.0e-6);
        assert(std::fabs(cutBounds.value().max.z - 0.5) < 1.0e-6);
        const double volume = meshVolume(cut.value().previewMesh);
        assert(std::fabs(volume - 0.84) < 0.02);
    }

    // --- Cut Distance from the side face: pocket into the box ------------
    {
        cadnext::ExtrudeCutParameters parameters;
        parameters.targetBodyId = "body-box";
        parameters.sketchId = "sketch-test";
        parameters.profileId = "profile-circle";
        parameters.depthMode = cadnext::CutDepthMode::Distance;
        parameters.direction = cadnext::CutDirection::Negative; // into the body
        parameters.distance = 0.3;

        const cadnext::Result<cadnext::CutSpan> span =
            cadnext::computeCutSpan(parameters, cadnext::CutExtents{});
        assert(span.isOk());
        assert(std::fabs(span.value().start + 0.3) < 1.0e-9);
        assert(std::fabs(span.value().end) < 1.0e-9);

        const auto cut = evaluator.evaluateExtrudeCut(
            box.value(), sideReference, circleProfile(0.2), span.value());
        assert(cut.isOk());
        assert(cut.value().isValid);
        assert(!cut.value().previewMesh.isEmpty());

        // Pocket volume: pi * r^2 * depth removed from the unit cube.
        const double expected = 1.0 - M_PI * 0.2 * 0.2 * 0.3;
        const double volume = meshVolume(cut.value().previewMesh);
        assert(std::fabs(volume - expected) < 0.02);
    }

    // --- Sketch + Cut Distance from a freshly created chamfer face -------
    {
        const std::vector<EdgeReference> boxEdges =
            edgeAnalyzer.edgesForBody("body-box", box.value());
        const EdgeReference* topFrontEdge =
            nearestEdge(boxEdges, {0.0, -0.5, 0.5});
        assert(topFrontEdge);

        cadnext::ChamferParameters chamferParameters;
        chamferParameters.targetBodyId = "body-box";
        chamferParameters.edgeIds = {topFrontEdge->edgeId};
        chamferParameters.mode = cadnext::ChamferMode::DistanceAngle;
        chamferParameters.distanceMm = 100.0;
        chamferParameters.angleDeg = 45.0;
        const auto chamfered =
            evaluator.evaluateChamfer(box.value(), chamferParameters);
        assert(chamfered.isOk());
        assert(chamfered.value().isValid);
        assert(kernel.isShapeValid(chamfered.value().shape));

        const std::vector<FaceReference> chamferedFaces =
            analyzer.planarFacesForBody("body-box", chamfered.value().shape);
        const FaceReference* slopedFace = chamferFace(chamferedFaces);
        assert(slopedFace);
        const SketchReference chamferReference = referenceFromFace(*slopedFace);

        cadnext::ExtrudeCutParameters parameters;
        parameters.targetBodyId = "body-box";
        parameters.sketchId = "sketch-test";
        parameters.profileId = "profile-circle";
        parameters.depthMode = cadnext::CutDepthMode::Distance;
        parameters.direction = cadnext::CutDirection::Negative; // into the chamfered body
        parameters.distance = 0.35;

        const cadnext::Result<cadnext::CutSpan> span =
            cadnext::computeCutSpan(parameters, cadnext::CutExtents{});
        assert(span.isOk());

        const double beforeVolume = std::fabs(meshVolume(chamfered.value().previewMesh));
        const auto cut = evaluator.evaluateExtrudeCut(
            chamfered.value().shape, chamferReference, circleProfile(0.04, {0.0, 0.055}),
            span.value());
        assert(cut.isOk());
        assert(cut.value().isValid);
        assert(!cut.value().previewMesh.isEmpty());
        assert(kernel.isShapeValid(cut.value().shape));

        const double afterVolume = std::fabs(meshVolume(cut.value().previewMesh));
        assert(afterVolume < beforeVolume - 1.0e-4);
    }

    return 0;
}
