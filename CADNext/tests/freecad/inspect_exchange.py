# Runs inside FreeCADCmd. Reads what CADNext wrote, and writes what FreeCAD itself builds, so the
# C++ test can compare the two sides without trusting either reader alone.
#
#   CADNEXT_FREECAD_TASK   inspect-step | inspect-fcstd | build-step
#   CADNEXT_FREECAD_INPUT  file to inspect (inspect-*)
#   CADNEXT_FREECAD_OUTPUT STEP to write (build-step)
#   CADNEXT_FREECAD_REPORT JSON report path
#
# Lengths in the report are FreeCAD's own: millimetres.
import json
import os
import traceback

import FreeCAD
import Part

task = os.environ["CADNEXT_FREECAD_TASK"]
report_path = os.environ["CADNEXT_FREECAD_REPORT"]
report = {"task": task, "freecad": ".".join(FreeCAD.Version()[:3])}


def shape_summary(shape):
    box = shape.BoundBox
    return {
        "solids": len(shape.Solids),
        "volume": shape.Volume,
        "bbox": [box.XMin, box.YMin, box.ZMin, box.XMax, box.YMax, box.ZMax],
    }


try:
    if task == "inspect-step":
        path = os.environ["CADNEXT_FREECAD_INPUT"]
        # Geometry as FreeCAD's STEP reader sees the whole file.
        report["geometry"] = shape_summary(Part.read(path))
        # Structure as FreeCAD builds its document from the file.
        import Import

        doc = FreeCAD.newDocument("inspect")
        Import.insert(path, doc.Name)
        report["labels"] = sorted({o.Label for o in doc.Objects})
        report["types"] = sorted({o.TypeId for o in doc.Objects})
        report["objectCount"] = len(doc.Objects)
    elif task == "inspect-fcstd":
        path = os.environ["CADNEXT_FREECAD_INPUT"]
        doc = FreeCAD.openDocument(path)
        bodies = []
        for o in doc.Objects:
            if hasattr(o, "Shape") and not o.Shape.isNull() and o.Shape.Solids:
                entry = shape_summary(o.Shape)
                entry["label"] = o.Label
                entry["type"] = o.TypeId
                bodies.append(entry)
        report["bodies"] = bodies
    elif task == "build-step":
        # The same model the CADNext tests use, built with FreeCAD's own objects: a subassembly
        # «Узел» (App::Part) of a box and a turned cylinder, linked twice, plus a loose box.
        import Import

        doc = FreeCAD.newDocument("build")
        housing = doc.addObject("Part::Box", "Housing")
        housing.Label = "Корпус"
        housing.Length, housing.Width, housing.Height = 10, 20, 30
        shaft = doc.addObject("Part::Cylinder", "Shaft")
        shaft.Label = "Вал"
        shaft.Radius, shaft.Height = 5, 40
        shaft.Placement = FreeCAD.Placement(FreeCAD.Vector(0, 50, -20), FreeCAD.Rotation(FreeCAD.Vector(1, 0, 0), 90))
        unit = doc.addObject("App::Part", "Unit")
        unit.Label = "Узел"
        unit.addObject(housing)
        unit.addObject(shaft)
        first = doc.addObject("App::Link", "UnitA")
        first.Label = "Узел-1"
        first.LinkedObject = unit
        second = doc.addObject("App::Link", "UnitB")
        second.Label = "Узел-2"
        second.LinkedObject = unit
        second.Placement = FreeCAD.Placement(FreeCAD.Vector(100, 0, 0), FreeCAD.Rotation(FreeCAD.Vector(0, 0, 1), 30))
        loose = doc.addObject("App::Link", "HousingLoose")
        loose.Label = "Корпус-2"
        loose.LinkedObject = housing
        loose.Placement = FreeCAD.Placement(FreeCAD.Vector(0, 0, 200), FreeCAD.Rotation())
        top = doc.addObject("App::Part", "Product")
        top.Label = "Изделие"
        top.addObject(first)
        top.addObject(second)
        top.addObject(loose)
        unit.Visibility = False
        doc.recompute()
        Import.export([top], os.environ["CADNEXT_FREECAD_OUTPUT"])
        report["written"] = os.environ["CADNEXT_FREECAD_OUTPUT"]
        report["geometry"] = shape_summary(Part.read(os.environ["CADNEXT_FREECAD_OUTPUT"]))
    else:
        raise ValueError("unknown task " + task)
    report["ok"] = True
except Exception:
    report["ok"] = False
    report["error"] = traceback.format_exc()

with open(report_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, ensure_ascii=False)
