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

    return 0;
}
