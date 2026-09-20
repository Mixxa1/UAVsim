#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/cfd/FlowSection.hpp"

#include <string>
#include <vector>

// Time frames of a time-accurate run, kept for the one section the result window shows.
//
// A URANS run writes the whole volume field at every output step. On an airframe mesh that is a few
// hundred megabytes a frame — forty frames would fill a disk with data nobody looks at. The window
// shows one plane, and a plane cuts only a small share of the cells, so each frame is reduced, as
// soon as SU2 has finished writing it, to the velocities of the mesh nodes that plane uses
// (`section_<step>.csv`: PointID, Velocity_x, Velocity_y, Velocity_z), and the full frame is removed.
// The last full frame is kept as the point's volume field.
//
// Which plane: the one halfway along the span of the walls (solver y), the same rule the window
// uses; `section.json` records it so the two can never disagree.

namespace cadnext::cfd {

// Mesh nodes used by the cut at planeY (see FlowSection::referencedNodes), from a mesh file.
Result<std::vector<std::size_t>> sectionNodes(const std::string& meshPath, double planeY);

// Halfway along the span (solver y) of every node on a non-far-field marker of the mesh.
Result<double> midSpanPlane(const std::string& meshPath);

// Reduces a SU2 volume CSV to the given nodes' velocities and writes it to `sectionPath`.
Result<bool> writeSectionFrame(const std::string& volumePath, const std::vector<std::size_t>& nodes, const std::string& sectionPath);

// Reads a section frame into the order of `nodes` (a section's referencedNodes()). Fails if any node
// is missing — a frame still being written, or one taken on a different plane.
Result<std::vector<FlowSection::Vector>> readSectionFrame(const std::string& sectionPath, const std::vector<std::size_t>& nodes);

} // namespace cadnext::cfd
