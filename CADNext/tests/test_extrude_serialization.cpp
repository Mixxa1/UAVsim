#include "cadnext/Document.hpp"
#include "cadnext/DocumentSerializer.hpp"

#include <cassert>
#include <cmath>

int main() {
    {
        cadnext::Document document;
        document.setName("Extrude Roundtrip");

        // Sketch with a rectangle entity (the profile source).
        cadnext::Sketch sketch;
        sketch.id = "sketch-1";
        sketch.name = "Sketch XY 1";
        sketch.plane = cadnext::SketchPlane::XY;
        cadnext::SketchEntity rect;
        rect.id = "entity-1";
        rect.name = "Rectangle 1";
        rect.type = cadnext::SketchEntityType::Rectangle;
        rect.rectangle.origin = {0.0, 0.0};
        rect.rectangle.width = 2.0;
        rect.rectangle.height = 1.0;
        sketch.entities.push_back(rect);
        document.addSketch(sketch);

        // The generated body (mesh is derived, never saved).
        cadnext::Object body;
        body.id = "object-1";
        body.name = "Extrude Body 1";
        body.type = cadnext::ObjectType::Body;
        body.primitive.kind = cadnext::PrimitiveKind::None;
        document.addObject(body);

        // The extrude feature recipe.
        cadnext::Feature feature;
        feature.id = "feature-1";
        feature.name = "Extrude 1";
        feature.type = cadnext::FeatureType::Extrude;
        feature.targetObjectId = "object-1";
        feature.createdBodyId = "object-1";
        feature.extrude.sketchId = "sketch-1";
        feature.extrude.profileId = "entity-1";
        feature.extrude.operation = cadnext::ExtrudeOperation::NewBody;
        feature.extrude.direction = cadnext::ExtrudeDirection::Symmetric;
        feature.extrude.depthMode = cadnext::ExtrudeDepthMode::Distance;
        feature.extrude.distance = 3.25;
        document.addFeature(feature);

        const std::string json = cadnext::DocumentSerializer::toJson(document);
        const cadnext::Result<cadnext::Document> loaded =
            cadnext::DocumentSerializer::fromJson(json);
        assert(loaded.isOk());

        const cadnext::Document& restored = loaded.value();
        assert(restored.sketches().size() == 1);
        assert(restored.sketches()[0].entities.size() == 1);
        assert(restored.objects().size() == 1);
        assert(restored.objects()[0].id == "object-1");
        assert(restored.features().size() == 1);

        const cadnext::Feature& restoredFeature = restored.features()[0];
        assert(restoredFeature.type == cadnext::FeatureType::Extrude);
        assert(restoredFeature.id == "feature-1");
        assert(restoredFeature.createdBodyId == "object-1");
        assert(restoredFeature.extrude.sketchId == "sketch-1");
        assert(restoredFeature.extrude.profileId == "entity-1");
        assert(restoredFeature.extrude.operation == cadnext::ExtrudeOperation::NewBody);
        assert(restoredFeature.extrude.direction == cadnext::ExtrudeDirection::Symmetric);
        assert(restoredFeature.extrude.depthMode == cadnext::ExtrudeDepthMode::Distance);
        assert(std::fabs(restoredFeature.extrude.distance - 3.25) < 1.0e-12);
    }

    // Non-extrude features do not gain extrude members in the file, and
    // pre-0.6 documents (features without extrude data) still load.
    {
        cadnext::Document document;
        cadnext::Feature feature;
        feature.id = "feature-1";
        feature.name = "Sketch Feature";
        feature.type = cadnext::FeatureType::Sketch;
        document.addFeature(feature);

        const std::string json = cadnext::DocumentSerializer::toJson(document);
        assert(json.find("\"extrude\"") == std::string::npos);
        assert(json.find("\"createdBodyId\"") == std::string::npos);

        const cadnext::Result<cadnext::Document> loaded =
            cadnext::DocumentSerializer::fromJson(json);
        assert(loaded.isOk());
        assert(loaded.value().features().size() == 1);
        assert(loaded.value().features()[0].createdBodyId.empty());
        assert(loaded.value().features()[0].extrude.sketchId.empty());
    }

    return 0;
}
