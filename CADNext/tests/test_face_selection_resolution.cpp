// CADNext 0.8: public selection contract for body-face picks. The GUI
// resolves Coin3D face pick proxies to this state before enabling face
// actions and showing face properties.

#include "cadnext/Selection.hpp"

#include <cassert>

int main() {
    cadnext::SelectionState empty;
    assert(empty.kind == cadnext::SelectionKind::None);
    assert(!empty.bodyId);
    assert(!empty.faceId);

    cadnext::BodyFaceSelection faceSelection{"body-1", "face-2-n-c-a"};
    cadnext::SelectionState state;
    state.kind = cadnext::SelectionKind::BodyFace;
    state.bodyId = faceSelection.bodyId;
    state.faceId = faceSelection.faceId;

    assert(state.kind == cadnext::SelectionKind::BodyFace);
    assert(state.bodyId && *state.bodyId == "body-1");
    assert(state.faceId && *state.faceId == "face-2-n-c-a");

    state.kind = cadnext::SelectionKind::Body;
    state.bodyId = "body-1";
    state.faceId.reset();
    assert(state.kind == cadnext::SelectionKind::Body);
    assert(state.bodyId && *state.bodyId == "body-1");
    assert(!state.faceId);

    return 0;
}
