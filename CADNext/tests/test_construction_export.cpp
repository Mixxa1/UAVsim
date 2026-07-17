// Construction export (.uavframe): the flattened airframe bundle survives
// toJson/fromJson unchanged — merged mesh, aggregated mass/CoM/bounds,
// collision proxy and mount points.
#include "cadnext/bridge/ConstructionExport.hpp"

#include <cassert>
#include <cmath>

using namespace cadnext::bridge;

namespace {

bool nearly(double a, double b, double tol = 1.0e-6) {
    return std::fabs(a - b) <= tol;
}

} // namespace

int main() {
    ConstructionDescriptor descriptor;
    descriptor.id = "frame-1";
    descriptor.name = "Recon Airframe";
    descriptor.massKg = 1.234;
    descriptor.centerOfMass = {0.01, -0.02, 0.03};
    descriptor.boundingBoxMin = {-0.5, -0.4, -0.1};
    descriptor.boundingBoxMax = {0.5, 0.4, 0.1};
    descriptor.collisionCenter = {0.0, 0.0, 0.0};
    descriptor.collisionSize = {1.0, 0.8, 0.2};

    descriptor.mesh.vertices = {0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f};
    descriptor.mesh.indices = {0, 1, 2};

    ConstructionAttachmentPoint motor;
    motor.id = "left-wing::motor-1";
    motor.name = "Left Wing / Motor Boss";
    motor.role = "motor";
    motor.position = {0.3, 0.0, 0.05};
    motor.rotation = {0.0, 0.0, 90.0};
    descriptor.attachmentPoints.push_back(motor);

    ConstructionAttachmentPoint battery;
    battery.id = "fuselage::bay-1";
    battery.name = "Fuselage / Battery Bay";
    battery.role = "battery";
    battery.position = {0.0, -0.05, 0.0};
    descriptor.attachmentPoints.push_back(battery);

    const std::string jsonText = ConstructionExport::toJson(descriptor);
    const auto loaded = ConstructionExport::fromJson(jsonText);
    assert(loaded.isOk());
    const ConstructionDescriptor& restored = loaded.value();

    assert(restored.id == "frame-1");
    assert(restored.name == "Recon Airframe");
    assert(nearly(restored.massKg, 1.234));
    assert(nearly(restored.centerOfMass.x, 0.01));
    assert(nearly(restored.centerOfMass.z, 0.03));
    assert(nearly(restored.boundingBoxMin.y, -0.4));
    assert(nearly(restored.boundingBoxMax.x, 0.5));
    assert(nearly(restored.collisionSize.x, 1.0));

    assert(restored.mesh.vertices.size() == 9);
    assert(nearly(restored.mesh.vertices[3], 1.0));
    assert(restored.mesh.indices.size() == 3);
    assert(restored.mesh.indices[2] == 2);

    assert(restored.attachmentPoints.size() == 2);
    assert(restored.attachmentPoints[0].id == "left-wing::motor-1");
    assert(restored.attachmentPoints[0].role == "motor");
    assert(nearly(restored.attachmentPoints[0].position.x, 0.3));
    assert(nearly(restored.attachmentPoints[0].rotation.z, 90.0));
    assert(restored.attachmentPoints[1].role == "battery");

    // A non-uavframe / malformed document fails cleanly.
    assert(!ConstructionExport::fromJson("{}").isOk());
    assert(!ConstructionExport::fromJson("not json").isOk());

    return 0;
}
