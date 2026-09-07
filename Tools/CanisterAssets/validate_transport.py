"""Asset consistency and native visual-scene transforms; no operational fit claim."""
import json,hashlib
from transport import truck,assembled,VEHICLES,CONFIGS,build_module,transform_module
from build import cover_angle,rotate_x,ROOT,OUT
from geometry import sub
manifest=json.loads((VEHICLES/'manifest.json').read_text())
native=json.loads((VEHICLES/'previews/native-validation.json').read_text())
audit=json.loads((VEHICLES/'connection-audit.json').read_text())
for row in manifest['models']:
 modern=row['photo_variant']=='cabover';loaded=row['loaded']
 m=assembled(modern) if loaded else truck(modern)
 n=next(n for n in native if n['id']==row['id'])
 assert n['sha256']==row['sha256']==hashlib.sha256((VEHICLES/row['file']).read_bytes()).hexdigest()
 assert n['mesh_count']==row['mesh_count']==len(m.parts)
 assert n['animated_covers']==(9 if modern and loaded else 0)
 states=[a for a in audit['models'] if a['id']==row['id']]
 assert len(states)==(3 if modern and loaded else 1)
 assert all(a['component_count']==1 and not a['islands'] for a in states)
 assert states[0]['geometry_sha256']==m.fingerprint()
 if modern and loaded:
  hinges={p['cover']:p['hinge'] for p in build_module(CONFIGS[1]).parts if 'cover' in p}
  ry=lambda v:(v[2],v[1],-v[0])
  assert len(n['cover_poses'])==45
  for pose in n['cover_poses']:
   h=hinges[pose['node']];angle=-cover_angle(pose['time']);rh=rotate_x(h,angle)
   columns=[ry(rotate_x(b,angle))+(0,) for b in [(1,0,0),(0,1,0),(0,0,1)]]
   columns+=[transform_module(sub(h,rh),True,m.deckY)+(1,)]
   assert max(abs(a-b) for a,b in zip([v for c in columns for v in c],pose['matrix']))<.001
 print(row['id'],': native hashes, meshes, connected assembly and covers passed')

# Report the present visual assets only. None contains a stored-airframe pose.
aircraft=json.loads((ROOT/'Assets/UAVModels/manifest.json').read_text())['models'];rows=[]
for ident,config in [('iai-harpy',CONFIGS[0]),('iai-harop',CONFIGS[1]),('iai-harpy-ng',CONFIGS[1])]:
 a=next(a for a in aircraft if a['id']==ident)
 actual=ROOT/'Assets/UAVModels'/a['file'];assert hashlib.sha256(actual.read_bytes()).hexdigest()==a['sha256']
 clear=[config['w']-.084,config['h']-.084,config['L']-.078]
 size=a['bounds_size_m']
 rows.append(dict(aircraft=ident,aircraft_sha256=a['sha256'],aircraft_default_pose_size_m=size,container_candidate=config['id'],nominal_empty_interior_size_m=clear,current_flight_pose_fits=False,reason='Unfolded wing mesh is wider than the interior; aircraft height also exceeds the nominal interior. No stored-pose mesh is authored.',stored_pose_fit='not_verified',mapping_confirmed=ident!='iai-harpy-ng'))
(VEHICLES/'visual-scale-audit.json').write_text(json.dumps(dict(scope='Existing digital meshes at their authored 1 m/unit scene scale; not physical launcher compatibility',aircraft=rows),ensure_ascii=False,indent=2)+'\n')
(OUT/'visual-scale-audit.json').write_text((VEHICLES/'visual-scale-audit.json').read_text())
print('Current aircraft mesh dimensions and file hashes recorded; all three flight poses do not fit')
