#include "cadnext/Document.hpp"

#include <cassert>

int main() {
    cadnext::Document document;

    cadnext::Object box;
    box.id = "obj-box";
    box.name = "Box 1";
    box.type = cadnext::ObjectType::Body;
    box.primitive.kind = cadnext::PrimitiveKind::Box;
    document.addObject(box);

    // Rename through the mutable accessor; the id must not change.
    cadnext::Object* mutableBox = document.mutableObjectById("obj-box");
    assert(mutableBox != nullptr);
    mutableBox->name = "Main Body";
    assert(document.objectById("obj-box").isOk());
    assert(document.objectById("obj-box").value().name == "Main Body");
    assert(document.objectById("obj-box").value().id == "obj-box");

    // Transform update.
    mutableBox->transform.position = {1.0, 2.0, 3.0};
    mutableBox->transform.rotationEuler = {0.0, 0.0, 45.0};
    mutableBox->transform.scale = {2.0, 2.0, 2.0};
    {
        const auto found = document.objectById("obj-box");
        assert(found.isOk());
        assert(found.value().transform.position.y == 2.0);
        assert(found.value().transform.rotationEuler.z == 45.0);
        assert(found.value().transform.scale.x == 2.0);
    }

    // Primitive parameter update.
    mutableBox->primitive.width = 4.0;
    mutableBox->primitive.height = 0.5;
    {
        const auto found = document.objectById("obj-box");
        assert(found.value().primitive.width == 4.0);
        assert(found.value().primitive.height == 0.5);
        assert(found.value().primitive.kind == cadnext::PrimitiveKind::Box);
    }

    // Unknown ids are rejected.
    assert(document.mutableObjectById("missing") == nullptr);

    // removeObject clears the object.
    assert(document.removeObject("obj-box"));
    assert(document.objects().empty());
    assert(!document.objectById("obj-box").isOk());
    assert(document.mutableObjectById("obj-box") == nullptr);

    return 0;
}
