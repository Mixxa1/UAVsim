// UAVPart v1: точный объём и центр масс через BRepGProp (Kernel::
// volumeProperties). Масса детали в .uavpart считается из этих величин,
// никогда из preview-меша.

#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>
#include <cmath>
#include <cstdio>

namespace {

bool nearlyEqual(double a, double b, double tolerance) {
    return std::fabs(a - b) <= tolerance;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    assert(kernel.isAvailable());

    // Брусок 0.2 × 0.1 × 0.05 м, центрированный на начале координат:
    // объём ровно 1e-3 м³, центр масс в нуле.
    const auto box = kernel.makeBox({0.2, 0.05, 0.1}); // width=X, height=Z, depth=Y
    assert(box.isOk());
    const auto boxProps = kernel.volumeProperties(box.value());
    assert(boxProps.isOk());
    assert(nearlyEqual(boxProps.value().volumeM3, 0.2 * 0.1 * 0.05, 1e-9));
    assert(nearlyEqual(boxProps.value().centerOfMass.x, 0.0, 1e-9));
    assert(nearlyEqual(boxProps.value().centerOfMass.y, 0.0, 1e-9));
    assert(nearlyEqual(boxProps.value().centerOfMass.z, 0.0, 1e-9));

    // Цилиндр r=0.05, h=0.1: V = π r² h.
    const auto cylinder = kernel.makeCylinder({0.05, 0.1});
    assert(cylinder.isOk());
    const auto cylinderProps = kernel.volumeProperties(cylinder.value());
    assert(cylinderProps.isOk());
    const double expected = M_PI * 0.05 * 0.05 * 0.1;
    assert(nearlyEqual(cylinderProps.value().volumeM3, expected, expected * 1e-6));

    // Масса = объём × плотность: ABS 1050 кг/м³ для бруска выше — 1.05 кг.
    const double massKg = boxProps.value().volumeM3 * 1050.0;
    assert(nearlyEqual(massKg, 1.05, 1e-6));

    // Невалидный handle не возвращает фальшивых свойств.
    const auto bad = kernel.volumeProperties(cadnext::kernel::ShapeHandle());
    assert(!bad.isOk());

    std::printf("test_occt_mass_properties: OK\n");
    return 0;
}
