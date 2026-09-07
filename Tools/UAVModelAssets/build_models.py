"""Build all 55 cosmetic UAV assets using the system OpenUSD tools on macOS.

Usage: python3 Tools/UAVModelAssets/build_models.py [--only catalogue-id]
Authoring output is written to Assets/UAVModels. After validation, models and the
manifest are copied to the application's UAVModels folder; its loader maps rotor,
damage-component and VTOL hinge nodes.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import shutil
from airframes import build

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'Assets/UAVModels'

def command(args):
    r=subprocess.run(args,capture_output=True,text=True)
    if r.returncode:raise RuntimeError(' '.join(map(str,args))+'\n'+r.stdout+r.stderr)
    return r.stdout+r.stderr

def one(profile):
    ident=profile['id'];m=build(profile)
    out=OUT/'models'/f'{ident}.usdz';src=OUT/'sources'/f'{ident}.usda'
    provenance='Concept from project, no real product' if profile['kind']=='concept' else 'Representative FPV class, not a specific commercial product' if profile['kind']=='class' else 'Approximate exterior authored from public reference imagery; see reference-manifest.json'
    m.write(src,provenance)
    with tempfile.TemporaryDirectory(prefix='uav-usdz-') as tmp:
        binary=Path(tmp)/f'{ident}.usdc'
        command(['/usr/bin/usdcat',str(src),'-o',str(binary)])
        shutil.copytree(OUT/'sources/textures',Path(tmp)/'textures')
        command(['/usr/bin/usdzip','--arkitAsset',str(binary),str(out)])
    report=command(['/usr/bin/usdchecker','--arkit',str(out)])
    (OUT/'validation'/f'{ident}.txt').write_text(report)
    low,high=m.bounds()
    row=dict(id=ident,name=profile['name'],kind=profile['kind'],file=f'models/{ident}.usdz',source=f'sources/{ident}.usda',
        preview=f'previews/{ident}.png',metres_per_unit=1,up_axis='Y',forward_axis='+Z',
        bounds_min_m=low,bounds_max_m=high,bounds_size_m=[high[i]-low[i] for i in range(3)],
        catalogue_dimensions=profile['dimensions'],geometry_accuracy='approximate exterior; not a measured CAD replica',
        scale_note='Published catalogue dimensions anchor the model where available. Rotor envelopes and small details are estimated. Entries with no catalogue dimensions use a nominal visual scale.',
        mesh_count=len(m.parts),triangles=sum(len(p['faces']) for p in m.parts),rotors=m.rotors,geometry_sha256=m.fingerprint(),
        transition=m.transition,
        animation=dict(embedded=bool(m.rotors),duration_seconds=12 if m.transition else 2,time_codes_per_second=60,samples_per_rotor=721 if m.transition else 121,preview_rpm=120,
            note='Cyclic display animation; rpm is deliberately slowed for inspection. Jet aircraft without external propellers have no rotor animation.'),
        rotor_paths=[f'/Aircraft/Geometry/'+(r['pivot']+'/' if r.get('pivot') else '')+r['name'] for r in m.rotors],
        texture_provenance='Original procedural surface patterns and original text decals; no reference photograph is embedded.',
        validation_note='Native usdchecker reports Success. Its macOS distribution may additionally emit a duplicate UsdShade behavior registration diagnostic; full raw output is retained.',
        bytes=out.stat().st_size,sha256=hashlib.sha256(out.read_bytes()).hexdigest(),arkit_validation='passed')
    print(f'{ident}: {row["triangles"]} triangles, {row["bytes"]//1024} KiB; ARKit passed',flush=True)
    return row

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--only');args=parser.parse_args()
    for folder in ['models','sources','previews','validation']:(OUT/folder).mkdir(parents=True,exist_ok=True)
    profiles=json.loads((ROOT/'Tools/UAVModelAssets/catalog_snapshot.json').read_text())
    selected=[p for p in profiles if not args.only or p['id']==args.only]
    if not selected:raise SystemExit('Unknown catalogue ID')
    with ThreadPoolExecutor(max_workers=4) as pool:rows=list(pool.map(one,selected))
    manifest=OUT/'manifest.json'
    if args.only and manifest.exists():
        old=json.loads(manifest.read_text());byid={r['id']:r for r in old['models']}
        byid.update({r['id']:r for r in rows});rows=[byid[p['id']] for p in profiles if p['id'] in byid]
    manifest.write_text(json.dumps(dict(schema_version=3,date='2026-09-07',generator='Tools/UAVModelAssets/build_models.py',
        intended_use='Exterior visualization in USD-aware viewers; not manufacturing, photogrammetry or flight-dynamics geometry.',
        models=rows),ensure_ascii=False,indent=2)+'\n')
