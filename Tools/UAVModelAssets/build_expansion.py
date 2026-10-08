"""Build the additional, self-contained USDZ files.

Uses macOS /usr/bin/usdcat, usdzip and usdchecker, plus Pillow for original
surface patterns and original typographic labels. Run with a Pillow-enabled
Python; --only accepts comma-separated model IDs for an incremental rebuild.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

from expansion_catalog import CATALOG, DATE
from expansion_airframes import build, TEXTURES

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'Assets/UAVModels-Expansion'


def command(args):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(' '.join(map(str,args))+'\n'+result.stdout+result.stderr)
    return result.stdout+result.stderr


def textures():
    from PIL import Image, ImageDraw, ImageFont
    import random
    path=OUT/'sources/textures'
    path.mkdir(parents=True, exist_ok=True)
    rng=random.Random(20261006)
    image=Image.new('RGB',(512,512))
    pix=image.load()
    for y in range(512):
        for x in range(512):
            warp=((x//16+y//16)%2)==0
            stripe=(x%16 if warp else y%16)
            lum=int(27+12*sin_lobe(stripe/16)+rng.randrange(4))
            pix[x,y]=(lum,lum+2,lum+3)
    image.save(path/'carbon.png')
    for name,base in [('epp-black',(45,47,46)),('epp-gray',(186,188,184))]:
        image=Image.new('RGB',(512,512),base);d=ImageDraw.Draw(image)
        for _ in range(6500):
            x,y=rng.randrange(512),rng.randrange(512);r=rng.randrange(1,4);delta=rng.randrange(-12,13)
            col=tuple(max(0,min(255,v+delta)) for v in base)
            d.ellipse((x-r,y-r,x+r,y+r),fill=col)
        image.save(path/(name+'.png'))
    font_path='/System/Library/Fonts/Supplemental/Arial.ttf'
    bold_path='/System/Library/Fonts/Supplemental/Arial Bold.ttf'
    for p in CATALOG:
        for suffix in ('','-right','-left'):
            ident=p['id']+suffix
            text=p['name']
            if p['id']=='wingtra-ray':
                text='wingtra' if suffix=='-left' else 'RAY'
            elif suffix=='-right':
                text=p['name'].split()[-1]
            color=(20,23,24,255) if p['shape'].get('paint') not in ('epp_black',) else (227,229,222,255)
            image=Image.new('RGBA',(1024,256));d=ImageDraw.Draw(image)
            size=120
            font=ImageFont.truetype(bold_path if Path(bold_path).exists() else font_path,size)
            while d.textbbox((0,0),text,font=font)[2]>970:
                size-=3;font=ImageFont.truetype(font_path,size)
            box=d.textbbox((0,0),text,font=font)
            d.text(((1024-box[2])/2,(256-(box[3]-box[1]))/2-box[1]),text,font=font,fill=color)
            image.save(path/(ident+'.png'))


def sin_lobe(x):
    return math.sin(x*math.pi)**2


def one(profile):
    ident=profile['id'];m=build(profile)
    # Catch non-finite geometry before passing the file to native parsers.
    assert m.parts and m.rotors
    for part in m.parts:
        assert all(math.isfinite(v) for point in part['points'] for v in point), part['name']
        assert all(math.isfinite(v) for normal in part['normals'] for v in normal),part['name']
        assert all(0<=i<len(part['points']) for face in part['faces'] for i in face),part['name']
    source=OUT/'sources'/f'{ident}.usda'
    asset=OUT/'models'/f'{ident}.usdz'
    provenance=f"Public exterior references checked {DATE}; {profile['source_url']}; cosmetic reconstruction; unpublished dimensions estimated."
    m.write(source,provenance)
    text=source.read_text()
    # LED emitters are actual PreviewSurface inputs; every other PBR material is
    # the inherited, portable USD PreviewSurface graph.
    for material in ('led_green','led_red'):
        token=f'        def Material "{material}"'
        if token in text:
            start=text.index(token);end=text.index('                token outputs:surface',start)
            emissive='(0.08, 0.8, 0.28)' if material=='led_green' else '(0.9, 0.05, 0.01)'
            text=text[:end]+f'                color3f inputs:emissiveColor = {emissive}\n'+text[end:]
    source.write_text(text)
    with tempfile.TemporaryDirectory(prefix='uav-expansion-') as temp:
        folder=Path(temp);binary=folder/(ident+'.usdc')
        command(['/usr/bin/usdcat',source,'-o',binary])
        used=sorted({TEXTURES[p['material']][0] for p in m.parts if p['material'] in TEXTURES})
        if used:
            (folder/'textures').mkdir()
            for filename in used:
                shutil.copy2(OUT/'sources/textures'/filename,folder/'textures'/filename)
        command(['/usr/bin/usdzip','--arkitAsset',binary,asset])
    output=command(['/usr/bin/usdchecker','--arkit',asset])
    assert 'Success!' in output,output
    (OUT/'validation'/(ident+'.txt')).write_text(output)
    low,high=m.bounds()
    row=dict(id=ident,name=profile['name'],category=profile['category'],layout=profile['layout'],
             file=f'models/{ident}.usdz',source=f'sources/{ident}.usda',preview=f'previews/{ident}.png',
             source_url=profile['source_url'],published_dimensions=profile['published'],
             meters_per_unit=1,up_axis='Y',forward_axis='+Z',
             static_bounds_min_m=low,static_bounds_max_m=high,
             static_bounds_size_m=[high[i]-low[i] for i in range(3)],
             wingspan_m=profile.get('wingspan_m'),nominal_length_m=profile.get('length_m'),
             accuracy='Original approximate exterior reconstruction from public images; not measured CAD or photogrammetry.',
             dimension_note='Only the values named in published_dimensions are sourced measurements. Skin curvature, small hardware, propeller envelopes and unlisted dimensions are estimated. Static bounds depend on blade pose.',
             mesh_count=len(m.parts),triangles=sum(len(p['faces']) for p in m.parts),
             material_count=len({p['material'] for p in m.parts}),textures=used,
             rotors=m.rotors,rotor_paths=['/Aircraft/Geometry/'+r['name'] for r in m.rotors],
             rigs=m.rigs,transition=m.transition,mechanics=m.mechanics,
             animation=dict(duration_seconds=12 if m.transition else 2,time_codes_per_second=60,
                            samples_per_rotor=721 if m.transition else 121,
                            preview_rpm=120,animated_rotors=len(m.rotors),
                            note='Cyclic inspection animation. In a simulator, disable imported animation and drive the named rotor pivots.'),
             body_pose='WingtraRAY has an embedded hover/cruise/hover attitude cycle; other bodies are horizontal.',
             geometry_sha256=m.fingerprint(),sha256=hashlib.sha256(asset.read_bytes()).hexdigest(),
             source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
             bytes=asset.stat().st_size,arkit_validation='passed')
    print(f'{ident}: {row["mesh_count"]} meshes, {row["triangles"]} triangles, {row["bytes"]//1024} KiB; ARKit passed',flush=True)
    return row


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--only');parser.add_argument('--workers',type=int,default=4)
    args=parser.parse_args()
    for name in ('sources','models','validation','previews'):
        (OUT/name).mkdir(parents=True,exist_ok=True)
    textures()
    selected=[p for p in CATALOG if not args.only or p['id'] in args.only.split(',')]
    if not selected:raise SystemExit('Unknown model ID')
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        rows=list(pool.map(one,selected))
    manifest=OUT/'manifest.json'
    if args.only and manifest.exists():
        byid={r['id']:r for r in json.loads(manifest.read_text())['models']}
        byid.update({r['id']:r for r in rows})
        rows=[byid[p['id']] for p in CATALOG if p['id'] in byid]
    manifest.write_text(json.dumps(dict(schema_version=1,date=DATE,
        generator='Tools/UAVModelAssets/build_expansion.py',models=rows),ensure_ascii=False,indent=2)+'\n')
    (OUT/'reference-manifest.json').write_text(json.dumps(dict(checked_on=DATE,
        method='Manufacturer pages and brochures, manuals, and supplementary exterior imagery. Photographs are not embedded in the models.',
        references=CATALOG),ensure_ascii=False,indent=2)+'\n')
