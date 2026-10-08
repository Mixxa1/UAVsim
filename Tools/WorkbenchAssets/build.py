#!/usr/bin/env python3
"""Build, validate and install the complete original Workbench USDZ library.

Use the bundled Python runtime (numpy and Pillow), plus macOS usdcat/usdzip/
usdchecker. --only accepts a catalog id for iteration. Full builds always check
catalog coverage, make the four wing/fuselage subsets and write a fresh manifest.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
import time

import numpy as np

from catalog import ROOT, catalog
from authoring import OUT, TEX, create_textures, referenced_textures, write_usda
from models import build, airframe_parts


def command(args):
    p = subprocess.run(list(map(str, args)), capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(" ".join(map(str, args))+"\n"+p.stdout+p.stderr)
    return p.stdout+p.stderr


def geometry_check(m):
    assert m.parts, m.id
    for part in m.parts:
        pts = np.asarray(part["points"])
        faces = np.asarray(part["faces"])
        ns = np.asarray(part["normals"])
        assert np.isfinite(pts).all() and np.isfinite(ns).all(), (m.id, part["name"])
        assert faces.min() >= 0 and faces.max() < len(pts), (m.id, part["name"])
        assert np.all(np.linalg.norm(ns, axis=1) > .98), (m.id, part["name"], "zero normals")
        area = np.linalg.norm(np.cross(pts[faces[:, 1]]-pts[faces[:, 0]], pts[faces[:, 2]]-pts[faces[:, 0]]), axis=1)
        assert np.all(area > 1e-13), (m.id, part["name"], "degenerate faces")
        if "uv" in part:
            assert len(part["uv"]) == len(pts), (m.id, part["name"], "UV count")


def package(m):
    start = time.monotonic()
    geometry_check(m)
    source = OUT / "sources" / (m.id+".usda")
    model = OUT / "models" / (m.id+".usdz")
    write_usda(m, source)
    textures = referenced_textures(m)
    with tempfile.TemporaryDirectory(prefix="workbench-usdz-") as tmp:
        binary = Path(tmp) / (m.id+".usdc")
        command(["/usr/bin/usdcat", source, "-o", binary])
        (Path(tmp)/"textures").mkdir()
        for texture in textures:
            shutil.copy2(TEX/texture, Path(tmp)/"textures"/texture)
        command(["/usr/bin/usdzip", "--arkitAsset", binary, model])
    report = command(["/usr/bin/usdchecker", "--arkit", model])
    (OUT/"validation"/(m.id+".txt")).write_text(report)
    if "Success!" not in report or "Failed!" in report:
        raise RuntimeError(m.id+": ARKit validation did not confirm success\n"+report)
    lo, hi = m.bounds()
    row = dict(id=m.id, name=m.name, kind=m.spec["kind"], brand=m.spec.get("brand", "UAVSim"),
               file="models/"+model.name, source="sources/"+source.name,
               preview="previews/"+m.id+".png", catalog_size_m=m.spec["size"],
               bounds_min_m=lo, bounds_max_m=hi, bounds_size_m=[hi[i]-lo[i] for i in range(3)],
               mesh_count=len(m.parts), triangles=sum(len(p["faces"]) for p in m.parts),
               vertices=sum(len(p["points"]) for p in m.parts), textures=textures,
               groups=sorted({p["section"] for p in m.parts}), details=m.notes,
               bytes=model.stat().st_size, sha256=hashlib.sha256(model.read_bytes()).hexdigest(),
               arkit_validation="passed", metres_per_unit=1, up_axis="Y", forward_axis="+Z",
               authoring="Original representative geometry; catalog dimensions, not a measured commercial CAD replica.")
    if m.spec["kind"] in ("wing", "fuselage"):
        row["parent_frame_id"] = m.id.rsplit("-", 1)[0]
        row["retains_assembly_datum"] = True
    if m.spec["kind"] == "motor":
        row["shaft_axis"] = "+Y"
        row["mount_plane_y_m"] = 0
    elif m.spec["kind"] == "propeller":
        row["rotation_axis"] = "+Y"
        row["rotation_pivot_m"] = [0, 0, 0]
    print(f"{m.id}: {row['triangles']:,} triangles, {row['bytes']//1024:,} KiB; ARKit passed ({time.monotonic()-start:.1f}s)", flush=True)
    return row


def build_entry(spec):
    m = build(spec)
    rows = [package(m)]
    if spec["kind"] == "frame" and spec["architecture"] != "multicopter":
        rows.extend(package(p) for p in airframe_parts(m))
    return rows


def install(manifest):
    dest = ROOT / "DroneUAVDemo/Resources/Models/WorkbenchParts"
    dest.mkdir(parents=True, exist_ok=True)
    for row in manifest["models"]:
        shutil.copy2(OUT/row["file"], dest/Path(row["file"]).name)
    (dest/"manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only")
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--workers", type=int, default=3)
    args = parser.parse_args()
    for folder in ["models", "sources", "previews", "validation"]:
        (OUT/folder).mkdir(parents=True, exist_ok=True)
    if not (TEX/"texture-version.txt").exists() or (TEX/"texture-version.txt").read_text().strip() != "2":
        create_textures()
    specs = catalog()
    (OUT/"catalog-snapshot.json").write_text(json.dumps(specs, ensure_ascii=False, indent=2)+"\n")
    selected = [p for p in specs if not args.only or p["id"] == args.only]
    if not selected:
        raise SystemExit("Unknown catalog id: "+args.only)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = [r for result in pool.map(build_entry, selected) for r in result]
    path = OUT/"manifest.json"
    if args.only and path.exists():
        byid = {p["id"]: p for p in json.loads(path.read_text())["models"]}
        byid.update({p["id"]: p for p in rows})
        rows = list(byid.values())
    rows.sort(key=lambda p: (p["kind"], p["id"]))
    manifest = dict(schema_version=1, created="2026-10-08", generator="Tools/WorkbenchAssets/build.py",
                    catalog_components=sum(p["kind"] != "frame" for p in specs),
                    catalog_frames=sum(p["kind"] == "frame" for p in specs),
                    origin="Original geometry, original procedural PBR maps and original labels; no downloaded models or photographic textures.",
                    intended_use="Workbench component visualization. Physical properties and CAD engineering geometry remain in the project catalog.",
                    models=rows)
    if not args.only:
        required = {p["id"] for p in specs}
        required |= {p["id"]+"-"+role for p in specs if p["kind"] == "frame" and p["architecture"] != "multicopter" for role in ("wing", "fuselage")}
        assert {r["id"] for r in rows} == required, "Incomplete Workbench library"
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n")
    summary = dict(model_count=len(rows), arkit_passed=len(rows),
                   triangles=sum(r["triangles"] for r in rows), total_bytes=sum(r["bytes"] for r in rows),
                   normals_finite=True, indices_in_range=True, no_degenerate_triangles=True,
                   standalone_airframe_parts=[r["id"] for r in rows if r["kind"] in ("wing", "fuselage")])
    (OUT/"validation-summary.json").write_text(json.dumps(summary, indent=2)+"\n")
    if args.install:
        install(manifest)
    # Apple's USDZ packager leaves empty recovery directories beside its output.
    # Remove only empty directories created by this generator.
    for folder in (OUT/"models").glob("(A Document Being Saved By usdzip*)"):
        if folder.is_dir():
            try:
                folder.rmdir()
            except OSError:
                pass
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
