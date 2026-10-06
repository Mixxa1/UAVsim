"""Validate the exact delivered packages against native imported animation poses."""
import hashlib
import json
import math
from pathlib import Path
import struct
import zipfile
from expansion_catalog import CATALOG

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'Assets/UAVModels-Expansion'


def validate():
    models=json.loads((OUT/'manifest.json').read_text())['models']
    native={r['id']:r for r in json.loads((OUT/'previews/scenekit-validation.json').read_text())}
    contacts={r['id']:r for r in json.loads((OUT/'connection-audit.json').read_text())['models']}
    ids={p['id'] for p in CATALOG}
    assert len(models)==30 and {p['id'] for p in models}==ids==set(native)==set(contacts)
    assert len({m['geometry_sha256'] for m in models})==30,'Duplicate authored geometry'
    original={p['id'] for p in json.loads((ROOT/'Tools/UAVModelAssets/catalog_snapshot.json').read_text())}
    assert not ids & original,'Expansion repeats an original aircraft ID'
    reports=[]
    for model in models:
        ident=model['id'];path=OUT/model['file'];raw=path.read_bytes();nr=native[ident];cr=contacts[ident]
        sha=hashlib.sha256(raw).hexdigest()
        assert sha==model['sha256']==nr['asset_sha256'],f'Stale native preview: {ident}'
        assert hashlib.sha256((OUT/model['source']).read_bytes()).hexdigest()==model['source_sha256']
        assert cr['geometry_sha256']==model['geometry_sha256'],f'Stale attachment audit: {ident}'
        assert cr['component_count']==1 and not cr['islands'],f'Detached exterior detail: {ident}'
        assert all(b['stationary_contacts'] for b in cr['rotor_bearings']),f'Unsupported rotor hub: {ident}'
        with zipfile.ZipFile(path) as package:
            assert package.testzip() is None
            assert package.infolist()[0].filename.endswith('.usdc')
            names=set(package.namelist())
            # --arkitAsset localizes dependencies (for example to 0/carbon.png).
            # Validate the embedded payload, not an assumed directory prefix.
            for name in model['textures']:
                matches=[n for n in names if Path(n).name==name]
                assert len(matches)==1,f'Missing/ambiguous embedded texture: {ident}/{name}'
                assert package.read(matches[0])==(OUT/'sources/textures'/name).read_bytes(),f'Texture differs from source: {ident}/{name}'
            for item in package.infolist():
                assert item.compress_type==zipfile.ZIP_STORED
                assert not item.filename.startswith('/') and '..' not in Path(item.filename).parts
                name_length,extra_length=struct.unpack_from('<HH',raw,item.header_offset+26)
                assert (item.header_offset+30+name_length+extra_length)%64==0,f'USDZ 64-byte alignment: {ident}'
        assert nr['scenekit_geometry_count']==model['mesh_count']
        expected={r['name'] for r in model['rotors']}|{r['name'] for r in model['rigs']}
        if model['transition'] and model['transition']['mechanism']=='tailsitter':expected.add('Geometry')
        assert expected and expected=={a['node'] for a in nr['animated_nodes']},f'Missing imported animation: {ident}'
        cycle=model['animation']['duration_seconds']
        poses={name:{} for name in expected}
        for pose in nr['animation_poses']:poses[pose['node']][pose['time']]=pose['transform']
        for name, samples in poses.items():
            start,end=samples[0],samples[cycle]
            assert all(math.isfinite(v) for p in samples.values() for v in p)
            assert max(abs(start[i]-end[i]) for i in range(12))<1e-4,f'Open animation loop: {ident}/{name}'
            assert max(abs(start[i]-p[i]) for p in samples.values() for i in range(9))>.01,f'Static animation: {ident}/{name}'
            assert max(abs(start[i]-p[i]) for p in samples.values() for i in range(9,12))<1e-5,f'Pivot drifts: {ident}/{name}'
        for rotor in model['rotors']:
            samples=poses[rotor['name']]
            for mat in samples.values():
                assert max(abs(mat[9+i]-rotor['center'][i]) for i in range(3))<1e-5
                axis=1 if rotor['axis']=='y' else 2
                assert max(abs(mat[axis*3+i]-(1 if i==axis else 0)) for i in range(3))<1e-4
            if rotor['axis']=='y':
                for peer in model['rotors']:
                    if peer['axis']=='y' and rotor['center'][0]*peer['center'][0]<0 and rotor['center'][2]*peer['center'][2]<0:
                        assert rotor['direction']==peer['direction'],'Incorrect diagonal rotor directions'
        for suffix in ('','-top','-side','-front','-underside','-animated'):
            ext='.gif' if suffix=='-animated' else '.png'
            assert (OUT/'previews'/(ident+suffix+ext)).stat().st_size>1000
        assert 'Success!' in (OUT/'validation'/(ident+'.txt')).read_text()
        reports.append(dict(id=ident,sha256=sha,arkit='passed',self_contained_usdz='passed',
            alignment_64_bytes='passed',native_import='passed',animated_nodes=len(expected),
            motion='passed',pivots='passed',loop='passed',attachments='passed'))
    result=dict(status='passed',models=30,winged_models=sum(m['category']!='multicopter' for m in models),
                animated_models=30,animated_nodes=sum(r['animated_nodes'] for r in reports),
                meshes=sum(m['mesh_count'] for m in models),triangles=sum(m['triangles'] for m in models),
                note='Compatibility, attachments and animation are verified; exterior metrology remains approximate.',
                models_checked=reports)
    (OUT/'validation-summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(f'PASS: 30 distinct USDZ; 30 native animated imports; {result["animated_nodes"]} moving nodes; closed cycles, stationary pivots and connected exterior meshes.')
    return result


if __name__=='__main__':validate()
