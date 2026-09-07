"""Check the native import against the authored cover pivots and sealed assets."""
import json,hashlib,copy
from build import build,CONFIGS,OUT,rotate_x,cover_angle
from geometry import add,sub
manifest=json.loads((OUT/'manifest.json').read_text())
native=json.loads((OUT/'previews/native-validation.json').read_text())
audit=json.loads((OUT/'connection-audit.json').read_text())
for c in CONFIGS:
 m=build(c);expected={p['cover']:p['hinge'] for p in m.parts if 'cover' in p}
 n=next(n for n in native if n['id']==m.id);record=next(n for n in manifest['models'] if n['id']==m.id)
 assert n['sha256']==record['sha256']==hashlib.sha256((OUT/record['file']).read_bytes()).hexdigest()
 assert record['geometry_sha256']==m.fingerprint()
 assert n['mesh_count']==len(m.parts) and n['animated_covers']==len(expected)
 assert len(n['cover_poses'])==len(expected)*5
 for pose in n['cover_poses']:
  h=expected[pose['node']];angle=-cover_angle(pose['time']);rh=rotate_x(h,angle)
  columns=[rotate_x(b,angle)+(0,) for b in [(1,0,0),(0,1,0),(0,0,1)]]+[tuple(h[k]-rh[k] for k in range(3))+(1,)]
  assert max(abs(x-y) for x,y in zip([v for col in columns for v in col],pose['matrix']))<.001
 states=[r for r in audit['models'] if r['id']==m.id]
 assert len(states)==(3 if expected else 1)
 assert all(r['component_count']==1 and not r['islands'] for r in states)
 for state in states:
  posed=copy.deepcopy(m)
  for p in posed.parts:
   if 'cover' in p:p['points']=[add(p['hinge'],rotate_x(sub(v,p['hinge']),-state['cover_angle'])) for v in p['points']]
  assert state['geometry_sha256']==posed.fingerprint()
 print(m.id,': asset hash, native geometry, cover poses and contacts passed')
