#include "cadnext/DocumentSerializer.hpp"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <string>

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1e-9;
}

cadnext::Document buildSampleDocument() {
    cadnext::Document document;
    document.setName("Serialization Sample");

    cadnext::Object box;
    box.id = "object-1";
    box.name = "Box \"quoted\" 1";
    box.type = cadnext::ObjectType::Body;
    box.primitive.kind = cadnext::PrimitiveKind::Box;
    box.primitive.width = 2.5;
    box.primitive.height = 0.75;
    box.primitive.depth = 1.25;
    box.transform.position = {1.0, -2.0, 0.375};
    box.transform.rotationEuler = {0.0, 0.0, 30.0};
    box.transform.scale = {1.0, 2.0, 3.0};
    document.addObject(box);

    cadnext::Object cylinder;
    cylinder.id = "object-2";
    cylinder.name = "Cylinder 1";
    cylinder.type = cadnext::ObjectType::Body;
    cylinder.primitive.kind = cadnext::PrimitiveKind::Cylinder;
    cylinder.primitive.radius = 0.5;
    cylinder.primitive.height = 1.2;
    cylinder.transform.position = {-3.0, 4.0, 0.6};
    document.addObject(cylinder);

    return document;
}

void verifyRoundTrip(const cadnext::Document& original, const cadnext::Document& loaded) {
    assert(loaded.id() == original.id());
    assert(loaded.name() == original.name());
    assert(loaded.unitSystem() == original.unitSystem());
    assert(loaded.objects().size() == original.objects().size());

    for (size_t i = 0; i < original.objects().size(); ++i) {
        const cadnext::Object& a = original.objects()[i];
        const cadnext::Object& b = loaded.objects()[i];
        assert(a.id == b.id);
        assert(a.name == b.name);
        assert(a.type == b.type);
        assert(a.primitive.kind == b.primitive.kind);
        assert(nearlyEqual(a.primitive.width, b.primitive.width));
        assert(nearlyEqual(a.primitive.height, b.primitive.height));
        assert(nearlyEqual(a.primitive.depth, b.primitive.depth));
        assert(nearlyEqual(a.primitive.radius, b.primitive.radius));
        assert(nearlyEqual(a.transform.position.x, b.transform.position.x));
        assert(nearlyEqual(a.transform.position.y, b.transform.position.y));
        assert(nearlyEqual(a.transform.position.z, b.transform.position.z));
        assert(nearlyEqual(a.transform.rotationEuler.z, b.transform.rotationEuler.z));
        assert(nearlyEqual(a.transform.scale.y, b.transform.scale.y));
        assert(nearlyEqual(a.transform.scale.z, b.transform.scale.z));
    }
}

} // namespace

int main() {
    const cadnext::Document document = buildSampleDocument();

    // String round trip.
    const std::string json = cadnext::DocumentSerializer::toJson(document);
    assert(json.find("\"format\": \"cadnext\"") != std::string::npos);
    assert(json.find("\"version\": 1") != std::string::npos);

    const auto fromString = cadnext::DocumentSerializer::fromJson(json);
    assert(fromString.isOk());
    verifyRoundTrip(document, fromString.value());

    // File round trip.
    const std::string path = "test_document_serialization_tmp.cadnext";
    const auto saved = cadnext::DocumentSerializer::saveToFile(document, path);
    assert(saved.isOk());
    const auto fromFile = cadnext::DocumentSerializer::loadFromFile(path);
    assert(fromFile.isOk());
    verifyRoundTrip(document, fromFile.value());
    std::remove(path.c_str());

    // Invalid inputs are rejected with SerializationFailed.
    const auto notJson = cadnext::DocumentSerializer::fromJson("not json at all");
    assert(!notJson.isOk());
    assert(notJson.error().code == cadnext::ErrorCode::SerializationFailed);

    const auto wrongFormat = cadnext::DocumentSerializer::fromJson("{\"format\": \"other\"}");
    assert(!wrongFormat.isOk());

    const auto wrongVersion = cadnext::DocumentSerializer::fromJson(
        "{\"format\": \"cadnext\", \"version\": 999, \"document\": {}}");
    assert(!wrongVersion.isOk());

    const auto missingFile = cadnext::DocumentSerializer::loadFromFile("does-not-exist.cadnext");
    assert(!missingFile.isOk());

    // Chamfer/Fillet feature metadata roundtrip (resulting BRep/mesh is
    // derived/transient; feature recipes are the serialized contract).
    cadnext::Document edgeOps;
    cadnext::Object body;
    body.id = "object-1";
    body.name = "Box 1";
    body.type = cadnext::ObjectType::Body;
    body.primitive.kind = cadnext::PrimitiveKind::Box;
    edgeOps.addObject(body);

    cadnext::Feature chamfer;
    chamfer.id = "feature-1";
    chamfer.name = "Chamfer 1";
    chamfer.type = cadnext::FeatureType::Chamfer;
    chamfer.targetObjectId = "object-1";
    chamfer.modifiedBodyId = "object-1";
    chamfer.chamfer.targetBodyId = "object-1";
    chamfer.chamfer.edgeIds = {"edge-0-saaa-eaaa-laaa"};
    chamfer.chamfer.mode = cadnext::ChamferMode::DistanceAngle;
    chamfer.chamfer.distanceMm = 12.5;
    chamfer.chamfer.angleDeg = 30.0;
    edgeOps.addFeature(chamfer);

    cadnext::Feature fillet;
    fillet.id = "feature-2";
    fillet.name = "Fillet 1";
    fillet.type = cadnext::FeatureType::Fillet;
    fillet.targetObjectId = "object-1";
    fillet.modifiedBodyId = "object-1";
    fillet.fillet.targetBodyId = "object-1";
    fillet.fillet.edgeIds = {"edge-1-sbbb-ebbb-lbbb"};
    fillet.fillet.radiusMm = 25.0;
    edgeOps.addFeature(fillet);

    const std::string edgeJson = cadnext::DocumentSerializer::toJson(edgeOps);
    assert(edgeJson.find("\"chamfer\"") != std::string::npos);
    assert(edgeJson.find("\"fillet\"") != std::string::npos);
    const auto edgeRoundtrip = cadnext::DocumentSerializer::fromJson(edgeJson);
    assert(edgeRoundtrip.isOk());
    assert(edgeRoundtrip.value().features().size() == 2);
    assert(edgeRoundtrip.value().features()[0].type == cadnext::FeatureType::Chamfer);
    assert(edgeRoundtrip.value().features()[0].chamfer.edgeIds.size() == 1);
    assert(edgeRoundtrip.value().features()[0].chamfer.edgeIds[0] ==
           "edge-0-saaa-eaaa-laaa");
    assert(edgeRoundtrip.value().features()[0].chamfer.mode ==
           cadnext::ChamferMode::DistanceAngle);
    assert(nearlyEqual(edgeRoundtrip.value().features()[0].chamfer.distanceMm, 12.5));
    assert(nearlyEqual(edgeRoundtrip.value().features()[0].chamfer.angleDeg, 30.0));
    assert(edgeRoundtrip.value().features()[1].type == cadnext::FeatureType::Fillet);
    assert(edgeRoundtrip.value().features()[1].fillet.edgeIds.size() == 1);
    assert(edgeRoundtrip.value().features()[1].fillet.edgeIds[0] ==
           "edge-1-sbbb-ebbb-lbbb");
    assert(nearlyEqual(edgeRoundtrip.value().features()[1].fillet.radiusMm, 25.0));

    // Legacy pre-0.9.x files stored "distance"/"radius" in model units;
    // they load as millimeters.
    const std::string legacyJson =
        "{\"format\": \"cadnext\", \"version\": 1, \"document\": {\"name\": \"L\","
        " \"objects\": [], \"workPlanes\": [], \"sketches\": [], \"features\": ["
        "  {\"id\": \"feature-1\", \"name\": \"Chamfer 1\", \"type\": \"Chamfer\","
        "   \"targetObjectId\": \"object-1\", \"chamfer\": {\"targetBodyId\": \"object-1\","
        "   \"edgeIds\": [\"edge-0\"], \"mode\": \"EqualDistance\", \"distance\": 0.125},"
        "   \"suppressed\": false},"
        "  {\"id\": \"feature-2\", \"name\": \"Fillet 1\", \"type\": \"Fillet\","
        "   \"targetObjectId\": \"object-1\", \"fillet\": {\"targetBodyId\": \"object-1\","
        "   \"edgeIds\": [\"edge-1\"], \"radius\": 0.25}, \"suppressed\": false}"
        "]}}";
    const auto legacy = cadnext::DocumentSerializer::fromJson(legacyJson);
    assert(legacy.isOk());
    assert(legacy.value().features().size() == 2);
    assert(legacy.value().features()[0].chamfer.mode == cadnext::ChamferMode::EqualDistance);
    assert(nearlyEqual(legacy.value().features()[0].chamfer.distanceMm, 125.0));
    assert(nearlyEqual(legacy.value().features()[1].fillet.radiusMm, 250.0));

    return 0;
}
