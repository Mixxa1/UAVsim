"""Photograph-derived exterior scene props, with cosmetic opening covers."""
import sys,json,hashlib,subprocess,tempfile
from pathlib import Path
from math import sin,cos,pi
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tools/UAVModelAssets'))
from geometry import Model,COLORS,add,sub,tup
OUT=ROOT/'Assets/CanisterModels'
COLORS.update(canister_olive=('#66705a',.77,.12),canister_sand=('#989779',.8,.08),canister_liner=('#b9baac',.81,.02),canister_edge=('#89917e',.58,.28),camo_dark=('#3d4840',.83,.03),camo_green=('#708956',.82,.03))
CONFIGS=[dict(id='iai-harpy-legacy-three-canister',name='HARPY · старый трёхконтейнерный блок',cols=1,rows=3,w=1.62,h=.43,L=2.85,paint='canister_sand',angle=17),dict(id='iai-harop-nine-canister',name='HAROP · девятиконтейнерная рама',cols=3,rows=3,w=1.62,h=.57,L=3.0,paint='canister_olive',angle=0)]

def cover_angle(t):
 if t<1:return 0
 if t<3:u=(t-1)/2
 elif t<5:return 90
 elif t<7:u=1-(t-5)/2
 else:return 0
 return 90*u*u*(3-2*u)

def rotate_x(p,a):
 a=a*pi/180;x,y,z=p;return x,y*cos(a)-z*sin(a),y*sin(a)+z*cos(a)

def build(c):
 m=Model(c['id'],c['name']);modern=c['cols']>1;W=c['w'];H=c['h'];L=c['L'];paint=c['paint'];pitchx=W+.12;pitchy=H+.115
 width=(c['cols']-1)*pitchx+W;z0=-L/2;z1=L/2
 # Transport skid. The complete truck chassis is intentionally a separate asset.
 for x in [-width/2+.12,width/2-.12]:m.box('TransportSkid',(x,.105,0),(.16,.21,L+.28),paint,.015)
 for z in [-L*.42,0,L*.42]:
  m.box('BaseCrossMember',(0,.25,z),(width+.08,.18,.15),paint,.012)
  for x in [-width/2+.12,width/2-.12]:
   m.box('MountingShoe',(x,.032,z),(.33,.062,.29),'dark',.013)
   for dx in [-.10,.10]:m.rod('AnchorHead',(x+dx,.061,z),(x+dx,.075,z),.022,'metal',segs=6)
 # Rack supports have a visible continuous path from each enclosure to the skid.
 roof=.48+(c['rows']-1)*pitchy+H
 for x in [-width/2-.018,width/2+.018]:
  for z in [-L*.39,L*.39]:
   m.box('RackUpright',(x,(.30+roof)/2,z),(.09,roof-.30,.095),paint,.009)
   m.plate('BaseGusset',[(x,.31,z-.18),(x,.31,z+.18),(x,.66,z)],.045,paint,axis=(1,0,0))
   for y in [.46,roof-.09]:m.rod('RackBolt',(x-.055,y,z),(x+.055,y,z),.019,'metal',segs=6)
 for row in range(c['rows']):
  floor=.48+row*pitchy
  for z in [-L*.39,L*.39]:m.box('ShelfCrossBeam',(0,floor-.055,z),(width+.12,.11,.10),paint,.012)
  for col in range(c['cols']):
   x=(col-(c['cols']-1)/2)*pitchx;bottom=floor;top=bottom+H;left=x-W/2;right=x+W/2
   prefix=f'Cell_{row+1}_{col+1}'
   # Four thin solid skins, open mouth, perimeter seal and an opaque rear closure.
   m.box(prefix+'_Floor',(x,bottom+.018,0),(W,.036,L),paint,.007)
   m.box(prefix+'_Roof',(x,top-.018,0),(W,.036,L),paint,.007)
   for xx in [left+.018,right-.018]:m.box(prefix+'_SideSkin',(xx,(bottom+top)/2,0),(.036,H,L),paint,.007)
   m.box(prefix+'_RearClosure',(x,(bottom+top)/2,z0+.018),(W-.035,H-.035,.036),paint,.01)
   # Warm liner visible at the empty front; no internal weapon or launch mechanism.
   m.box(prefix+'_InnerFloor',(x,bottom+.037,0),(W-.07,.010,L-.08),'canister_liner')
   m.box(prefix+'_InnerRoof',(x,top-.037,0),(W-.07,.010,L-.08),'canister_liner')
   for xx in [left+.037,right-.037]:m.box(prefix+'_InnerSide',(xx,(bottom+top)/2,0),(.010,H-.08,L-.08),'canister_liner')
   for zz in [z0+.022,z1-.008]:
    for yy in [bottom+.025,top-.025]:m.box(prefix+'_EdgeRail',(x,yy,zz),(W+.025,.044,.054),'canister_edge',.006)
    for xx in [left+.020,right-.020]:m.box(prefix+'_EdgePost',(xx,(bottom+top)/2,zz),(.047,H,.054),'canister_edge',.006)
   # Rivet rows, reinforced corner strips, attachment ears and side handles.
   for side,xx in [(-1,left),(1,right)]:
    for yy in [bottom+.027,top-.027]:
     m.box(prefix+'_CornerStrip',(xx,yy,0),(.020,.052,L-.06),'canister_edge',.004)
     for j in range(14):
      zz=z0+.12+(L-.24)*j/13
      m.rod(prefix+'_Rivet',(xx,yy,zz),(xx+side*.012,yy,zz),.0065,'silver',segs=8)
    for zz in [-L*.30,L*.30]:
     m.box(prefix+'_LiftTab',(xx+side*.012,top-.12,zz),(.035,.12,.09),paint,.008)
     m.tube(prefix+'_LiftLoop',[(xx+side*.024,top-.11,zz-.021),(xx+side*.059,top-.11,zz-.021),(xx+side*.059,top-.065,zz+.021),(xx+side*.024,top-.065,zz+.021)],.007,'metal',steps=3,segs=10)
    for zz in [-L*.20,L*.20]:
     y=(bottom+top)/2
     m.tube(prefix+'_CarryHandle',[(xx,y,zz-.06),(xx+side*.036,y,zz-.06),(xx+side*.036,y,zz+.06),(xx,y,zz+.06)],.011,paint,steps=3,segs=12)
   # Top hinged full-width cover. Older reference only supports a sealed end cap.
   hinge=(x,top,z1+.040)
   for dx in [-W*.32,W*.32]:
    m.box(prefix+'_HingeLeaf',(x+dx,top-.012,z1-.024),(.14,.025,.16),'canister_edge',.005)
    m.rod(prefix+'_HingeBarrel',(x+dx-.085,top,z1+.040),(x+dx+.085,top,z1+.040),.022,'metal',segs=24)
   start=len(m.parts)
   m.box(prefix+'_CoverSeal',(x,(bottom+top)/2,z1+.023),(W-.025,H-.025,.021),'rubber',.01)
   m.box(prefix+'_CoverPanel',(x,(bottom+top)/2,z1+.046),(W+.018,H+.015,.037),paint,.014)
   for yy in [bottom+.018,top-.018]:m.box(prefix+'_CoverRim',(x,yy,z1+.069),(W+.025,.036,.025),'canister_edge',.005)
   for xx in [left+.025,right-.025]:m.box(prefix+'_CoverRim',(xx,(bottom+top)/2,z1+.069),(.035,H,.025),'canister_edge',.005)
   for dx in [-W*.32,W*.32]:m.box(prefix+'_MovingHingeLeaf',(x+dx,top-.049,z1+.052),(.13,.12,.016),'canister_edge',.004)
   # Shallow pressed stiffeners and a recessed pull handle on the cover.
   for dx in [-W*.25,W*.25]:m.box(prefix+'_CoverStiffener',(x+dx,(bottom+top)/2,z1+.069),(.026,H*.56,.028),paint,.01)
   m.box(prefix+'_HandleRecess',(x,bottom+.115,z1+.066),(.19,.062,.013),'dark',.013)
   m.rod(prefix+'_CoverHandle',(x-.067,bottom+.115,z1+.079),(x+.067,bottom+.115,z1+.079),.012,'canister_edge')
   for dx in [-W*.43,W*.43]:
    m.box(prefix+'_LatchPlate',(x+dx,bottom+.10,z1+.074),(.063,.13,.019),'canister_edge',.005)
    m.rod(prefix+'_LatchPivot',(x+dx-.030,bottom+.13,z1+.087),(x+dx+.030,bottom+.13,z1+.087),.008,'metal',segs=12)
    m.box(prefix+'_LatchLever',(x+dx,bottom+.098,z1+.089),(.022,.073,.014),'metal',.005)
   m.box(prefix+'_LabelBacking',(x-W*.32,top-.10,z1+.068),(.17,.055,.008),'dark',.003)
   for j in range(row*3+col+1):
    m.box(prefix+'_IndexMark',(x-W*.37+j*.013,top-.10,z1+.073),(.006,.025,.003),'white')
   if modern:
    for part in m.parts[start:]:part['cover']=prefix+'_Door';part['hinge']=hinge
   # Feet and isolator shoes connect the enclosure to the shelf.
   for zz in [-L*.39,L*.39]:
    for dx in [-W*.34,W*.34]:
     m.box(prefix+'_Isolator',(x+dx,bottom-.015,zz),(.17,.045,.13),'rubber',.009)
     m.box(prefix+'_MountClamp',(x+dx,bottom+.008,zz),(.22,.03,.16),'canister_edge',.005)
     for dxx in [-.087,.087]:m.rod(prefix+'_ClampBolt',(x+dx+dxx,bottom+.020,zz),(x+dx+dxx,bottom+.041,zz),.012,'metal',segs=6)
 # Externally visible low cable tray and connected junction enclosures.
 m.box('CableTray',(0,.35,-L*.40),(width,.07,.09),'dark',.008)
 for col in range(c['cols']):
  x=(col-(c['cols']-1)/2)*pitchx
  m.box('JunctionHousing',(x,.38,-L*.43),(.26,.16,.14),paint,.015)
  m.tube('ExteriorCable',[(x,.40,-L*.47),(x+.20,.36,-L*.47),(x+.25,.35,-L*.40)],.012,'rubber',steps=6,segs=12)
 # A legacy section is shown tilted on its support, as in the archival photograph.
 if not modern:
  origin=(0,.25,-L/2)
  # Shift entire rack uniformly: support shoes are rebuilt beneath the rotated skid.
  for part in m.parts:
   part['points']=[add(origin,rotate_x(sub(p,origin),-c['angle'])) for p in part['points']]
   part['normals']=[rotate_x(n,-c['angle']) for n in part['normals']]
  lo,hi=m.bounds();shift=-lo[1]+.20
  for part in m.parts:part['points']=[add(p,(0,shift,0)) for p in part['points']]
  for x in [-width/2+.12,width/2-.12]:
   a=add(add(origin,rotate_x(sub((x,.12,-L*.42),origin),-c['angle'])),(0,shift,0))
   b=add(add(origin,rotate_x(sub((x,.12,L*.42),origin),-c['angle'])),(0,shift,0))
   m.box('LegacyGroundSkid',(x,.055,(a[2]+b[2])/2),(.20,.11,b[2]-a[2]+.35),paint,.012)
   for p in [a,b]:m.beam('LegacySupportPost',(x,.055,p[2]),p,.11,.11,paint,.009)
   m.beam('LegacyDiagonalBrace',(x,.09,a[2]),b,.065,.065,paint,.008)
  m.box('LegacyBaseTie',(0,.065,0),(width,.10,.12),paint,.008)
 m.config=c
 return m

def write(m,path):
 m.write(path,'Exterior reconstructed from publicly available photographs. Estimated visual scale; unseen details simplified. No functional launch internals.')
 src=path.read_text().replace('Aircraft','CanisterLauncher').replace('endTimeCode = 120','endTimeCode = 480')
 if m.config['cols']>1:
  parts={p['name']:p for p in m.parts if 'cover' in p};lines=src.splitlines();fixed=[];groups={};i=0
  while i<len(lines):
   line=lines[i];name=line.split('"')[1] if 'def Mesh "' in line else ''
   if name in parts:
    p=parts[name];block=[line];i+=1;depth=0
    while i<len(lines):
     ln=lines[i];block.append(ln);depth+=ln.count('{')-ln.count('}');i+=1
     if depth==0:break
    groups.setdefault(p['cover'],dict(hinge=p['hinge'],lines=[]))['lines'].extend(block)
   else:fixed.append(line);i+=1
  rig=[]
  for name,g in groups.items():
   h=g['hinge'];samples=', '.join(f'{t}: {-cover_angle(t/60):.7g}' for t in range(481))
   rig+=['        def Xform "'+name+'"','        {',f'            double3 xformOp:translate:pivot = {tup(h)}','            float xformOp:rotateX = 0','            float xformOp:rotateX.timeSamples = {'+samples+'}', '            uniform token[] xformOpOrder = ["xformOp:translate:pivot", "xformOp:rotateX", "!invert!xformOp:translate:pivot"]']+g['lines']+['        }']
  fixed[-2:-2]=rig;src='\n'.join(fixed)+'\n'
 path.write_text(src)

def run(args):
 r=subprocess.run(args,capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stdout+r.stderr)
 return r.stdout+r.stderr

def main():
 for d in ['models','sources','previews','validation']:(OUT/d).mkdir(exist_ok=True,parents=True)
 rows=[]
 for c in CONFIGS:
  m=build(c);src=OUT/'sources'/(m.id+'.usda');out=OUT/'models'/(m.id+'.usdz');write(m,src)
  with tempfile.TemporaryDirectory(prefix='canister-usdz-') as td:
   usdc=Path(td)/(m.id+'.usdc');run(['/usr/bin/usdcat',str(src),'-o',str(usdc)]);run(['/usr/bin/usdzip','--arkitAsset',str(usdc),str(out)])
  report=run(['/usr/bin/usdchecker','--arkit',str(out)]);assert 'Success!' in report;(OUT/'validation'/(m.id+'.txt')).write_text(report)
  lo,hi=m.bounds();rows.append(dict(id=m.id,name=c['name'],file='models/'+out.name,source='sources/'+src.name,preview='previews/'+m.id+'.png',mesh_count=len(m.parts),triangles=sum(len(p['faces']) for p in m.parts),dimensions_m=[hi[k]-lo[k] for k in range(3)],scale_note='Photo-estimated exterior scene scale, not factory dimensions',sha256=hashlib.sha256(out.read_bytes()).hexdigest(),geometry_sha256=m.fingerprint(),bytes=out.stat().st_size,canister_count=c['cols']*c['rows'],animation={'duration_seconds':8,'covers':9,'description':'Cosmetic cover opening and closing; not a launch sequence'} if c['cols']>1 else None))
  print(m.id,len(m.parts),'meshes; ARKit passed',flush=True)
 (OUT/'manifest.json').write_text(json.dumps(dict(schema_version=1,date='2026-09-07',models=rows),ensure_ascii=False,indent=2)+'\n')
if __name__=='__main__':main()
