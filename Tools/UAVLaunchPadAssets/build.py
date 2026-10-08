"""Build an original, metre-scale UAV launch pad with an animated windsock.

Uses the repository's mesh primitives and Apple's USD command-line tools. No
downloaded geometry or textures. Landing surface is Y=0; north/approach is +Z.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/UAVModelAssets"))
from geometry import Model, tup, array  # noqa: E402

OUT = ROOT / "Assets/UAVLaunchPad"
SOURCE = OUT / "sources"
IDENT = "uav-launch-pad"
CYCLE = 6.0
FPS = 30

MATERIALS = {
    "concrete": ("#babdb8", .93, 0),
    "deck_markings": ("#ffffff", .90, 0),
    "asphalt": ("#ffffff", .96, 0),
    "joint": ("#262d2e", .92, 0),
    "steel": ("#8a989e", .34, .83),
    "dark_steel": ("#303c43", .42, .70),
    "cabinet": ("#60717b", .46, .55),
    "yellow": ("#f7c44f", .62, .04),
    "black": ("#212a2e", .66, .03),
    "rubber": ("#202726", .87, 0),
    "wind_orange": ("#eb7734", .85, 0),
    "wind_white": ("#edeae0", .90, 0),
    "green_lens": ("#64b89b", .30, .03),
    "red_button": ("#d04434", .43, .03),
    "screen": ("#244d44", .32, .10),
    "label": ("#ffffff", .65, 0),
}
TEXTURES = {
    "deck_markings": "deck-markings.png",
    "asphalt": "asphalt.png",
    "label": "cabinet-label.png",
}


def run(args):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def textures():
    path = SOURCE / "textures"
    path.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20261007)
    n = 4096
    coarse = Image.fromarray(rng.integers(0, 255, (128, 128), dtype=np.uint8))
    coarse = np.asarray(coarse.resize((n, n), Image.Resampling.BICUBIC), dtype=np.float32)
    grain = rng.normal(0, 1.7, (n, n)).astype(np.float32)
    base = 177 + (coarse - 128) * .04 + grain
    rgb = np.stack([base + 3, base + 4, base + 1], axis=2)
    im = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(im)

    def p(x, z):
        return ((x + 6) / 12 * n, (6 - z) / 12 * n)

    def line(points, color, width):
        d.line([p(*q) for q in points], fill=color, width=max(1, int(width / 12 * n)), joint="curve")

    # Each slab has its own mild finish variation, before paint is applied.
    tint = Image.new("RGBA", im.size)
    td = ImageDraw.Draw(tint)
    for row in range(4):
        for col in range(4):
            td.rectangle((col*n//4, row*n//4, (col+1)*n//4-1, (row+1)*n//4-1),
                         fill=(33, 43, 42, int(rng.integers(0, 12))))
    im = Image.alpha_composite(im.convert("RGBA"), tint).convert("RGB")
    d = ImageDraw.Draw(im)
    white, yellow = (237, 236, 220), (235, 187, 67)

    # Interrupted edge strip: original visual design, not regulatory markings.
    for side in range(4):
        for i in range(44):
            a = -5.70 + i * .26
            b = min(a + .255, 5.70)
            quad = [(a, 5.56), (b, 5.56), (b+.13, 5.76), (a+.13, 5.76)]
            for _ in range(side):
                quad = [(-z, x) for x, z in quad]
            d.polygon([p(*q) for q in quad], fill=yellow if i % 2 else (42, 49, 49))

    octagon = [(4.38*math.sin(math.pi/8 + i*math.pi/4),
                4.38*math.cos(math.pi/8 + i*math.pi/4)) for i in range(8)]
    d.polygon([p(*q) for q in octagon], fill=(48, 69, 73))
    line(octagon + [octagon[0]], yellow, .13)
    for a in range(0, 360, 45):
        arc = [(3.19*math.sin(math.radians(t)), 3.19*math.cos(math.radians(t)))
               for t in np.linspace(a+5, a+35, 28)]
        line(arc, white, .105)
    for x, z in [(-2.45, 0), (2.45, 0), (0, -2.45), (0, 2.45)]:
        line([(x-.30, z), (x+.30, z)], white, .075)
        line([(x, z-.30), (x, z+.30)], white, .075)
    # Original quadrotor pictogram: arms, rotor rings and a central fuselage.
    # It is paint in the texture, not lettering or a separate raised object.
    for x, z in [(-1.02, -1.02), (1.02, -1.02), (-1.02, 1.02), (1.02, 1.02)]:
        line([(math.copysign(.18, x), math.copysign(.24, z)), (x, z)], white, .15)
        ring = [(x+.38*math.sin(a), z+.38*math.cos(a)) for a in np.linspace(0, 2*math.pi, 81)]
        line(ring, white, .065)
        for a in (0, 2*math.pi/3, 4*math.pi/3):
            line([(x, z), (x+.27*math.sin(a), z+.27*math.cos(a))], white, .045)
    body = [(-.20, .50), (.20, .50), (.30, .27), (.30, -.29), (.13, -.67),
            (-.13, -.67), (-.30, -.29), (-.30, .27)]
    d.polygon([p(*q) for q in body], fill=white)
    arrow = [(-.18, 5.20), (.18, 5.20), (.18, 4.87), (.42, 4.87),
             (0, 4.37), (-.42, 4.87), (-.18, 4.87)]
    d.polygon([p(*q) for q in arrow], fill=(54, 74, 76))
    # Fine aggregate and modest paint wear, not arbitrary cracks across a new slab.
    for _ in range(5200):
        x, y = (int(v) for v in rng.integers(0, n, 2))
        c = im.getpixel((x, y))
        d.point((x, y), fill=tuple(max(0, v-17) for v in c))
    im.save(path / "deck-markings.png", optimize=True)

    noise = rng.normal(0, 5.0, (1024, 1024))
    base = np.stack([noise+49, noise+56, noise+59], axis=2)
    Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").save(path / "asphalt.png")
    label = Image.new("RGB", (1024, 512), (220, 224, 214))
    ld = ImageDraw.Draw(label)
    ld.polygon([(512, 70), (305, 426), (719, 426)], fill=(190, 160, 96), outline=(64, 70, 65), width=10)
    ld.polygon([(530, 162), (440, 288), (497, 288), (463, 370), (587, 244), (529, 244)], fill=(64, 70, 65))
    label.save(path / "cabinet-label.png")


class Pad:
    def __init__(self):
        self.mesh = Model(IDENT, "Стартовая площадка БВС")
        self.nodes = {"": {}}

    def node(self, path, **data):
        parent = path.rpartition("/")[0]
        if parent not in self.nodes:
            self.node(parent)
        self.nodes.setdefault(path, {}).update(data)
        return path

    def add(self, parent, method, *args, **kwargs):
        self.node(parent)
        start = len(self.mesh.parts)
        getattr(self.mesh, method)(*args, **kwargs)
        for part in self.mesh.parts[start:]:
            part["parent"] = parent
        return self.mesh.parts[-1]

    def quad(self, parent, name, points, mat, uv):
        part = self.add(parent, "mesh", name, points, [(0, 1, 2, 3)], mat)
        part["uv"] = uv

    def merge(self, start, name):
        parts = self.mesh.parts[start:]
        if not parts:
            return
        assert len({(p["parent"], p["material"]) for p in parts}) == 1
        points, faces = [], []
        for part in parts:
            offset = len(points)
            points.extend(part["points"])
            faces.extend(tuple(v+offset for v in f) for f in part["faces"])
        del self.mesh.parts[start:]
        self.add(parts[0]["parent"], "mesh", name, points, faces, parts[0]["material"])

    def build(self):
        self.add("Apron", "box", "AsphaltApron", (0, -.18, 0), (16, .26, 16), "asphalt", bevel=.06)
        self.add("Deck", "box", "ExpansionJointBed", (0, -.12, 0), (12, .22, 12), "joint")
        for row in range(4):
            for col in range(4):
                x, z = -4.5 + 3*col, -4.5 + 3*row
                w = 2.984
                self.add("Deck", "box", "ConcreteSlab", (x, -.106, z), (w, .210, w), "concrete", bevel=.008)
                points = [(x-w/2, 0, z-w/2), (x-w/2, 0, z+w/2),
                          (x+w/2, 0, z+w/2), (x+w/2, 0, z-w/2)]
                self.quad("Deck", "SlabFinish", points, "deck_markings", [((q[0]+6)/12, (6-q[2])/12) for q in points])

        # Shallow bevelled concrete edging; grates sit below the landing deck.
        for side in (-1, 1):
            self.add("Drainage", "box", "DrainTrough", (side*6.19, -.062, 0), (.31, .09, 12.25), "joint")
            self.add("Drainage", "box", "DrainTrough", (0, -.062, side*6.19), (12.25, .09, .31), "joint")
            for outer in (-1, 1):
                self.add("Drainage", "box", "DrainFrame", (side*6.19+outer*.15, -.024, 0), (.02, .024, 12.20), "steel")
                self.add("Drainage", "box", "DrainFrame", (0, -.024, side*6.19+outer*.15), (12.20, .024, .02), "steel")
            for axis in (0, 2):
                start = len(self.mesh.parts)
                for i in range(174):
                    a = -6.05 + i*.070
                    center = (side*6.19, -.026, a) if axis == 0 else (a, -.026, side*6.19)
                    size = (.27, .022, .016) if axis == 0 else (.016, .022, .27)
                    self.add("Drainage", "box", "GrateBar", center, size, "steel")
                self.merge(start, "DrainGrating")

        for x in (-6.64, 6.64):
            for z in (-6.64, 6.64):
                self.add("Drainage", "box", "InspectionFrame", (x, -.029, z), (.44, .042, .44), "dark_steel", bevel=.008)
                self.add("Drainage", "box", "InspectionCover", (x, -.008, z), (.385, .012, .385), "steel", bevel=.006)
                for bx in (-.14, .14):
                    for bz in (-.14, .14):
                        self.add("Drainage", "rod", "CoverBolt", (x+bx, -.004, z+bz), (x+bx, .001, z+bz), .012, "dark_steel", segs=6)

        lamps = [(x, z) for x in (-5.87, 5.87) for z in (-5.87, -1.95, 1.95, 5.87)]
        lamps += [(x, z) for x in (-1.95, 1.95) for z in (-5.87, 5.87)]
        for x, z in lamps:
            self.add("EdgeLights", "rod", "InsetLightBody", (x, -.065, z), (x, .002, z), .095, "dark_steel", segs=32)
            self.add("EdgeLights", "ring", "InsetLightBezel", (x, .002, z), .079, .023, .008, "steel", segs=32)
            self.add("EdgeLights", "ellipsoid", "GreenLens", (x, .001, z), (.063, .009, .063), "green_lens", segs=32, rings=8)
            for a in (0, math.pi):
                bx, bz = x+.084*math.cos(a), z+.084*math.sin(a)
                self.add("EdgeLights", "rod", "LightFastener", (bx, .002, bz), (bx, .008, bz), .009, "dark_steel", segs=6)

        for x in (-7.38, 7.38):
            for z in (-7.38, 7.38):
                self.add("Perimeter", "rod", "BollardFoot", (x, -.054, z), (x, -.025, z), .15, "dark_steel", segs=32)
                self.add("Perimeter", "rod", "LowBollard", (x, -.025, z), (x, .44, z), .065, "yellow", segs=32)
                self.add("Perimeter", "rod", "BollardBand", (x, .26, z), (x, .34, z), .066, "black", segs=32)
                self.add("Perimeter", "ellipsoid", "BollardCap", (x, .44, z), (.065, .025, .065), "black", segs=24, rings=8)

        self.cabinet()
        self.windsock()
        # UVs are explicit and use metres for the apron grain; labels use 0..1.
        for part in self.mesh.parts:
            if part["material"] == "asphalt":
                part["uv"] = [(p[0]*.5, p[2]*.5) for p in part["points"]]
        return self

    def cabinet(self):
        path = self.node("UtilityCabinet", translation=(6.92, 0, 4.70))
        self.add(path, "box", "ServicePlinth", (0, -.025, 0), (1.2, .15, 1.0), "concrete", bevel=.035)
        self.add(path, "box", "PowerCabinet", (0, .615, 0), (.82, 1.08, .55), "cabinet", bevel=.025)
        self.add(path, "box", "DoorGasket", (0, .62, .277), (.76, .99, .012), "rubber", bevel=.01)
        self.add(path, "box", "CabinetDoor", (0, .62, .292), (.725, .952, .027), "cabinet", bevel=.01)
        for y in (.28, .94):
            self.add(path, "rod", "DoorHinge", (-.37, y-.045, .305), (-.37, y+.045, .305), .023, "steel", segs=24)
        self.add(path, "box", "RecessedHandle", (.29, .56, .313), (.043, .12, .014), "dark_steel", bevel=.008)
        self.add(path, "rod", "EmergencyButtonSocket", (.24, .80, .309), (.24, .80, .331), .051, "yellow", segs=32)
        self.add(path, "rod", "EmergencyButton", (.24, .80, .33), (.24, .80, .354), .030, "red_button", segs=32)
        self.add(path, "box", "StatusDisplayFrame", (-.135, .96, .32), (.285, .125, .02), "dark_steel", bevel=.006)
        self.add(path, "box", "StatusDisplay", (-.135, .96, .331), (.251, .088, .008), "screen", bevel=.003)
        self.add(path, "rod", "PowerLED", (.058, .96, .323), (.058, .96, .336), .015, "green_lens", segs=20)
        self.quad(path, "IdentificationPlate", [(-.28, .42, .312), (.12, .42, .312), (.12, .68, .312), (-.28, .68, .312)],
                  "label", [(0, 0), (1, 0), (1, 1), (0, 1)])
        for x in (-.413, .413):
            self.add(path, "box", "VentRecess", (x, .48, -.02), (.004, .39, .31), "black")
            start = len(self.mesh.parts)
            for i in range(12):
                self.add(path, "box", "VentLouver", (x*1.01, .30+i*.032, -.02), (.015, .014, .275), "cabinet")
            self.merge(start, "VentLouvers")
        for x in (-.3, .3):
            self.add(path, "box", "CabinetFoot", (x, .09, 0), (.085, .14, .35), "dark_steel", bevel=.006)
        self.add(path, "tube", "CableConduit", [(0, .12, -.17), (0, -.012, -.3), (0, -.025, -.7), (-.8, -.025, -.7)],
                 .018, "black", steps=4, segs=12)

    def windsock(self):
        self.node("Windsock")
        x, z = 6.77, -6.76
        self.add("Windsock/Mast", "box", "MastFooting", (x, -.015, z), (.65, .12, .65), "concrete", bevel=.028)
        self.add("Windsock/Mast", "box", "MastBasePlate", (x, .055, z), (.30, .03, .30), "steel", bevel=.006)
        self.add("Windsock/Mast", "rod", "TaperedMast", (x, .06, z), (x, 3.18, z), .053, "steel", r2=.034, segs=40)
        for dx in (-.105, .105):
            for dz in (-.105, .105):
                self.add("Windsock/Mast", "rod", "AnchorBolt", (x+dx, .06, z+dz), (x+dx, .093, z+dz), .013, "dark_steel", segs=6)
        self.add("Windsock/Mast", "rod", "MastWarningBand", (x, .62, z), (x, .82, z), .054, "yellow", segs=32)
        self.add("Windsock/Mast", "rod", "SwivelBearing", (x, 3.10, z), (x, 3.20, z), .068, "dark_steel", segs=32)
        yaw = self.node("Windsock/Yaw", translation=(x, 3.15, z), axis="Y",
                        curve=lambda t: -65 + 17*math.sin(2*math.pi*t/CYCLE))
        self.add(yaw, "rod", "SwivelArm", (0, -.015, 0), (0, .12, .16), .018, "steel", segs=20)
        self.add(yaw, "profiled_ring", "WindsockHoop", (0, .12, .19), .19,
                 [(.009*math.cos(a*math.pi/4), .009*math.sin(a*math.pi/4)) for a in range(8)],
                 "steel", segs=64, axis="z")
        lengths, radii = [.40, .37, .34, .31, .28], [.184, .158, .132, .108, .084, .06]
        parent = yaw
        for i, length in enumerate(lengths):
            phase = i*.48
            node = self.node(parent + f"/Fabric{i+1:02}", translation=(0, .12, .19) if i == 0 else (0, 0, lengths[i-1]),
                             axis="X", curve=lambda t, i=i, phase=phase: 3.5 + i*.6 + (2.0+i*.5)*math.sin(2*math.pi*t/CYCLE+phase))
            # Closed thin fabric wall, with open air passages at each end.
            points, faces, segs = [], [], 48
            for zz, rr in [(0, radii[i]), (length, radii[i+1]), (length, radii[i+1]-.003), (0, radii[i]-.003)]:
                for j in range(segs):
                    a = 2*math.pi*j/segs
                    crease = 1 + .018*math.sin(8*a)
                    points.append((rr*crease*math.cos(a), rr*crease*math.sin(a), zz))
            for k in range(4):
                for j in range(segs):
                    faces.append((k*segs+j, k*segs+(j+1)%segs, ((k+1)%4)*segs+(j+1)%segs, ((k+1)%4)*segs+j))
            self.add(node, "mesh", "WindsockFabric", points, faces, "wind_orange" if i % 2 == 0 else "wind_white", True)
            parent = node

    def write(self, path):
        frames = round(CYCLE*FPS)
        lines = ["#usda 1.0", "(", '    defaultPrim = "LaunchPad"', "    metersPerUnit = 1", '    upAxis = "Y"',
                 "    startTimeCode = 0", f"    endTimeCode = {frames}", f"    timeCodesPerSecond = {FPS}",
                 f"    framesPerSecond = {FPS}", ")", 'def Xform "LaunchPad" (', '    kind = "component"',
                 '    documentation = "Original UAV launch/landing pad; 12 x 12 m deck; landing surface Y=0; +Z approach."',
                 "    customData = {", '        string assetID = "uav-launch-pad"',
                 '        string design = "Original visual concept; no claim of regulatory approval or load rating"',
                 "        double landingSurfaceY = 0", "        double deckWidthM = 12", "        double deckLengthM = 12", "    }", ")", "{"]
        lines += ['    def Scope "Materials"', "    {"]
        for mat in sorted({p["material"] for p in self.mesh.parts}):
            color, roughness, metallic = MATERIALS[mat]
            srgb = [int(color[k:k+2], 16)/255 for k in (1, 3, 5)]
            rgb = [v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in srgb]
            base = f"/LaunchPad/Materials/{mat}"
            lines += [f'        def Material "{mat}"', "        {", f"            token outputs:surface.connect = <{base}/Surface.outputs:surface>",
                      '            def Shader "Surface"', "            {", '                uniform token info:id = "UsdPreviewSurface"',
                      f"                color3f inputs:diffuseColor = {tup(rgb)}", f"                float inputs:roughness = {roughness}",
                      f"                float inputs:metallic = {metallic}"]
            if mat in TEXTURES:
                lines += [f"                color3f inputs:diffuseColor.connect = <{base}/Texture.outputs:rgb>"]
            if mat == "green_lens":
                lines += ["                color3f inputs:emissiveColor = (0.008, 0.080, 0.035)"]
            lines += ["                token outputs:surface", "            }"]
            if mat in TEXTURES:
                lines += ['            def Shader "UV"', "            {", '                uniform token info:id = "UsdPrimvarReader_float2"',
                          '                string inputs:varname = "st"', "                float2 outputs:result", "            }",
                          '            def Shader "Texture"', "            {", '                uniform token info:id = "UsdUVTexture"',
                          f"                asset inputs:file = @textures/{TEXTURES[mat]}@", '                token inputs:sourceColorSpace = "sRGB"',
                          '                token inputs:wrapS = "repeat"', '                token inputs:wrapT = "repeat"',
                          f"                float2 inputs:st.connect = <{base}/UV.outputs:result>", "                float3 outputs:rgb", "            }"]
            lines += ["        }"]
        lines += ["    }"]

        def node(path, depth):
            indent = "    " * depth
            info = self.nodes[path]
            lines.extend([f'{indent}def Xform "{path.split("/")[-1]}"', indent+"{"])
            ops = []
            if "translation" in info:
                lines.append(f"{indent}    double3 xformOp:translate = {tup(info['translation'])}")
                ops.append("xformOp:translate")
            if "curve" in info:
                op = "xformOp:rotate" + info["axis"]
                lines.append(f"{indent}    float {op} = {info['curve'](0):.7g}")
                samples = ", ".join(f"{f}: {info['curve'](f/FPS):.7g}" for f in range(frames+1))
                lines.append(f"{indent}    float {op}.timeSamples = {{{samples}}}")
                ops.append(op)
            if ops:
                lines.append(f"{indent}    uniform token[] xformOpOrder = {json.dumps(ops)}")
            for part in self.mesh.parts:
                if part["parent"] != path:
                    continue
                p = part["points"]
                low = [min(q[k] for q in p) for k in range(3)]
                high = [max(q[k] for q in p) for k in range(3)]
                lines.extend([f'{indent}    def Mesh "{part["name"]}" (prepend apiSchemas = ["MaterialBindingAPI"])', indent+"    {",
                              f'{indent}        uniform token subdivisionScheme = "none"', f'{indent}        bool doubleSided = false',
                              f'{indent}        point3f[] points = [{", ".join(tup(q) for q in p)}]',
                              f'{indent}        int[] faceVertexCounts = {array([3]*len(part["faces"]))}',
                              f'{indent}        int[] faceVertexIndices = {array([i for f in part["faces"] for i in f])}',
                              f'{indent}        normal3f[] normals = [{", ".join(tup(q) for q in part["normals"])}] (interpolation = "{part["interpolation"]}")',
                              f'{indent}        float3[] extent = [{tup(low)}, {tup(high)}]',
                              f'{indent}        rel material:binding = </LaunchPad/Materials/{part["material"]}>'])
                if "uv" in part:
                    uv = [part["uv"][i] for f in part["faces"] for i in f]
                    lines.append(f'{indent}        texCoord2f[] primvars:st = [{", ".join(tup(q) for q in uv)}] (interpolation = "faceVarying")')
                lines.append(indent+"    }")
            for child in self.nodes:
                if child and child.rpartition("/")[0] == path:
                    node(child, depth+1)
            lines.append(indent+"}")

        for node_path in self.nodes:
            if node_path and "/" not in node_path:
                node(node_path, 1)
        lines.append("}")
        path.write_text("\n".join(lines)+"\n")


def main():
    SOURCE.mkdir(parents=True, exist_ok=True)
    textures()
    pad = Pad().build()
    names = [p["name"] for p in pad.mesh.parts]
    assert len(names) == len(set(names))
    for part in pad.mesh.parts:
        assert all(math.isfinite(v) for q in part["points"] for v in q), part["name"]
        assert all(0 <= i < len(part["points"]) for f in part["faces"] for i in f), part["name"]
    source, asset = SOURCE / (IDENT+".usda"), OUT / (IDENT+".usdz")
    pad.write(source)
    with tempfile.TemporaryDirectory(prefix="uav-launch-pad-") as temp:
        binary = Path(temp) / (IDENT+".usdc")
        run(["/usr/bin/usdcat", source, "-o", binary])
        # Keep relative texture assets resolvable from the temporary root layer.
        shutil.copytree(SOURCE / "textures", Path(temp) / "textures")
        run(["/usr/bin/usdzip", "--arkitAsset", binary, asset])
    report = run(["/usr/bin/usdchecker", "--arkit", asset])
    (OUT / "usdchecker.txt").write_text(report)
    metadata = {
        "id": IDENT, "name": "Стартовая площадка БВС", "file": asset.name,
        "design": "Original visual concept, procedural geometry and textures",
        "visible_text": False, "markings": "White UAV pictogram inside a dark octagon with yellow outline, alignment ring and direction arrow",
        "meters_per_unit": 1, "up_axis": "Y", "approach_axis": "+Z",
        "origin": "Centre of the landing surface, Y=0",
        "deck_size_m": [12, 12], "apron_size_m": [16, 16],
        "landing_surface_y_m": 0, "foundation_bottom_y_m": -.31,
        "clear_centre_radius_m": 5.5, "flush_lens_max_y_m": .01,
        "mesh_count": len(pad.mesh.parts), "triangles": sum(len(p["faces"]) for p in pad.mesh.parts),
        "materials": len({p["material"] for p in pad.mesh.parts}),
        "edge_lights": 12, "concrete_slabs": 16,
        "animation": {"duration_seconds": CYCLE, "fps": FPS,
                      "nodes": [p for p, d in pad.nodes.items() if "curve" in d],
                      "description": "Cyclic windsock heading and five articulated fabric sections"},
        "sha256": hashlib.sha256(asset.read_bytes()).hexdigest(), "bytes": asset.stat().st_size,
        "arkit_validation": "passed",
    }
    (OUT / "manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n")
    bundle = ROOT / "DroneUAVDemo/Resources/Models/LaunchPads"
    bundle.mkdir(parents=True, exist_ok=True)
    shutil.copy2(asset, bundle / asset.name)
    shutil.copy2(OUT / "manifest.json", bundle / "manifest.json")
    print(json.dumps({k: metadata[k] for k in ("file", "mesh_count", "triangles", "materials", "bytes", "arkit_validation")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
