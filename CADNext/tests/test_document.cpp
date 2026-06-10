#include "cadnext/Document.hpp"

#include <cassert>

int main() {
    cadnext::Document document;

    assert(!document.id().empty());
    document.setName("Airframe document");
    assert(document.name() == "Airframe document");

    cadnext::Object frame;
    frame.id = "obj-frame";
    frame.name = "Frame";
    frame.type = cadnext::ObjectType::Body;
    document.addObject(frame);

    const auto found = document.objectById("obj-frame");
    assert(found.isOk());
    assert(found.value().name == "Frame");

    const auto missing = document.objectById("missing");
    assert(!missing.isOk());
    assert(missing.error().code == cadnext::ErrorCode::NotFound);

    cadnext::Feature feature;
    feature.id = "feature-1";
    feature.name = "Base sketch";
    feature.type = cadnext::FeatureType::Sketch;
    feature.targetObjectId = "obj-frame";
    document.addFeature(feature);

    assert(document.features().size() == 1);
    assert(document.features().front().targetObjectId == "obj-frame");

    return 0;
}
