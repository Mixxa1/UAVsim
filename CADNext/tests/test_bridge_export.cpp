#include "cadnext/Document.hpp"
#include "cadnext/bridge/UAVSimBridge.hpp"

#include <cassert>

int main() {
    cadnext::Document document;
    document.setName("Bridge test");

    cadnext::Object payloadMount;
    payloadMount.id = "obj-payload-mount";
    payloadMount.name = "Payload mount";
    payloadMount.type = cadnext::ObjectType::Body;
    payloadMount.attachmentPoints.push_back(cadnext::AttachmentPoint{
        "ap-payload",
        "Payload",
        cadnext::Vector3{0.0, 0.0, 0.0},
        cadnext::Vector3{0.0, 0.0, 0.0},
        cadnext::AttachmentRole::Payload,
        true,
        true
    });
    document.addObject(payloadMount);

    cadnext::bridge::UAVSimBridge bridge;
    const auto package = bridge.makeExportPackage(document);

    assert(package.id == document.id());
    assert(package.name == "Bridge test");
    assert(package.attachments.size() == 1);
    assert(package.attachments.front().role == "payload");
    assert(package.mass.massKg == 0.0);

    return 0;
}
