"""Broad-phase support audit; flags isolated mesh clusters for visual review.

An AABB connection is only a candidate contact, never proof of solid contact.
Independent kits and moving/control surfaces are explicitly reported. Label
surface projection and aperture area checks are exact authoring constraints.
"""
from collections import Counter
import json
import numpy as np
from catalog import catalog
from models import build
from authoring import OUT


def clusters(asset):
    bounds = [(np.min(p["points"], axis=0), np.max(p["points"], axis=0)) for p in asset.parts]
    low, high = np.asarray([b[0] for b in bounds]), np.asarray([b[1] for b in bounds])
    gap = np.maximum(0, np.maximum(low[:, None, :]-high[None, :, :], low[None, :, :]-high[:, None, :]))
    candidates = np.max(gap, axis=2) <= .000055
    remaining = set(range(len(bounds)))
    groups = []
    while remaining:
        seed = remaining.pop()
        group, queue = {seed}, [seed]
        while queue:
            neighbors = set(np.flatnonzero(candidates[queue.pop()])) & remaining
            remaining -= neighbors
            group |= neighbors
            queue.extend(neighbors)
        groups.append(sorted(group))
    groups.sort(key=len, reverse=True)
    return [[asset.parts[i]["name"] for i in g] for g in groups]


rows = []
for spec in catalog():
    asset = build(spec)
    groups = clusters(asset)
    labels = [p for p in asset.parts if p["material"].startswith("label_")]
    row = dict(id=asset.id, candidate_clusters=len(groups), isolated_clusters=groups[1:],
               attached_labels=[dict(mesh=p["name"], host=p["attached_to"], clearance_m=p["attachment_clearance_m"]) for p in labels])
    rows.append(row)
    if len(groups) > 1:
        print(asset.id, "clusters", len(groups), "isolated", groups[1:])
path = OUT/"support-audit.json"
path.write_text(json.dumps(dict(method="55-micron AABB adjacency: broad-phase review aid, not proof of physical contact", models=rows), indent=2)+"\n")
print("Catalog support audit:", dict(Counter(r["candidate_clusters"] for r in rows)))
independent_kits = {"gear-skid": 2, "gear-tall-carbon": 2, "gear-retractable": 2, "gear-cine-bumpers": 4}
unexpected = [r["id"] for r in rows if r["candidate_clusters"] != independent_kits.get(r["id"], 1)]
if unexpected:
    raise SystemExit("Unsupported clusters need inspection: "+", ".join(unexpected))
print("PASS: no unexpected isolated clusters; four independent landing-gear kits explicitly accounted for.")
