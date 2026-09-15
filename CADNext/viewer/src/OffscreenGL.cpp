#include "cadnext/viewer/OffscreenGL.hpp"

#include <Inventor/C/glue/gl.h>

#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>

namespace cadnext::viewer {

namespace {

// Coin's built-in offscreen path uses CGL pbuffers and the software renderer, both gone from
// current macOS. Coin lets an application supply the context instead: an accelerated CGL
// context rendering into a framebuffer object of the requested size.
struct OffscreenContext {
    CGLContextObj context = nullptr;
    CGLContextObj previous = nullptr;
    GLuint framebuffer = 0;
    GLuint color = 0;
    GLuint depth = 0;
    unsigned int width = 0;
    unsigned int height = 0;
};

cc_glglue_offscreen_data createOffscreen(unsigned int width, unsigned int height) {
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAAccelerated, kCGLPFAColorSize, static_cast<CGLPixelFormatAttribute>(24),
        kCGLPFAAlphaSize, static_cast<CGLPixelFormatAttribute>(8), kCGLPFADepthSize,
        static_cast<CGLPixelFormatAttribute>(24), kCGLPFAAllowOfflineRenderers, static_cast<CGLPixelFormatAttribute>(0)};
    CGLPixelFormatObj format = nullptr;
    GLint formats = 0;
    if (CGLChoosePixelFormat(attributes, &format, &formats) != kCGLNoError || format == nullptr) return nullptr;
    auto* offscreen = new OffscreenContext;
    const CGLError error = CGLCreateContext(format, nullptr, &offscreen->context);
    CGLReleasePixelFormat(format);
    if (error != kCGLNoError) {
        delete offscreen;
        return nullptr;
    }
    offscreen->width = width;
    offscreen->height = height;
    return offscreen;
}

SbBool makeCurrent(cc_glglue_offscreen_data data) {
    auto* offscreen = static_cast<OffscreenContext*>(data);
    offscreen->previous = CGLGetCurrentContext();
    if (CGLSetCurrentContext(offscreen->context) != kCGLNoError) return FALSE;
    if (offscreen->framebuffer == 0) {
        glGenFramebuffersEXT(1, &offscreen->framebuffer);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, offscreen->framebuffer);
        glGenRenderbuffersEXT(1, &offscreen->color);
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, offscreen->color);
        glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, offscreen->width, offscreen->height);
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_RENDERBUFFER_EXT, offscreen->color);
        glGenRenderbuffersEXT(1, &offscreen->depth);
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, offscreen->depth);
        glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT24, offscreen->width, offscreen->height);
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, offscreen->depth);
        if (glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) != GL_FRAMEBUFFER_COMPLETE_EXT) return FALSE;
    }
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, offscreen->framebuffer);
    return TRUE;
}

void reinstatePrevious(cc_glglue_offscreen_data data) {
    auto* offscreen = static_cast<OffscreenContext*>(data);
    CGLSetCurrentContext(offscreen->previous);
}

void destruct(cc_glglue_offscreen_data data) {
    auto* offscreen = static_cast<OffscreenContext*>(data);
    if (offscreen->context != nullptr) {
        CGLSetCurrentContext(offscreen->context);
        if (offscreen->framebuffer) glDeleteFramebuffersEXT(1, &offscreen->framebuffer);
        if (offscreen->color) glDeleteRenderbuffersEXT(1, &offscreen->color);
        if (offscreen->depth) glDeleteRenderbuffersEXT(1, &offscreen->depth);
        CGLSetCurrentContext(nullptr);
        CGLDestroyContext(offscreen->context);
    }
    delete offscreen;
}


} // namespace

void installOffscreenGLContext() {
    static cc_glglue_offscreen_cb_functions callbacks = {createOffscreen, makeCurrent, reinstatePrevious, destruct};
    cc_glglue_context_set_offscreen_cb_functions(&callbacks);
}

} // namespace cadnext::viewer
