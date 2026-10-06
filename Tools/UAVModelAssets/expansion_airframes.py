"""Reference-shaped exterior meshes for the thirty-model expansion.

Metres, +Y up, +Z nose. Rounded shells, skins, control-surface divisions,
hardware and optical assemblies are cosmetic reconstructions from public views.
No manufacturing dimensions or flight-performance geometry is implied.
"""
from math import sin, cos, pi, sqrt
from geometry import Model, COLORS, TEXTURES, add, sub, mul, mix, unit, spline
import json

COLORS.update({
    'paint_white': ('#dedfdc', .48, .02),
    'paint_gray': ('#a9b0b4', .49, .04),
    'paint_sand': ('#c5bda5', .59, .01),
    'mini_shell': ('#969c9c', .50, .02),
    'avata_shell': ('#747c7e', .57, .01),
    'autel_shell': ('#989e9e', .49, .04),
    'ray_orange': ('#f17e0c', .46, .01),
    'epp_black': ('#303232', .92, .0),
    'epp_gray': ('#babcb9', .92, .0),
    'optical_blue': ('#1a5065', .08, .57),
    'thermal_glass': ('#493c31', .15, .65),
    'anodized': ('#3b444a', .27, .70),
    'edge_seam': ('#485056', .64, .05),
    'prop_tip': ('#d3a36b', .53, .02),
    'label_black': ('#181b1c', .53, .0),
})
TEXTURES['carbon'] = ('carbon.png', False, 70)
TEXTURES['epp_black'] = ('epp-black.png', False, 16)
TEXTURES['epp_gray'] = ('epp-gray.png', False, 16)


class ExteriorModel(Model):
    def __init__(self,ident,name):
        super().__init__(ident,name)
        self.rigs=[]

    def rig(self,name,center,axis,parts,amplitude,role):
        names=[p['name'] for p in parts if not p['group']]
        if names:
            self.rigs.append(dict(name=name,center=center,axis=axis,parts=names,
                                  amplitude_degrees=amplitude,role=role))

    def scale(self,factors):
        super().scale(factors)
        for rig in self.rigs:
            rig['center']=tuple(rig['center'][i]*factors[i] for i in range(3))

    def write(self,path,metadata):
        # The base exporter authors rotor hierarchies. Other articulated meshes
        # get their own local-space pivots without changing the source geometry.
        rig_by_part={name:r for r in self.rigs for name in r['parts']}
        saved={}
        for part in self.parts:
            if part['name'] in rig_by_part:
                saved[part['name']]=part['points']
                part['points']=[sub(q,rig_by_part[part['name']]['center']) for q in part['points']]
        try:
            super().write(path,metadata)
        finally:
            for part in self.parts:
                if part['name'] in saved:part['points']=saved[part['name']]
        lines=path.read_text().splitlines();kept=[];blocks={};i=0
        while i<len(lines):
            line=lines[i]
            if line.startswith('            def Mesh "'):
                name=line.split('"')[1];block=[line];i+=1
                while i<len(lines):
                    block.append(lines[i]);i+=1
                    if block[-1]=='            }':break
                if name in rig_by_part:blocks[name]=block
                else:kept.extend(block)
            else:kept.append(line);i+=1
        end=720 if self.transition else 120;insert=[]
        for rig in self.rigs:
            axis=rig['axis'].upper();op='xformOp:rotate'+axis
            center='('+', '.join(f'{v:.9g}' for v in rig['center'])+')'
            samples=', '.join(f'{t}: {rig["amplitude_degrees"]*sin(2*pi*t/end):.9g}' for t in range(end+1))
            insert += [f'        def Xform "{rig["name"]}"','        {',
                       f'            double3 xformOp:translate = {center}',
                       f'            float {op} = 0',f'            float {op}.timeSamples = {{{samples}}}',
                       f'            uniform token[] xformOpOrder = ["xformOp:translate", "{op}"]',
                       f'            custom string componentRole = {json.dumps(rig["role"])}']
            for name in rig['parts']:insert.extend(blocks[name])
            insert.append('        }')
        at=kept.index('    def Xform "Geometry"')+2
        kept[at:at]=insert
        path.write_text('\n'.join(kept)+'\n')

    def loft(self, name, sections, material='paint_gray', exponent=2.4, cx=0):
        """Superelliptic molded shell. Sections are z, half-width, half-height, y."""
        rings = spline(sections, 9)
        points = []
        segs = 64
        for z, rx, ry, cy in rings:
            for i in range(segs):
                a = 2*pi*i/segs
                x, y = cos(a), sin(a)
                x = (1 if x >= 0 else -1)*abs(x)**(2/exponent)
                y = (1 if y >= 0 else -1)*abs(y)**(2/exponent)
                points.append((cx+max(rx, .000001)*x, cy+max(ry, .000001)*y, z))
        faces = []
        for j in range(len(rings)-1):
            for i in range(segs):
                k = (i+1) % segs
                faces.append((j*segs+i, j*segs+k, (j+1)*segs+k, (j+1)*segs+i))
        faces += [tuple(range(segs-1, -1, -1)),
                  tuple((len(rings)-1)*segs+i for i in range(segs))]
        self.mesh(name, points, faces, material, True)

    def skin(self, point, hosts, axis='y'):
        return self.surface_point(point, hosts, axis)

    def skin_line(self, name, points, hosts, radius, material='edge_seam', axis='y', closed=False):
        fitted = []
        for p in points:
            try:
                fitted.append(self.skin(p, hosts, axis))
            except ValueError:
                continue
        if len(fitted) > 1:
            self.tube(name, fitted, radius, material, closed=closed, steps=1, segs=8)

    def hatch(self, hosts, x, z, width, length, scale, material=None):
        # Seams and fasteners intersect the host skin rather than hovering over it.
        outline = [(x-width/2, scale, z-length/2), (x+width/2, scale, z-length/2),
                   (x+width/2, scale, z+length/2), (x-width/2, scale, z+length/2)]
        self.skin_line('AccessPanelSeam', outline, hosts, scale*.0007, closed=True)
        for sx in (-1, 1):
            for sz in (-1, 1):
                q = (x+sx*width*.39, scale, z+sz*length*.39)
                try:
                    self.screw('QuarterTurnFastener', q, scale*.0017, hosts=hosts)
                except ValueError:
                    pass
        if material:
            self.surface_patch('AccessPanelFinish', outline, hosts, material)

    def lens(self, name, center, radius, axis='z', thermal=False):
        vector = (0, 1, 0) if axis == 'y' else (0, -1, 0) if axis == '-y' else (0, 0, 1)
        ring_axis = 'y' if axis in ('y', '-y') else 'z'
        self.rod(name+'Socket', sub(center, mul(vector, radius*.30)),
                 add(center, mul(vector, radius*.04)), radius*1.13, 'rubber', segs=48)
        profile = [(radius*.085*cos(a*2*pi/10), radius*.085*sin(a*2*pi/10)) for a in range(10)]
        self.profiled_ring(name+'Bezel', center, radius*.98, profile, 'anodized', 80, axis=ring_axis)
        self.rod(name+'CoatedGlass', sub(center, mul(vector, radius*.02)),
                 add(center, mul(vector, radius*.022)), radius*.89,
                 'thermal_glass' if thermal else 'glass', segs=64)
        self.profiled_ring(name+'CoatingRim', add(center, mul(vector, radius*.024)), radius*.77,
                           [(radius*.018*cos(a*2*pi/8), radius*.012*sin(a*2*pi/8)) for a in range(8)],
                           'optical_blue', 64, axis=ring_axis)


def drive(m, center, radius, prop_radius, index, axis='y', blades=2, angle=.30, tips=False, rear=False):
    """Exterior motor, bell, bearings, hub bolts and an individually rigged propeller."""
    v = (0, 1, 0) if axis == 'y' else (0, 0, 1)
    if rear:v=mul(v,-1)
    m.rod('MotorStatorCase', sub(center, mul(v, radius*1.35)), sub(center, mul(v, radius*.25)),
          radius, 'anodized', segs=48)
    m.rod('MotorBell', sub(center, mul(v, radius*.30)), add(center, mul(v, radius*.05)),
          radius*1.03, 'black', segs=48)
    for offset in (-.95, -.75, -.55):
        m.profiled_ring('MotorCoolingRib', add(center, mul(v, radius*offset)), radius*.99,
                       [(radius*.035*cos(a*2*pi/8), radius*.035*sin(a*2*pi/8)) for a in range(8)],
                       'anodized', 48, axis=axis)
    m.rod('MotorShaft', sub(center, mul(v, radius*.35)), add(center, mul(v, radius*.18)),
          radius*.19, 'metal', segs=32)
    start = len(m.parts)
    group = f'Rotor_{index:02}' if axis == 'y' else f'Propeller_{index:02}'
    direction=(-1 if center[0]*center[2]<0 else 1) if axis=='y' else (-1 if index%2 else 1)
    m.prop(group, center, prop_radius, axis=axis, blades=blades, angle=angle,
           mat='black', direction=direction)
    for j in range(blades):
        a = angle+2*pi*j/blades
        q = (cos(a)*radius*.45, radius*.07, sin(a)*radius*.45)
        if axis == 'z':
            q = (q[0], q[2], q[1])
        m.screw('PropellerRootBolt', add(center, q), radius*.085, axis=axis, group=group)
    if tips:
        for part in list(m.parts[start:]):
            if not part['name'].startswith('Blade_'):
                continue
            radial_axes = (0, 2) if axis == 'y' else (0, 1)
            tip_faces = []
            retained = []
            for face in part['faces']:
                target = tip_faces if all(sqrt(sum((part['points'][i][k]-center[k])**2
                                                   for k in radial_axes)) > prop_radius*.90 for i in face) else retained
                target.append(face)
            if tip_faces:
                part['faces'] = retained
                copy = dict(part, name=part['name'].replace('Blade_', 'BladeTip_'),
                            faces=tip_faces, material='prop_tip')
                m.parts.append(copy)


def fin(m, name, x, y, z, height, chord, paint, cant=0, sweep=.32):
    outline = [(x, y, z+chord*.48), (x, y, z-chord*.52),
               (x+cant*height, y+height, z-chord*.30),
               (x+cant*height, y+height, z+chord*(.48-sweep))]
    thickness = max(abs(height)*.032, .001)
    m.plate(name, outline, thickness, paint, axis=(1, 0, 0))
    # Rudder hinge and a visible actuator access cover.
    q = [(x+thickness*.49+cant*height*.08, y+height*.08, z-chord*.31),
         (x+cant*height*.83+thickness*.49, y+height*.83, z-chord*.24)]
    m.tube(name+'RudderHinge', q, abs(height)*.004, 'edge_seam', steps=1, segs=8)


def wing_pair(m, stations, paint, name='MainWing', controls=True):
    for side, suffix in [(-1, 'Left'), (1, 'Right')]:
        host = name+suffix
        m.wing(host, stations, paint, side)
        if not controls:
            continue
        scale = stations[-1][0]*2
        # Interpolate the actual station contour for inboard flap/elevon seams.
        for first, last in [(.18, .50), (.56, .90)]:
            line = []
            for j in range(15):
                xx = stations[-1][0]*(first+(last-first)*j/14)
                for a, b in zip(stations, stations[1:]):
                    if a[0] <= xx <= b[0]:
                        u = (xx-a[0])/max(b[0]-a[0], 1e-12)
                        st = mix(a, b, u)
                        line.append((side*xx, scale, st[2]+(st[1]-st[2])*.22))
                        break
            m.skin_line('ControlSurfaceHinge', line, [host], scale*.00042)
        for fraction in (.22, .51, .89):
            xx = stations[-1][0]*fraction
            for a, b in zip(stations, stations[1:]):
                if a[0] <= xx <= b[0]:
                    st = mix(a, b, (xx-a[0])/max(b[0]-a[0], 1e-12))
                    m.hatch([host], side*xx, st[2]+(st[1]-st[2])*.37,
                            scale*.025, (st[1]-st[2])*.10, scale)
                    break


def small_camera(m, center, size, lenses=2, mount=None):
    start=len(m.parts)
    m.camera(center, size, lenses=lenses, mat='anodized', ball=True, mount=mount)
    moving=[p for p in m.parts[start:] if p['name'].startswith(('SensorTurret_','LensRim_',
             'OpticalBezel_','OpticalGlass_'))]
    m.rig('CameraGimbal',center,'y',moving,12,'camera')


def fuselage_details(m, L, hosts=['Fuselage'], paint='paint_gray'):
    m.hatch(hosts, 0, L*.19, L*.060, L*.085, L)
    m.hatch(hosts, 0, -L*.04, L*.050, L*.13, L)
    # Panel junctions and exterior cooling slots fitted to the shell.
    for z in (-L*.15, L*.28):
        coords = [(-L*.045+i*L*.09/18, L, z) for i in range(19)]
        m.skin_line('FuselagePanelJoint', coords, hosts, L*.0005)
    for side in (-1, 1):
        for j in range(8):
            x = side*L*.021
            zz = -L*.03+j*L*.006
            m.skin_line('CoolingGrille', [(x-L*.003, L, zz), (x+L*.003, L, zz)], hosts, L*.0009)
    for z in (L*.08, -L*.10):
        try:
            p = m.skin((0, L, z), hosts)
        except ValueError:
            continue
        m.rod('CommunicationAntenna', p, add(p, (0, L*.045, -.012*L)), L*.0016, 'black', segs=16)
        m.ellipsoid('AntennaFoot', p, (L*.007, L*.004, L*.011), paint, 24, 12)


def label(m, ident, x, z, width, length, height):
    try:
        m.decal(ident, (x, height, z), width, length)
    except ValueError:
        pass


def mini5(m):
    m.loft('Fuselage', [(-.073,.016,.017,.016), (-.064,.028,.022,.019),
           (-.026,.031,.025,.019), (.021,.029,.022,.020), (.048,.025,.019,.019),
           (.059,.017,.017,.017)], 'mini_shell', 3.2)
    m.loft('BatteryPack', [(-.074,.015,.015,.016),(-.064,.025,.020,.018),
           (-.027,.026,.020,.019)], 'mini_shell', 3.0)
    for side in (-1,1):
        for front in (True,False):
            index = (1 if side<0 else 3)+(0 if front else 1)
            root=(side*.022,.012 if front else .025,.039 if front else -.048)
            tip=(side*(.119 if front else .109),.010 if front else .028,.081 if front else -.079)
            m.beam('FoldingArm',root,tip,.010,.008,'mini_shell',.002)
            m.rod('ArmHingePin',add(root,(0,-.004,0)),add(root,(0,.005,0)),.006,'mini_shell',segs=40)
            m.screw('ArmHingeBolt',add(root,(0,.006,0)),.0014)
            m.loft('MotorFairing',[(tip[2]-.011,.006,.005,tip[1]-.004),
                   (tip[2],.008,.006,tip[1]-.001),(tip[2]+.010,.005,.004,tip[1]-.003)],
                   'mini_shell',2.6,cx=tip[0])
            center=add(tip,(0,.008,0))
            drive(m,center,.0072,.071,index,angle=(.32 if front else -.32)*side,tips=True)
            if front:
                foot=(tip[0],-.030,tip[2])
                m.beam('FrontLandingAntenna',add(tip,(0,-.004,0)),foot,.007,.007,'mini_shell',.002)
                m.box('FootPad',foot,(.009,.003,.009),'rubber',.001)
            else:
                m.box('RearArmIndicator',add(tip,(-side*.007,0,-.001)),(.003,.003,.004),'led_green',.0006)
    # Recessed front sensor fascia and the three-axis camera yoke.
    m.box('NoseSensorFascia',(0,.019,.058),(.045,.020,.008),'black',.004)
    for side in (-1,1):
        m.lens('ForwardVision',(side*.019,.019,.062),.0051)
        m.ellipsoid('UpwardVisionSocket',(side*.024,.035,.030),(.007,.004,.009),'black',32,16)
        m.lens('UpwardVision',(side*.024,.037,.030),.0040,'y')
        m.lens('RearVision',(side*.017,.026,-.071),.0045)
        m.lens('DownwardVision',m.skin((side*.014,-.2,.026),['Fuselage']),.0034,'-y')
        m.box('BatteryLatch',(side*.029,.014,-.025),(.003,.009,.015),'edge_seam',.001)
    m.box('ForwardLiDAR',(0,.030,.061),(.012,.007,.004),'glass',.0013)
    for j in range(8):
        m.box('NoseVent',( -.009+j*.0026,.013,.062),(.0010,.008,.002),'edge_seam',.0002)
    m.box('GimbalBase',(0,-.002,.049),(.028,.008,.028),'anodized',.003)
    m.beam('GimbalRollArm',(0,-.003,.047),(0,-.023,.067),.012,.008,'anodized',.002)
    for side in (-1,1):
        m.beam('GimbalCrossSupport',(side*.011,-.004,.055),(side*.018,-.010,.065),.004,.004,'anodized',.001)
        m.beam('GimbalPitchYoke',(side*.018,-.009,.065),(side*.018,-.029,.075),.005,.006,'anodized',.001)
        m.rod('GimbalPitchBearing',(side*.012,-.027,.075),(side*.021,-.027,.075),.0048,'metal',segs=40)
    m.box('CameraHousing',(0,-.027,.075),(.029,.025,.024),'black',.005)
    m.box('CameraFrontFrame',(0,-.027,.088),(.025,.022,.004),'anodized',.003)
    m.lens('MainCamera',(0,-.027,.091),.0092)
    m.lens('BellyInfrared',m.skin((0,-.2,-.013),['Fuselage']),.004,'-y')
    m.box('AuxiliaryLight',(0,-.006,-.034),(.009,.002,.007),'label',.001)
    m.hatch(['Fuselage','BatteryPack'],0,-.045,.025,.028,.14)
    p=m.skin((0,.15,-.047),['BatteryPack'])
    m.rod('PowerButton',sub(p,(0,.0005,0)),add(p,(0,.0007,0)),.0032,'edge_seam',segs=32)
    for j in range(4):
        q=m.skin((-.005+j*.0035,.15,-.056),['BatteryPack'])
        m.box('BatteryLevelLED',q,(.002,.001,.0009),'led_green',.0002)
    m.box('RearUSBPort',(0,.012,-.074),(.008,.003,.001),'black',.0007)
    m.box('MicroSDSlot',(.012,.012,-.072),(.006,.001,.002),'black',.0003)
    label(m,m.id,0,-.008,.024,.010,.2)
    m.rig('CameraPitch',(0,-.027,.075),'x',[p for p in m.parts if p['name'].startswith(
          ('CameraHousing_','CameraFrontFrame_','MainCamera'))],9,'camera')


def avata2(m):
    # Four low, molded guards; front/rear centres are closer than left/right.
    centers=[(side*.063,0,end*.049) for side in (-1,1) for end in (-1,1)]
    for i,c in enumerate(centers,1):
        m.profiled_ring('MoldedPropellerGuard',c,.0410,
            [(-.0018,-.0058),(.0013,-.006),(.0020,-.003),(.0018,.0048),
             (.0007,.0072),(-.0015,.006),(-.0021,.003),(-.0021,-.003)],'avata_shell',128)
        for a in (pi/4,pi*3/4,pi*5/4,pi*7/4):
            start=add(c,(cos(a)*.006,-.0045,sin(a)*.006))
            end=add(c,(cos(a)*.041,-.0045,sin(a)*.041))
            m.beam('GuardMotorSpoke',start,end,.0033,.003,'avata_shell',.0007)
        m.rod('MotorPedestal',add(c,(0,-.007,0)),add(c,(0,.001,0)),.008,'avata_shell',segs=40)
        drive(m,add(c,(0,.003,0)),.0055,.0385,i,blades=3,angle=.25*i)
        m.screw('MotorSpokeFastener',add(c,(0,-.007,0)),.0012,facing=-1)
    m.loft('Fuselage',[(-.088,.017,.010,.003),(-.063,.025,.014,.009),
           (-.017,.022,.022,.017),(.022,.018,.024,.019),(.060,.017,.013,.013),
           (.079,.015,.010,.010)],'avata_shell',3.5)
    # The tall battery runs along the centre, with a front camera in its recess.
    m.loft('BatteryPack',[(-.081,.014,.017,.024),(-.067,.020,.024,.027),
           (-.012,.019,.026,.027),(.038,.016,.024,.025),(.049,.012,.017,.019)],
           'avata_shell',3.4)
    for side in (-1,1):
        for end in (-1,1):
            m.beam('GuardFrameBridge',(side*.018,.002,end*.046),(side*.058,-.003,end*.049),
                   .016,.005,'avata_shell',.0015)
        m.box('CameraShockPad',(side*.020,.004,.069),(.005,.024,.018),'orange',.0015)
        m.rod('CameraPitchPivot',(side*.015,.006,.071),(side*.022,.006,.071),.0046,'anodized',segs=40)
        m.box('BatteryRelease',(side*.022,.018,-.050),(.004,.010,.013),'black',.001)
        m.lens('DownwardFisheye',m.skin((side*.014,-.2,-.033),['Fuselage']),.004,'-y')
    m.box('CameraHousing',(0,.006,.073),(.032,.027,.025),'black',.004)
    m.lens('FPVCamera',(0,.006,.088),.0101)
    m.box('CameraUpperCoolingBlock',(0,.025,.062),(.025,.009,.023),'anodized',.002)
    for j in range(12):
        m.box('CameraCoolingFin',(-.0105+j*.0019,.028,.064),(.00065,.010,.018),'anodized',.0002)
    m.hatch(['BatteryPack'],0,.012,.022,.039,.15)
    for side in (-1,1):
        m.lens('RearFisheye',(side*.013,.019,-.082),.0038)
    m.box('BellyInfrared',m.skin((0,-.2,-.049),['Fuselage']),(.007,.0015,.008),'glass',.001)
    p=m.skin((0,.2,-.057),['BatteryPack'])
    m.rod('PowerButton',sub(p,(0,.0004,0)),add(p,(0,.0007,0)),.0033,'edge_seam',segs=40)
    for j in range(4):
        q=m.skin((-.005+j*.0034,.2,-.045),['BatteryPack'])
        m.box('BatteryLevelLED',q,(.0019,.0009,.001),'led_green',.0002)
    m.box('RearStatusLED',(0,.012,-.088),(.009,.003,.001),'led_green',.0005)
    m.box('USBPort',(.010,.006,-.087),(.008,.003,.002),'black',.0007)
    m.box('CardSlot',(-.011,.006,-.087),(.007,.0015,.002),'black',.0003)
    label(m,m.id,0,-.012,.018,.009,.2)
    m.rig('CameraPitch',(0,.006,.073),'x',[p for p in m.parts if p['name'].startswith(
          ('CameraHousing_','FPVCamera'))],10,'camera')


def autel(m):
    m.loft('Fuselage',[(-.133,.023,.019,.030),(-.115,.050,.028,.032),
           (-.025,.059,.034,.033),(.077,.052,.033,.032),(.112,.042,.024,.028)],
           'autel_shell',3.1)
    m.loft('BatteryPack',[(-.136,.026,.021,.035),(-.112,.049,.030,.041),
           (-.022,.049,.030,.041),(.041,.043,.023,.039)],'autel_shell',3.4)
    for side in (-1,1):
        for front in (True,False):
            index=(1 if side<0 else 3)+(0 if front else 1)
            c=(side*(.191 if front else .155),.025 if front else .056,.119 if front else -.134)
            root=(side*.049,.027 if front else .045,.069 if front else -.083)
            m.beam('FoldableMotorArm',root,c,.014,.017,'autel_shell',.003)
            m.rod('ArmHinge',add(root,(0,-.008,0)),add(root,(0,.009,0)),.010,'autel_shell',segs=40)
            m.screw('ArmHingeBolt',add(root,(0,.010,0)),.0022)
            drive(m,add(c,(0,.013,0)),.013,.1397,index,angle=.19*side,tips=False)
            m.profiled_ring('MotorWarningRing',add(c,(0,.010,0)),.0132,
                             [(.0003,-.0007),(.0003,.0007),(-.0003,.0007),(-.0003,-.0007)],'red',64)
            if front:
                m.beam('LandingLeg',c,(c[0],-.077,c[2]-.003),.009,.011,'autel_shell',.002)
                m.box('LegRubberFoot',(c[0],-.078,c[2]-.003),(.013,.004,.019),'rubber',.001)
        m.ellipsoid('ForwardVisionSocket',(side*.038,.026,.111),(.009,.010,.006),'edge_seam',32,16)
        m.lens('ForwardVision',(side*.038,.027,.116),.0057)
        m.profiled_ring('SensorOrangeTrim',(side*.038,.027,.116),.0064,
                         [(.00035*cos(j*2*pi/8),.00035*sin(j*2*pi/8)) for j in range(8)],'orange',64,axis='z')
        m.lens('TopVision',(side*.025,.067,.006),.0051,'y')
        m.lens('BottomVision',m.skin((side*.022,-.5,-.019),['Fuselage']),.0044,'-y')
        m.box('BatteryRelease',(side*.050,.023,-.079),(.004,.019,.026),'edge_seam',.001)
    m.box('GimbalIsolationMount',(0,-.007,.071),(.052,.012,.055),'anodized',.004)
    for side in (-1,1):
        m.beam('GimbalYoke',(side*.023,-.010,.065),(side*.029,-.040,.092),.008,.009,'anodized',.002)
        m.rod('CameraTiltBearing',(side*.026,-.041,.098),(side*.035,-.041,.098),.008,'metal',segs=40)
    camera_start=len(m.parts)
    m.box('Fusion4TCamera',(0,-.042,.099),(.064,.050,.041),'autel_shell',.009)
    m.box('Fusion4TFace',(0,-.042,.122),(.058,.044,.007),'anodized',.005)
    m.lens('ZoomCamera',(-.014,-.050,.127),.011)
    m.lens('ThermalCamera',(.015,-.050,.127),.0075,thermal=True)
    m.lens('WideCamera',(.015,-.029,.127),.0065)
    m.box('LaserRangefinder',(-.013,-.028,.127),(.021,.011,.004),'glass',.002)
    for sx in (-1,1):
        for sy in (-1,1):
            m.screw('CameraCaseBolt',(sx*.024,-.042+sy*.016,.126),.0013,axis='z',hosts=['Fusion4TFace'])
    camera_end=len(m.parts)
    m.ellipsoid('GNSSAntenna',(0,.071,-.079),(.007,.004,.007),'yellow',32,16)
    m.hatch(['Fuselage','BatteryPack'],0,-.049,.068,.079,.6)
    for j in range(4):
        q=m.skin((-.009+j*.006,.5,-.100),['BatteryPack'])
        m.box('BatteryLevelLED',q,(.003,.0014,.0015),'led_green',.0003)
    p=m.skin((0,.5,-.088),['BatteryPack'])
    m.rod('PowerButton',sub(p,(0,.001,0)),add(p,(0,.001,0)),.005,'edge_seam',segs=40)
    fuselage_details(m,.28,['Fuselage','BatteryPack'],'autel_shell')
    label(m,m.id,0,.028,.054,.022,.5)
    m.rig('CameraPitch',(0,-.042,.099),'x',m.parts[camera_start:camera_end],8,'camera')


def ray(m,p):
    W,L=p['wingspan_m'],p['length_m']
    orange='ray_orange'
    wing_pair(m,[(0,.22,-.30,0,.072),(.16,.21,-.29,0,.065),
              (.48,.195,-.257,0,.044),(.605,.175,-.211,.0,.023),(.625,.141,-.19,0,.015)],orange)
    m.loft('Fuselage',[(-.334,.021,.025,0),(-.29,.078,.044,-.005),(-.08,.105,.060,0),
           (.19,.089,.056,0),(.27,.066,.044,0),(.334,.008,.010,0)],orange,2.1)
    m.loft('NoseCover',[(.155,.082,.055,.000),(.22,.076,.050,0),
           (.29,.052,.035,0),(.335,.007,.007,0)],'black',2.0)
    for side in (-1,1):
        host='MainWing'+('Left' if side<0 else 'Right')
        # Dark trailing corners, using split host triangles, preserve the curved skin.
        m.surface_patch('TrailingBlackPanel',[(side*.24,0,-.224),(side*.615,0,-.147),
                         (side*.615,0,-.248),(side*.45,0,-.28)], [host], 'black')
        x=side*.286
        m.loft('MotorNacelle',[(.066,.025,.026,.018),(.160,.029,.035,.018),
               (.221,.022,.025,.018)],orange,2.6,cx=x)
        m.rod('MotorMount',(x,.018,.182),(x,.018,.234),.018,'anodized',segs=48)
        drive(m,(x,.018,.252),.015,.137,1 if side<0 else 2,axis='z',blades=2,angle=.16)
        # Actual tailsitter contact rods extend from the trailing wing corners.
        root=(side*.589,0,-.206)
        m.rod('LandingRod',root,(side*.604,0,-.372),.0045,'carbon',segs=24)
        m.rod('LandingRodSocket',add(root,(0,0,.020)),add(root,(0,0,-.020)),.009,'orange',segs=32)
        label(m,m.id+('-left' if side<0 else '-right'),side*.391,-.133,.215,.048,.5)
    # Ventral removable MAP61 fairing and camera, not a guessed LiDAR configuration.
    m.loft('PayloadFairing',[(-.26,.032,.020,-.043),(-.13,.071,.032,-.051),
           (.12,.067,.033,-.050),(.21,.037,.024,-.041)],'anodized',2.7)
    m.lens('MappingCamera',(0,-.082,.042),.026,'-y')
    m.hatch(['Fuselage'],0,-.085,.095,.25,L)
    m.skin_line('PayloadBaySeam',[(-.045,-L,-.16),(.045,-L,-.16),(.045,-L,.13),(-.045,-L,.13)],
                ['PayloadFairing'],.0009,closed=True)
    fin(m,'LandingFin',0,-.045,-.255,-.17,.18,'black',sweep=.60)
    m.lens('NoseObstacleSensor',(0,0,.331),.009)
    for z in (-.14,-.29):
        q=m.skin((0,L,z),['Fuselage'])
        m.ellipsoid('HatchLatch',q,(.009,.003,.012),'black',24,12)
    m.skin_line('CentreHatchJoint',[(0,L,-.25),(0,L,.13)],['Fuselage'],.0009)


def flying_wing(m,p):
    W,L=p['wingspan_m'],p['length_m'];kind=p['layout'];paint=p['shape']['paint']
    if kind=='ebee':
        stations=[(0,L*.30,-L*.19,0,L*.14),(W*.12,L*.29,-L*.18,0,L*.12),
                  (W*.29,L*.17,-L*.39,.005*L,L*.075),(W*.47,-L*.10,-L*.46,L*.065,L*.03),
                  (W*.5,-L*.15,-L*.42,L*.10,L*.018)]
    elif kind=='ux11':
        stations=[(0,L*.29,-L*.19,0,L*.11),(W*.12,L*.23,-L*.16,0,L*.095),
                  (W*.37,-L*.04,-L*.40,L*.015,L*.04),(W*.49,-L*.22,-L*.45,L*.035,L*.025),
                  (W*.5,-L*.23,-L*.43,L*.040,L*.018)]
    elif kind=='bramor':
        stations=[(0,L*.22,-L*.31,0,L*.12),(W*.12,L*.17,-L*.30,0,L*.09),
                  (W*.37,-L*.02,-L*.42,L*.01,L*.045),(W*.5,-L*.17,-L*.46,L*.025,L*.018)]
    elif kind=='orbiter':
        if p['shape'].get('revision')==4:
            stations=[(0,L*.25,-L*.31,0,L*.17),(W*.13,L*.16,-L*.29,0,L*.13),
                      (W*.36,-L*.055,-L*.42,L*.01,L*.055),(W*.5,-L*.20,-L*.47,L*.026,L*.024)]
        else:
            stations=[(0,L*.21,-L*.32,0,L*.15),(W*.13,L*.14,-L*.28,0,L*.12),
                      (W*.36,-L*.07,-L*.38,L*.014,L*.050),(W*.5,-L*.18,-L*.43,L*.028,L*.025)]
    else:  # DeltaQuad Evo, broad blended wing with anhedral tip panels.
        stations=[(0,L*.39,-L*.44,0,L*.16),(W*.13,L*.34,-L*.41,0,L*.13),
                  (W*.37,L*.10,-L*.45,L*.01,L*.08),(W*.47,-L*.11,-L*.48,-L*.026,L*.045),
                  (W*.5,-L*.20,-L*.47,-L*.085,L*.02)]
    wing_pair(m,stations,paint)
    width=L*(.18 if kind=='deltaquad' else .10 if kind=='ebee' else .12)
    if kind=='orbiter' and p['shape'].get('revision')==4:width=L*.155
    m.loft('Fuselage',[(-L*.36,width*.20,L*.03,0),(-L*.23,width*.83,L*.078,.006*L),
           (L*.13,width,L*.115,.014*L),(L*.33,width*.78,L*.090,.01*L),
           (L*.48,width*.25,L*.042,0),(L*.50,width*.025,L*.012,0)],paint,2.4)
    if kind=='ebee':
        m.loft('YellowPayloadHatch',[(-L*.20,width*.75,L*.03,L*.067),
               (L*.0,width*.85,L*.03,L*.080),(L*.32,width*.54,L*.015,L*.070)],'epp_black',3.0)
        m.hatch(['YellowPayloadHatch'],0,L*.07,L*.12,L*.26,L)
        m.rod('PitotTube',(0,L*.023,L*.46),(0,L*.023,L*.55),L*.0024,'metal',segs=20)
        for side in (-1,1):
            m.skin_line('YellowWingJoin',[(side*W*.095,L,L*.23),(side*W*.115,L,-L*.04),
                        (side*W*.145,L,-L*.18)],['MainWingLeft','MainWingRight'],L*.0030,'yellow')
    if kind in ('bramor','orbiter'):
        for side in (-1,1):
            fin(m,'Winglet',side*W*.494,L*.015,-L*.32,L*.24,L*.28,paint,cant=side*.24)
    if kind=='ux11':
        for side in (-1,1):
            fin(m,'Winglet',side*W*.494,L*.040,-L*.33,L*.18,L*.24,paint,cant=side*.08)
        m.loft('WhiteNose',[(L*.15,width*.93,L*.09,L*.01),(L*.37,width*.70,L*.074,0),
               (L*.49,width*.15,L*.030,0)],'paint_white',2.4)
    if kind=='deltaquad':
        for side in (-1,1):
            x=side*W*.19
            m.beam('VTOLBoom',(x,.014*L,-L*.46),(x,.014*L,L*.44),W*.018,L*.055,'carbon',.005)
            for end in (-1,1):
                c=(x,L*.085,end*L*.40)
                m.beam('LiftMotorPylon',(x,0,c[2]),c,W*.013,L*.035,paint,.004)
                drive(m,c,W*.0075,W*.080,(1 if side<0 else 3)+(0 if end<0 else 1),blades=2)
                foot=(x,-.25,c[2]*.55)
                m.rod('LandingLeg',(x,-.010,c[2]*.55),foot,.007,'carbon',segs=24)
                m.ellipsoid('LandingFoot',foot,(.012,.006,.018),'rubber',24,12)
    # Rear pusher is supported by a flush exterior mount.
    z=-L*.36
    m.rod('PusherMount',(0,0,z+L*.05),(0,0,z-L*.02),L*.030,'anodized',segs=48)
    blades=2 if kind in ('ebee','ux11','bramor') or kind=='orbiter' and p['shape'].get('revision')==3 else 3
    drive(m,(0,0,z-L*.035),L*.024,L*(.15 if kind!='deltaquad' else .23),
          9,axis='z',blades=blades,angle=.2,rear=True)
    if kind=='orbiter' and p['shape'].get('revision')==4:
        m.loft('EngineCowling',[(-L*.34,L*.025,L*.033,.015*L),
               (-L*.22,L*.063,L*.05,.017*L),(-L*.10,L*.082,L*.052,.012*L)],paint,2.7)
        m.lens('ForwardSensorWindow',(0,-L*.02,L*.491),L*.025)
    if kind in ('bramor','orbiter','deltaquad'):
        small_camera(m,(0,-L*.14,L*.26),L*.12,lenses=2,
                     mount=(0,-L*.047,L*.21))
    else:
        m.lens('MappingCamera',(0,-L*.100,L*.16),L*.029,'-y')
        m.box('CameraBellyBezel',(0,-L*.082,L*.16),(L*.11,L*.025,L*.09),'anodized',L*.01)
    fuselage_details(m,L,paint=paint)
    label(m,m.id,-W*.27,-L*.16,W*.13,L*.075,L)
    label(m,m.id+'-right',W*.26,-L*.16,W*.12,L*.065,L)


def landing_gear(m,L,wide=.105,main_z=-.06,nose_z=.30,paint='paint_gray'):
    for index,(x,z) in enumerate([(0,L*nose_z),(-L*wide,L*main_z),(L*wide,L*main_z)]):
        radius=L*(.021 if index==0 else .027)
        y=-L*.18
        mount=(x*.24,-L*.032,z)
        axle=(x,y,z)
        m.ellipsoid('LandingGearTrunnion',mount,(L*.015,L*.012,L*.025),paint,32,16)
        m.beam('LandingGearLeg',mount,axle,L*.011,L*.010,'metal',L*.0025)
        m.rod('ShockAbsorber',mix(mount,axle,.28),mix(mount,axle,.76),L*.007,'anodized',segs=32)
        m.rod('ShockPiston',mix(mount,axle,.72),axle,L*.0038,'silver',segs=32)
        m.rod('WheelAxle',(x-radius*.38,y,z),(x+radius*.38,y,z),radius*.16,'metal',segs=32)
        m.profiled_ring('WheelTyre',axle,radius*.79,
            [(radius*.21*cos(j*2*pi/16),radius*.24*sin(j*2*pi/16)) for j in range(16)],
            'rubber',96,axis='x')
        m.rod('WheelHub',(x-radius*.20,y,z),(x+radius*.20,y,z),radius*.65,'anodized',segs=64)
        for sx in (-1,1):
            m.profiled_ring('WheelRim',(x+sx*radius*.205,y,z),radius*.58,
                [(radius*.034*cos(j*2*pi/8),radius*.030*sin(j*2*pi/8)) for j in range(8)],
                'metal',64,axis='x')
            for j in range(8):
                a=j*2*pi/8
                q=(x+sx*radius*.208,y+radius*.46*cos(a),z+radius*.46*sin(a))
                m.ellipsoid('WheelBolt',q,(radius*.018,radius*.040,radius*.040),'metal',16,8)
        # Brake cable and attachment fairing both meet the leg.
        m.tube('BrakeCable',[add(mount,(L*.004,0,0)),add(mix(mount,axle,.55),(L*.006,0,0)),
                            add(axle,(L*.004,0,0))],L*.0012,'black',steps=3,segs=8)
        m.box('GearDoorFairing',mount,(L*.026,L*.009,L*.046),paint,L*.003)


def conventional(m,p):
    W,L=p['wingspan_m'],p['length_m'];kind=p['layout'];paint=p['shape']['paint']
    is_raven=kind=='raven';is_puma=kind=='puma';is_jump=kind=='jump';is_dt=kind=='dt26'
    if is_raven:
        m.loft('Fuselage',[(L*.05,L*.029,L*.050,0),(L*.12,L*.060,L*.073,0),
               (L*.36,L*.060,L*.064,0),(L*.49,L*.040,L*.037,0)],paint,3.6)
        m.beam('TailBoom',(0,L*.004,L*.16),(0,L*.004,-L*.49),L*.028,L*.028,paint,L*.006)
        wing_y=L*.15
        stations=[(0,L*.27,L*.035,wing_y,L*.040),(W*.36,L*.24,L*.045,wing_y,L*.032),
                  (W*.48,L*.21,L*.068,wing_y+L*.075,L*.022),(W*.5,L*.19,L*.073,wing_y+L*.079,L*.013)]
        wing_pair(m,stations,paint)
        m.beam('HighWingPylon',(0,L*.060,L*.20),(0,wing_y,L*.16),L*.070,L*.074,paint,L*.008)
        m.beam('PusherMotorPedestal',(0,L*.035,L*.095),(0,L*.09,L*.045),L*.037,L*.037,paint,L*.008)
        drive(m,(0,L*.09,L*.018),L*.019,L*.11,1,axis='z',blades=2,angle=.35,rear=True)
        tail_y=L*.018
        fin(m,'VerticalTail',0,tail_y,-L*.36,L*.17,L*.19,paint)
        wing_pair(m,[(0,-L*.325,-L*.49,tail_y,L*.018),
                    (W*.12,-L*.35,-L*.48,tail_y,L*.010)],paint,'Tailplane')
        small_camera(m,(0,-L*.061,L*.405),L*.065,lenses=3,mount=(0,-L*.04,L*.37))
    else:
        width=L*(.059 if is_puma else .061 if is_dt else .072 if is_jump else .073)
        m.loft('Fuselage',[(-L*.19,width*.27,L*.028,0),(-L*.11,width*.70,L*.066,0),
               (L*.14,width,L*.088,0),(L*.34,width*.90,L*.071,0),
               (L*.46,width*.43,L*.034,0),(L*.49,width*.10,L*.013,0)],paint,2.6)
        m.loft('TailBoom',[(-L*.49,L*.008,L*.010,L*.020),(-L*.32,L*.013,L*.014,L*.01),
               (-L*.11,L*.024,L*.032,0)],'carbon' if is_dt else paint,2.1)
        wy=L*(.070 if is_puma else .083 if is_jump else .061)
        chord=L*(.17 if is_puma else .29 if is_dt else .26)
        stations=[(0,L*.19,L*.19-chord,wy,L*.060),
                  (W*.32,L*.175,L*.19-chord,wy,L*.045),
                  (W*.44,L*.14,L*.17-chord,wy+L*(.04 if is_puma else .012),L*.027),
                  (W*.495,L*.10,L*.15-chord,wy+L*(.10 if is_puma else .03),L*.012),
                  (W*.5,L*.085,L*.13-chord,wy+L*(.10 if is_puma else .03),L*.005)]
        wing_pair(m,stations,paint)
        tail_y=L*.019
        t_height=L*(.18 if is_dt or is_jump else .135)
        fin(m,'VerticalTail',0,tail_y,-L*.365,t_height,L*.23,paint,sweep=.38)
        t_y=tail_y+t_height if is_dt or is_jump else tail_y
        wing_pair(m,[(0,-L*.345,-L*.49,t_y,L*.025),
                    (W*.125,-L*.36,-L*.48,t_y,L*.018),
                    (W*.145,-L*.38,-L*.46,t_y+L*.014,L*.006)],paint,'Tailplane')
        if is_puma or is_jump:
            m.rod('NoseMotorMount',(0,0,L*.435),(0,0,L*.50),L*.027,'anodized',segs=48)
            drive(m,(0,0,L*.505),L*.025,L*(.135 if is_jump else .15),1,axis='z',blades=2,angle=.30)
        else:
            c=(0,L*.085,-L*.17)
            m.beam('PusherEnginePedestal',(0,L*.025,-L*.12),c,L*.070,L*.043,paint,L*.008)
            drive(m,add(c,(0,0,-L*.025)),L*.034,L*.18,1,axis='z',blades=2,angle=.15,rear=True)
        small_camera(m,(0,-L*.080,L*.27),L*.075,lenses=2,mount=(0,-L*.049,L*.245))
        if is_jump:
            for side in (-1,1):
                x=side*W*.17
                m.beam('LiftBoom',(x,L*.014,-L*.27),(x,L*.014,L*.36),L*.027,L*.027,'carbon',L*.006)
                m.beam('LiftBoomWingClamp',(x,wy-L*.020,-L*.02),(x,L*.014,-L*.02),L*.033,L*.044,paint,L*.004)
                for end in (-1,1):
                    z=L*(.34 if end>0 else -.26)
                    c=(x,L*.096,z)
                    m.beam('LiftMotorPylon',(x,L*.015,z),c,L*.039,L*.046,paint,L*.007)
                    drive(m,c,L*.019,L*.15,(2 if side<0 else 4)+(0 if end<0 else 1),blades=2)
                    foot=(x,-L*.12,z*.64)
                    m.rod('LandingLeg',(x,L*.004,z*.64),foot,L*.005,'carbon',segs=32)
                    m.ellipsoid('LandingFoot',foot,(L*.009,L*.005,L*.015),'rubber',24,12)
            for side in (-1,1):
                fin(m,'Winglet',side*W*.494,wy+L*.015,-L*.07,L*.063,L*.10,paint)
        if is_dt:
            # Visible nose survey window and a broad removable belly payload bay.
            m.loft('PayloadBay',[(-L*.13,L*.045,L*.031,-L*.046),
                   (L*.07,L*.064,L*.038,-L*.055),(L*.33,L*.05,L*.029,-L*.049)],'black',3)
            m.lens('SurveyCamera',(0,-L*.09,L*.12),L*.035,'-y')
            for side in (-1,1):
                label(m,m.id,side*W*.29,L*.07,W*.12,L*.070,W)
    fuselage_details(m,L,paint=paint)
    label(m,m.id,0,L*.18,L*.07,L*.035,L)


def scaneagle(m,p):
    W,L=p['wingspan_m'],p['length_m'];paint=p['shape']['paint']
    m.loft('Fuselage',[(-L*.49,L*.021,L*.028,.010*L),(-L*.24,L*.029,L*.035,.015*L),
           (L*.07,L*.040,L*.047,0),(L*.28,L*.055,L*.057,-L*.005),
           (L*.45,L*.041,L*.043,0),(L*.5,L*.008,L*.012,0)],paint,2)
    wing_pair(m,[(0,L*.04,-L*.23,L*.035,L*.044),(W*.12,L*.005,-L*.24,L*.035,L*.034),
                 (W*.39,-L*.145,-L*.335,L*.06,L*.017),
                 (W*.5,-L*.225,-L*.355,L*.10,L*.008)],paint)
    for side in (-1,1):
        fin(m,'RecoveryWinglet',side*W*.494,L*.10,-L*.292,L*.19,L*.15,paint,cant=side*.14)
        m.rod('SkyhookWingtipBar',(side*W*.477,L*.113,-L*.278),
              (side*W*.495,L*.145,-L*.278),L*.0033,'metal',segs=24)
        label(m,m.id,side*W*.275,-L*.195,W*.12,L*.043,L)
    m.rod('PusherMotorMount',(0,L*.013,-L*.44),(0,L*.013,-L*.50),L*.019,'anodized',segs=48)
    drive(m,(0,L*.013,-L*.505),L*.017,L*.125,1,axis='z',blades=2,rear=True)
    small_camera(m,(0,-L*.049,L*.387),L*.061,lenses=2,mount=(0,-L*.024,L*.355))
    fuselage_details(m,L,paint=paint)


def twinboom(m,p):
    W,L=p['wingspan_m'],p['length_m'];kind=p['layout'];paint=p['shape']['paint']
    is_tb=kind=='tb';is_cw=kind=='cw20';is_ar5=kind=='ar5';is_tp=p['id']=='iai-heron-tp'
    width=L*(.063 if is_tb else .070 if is_tp else .067)
    tall=L*(.115 if is_tp else .082)
    m.loft('Fuselage',[(-L*.31,width*.25,tall*.33,0),(-L*.21,width*.68,tall*.62,0),
           (L*.01,width,tall,0),(L*.26,width*.91,tall*.96,L*.014 if is_tp else 0),
           (L*.41,width*.62,tall*.70,L*.007),(L*.50,width*.02,tall*.025,0)],paint,2.3)
    wy=L*.052
    stations=[(0,L*.16,-L*.155,wy,L*.061),(W*.18,L*.15,-L*.145,wy,L*.048),
              (W*.42,L*.095,-L*.115,wy+L*.014,L*.029),
              (W*.495,L*.035,-L*.074,wy+L*.023,L*.009),
              (W*.5,L*.022,-L*.064,wy+L*.023,L*.005)]
    wing_pair(m,stations,paint)
    bx=W*(.105 if is_tb else .135 if is_ar5 else .12)
    tail='inverted-v' if is_tb or is_cw else p['shape'].get('tail','h')
    for side in (-1,1):
        x=side*bx
        m.loft('TailBoom',[(-L*.49,L*.007,L*.009,L*.023),(-L*.35,L*.012,L*.013,L*.025),
               (-L*.12,L*.021,L*.021,wy),(L*.065,L*.023,L*.025,wy)],paint,2,cx=x)
        if tail=='h':
            fin(m,'TailFin',x,L*.023,-L*.37,L*.17,L*.22,paint)
        if is_ar5:
            # Two forward-facing engines, each nacelle continuous with its boom.
            m.loft('EngineNacelle',[(-L*.115,L*.028,L*.035,wy),
                   (L*.09,L*.039,L*.043,wy),(L*.20,L*.023,L*.029,wy)],paint,2.3,cx=x)
            drive(m,(x,wy,L*.223),L*.024,L*.18,1 if side<0 else 2,axis='z',blades=2)
            m.lens('EngineAirInlet',(x,wy-L*.023,L*.197),L*.014)
        if is_cw:
            m.beam('VTOLBoom',(x,L*.052,-L*.40),(x,L*.052,L*.35),L*.024,L*.025,'carbon',L*.006)
            for end in (-1,1):
                z=L*(.35 if end>0 else -.40)
                c=(x,L*.12,z)
                m.beam('MotorFairing',(x,L*.051,z),c,L*.040,L*.041,paint,L*.008)
                drive(m,c,L*.020,L*.14,(1 if side<0 else 3)+(0 if end<0 else 1),blades=2)
                foot=(x,-L*.17,z)
                m.rod('LandingLeg',(x,L*.06,z),foot,L*.0057,'carbon',segs=32)
                m.ellipsoid('LandingFoot',foot,(L*.010,L*.006,L*.018),'rubber',24,12)
        label(m,m.id,side*W*.29,-L*.015,W*.12,L*.046,L)
    if tail=='inverted-v':
        wing_pair(m,[(0,-L*.315,-L*.49,L*.18,L*.022),
                    (bx,-L*.35,-L*.50,L*.023,L*.014)],paint,'InvertedVTail')
    else:
        wing_pair(m,[(0,-L*.335,-L*.49,L*.028,L*.025),
                    (bx*1.02,-L*.35,-L*.49,L*.028,L*.014)],paint,'Tailplane')
    if not is_ar5:
        blades=5 if is_tp else 3 if is_tb and p['shape'].get('revision')==3 else 2 if is_tb else 3
        m.rod('EngineRearMount',(0,0,-L*.26),(0,0,-L*.32),L*.035,'anodized',segs=48)
        drive(m,(0,0,-L*.337),L*.029,L*(.125 if is_tb else .15),8,axis='z',blades=blades,rear=True)
        for side in (-1,1):
            m.rod('ExhaustOutlet',(side*width*.7,-L*.006,-L*.21),
                  (side*width*.83,-L*.016,-L*.27),L*.012,'metal',segs=32)
    if p['shape'].get('dome'):
        m.loft('SATCOMRadome',[(L*.06,width*.72,L*.041,L*.071),
               (L*.20,width*.75,L*.066,L*.086),(L*.36,width*.57,L*.043,L*.063)],paint,2)
    small_camera(m,(0,-L*.119,L*.292),L*(.088 if is_tp else .072),
                 lenses=3 if is_tp else 2,mount=(0,-L*.067,L*.255))
    if p['shape'].get('gear'):
        landing_gear(m,L,paint=paint)
    if is_tb and p['shape'].get('revision')==3:
        for side in (-1,1):
            host='MainWing'+('Left' if side<0 else 'Right')
            x=side*W*.28
            m.skin_line('WingFoldJoint',[(x,L,L*.11),(x,L,-L*.12)],[host],L*.0012)
            for z in (-L*.055,L*.06):
                q=m.skin((x,L,z),[host]);m.box('WingFoldHinge',q,(L*.038,L*.012,L*.028),'anodized',L*.003)
    fuselage_details(m,L,paint=paint)


def male(m,p):
    W,L=p['wingspan_m'],p['length_m'];paint=p['shape']['paint'];dome=p['shape'].get('dome')
    width=L*(.077 if dome else .060)
    m.loft('Fuselage',[(-L*.49,L*.012,L*.017,L*.021),(-L*.31,L*.027,L*.033,.006*L),
           (-L*.02,width*.85,L*.068,0),(L*.18,width,L*.09,0),
           (L*.36,width*.88,L*.10,L*.011),(L*.50,width*.03,L*.016,0)],paint,2.2)
    wy=L*.057
    wing_pair(m,[(0,L*.12,-L*.20,wy,L*.055),(W*.18,L*.105,-L*.17,wy,L*.042),
                 (W*.43,L*.040,-L*.13,wy+L*.013,L*.025),
                 (W*.5,-L*.01,-L*.07,wy+L*.050,L*.008)],paint)
    wing_pair(m,[(0,-L*.31,-L*.49,L*.014,L*.025),
                 (W*.115,-L*.38,-L*.485,L*.16,L*.011)],paint,'VTail')
    if dome:
        m.loft('NoseRadome',[(L*.16,width*.70,L*.049,L*.067),
               (L*.28,width*.81,L*.074,L*.079),(L*.42,width*.56,L*.05,L*.055)],paint,2)
    m.rod('RearEngineMount',(0,L*.006,-L*.43),(0,L*.006,-L*.50),L*.027,'anodized',segs=48)
    drive(m,(0,L*.006,-L*.512),L*.023,L*.12,1,axis='z',blades=3,rear=True)
    small_camera(m,(0,-L*.125,L*.26),L*.073,lenses=2,mount=(0,-L*.065,L*.225))
    landing_gear(m,L,wide=.14,paint=paint)
    fuselage_details(m,L,paint=paint)
    for side in (-1,1):
        label(m,m.id,side*W*.26,-L*.026,W*.14,L*.045,L)


def build_akinci(m,p):
    W,L=p['wingspan_m'],p['length_m'];paint=p['shape']['paint']
    width=L*.078
    m.loft('Fuselage',[(-L*.49,L*.012,L*.021,L*.023),(-L*.27,L*.027,L*.035,0),
           (L*.03,width*.85,L*.080,0),(L*.20,width,L*.118,L*.020),
           (L*.37,width*.81,L*.102,L*.014),(L*.50,width*.025,L*.014,0)],paint,2.2)
    # Gull-wing: the motors sit near the highest inner wing station.
    stations=[(0,L*.17,-L*.18,L*.027,L*.060),
              (W*.14,L*.15,-L*.16,L*.115,L*.051),
              (W*.24,L*.105,-L*.14,L*.071,L*.044),
              (W*.44,L*.015,-L*.12,L*.048,L*.025),
              (W*.5,-L*.032,-L*.076,L*.073,L*.007)]
    wing_pair(m,stations,paint)
    for side in (-1,1):
        x=side*W*.145;cy=L*.083
        m.loft('TurbopropNacelle',[(-L*.13,L*.027,L*.033,cy),
               (L*.06,L*.045,L*.049,cy),(L*.20,L*.033,L*.033,cy),
               (L*.23,L*.015,L*.017,cy)],paint,2.2,cx=x)
        drive(m,(x,cy,L*.246),L*.023,L*.138,1 if side<0 else 2,axis='z',blades=5,angle=.17)
        m.lens('EngineAirIntake',(x,cy-L*.032,L*.197),L*.017)
        m.rod('ExhaustPipe',(x+side*L*.025,cy-L*.008,-L*.07),
              (x+side*L*.047,cy-L*.019,-L*.16),L*.011,'metal',segs=48)
        m.hatch(['TurbopropNacelle'],x,L*.058,L*.046,L*.075,L)
        label(m,m.id,side*W*.29,-L*.036,W*.15,L*.055,L)
    wing_pair(m,[(0,-L*.32,-L*.49,L*.025,L*.028),
                 (W*.115,-L*.36,-L*.49,L*.19,L*.012)],paint,'VTail')
    m.loft('SATCOMRadome',[(L*.15,width*.80,L*.050,L*.098),
           (L*.27,width*.73,L*.073,L*.111),(L*.41,width*.41,L*.04,L*.071)],paint,2)
    small_camera(m,(0,-L*.129,L*.29),L*.085,lenses=3,mount=(0,-L*.065,L*.25))
    landing_gear(m,L,wide=.12,paint=paint)
    fuselage_details(m,L,paint=paint)


def kizilelma(m,p):
    W,L=p['wingspan_m'],p['length_m'];paint=p['shape']['paint']
    m.loft('Fuselage',[(-L*.49,L*.043,L*.048,0),(-L*.33,L*.070,L*.062,0),
           (-L*.10,L*.075,L*.075,0),(L*.12,L*.074,L*.092,L*.01),
           (L*.32,L*.049,L*.07,0),(L*.45,L*.018,L*.025,0),
           (L*.50,L*.0003,L*.0004,0)],paint,2.4)
    wing_pair(m,[(0,L*.12,-L*.39,-L*.006,L*.042),
                 (W*.20,-L*.015,-L*.38,-L*.002,L*.036),
                 (W*.5,-L*.22,-L*.335,L*.004,L*.007)],paint)
    start=len(m.parts)
    wing_pair(m,[(0,L*.25,L*.13,L*.024,L*.021),
                 (W*.22,L*.165,L*.075,L*.026,L*.008)],paint,'Canard')
    m.rig('CanardPitch',(0,L*.024,L*.19),'x',m.parts[start:],6,'control_surface')
    for side in (-1,1):
        x=side*L*.059
        m.loft('IntakeDuct',[(-L*.15,L*.035,L*.045,-L*.028),
               (L*.06,L*.037,L*.045,-L*.028),(L*.14,L*.026,L*.028,-L*.025)],paint,3.6,cx=x)
        # Duct mouth uses a dark recessed interior and a substantial modeled lip.
        m.box('IntakeInterior',(x,-L*.025,L*.144),(L*.044,L*.043,L*.004),'black',L*.003)
        m.profiled_ring('IntakeLip',(x,-L*.025,L*.144),L*.027,
            [(L*.0025*cos(j*2*pi/12),L*.0025*sin(j*2*pi/12)) for j in range(12)],
            'anodized',80,axis='z')
        fin(m,'CantedVerticalTail',side*L*.044,L*.034,-L*.365,L*.155,L*.18,
            paint,cant=side*.46,sweep=.43)
        label(m,m.id,side*W*.26,-L*.226,W*.12,L*.027,L)
    # Open-looking concentric nozzle, heat shields, and petal divisions.
    c=(0,0,-L*.49)
    m.rod('NozzleInterior',(0,0,-L*.489),(0,0,-L*.513),L*.039,'black',segs=80)
    m.profiled_ring('ExhaustNozzle',c,L*.042,
        [(-L*.003,L*.020),(L*.003,L*.010),(L*.004,-L*.009),(-L*.001,-L*.023)],
        'metal',128,axis='z')
    for j in range(24):
        a=j*2*pi/24
        m.rod('NozzlePetalSeam',(L*.042*cos(a),L*.042*sin(a),-L*.481),
              (L*.043*cos(a),L*.043*sin(a),-L*.506),L*.00065,'anodized',segs=8)
    m.loft('DorsalAvionicsCover',[(-L*.15,L*.041,L*.026,L*.065),
           (L*.02,L*.043,L*.035,L*.078),(L*.21,L*.036,L*.029,L*.081)],'anodized',2.3)
    landing_gear(m,L,wide=.13,nose_z=.34,paint=paint)
    fuselage_details(m,L,paint=paint)


def piaggio(m,p):
    W,L=p['wingspan_m'],p['length_m'];paint='paint_gray'
    m.loft('Fuselage',[(-L*.49,L*.009,L*.014,L*.032),(-L*.30,L*.040,L*.044,0),
           (-L*.12,L*.063,L*.066,0),(L*.11,L*.069,L*.080,0),
           (L*.32,L*.058,L*.067,0),(L*.46,L*.025,L*.034,0),
           (L*.50,L*.001,L*.001,0)],paint,2.2)
    wy=-L*.02
    wing_pair(m,[(0,-L*.03,-L*.20,wy,L*.040),
                 (W*.32,-L*.056,-L*.22,wy,L*.031),
                 (W*.5,-L*.09,-L*.21,wy+L*.05,L*.008)],paint)
    # P.1HH's characteristic forward lifting surface and a high T-tail.
    wing_pair(m,[(0,L*.34,L*.22,-L*.002,L*.024),
                 (W*.15,L*.32,L*.245,L*.012,L*.006)],paint,'ForwardWing')
    fin(m,'VerticalTail',0,L*.03,-L*.385,L*.23,L*.24,paint,sweep=.55)
    wing_pair(m,[(0,-L*.30,-L*.465,L*.259,L*.022),
                 (W*.21,-L*.35,-L*.475,L*.264,L*.012)],paint,'HighTailplane')
    for side in (-1,1):
        x=side*W*.22;cy=L*.01
        m.loft('EngineNacelle',[(-L*.26,L*.025,L*.030,cy),
               (-L*.13,L*.052,L*.054,cy),(L*.007,L*.029,L*.039,cy)],paint,2.2,cx=x)
        drive(m,(x,cy,-L*.277),L*.024,L*.117,1 if side<0 else 2,axis='z',blades=5,angle=.16,rear=True)
        m.lens('EngineAirInlet',(x,cy-L*.022,L*.009),L*.018)
        m.rod('TurbopropExhaust',(x+side*L*.037,cy-L*.001,-L*.13),
              (x+side*L*.052,cy-L*.015,-L*.205),L*.011,'metal',segs=40)
        m.hatch(['EngineNacelle'],x,-L*.13,L*.054,L*.060,L)
        label(m,m.id,side*W*.34,-L*.15,W*.15,L*.045,L)
    m.loft('DorsalSATCOM',[(L*.06,L*.037,L*.022,L*.079),
           (L*.16,L*.039,L*.036,L*.089),(L*.29,L*.03,L*.025,L*.070)],paint,2)
    small_camera(m,(0,-L*.10,L*.30),L*.057,lenses=2,mount=(0,-L*.061,L*.26))
    landing_gear(m,L,wide=.11,main_z=-.10,paint=paint)
    fuselage_details(m,L,paint=paint)


BUILDERS = {
    'mini5': lambda m,p: mini5(m), 'avata2': lambda m,p: avata2(m),
    'autel': lambda m,p: autel(m), 'ray': ray,
    'ebee': flying_wing, 'ux11': flying_wing, 'bramor': flying_wing,
    'orbiter': flying_wing, 'deltaquad': flying_wing,
    'dt26': conventional, 'ar3': conventional, 'puma': conventional, 'raven': conventional,
    'jump': conventional, 'scaneagle': scaneagle, 'twinboom': twinboom,
    'tb': twinboom, 'cw20': twinboom, 'ar5': twinboom, 'male': male,
    'akinci': build_akinci, 'kizilelma': kizilelma, 'piaggio': piaggio,
}


def build(profile):
    m=ExteriorModel(profile['id'],profile['name'])
    BUILDERS[profile['layout']](m,profile)
    if profile.get('wingspan_m'):
        low,high=m.bounds()
        actual=high[0]-low[0]
        factor=profile['wingspan_m']/actual
        # Include canted winglet tips in the span anchor; retain circular props.
        if abs(factor-1)>1e-6:m.scale((factor,1,1))
    if profile['layout']=='ray':
        m.transition=dict(mechanism='tailsitter',duration_seconds=12,pivots=[])
    elif profile['shape'].get('vtol'):
        m.transition=dict(mechanism='quadplane',duration_seconds=12,pivots=[])
        for rotor in m.rotors:
            if rotor['axis']=='y':rotor['preview_cruise_spin']=False
    return m
