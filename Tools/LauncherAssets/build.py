"""Standalone cosmetic launcher assets. No force, pressure or launch-performance model."""
import sys,json,re,hashlib,subprocess,tempfile,shutil
from pathlib import Path
from math import sin,cos,pi,sqrt
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tools/UAVModelAssets'))
from geometry import Model,add,mul,sub,tup,COLORS
OUT=ROOT/'Assets/LauncherModels'
COLORS.update(launcher_sand=('#b4a382',.69,.12),launcher_blue=('#375468',.61,.2),launcher_orange=('#db762f',.58,.1))
CONFIGS=[
 dict(id='catapult-s-portable',name='S · Переносная',class_label='Мини-БВС · условно до 5 кг',length=2.3,width=.18,height=.53,slope=.19,variant=0,paint='metal',accent='launcher_orange'),
 dict(id='catapult-m-modular',name='M · Секционная полевая',class_label='Лёгкие БВС · условно 5–15 кг',length=3.6,width=.29,height=.58,slope=.22,variant=1,paint='dark',accent='launcher_orange'),
 dict(id='catapult-l-pneumatic',name='L · Пневматическая',class_label='Средние БВС · условно 15–60 кг',length=5.2,width=.40,height=.72,slope=.23,variant=2,paint='launcher_sand',accent='dark'),
 dict(id='catapult-xl-trailer',name='XL · Прицепная',class_label='Крупные БВС · условно 60–120 кг',length=7.2,width=.60,height=1.05,slope=.25,variant=3,paint='launcher_blue',accent='launcher_orange')]

def fraction(t):
 if t<1:return 0
 if t<2.5:u=(t-1)/1.5
 elif t<3.5:return 1
 elif t<5.5:u=1-(t-3.5)/2
 else:return 0
 return u*u*(3-2*u)

def build(c):
 m=Model(c['id'],c['name']);v=c['variant'];L=c['length'];w=c['width'];h=c['height'];s=c['slope'];paint=c['paint'];accent=c['accent'];q=1+v*.40
 z0=-L/2;z1=L/2
 def pt(x,z,dy=0):return (x,h+(z-z0)*s+dy,z)
 def beam(name,a,b,width,thick,mat=paint):m.beam(name,a,b,width,thick,mat,min(width,thick)*.1)
 def foot(x,z):
  m.box('FootPad',(x,.025*q,z),(.20*q,.05*q,.18*q),'rubber',.009*q)
  m.rod('LevelingScrew',(x,.04*q,z),(x,.20*q,z),.012*q,'metal',segs=16)
  m.rod('LockCollar',(x,.11*q,z),(x,.15*q,z),.025*q,paint,segs=6)
  return (x,.16*q,z)
 # Extrusions and a recessed center drive channel. All meet cross members.
 for x in [-w/2,w/2]:
  beam('RailExtrusion',pt(x,z0),pt(x,z1),.055*q,.08*q,'metal')
  beam('RailWearStrip',pt(x,z0,.043*q),pt(x,z1,.043*q),.040*q,.012*q,'silver')
  beam('RailSideGroove',pt(x+(.029*q if x>0 else -.029*q),z0+.025),pt(x+(.029*q if x>0 else -.029*q),z1-.025),.002*q,.012*q,'black')
 beam('DriveChannel',pt(0,z0,-.035*q),pt(0,z1,-.035*q),w*.58,.055*q,accent)
 sections=7+v*3
 for j in range(sections+1):
  z=z0+L*j/sections
  beam('RailCrossMember',pt(-w/2,z,-.03*q),pt(w/2,z,-.03*q),.034*q,.025*q)
  for x in [-w/2,w/2]:m.screw('RailFastener',pt(x,z,.049*q),.007*q)
 if v>=1:
  # Perforated sides are actual open frames, not holes painted on a box.
  for side in [-1,1]:
   x=side*(w/2+.025*q)
   beam('TrussLowerChord',pt(x,z0,-.23*q),pt(x,z1,-.23*q),.035*q,.04*q)
   for j in range(sections):
    za=z0+L*j/sections;zb=z0+L*(j+1)/sections
    beam('TrussPost',pt(x,za,-.02*q),pt(x,za,-.23*q),.027*q,.025*q)
    beam('TrussDiagonal',pt(x,za,-.23*q),pt(x,zb,-.025*q),.018*q,.018*q,'metal')
   beam('TrussEndPost',pt(x,z1,-.02*q),pt(x,z1,-.23*q),.027*q,.025*q)
  for z in [0] if v<3 else [-L/6,L/6]:
   for side in [-1,1]:
    x=side*(w/2+.03*q)
    m.box('SectionSplice',pt(x,z,-.13*q),(.026*q,.25*q,.15*q),'metal',.007*q)
    for dz in [-.05*q,.05*q]:
     for dy in [-.04*q,-.21*q]:
      m.rod('SpliceBolt',pt(x, z+dz,dy),pt(x+side*.019*q,z+dz,dy),.011*q,'dark',segs=6)
 # Tripod / four-legged field frame, distinct from the trailer chassis.
 if v<3:
  for z,spread in [(z0+L*.14,.34*q),(z0+L*.75,.40*q)]:
   hinge=pt(0,z,-.08*q if v==0 else -.21*q)
   if v>=1:beam('LegMountCrossbar',pt(-w/2-.025*q,z,-.21*q),pt(w/2+.025*q,z,-.21*q),.05*q,.05*q)
   for side in [-1,1]:
    base=foot(side*spread,z-.10*q if z<0 else z+.10*q)
    beam('FoldingLeg',hinge,base,.038*q,.035*q)
    beam('LegBrace',pt(side*w*.4,z+.20*q,-.04*q),add(base,(0,.15*q,0)),.018*q,.018*q,'metal')
   m.rod('LegHinge',add(hinge,(-.10*q,0,0)),add(hinge,(.10*q,0,0)),.034*q,accent)
   beam('GroundCrossTie',(-spread,.17*q,z+(-.10*q if z<0 else .10*q)), (spread,.17*q,z+(-.10*q if z<0 else .10*q)),.026*q,.026*q)
  if v==2:
   # A compact handling axle between the feet; deployed feet carry the scene model.
   zz=z0+L*.26;rad=.17*q;yy=rad+.015
   m.rod('HandlingAxle',(-.43*q,yy,zz),(.43*q,yy,zz),.023*q,'metal')
   for side in [-1,1]:
    beam('AxleBracket',pt(side*w*.3,zz,-.12*q),(side*.30*q,yy,zz),.033*q,.035*q)
    wheel(m,side*.42*q,yy,zz,rad,.055*q)
 else:
  # Twin-axle road trailer with deployed stabilizers and drawbar.
  deck=.66;chassis=.68;half=.70;rear=z0+.8;front=z0+L*.72
  for side in [-1,1]:beam('TrailerLongeron',(side*half,chassis,rear),(side*half,chassis,front),.12,.14)
  for z in [rear,rear+.85,0,front]:beam('TrailerCrossMember',(-half,chassis,z),(half,chassis,z),.10,.13)
  m.box('TrailerDeck',(0,deck+.10,(rear+front)/2),(half*2,.065,front-rear),'dark',.016)
  for side in [-1,1]:
   for z in [rear+.15,front-.15]:
    outx=side*1.55
    beam('Outrigger',(side*.56,chassis,z),(outx,chassis,z),.095,.09)
    bottom=foot(outx,z)
    m.rod('StabilizerJack',bottom,(outx,chassis+.10,z),.038,'metal')
    m.rod('StabilizerHandle',(outx-.13,chassis+.07,z),(outx+.13,chassis+.07,z),.011,'dark')
   for z in [z0+L*.34,z0+L*.48]:
    m.rod('TrailerAxle',(-1.02,.35,z),(1.02,.35,z),.045,'metal')
    beam('AxleSpringHanger',(side*.68,chassis,z),(side*.72,.35,z),.10,.085,'dark')
    wheel(m,side*.92,.35,z,.34,.10)
   # Polygonal mudguard with vertical outer edge, attached to the chassis.
   m.plate('WheelMudguard',[(side*.70,.71,z0+L*.27),(side*1.10,.71,z0+L*.27),(side*1.10,.71,z0+L*.55),(side*.70,.71,z0+L*.55)],.035,paint)
   beam('MudguardBracket',(side*.68,chassis,z0+L*.40),(side*1.0,.71,z0+L*.40),.04,.045)
   beam('Drawbar',(side*.65,chassis,rear),(0,.58,z0-1.10),.09,.09)
  m.rod('TowCoupler',(0,.58,z0-1.08),(0,.58,z0-1.35),.075,'metal')
  for z in [rear+.25,front-.25]:
   for side in [-1,1]:beam('RailSupportTower',(side*.47,chassis+.12,z),pt(side*w*.45,z,-.20*q),.080,.080)
   m.rod('ElevationHinge',pt(-.48,z,-.20*q),pt(.48,z,-.20*q),.07,'metal')
  for side in [-1,1]:
   m.box('RearLamp',(side*.53,.69,rear-.07),(.17,.08,.035),'led_red',.02)
   beam('RearLampMount',(side*.53,chassis,rear),(side*.53,.69,rear-.07),.06,.06)
 # Enclosed drive assemblies: exterior casing only, no functional internals.
 if v<2:
  z=z0+.12*q
  m.box('WinchMount',pt(0,z,-.12*q),(w*.85,.22*q,.22*q),paint,.015*q)
  m.rod('WinchDrum',pt(-.16*q,z,-.09*q),pt(.16*q,z,-.09*q),.075*q,'metal')
  for side in [-1,1]:m.rod('WinchFlange',pt(side*.15*q,z,-.09*q),pt(side*.175*q,z,-.09*q),.098*q,'metal')
  x=.19*q;m.rod('WinchShaft',pt(0,z,-.09*q),pt(x,z,-.09*q),.018*q,'dark')
  beam('WinchCrank',pt(x,z,-.09*q),pt(x,z+.13*q,-.19*q),.020*q,.018*q,'metal')
  m.rod('WinchGrip',pt(x,z+.13*q,-.19*q),pt(x+.10*q,z+.13*q,-.19*q),.021*q,'rubber')
  for side in [-1,1]:beam('EnclosedElasticCassette',pt(side*w*.30,z0+.25*q,-.13*q),pt(side*w*.30,z1-.15*q,-.13*q),.030*q,.037*q,'black')
  for zz in [z0+.40*q,z1-.30*q]:
   for side in [-1,1]:beam('CassetteBracket',pt(side*w*.30,zz,-.04*q),pt(side*w*.30,zz,-.13*q),.034*q,.028*q,'metal')
 else:
  # Cylinder fairing and saddle clamps directly under the rail.
  dy=-.16*q
  m.rod('PneumaticHousing',pt(0,z0+.15*q,dy),pt(0,z1-.18*q,dy),.067*q,'metal',segs=40)
  for z in [z0+.30*q,0,z1-.35*q]:
   beam('CylinderSaddle',pt(-w*.36,z,-.12*q),pt(w*.36,z,-.12*q),.11*q,.10*q,paint)
  z=z0+.60*q
  m.box('EquipmentCase',pt(-.25*q,z,-.40*q),(.34*q,.34*q,.47*q),paint,.035*q)
  beam('EquipmentBracket',pt(0,z,-.15*q),pt(-.25*q,z,-.25*q),.07*q,.07*q,'metal')
  m.box('ControlPanel',pt(-.25*q,z,-.224*q),(.28*q,.014*q,.33*q),'black',.008*q)
  m.rod('GaugeRim',pt(-.25*q,z,-.217*q),pt(-.25*q,z,-.198*q),.052*q,'metal',segs=40)
  m.rod('GaugeFace',pt(-.25*q,z,-.197*q),pt(-.25*q,z,-.194*q),.046*q,'white',segs=40)
  for j in range(9):
   a=j*2*pi/10;x=-.25*q+cos(a)*.036*q;zz=z+sin(a)*.036*q
   cy=pt(0,z,-.194*q)[1]
   m.rod('GaugeTick',(x,cy,zz),(x,cy+.001*q,zz),.0025*q,'dark',segs=6)
  cy=pt(0,z,-.194*q)[1]+.001*q
  m.rod('GaugePointer',(-.25*q,cy,z),(-.228*q,cy,z+.019*q),.002*q,'red',segs=6)
  for x,zz in [(-.32*q,z-.12*q),(-.20*q,z-.12*q)]:m.rod('PanelButton',pt(x,zz,-.213*q),pt(x,zz,-.19*q),.012*q,'red' if x<-.25*q else 'green')
  m.tube('ProtectedServiceHose',[pt(-.25*q,z+.2*q,-.32*q),pt(-.32*q,z+.37*q,-.31*q),pt(0,z+.47*q,-.16*q)],.012*q,'rubber',steps=8,segs=12)
 # Ends, carry handles, fasteners and warning stripes.
 for z in [z0,z1]:
  m.box('EndCap',pt(0,z), (w+.08*q,.12*q,.05*q),accent,.013*q)
  for x in [-w/2,w/2]:m.screw('EndBolt',pt(x,z,.062*q),.009*q,hosts=['EndCap'])
 for z in [z0+L*.28,z0+L*.58]:
  for side in [-1,1]:
   x=side*(w*.5+.06*q)
   m.tube('CarryHandle',[pt(side*w*.5,z,-.02*q),pt(x,z,-.06*q),pt(x,z+.15*q,-.06*q),pt(side*w*.5,z+.15*q,-.02*q)],.012*q,'rubber',steps=4,segs=12)
 # Carriage and adapter cradle. The rollers are positioned on the wear strips.
 start=len(m.parts);zc=z0+.38*q;roller=.025*q
 beam('Carriage_Base',pt(0,zc-.13*q,.105*q),pt(0,zc+.13*q,.105*q),w+.10*q,.066*q,accent)
 for dz in [-.083*q,.083*q]:
  for x in [-w/2,w/2]:
   zz=zc+dz
   m.rod('Carriage_RollerAxle',pt(x-.030*q,zz,.072*q),pt(x+.030*q,zz,.072*q),.008*q,'metal')
   m.rod('Carriage_Roller',pt(x-.022*q,zz,.072*q),pt(x+.022*q,zz,.072*q),roller,'rubber',segs=24)
   m.box('Carriage_BearingBlock',pt(x,zz,.099*q),(.066*q,.034*q,.060*q),'metal',.005*q)
 for dz in [-.08*q,.08*q]:
  zz=zc+dz
  beam('Carriage_Crossarm',pt(-.30*q,zz,.19*q),pt(.30*q,zz,.19*q),.038*q,.04*q,'metal')
  for side in [-1,1]:
   beam('Carriage_CradlePost',pt(side*.14*q,zz,.12*q),pt(side*.22*q,zz,.31*q),.035*q,.031*q,paint)
   beam('Carriage_CradlePad',pt(side*.16*q,zz,.29*q),pt(side*.27*q,zz,.36*q),.055*q,.025*q,'rubber')
   m.rod('Carriage_AdapterPin',pt(side*.14*q-.03*q,zz,.15*q),pt(side*.14*q+.03*q,zz,.15*q),.012*q,'silver')
 m.box('Carriage_CentralSaddle',pt(0,zc,.15*q),(.17*q,.05*q,.20*q),'rubber',.014*q)
 for part in m.parts[start:]:part['moving']=True
 # Travel is a visual animation extent, deliberately not a launch-performance parameter.
 m.travel=(L-.76*q);m.motion_vector=(0,m.travel*s,m.travel)
 m.config=c
 return m

def wheel(m,x,y,z,r,half):
 m.profiled_ring('Tyre',(x,y,z),r*.76,[(r*.24*cos(j*2*pi/16),half*sin(j*2*pi/16)) for j in range(16)],'rubber',64,axis='x')
 m.rod('WheelRim',(x-half*.8,y,z),(x+half*.8,y,z),r*.62,'metal',segs=32)
 for side in [-1,1]:
  m.rod('WheelHub',(x+side*half*.6,y,z),(x+side*half*1.1,y,z),r*.20,'dark')
  for j in range(6):
   a=j*pi/3
   m.rod('LugNut',(x+side*half*.80,y+cos(a)*r*.32,z+sin(a)*r*.32),(x+side*half*.95,y+cos(a)*r*.32,z+sin(a)*r*.32),r*.035,'metal',segs=6)

def write(m,path):
 m.write(path,'Original generic exterior asset inspired by public launcher photographs; not a replica or manufacturing model.')
 source=path.read_text().replace('Aircraft','Launcher').replace('endTimeCode = 120','endTimeCode = 360')
 lines=source.splitlines();fixed=[];moving=[];i=0
 while i<len(lines):
  if 'def Mesh "Carriage_' in lines[i]:
   block=[lines[i]];i+=1;depth=0
   while i<len(lines):
    line=lines[i];block.append(line);depth+=line.count('{')-line.count('}');i+=1
    if depth==0:break
   moving.extend(block)
  else:fixed.append(lines[i]);i+=1
 assert moving
 samples=', '.join(f'{t}: {tup(mul(m.motion_vector,fraction(t/60)))}' for t in range(361))
 rig=['        def Xform "Carriage"','        {','            double3 xformOp:translate = (0, 0, 0)',
      '            double3 xformOp:translate.timeSamples = {'+samples+'}',
      '            uniform token[] xformOpOrder = ["xformOp:translate"]']+moving+['        }']
 fixed[-2:-2]=rig
 path.write_text('\n'.join(fixed)+'\n')

def command(args):
 r=subprocess.run(args,capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stdout+r.stderr)
 return r.stdout+r.stderr

def main():
 for folder in ['models','sources','previews','validation']:(OUT/folder).mkdir(parents=True,exist_ok=True)
 rows=[]
 for c in CONFIGS:
  m=build(c);src=OUT/'sources'/(m.id+'.usda');out=OUT/'models'/(m.id+'.usdz');write(m,src)
  with tempfile.TemporaryDirectory(prefix='launcher-usdz-') as td:
   usdc=Path(td)/(m.id+'.usdc');command(['/usr/bin/usdcat',str(src),'-o',str(usdc)])
   command(['/usr/bin/usdzip','--arkitAsset',str(usdc),str(out)])
  result=command(['/usr/bin/usdchecker','--arkit',str(out)]);assert 'Success!' in result
  (OUT/'validation'/(m.id+'.txt')).write_text(result)
  lo,hi=m.bounds();rows.append(dict(id=m.id,name=c['name'],class_label=c['class_label'],file='models/'+out.name,
   source='sources/'+src.name,preview='previews/'+m.id+'.png',dimensions_m=[hi[i]-lo[i] for i in range(3)],
   scale_note='Nominal scene scale, not measured CAD or certified capacity.',metres_per_unit=1,up_axis='Y',forward_axis='+Z',ground_plane_y=0,
   mesh_count=len(m.parts),triangles=sum(len(p['faces']) for p in m.parts),sha256=hashlib.sha256(out.read_bytes()).hexdigest(),geometry_sha256=m.fingerprint(),
   animation=dict(node='/Launcher/Geometry/Carriage',duration_seconds=6,samples=361,translation_vector_m=m.motion_vector,meaning='Slow carriage travel and reset for visual inspection, not physical launch timing.'),
   moving_parts=[p['name'] for p in m.parts if p.get('moving')],bytes=out.stat().st_size))
  print(m.id,len(m.parts),'meshes; ARKit passed',flush=True)
 (OUT/'manifest.json').write_text(json.dumps(dict(schema_version=1,date='2026-09-07',collection='Four standalone generic UAV launcher exteriors',models=rows),ensure_ascii=False,indent=2)+'\n')
if __name__=='__main__':main()
