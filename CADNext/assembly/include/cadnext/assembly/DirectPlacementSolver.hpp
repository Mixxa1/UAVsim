#pragma once

#include "cadnext/assembly/AssemblyMath.hpp"
#include "cadnext/assembly/AssemblyModel.hpp"

namespace cadnext::assembly {

// Analytic placement path (assembly spec §9): for unambiguous single-mate
// situations and the interactive ghost preview,
//
//   T_child = T_parent × T_parentRef × T_joint × inverse(T_childRef)
//
// where T_*Ref are the local frames of the two picked geometry elements
// and T_joint encodes alignment (opposed flips the mated Z), the offset
// along the mated Z and the angle about it. Fast, deterministic, no
// numeric iteration. Partially-constraining joint types apply the minimal
// rotation/translation that satisfies the constraint instead of a full
// frame snap.
class DirectPlacementSolver {
public:
    struct Input {
        JointType type = JointType::Coincident;
        JointAlignment alignment = JointAlignment::Aligned;
        double offsetMeters = 0.0;
        double angleRadians = 0.0;

        // Assembly placement of the fixed (parent) component and the local
        // frame of its picked element.
        Placement parentPlacement;
        Frame parentLocalFrame;

        // Current assembly placement of the moved (child) component and
        // the local frame of its picked element.
        Placement childPlacement;
        Frame childLocalFrame;

        // Rigid joints with a captured mutual position.
        bool hasCapturedRelativePlacement = false;
        Placement capturedRelativePlacement;
    };

    // New assembly placement of the child component.
    static Placement solveChildPlacement(const Input& input);
};

} // namespace cadnext::assembly
