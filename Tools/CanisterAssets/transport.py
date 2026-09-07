"""Exterior-only transport scene props, composed with existing display modules."""
import copy,json,hashlib,tempfile,sys
from pathlib import Path
from math import pi,sin,cos
from build import ROOT,OUT,CONFIGS,build as build_module,run,rotate_x
from geometry import Model,COLORS,add,sub
VEHICLES=ROOT/'Assets/IAITransportModels'
COLORS.update(truck_olive=('#515e48',.73,.10),truck_sand=('#9c9475',.74,.07),truck_window=('#263e49',.15,.20),lamp_clear=('#d0d7ce',.24,.12))

def wheel(m,x,z,r=.63):
 y=r+.012;half=.20
 m.profiled_ring('Tyre',(x,y,z),r*.78,[(r*.22*cos(j*2*pi/20),half*sin(j*2*pi/20)) for j in range(20)],'rubber',64,axis='x')
 m.rod('WheelRim',(x-half*.83,y,z),(x+half*.83,y,z),r*.62,'truck_olive',segs=40)
 m.rod('WheelHub',(x-half*1.04,y,z),(x+half*1.04,y,z),r*.21,'dark',segs=24)
 for side in [-1,1]:
  for j in range(8):
   a=j*pi/4
   m.rod('WheelNut',(x+side*half*.78,y+cos(a)*r*.38,z+sin(a)*r*.38),(x+side*half*.92,y+cos(a)*r*.38,z+sin(a)*r*.38),.019,'metal',segs=6)
 for j in range(32):
  a=j*2*pi/32
  for side in [-1,1]:
   start=len(m.parts)
   m.box('TreadBlock',(side*.085,0,r-.003),(.16,.08,.038),'rubber',.007)
   for p in m.parts[start:]:
    def transform(v,point=False):
     xx,yy,zz=v
     q=(xx,yy*cos(a)-zz*sin(a),yy*sin(a)+zz*cos(a))
     return add(q,(x,y,z)) if point else q
    p['points']=[transform(v,True) for v in p['points']];p['normals']=[transform(v) for v in p['normals']]

def truck(modern):
 ident='cabover-6x6' if modern else 'bonnet-6x6'
 m=Model(ident,'Бескапотная платформа 6×6' if modern else 'Капотная платформа 6×6')
 paint='truck_olive' if modern else 'truck_sand';cabw=2.55;rear=-4.1;front=4.12
 deckw=3.34 if modern else 2.48;deckfront=1.50 if modern else .80;deckrear=-3.98;deckY=1.64
 # Chassis rails and crossmembers remain visible below the load bed.
 for x in [-.71,.71]:m.box('ChassisRail',(x,1.02,(front+rear)/2),(.19,.28,front-rear),paint,.025)
 for z in [rear+.08,-2.9,-1.5,0,1.55,3.15,front-.12]:m.box('ChassisCrossmember',(0,1.03,z),(1.65,.17,.16),'dark',.016)
 for z in [deckrear+.2,-2.2,-.5,deckfront-.15]:
  m.box('DeckSubframe',(0,1.37,z),(deckw-.16,.40,.14),paint,.015)
 m.box('LoadDeck',(0,deckY-.06,(deckrear+deckfront)/2),(deckw,.12,deckfront-deckrear),paint,.02)
 for side in [-1,1]:
  x=side*(deckw/2-.035)
  m.box('DeckEdge',(x,1.57,(deckrear+deckfront)/2),(.07,.20,deckfront-deckrear),paint,.008)
  for z in [-3.75,-2.5,-1.25,0,deckfront-.15]:
   m.tube('TieDownLoop',[(x,1.51,z-.05),(x+side*.045,1.49,z-.05),(x+side*.045,1.49,z+.05),(x,1.51,z+.05)],.012,'metal',steps=3,segs=10)
 # Six wheels, connected suspension and axles.
 for z in [-3.10,-1.60,3.10]:
  m.rod('Axle',(-1.22,.642,z),(1.22,.642,z),.075,'dark',segs=24)
  m.ellipsoid('Differential',(0,.642,z),(.19,.15,.20),'dark',segs=24,rings=12)
  for side in [-1,1]:
   x=side*1.15;wheel(m,x,z)
   for k in range(3):m.box('LeafSpring',(side*.70,.77+k*.025,z),(.12,.024,.64-k*.10),'dark',.006)
   for dz in [-.24,.24]:m.beam('SpringHanger',(side*.70,.99,z+dz),(side*.70,.78,z+dz),.085,.06,paint,.005)
   m.rod('ShockAbsorber',(side*.78,.68,z+.05),(side*.82,1.02,z+.22),.035,'metal')
   m.beam('AxleSaddle',(side*.70,.642,z),(side*.70,.83,z),.15,.15,'dark',.01)
 # Rear fenders, mud flaps, storage boxes and fuel tank.
 for side in [-1,1]:
  x=side*1.16
  m.box('RearMudguard',(x,1.34,-2.35),(.51,.06,2.55),paint,.022)
  for z in [-3.65,-1.05]:m.box('Mudflap',(x,.94,z),(.49,.76,.035),'rubber',.012)
  for z in [-3.3,-1.4]:m.beam('FenderBracket',(side*.71,1.08,z),(x,1.33,z),.07,.065,paint,.008)
  m.box('Toolbox',(side*1.0,1.0,.1),(.60,.52,.76),paint,.04)
  m.box('ToolboxDoor',(side*1.31,1.0,.1),(.025,.43,.67),paint,.012)
  m.rod('ToolboxLatch',(side*1.33,.93,.05),(side*1.33,.93,.19),.013,'metal')
 m.rod('DriveShaft',(0,.78,-3.1),(0,.86,3.1),.05,'metal')
 # Cab shape: high flat front on the modern carrier; lower cab plus hood on legacy.
 cabz=2.82 if modern else 1.68;cablen=2.38 if modern else 1.78;cabbottom=1.42;cabtop=3.26 if modern else 3.02
 m.box('CabLower',(0,1.77,cabz),(cabw,.70,cablen),paint,.075)
 m.box('CabUpper',(0,(2.05+cabtop)/2,cabz),(cabw-.08,cabtop-2.05,cablen-.035),paint,.09)
 m.box('CabRoof',(0,cabtop+.025,cabz),(cabw+.055,.10,cablen+.075),paint,.06)
 for xx in [-.71,.71]:
  for zz in [cabz-.60,cabz+.60]:m.box('CabMount',(xx,1.30,zz),(.18,.40,.18),'rubber',.02)
 face=cabz+cablen/2
 if not modern:
  m.box('Bonnet',(0,2.06,3.25),(1.47,.64,1.35),paint,.085)
  m.box('EngineExteriorHousing',(0,1.48,3.18),(1.35,.80,1.14),'dark',.045)
  m.box('BonnetCenterSeam',(0,2.381,3.25),(.009,.009,1.18),'seam',.003)
  for side in [-1,1]:
   m.box('FrontFender',(side*1.0,1.51,3.13),(.57,.10,1.47),paint,.028)
   m.box('FenderApron',(side*.77,1.38,3.13),(.07,.26,1.30),paint,.015)
   for z in [2.86,3.43]:m.rod('HoodCatch',(side*.744,2.05,z),(side*.744,2.24,z),.014,'metal')
   for j in range(6):m.box('HoodVent',(side*.733,2.13,3.0+j*.10),(.009,.16,.022),'dark',.005)
  grillz=3.94;grilly=2.06;grillw=1.20
 else:grillz=face+.028;grilly=1.88;grillw=1.92
 # Split windshield, rubber surrounds, wipers, side windows and door seams.
 glassy=(2.34+cabtop-.15)/2;glassh=cabtop-.15-2.34
 for side in [-1,1]:
  x=side*.59
  m.box('WindshieldGasket',(x,glassy,face-.010),(1.09,glassh+.07,.060),'rubber',.04)
  m.box('Windshield',(x,glassy,face+.019),(1.01,glassh,.018),'truck_window',.035)
  m.rod('WiperArm',(x-.30,2.34,face+.038),(x+.12,glassy+.04,face+.038),.013,'dark',segs=12)
  m.rod('WiperBlade',(x-.08,glassy-.02,face+.050),(x+.34,glassy+.10,face+.050),.016,'rubber',segs=12)
  xx=side*(cabw/2-.034)
  m.box('SideWindowSeal',(xx,glassy,cabz+.18),(.038,glassh+.05,cablen*.59),'rubber',.026)
  m.box('SideWindow',(xx+side*.022,glassy,cabz+.18),(.015,glassh-.025,cablen*.54),'truck_window',.016)
  m.box('WindowDivider',(xx+side*.035,glassy,cabz+.50),(.018,glassh,.025),paint,.004)
  # Door panel inset is a surface detail attached to the cab shell.
  m.box('DoorPanel',(side*(cabw/2+.004),2.08,cabz+.20),(.023,.37,cablen*.68),paint,.013)
  m.rod('DoorHandle',(side*(cabw/2+.025),2.22,cabz-.14),(side*(cabw/2+.025),2.22,cabz+.05),.021,'dark')
  for z in [cabz+.65,cabz-.48]:m.box('DoorHinge',(side*(cabw/2+.010),1.99,z),(.04,.12,.05),'metal',.007)
  m.box('CabStep',(side*1.14,1.08,cabz+.10),(.58,.065,1.05),'dark',.025)
  m.beam('StepBracket',(side*.72,1.09,cabz+.10),(side*1.14,1.08,cabz+.10),.08,.09,paint,.01)
  for j in range(8):m.box('StepGrip',(side*1.23,1.117,cabz-.32+j*.12),(.30,.012,.017),'metal',.002)
  m.tube('MirrorArm',[(side*1.20,2.76,face-.18),(side*1.60,2.76,face-.12),(side*1.60,2.53,face-.12)],.022,paint,steps=3,segs=12)
  m.box('MirrorHousing',(side*1.60,2.56,face-.12),(.18,.36,.10),'dark',.035)
  m.box('MirrorGlass',(side*1.60,2.56,face-.177),(.145,.30,.016),'metal',.02)
 # Front face, bumper and headlights; no copied emblems or made-up serial numbers.
 m.box('RadiatorGrille',(0,grilly,grillz),(grillw,.38,.045),'dark',.025)
 for j in range(10):m.box('GrilleSlat',(-grillw*.44+j*grillw*.88/9,grilly,grillz+.025),(.028,.33,.022),paint,.007)
 m.box('FrontBumper',(0,1.23,4.10),(2.66,.25,.22),paint,.045)
 for side in [-1,1]:
  m.beam('BumperBracket',(side*.71,1.05,3.87),(side*.71,1.23,4.10),.12,.14,'dark',.01)
  m.box('HeadlampHousing',(side*.93,1.62,grillz-.025),(.35,.34,.14),paint,.035)
  m.rod('HeadlampRim',(side*.93,1.62,grillz+.025),(side*.93,1.62,grillz+.080),.12,'metal',segs=40)
  m.rod('HeadlampGlass',(side*.93,1.62,grillz+.071),(side*.93,1.62,grillz+.088),.105,'lamp_clear',segs=40)
  m.box('Indicator',(side*1.14,1.70,grillz+.058),(.12,.10,.06),'orange',.025)
  m.box('RearLampMount',(side*1.03,1.29,rear-.055),(.43,.23,.08),paint,.016)
  m.beam('RearLampBracket',(side*.71,1.09,rear),(side*1.03,1.29,rear),.08,.10,paint,.009)
  for dx,mat in [(-.11,'red'),(.04,'orange')]:m.box('RearLamp',(side*1.03+dx,1.29,rear-.106),(.12,.14,.035),mat,.02)
  m.box('CabMarker',(side*.95,cabtop+.015,face+.022),(.15,.06,.055),'orange',.01)
 # Attached air intake and exhaust behind the cabin.
 for x in [-.97,.97]:
  back=cabz-cablen/2-.15
  m.rod('ServiceStack',(x,1.10,back),(x,cabtop-.08,back),.072,'dark',segs=24)
  for yy in [1.52,2.30]:m.beam('StackClamp',(x,yy,back),(x,yy,cabz-cablen/2+.05),.07,.065,paint,.006)
  m.rod('StackCap',(x,cabtop-.12,back),(x,cabtop-.06,back),.10,'dark',segs=24)
 # Body bolts and tied-down equipment remain connected to the exterior.
 for z in [-3.7,-2.8,-1.9,-1.0,-.1,deckfront-.18]:
  for side in [-1,1]:m.rod('BedFastener',(side*(deckw/2-.008),1.58,z),(side*(deckw/2+.015),1.58,z),.016,'metal',segs=6)
 m.deckY=deckY;m.modern=modern
 return m

def transform_module(v,modern,deckY):
 x,y,z=v
 return (z,y+deckY,-x-1.10) if modern else (x,y+deckY,z-1.60)

def assembled(modern,angle=0):
 t=truck(modern);cargo=build_module(CONFIGS[1 if modern else 0])
 for p in cargo.parts:
  p=copy.deepcopy(p);p['name']='Cargo_'+p['name']
  if angle and 'cover' in p:p['points']=[add(p['hinge'],rotate_x(sub(v,p['hinge']),-angle)) for v in p['points']]
  p['points']=[transform_module(v,modern,t.deckY) for v in p['points']]
  p['normals']=[(v[2],v[1],-v[0]) if modern else v for v in p['normals']]
  t.parts.append(p)
 return t

def export(modern,loaded):
 m=truck(modern);base='harop-cabover-6x6' if modern else 'harpy-bonnet-6x6';ident=base+('-with-module' if loaded else '-transport')
 m.id=ident
 src=VEHICLES/'sources'/(ident+'.usda');m.write(src,'Exterior scene truck inspired by public photographs; nominal scale, not an exact commercial chassis.')
 s=src.read_text().replace('Aircraft','Transport').replace('endTimeCode = 120','endTimeCode = 480')
 if loaded:
  cid=CONFIGS[1 if modern else 0]['id'];ref=(OUT/'sources'/(cid+'.usda')).resolve()
  offset=(0,m.deckY,-1.10 if modern else -1.60)
  cargo=f'''    def Xform "ContainerModule" (prepend references = @{ref}@</CanisterLauncher>)
    {{
        double3 xformOp:translate = {offset}
        float xformOp:rotateY = {90 if modern else 0}
        uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateY"]
    }}
'''
  s=s.rsplit('}',1)[0]+cargo+'}\n'
 src.write_text(s)
 out=VEHICLES/'models'/(ident+'.usdz')
 with tempfile.TemporaryDirectory(prefix='iai-transport-') as td:
  flat=Path(td)/(ident+'.usdc');run(['/usr/bin/usdcat','--flatten',str(src),'-o',str(flat)])
  # Keep each published USDA self-contained as well as the USDZ.
  run(['/usr/bin/usdcat',str(flat),'-o',str(src)])
  run(['/usr/bin/usdzip','--arkitAsset',str(flat),str(out)])
 result=run(['/usr/bin/usdchecker','--arkit',str(out)]);assert 'Success!' in result
 (VEHICLES/'validation'/(ident+'.txt')).write_text(result)
 mm=assembled(modern) if loaded else m;lo,hi=mm.bounds()
 row=dict(id=ident,file='models/'+out.name,source='sources/'+src.name,preview='previews/'+ident+'.png',loaded=loaded,photo_variant='cabover' if modern else 'bonnet',mesh_count=len(mm.parts),bounds_min_m=lo,bounds_max_m=hi,dimensions_m=[hi[i]-lo[i] for i in range(3)],sha256=hashlib.sha256(out.read_bytes()).hexdigest(),bytes=out.stat().st_size,container_scale=1 if loaded else None,scale_note='Nominal exterior scene scale. Body adapted to the existing estimated module; not a factory chassis replica.')
 print(ident,len(mm.parts),'meshes; USDZ passed',flush=True)
 return row

def main():
 for d in ['models','sources','previews','validation']:(VEHICLES/d).mkdir(exist_ok=True,parents=True)
 rows=[export(modern,loaded) for modern in [False,True] for loaded in [False,True]]
 (VEHICLES/'manifest.json').write_text(json.dumps(dict(schema_version=1,models=rows),ensure_ascii=False,indent=2)+'\n')
if __name__=='__main__':main()
