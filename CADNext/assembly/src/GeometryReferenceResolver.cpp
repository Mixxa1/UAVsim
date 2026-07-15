#include "cadnext/assembly/GeometryReferenceResolver.hpp"

#include <cmath>
#include <limits>

namespace cadnext::assembly {

namespace {

// Heuristic re-bind tolerances. Position is absolute (model units = m);
// direction compares |cos| against 1; scalar properties are relative.
constexpr double kPositionTolerance = 5.0e-3;
constexpr double kDirectionTolerance = 1.0e-2;
constexpr double kScalarRelativeTolerance = 2.0e-2;

bool scalarMatches(double stored, double candidate) {
    const double magnitude = std::max(std::fabs(stored), std::fabs(candidate));
    if (magnitude <= 1.0e-12) {
        return true;
    }
    return std::fabs(stored - candidate) <= magnitude * kScalarRelativeTolerance;
}

// Directions of faces/axes are orientation-sensitive for solving, but the
// heuristic match accepts a flipped element (the joint alignment flag owns
// the final orientation).
bool directionMatches(const Vector3& stored, const Vector3& candidate) {
    const double storedLength = length(stored);
    const double candidateLength = length(candidate);
    if (storedLength <= 1.0e-9 || candidateLength <= 1.0e-9) {
        return true;
    }
    const double cosine = dot(stored, candidate) / (storedLength * candidateLength);
    return std::fabs(std::fabs(cosine) - 1.0) <= kDirectionTolerance;
}

bool positionMatches(const Vector3& stored, const Vector3& candidate) {
    return length(subtract(candidate, stored)) <= kPositionTolerance;
}

double positionDistance(const Vector3& stored, const Vector3& candidate) {
    return length(subtract(candidate, stored));
}

bool kindMatchesFace(GeometryReferenceKind kind, const kernel::FaceReference& face) {
    if (kind == GeometryReferenceKind::PlanarFace) {
        return face.kind == kernel::FaceKind::Planar;
    }
    if (kind == GeometryReferenceKind::CylindricalFace) {
        return face.kind == kernel::FaceKind::Cylindrical;
    }
    return false;
}

bool kindMatchesEdge(GeometryReferenceKind kind, const kernel::EdgeReference& edge) {
    if (kind == GeometryReferenceKind::LinearEdge) {
        return edge.kind == kernel::EdgeKind::Line;
    }
    if (kind == GeometryReferenceKind::CircularEdge) {
        return edge.kind == kernel::EdgeKind::Circle;
    }
    return false;
}

ResolvedReference exactResult(Frame frame, std::string topologyId,
                              GeometrySignature signature) {
    ResolvedReference result;
    result.status = ReferenceResolutionStatus::Exact;
    result.localFrame = frame;
    result.resolvedTopologyId = std::move(topologyId);
    result.refreshedSignature = std::move(signature);
    return result;
}

ResolvedReference heuristicResult(Frame frame, std::string topologyId,
                                  GeometrySignature signature) {
    ResolvedReference result;
    result.status = ReferenceResolutionStatus::Heuristic;
    result.localFrame = frame;
    result.resolvedTopologyId = std::move(topologyId);
    result.refreshedSignature = std::move(signature);
    result.message = "Reference re-bound by geometric signature";
    return result;
}

ResolvedReference brokenResult(const GeometryReference& reference, std::string message) {
    ResolvedReference result;
    result.status = ReferenceResolutionStatus::Broken;
    result.localFrame = reference.fallbackFrame;
    result.resolvedTopologyId = reference.persistentTopologyId;
    result.refreshedSignature = reference.signature;
    result.message = std::move(message);
    return result;
}

} // namespace

Frame GeometryReferenceResolver::frameForFace(const kernel::FaceReference& face) {
    if (face.kind == kernel::FaceKind::Cylindrical && face.radius > 0.0) {
        // Cylinder: origin on the axis, Z along the axis.
        return Frame::fromOriginZX(face.axisOrigin, face.axisDirection,
                                   stablePerpendicular(face.axisDirection));
    }
    // Planar (and fallback for other kinds): origin at face center,
    // Z = outward normal, X = surface U direction.
    return Frame::fromOriginZX(face.origin, face.normal, face.uAxis);
}

Frame GeometryReferenceResolver::frameForEdge(const kernel::EdgeReference& edge) {
    if (edge.kind == kernel::EdgeKind::Circle && edge.radius > 0.0) {
        // Circle: origin at the center, Z along the circle axis.
        return Frame::fromOriginZX(edge.center, edge.axisDirection,
                                   stablePerpendicular(edge.axisDirection));
    }
    // Line (and fallback): origin at the midpoint, Z along the edge.
    const Vector3 direction = subtract(edge.end, edge.start);
    const Vector3 midpoint = scale(add(edge.start, edge.end), 0.5);
    return Frame::fromOriginZX(midpoint, direction, stablePerpendicular(direction));
}

Frame GeometryReferenceResolver::frameForVertex(const kernel::VertexReference& vertex) {
    Frame frame = Frame::identity();
    frame.origin = vertex.position;
    return frame;
}

GeometrySignature GeometryReferenceResolver::signatureForFace(
    const kernel::FaceReference& face) {
    GeometrySignature signature;
    if (face.kind == kernel::FaceKind::Cylindrical && face.radius > 0.0) {
        signature.origin = face.axisOrigin;
        signature.direction = face.axisDirection;
        signature.radius = face.radius;
    } else {
        signature.origin = face.origin;
        signature.direction = face.normal;
    }
    signature.area = face.area;
    return signature;
}

GeometrySignature GeometryReferenceResolver::signatureForEdge(
    const kernel::EdgeReference& edge) {
    GeometrySignature signature;
    if (edge.kind == kernel::EdgeKind::Circle && edge.radius > 0.0) {
        signature.origin = edge.center;
        signature.direction = edge.axisDirection;
        signature.radius = edge.radius;
    } else {
        signature.origin = scale(add(edge.start, edge.end), 0.5);
        signature.direction = normalizedOr(subtract(edge.end, edge.start), {0.0, 0.0, 0.0});
    }
    signature.length = edge.length;
    return signature;
}

GeometrySignature GeometryReferenceResolver::signatureForVertex(
    const kernel::VertexReference& vertex) {
    GeometrySignature signature;
    signature.origin = vertex.position;
    return signature;
}

GeometryReference GeometryReferenceResolver::makeFaceReference(
    std::vector<std::string> componentPath, const kernel::FaceReference& face) {
    GeometryReference reference;
    reference.kind = face.kind == kernel::FaceKind::Cylindrical
                         ? GeometryReferenceKind::CylindricalFace
                         : GeometryReferenceKind::PlanarFace;
    reference.componentPath = std::move(componentPath);
    reference.bodyId = face.bodyId;
    reference.persistentTopologyId = face.faceId;
    reference.signature = signatureForFace(face);
    reference.fallbackFrame = frameForFace(face);
    return reference;
}

GeometryReference GeometryReferenceResolver::makeEdgeReference(
    std::vector<std::string> componentPath, const kernel::EdgeReference& edge) {
    GeometryReference reference;
    reference.kind = edge.kind == kernel::EdgeKind::Circle
                         ? GeometryReferenceKind::CircularEdge
                         : GeometryReferenceKind::LinearEdge;
    reference.componentPath = std::move(componentPath);
    reference.bodyId = edge.bodyId;
    reference.persistentTopologyId = edge.edgeId;
    reference.signature = signatureForEdge(edge);
    reference.fallbackFrame = frameForEdge(edge);
    return reference;
}

GeometryReference GeometryReferenceResolver::makeVertexReference(
    std::vector<std::string> componentPath, const kernel::VertexReference& vertex) {
    GeometryReference reference;
    reference.kind = GeometryReferenceKind::Vertex;
    reference.componentPath = std::move(componentPath);
    reference.bodyId = vertex.bodyId;
    reference.persistentTopologyId = vertex.vertexId;
    reference.signature = signatureForVertex(vertex);
    reference.fallbackFrame = frameForVertex(vertex);
    return reference;
}

GeometryReference GeometryReferenceResolver::makeLcsReference(
    std::vector<std::string> componentPath) {
    GeometryReference reference;
    reference.kind = GeometryReferenceKind::LocalCoordinateSystem;
    reference.componentPath = std::move(componentPath);
    reference.fallbackFrame = Frame::identity();
    return reference;
}

ResolvedReference GeometryReferenceResolver::resolve(const GeometryReference& reference,
                                                     const PartTopology& topology) {
    switch (reference.kind) {
    case GeometryReferenceKind::LocalCoordinateSystem: {
        // The component's own origin frame always resolves.
        ResolvedReference result;
        result.status = ReferenceResolutionStatus::Exact;
        result.localFrame = Frame::identity();
        return result;
    }
    case GeometryReferenceKind::PlanarFace:
    case GeometryReferenceKind::CylindricalFace: {
        for (const kernel::FaceReference& face : topology.faces) {
            if (face.faceId == reference.persistentTopologyId &&
                kindMatchesFace(reference.kind, face)) {
                return exactResult(frameForFace(face), face.faceId, signatureForFace(face));
            }
        }
        const kernel::FaceReference* best = nullptr;
        double bestDistance = std::numeric_limits<double>::infinity();
        for (const kernel::FaceReference& face : topology.faces) {
            if (!kindMatchesFace(reference.kind, face)) {
                continue;
            }
            const GeometrySignature candidate = signatureForFace(face);
            if (!positionMatches(reference.signature.origin, candidate.origin) ||
                !directionMatches(reference.signature.direction, candidate.direction) ||
                !scalarMatches(reference.signature.area, candidate.area) ||
                !scalarMatches(reference.signature.radius, candidate.radius)) {
                continue;
            }
            const double distance =
                positionDistance(reference.signature.origin, candidate.origin);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = &face;
            }
        }
        if (best) {
            return heuristicResult(frameForFace(*best), best->faceId,
                                   signatureForFace(*best));
        }
        return brokenResult(reference, "Face not found in the current part topology");
    }
    case GeometryReferenceKind::LinearEdge:
    case GeometryReferenceKind::CircularEdge: {
        for (const kernel::EdgeReference& edge : topology.edges) {
            if (edge.edgeId == reference.persistentTopologyId &&
                kindMatchesEdge(reference.kind, edge)) {
                return exactResult(frameForEdge(edge), edge.edgeId, signatureForEdge(edge));
            }
        }
        const kernel::EdgeReference* best = nullptr;
        double bestDistance = std::numeric_limits<double>::infinity();
        for (const kernel::EdgeReference& edge : topology.edges) {
            if (!kindMatchesEdge(reference.kind, edge)) {
                continue;
            }
            const GeometrySignature candidate = signatureForEdge(edge);
            if (!positionMatches(reference.signature.origin, candidate.origin) ||
                !directionMatches(reference.signature.direction, candidate.direction) ||
                !scalarMatches(reference.signature.radius, candidate.radius) ||
                !scalarMatches(reference.signature.length, candidate.length)) {
                continue;
            }
            const double distance =
                positionDistance(reference.signature.origin, candidate.origin);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = &edge;
            }
        }
        if (best) {
            return heuristicResult(frameForEdge(*best), best->edgeId,
                                   signatureForEdge(*best));
        }
        return brokenResult(reference, "Edge not found in the current part topology");
    }
    case GeometryReferenceKind::Vertex: {
        for (const kernel::VertexReference& vertex : topology.vertices) {
            if (vertex.vertexId == reference.persistentTopologyId) {
                return exactResult(frameForVertex(vertex), vertex.vertexId,
                                   signatureForVertex(vertex));
            }
        }
        const kernel::VertexReference* best = nullptr;
        double bestDistance = std::numeric_limits<double>::infinity();
        for (const kernel::VertexReference& vertex : topology.vertices) {
            if (!positionMatches(reference.signature.origin, vertex.position)) {
                continue;
            }
            const double distance =
                positionDistance(reference.signature.origin, vertex.position);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = &vertex;
            }
        }
        if (best) {
            return heuristicResult(frameForVertex(*best), best->vertexId,
                                   signatureForVertex(*best));
        }
        return brokenResult(reference, "Vertex not found in the current part topology");
    }
    }
    return brokenResult(reference, "Unknown reference kind");
}

} // namespace cadnext::assembly
