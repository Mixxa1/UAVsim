#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdlib>
#include <filesystem>

int main() {
    cadnext::kernel::OcctKernel kernel;
    cadnext::kernel::GeometryEvaluator evaluator(kernel);
    cadnext::SketchReference reference;
    cadnext::SketchProfile profile;
    profile.id = "profile-rectangle";
    profile.isClosed = true;
    profile.isValid = true;
    profile.kind = cadnext::SketchProfileKind::Rectangle;
    profile.outerLoop = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
    cadnext::RevolveParameters params;
    params.sketchId = "sketch-1";
    params.profileId = profile.id;
    params.axis = cadnext::RevolveAxis::V;
    auto cylinder = evaluator.evaluateRevolve(reference, profile, params);
    assert(cylinder.isOk() && cylinder.value().isValid);
    auto volume = kernel.volumeProperties(cylinder.value().shape);
    assert(volume.isOk());
    assert(std::fabs(volume.value().volumeM3 - M_PI) < 1.0e-5);

    params.angleDegrees = 180.0;
    auto half = evaluator.evaluateRevolve(reference, profile, params);
    assert(half.isOk() && half.value().isValid);
    volume = kernel.volumeProperties(half.value().shape);
    assert(volume.isOk());
    assert(std::fabs(volume.value().volumeM3 - M_PI / 2.0) < 1.0e-5);

    profile.outerLoop = {{-1, 0}, {1, 0}, {1, 1}, {-1, 1}};
    assert(!evaluator.evaluateRevolve(reference, profile, params).isOk());

    cadnext::Document document;
    cadnext::Object body;
    body.id = "object-1";
    body.type = cadnext::ObjectType::Body;
    body.primitive.kind = cadnext::PrimitiveKind::None;
    const auto bytes = kernel.exportBRepGeometry(cylinder.value().shape);
    assert(bytes.isOk() && !bytes.value().empty());
    body.importedBRep = bytes.value();
    document.addObject(body);
    cadnext::Feature feature;
    feature.id = "feature-1";
    feature.type = cadnext::FeatureType::Revolve;
    feature.createdBodyId = body.id;
    feature.revolve = params;
    document.addFeature(feature);
    const auto loaded = cadnext::DocumentSerializer::fromJson(
        cadnext::DocumentSerializer::toJson(document));
    assert(loaded.isOk());
    assert(loaded.value().objects().front().importedBRep == bytes.value());
    assert(loaded.value().features().front().type == cadnext::FeatureType::Revolve);
    assert(loaded.value().features().front().revolve.angleDegrees == 180.0);

    const auto prefix = std::filesystem::temp_directory_path() / "cadnext-revolve-exchange";
    cadnext::kernel::ExchangeBody placed;
    placed.shape = cylinder.value().shape;
    placed.placement.position = {2, 0, 0};
    for (const char* suffix : {".step", ".iges"}) {
        const auto path = prefix.string() + suffix;
        const auto saved = kernel.exportExchangeFile({placed}, path);
        assert(saved.isOk());
        const auto imported = kernel.importExchangeFile(path);
        assert(imported.isOk());
        const auto mesh = evaluator.evaluateShape(imported.value());
        assert(mesh.isOk() && mesh.value().isValid);
        double minx = 1e30, maxx = -1e30;
        for (const auto& v : mesh.value().previewMesh.vertices) {
            minx = std::min(minx, v.x);
            maxx = std::max(maxx, v.x);
        }
        assert(std::fabs(minx - 1.0) < 5.0e-3);
        assert(std::fabs(maxx - 3.0) < 5.0e-3);
        std::filesystem::remove(path);
    }

    // Export uses the document placement, including nonuniform scale and
    // rotation, rather than the kernel shape's local coordinates.
    const auto box = kernel.makeBox({2.0, 1.0, 1.0});
    assert(box.isOk());
    cadnext::kernel::ExchangeBody transformed;
    transformed.shape = box.value();
    transformed.placement.position = {3, 4, 0};
    transformed.placement.rotationEuler = {0, 0, 90};
    transformed.placement.scale = {2, 1, 1};
    const auto transformedPath = prefix.string() + "-placed.step";
    assert(kernel.exportExchangeFile({transformed}, transformedPath).isOk());
    const auto importedBox = kernel.importExchangeFile(transformedPath);
    assert(importedBox.isOk());
    const auto placedMesh = evaluator.evaluateShape(importedBox.value());
    assert(placedMesh.isOk() && placedMesh.value().isValid);
    double minx = 1e30, maxx = -1e30, miny = 1e30, maxy = -1e30;
    for (const auto& vertex : placedMesh.value().previewMesh.vertices) {
        minx = std::min(minx, vertex.x); maxx = std::max(maxx, vertex.x);
        miny = std::min(miny, vertex.y); maxy = std::max(maxy, vertex.y);
    }
    assert(std::fabs(minx - 2.5) < 5.0e-3);
    assert(std::fabs(maxx - 3.5) < 5.0e-3);
    assert(std::fabs(miny - 2.0) < 5.0e-3);
    assert(std::fabs(maxy - 6.0) < 5.0e-3);
    std::filesystem::remove(transformedPath);

    const auto assemblyPath = prefix.string() + "-assembly.step";
    cadnext::kernel::ExchangeBody left{box.value(), {}};
    cadnext::kernel::ExchangeBody right{box.value(), {}};
    right.placement.position = {5, 0, 0};
    assert(kernel.exportStepAssembly({{"Левая", left}, {"Right", right}},
                                     assemblyPath).isOk());
    const auto assembly = kernel.importStepAssembly(assemblyPath);
    assert(assembly.isOk());
    assert(assembly.value().size() == 2);
    assert(assembly.value()[0].name == "Левая");
    assert(assembly.value()[1].name == "Right");
    const auto leftBounds = kernel.boundingBox(assembly.value()[0].shape);
    const auto rightBounds = kernel.boundingBox(assembly.value()[1].shape);
    assert(leftBounds.isOk() && rightBounds.isOk());
    assert(std::fabs(leftBounds.value().min.x + 1.0) < 1e-6);
    assert(std::fabs(rightBounds.value().min.x - 4.0) < 1e-6);
    const auto leftVolume = kernel.volumeProperties(assembly.value()[0].shape);
    const auto rightVolume = kernel.volumeProperties(assembly.value()[1].shape);
    assert(leftVolume.isOk() && rightVolume.isOk());
    assert(std::fabs(leftVolume.value().volumeM3 - 2.0) < 1e-6);
    assert(std::fabs(rightVolume.value().volumeM3 - 2.0) < 1e-6);
    const auto neutralAssembly = kernel.importExchangeFile(assemblyPath);
    assert(neutralAssembly.isOk());
    const auto neutralVolume = kernel.volumeProperties(neutralAssembly.value());
    assert(neutralVolume.isOk());
    assert(std::fabs(neutralVolume.value().volumeM3 - 4.0) < 1e-6);
    std::filesystem::remove(assemblyPath);

    if (const char* fixture = std::getenv("CADNEXT_TEST_STEP_FILE")) {
        const auto external = kernel.importStepAssembly(fixture);
        assert(external.isOk() && !external.value().empty());
        bool foundSolid = false;
        for (const auto& item : external.value()) {
            assert(kernel.isShapeValid(item.shape));
            const auto mesh = evaluator.evaluateShape(item.shape);
            assert(mesh.isOk() && mesh.value().isValid &&
                   !mesh.value().previewMesh.isEmpty());
            const auto mass = kernel.volumeProperties(item.shape);
            foundSolid = foundSolid || mass.isOk();
        }
        assert(foundSolid);
    }
}
