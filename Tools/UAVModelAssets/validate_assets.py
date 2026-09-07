"""Verify packaging and native imported motion of the exact delivered assets."""
from pathlib import Path
import json,hashlib,zipfile,struct,math
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'Assets/UAVModels'
manifest=json.loads((OUT/'manifest.json').read_text())['models']
profiles=json.loads((ROOT/'Tools/UAVModelAssets/catalog_snapshot.json').read_text())
native={r['id']:r for r in json.loads((OUT/'previews/scenekit-validation.json').read_text())}
connections={r['id']:r for r in json.loads((OUT/'connection-audit.json').read_text())['models']}
assert len(manifest)==55 and {r['id'] for r in manifest}=={r['id'] for r in profiles}
assert set(connections)=={r['id'] for r in profiles}
rows=[]
for m in manifest:
 ident=m['id'];p=OUT/m['file'];raw=p.read_bytes();sha=hashlib.sha256(raw).hexdigest()
 assert sha==m['sha256']==native[ident]['asset_sha256'],f'Stale native render: {ident}'
 cr=connections[ident]
 assert cr['geometry_sha256']==m['geometry_sha256'],f'Stale contact audit: {ident}'
 assert cr['component_count']==1 and not cr['islands'],f'Detached geometry: {ident}'
 assert all(j['attached_to'] for j in cr['joints']),f'Unsupported mounting point: {ident}'
 assert all(b['stationary_contacts'] for b in cr['rotor_bearings']),f'Floating hub: {ident}'
 for r in m['rotors']:
  if r['axis']!='y':continue
  for s in m['rotors']:
   if s is r or s['axis']!='y':continue
   if abs(r['center'][0]-s['center'][0])+abs(r['center'][2]-s['center'][2])<1e-7:
    assert r['direction']==-s['direction'],f'Coaxial directions: {ident}'
 if ident in ['everdrone-first-on-scene','wildfire-ember-40','pyrolift-talon-60','colossus-ca12-atlas']:
  stations=sorted(set((round(r['center'][0],7),round(r['center'][2],7)) for r in m['rotors']))
  assert len(stations)==6
  for x,z in stations:
   assert (-x,z) in stations and (x,-z) in stations,f'Asymmetric hex frame: {ident}'
  angles=sorted(math.atan2(z,x) for x,z in stations)
  steps=[(angles[(i+1)%6]-angles[i])%(2*math.pi) for i in range(6)]
  assert max(abs(a-math.pi/3) for a in steps)<1e-6,f'Uneven hex spacing: {ident}'
 if ident=='wingcopter-198':
  assert len({(round(r['center'][0],6),round(r['center'][2],6)) for r in m['rotors']})==8
 with zipfile.ZipFile(p) as z:
  assert z.testzip() is None
  assert z.infolist()[0].filename.endswith('.usdc')
  for f in z.infolist():
   assert f.compress_type==zipfile.ZIP_STORED
   assert not f.filename.startswith('/') and '..' not in Path(f.filename).parts
   h=raw[f.header_offset:f.header_offset+30]
   namelen,extralen=struct.unpack_from('<HH',h,26)
   assert (f.header_offset+30+namelen+extralen)%64==0,f'USDZ alignment: {ident}/{f.filename}'
 nr=native[ident]
 assert nr['scenekit_geometry_count']==m['mesh_count']
 expected={r['name'] for r in m['rotors']}
 transition=m.get('transition');cycle=12 if transition else 2
 rig_nodes={p['name'] for p in transition['pivots']} if transition else set()
 if transition and transition['mechanism']=='tailsitter':rig_nodes.add('Geometry')
 assert {a['node'] for a in nr['animated_nodes']}==expected|rig_nodes,f'Unexpected animated node: {ident}'
 for rotor in m['rotors']:
  poses={round(p['time'],3):p['transform'] for p in nr['animation_poses'] if p['node']==rotor['name']}
  assert set(poses)=={0,.037,cycle}
  parent=next((p for p in (transition or {}).get('pivots',[]) if p['name']==rotor.get('pivot')),None)
  center=[rotor['center'][k]-(parent['center'][k] if parent else 0) for k in range(3)]
  for t,mat in poses.items():
   assert all(math.isfinite(v) for v in mat)
   assert max(abs(mat[9+k]-center[k]) for k in range(3))<1e-5,f'Orbiting rotor: {ident}'
  assert max(abs(poses[0][k]-poses[.037][k]) for k in range(9))>.1,f'Static rotor: {ident}'
  assert max(abs(poses[0][k]-poses[cycle][k]) for k in range(12))<1e-4,f'Open animation loop: {ident}'
  # A rotation leaves its own unit axis unchanged.
  idx=1 if rotor['axis']=='y' else 2
  assert max(abs(poses[.037][idx*3+k]-(1 if k==idx else 0)) for k in range(3))<1e-4
 for suffix in ['', '-top','-front','-side','-underside','-motion']:
  assert (OUT/'previews'/(ident+suffix+'.png')).stat().st_size>1000
 assert 'Success!' in (OUT/'validation'/(ident+'.txt')).read_text()
 rows.append(dict(id=ident,sha256=sha,archive_crc='passed',usdz_alignment_64_bytes='passed',native_import='passed',
  animated_rotors=len(expected),rotor_axes='passed',rotor_centers_stationary='passed',cycle_closes='passed',connected_geometry='passed',supported_mounts=len(cr['joints']),supported_rotor_hubs=len(cr['rotor_bearings']),views=5))
neo=next(m for m in manifest if m['id']=='dji-neo')
assert max(abs(neo['bounds_size_m'][i]-[.157,.0485,.130][i]) for i in range(3))<1e-5
report=dict(status='passed',models=len(rows),animated_models=sum(bool(m['rotors']) for m in manifest),
 animated_rotors=sum(len(m['rotors']) for m in manifest),
 connected_models=len(rows),unsupported_components=0,hex_frame_symmetry='passed',coaxial_counterrotation='passed',
 note='Checks establish file compatibility and native animation, not metrology or identity of visually estimated details.',models_checked=rows)
(OUT/'validation-summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(f'PASS: {len(rows)} USDZ files; {report["animated_rotors"]} spinning rotors across {report["animated_models"]} models; stationary pivots, correct axes, closed loops, exact-asset native renders.')
