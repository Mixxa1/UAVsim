#pragma once

// Offscreen OpenGL for Coin on macOS.
//
// Coin's built-in offscreen path (SoOffscreenRenderer) uses CGL pbuffers and the software
// renderer, both gone from current macOS. Coin lets an application supply the context instead;
// this installs an accelerated CGL context rendering into a framebuffer object. Call once,
// before SoDB::init() in a tool, or before the first SoOffscreenRenderer in an application.

namespace cadnext::viewer {

void installOffscreenGLContext();

} // namespace cadnext::viewer
