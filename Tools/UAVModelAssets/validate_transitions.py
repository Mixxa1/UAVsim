"""Check native motor/rotor hierarchy and physical contact throughout transition."""
import copy, hashlib, json, math
from pathlib import Path
import numpy as np
from airframes import build
from check_connections import audit
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'Assets/UAVModels'

def rotate(axis,deg):
 a=math.radians(deg);c=math.cos(a);s=math.sin(a)
 if axis=='x':return np.array([[1,0,0],[0,c,-s],[0,s,c]])
 if axis=='y':return np.array([[c,0,s],[0,1,0],[-s,0,c]])
 return np.array([[c,-s,0],[s,c,0],[0,0,1]])
def matrix(r=np.eye(3),t=np.zeros(3)):
 a=np.eye(4);a[:3,:3]=r;a[:3,3]=t;return a

def pose(m,fraction):
 result=copy.deepcopy(m);rotors={r['name']:r for r in m.rotors}
 pivots={p['name']:p for p in m.pivots}
 for p in result.parts:
  pivot=pivots.get(p.get('pivot') or rotors.get(p['group'],{}).get('pivot'))
  if m.transition['mechanism']=='tailsitter':center=np.zeros(3);angle=-90*(1-fraction)
  elif pivot:center=np.array(pivot['center']);angle=pivot['hover_degrees']+(pivot['cruise_degrees']-pivot['hover_degrees'])*fraction
  else:continue
  rot=rotate('x',angle)
  p['points']=((np.array(p['points'])-center)@rot.T+center).tolist()
  p['normals']=(np.array(p['normals'])@rot.T).tolist()
 return result

def main():
 profiles=json.loads((ROOT/'Tools/UAVModelAssets/catalog_snapshot.json').read_text())
 manifest={r['id']:r for r in json.loads((OUT/'manifest.json').read_text())['models']}
 native={r['id']:r for r in json.loads((OUT/'previews/scenekit-validation.json').read_text())}
 rows=[]
 for profile in profiles:
  row=manifest[profile['id']]
  if not row.get('transition'):continue
  m=build(profile);n=native[m.id]
  assert n['asset_sha256']==row['sha256']
  bytime={}
  for sample in n['transition_poses']:bytime.setdefault(sample['time'],{})[sample['node']]=sample['world_transform']
  assert set(bytime)=={0,2.75,3.5,4.25,6,8.5,12}
  counts=0;contacts=[]
  for t,samples in bytime.items():
   fraction=m.transition_fraction(t);body=matrix(rotate('x',-90*(1-fraction))) if m.transition['mechanism']=='tailsitter' else np.eye(4)
   transforms={'Geometry':body};pivot_by_name={}
   for pivot in m.pivots:
    angle=pivot['hover_degrees']+(pivot['cruise_degrees']-pivot['hover_degrees'])*fraction
    pm=matrix(rotate('x',angle),np.array(pivot['center']));transforms[pivot['name']]=pm;pivot_by_name[pivot['name']]=pivot
   for rotor in m.rotors:
    parent=transforms.get(rotor.get('pivot'),body)
    center=np.array(rotor['center'])-np.array(pivot_by_name[rotor['pivot']]['center']) if rotor.get('pivot') else np.array(rotor['center'])
    transforms[rotor['name']]=parent@matrix(rotate(rotor['axis'],m.rotor_angle(rotor,t)),center)
   for part in m.parts:transforms[part['name']]=transforms.get(part['group'] or part.get('pivot'),body)
   for name,expected in transforms.items():
    if name=='Geometry' and m.transition['mechanism']!='tailsitter':continue
    assert name in samples,(m.id,t,'missing',name)
    actual=np.eye(4);actual[:3,:]=np.array(samples[name]).reshape(4,3).T
    assert np.max(abs(actual-expected))<.0003,(m.id,t,name,np.max(abs(actual-expected)))
    counts+=1
   if t<=6:
    cr=audit(profile,pose(m,fraction))
    assert cr['component_count']==1,(m.id,t,cr['islands'])
    assert all(r['stationary_contacts'] for r in cr['rotor_bearings']),(m.id,t,'loose hub')
    contacts.append(dict(time=t,fraction=fraction,connected_components=cr['component_count'],supported_hubs=len(cr['rotor_bearings'])))
  rows.append(dict(id=m.id,sha256=row['sha256'],mechanism=m.transition['mechanism'],moving_motor_assemblies=len(m.pivots),native_transforms_checked=counts,contact_samples=contacts,closed_loop=True))
 report=dict(status='passed',models=rows,preview_note='Illustrative 12-second loop, not real flight timing. No flight-control thresholds are encoded in USDZ.')
 (OUT/'transition-validation.json').write_text(json.dumps(report,indent=2)+'\n')
 print('PASS: three VTOL mechanisms, rigid motor/rotor motion and connected geometry at intermediate poses.')
if __name__=='__main__':main()
