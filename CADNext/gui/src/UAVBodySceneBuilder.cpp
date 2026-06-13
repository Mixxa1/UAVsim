#include "cadnext/gui/UAVBodySceneBuilder.hpp"
#include "cadnext/gui/UAVCatalogPreviewProvider.hpp"

#include <cmath>
#include <string>

#include <Inventor/SbRotation.h>
#include <Inventor/SbVec3f.h>
#include <Inventor/nodes/SoCube.h>
#include <Inventor/nodes/SoCylinder.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoScale.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoShapeHints.h>
#include <Inventor/nodes/SoSphere.h>
#include <Inventor/nodes/SoTransform.h>

namespace cadnext::gui {

namespace {

static constexpr float kPi = 3.14159265f;

// ─── Primitive helpers ────────────────────────────────────────────────────────

SoMaterial* mat(float r, float g, float b)
{
    auto* m = new SoMaterial;
    m->diffuseColor.setValue(r, g, b);
    return m;
}

SoShapeHints* ccwHints()
{
    auto* h = new SoShapeHints;
    h->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
    return h;
}

// placed(): shape + material + translation (no rotation).
SoSeparator* placed(float tx, float ty, float tz, SoNode* shape, SoMaterial* m = nullptr)
{
    auto* sep = new SoSeparator;
    if (m) sep->addChild(m);
    auto* xf = new SoTransform;
    xf->translation.setValue(tx, ty, tz);
    sep->addChild(xf);
    sep->addChild(shape);
    return sep;
}

// placed(): shape + material + translation + axis-angle rotation.
SoSeparator* placed(float tx, float ty, float tz,
                    const SbVec3f& axis, float angleDeg,
                    SoNode* shape, SoMaterial* m = nullptr)
{
    auto* sep = new SoSeparator;
    if (m) sep->addChild(m);
    auto* xf = new SoTransform;
    xf->translation.setValue(tx, ty, tz);
    if (angleDeg != 0.0f)
        xf->rotation.setValue(axis, angleDeg * kPi / 180.0f);
    sep->addChild(xf);
    sep->addChild(shape);
    return sep;
}

// ─── beamNode: SoCylinder aligned from start to end (matches Swift beamNode) ─

SoSeparator* beamNode(float x0, float y0, float z0,
                      float x1, float y1, float z1,
                      float radius, SoMaterial* m)
{
    const SbVec3f start(x0, y0, z0), end(x1, y1, z1);
    const SbVec3f delta = end - start;
    const float   len   = delta.length();
    if (len < 1e-6f) return new SoSeparator;

    const SbVec3f mid = (start + end) * 0.5f;
    SbVec3f dir = delta; dir.normalize();
    static const SbVec3f kY(0.0f, 1.0f, 0.0f);

    SbRotation rot;
    const float dot = dir.dot(kY);
    if (dot > 1.0f - 1e-4f) {
        rot = SbRotation(SbVec3f(0,0,1), 0.0f); // identity
    } else if (dot < -1.0f + 1e-4f) {
        rot = SbRotation(SbVec3f(1,0,0), kPi);  // antiparallel
    } else {
        rot = SbRotation(kY, dir);               // from Y to dir
    }

    auto* sep = new SoSeparator;
    if (m) sep->addChild(m);
    auto* xf = new SoTransform;
    xf->translation.setValue(mid);
    xf->rotation.setValue(rot);
    sep->addChild(xf);
    auto* cyl = new SoCylinder;
    cyl->radius = radius;
    cyl->height = len;
    sep->addChild(cyl);
    return sep;
}

// ─── topRotorDisc: flat horizontal disc (SoCylinder height along Y) ──────────
SoSeparator* topRotorDisc(float tx, float ty, float tz, float radius, SoMaterial* m)
{
    auto* cyl  = new SoCylinder;
    cyl->radius = radius;
    cyl->height = radius * 0.06f;
    return placed(tx, ty, tz, cyl, m);
}

// ─── fwdPropDisc: forward-facing pusher disc (height along Z after +90° X) ──
SoSeparator* fwdPropDisc(float tx, float ty, float tz, float radius, SoMaterial* m)
{
    auto* cyl  = new SoCylinder;
    cyl->radius = radius;
    cyl->height = radius * 0.06f;
    return placed(tx, ty, tz, SbVec3f(1,0,0), 90.0f, cyl, m);
}

// ─── hCyl: horizontal capsule — SoCylinder height along Z ────────────────────
SoSeparator* hCyl(float tx, float ty, float tz, float len, float radius, SoMaterial* m)
{
    auto* cyl  = new SoCylinder;
    cyl->radius = radius;
    cyl->height = len;
    return placed(tx, ty, tz, SbVec3f(1,0,0), 90.0f, cyl, m);
}

// ─── fwdMotorCyl: forward-facing motor cylinder (along Z) ────────────────────
SoSeparator* fwdMotorCyl(float tx, float ty, float tz,
                          float radius, float len, SoMaterial* m)
{
    auto* cyl  = new SoCylinder;
    cyl->radius = radius;
    cyl->height = len;
    return placed(tx, ty, tz, SbVec3f(1,0,0), 90.0f, cyl, m);
}

// ─── torusApprox: flat disc approximating a torus ring ───────────────────────
SoSeparator* torusApprox(float tx, float ty, float tz, float ringRadius, SoMaterial* m)
{
    auto* cyl  = new SoCylinder;
    cyl->radius = ringRadius;
    cyl->height = ringRadius * 0.12f;
    return placed(tx, ty, tz, cyl, m);
}

// ─── wingBox: wing planform → flat SoCube approximation ──────────────────────
SoSeparator* wingBox(float tx, float ty, float tz,
                     float span, float chord, float thickness, SoMaterial* m)
{
    auto* box  = new SoCube;
    box->width  = span;
    box->height = thickness;
    box->depth  = chord;
    return placed(tx, ty, tz, box, m);
}

// ─── vFinBox: vertical stabiliser fin ────────────────────────────────────────
SoSeparator* vFinBox(float tx, float ty, float tz,
                     float chord, float height, float thickness, SoMaterial* m)
{
    auto* box  = new SoCube;
    box->width  = thickness;
    box->height = height;
    box->depth  = chord;
    return placed(tx, ty, tz, box, m);
}

// ─── scaledSphere: non-uniform-scale sphere ───────────────────────────────────
// Matches Swift: sphereNode(radius).scale = (sx,sy,sz)
SoSeparator* scaledSphere(float tx, float ty, float tz,
                           float radius, float sx, float sy, float sz,
                           SoMaterial* m)
{
    auto* sep  = new SoSeparator;
    if (m) sep->addChild(m);
    auto* xf   = new SoTransform;
    xf->translation.setValue(tx, ty, tz);
    xf->scaleFactor.setValue(sx, sy, sz);
    sep->addChild(xf);
    auto* sp   = new SoSphere;
    sp->radius  = radius;
    sep->addChild(sp);
    return sep;
}

// ─── bodyScale for generic fallback ──────────────────────────────────────────
float bodyScale(UAVPreviewMassCategory cat)
{
    switch (cat) {
    case UAVPreviewMassCategory::nano:   return 0.05f;
    case UAVPreviewMassCategory::micro:  return 0.12f;
    case UAVPreviewMassCategory::light:  return 0.25f;
    case UAVPreviewMassCategory::medium: return 0.45f;
    case UAVPreviewMassCategory::heavy:  return 0.70f;
    }
    return 0.30f;
}

// =============================================================================
// Per-aircraft builders (geometry sourced from UAVVisualFactory.swift)
// =============================================================================

// ─── DJI Matrice 350 RTK ─────────────────────────────────────────────────────
SoSeparator* buildDJIMatrice350RTK()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.32f,0.35f,0.39f);
    auto* mArm    = mat(0.20f,0.22f,0.26f);
    auto* mAccent = mat(0.78f,0.81f,0.84f);
    auto* mRotor  = mat(0.94f,0.94f,0.94f);

    { auto* b=new SoCube; b->width=0.22f; b->height=0.07f; b->depth=0.16f;
      root->addChild(placed(0.0f, 0.02f, 0.0f, b, mBody)); }
    { auto* b=new SoCube; b->width=0.15f; b->height=0.10f; b->depth=0.10f;
      root->addChild(placed(0.0f, 0.06f,-0.01f, b, mAccent)); }
    { auto* b=new SoCube; b->width=0.17f; b->height=0.045f; b->depth=0.14f;
      root->addChild(placed(0.0f,-0.03f,-0.01f, b, mArm)); }
    { auto* b=new SoCube; b->width=0.12f; b->height=0.07f; b->depth=0.10f;
      root->addChild(placed(0.0f,-0.08f, 0.03f, b, mAccent)); }

    const float aSt[4][3]={{-0.06f,0.03f,0.04f},{0.06f,0.03f,0.04f},
                            {-0.06f,0.03f,-0.04f},{0.06f,0.03f,-0.04f}};
    const float aEn[4][3]={{-0.31f,0.05f,0.23f},{0.31f,0.05f,0.23f},
                            {-0.31f,0.05f,-0.23f},{0.31f,0.05f,-0.23f}};
    for (int i=0;i<4;++i) {
        root->addChild(beamNode(aSt[i][0],aSt[i][1],aSt[i][2],
                                aEn[i][0],aEn[i][1],aEn[i][2], 0.016f, mArm));
        { auto* c=new SoCylinder; c->radius=0.030f; c->height=0.030f;
          root->addChild(placed(aEn[i][0],aEn[i][1],aEn[i][2], c, mArm)); }
        root->addChild(topRotorDisc(aEn[i][0], aEn[i][1]+0.026f, aEn[i][2], 0.12f, mRotor));
    }
    for (float s:{-1.0f,1.0f}) {
        root->addChild(beamNode(0.18f*s,-0.01f,0.10f, 0.22f*s,-0.19f,0.10f, 0.010f,mAccent));
        root->addChild(beamNode(0.12f*s,-0.01f,-0.08f, 0.16f*s,-0.19f,-0.08f,0.010f,mAccent));
        root->addChild(beamNode(0.22f*s,-0.19f,-0.10f, 0.22f*s,-0.19f,0.12f, 0.009f,mAccent));
    }
    return root;
}

// ─── DJI FlyCart 30 ──────────────────────────────────────────────────────────
SoSeparator* buildDJIFlyCart30()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.30f,0.31f,0.33f);
    auto* mArm    = mat(0.13f,0.14f,0.16f);
    auto* mAccent = mat(0.82f,0.58f,0.14f);
    auto* mRotor  = mat(0.94f,0.94f,0.94f);

    { auto* b=new SoCube; b->width=0.46f; b->height=0.16f; b->depth=0.32f;
      root->addChild(placed(0.0f,0.04f,0.0f, b, mBody)); }
    { auto* b=new SoCube; b->width=0.36f; b->height=0.12f; b->depth=0.24f;
      root->addChild(placed(0.0f,0.14f,-0.02f, b, mAccent)); }
    { auto* b=new SoCube; b->width=0.30f; b->height=0.14f; b->depth=0.28f;
      root->addChild(placed(0.0f,-0.14f,0.0f, b, mArm)); }

    const float tips[4][3]={{-0.58f,0.14f,0.40f},{0.58f,0.14f,0.40f},
                             {-0.58f,0.14f,-0.40f},{0.58f,0.14f,-0.40f}};
    for (int i=0;i<4;++i) {
        root->addChild(beamNode(0.0f,0.08f,0.0f, tips[i][0],tips[i][1],tips[i][2], 0.026f,mArm));
        { auto* c=new SoCylinder; c->radius=0.048f; c->height=0.040f;
          root->addChild(placed(tips[i][0],tips[i][1]+0.060f,tips[i][2], c, mArm)); }
        { auto* c=new SoCylinder; c->radius=0.048f; c->height=0.040f;
          root->addChild(placed(tips[i][0],tips[i][1],tips[i][2], c, mArm)); }
        root->addChild(topRotorDisc(tips[i][0],tips[i][1]+0.094f,tips[i][2], 0.22f, mRotor));
        root->addChild(topRotorDisc(tips[i][0],tips[i][1]-0.022f,tips[i][2], 0.22f, mRotor));
    }
    for (float s:{-1.0f,1.0f}) {
        root->addChild(beamNode(0.26f*s,-0.02f,0.20f, 0.36f*s,-0.34f,0.20f, 0.018f,mAccent));
        root->addChild(beamNode(0.26f*s,-0.02f,-0.20f,0.36f*s,-0.34f,-0.20f,0.018f,mAccent));
        root->addChild(beamNode(0.36f*s,-0.34f,-0.26f,0.36f*s,-0.34f,0.26f, 0.016f,mAccent));
    }
    return root;
}

// ─── DJI Mavic 4 Pro ─────────────────────────────────────────────────────────
SoSeparator* buildDJIMavic4Pro()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.56f,0.58f,0.61f);
    auto* mArm    = mat(0.38f,0.40f,0.43f);
    auto* mAccent = mat(0.18f,0.19f,0.22f);
    auto* mRotor  = mat(0.95f,0.95f,0.95f);

    { auto* b=new SoCube; b->width=0.19f; b->height=0.050f; b->depth=0.12f;
      root->addChild(placed(0.0f,0.012f,0.0f, b, mBody)); }
    { auto* b=new SoCube; b->width=0.12f; b->height=0.046f; b->depth=0.08f;
      root->addChild(placed(0.0f,0.046f,-0.02f, b, mArm)); }
    { auto* b=new SoCube; b->width=0.08f; b->height=0.032f; b->depth=0.05f;
      root->addChild(placed(0.0f,-0.010f,0.082f, b, mAccent)); }
    root->addChild(scaledSphere(0.0f,-0.040f,0.090f, 0.026f, 1.0f,0.85f,1.05f, mAccent));
    for (float ox:{-0.015f,0.015f}) {
        auto* c=new SoCylinder; c->radius=0.008f; c->height=0.012f;
        root->addChild(placed(ox,-0.040f,0.110f, SbVec3f(1,0,0),90.0f, c, mAccent));
    }

    const float aSt[4][3]={{-0.06f,0.012f,0.028f},{0.06f,0.012f,0.028f},
                            {-0.05f,0.012f,-0.030f},{0.05f,0.012f,-0.030f}};
    const float aEn[4][3]={{-0.21f,0.018f,0.18f},{0.21f,0.018f,0.18f},
                            {-0.23f,0.012f,-0.17f},{0.23f,0.012f,-0.17f}};
    for (int i=0;i<4;++i) {
        root->addChild(beamNode(aSt[i][0],aSt[i][1],aSt[i][2],
                                aEn[i][0],aEn[i][1],aEn[i][2], 0.010f, mArm));
        { auto* c=new SoCylinder; c->radius=0.018f; c->height=0.016f;
          root->addChild(placed(aEn[i][0],aEn[i][1],aEn[i][2], c, mArm)); }
        root->addChild(topRotorDisc(aEn[i][0],aEn[i][1]+0.014f,aEn[i][2], 0.085f, mRotor));
    }
    return root;
}

// ─── DJI Neo ─────────────────────────────────────────────────────────────────
SoSeparator* buildDJINeo()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.72f,0.73f,0.75f);
    auto* mGuard  = mat(0.18f,0.20f,0.24f);
    auto* mAccent = mat(0.11f,0.12f,0.15f);
    auto* mRotor  = mat(0.94f,0.94f,0.94f);

    { auto* b=new SoCube; b->width=0.11f; b->height=0.034f; b->depth=0.085f;
      root->addChild(placed(0.0f,0.0f,0.0f, b, mBody)); }
    { auto* b=new SoCube; b->width=0.07f; b->height=0.020f; b->depth=0.05f;
      root->addChild(placed(0.0f,0.022f,-0.01f, b, mAccent)); }
    { auto* b=new SoCube; b->width=0.055f; b->height=0.022f; b->depth=0.038f;
      root->addChild(placed(0.0f,-0.016f,0.050f, b, mAccent)); }

    const float rings[4][3]={{-0.085f,0.0f,0.060f},{0.085f,0.0f,0.060f},
                              {-0.085f,0.0f,-0.060f},{0.085f,0.0f,-0.060f}};
    for (int i=0;i<4;++i) {
        root->addChild(beamNode(0.0f,0.0f,0.0f, rings[i][0],rings[i][1],rings[i][2], 0.008f,mGuard));
        root->addChild(torusApprox(rings[i][0],rings[i][1],rings[i][2], 0.052f, mGuard));
        { auto* c=new SoCylinder; c->radius=0.013f; c->height=0.014f;
          root->addChild(placed(rings[i][0],0.0f,rings[i][2], c, mAccent)); }
        root->addChild(topRotorDisc(rings[i][0],0.010f,rings[i][2], 0.042f, mRotor));
    }
    return root;
}

// ─── DJI Phantom 3 Standard ──────────────────────────────────────────────────
SoSeparator* buildDJIPhantom3Standard()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mShell  = mat(0.93f,0.94f,0.96f);
    auto* mArm    = mat(0.85f,0.87f,0.90f);
    auto* mAccent = mat(0.15f,0.18f,0.22f);
    auto* mRotor  = mat(0.95f,0.95f,0.95f);

    root->addChild(scaledSphere(0.0f,0.02f,0.0f, 0.085f, 1.05f,0.48f,1.00f, mShell));
    { auto* b=new SoCube; b->width=0.12f; b->height=0.032f; b->depth=0.09f;
      root->addChild(placed(0.0f,0.056f,-0.015f, b, mShell)); }
    { auto* b=new SoCube; b->width=0.060f; b->height=0.032f; b->depth=0.040f;
      root->addChild(placed(0.0f,-0.080f,0.075f, b, mAccent)); }

    const float aEn[4][3]={{-0.22f,0.045f,0.18f},{0.22f,0.045f,0.18f},
                            {-0.22f,0.045f,-0.18f},{0.22f,0.045f,-0.18f}};
    for (int i=0;i<4;++i) {
        root->addChild(beamNode(0.0f,0.032f,0.0f, aEn[i][0],aEn[i][1],aEn[i][2], 0.012f,mArm));
        { auto* c=new SoCylinder; c->radius=0.020f; c->height=0.018f;
          root->addChild(placed(aEn[i][0],aEn[i][1],aEn[i][2], c, mArm)); }
        root->addChild(topRotorDisc(aEn[i][0],aEn[i][1]+0.014f,aEn[i][2], 0.095f, mRotor));
    }
    for (float s:{-1.0f,1.0f}) {
        root->addChild(beamNode(0.12f*s,-0.01f,0.08f, 0.16f*s,-0.22f,0.10f, 0.010f,mArm));
        root->addChild(beamNode(0.10f*s,-0.01f,-0.04f,0.14f*s,-0.22f,-0.02f,0.010f,mArm));
        root->addChild(beamNode(0.16f*s,-0.22f,-0.06f,0.16f*s,-0.22f,0.14f, 0.008f,mArm));
    }
    return root;
}

// ─── Freefly Alta X ──────────────────────────────────────────────────────────
SoSeparator* buildFreeflyAltaX()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mCarbon  = mat(0.10f,0.11f,0.13f);
    auto* mFrame   = mat(0.28f,0.29f,0.31f);
    auto* mAccent  = mat(0.89f,0.35f,0.12f);
    auto* mRotor   = mat(0.94f,0.94f,0.94f);

    { auto* c=new SoCylinder; c->radius=0.16f; c->height=0.030f;
      root->addChild(placed(0.0f,0.04f,0.0f, c, mFrame)); }
    { auto* b=new SoCube; b->width=0.18f; b->height=0.11f; b->depth=0.18f;
      root->addChild(placed(0.0f,-0.01f,0.0f, b, mCarbon)); }
    { auto* b=new SoCube; b->width=0.22f; b->height=0.04f; b->depth=0.22f;
      root->addChild(placed(0.0f,-0.13f,0.0f, b, mAccent)); }

    const float tips[4][3]={{-0.58f,0.08f,0.58f},{0.58f,0.08f,0.58f},
                             {-0.58f,0.08f,-0.58f},{0.58f,0.08f,-0.58f}};
    for (int i=0;i<4;++i) {
        root->addChild(beamNode(0.0f,0.04f,0.0f, tips[i][0],tips[i][1],tips[i][2], 0.024f,mCarbon));
        { auto* sp=new SoSphere; sp->radius=0.040f;
          root->addChild(placed(tips[i][0]*0.72f,tips[i][1]*0.72f,tips[i][2]*0.72f, sp, mFrame)); }
        { auto* c=new SoCylinder; c->radius=0.046f; c->height=0.034f;
          root->addChild(placed(tips[i][0],tips[i][1]+0.040f,tips[i][2], c, mFrame)); }
        { auto* c=new SoCylinder; c->radius=0.046f; c->height=0.034f;
          root->addChild(placed(tips[i][0],tips[i][1]-0.010f,tips[i][2], c, mFrame)); }
        root->addChild(topRotorDisc(tips[i][0],tips[i][1]+0.072f,tips[i][2], 0.17f, mRotor));
        root->addChild(topRotorDisc(tips[i][0],tips[i][1]-0.040f,tips[i][2], 0.17f, mRotor));
    }
    for (float s:{-1.0f,1.0f}) {
        root->addChild(beamNode(0.30f*s,-0.04f,0.20f,  0.44f*s,-0.28f,0.20f,  0.014f,mAccent));
        root->addChild(beamNode(0.30f*s,-0.04f,-0.20f, 0.44f*s,-0.28f,-0.20f, 0.014f,mAccent));
        root->addChild(beamNode(0.44f*s,-0.28f,-0.24f, 0.44f*s,-0.28f,0.24f,  0.012f,mAccent));
    }
    return root;
}

// ─── Griff 30 ────────────────────────────────────────────────────────────────
SoSeparator* buildGriff30()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mCarbon  = mat(0.11f,0.12f,0.14f);
    auto* mFrame   = mat(0.33f,0.34f,0.36f);
    auto* mAccent  = mat(0.75f,0.14f,0.12f);
    auto* mRotor   = mat(0.94f,0.94f,0.94f);

    root->addChild(torusApprox(0.0f,0.06f,0.0f, 0.24f, mFrame));
    { auto* b=new SoCube; b->width=0.22f; b->height=0.12f; b->depth=0.22f;
      root->addChild(placed(0.0f,0.0f,0.0f, b, mCarbon)); }
    { auto* b=new SoCube; b->width=0.26f; b->height=0.05f; b->depth=0.26f;
      root->addChild(placed(0.0f,-0.14f,0.0f, b, mAccent)); }

    const float rp[8][3]={
        {0.00f,0.12f,0.72f},{0.51f,0.12f,0.51f},{0.72f,0.12f,0.00f},{0.51f,0.12f,-0.51f},
        {0.00f,0.12f,-0.72f},{-0.51f,0.12f,-0.51f},{-0.72f,0.12f,0.00f},{-0.51f,0.12f,0.51f}
    };
    for (int i=0;i<8;++i) {
        root->addChild(beamNode(0.0f,0.04f,0.0f, rp[i][0],rp[i][1],rp[i][2], 0.020f,mCarbon));
        { auto* c=new SoCylinder; c->radius=0.044f; c->height=0.036f;
          root->addChild(placed(rp[i][0],rp[i][1],rp[i][2], c, mFrame)); }
        root->addChild(topRotorDisc(rp[i][0],rp[i][1]+0.030f,rp[i][2], 0.19f, mRotor));
    }
    for (float s:{-1.0f,1.0f}) {
        root->addChild(beamNode(0.34f*s,-0.02f,0.24f, 0.46f*s,-0.30f,0.24f, 0.015f,mAccent));
        root->addChild(beamNode(0.34f*s,-0.02f,-0.24f,0.46f*s,-0.30f,-0.24f,0.015f,mAccent));
        root->addChild(beamNode(0.46f*s,-0.30f,-0.28f,0.46f*s,-0.30f,0.28f, 0.013f,mAccent));
    }
    return root;
}

// ─── Griff 60 ────────────────────────────────────────────────────────────────
SoSeparator* buildGriff60()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mCarbon  = mat(0.10f,0.11f,0.13f);
    auto* mFrame   = mat(0.28f,0.29f,0.31f);
    auto* mAccent  = mat(0.79f,0.18f,0.14f);
    auto* mRotor   = mat(0.94f,0.94f,0.94f);

    root->addChild(torusApprox(0.0f,0.10f,0.0f, 0.34f, mFrame));
    root->addChild(torusApprox(0.0f,-0.02f,0.0f, 0.24f, mCarbon));
    { auto* b=new SoCube; b->width=0.30f; b->height=0.18f; b->depth=0.30f;
      root->addChild(placed(0.0f,0.02f,0.0f, b, mCarbon)); }
    { auto* b=new SoCube; b->width=0.34f; b->height=0.08f; b->depth=0.34f;
      root->addChild(placed(0.0f,-0.20f,0.0f, b, mAccent)); }

    const float rp[8][3]={
        {0.00f,0.16f,0.96f},{0.68f,0.16f,0.68f},{0.96f,0.16f,0.00f},{0.68f,0.16f,-0.68f},
        {0.00f,0.16f,-0.96f},{-0.68f,0.16f,-0.68f},{-0.96f,0.16f,0.00f},{-0.68f,0.16f,0.68f}
    };
    for (int i=0;i<8;++i) {
        root->addChild(beamNode(0.0f,0.06f,0.0f, rp[i][0],rp[i][1],rp[i][2], 0.024f,mCarbon));
        { auto* c=new SoCylinder; c->radius=0.054f; c->height=0.042f;
          root->addChild(placed(rp[i][0],rp[i][1],rp[i][2], c, mFrame)); }
        root->addChild(topRotorDisc(rp[i][0],rp[i][1]+0.034f,rp[i][2], 0.24f, mRotor));
    }
    for (float s:{-1.0f,1.0f}) {
        root->addChild(beamNode(0.40f*s,-0.02f,0.28f,  0.58f*s,-0.38f,0.30f,  0.018f,mAccent));
        root->addChild(beamNode(0.40f*s,-0.02f,-0.28f, 0.58f*s,-0.38f,-0.30f, 0.018f,mAccent));
        root->addChild(beamNode(0.58f*s,-0.38f,-0.36f, 0.58f*s,-0.38f,0.36f,  0.016f,mAccent));
    }
    return root;
}

// ─── Avidrone 490TL ──────────────────────────────────────────────────────────
SoSeparator* buildAvidrone490TL()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.34f,0.36f,0.39f);
    auto* mArm    = mat(0.20f,0.22f,0.25f);
    auto* mAccent = mat(0.82f,0.31f,0.12f);
    auto* mRotor  = mat(0.94f,0.94f,0.94f);

    { auto* b=new SoCube; b->width=0.20f; b->height=0.12f; b->depth=0.92f;
      root->addChild(placed(0.0f,-0.02f,0.0f, b, mBody)); }
    { auto* b=new SoCube; b->width=0.12f; b->height=0.10f; b->depth=0.78f;
      root->addChild(placed(0.0f,0.07f,0.0f, b, mArm)); }
    { auto* b=new SoCube; b->width=0.18f; b->height=0.10f; b->depth=0.28f;
      root->addChild(placed(0.0f,-0.15f,0.04f, b, mAccent)); }
    { auto* b=new SoCube; b->width=0.08f; b->height=0.18f; b->depth=0.10f;
      root->addChild(placed(0.0f,0.18f,0.34f, b, mArm)); }
    { auto* b=new SoCube; b->width=0.08f; b->height=0.18f; b->depth=0.10f;
      root->addChild(placed(0.0f,0.18f,-0.34f, b, mArm)); }
    { auto* c=new SoCylinder; c->radius=0.12f; c->height=0.040f;
      root->addChild(placed(0.0f,0.28f,0.34f, c, mArm)); }
    { auto* c=new SoCylinder; c->radius=0.12f; c->height=0.040f;
      root->addChild(placed(0.0f,0.28f,-0.34f, c, mArm)); }
    root->addChild(topRotorDisc(0.0f,0.31f, 0.34f, 0.28f, mRotor));
    root->addChild(topRotorDisc(0.0f,0.31f,-0.34f, 0.28f, mRotor));

    for (float s:{-1.0f,1.0f}) {
        root->addChild(beamNode(0.08f*s,-0.02f,0.18f,  0.18f*s,-0.24f,0.18f,  0.014f,mAccent));
        root->addChild(beamNode(0.08f*s,-0.02f,-0.18f, 0.18f*s,-0.24f,-0.18f, 0.014f,mAccent));
        root->addChild(beamNode(0.18f*s,-0.24f,-0.28f, 0.18f*s,-0.24f,0.28f,  0.012f,mAccent));
    }
    return root;
}

// ─── WingtraOne GEN II ────────────────────────────────────────────────────────
SoSeparator* buildWingtraOneGenII()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.86f,0.87f,0.89f);
    auto* mWing   = mat(0.24f,0.28f,0.33f);
    auto* mAccent = mat(0.17f,0.20f,0.24f);
    auto* mRotor  = mat(0.94f,0.94f,0.94f);

    root->addChild(hCyl(0.0f,0.0f,0.0f, 0.78f,0.036f, mBody));
    root->addChild(wingBox(0.0f,0.018f,0.02f, 1.28f,0.31f,0.022f, mWing));
    { auto* b=new SoCube; b->width=0.11f; b->height=0.05f; b->depth=0.24f;
      root->addChild(placed(0.0f,-0.035f,0.05f, b, mAccent)); }
    // Twin tail fins
    for (float sx:{-0.40f,0.40f})
        root->addChild(vFinBox(sx,0.02f+0.09f,-0.24f, 0.10f,0.18f,0.012f, mWing));
    // VTOL pylons + motors + props (both sides)
    for (float sx:{-0.29f,0.29f}) {
        { auto* b=new SoCube; b->width=0.028f; b->height=0.10f; b->depth=0.032f;
          root->addChild(placed(sx,0.056f,0.10f, b, mAccent)); }
        root->addChild(fwdMotorCyl(sx,0.060f,0.14f, 0.020f,0.050f, mAccent));
        root->addChild(fwdPropDisc(sx,0.060f,0.18f, 0.13f, mRotor));
    }
    return root;
}

// ─── Quantum Systems Trinity Pro ──────────────────────────────────────────────
SoSeparator* buildQuantumSystemsTrinityPro()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.87f,0.88f,0.90f);
    auto* mWing   = mat(0.20f,0.24f,0.30f);
    auto* mAccent = mat(0.14f,0.17f,0.21f);
    auto* mRotor  = mat(0.94f,0.94f,0.94f);

    root->addChild(hCyl(0.0f,0.0f,0.0f, 1.08f,0.050f, mBody));
    { auto* b=new SoCube; b->width=0.16f; b->height=0.08f; b->depth=0.34f;
      root->addChild(placed(0.0f,-0.03f,0.12f, b, mAccent)); }
    root->addChild(wingBox(0.0f,0.024f,0.02f, 2.36f,0.40f,0.028f, mWing));
    for (float sx:{-0.34f,0.34f})
        root->addChild(hCyl(sx,0.012f,-0.18f, 0.72f,0.022f, mAccent));
    root->addChild(wingBox(0.0f,0.072f,-0.54f, 0.68f,0.12f,0.018f, mWing));
    for (float sx:{-0.34f,0.34f})
        root->addChild(vFinBox(sx,0.072f+0.11f,-0.58f, 0.14f,0.22f,0.014f, mWing));
    // 4 VTOL rotor pods
    const float pods[4][3]={{-0.56f,0.10f,0.13f},{0.56f,0.10f,0.13f},
                             {-0.56f,0.10f,-0.15f},{0.56f,0.10f,-0.15f}};
    for (int i=0;i<4;++i) {
        { auto* b=new SoCube; b->width=0.034f; b->height=0.10f; b->depth=0.034f;
          root->addChild(placed(pods[i][0],0.054f,pods[i][2], b, mAccent)); }
        { auto* c=new SoCylinder; c->radius=0.022f; c->height=0.026f;
          root->addChild(placed(pods[i][0],pods[i][1],pods[i][2], c, mAccent)); }
        root->addChild(topRotorDisc(pods[i][0],pods[i][1]+0.020f,pods[i][2], 0.13f, mRotor));
    }
    return root;
}

// ─── MQ-9B SkyGuardian ───────────────────────────────────────────────────────
SoSeparator* buildMQ9BSkyGuardian()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.78f,0.80f,0.83f);
    auto* mWing   = mat(0.45f,0.49f,0.54f);
    auto* mAccent = mat(0.18f,0.21f,0.25f);
    auto* mRotor  = mat(0.92f,0.92f,0.92f);

    root->addChild(hCyl(0.0f,0.0f,0.0f, 1.52f,0.060f, mBody));
    root->addChild(scaledSphere(0.0f,0.0f,0.70f, 0.064f, 1.0f,0.9f,1.5f, mBody));
    root->addChild(wingBox(0.0f,0.032f,0.02f, 2.80f,0.28f,0.022f, mWing));
    root->addChild(beamNode(0.0f,0.04f,-0.22f, 0.0f,0.09f,-0.78f, 0.026f,mAccent));
    root->addChild(beamNode(-0.34f,0.03f,-0.18f,-0.26f,0.13f,-0.82f, 0.018f,mAccent));
    root->addChild(beamNode( 0.34f,0.03f,-0.18f, 0.26f,0.13f,-0.82f, 0.018f,mAccent));
    root->addChild(wingBox(0.0f,0.14f,-0.86f, 0.84f,0.11f,0.014f, mWing));
    for (float sx:{-0.28f,0.28f})
        root->addChild(vFinBox(sx,0.14f+0.13f,-0.90f, 0.20f,0.26f,0.012f, mWing));
    root->addChild(scaledSphere(0.0f,-0.085f,0.34f, 0.055f, 1.0f,0.92f,1.0f, mAccent));
    root->addChild(fwdMotorCyl(0.0f,0.09f,-0.82f, 0.030f,0.080f, mAccent));
    root->addChild(fwdPropDisc(0.0f,0.09f,-0.90f, 0.18f, mRotor));
    return root;
}

// ─── Hermes 900 ──────────────────────────────────────────────────────────────
SoSeparator* buildHermes900()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.80f,0.82f,0.84f);
    auto* mWing   = mat(0.34f,0.38f,0.43f);
    auto* mAccent = mat(0.16f,0.18f,0.21f);
    auto* mRotor  = mat(0.92f,0.92f,0.92f);

    root->addChild(hCyl(0.0f,0.0f,0.0f, 1.12f,0.050f, mBody));
    root->addChild(wingBox(0.0f,0.035f,0.05f, 2.20f,0.20f,0.020f, mWing));
    for (float sx:{-0.28f,0.28f})
        root->addChild(hCyl(sx,0.02f,-0.24f, 0.84f,0.020f, mAccent));
    root->addChild(wingBox(0.0f,0.05f,-0.66f, 0.76f,0.10f,0.016f, mWing));
    for (float sx:{-0.28f,0.28f})
        root->addChild(vFinBox(sx,0.05f+0.12f,-0.70f, 0.18f,0.24f,0.012f, mWing));
    { auto* sp=new SoSphere; sp->radius=0.042f;
      root->addChild(placed(0.0f,-0.06f,0.28f, sp, mAccent)); }
    { auto* b=new SoCube; b->width=0.12f; b->height=0.05f; b->depth=0.08f;
      root->addChild(placed(0.0f,-0.07f,0.06f, b, mAccent)); }
    root->addChild(fwdMotorCyl(0.0f,0.03f,-0.40f, 0.026f,0.070f, mAccent));
    root->addChild(fwdPropDisc(0.0f,0.03f,-0.46f, 0.14f, mRotor));
    return root;
}

// ─── FT5 Łoś ─────────────────────────────────────────────────────────────────
SoSeparator* buildFT5Los()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.71f,0.74f,0.78f);
    auto* mWing   = mat(0.32f,0.36f,0.40f);
    auto* mAccent = mat(0.18f,0.20f,0.24f);
    auto* mRotor  = mat(0.92f,0.92f,0.92f);

    root->addChild(hCyl(0.0f,0.0f,0.0f, 0.86f,0.045f, mBody));
    root->addChild(wingBox(0.0f,0.025f,0.04f, 2.00f,0.28f,0.022f, mWing));
    { auto* b=new SoCube; b->width=0.12f; b->height=0.05f; b->depth=0.10f;
      root->addChild(placed(0.0f,-0.06f,0.10f, b, mAccent)); }
    for (float sx:{-0.34f,0.34f}) {
        root->addChild(fwdMotorCyl(sx,0.01f,0.10f, 0.024f,0.070f, mAccent));
        root->addChild(fwdPropDisc(sx,0.01f,0.16f, 0.12f, mRotor));
    }
    root->addChild(wingBox(0.0f,0.06f,-0.42f, 0.52f,0.09f,0.016f, mWing));
    root->addChild(vFinBox(0.0f,0.06f+0.11f,-0.46f, 0.16f,0.22f,0.012f, mWing));
    return root;
}

// ─── FlyEye ──────────────────────────────────────────────────────────────────
SoSeparator* buildFlyEye()
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* mBody   = mat(0.66f,0.69f,0.73f);
    auto* mWing   = mat(0.26f,0.30f,0.34f);
    auto* mAccent = mat(0.14f,0.16f,0.19f);
    auto* mRotor  = mat(0.92f,0.92f,0.92f);

    root->addChild(hCyl(0.0f,0.0f,0.0f, 0.58f,0.030f, mBody));
    root->addChild(wingBox(0.0f,0.016f,0.02f, 1.64f,0.20f,0.018f, mWing));
    { auto* b=new SoCube; b->width=0.08f; b->height=0.04f; b->depth=0.07f;
      root->addChild(placed(0.0f,-0.045f,0.10f, b, mAccent)); }
    root->addChild(beamNode(-0.24f,0.01f,-0.02f,-0.14f,0.06f,-0.28f, 0.010f,mAccent));
    root->addChild(beamNode( 0.24f,0.01f,-0.02f, 0.14f,0.06f,-0.28f, 0.010f,mAccent));
    root->addChild(wingBox(0.0f,0.06f,-0.32f, 0.36f,0.07f,0.012f, mWing));
    for (float sx:{-0.14f,0.14f})
        root->addChild(vFinBox(sx,0.06f+0.07f,-0.34f, 0.10f,0.14f,0.010f, mWing));
    root->addChild(fwdMotorCyl(0.0f,0.02f,-0.18f, 0.018f,0.050f, mAccent));
    root->addChild(fwdPropDisc(0.0f,0.02f,-0.24f, 0.09f, mRotor));
    return root;
}

// =============================================================================
// Generic type-based fallback builders (used when uavId is not recognised)
// =============================================================================

SoSeparator* buildGenericMulticopter(float s)
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    { auto* b=new SoCube; b->width=0.70f*s; b->height=0.20f*s; b->depth=0.70f*s;
      root->addChild(placed(0.0f,0.0f,0.0f, b, mat(0.35f,0.35f,0.40f))); }
    for (float angle:{45.0f,-45.0f}) {
        auto* arm=new SoCube; arm->width=2.20f*s; arm->height=0.05f*s; arm->depth=0.05f*s;
        root->addChild(placed(0.0f,0.0f,0.0f, SbVec3f(0,1,0),angle, arm, mat(0.22f,0.22f,0.25f)));
    }
    const float r=1.10f*s, d=r*0.7071f;
    auto* mMot=mat(0.15f,0.15f,0.18f);
    for (float sx:{d,-d}) for (float sz:{d,-d}) {
        auto* sp=new SoSphere; sp->radius=0.065f*s;
        root->addChild(placed(sx,0.025f*s,sz, sp, mMot));
    }
    return root;
}

SoSeparator* buildGenericFixedWing(float s)
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    { auto* c=new SoCylinder; c->radius=0.08f*s; c->height=1.40f*s;
      root->addChild(placed(0.0f,0.0f,0.0f, SbVec3f(1,0,0),90.0f, c, mat(0.45f,0.45f,0.50f))); }
    { auto* b=new SoCube; b->width=3.00f*s; b->height=0.025f*s; b->depth=0.35f*s;
      root->addChild(placed(0.0f,0.0f,0.05f*s, b, mat(0.55f,0.55f,0.60f))); }
    { auto* b=new SoCube; b->width=0.90f*s; b->height=0.020f*s; b->depth=0.18f*s;
      root->addChild(placed(0.0f,0.02f*s,-0.62f*s, b, mat(0.50f,0.50f,0.55f))); }
    { auto* b=new SoCube; b->width=0.025f*s; b->height=0.28f*s; b->depth=0.15f*s;
      root->addChild(placed(0.0f,0.14f*s,-0.62f*s, b, mat(0.50f,0.50f,0.55f))); }
    root->addChild(fwdPropDisc(0.0f,0.0f,0.71f*s, 0.18f*s, mat(0.25f,0.25f,0.28f)));
    return root;
}

SoSeparator* buildGenericHybridVTOL(float s)
{
    auto* root = buildGenericFixedWing(s);
    auto* mRot = mat(0.22f,0.22f,0.28f);
    for (float px:{1.45f*s,-1.45f*s})
        root->addChild(topRotorDisc(px,0.04f*s,0.05f*s, 0.22f*s, mRot));
    return root;
}

SoSeparator* buildGenericHelicopter(float s)
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    { auto* b=new SoCube; b->width=0.45f*s; b->height=0.30f*s; b->depth=1.00f*s;
      root->addChild(placed(0.0f,0.0f,0.0f, b, mat(0.40f,0.40f,0.45f))); }
    { auto* c=new SoCylinder; c->radius=0.025f*s; c->height=0.15f*s;
      root->addChild(placed(0.0f,0.225f*s,0.05f*s, c, mat(0.25f,0.25f,0.28f))); }
    root->addChild(topRotorDisc(0.0f,0.30f*s,0.05f*s, 0.95f*s, mat(0.22f,0.22f,0.25f)));
    { auto* b=new SoCube; b->width=0.08f*s; b->height=0.08f*s; b->depth=0.65f*s;
      root->addChild(placed(0.0f,0.05f*s,-0.825f*s, b, mat(0.35f,0.35f,0.38f))); }
    // Tail rotor (shaft along X)
    { auto* c=new SoCylinder; c->radius=0.020f*s; c->height=0.10f*s;
      root->addChild(placed(0.10f*s,0.05f*s,-1.15f*s, SbVec3f(0,0,1),-90.0f, c, mat(0.25f,0.25f,0.28f))); }
    { auto* c=new SoCylinder; c->radius=0.18f*s; c->height=0.012f*s;
      root->addChild(placed(0.16f*s,0.05f*s,-1.15f*s, SbVec3f(0,0,1),-90.0f, c, mat(0.20f,0.20f,0.22f))); }
    return root;
}

SoSeparator* buildGenericCustom(float s)
{
    auto* root = new SoSeparator; root->addChild(ccwHints());
    auto* b=new SoCube; b->width=0.8f*s; b->height=0.5f*s; b->depth=1.2f*s;
    root->addChild(mat(0.40f,0.40f,0.45f));
    root->addChild(b);
    return root;
}

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
SoSeparator* UAVBodySceneBuilder::buildScene(const std::string&    uavId,
                                              UAVPreviewVehicleType  type,
                                              UAVPreviewMassCategory cat)
{
    if (uavId == "dji-matrice-350-rtk")        return buildDJIMatrice350RTK();
    if (uavId == "dji-flycart-30")              return buildDJIFlyCart30();
    if (uavId == "dji-mavic-4-pro")             return buildDJIMavic4Pro();
    if (uavId == "dji-neo")                     return buildDJINeo();
    if (uavId == "dji-phantom-3-standard")      return buildDJIPhantom3Standard();
    if (uavId == "freefly-alta-x")              return buildFreeflyAltaX();
    if (uavId == "griff-30")                    return buildGriff30();
    if (uavId == "griff-60")                    return buildGriff60();
    if (uavId == "avidrone-490tl")              return buildAvidrone490TL();
    if (uavId == "wingtraone-gen-ii")           return buildWingtraOneGenII();
    if (uavId == "quantum-systems-trinity-pro") return buildQuantumSystemsTrinityPro();
    if (uavId == "mq-9b-skyguardian")           return buildMQ9BSkyGuardian();
    if (uavId == "hermes-900")                  return buildHermes900();
    if (uavId == "ft5-los")                     return buildFT5Los();
    if (uavId == "flyeye")                      return buildFlyEye();

    // Generic fallback
    const float s = bodyScale(cat);
    switch (type) {
    case UAVPreviewVehicleType::multicopter: return buildGenericMulticopter(s);
    case UAVPreviewVehicleType::fixedWing:   return buildGenericFixedWing(s);
    case UAVPreviewVehicleType::hybridVTOL:  return buildGenericHybridVTOL(s);
    case UAVPreviewVehicleType::helicopter:  return buildGenericHelicopter(s);
    case UAVPreviewVehicleType::custom:      return buildGenericCustom(s);
    }
    return buildGenericCustom(s);
}

} // namespace cadnext::gui
