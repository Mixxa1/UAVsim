"""Author an articulated TX16S-style exterior, then package it with native USD tools.

Original approximate display geometry, based on RadioMaster's public product views.
No downloaded scan, reference photograph, or manufacturing CAD is embedded.
"""
from pathlib import Path
import sys, math, json, shutil, subprocess, tempfile, random
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/UAVModelAssets"))
from geometry import Model, COLORS, TEXTURES, tup, array, sub

OUT = ROOT / "Assets/Transmitter"
TEX = OUT / "textures"
RESOURCE = ROOT / "DroneUAVDemo/Resources/Models/Controllers/RadioMasterTX16S.usdz"
for p in [OUT, TEX, RESOURCE.parent]: p.mkdir(parents=True, exist_ok=True)
COLORS.update(shell=("#282D33", .52, .02), fascia=("#3E444A", .38, .08),
              grip=("#15191D", .89, 0), alloy=("#A6ADB4", .28, .72),
              blue=("#387BA4", .32, .58), screen=("#ECF4F2", .30, 0))
rng = random.Random(2001)
im = Image.new("RGB", (512,512)); px = im.load()
for y in range(512):
    for x in range(512):
        weave = ((x//12 + y//12)%4)<2
        v=85+int(15*math.sin((x if weave else y)*math.pi/6))+rng.randrange(-4,5)
        px[x,y]=(v,v+3,v+5)
im.save(TEX/"fascia.png")
TEXTURES['fascia'] = ('fascia.png', False, 35)
font_path='/System/Library/Fonts/Helvetica.ttc'
def font(size): return ImageFont.truetype(font_path, size)
lcd=Image.new('RGB',(960,544),'#13242E'); d=ImageDraw.Draw(lcd)
d.rounded_rectangle((20,20,940,524),20,fill='#1D3541',outline='#426A77',width=3)
d.text((46,38),'UAVsim   |   USB JOYSTICK',font=font(44),fill='#E4EDEC')
d.text((48,120),'MANUAL',font=font(68),fill='#87DBBA')
d.text((48,223),'ARM     ROLL    PITCH    YAW',font=font(35),fill='#C6D5D5')
for i in range(4):
    y=294+i*47; d.rounded_rectangle((48,y,860,y+24),6,fill='#425C65');d.rounded_rectangle((48,y,340+i*115,y+24),6,fill='#6DABB7')
lcd.save(TEX/'screen.png')
label=Image.new('RGBA',(1024,160),(0,0,0,0)); ld=ImageDraw.Draw(label)
ld.text((25,26),'RADIOMASTER  TX16S',font=font(75),fill='#D5D8DC')
label.save(TEX/'branding.png')

m=Model('radiomaster-tx16s-display','RadioMaster TX16S-style articulated transmitter')
rigs={}
def group(name, center, build):
    start=len(m.parts); build()
    for p in m.parts[start:]: p['group']=name
    rigs[name]=center
def decal(name,c,w,h):
    mat='decal_'+name;COLORS[mat]=('#FFFFFF',.44,0);TEXTURES[mat]=(name+'.png',name!='screen',1)
    x,y,z=c
    m.mesh(name,[(x-w/2,y-h/2,z),(x+w/2,y-h/2,z),(x+w/2,y+h/2,z),(x-w/2,y+h/2,z)],[(0,1,2,3)],mat)
    m.parts[-1]['uv']=[(0,0),(1,0),(1,1),(0,1)]

outline=[(-.063,-.096),(-.085,-.080),(-.091,-.040),(-.086,.020),(-.099,.068),(-.088,.092),
         (-.060,.100),(-.020,.090),(.020,.090),(.060,.100),(.088,.092),(.099,.068),(.086,.020),(.091,-.040),(.085,-.080),(.063,-.096)]
m.shell('MoldedHousing',outline,[(.85,-.036),(.98,-.027),(1,-.011),(1,.011),(.96,.028),(.91,.034)],'shell',steps=8)
# shell() extrudes along Y. Turn that thickness into Z; the outline becomes the front X/Y profile.
p=m.parts[-1]; p['points']=[(x,z,-y) for x,y,z in p['points']];p['normals']=[(x,z,-y) for x,y,z in p['normals']]
m.box('CarbonFascia',(0,.023,.033),(.161,.130,.006),'fascia',.003)
for side in [-1,1]:
    m.ellipsoid('RubberGrip',(side*.081,-.030,-.009),(.014,.055,.027),'grip',32,16)
    for k in range(8):
        m.rod('GripRib',(side*.090,-.070+k*.008,-.010),(side*.089,-.069+k*.008,.013),.0014,'rubber',segs=10)
    x=side*.046; y=.030
    m.profiled_ring('GimbalAlloyRim',(x,y,.039),.028,[(0,-.003),(.002,-.002),(.002,.001),(0,.002),(-.002,.001),(-.002,-.003)],'alloy',96,'z')
    m.rod('GimbalRecess',(x,y,.034),(x,y,.038),.026,'rubber',segs=64)
    m.profiled_ring('InnerGimbal',(x,y,.039),.021,[(-.001,-.001),(.001,-.001),(.001,.001),(-.001,.001)],'shell',64,'z')
    for a in [math.pi/4,3*math.pi/4,5*math.pi/4,7*math.pi/4]:
        m.screw('GimbalBolt',(x+math.cos(a)*.024,y+math.sin(a)*.024,.042),.0014,'z')
    def stick():
        m.ellipsoid('GimbalBall',(x,y,.041),(.007,.007,.005),'alloy')
        m.rod('StickShaft',(x,y,.041),(x,y,.067),.0022,'alloy',segs=32)
        m.rod('StickCap',(x,y,.062),(x,y,.072),.0045,'blue',r2=.0052,segs=32)
        for k in range(5):
            m.profiled_ring('StickKnurl',(x,y,.063+k*.0017),.0048,[(-.0004,-.0002),(.0003,-.0002),(.0003,.0002),(-.0004,.0002)],'alloy',32,'z')
    group('GimbalLeft' if side<0 else 'GimbalRight',(x,y,.041),stick)
    m.box('VerticalTrim',(x-side*.034,y-.010,.037),(.006,.023,.005),'rubber',.002)
    m.box('HorizontalTrim',(x,y-.037,.037),(.026,.006,.005),'rubber',.002)
    m.rod('KnobBase',(x,.075,.033),(x,.075,.040),.009,'shell',segs=48)
    m.rod('KnobDial',(x,.075,.038),(x,.075,.046),.0075,'alloy',segs=48)
    for k in range(20):
        a=k*math.pi/10
        m.rod('KnobKnurl',(x+math.cos(a)*.0074,.075+math.sin(a)*.0074,.039),(x+math.cos(a)*.0074,.075+math.sin(a)*.0074,.045),.0006,'dark',segs=6)

m.box('DisplayBezel',(0,-.055,.033),(.118,.068,.008),'rubber',.003)
m.box('DisplayGlass',(0,-.055,.038),(.106,.056,.002),'glass',.001)
decal('screen',(0,-.055,.0392),.104,.054)
decal('branding',(0,-.093,.034),.091,.014)
m.box('PowerButton',(0,.016,.041),(.012,.008,.005),'rubber',.002)
m.box('PowerLED',(0,.016,.044),(.004,.0012,.001),'led_green')
m.profiled_ring('LanyardEye',(0,-.011,.041),.006,[(-.001,-.001),(.001,-.001),(.001,.001),(-.001,.001)],'alloy',48,'z')
for i in range(6):
    x=-.029+i*.0116
    group('Button'+str(i),(x,.065,.040),lambda x=x: m.box('SixPositionButton',(x,.065,.040),(.008,.007,.004),'rubber',.0015))
for i,(x,y) in enumerate([(-.081,.092),(-.066,.095),(-.080,.073),(-.094,.065),(.066,.095),(.081,.092),(.080,.073),(.094,.065)]):
    m.rod('SwitchSocket',(x,y,.029),(x,y,.040),.0045,'alloy',segs=32)
    def switch(x=x,y=y):
        m.rod('SwitchLever',(x,y,.039),(x,y+.012,.063),.0015,'alloy',segs=24)
        m.rod('SwitchTip',(x,y+.010,.061),(x,y+.014,.068),.0023,'white',segs=24)
    group('Switch'+str(i),(x,y,.039),switch)
for i in range(6):
    y=-.036-i*.008
    m.box('MenuKey',(-.066,y,.038),(.009,.005,.005),'rubber',.001)
m.rod('ScrollWheel',(.066,-.055,.037),(.066,-.055,.046),.008,'alloy',segs=48)
for i in range(15):
    a=i*2*math.pi/15
    m.rod('EncoderKnurl',(.066+math.cos(a)*.008,-.055+math.sin(a)*.008,.038),(.066+math.cos(a)*.008,-.055+math.sin(a)*.008,.045),.0006,'dark',segs=6)
for i in range(5):
    m.box('SpeakerSlot',(-.013+i*.006,.048,.036),(.002,.015,.001),'rubber',.0004)
m.tube('CarryHandle',[(-.060,.080,-.040),(-.062,.106,-.047),(-.050,.119,-.047),(.050,.119,-.047),(.062,.106,-.047),(.060,.080,-.040)],.004,'alloy',steps=8,segs=16)
m.rod('AntennaHinge',(0,.087,-.015),(0,.098,-.015),.009,'rubber',segs=40)
m.rod('Antenna',(0,.096,-.015),(0,.177,-.025),.0058,'rubber',r2=.0038,segs=32)
m.box('RearBatteryCover',(0,-.050,-.036),(.118,.082,.004),'shell',.004)
m.box('RearModuleBay',(0,.035,-.037),(.050,.052,.008),'rubber',.002)
for x,y in [(-.07,-.080),(.07,-.080),(-.076,.075),(.076,.075)]: m.screw('HousingScrew',(x,y,.032),.0013,'z')

lines=['#usda 1.0','( defaultPrim = "Transmitter"; metersPerUnit = 1; upAxis = "Y" )',
       'def Xform "Transmitter" (kind = "component") {','def Scope "Materials" {']
for mat in sorted({p['material'] for p in m.parts}):
    color,rough,metal=COLORS[mat]; rgb=[int(color[k:k+2],16)/255 for k in [1,3,5]]
    rgb=[v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in rgb]
    prefix='/Transmitter/Materials/'+mat
    lines += [f'def Material "{mat}" {{',f'token outputs:surface.connect = <{prefix}/Surface.outputs:surface>',
              'def Shader "Surface" { uniform token info:id = "UsdPreviewSurface"',f'color3f inputs:diffuseColor = {tup(rgb)}',
              f'float inputs:roughness = {rough}',f'float inputs:metallic = {metal}','token outputs:surface']
    if mat in TEXTURES:
        tex,alpha,_=TEXTURES[mat]
        lines += [f'color3f inputs:diffuseColor.connect = <{prefix}/Texture.outputs:rgb>']
        if alpha:lines += [f'float inputs:opacity.connect = <{prefix}/Texture.outputs:a>','float inputs:opacityThreshold = 0.05']
        lines += ['}', 'def Shader "UV" {', 'uniform token info:id = "UsdPrimvarReader_float2"', 'string inputs:varname = "st"', 'float2 outputs:result', '}',
                  'def Shader "Texture" { uniform token info:id = "UsdUVTexture"',f'asset inputs:file = @textures/{tex}@',
                  'token inputs:sourceColorSpace = "sRGB"',f'float2 inputs:st.connect = <{prefix}/UV.outputs:result>',
                  'token inputs:wrapS = "repeat"', 'token inputs:wrapT = "repeat"', 'float3 outputs:rgb', 'float outputs:a', '}']
    else:lines+=['}']
    lines+=['}']
lines+=['}','def Xform "Geometry" {']
for group_name in [None]+list(rigs):
    origin=rigs.get(group_name,(0,0,0))
    if group_name:lines += [f'def Xform "{group_name}" {{',f'double3 xformOp:translate = {tup(origin)}','float3 xformOp:rotateXYZ = (0,0,0)','uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateXYZ"]']
    for p in [p for p in m.parts if p['group']==group_name]:
        pts=[sub(v,origin) for v in p['points']]
        lines += [f'def Mesh "{p["name"]}" (prepend apiSchemas = ["MaterialBindingAPI"]) {{',
                  'uniform token subdivisionScheme = "none"',f'point3f[] points = [{", ".join(tup(v) for v in pts)}]',
                  f'int[] faceVertexCounts = {array([3]*len(p["faces"]))}', f'int[] faceVertexIndices = {array([v for f in p["faces"] for v in f])}',
                  f'normal3f[] normals = [{", ".join(tup(v) for v in p["normals"])}] (interpolation = "{p["interpolation"]}")',
                  f'rel material:binding = </Transmitter/Materials/{p["material"]}>']
        if p['material'] in TEXTURES:
            uv=[]
            for f in p['faces']:
                if 'uv' in p:uv.extend(p['uv'][i] for i in f)
                else:uv.extend((p['points'][i][0]*35,p['points'][i][1]*35) for i in f)
            lines += [f'texCoord2f[] primvars:st = [{", ".join(tup(v) for v in uv)}] (interpolation = "faceVarying")']
        lines+=['}']
    if group_name:lines+=['}']
lines+=['}','}']
source=OUT/'RadioMasterTX16S.usda';source.write_text('\n'.join(lines)+'\n')
def run(args):
    p=subprocess.run(list(map(str,args)),capture_output=True,text=True)
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)
    return p.stdout+p.stderr
with tempfile.TemporaryDirectory(prefix='uavsim-transmitter-') as tmp:
    tmp=Path(tmp);binary=tmp/'RadioMasterTX16S.usdc'
    run(['/usr/bin/usdcat',source,'-o',binary]);shutil.copytree(TEX,tmp/'textures')
    run(['/usr/bin/usdzip','--arkitAsset',binary,RESOURCE])
report=run(['/usr/bin/usdchecker','--arkit',RESOURCE]);(OUT/'validation.txt').write_text(report)
(OUT/'manifest.json').write_text(json.dumps(dict(source='Original approximate exterior, not scanned CAD',
    reference='https://www.radiomasterrc.com/products/tx16s-mark-ii-radio-controller',
    pivots=rigs, meshes=len(m.parts),triangles=sum(len(p['faces']) for p in m.parts),file=str(RESOURCE.relative_to(ROOT))),indent=2)+'\n')
print(f'{RESOURCE}: {len(m.parts)} meshes, {sum(len(p["faces"]) for p in m.parts)} triangles; USD validation passed')
