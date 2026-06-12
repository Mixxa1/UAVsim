// CADNext 0.8A: selecting a triangle with face ownership produces a
// BodyFace selection state and enables face actions only for sketchable
// resolved faces.

#include "cadnext/Selection.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"

#include <cassert>

namespace {

bool faceActionsEnabled(const cadnext::SelectionState& selection,
                        const cadnext::kernel::FaceReference* face) {
    return selection.kind == cadnext::SelectionKind::BodyFace && selection.bodyId &&
           selection.faceId && face && face->isSketchable;
}

} // namespace

int main() {
    cadnext::kernel::FaceReference face;
    face.bodyId = "body-1";
    face.faceId = "face-top";
    face.kind = cadnext::kernel::FaceKind::Planar;
    face.isSketchable = true;

    cadnext::SelectionState selection;
    selection.kind = cadnext::SelectionKind::BodyFace;
    selection.bodyId = face.bodyId;
    selection.faceId = face.faceId;

    assert(selection.kind == cadnext::SelectionKind::BodyFace);
    assert(selection.bodyId && *selection.bodyId == "body-1");
    assert(selection.faceId && *selection.faceId == "face-top");
    assert(faceActionsEnabled(selection, &face));

    face.isSketchable = false;
    assert(!faceActionsEnabled(selection, &face));

    selection.kind = cadnext::SelectionKind::Body;
    selection.faceId.reset();
    assert(!faceActionsEnabled(selection, &face));

    return 0;
}
