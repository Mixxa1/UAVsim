// cadnext_structural_snapshot — renders a structural field file offscreen, with the same scene
// the CADNext result window shows.
//
//   cadnext_structural_snapshot <field.json> <out.ppm> [utilization|vonMises|displacement] [width height]
//
// For documentation images and for checking the viewer without opening a window.

#include "cadnext/viewer/OffscreenGL.hpp"
#include "cadnext/viewer/StructuralFieldScene.hpp"

#include <Inventor/SbViewportRegion.h>
#include <Inventor/SoDB.h>
#include <Inventor/SoOffscreenRenderer.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoPerspectiveCamera.h>
#include <Inventor/nodes/SoSeparator.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>

using namespace cadnext;


int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <field.json> <out.ppm> [utilization|vonMises|displacement] [width height]\n", argv[0]);
        return 64;
    }
    std::ifstream stream(argv[1], std::ios::binary);
    const std::string text{std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    auto parsed = fea::parseStructuralField(text);
    if (!parsed.isOk()) {
        std::fprintf(stderr, "%s\n", parsed.error().message.c_str());
        return 2;
    }
    const std::string quantity = argc > 3 ? argv[3] : "utilization";
    const int width = argc > 5 ? std::atoi(argv[4]) : 1200;
    const int height = argc > 5 ? std::atoi(argv[5]) : 800;

    viewer::installOffscreenGLContext();
    SoDB::init();
    viewer::StructuralFieldScene scene(parsed.value());
    if (quantity == "vonMises") scene.setQuantity(viewer::FieldQuantity::VonMises);
    if (quantity == "displacement") scene.setQuantity(viewer::FieldQuantity::Displacement);

    auto* root = new SoSeparator;
    root->ref();
    auto* camera = new SoPerspectiveCamera;
    root->addChild(camera);
    // Headlight along the view, as in the viewer; the scene brings its own fill lights.
    auto* headlight = new SoDirectionalLight;
    headlight->intensity = viewer::kStructuralHeadlightIntensity;
    root->addChild(headlight);
    root->addChild(scene.root());

    // Z-up axonometric view (CAD convention), then frame the part.
    viewer::applyAxonometricZUpOrientation(*camera);
    const SbViewportRegion viewport(width, height);
    scene.frame(*camera, static_cast<double>(width) / height);
    SbVec3f viewDirection;
    camera->orientation.getValue().multVec(SbVec3f(0, 0, -1), viewDirection);
    headlight->direction = viewDirection;

    SoOffscreenRenderer renderer(viewport);
    renderer.setBackgroundColor(SbColor(0.29f, 0.29f, 0.27f));
    if (!renderer.render(root)) {
        std::fprintf(stderr, "offscreen rendering failed (no OpenGL context?)\n");
        return 3;
    }
    const unsigned char* buffer = renderer.getBuffer();
    const int components = renderer.getComponents();
    std::ofstream out(argv[2], std::ios::binary);
    out << "P6\n" << width << " " << height << "\n255\n";
    for (int y = height - 1; y >= 0; --y) { // Coin's buffer starts at the bottom row
        for (int x = 0; x < width; ++x) {
            const unsigned char* pixel = buffer + (y * width + x) * components;
            out.put(static_cast<char>(pixel[0])).put(static_cast<char>(pixel[1])).put(static_cast<char>(pixel[2]));
        }
    }
    root->unref();
    return 0;
}
