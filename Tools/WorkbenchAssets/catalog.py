"""Read the built-in Workbench catalog without duplicating its specifications.

This deliberately handles the literal constructors used by the two Swift
libraries. Unknown expressions fail the build instead of silently inventing a
dimension. The native Swift probe independently verifies coverage and dimensions.
"""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[2]


def constructors(text, marker):
    for match in re.finditer(re.escape(marker) + r"\s*\(", text):
        start = match.end()
        depth, quoted, escaped = 1, False, False
        for i in range(start, len(text)):
            c = text[i]
            if quoted:
                if escaped:
                    escaped = False
                elif c == "\\":
                    escaped = True
                elif c == '"':
                    quoted = False
            elif c == '"':
                quoted = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    yield text[start:i]
                    break
        else:
            raise ValueError("Unclosed catalog constructor")


def number(value):
    return float(value.strip().replace("_", ""))


def scalar(text, field, default=None):
    match = re.search(r"\b" + field + r":\s*([-+\d_.]+)", text)
    if match:
        return number(match[1])
    if default is not None:
        return default
    raise ValueError(f"No literal value for {field}")


def string(text, field):
    match = re.search(r"\b" + field + r':\s*("(?:[^"\\]|\\.)*")', text)
    if not match:
        raise ValueError(f"No string value for {field}")
    return json.loads(match[1])


def vectors(text):
    return [[scalar(v, k) for k in ("x", "y", "z")]
            for v in constructors(text, "CodableVector3D")]


def components():
    text = (ROOT / "DroneUAVDemo/Domain/WorkbenchComponentLibrary.swift").read_text()
    rows = []
    for item in constructors(text, ".init"):
        if not re.search(r'\bid: "', item):
            continue
        kind = re.search(r"\bkind:\s*\.(\w+)", item)[1]
        shape, args = re.search(r"proxy:\s*\.(\w+)\(([^)]+)\)", item).groups()
        color = re.search(r'"(#[0-9A-Fa-f]{6})"', args)[1]
        if shape == "cylinder":
            d, h = scalar(args, "diameter"), scalar(args, "height")
            size = [d, h, d]
        else:
            size = [number(v) for v in args.split(",")[:3]]
        params = {key: number(value) for key, value in
                  re.findall(r"P\.(\w+):\s*([-+\d_.]+)", item)}
        rows.append(dict(id=string(item, "id"), name=string(item, "displayName"),
                         kind=kind, brand=string(item, "brand"),
                         summary=string(item, "summary"), mass_kg=scalar(item, "massKg"),
                         shape=shape, size=size, color=color, params=params))
    assert len({r["id"] for r in rows}) == len(rows)
    return rows


def frames():
    text = (ROOT / "DroneUAVDemo/Domain/WorkbenchFrame.swift").read_text()
    rows = []
    for item in constructors(text, "WorkbenchFrameSpec"):
        if not re.search(r'\bid: "', item):
            continue
        size = vectors(re.search(r"sizeMeters:\s*(CodableVector3D\([^)]*\))", item)[1])[0]
        family = re.search(r"frameClass:\s*\.(\w+)", item)[1]
        architecture = re.search(r"architecture:\s*\.(\w+)", item)
        architecture = architecture[1] if architecture else "multicopter"
        arm = scalar(item, "armLengthM")
        if "motorMounts: quadMounts" in item:
            a = scalar(re.search(r"quadMounts\(([^)]+)\)", item)[1], "arm") * .7071
            mounts = [[a, 0, a], [-a, 0, a], [-a, 0, -a], [a, 0, -a]]
        elif "motorMounts: deadcatMounts()" in item:
            mounts = [[-.090, 0, .090], [.090, 0, .090], [-.104, 0, -.066], [.104, 0, -.066]]
        else:
            mounts = vectors(re.search(r"motorMounts:\s*\[([\s\S]*?)\]", item)[1])
        rows.append(dict(id=string(item, "id"), name=string(item, "name"), kind="frame",
                         brand="UAVSim", shape="frame", size=size, family=family,
                         architecture=architecture, arm_length=arm, mounts=mounts,
                         fc_bay=vectors(re.search(r"fcBay:\s*(CodableVector3D\([^)]*\))", item)[1])[0],
                         camera_mount=vectors(re.search(r"cameraMount:\s*(CodableVector3D\([^)]*\))", item)[1])[0],
                         prop_max=scalar(item, "propMaxInch"),
                         stator_max=scalar(item, "motorStatorMaxMm"),
                         wing_area=scalar(item, "wingAreaM2", 0),
                         mass_kg=scalar(item, "massKg"), color="#3E728F"))
    assert len({r["id"] for r in rows}) == len(rows)
    return rows


def catalog():
    return frames() + components()
