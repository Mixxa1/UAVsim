"""Detailed display meshes and portable UsdPreviewSurface materials.

All models are original representative designs for the project's fictional
hardware. Coordinates are metres, +Y up, +Z forward. These are visual assets;
the application continues to use its catalog/CAD engineering properties.
"""
from pathlib import Path
import hashlib
import json
import math
import sys
import threading

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/UAVModelAssets"))
from geometry import Model, add, sub, mul, cross, unit, norm, mix, tup, array, safe, spline

OUT = ROOT / "Assets/WorkbenchModels"
TEX = OUT / "sources/textures"
MATERIALS = {
    "carbon": ("#43494F", .40, .08, "carbon"),
    "carbon_edge": ("#222831", .58, .02, None),
    "steel": ("#B7C1C9", .25, .86, "brushed"),
    "alloy": ("#8A99A6", .34, .77, "brushed"),
    "black_metal": ("#252C34", .35, .70, "machined"),
    "copper": ("#B87942", .28, .82, None),
    "gold": ("#D2AF58", .27, .78, None),
    "solder": ("#AAB8BF", .28, .82, None),
    "polymer": ("#252D35", .58, .02, "grain"),
    "rubber": ("#1B2127", .85, 0, "grain"),
    "seam": ("#222D34", .82, 0, None),
    "silicon": ("#1B242C", .51, .05, None),
    "ceramic": ("#D1CCC2", .72, 0, "grain"),
    "white": ("#DBE1DE", .39, .01, "paint"),
    "red": ("#B4433C", .58, 0, "grain"),
    "wire_black": ("#202830", .62, 0, "grain"),
    "yellow": ("#DCB454", .53, 0, "grain"),
    "wire_white": ("#DADDD5", .63, 0, None),
    "glass": ("#173442", .09, .26, None),
    "ir_glass": ("#493739", .15, .39, None),
    "strap": ("#333B44", .91, 0, "weave"),
    "silver_foil": ("#969CA1", .57, .43, "grain"),
    "led": ("#83CAB2", .26, 0, None),
}
_texture_lock = threading.Lock()
_baked = {}


def color_material(name, color, rough=.42, metal=.50, pattern="machined"):
    MATERIALS[name] = (color, rough, metal, pattern)
    return name


def create_textures():
    TEX.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20261008)
    for name in ["carbon", "brushed", "machined", "grain", "paint", "weave"]:
        # Woven carbon needs a 1K pattern. Fine finish maps tile at millimetre
        # scale, so 512 px retains detail without duplicating megabytes per bolt.
        n = 1024 if name == "carbon" else 512
        yy, xx = np.mgrid[:n, :n]
        noise = rng.normal(0, 1, (n, n))
        if name == "carbon":
            # Two-over/two-under twill, with individual fibres in each tow.
            cell = 64
            diagonal = ((xx // cell + yy // cell) % 4) < 2
            fibre = np.where(diagonal, np.sin(xx * math.pi / 4), np.sin(yy * math.pi / 4))
            ridge = np.where(diagonal, np.sin((xx % cell) * math.pi / cell),
                             np.sin((yy % cell) * math.pi / cell))
            values = 191 + 31 * ridge + 10 * fibre + 2 * noise
            height = ridge * .7 + fibre * .06
            rough = 111 + 18 * (1 - ridge) + noise * 3
        elif name == "weave":
            values = 189 + 27 * np.sin(xx * math.pi / 6) * np.sin(yy * math.pi / 6) + noise * 3
            height = (values - 189) / 45
            rough = 221 + noise * 4
        elif name in ("brushed", "machined"):
            line = rng.normal(0, 1, (n, 1))
            values = 229 + line * 5 + noise * 1.3
            height = line * .05 + noise * .008
            rough = 93 + line * 9 + noise * 2
        else:
            values = 230 + noise * (2 if name == "paint" else 4)
            height = noise * (.012 if name == "paint" else .035)
            rough = 132 + noise * 4
        rgb = np.repeat(np.clip(values[..., None], 0, 255), 3, axis=2).astype(np.uint8)
        Image.fromarray(rgb).save(TEX / f"{name}-color.png", optimize=True)
        dy, dx = np.gradient(height)
        normals = np.stack([-dx * .75, -dy * .75, np.ones_like(dx)], axis=-1)
        normals /= np.linalg.norm(normals, axis=-1)[..., None]
        Image.fromarray(np.clip((normals * .5 + .5) * 255, 0, 255).astype(np.uint8)).save(TEX / f"{name}-normal.png")
        Image.fromarray(np.clip(rough, 0, 255).astype(np.uint8)).save(TEX / f"{name}-rough.png")
    (TEX/"texture-version.txt").write_text("2\n")


def font(size):
    for path in ["/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc"]:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


class Asset(Model):
    def __init__(self, spec):
        super().__init__(spec["id"], spec["name"])
        self.spec = spec
        self.group = "Geometry"
        self.notes = []
        self.accent = color_material("accent_" + safe(self.id), spec["color"], .41, .58)
        self.plastic = color_material("plastic_" + safe(self.id), spec["color"], .54, .02, "grain")
        self.board = color_material("pcb_" + safe(self.id), spec["color"], .62, .05, "paint")

    def mesh(self, *args, **kwargs):
        old = len(self.parts)
        super().mesh(*args, **kwargs)
        if len(self.parts) != old:
            self.parts[-1]["section"] = self.group

    def cylinder(self, name, c, r, h, mat="black_metal", axis="y", segs=72):
        v = {"x": (h / 2, 0, 0), "y": (0, h / 2, 0), "z": (0, 0, h / 2)}[axis]
        self.rod(name, sub(c, v), add(c, v), r, mat, segs=segs)

    def torus(self, name, c, r, tube, mat="steel", axis="y", segs=80):
        self.profiled_ring(name, c, r, [(tube * math.cos(a), tube * math.sin(a))
                          for a in np.linspace(0, 2 * math.pi, 13)[:-1]], mat, segs, axis)

    def washer(self, name, c, outer, inner, h, mat="steel", axis="y", segs=64):
        self.profiled_ring(name, c, 0, [(inner, -h / 2), (outer, -h / 2),
                            (outer, h / 2), (inner, h / 2)], mat, segs, axis)

    def fastener(self, c, r=.0012, axis="y", facing=1):
        self.cylinder("FastenerHead", c, r, r * .36, "steel", axis, 32)
        # Recessed hex socket remains legible at grazing angles.
        d = mul({"x": (r * .177, 0, 0), "y": (0, r * .177, 0), "z": (0, 0, r * .177)}[axis], facing)
        self.cylinder("HexSocket", add(c, d), r * .43, r * .015, "seam", axis, 6)

    def cable(self, name, points, r, mat="wire_black"):
        self.tube(name, points, r, mat, steps=9, segs=12)

    def hull(self, name, sections, mat="white", segs=96, subdiv=12):
        rings = spline(sections, max(subdiv, 6))
        points = [(rx*math.cos(i*2*math.pi/segs), cy+ry*math.sin(i*2*math.pi/segs), z)
                  for z, rx, ry, cy in rings for i in range(segs)]
        faces = []
        for j in range(len(rings)-1):
            for i in range(segs):
                a, b = j*segs+i, j*segs+(i+1)%segs
                faces.append((a, b, b+segs, a+segs))
        first = len(points)
        points.extend(points[:segs])
        last = len(points)
        points.extend(points[(len(rings)-1)*segs:len(rings)*segs])
        faces += [tuple(first+i for i in range(segs-1, -1, -1)), tuple(last+i for i in range(segs))]
        self.mesh(name, points, faces, mat, True)
        self.hull_specs.append((name, rings, mat))

    def label(self, c, size, title, subtitle="", axis="y", light=False, host=None):
        ident = safe(self.id + "_" + title)
        w, h = size
        ratio = w/h
        width = 1536 if ratio >= 1 else 768
        height = max(192, min(3072, round(width/ratio)))
        im = Image.new("RGB", (width, height), (211, 217, 213) if light else (30, 39, 47))
        d = ImageDraw.Draw(im)
        ink = (36, 45, 54) if light else (218, 226, 222)
        accent = tuple(int(self.spec["color"][i:i+2], 16) for i in (1, 3, 5))
        pad = max(15, int(width*.075))
        fs = int(min(width*.15, height*.19))
        while d.textbbox((0, 0), title, font=font(fs))[2] > width-2*pad and fs > 14:
            fs -= 2
        border = max(2, int(min(width, height)*.006))
        d.rounded_rectangle((border*2, border*2, width-border*2, height-border*2),
                            radius=pad*.25, outline=ink, width=border)
        d.rectangle((pad*.48, pad, pad*.65, pad+fs*1.2), fill=accent)
        d.text((pad, pad*.82), title, fill=ink, font=font(fs))
        sy = pad+fs*1.6
        sf = int(min(width*.064, height*.10))
        while d.textbbox((0, 0), subtitle, font=font(sf))[2] > width-2*pad and sf > 12:
            sf -= 2
        d.text((pad, sy), subtitle, fill=ink, font=font(sf))
        liney = sy+sf*1.75
        d.line((pad, liney, width-pad, liney), fill=ink, width=border)
        brand_font = int(min(width*.080, height*.10))
        brand = self.spec.get("brand", "UAVSIM").upper()
        d.text((pad, liney+brand_font*.45), brand, fill=ink, font=font(brand_font))
        warning = "INSPECT BEFORE FLIGHT"
        wf = int(min(width*.039, height*.065))
        d.text((pad, height-pad-wf), warning, fill=ink, font=font(wf))
        seed = int(hashlib.sha256(self.id.encode()).hexdigest()[:8], 16)
        rng = np.random.default_rng(seed)
        for x in range(int(width*.61), int(width*.88), max(2, width//220)):
            if rng.random() > .35:
                d.rectangle((x, height*.67, x+max(1, width//430), height*.85), fill=ink)
        filename = ident + ".png"
        im.save(TEX / filename, optimize=True)
        mat = "label_" + ident
        MATERIALS[mat] = ("#FFFFFF", .72, 0, "label:" + filename)
        k = {"x": 0, "y": 1, "z": 2}[axis]
        def project(q, part):
            axes = [i for i in range(3) if i != k]
            pts = np.asarray(part["points"], dtype=float)
            faces = np.asarray(part["faces"], dtype=int)
            a, b, e = [pts[faces[:, i]] for i in range(3)]
            uv, vv = b[:, axes]-a[:, axes], e[:, axes]-a[:, axes]
            det = uv[:, 0]*vv[:, 1]-uv[:, 1]*vv[:, 0]
            valid = np.abs(det) > 1e-18
            delta = np.asarray(q)[axes]-a[:, axes]
            denominator = np.where(valid, det, 1)
            u = (delta[:, 0]*vv[:, 1]-delta[:, 1]*vv[:, 0])/denominator
            v = (uv[:, 0]*delta[:, 1]-uv[:, 1]*delta[:, 0])/denominator
            hit = valid & (u >= -1e-7) & (v >= -1e-7) & (u+v <= 1+1e-7)
            values = (a[:, k]+u*(b[:, k]-a[:, k])+v*(e[:, k]-a[:, k]))[hit]
            return min(values, key=lambda p: abs(p-q[k])) if len(values) else None
        candidates = [p for p in self.parts if not p["material"].startswith("label_")
                      and (host is None or p["name"].startswith(host+"_"))]
        hits = [(abs(value-c[k]), p) for p in candidates if (value := project(c, p)) is not None]
        if not hits:
            raise ValueError(f"{self.id}: no {axis}-facing surface under label {title}")
        target = min(hits, key=lambda p: p[0])[1]
        points, uv, faces = [], [], []
        n = 8
        for i in range(n+1):
            for j in range(n+1):
                x, z = (i/n-.5)*w, (j/n-.5)*h
                p = (x, 0, z) if axis == "y" else (x, -z, 0) if axis == "z" else (0, x, z)
                q = list(add(c, p))
                value = project(q, target)
                if value is None:
                    raise ValueError(f"{self.id}: label {title} overhangs {target['name']}")
                q[k] = value+.000015
                points.append(tuple(q))
                uv.append((i/n, 1-j/n))
        for i in range(n):
            for j in range(n):
                a = i*(n+1)+j
                faces.append((a, a+1, a+n+2, a+n+1))
        self.mesh("IdentificationLabel", points, faces, mat, True)
        part = self.parts[-1]
        if sum(v[k] for v in part["normals"]) < 0:
            part["faces"] = [(a, e, b) for a, b, e in part["faces"]]
            part["normals"] = [mul(v, -1) for v in part["normals"]]
        part["uv"] = uv
        part["attached_to"] = target["name"]
        part["attachment_clearance_m"] = .000015
        self.parts[-1]["double_sided"] = True

    def lens(self, c, r, depth, axis="z", ir=False):
        v = {"x": (1, 0, 0), "y": (0, 1, 0), "z": (0, 0, 1)}[axis]
        self.cylinder("LensBarrel", add(c, mul(v, depth*.35)), r, depth*.7, "black_metal", axis)
        self.washer("LensBezel", add(c, mul(v, depth*.74)), r*1.07, r*.78, depth*.12, "polymer", axis)
        self.washer("RetentionRing", add(c, mul(v, depth*.775)), r*.90, r*.78, depth*.04, "alloy", axis)
        self.torus("OpticGasket", add(c, mul(v, depth*.74)), r*.77, r*.023, "rubber", axis, 64)
        glass = add(c, mul(v, depth*.73))
        radii = [r*.76, r*.76, depth*.06]
        if axis == "x":
            radii = [depth*.06, r*.76, r*.76]
        elif axis == "y":
            radii = [r*.76, depth*.06, r*.76]
        self.ellipsoid("CoatedOpticalGlass", glass, radii, "ir_glass" if ir else "glass", 64, 22)
        for j in range(24):
            a = j * 2 * math.pi / 24
            p = (r*1.01*math.cos(a), r*1.01*math.sin(a), depth*.48)
            if axis == "y":
                p = (p[0], p[2], p[1])
            elif axis == "x":
                p = (p[2], p[0], p[1])
            self.box("FocusGrip", add(c, p), (r*.045, r*.045, depth*.34) if axis == "z" else (r*.045, depth*.34, r*.045), "polymer", r*.014)

    def header(self, c, count, pitch=.00125, axis="z", facing=1):
        start = len(self.parts)
        w = (count+1)*pitch
        self.box("ConnectorHousing", c, (w, pitch*1.55, pitch*1.8), "ceramic", pitch*.15)
        for i in range(count):
            x = (i-(count-1)/2)*pitch
            self.box("ConnectorCavity", add(c, (x, 0, pitch*.91)), (pitch*.56, pitch*.78, pitch*.025), "seam")
            self.box("ContactPin", add(c, (x, -pitch*.09, pitch*.93)), (pitch*.21, pitch*.22, pitch*.03), "gold")
        forward = mul({"x": (1, 0, 0), "y": (0, 1, 0), "z": (0, 0, 1)}[axis], facing)
        right = unit(cross((0, 0, -1) if axis == "y" else (0, 1, 0), forward))
        up = cross(forward, right)
        def orient(p):
            return add(add(mul(right, p[0]), mul(up, p[1])), mul(forward, p[2]))
        for part in self.parts[start:]:
            part["points"] = [add(c, orient(sub(p, c))) for p in part["points"]]
            part["normals"] = [orient(n) for n in part["normals"]]


def linear_color(hexvalue):
    color = [int(hexvalue[i:i+2], 16)/255 for i in (1, 3, 5)]
    return [v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in color]


def material_textures(mat):
    """Bake tint and roughness for importers that ignore UsdUVTexture.scale.

    SceneKit's USD importer accepts the maps but drops the multiplicative
    scale. Putting the final values in the images keeps Finder, Quick Look
    and the actual Workbench renderer consistent.
    """
    color, rough, _, pattern = MATERIALS[mat]
    if not pattern:
        return []
    if pattern.startswith("label:"):
        return [("Color", pattern[6:], True)]
    key = (pattern, color, rough)
    with _texture_lock:
        if key in _baked:
            return _baked[key]
        token = hashlib.sha256(json.dumps(key).encode()).hexdigest()[:14]
        colorfile, roughfile = f"surface-{token}-color.png", f"surface-{token}-rough.png"
        tint = np.asarray([int(color[i:i+2], 16)/255 for i in (1, 3, 5)])
        pixels = np.asarray(Image.open(TEX/(pattern+"-color.png")).convert("RGB"), dtype=float)
        Image.fromarray(np.clip(pixels*tint, 0, 255).astype(np.uint8)).save(TEX/colorfile, optimize=True)
        pixels = np.asarray(Image.open(TEX/(pattern+"-rough.png")), dtype=float)
        Image.fromarray(np.clip(pixels*rough/.52, 0, 255).astype(np.uint8)).save(TEX/roughfile, optimize=True)
        result = [("Color", colorfile, True), ("Normal", pattern+"-normal.png", False), ("Rough", roughfile, False)]
        _baked[key] = result
        return result


def write_usda(asset, path):
    lines = ["#usda 1.0", "(", '    defaultPrim = "WorkbenchPart"', "    metersPerUnit = 1",
             '    upAxis = "Y"', ")", 'def Xform "WorkbenchPart" (', '    kind = "component"',
             "    customData = {", "        string catalogID = " + json.dumps(asset.id),
             '        string forwardAxis = "+Z"', "    }", ")", "{", '    def Scope "Materials"', "    {"]
    for mat in sorted({p["material"] for p in asset.parts}):
        color, rough, metal, pattern = MATERIALS[mat]
        base = f"/WorkbenchPart/Materials/{mat}"
        lines += [f'        def Material "{mat}"', "        {",
                  f"            token outputs:surface.connect = <{base}/Surface.outputs:surface>",
                  '            def Shader "Surface"', "            {", '                uniform token info:id = "UsdPreviewSurface"',
                  f"                color3f inputs:diffuseColor = {tup(linear_color(color))}",
                  f"                float inputs:roughness = {rough}", f"                float inputs:metallic = {metal}",
                  "                float inputs:ior = 1.46"]
        if pattern:
            lines += [f"                color3f inputs:diffuseColor.connect = <{base}/Color.outputs:rgb>"]
            if not pattern.startswith("label:"):
                lines += [f"                normal3f inputs:normal.connect = <{base}/Normal.outputs:rgb>",
                          f"                float inputs:roughness.connect = <{base}/Rough.outputs:r>"]
        lines += ["                token outputs:surface", "            }"]
        if pattern:
            lines += ['            def Shader "UV"', "            {", '                uniform token info:id = "UsdPrimvarReader_float2"',
                      '                string inputs:varname = "st"', "                float2 outputs:result", "            }"]
            textures = material_textures(mat)
            for name, filename, srgb in textures:
                lines += [f'            def Shader "{name}"', "            {", '                uniform token info:id = "UsdUVTexture"',
                          f"                asset inputs:file = @textures/{filename}@",
                          '                token inputs:sourceColorSpace = "' + ("sRGB" if srgb else "raw") + '"',
                          '                token inputs:wrapS = "repeat"', '                token inputs:wrapT = "repeat"',
                          f"                float2 inputs:st.connect = <{base}/UV.outputs:result>"]
                if name == "Normal":
                    lines += ["                float4 inputs:scale = (2, 2, 2, 1)", "                float4 inputs:bias = (-1, -1, -1, 0)"]
                lines += ["                float3 outputs:rgb", "                float outputs:r", "            }"]
        lines += ["        }"]
    lines += ["    }"]
    for section in dict.fromkeys(p["section"] for p in asset.parts):
        lines += [f'    def Xform "{safe(section)}"', "    {"]
        for part in [p for p in asset.parts if p["section"] == section]:
            pts = part["points"]
            lo = [min(p[k] for p in pts) for k in range(3)]
            hi = [max(p[k] for p in pts) for k in range(3)]
            lines += [f'        def Mesh "{part["name"]}" (prepend apiSchemas = ["MaterialBindingAPI"])', "        {",
                      '            uniform token subdivisionScheme = "none"', '            uniform token orientation = "rightHanded"',
                      f'            bool doubleSided = {str(part.get("double_sided", False)).lower()}',
                      "            point3f[] points = [" + ", ".join(tup(p) for p in pts) + "]",
                      "            int[] faceVertexCounts = " + array([3]*len(part["faces"])),
                      "            int[] faceVertexIndices = " + array([v for f in part["faces"] for v in f]),
                      "            normal3f[] normals = [" + ", ".join(tup(n) for n in part["normals"]) +
                      f'] (interpolation = "{part["interpolation"]}")',
                      f"            float3[] extent = [{tup(lo)}, {tup(hi)}]",
                      f'            rel material:binding = </WorkbenchPart/Materials/{part["material"]}>']
            pattern = MATERIALS[part["material"]][3]
            if pattern:
                if "uv" in part:
                    uv = part["uv"]
                    interpolation = "vertex"
                else:
                    uv = []
                    # Independent face projection keeps tiny hardware texture scale
                    # consistent and avoids UV pinching at cylindrical end caps.
                    texscale = 1/.0025 if pattern in ("carbon", "weave") else 1/.009
                    for face in part["faces"]:
                        n = cross(sub(pts[face[1]], pts[face[0]]), sub(pts[face[2]], pts[face[0]]))
                        axes = [k for k in range(3) if k != max(range(3), key=lambda k: abs(n[k]))]
                        uv.extend(tuple(pts[v][k]*texscale for k in axes) for v in face)
                    interpolation = "faceVarying"
                lines += ["            texCoord2f[] primvars:st = [" + ", ".join(tup(u) for u in uv) +
                          f'] (interpolation = "{interpolation}")']
            lines += ["        }"]
        lines += ["    }"]
    lines += ["}"]
    path.write_text("\n".join(lines) + "\n")


def referenced_textures(asset):
    files = set()
    for part in asset.parts:
        files.update(filename for _, filename, _ in material_textures(part["material"]))
    return sorted(files)
