#include "cadnext/gui/AssemblyPartLoader.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

#include <QCoreApplication>
#include <QFileInfo>

#include "cadnext/Document.hpp"
#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/ExtrudeCut.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/WorkPlane.hpp"
#include "cadnext/assembly/AssemblyMath.hpp"
#include "cadnext/assembly/AssemblyRecomputeEngine.hpp"
#include "cadnext/assembly/AssemblySerializer.hpp"
#include "cadnext/assembly/SubassemblyMerge.hpp"
#include "cadnext/bridge/UAVPartReader.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/KernelFactory.hpp"
#include "cadnext/kernel/VertexAnalyzer.hpp"

namespace cadnext::gui {

namespace {

// Profile lookup mirroring MainWindow::profileByIdOrLegacy (profiles are
// never serialized — re-detected on load and matched by stable id, with a
// pre-0.7 id fallback).
const SketchProfile* profileByIdOrLegacy(const std::vector<SketchProfile>& profiles,
                                         const std::string& profileId,
                                         const Sketch& sketch) {
    for (const SketchProfile& profile : profiles) {
        if (profile.id == profileId) {
            return &profile;
        }
    }
    for (const SketchProfile& profile : profiles) {
        if (!profile.sourceEntityId.empty() && profile.sourceEntityId == profileId) {
            return &profile;
        }
    }
    if (profileId == sketch.id + "-loop") {
        for (const SketchProfile& profile : profiles) {
            if (profile.kind == SketchProfileKind::Polygon && profile.isValid) {
                return &profile;
            }
        }
    }
    return nullptr;
}

double projectedOffsetAlongNormal(const Vector3& point, const SketchReference& reference) {
    const Vector3 delta{point.x - reference.origin.x, point.y - reference.origin.y,
                        point.z - reference.origin.z};
    return delta.x * reference.normal.x + delta.y * reference.normal.y +
           delta.z * reference.normal.z;
}

void accumulateProjectedBounds(const kernel::ShapeBounds& bounds,
                               const SketchReference& reference, double& outMin,
                               double& outMax) {
    outMin = std::numeric_limits<double>::infinity();
    outMax = -std::numeric_limits<double>::infinity();
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
    for (const Vector3& corner : corners) {
        const double offset = projectedOffsetAlongNormal(corner, reference);
        outMin = std::min(outMin, offset);
        outMax = std::max(outMax, offset);
    }
}

double boundsDiagonal(const kernel::ShapeBounds& bounds) {
    const double dx = bounds.max.x - bounds.min.x;
    const double dy = bounds.max.y - bounds.min.y;
    const double dz = bounds.max.z - bounds.min.z;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

SketchReference referenceForSketch(const Sketch& sketch) {
    return sketch.reference.sourceId.empty() ? canonicalSketchReference(sketch.plane)
                                             : sketch.reference;
}

const Feature* extrudeFeatureForBody(const Document& document,
                                     const std::string& objectId) {
    for (const Feature& feature : document.features()) {
        if (feature.type == FeatureType::Extrude && feature.createdBodyId == objectId) {
            return &feature;
        }
    }
    return nullptr;
}

} // namespace

AssemblyPartLoader::AssemblyPartLoader() {
    // Falls back to the stub backend without OCCT; loads then fail with a
    // clear message instead of crashing (same policy as MainWindow).
    kernel_ = kernel::makeKernel(kernel::KernelBackend::Occt);
    evaluator_ = std::make_unique<kernel::GeometryEvaluator>(*kernel_);
}

AssemblyPartLoader::~AssemblyPartLoader() = default;

const AssemblyPartGeometry& AssemblyPartLoader::geometryForSource(
    const assembly::PartReference& source) {
    const std::string contentHash =
        assembly::AssemblySerializer::contentHashForFile(source.filePath);

    auto it = cacheByPath_.find(source.filePath);
    if (it != cacheByPath_.end() && it->second.contentHash == contentHash &&
        !contentHash.empty()) {
        return it->second;
    }

    AssemblyPartGeometry geometry = loadSource(source, contentHash);
    auto inserted = cacheByPath_.insert_or_assign(source.filePath, std::move(geometry));
    return inserted.first->second;
}

void AssemblyPartLoader::invalidate(const std::string& filePath) {
    cacheByPath_.erase(filePath);
}

void AssemblyPartLoader::clear() {
    cacheByPath_.clear();
}

AssemblyPartGeometry AssemblyPartLoader::loadSource(const assembly::PartReference& source,
                                                    const std::string& contentHash) {
    AssemblyPartGeometry geometry;
    geometry.contentHash = contentHash;

    if (!QFileInfo::exists(QString::fromStdString(source.filePath))) {
        geometry.error = QCoreApplication::translate("AssemblyPartLoader",
                                                     "Файл детали не найден: %1")
                             .arg(QString::fromStdString(source.filePath));
        return geometry;
    }

    switch (source.kind) {
    case assembly::PartSourceKind::UavPart: {
        AssemblyPartGeometry loaded = loadUavPart(source.filePath);
        loaded.contentHash = contentHash;
        return loaded;
    }
    case assembly::PartSourceKind::CadnextDocument: {
        AssemblyPartGeometry loaded = loadCadnextPart(source.filePath, source.bodyId);
        loaded.contentHash = contentHash;
        return loaded;
    }
    case assembly::PartSourceKind::Assembly: {
        AssemblyPartGeometry loaded = loadSubassembly(source.filePath);
        loaded.contentHash = contentHash;
        return loaded;
    }
    }
    return geometry;
}

AssemblyPartGeometry AssemblyPartLoader::loadSubassembly(const std::string& path) {
    AssemblyPartGeometry geometry;

    if (loadingStack_.count(path)) {
        geometry.error = QCoreApplication::translate(
            "AssemblyPartLoader", "Циклическая подсборка: %1")
                             .arg(QString::fromStdString(path));
        return geometry;
    }
    const Result<assembly::AssemblyDocument> loaded =
        assembly::AssemblySerializer::loadFromFile(path);
    if (!loaded.isOk()) {
        geometry.error = QString::fromStdString(loaded.error().message);
        return geometry;
    }

    loadingStack_.insert(path);

    assembly::AssemblyDocument subDocument = loaded.value();
    // Solve the subassembly's internal joints so each internal part sits
    // at its final subassembly-local placement.
    assembly::AssemblyRecomputeEngine engine;
    engine.recompute(subDocument,
                     [this](const assembly::AssemblyComponent& component)
                         -> const assembly::PartTopology* {
                         const AssemblyPartGeometry& internal =
                             geometryForSource(component.source);
                         return internal.valid ? &internal.topology : nullptr;
                     });

    AssemblyPartGeometry merged;
    merged.valid = true;
    merged.displayName =
        subDocument.name().empty() ? QFileInfo(QString::fromStdString(path))
                                         .completeBaseName()
                                         .toStdString()
                                   : subDocument.name();

    assembly::MergedGeometry mergedGeometry;
    for (const assembly::AssemblyComponent& component : subDocument.components()) {
        if (component.isSuppressed || !component.isVisible) {
            continue;
        }
        const AssemblyPartGeometry& internal = geometryForSource(component.source);
        if (!internal.valid) {
            continue;
        }
        assembly::appendTransformedGeometry(mergedGeometry, internal.mesh,
                                            internal.topology, component.placement,
                                            component.id + "::");
    }
    merged.mesh = std::move(mergedGeometry.mesh);
    merged.topology = std::move(mergedGeometry.topology);

    loadingStack_.erase(path);

    if (merged.mesh.vertices.empty()) {
        geometry.error = QCoreApplication::translate(
            "AssemblyPartLoader", "Подсборка не содержит загружаемых деталей: %1")
                             .arg(QString::fromStdString(path));
        return geometry;
    }
    return merged;
}

AssemblyPartGeometry AssemblyPartLoader::loadCadnextPart(const std::string& path,
                                                         const std::string& bodyId) {
    AssemblyPartGeometry geometry;

    const Result<Document> loaded = DocumentSerializer::loadFromFile(path);
    if (!loaded.isOk()) {
        geometry.error = QString::fromStdString(loaded.error().message);
        return geometry;
    }
    const Document& document = loaded.value();
    geometry.displayName =
        document.name().empty() ? QFileInfo(QString::fromStdString(path))
                                      .completeBaseName()
                                      .toStdString()
                                : document.name();

    // Base bodies: primitives (evaluateObject) or extruded profiles
    // (evaluateExtrude), exactly as MainWindow rebuilds them on load.
    std::map<std::string, kernel::ShapeHandle> shapes;
    std::vector<std::string> bodyOrder;
    for (const Object& object : document.objects()) {
        if (object.type != ObjectType::Body) {
            continue;
        }
        if (const Feature* extrude = extrudeFeatureForBody(document, object.id)) {
            const Result<Sketch> sketch =
                document.sketchById(extrude->extrude.sketchId);
            if (!sketch.isOk()) {
                continue;
            }
            const std::vector<SketchProfile> profiles =
                SketchProfileDetector().detect(sketch.value());
            const SketchProfile* profile = profileByIdOrLegacy(
                profiles, extrude->extrude.profileId, sketch.value());
            if (!profile) {
                continue;
            }
            const Result<kernel::EvaluatedGeometry> evaluated =
                evaluator_->evaluateExtrude(referenceForSketch(sketch.value()), *profile,
                                            extrude->extrude);
            if (evaluated.isOk() && evaluated.value().isValid &&
                !evaluated.value().shape.isNull()) {
                shapes[object.id] = evaluated.value().shape;
                bodyOrder.push_back(object.id);
            }
            continue;
        }
        const Result<kernel::EvaluatedGeometry> evaluated =
            evaluator_->evaluateObject(object);
        if (evaluated.isOk() && evaluated.value().isValid &&
            !evaluated.value().shape.isNull()) {
            shapes[object.id] = evaluated.value().shape;
            bodyOrder.push_back(object.id);
        }
    }

    // Replay modifier features in document order (cuts, then edge ops).
    for (const Feature& feature : document.features()) {
        if (feature.suppressed) {
            continue;
        }
        if (feature.type == FeatureType::ExtrudeCut) {
            const auto targetIt = shapes.find(feature.extrudeCut.targetBodyId);
            const Result<Sketch> sketch =
                document.sketchById(feature.extrudeCut.sketchId);
            if (targetIt == shapes.end() || targetIt->second.isNull() ||
                !sketch.isOk()) {
                continue;
            }
            const std::vector<SketchProfile> profiles =
                SketchProfileDetector().detect(sketch.value());
            const SketchProfile* profile = profileByIdOrLegacy(
                profiles, feature.extrudeCut.profileId, sketch.value());
            if (!profile || !profile->isValid) {
                continue;
            }
            const SketchReference reference = referenceForSketch(sketch.value());

            CutExtents extents;
            const Result<kernel::ShapeBounds> targetBounds =
                kernel_->boundingBox(targetIt->second);
            if (!targetBounds.isOk()) {
                continue;
            }
            accumulateProjectedBounds(targetBounds.value(), reference, extents.targetMin,
                                      extents.targetMax);
            extents.targetDiagonal = boundsDiagonal(targetBounds.value());
            if (feature.extrudeCut.depthMode == CutDepthMode::ToObject) {
                const auto limitIt = shapes.find(feature.extrudeCut.limitObjectId);
                if (limitIt == shapes.end() || limitIt->second.isNull()) {
                    continue;
                }
                const Result<kernel::ShapeBounds> limitBounds =
                    kernel_->boundingBox(limitIt->second);
                if (!limitBounds.isOk()) {
                    continue;
                }
                accumulateProjectedBounds(limitBounds.value(), reference,
                                          extents.limitMin, extents.limitMax);
                extents.hasLimit = true;
            }
            const Result<CutSpan> span = computeCutSpan(feature.extrudeCut, extents);
            if (!span.isOk()) {
                continue;
            }
            const Result<kernel::EvaluatedGeometry> evaluated =
                evaluator_->evaluateExtrudeCut(targetIt->second, reference, *profile,
                                               span.value());
            if (evaluated.isOk() && evaluated.value().isValid &&
                !evaluated.value().shape.isNull()) {
                shapes[feature.extrudeCut.targetBodyId] = evaluated.value().shape;
            }
        } else if (feature.type == FeatureType::Chamfer) {
            const auto targetIt = shapes.find(feature.chamfer.targetBodyId);
            if (targetIt == shapes.end() || targetIt->second.isNull()) {
                continue;
            }
            const Result<kernel::EvaluatedGeometry> evaluated =
                evaluator_->evaluateChamfer(targetIt->second, feature.chamfer);
            if (evaluated.isOk() && evaluated.value().isValid &&
                !evaluated.value().shape.isNull()) {
                shapes[feature.chamfer.targetBodyId] = evaluated.value().shape;
            }
        } else if (feature.type == FeatureType::Fillet) {
            const auto targetIt = shapes.find(feature.fillet.targetBodyId);
            if (targetIt == shapes.end() || targetIt->second.isNull()) {
                continue;
            }
            const Result<kernel::EvaluatedGeometry> evaluated =
                evaluator_->evaluateFillet(targetIt->second, feature.fillet);
            if (evaluated.isOk() && evaluated.value().isValid &&
                !evaluated.value().shape.isNull()) {
                shapes[feature.fillet.targetBodyId] = evaluated.value().shape;
            }
        }
    }

    if (shapes.empty()) {
        geometry.error = QCoreApplication::translate(
            "AssemblyPartLoader",
            "В документе детали нет тел с точной геометрией (нужно ядро OCCT)");
        return geometry;
    }

    // Pick the requested body, else the last one created.
    std::string chosenId = bodyId;
    if (chosenId.empty() || shapes.find(chosenId) == shapes.end()) {
        chosenId = bodyOrder.empty() ? shapes.begin()->first : bodyOrder.back();
    }
    AssemblyPartGeometry result =
        geometryFromShape(shapes.at(chosenId), geometry.displayName);
    return result;
}

AssemblyPartGeometry AssemblyPartLoader::loadUavPart(const std::string& path) {
    AssemblyPartGeometry geometry;

    bridge::UAVPartReader reader;
    const Result<bridge::UAVPartReadResult> read = reader.readFullPart(path);
    if (!read.isOk()) {
        geometry.error = QString::fromStdString(read.error().message);
        return geometry;
    }

    const bridge::UAVPartDescriptor& part = read.value().part;
    const std::string displayName = part.manifest.displayName.empty()
                                        ? part.manifest.name
                                        : part.manifest.displayName;

    if (!part.exactGeometry.valid || part.exactGeometry.payload.empty()) {
        geometry.error = QCoreApplication::translate(
            "AssemblyPartLoader", "В файле детали отсутствует точная геометрия");
        geometry.displayName = displayName;
        return geometry;
    }

    const Result<kernel::ShapeHandle> imported =
        kernel_->importBRep(part.exactGeometry.payload);
    if (!imported.isOk()) {
        geometry.error = QString::fromStdString(imported.error().message);
        geometry.displayName = displayName;
        return geometry;
    }

    geometry = geometryFromShape(imported.value(), displayName);
    return geometry;
}

AssemblyPartGeometry AssemblyPartLoader::geometryFromShape(const kernel::ShapeHandle& shape,
                                                           const std::string& displayName) {
    AssemblyPartGeometry geometry;
    geometry.displayName = displayName;

    const Result<kernel::EvaluatedGeometry> evaluated = evaluator_->evaluateShape(shape);
    if (!evaluated.isOk() || !evaluated.value().isValid ||
        evaluated.value().previewMesh.isEmpty()) {
        geometry.error = QCoreApplication::translate(
            "AssemblyPartLoader", "Не удалось построить отображаемую геометрию детали");
        return geometry;
    }
    geometry.mesh = evaluated.value().previewMesh;

    // Topology extraction in the part's own frame. The body id inside a
    // part file plays no role for assembly references (a .uavpart carries
    // exactly one body), so a stable constant keeps ids reproducible.
    kernel::FaceAnalyzer faceAnalyzer(*kernel_);
    geometry.topology.faces = faceAnalyzer.planarFacesForBody("part-body", shape);
    kernel::EdgeAnalyzer edgeAnalyzer(*kernel_);
    geometry.topology.edges = edgeAnalyzer.edgesForBody("part-body", shape);
    kernel::VertexAnalyzer vertexAnalyzer(*kernel_);
    geometry.topology.vertices = vertexAnalyzer.verticesForBody("part-body", shape);

    geometry.valid = true;
    return geometry;
}

} // namespace cadnext::gui
