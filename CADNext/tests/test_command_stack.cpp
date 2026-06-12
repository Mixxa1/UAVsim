#include "cadnext/CommandStack.hpp"

#include <cassert>
#include <memory>

int main() {
    cadnext::Document document;

    cadnext::Object box;
    box.id = "obj-box";
    box.name = "Box 1";
    box.type = cadnext::ObjectType::Body;
    document.addObject(box);

    cadnext::CommandStack stack;
    assert(!stack.canUndo());
    assert(!stack.canRedo());

    // push() executes the command.
    stack.push(std::make_unique<cadnext::RenameObjectCommand>("obj-box", "Box 1", "Frame"),
               document);
    assert(document.objectById("obj-box").value().name == "Frame");
    assert(stack.canUndo());
    assert(!stack.canRedo());
    assert(stack.undoCount() == 1);

    // undo() restores the old name.
    stack.undo(document);
    assert(document.objectById("obj-box").value().name == "Box 1");
    assert(!stack.canUndo());
    assert(stack.canRedo());

    // redo() re-applies the rename.
    stack.redo(document);
    assert(document.objectById("obj-box").value().name == "Frame");
    assert(stack.canUndo());
    assert(!stack.canRedo());

    // A new push after undo clears the redo history.
    stack.undo(document);
    assert(stack.canRedo());
    stack.push(std::make_unique<cadnext::RenameObjectCommand>("obj-box", "Box 1", "Hull"),
               document);
    assert(!stack.canRedo());
    assert(document.objectById("obj-box").value().name == "Hull");

    // Undo/redo on a deleted object are safe no-ops.
    document.removeObject("obj-box");
    stack.undo(document);
    stack.redo(document);
    assert(!document.objectById("obj-box").isOk());

    cadnext::Object extrudedBody;
    extrudedBody.id = "obj-extrude";
    extrudedBody.name = "Extruded Body";
    extrudedBody.type = cadnext::ObjectType::Body;

    cadnext::Feature extrudeFeature;
    extrudeFeature.id = "feature-extrude";
    extrudeFeature.name = "Extrude";
    extrudeFeature.type = cadnext::FeatureType::Extrude;
    extrudeFeature.createdBodyId = extrudedBody.id;
    extrudeFeature.targetObjectId = extrudedBody.id;

    stack.push(std::make_unique<cadnext::AddObjectWithFeatureCommand>(
                   extrudedBody, extrudeFeature),
               document);
    assert(document.objectById("obj-extrude").isOk());
    assert(document.featureById("feature-extrude").isOk());
    stack.undo(document);
    assert(!document.objectById("obj-extrude").isOk());
    assert(!document.featureById("feature-extrude").isOk());
    stack.redo(document);
    assert(document.objectById("obj-extrude").isOk());
    assert(document.featureById("feature-extrude").isOk());

    cadnext::Feature cutFeature;
    cutFeature.id = "feature-cut";
    cutFeature.name = "Cut";
    cutFeature.type = cadnext::FeatureType::ExtrudeCut;
    cutFeature.targetObjectId = "obj-extrude";
    cutFeature.modifiedBodyId = "obj-extrude";

    stack.push(std::make_unique<cadnext::AddFeatureCommand>(cutFeature), document);
    assert(document.featureById("feature-cut").isOk());
    stack.undo(document);
    assert(!document.featureById("feature-cut").isOk());
    assert(document.objectById("obj-extrude").isOk());
    stack.redo(document);
    assert(document.featureById("feature-cut").isOk());

    // Undo/redo on an empty stack are no-ops.
    stack.clear();
    assert(!stack.canUndo());
    assert(!stack.canRedo());
    stack.undo(document);
    stack.redo(document);

    return 0;
}
