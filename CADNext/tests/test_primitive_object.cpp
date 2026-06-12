#include "cadnext/Document.hpp"
#include "cadnext/Primitive.hpp"

#include <cassert>
#include <string>

int main() {
    cadnext::Document document;

    cadnext::Object box;
    box.id = "obj-box";
    box.name = "Box 1";
    box.type = cadnext::ObjectType::Body;
    box.primitive.kind = cadnext::PrimitiveKind::Box;
    box.primitive.width = 2.0;
    box.primitive.depth = 1.5;
    box.primitive.height = 1.0;
    document.addObject(box);

    cadnext::Object cylinder;
    cylinder.id = "obj-cylinder";
    cylinder.name = "Cylinder 1";
    cylinder.type = cadnext::ObjectType::Body;
    cylinder.primitive.kind = cadnext::PrimitiveKind::Cylinder;
    cylinder.primitive.radius = 0.5;
    cylinder.primitive.height = 1.2;
    document.addObject(cylinder);

    assert(document.objects().size() == 2);

    const auto foundBox = document.objectById("obj-box");
    assert(foundBox.isOk());
    assert(foundBox.value().primitive.kind == cadnext::PrimitiveKind::Box);
    assert(foundBox.value().primitive.width > 0.0);
    assert(foundBox.value().primitive.depth > 0.0);
    assert(foundBox.value().primitive.height > 0.0);
    assert(std::string(cadnext::primitiveKindName(foundBox.value().primitive.kind)) == "Box");

    const auto foundCylinder = document.objectById("obj-cylinder");
    assert(foundCylinder.isOk());
    assert(foundCylinder.value().primitive.kind == cadnext::PrimitiveKind::Cylinder);
    assert(foundCylinder.value().primitive.radius > 0.0);
    assert(foundCylinder.value().primitive.height > 0.0);

    // A freshly constructed object has no primitive descriptor.
    cadnext::Object plain;
    assert(plain.primitive.kind == cadnext::PrimitiveKind::None);

    // Renaming through the mutable accessor is visible on lookup.
    cadnext::Object* mutableBox = document.mutableObjectById("obj-box");
    assert(mutableBox != nullptr);
    mutableBox->name = "Renamed Box";
    assert(document.objectById("obj-box").value().name == "Renamed Box");

    // Removal updates the document and further lookups fail.
    assert(document.removeObject("obj-box"));
    assert(!document.removeObject("obj-box"));
    assert(document.objects().size() == 1);
    assert(!document.objectById("obj-box").isOk());

    return 0;
}
