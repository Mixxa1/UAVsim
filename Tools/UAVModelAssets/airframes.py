"""Photo-guided exterior approximations for the UAVsim catalogue.

All unmeasured proportions and small details are artistic estimates. The research
manifest identifies exact aircraft imagery, related-airframe references, and
fictional/representative entries separately. No downloaded mesh is reused.
"""
from math import pi, sin, cos, sqrt
from geometry import Model, add, mul, mix
from detailed import neo, lemur, trinity, blended_delta, zipline, flying_wing, surface_details

def motor(m,c,radius,prop_radius,index,coax=False,blades=2,paint='carbon',direction=None,downward=False):
    start_parts=len(m.parts);start_rotors=len(m.rotors)
    x,y,z=c
    m.rod('MotorCase',(x,y-radius*.6,z),(x,y+radius*.6,z),radius,'dark',segs=24)
    m.rod('MotorBell',(x,y+radius*.35,z),(x,y+radius*.7,z),radius*1.03,'copper' if paint=='white' else 'metal',segs=24)
    for j in range(12):
        t=j*pi/6;xx=x+radius*.998*cos(t);zz=z+radius*.998*sin(t)
        m.rod('MotorCoolingGroove',(xx,y-radius*.3,zz),(xx,y+radius*.25,zz),radius*.025,'black',segs=6)
    m.prop(f'Rotor_{index:02}',(x,y+radius*.88,z),prop_radius,blades=blades,mat='white' if paint=='whiteprop' else 'carbon',angle=.5+(index%2)*1.1,direction=direction)
    if coax:
        m.rod('LowerMotor',(x,y-radius*.55,z),(x,y-radius*1.4,z),radius,'dark',segs=24)
        m.prop(f'Rotor_{index+4:02}',(x,y-radius*1.65,z),prop_radius,blades=blades,angle=1.2+(index%2))
    if downward:
        for part in m.parts[start_parts:]:
            part['points']=[(p[0],2*y-p[1],p[2]) for p in part['points']]
            part['normals']=[(n[0],-n[1],n[2]) for n in part['normals']]
            part['faces']=[(a,c,b) for a,b,c in part['faces']]
        for rotor in m.rotors[start_rotors:]:
            rotor['center']=(rotor['center'][0],2*y-rotor['center'][1],rotor['center'][2]);rotor['motor_side']=1

def antenna(m,x,y,z,s):
    m.rod('AntennaMast',(x,y,z),(x,y+s,z),s*.055,'dark')
    m.rod('GNSSCap',(x,y+s,z),(x,y+s*1.08,z),s*.22,'white')

def compact(m,ident):
    # motor half-width, half-length, prop radius, shell W/H/L, paint, sensors
    configs={
      'dji-mavic-3t':(.120,.1474,.119,.088,.066,.196,'gray',3),
      'dji-mavic-4-pro':(.157,.143,.122,.105,.078,.218,'lightgray',3),
      'dji-matrice-4t':(.178,.128,.124,.108,.080,.220,'lightgray',5),
      'dji-matrice-4td-dock-3':(.185,.164,.144,.121,.108,.242,'lightgray',5),
      'skydio-x10':(.190,.260,.135,.143,.084,.312,'gray',3),
    }
    x,z,r,w,h,l,paint,sensors=configs[ident]
    side=[(w*.23,-l*.50),(w*.42,-l*.41),(w*.49,-l*.19),(w*.48,l*.11),(w*.39,l*.35),(w*.22,l*.47)]
    footprint=side+[(-xx,zz) for xx,zz in reversed(side)]
    m.shell('MoldedUpperShell',footprint,[(.70,-h*.48),(.95,-h*.27),(1,0),(.97,h*.22),(.80,h*.42),(.40,h*.48)],paint)
    m.tube('ShellSplitJoint',[(xx*.985,-h*.16,zz*.985) for xx,zz in footprint],h*.004,'seam',True,5,6)
    m.box('BatteryTop',(0,h*.44,-l*.09),(w*.72,h*.09,l*.56),'gray' if paint!='dark' else 'black',h*.025)
    m.box('BatteryRelease',(0,h*.47,-l*.30),(w*.29,h*.025,l*.09),'dark',h*.01)
    for i,(sx,sz) in enumerate([(-1,1),(1,1),(-1,-1),(1,-1)],1):
        origin=(sx*w*.41,-h*.1,sz*l*.24);tip=(sx*x,(-.18 if sz>0 else .23)*h,sz*z)
        elbow=mix(origin,tip,.30)
        if ident=='skydio-x10':
            m.plate('SquareSectionArm',[add(origin,(0,0,-h*.09)),add(tip,(0,0,-h*.09)),add(tip,(0,0,h*.09)),add(origin,(0,0,h*.09))],h*.19,paint)
        else:m.beam('FoldingArm',origin,tip,h*.25,h*.20,paint,h*.045)
        m.rod('ArmHinge',add(elbow,(0,-h*.18,0)),add(elbow,(0,h*.16,0)),h*.14,'dark')
        motor(m,tip,h*.23,r,i,blades=3 if ident=='skydio-x10' else 2)
        footy=-h*(.96 if ident.endswith('dock-3') else .76)
        m.rod('LandingFoot',add(tip,(0,-h*.08,0)),(tip[0],footy,tip[2]+sz*h*.12),h*.065,paint)
        m.ellipsoid('StatusLight',add(tip,(0,-h*.32,sz*h*.10)),(h*.08,h*.035,h*.055),'led_red' if sz>0 else 'led_green',12,6)
    for side in [-1,1]:
        m.rod('ObstacleSensor',(side*w*.28,h*.03,l*.42),(side*w*.28,h*.03,l*.443),w*.085,'glass',segs=32)
        for j in range(6):m.box('VentSlot',(side*w*.43,h*.26,-l*.21+j*l*.032),(w*.018,h*.03,l*.011),'dark')
    cam=(0,-h*.57,l*.42)
    m.camera(cam,s=w*.62,lenses=sensors,ball=ident=='dji-mavic-4-pro',mat='gray' if ident=='skydio-x10' else 'dark')
    if ident=='dji-matrice-4t' or ident.endswith('dock-3'):
        m.rod('RTKDome',(0,h*.42,-l*.20),(0,h*.95,-l*.20),w*.17,paint,segs=24)
    if ident=='skydio-x10':
        for sx in [-1,1]:m.box('BlueArmStripe',(sx*x*.77,-h*.06,z*.81),(h*.16,h*.08,h*.55),'blue',h*.02)
    m.decal('skydio-brand' if ident=='skydio-x10' else 'mavic-brand',(0,h*.499,-l*.05),w*.44,w*.11)
    for sx in [-1,1]:
        m.rod('SideVisionLens',(sx*w*.46,h*.1,0),(sx*w*.505,h*.1,0),h*.075,'glass')
        for zz in [-l*.23,l*.22]:m.screw('BodyFastener',(sx*w*.32,h*.39,zz),h*.021)
    for j in range(4):m.box('BatteryLevelLED',(-w*.08+j*w*.055,h*.485,-l*.23),(w*.025,h*.008,h*.016),'led_green',h*.002)

def phantom(m):
    w,h,l=.12,.073,.18;a=.124
    m.ellipsoid('Shell',(0,0,0),(w*.65,h*.6,l*.6),'white')
    m.box('Battery',(0,0,-l*.4),(w*.66,h*.72,l*.38),'white',.008)
    for i,(sx,sz) in enumerate([(-1,1),(1,1),(-1,-1),(1,-1)],1):
        m.rod('MouldedArm',(sx*.025,0,sz*.045),(sx*a,.010,sz*a),.031,'white',r2=.019)
        if sz>0:
            for u in [.62,.73]:
                p=(sx*a*u,.008,sz*a*u);q=(sx*a*(u+.045),.008,sz*a*(u+.045));m.rod('RedArmBand',p,q,.025,'red')
        motor(m,(sx*a,.025,sz*a),.017,.119,i,paint='whiteprop')
    m.skids(.145,-.12,.205,-.017,'white',mount_w=.09,mount_z=.048)
    m.camera((0,-.103,.062),.052,1,'metal',mount=(0,-.036,.026))
    for side in [-1,1]:
        for j in range(9):m.box('PhantomVent',(side*.064,.010,-.027+j*.006),(.0015,.018,.002),'dark',.0005)
        for z in [-.056,.054]:m.screw('ShellFastener',(side*.051,.024,z),.0013)
    m.box('BatteryButton',(0,.010,-.106),(.020,.009,.004),'seam',.002)
    m.decal('phantom-brand',(0,.044,.01),.042,.010)

def guarded(m,ident):
    if ident=='dji-neo':neo(m);return
    if ident=='brinc-lemur-2':lemur(m);return
    w,l,h,r,paint=.3302,.4064,.1016,.076,'dark'
    m.box('CentralShell',(0,h*.08,0),(w*.33,h*.6,l*.69),paint,h*.20)
    for i,(sx,sz) in enumerate([(-1,1),(1,1),(-1,-1),(1,-1)],1):
        c=(sx*w*.275,0,sz*l*.255)
        m.rod('MotorSupport',(sx*w*.1,0,sz*l*.13),c,h*.08,paint)
        m.ring('PropellerGuard',c,r*1.10,r*.12,h*.33,paint)
        motor(m,c,h*.16,r,i,blades=3)
        if ident=='dji-neo':
            for a in [0,pi/2]:
                dx=cos(a)*r;dz=sin(a)*r
                m.rod('GuardTop',add(c,(-dx,h*.2,-dz)),add(c,(dx,h*.2,dz)),r*.025,paint,segs=8)
    m.camera((0,-h*.13,l*.32),w*.23,1 if ident=='dji-neo' else 3,paint)
    if ident!='dji-neo':
        m.box('UpperSensorUnit',(0,h*.50,0),(w*.18,h*.4,l*.14),'dark',h*.05)
        for x in [-w*.23,w*.23]:m.rod('TopCage',(x,h*.35,-l*.43),(x,h*.35,l*.43),h*.035,'carbon')

def industrial(m,ident):
    # Overall cosmetic size is estimated where the catalogue has no dimensions.
    c={
      'dji-matrice-350-rtk':(.284,.346,.267,.19,.16,.30,.28,'gray',False),
      'dji-matrice-30t':(.26,.21,.175,.18,.15,.265,.14,'dark',False),
      'dji-matrice-400':(.327,.425,.30,.23,.20,.35,.30,'lightgray',False),
      'dji-flycart-30':(.845,.7041,.6875,.62,.33,.86,.64,'dark',True),
      'freefly-alta-x':(.718,.718,.419,.36,.14,.40,.48,'carbon',False),
      'griff-30':(.86,.70,.47,.42,.23,1.24,.46,'white',False),
      'griff-60':(.97,.82,.54,.48,.28,1.39,.56,'white',True),
    }[ident]
    x,z,r,w,h,l,gear,paint,coax=c
    if ident.startswith('griff'):
        m.hull('LongCargoFuselage',[(-l*.5,w*.25,h*.32,0),(-l*.42,w*.45,h*.46,0),(l*.31,w*.5,h*.5,0),(l*.47,w*.35,h*.43,0),(l*.5,w*.2,h*.30,0)],paint)
        for zz in [-.25,-.1,.05,.2]:m.rod('TopRailPost',(0,h*.5,zz*l),(0,h*.96,zz*l),w*.018,'metal')
        m.rod('TopHandle',(0,h*.96,-.25*l),(0,h*.96,.2*l),w*.018,'dark')
    elif ident=='freefly-alta-x':
        m.rod('OctagonalCore',(0,-h*.5,0),(0,h*.5,0),w*.57,'carbon',segs=8)
        m.ring('PayloadIsolationRing',(0,-h*.55,0),w*.46,w*.06,h*.16,'metal',32)
        for side in [-1,1]:
            m.box('TopBattery',(side*w*.22,h*.75,0),(w*.36,h*.68,l*.67),'dark',h*.05)
            m.box('BatteryStrap',(side*w*.22,h*1.10,0),(w*.39,h*.055,l*.12),'rubber',h*.01)
    else:
        outline=[(w*.30,-l*.50),(w*.46,-l*.37),(w*.50,l*.05),(w*.42,l*.34),(w*.29,l*.50)]
        outline += [(-xx,zz) for xx,zz in reversed(outline)]
        m.shell('MoldedMainFuselage',outline,[(.76,-h*.50),(1,-h*.22),(1,h*.24),(.88,h*.46),(.55,h*.50)],paint)
        for side in [-1,1]:m.box('BatteryPack',(side*w*.24,h*.38,-l*.12),(w*.42,h*.55,l*.62),'dark',h*.06)
        for i in range(5):m.box('FrontCoolingSlot',(-w*.32+i*w*.16,h*.06,l*.502),(w*.065,h*.11,h*.012),'black')
        m.box('UpperEquipmentDeck',(0,h*.51,l*.05),(w*.54,h*.035,l*.32),paint,h*.02)
        for side in [-1,1]:
            for zz in [-l*.25,l*.20]:m.screw('DeckBolt',(side*w*.30,h*.445,zz),h*.029)
            for j in range(8):m.box('SideCoolingSlot',(side*w*.493,-h*.02,-l*.20+j*l*.04),(w*.008,h*.17,l*.012),'black',h*.003)
    for i,(sx,sz) in enumerate([(-1,1),(1,1),(-1,-1),(1,-1)],1):
        origin=(sx*w*.40,0,sz*l*.26);tip=(sx*x,h*.05,sz*z)
        arm_mat=paint if ident.startswith('griff') else 'carbon'
        if ident.startswith('griff'):m.beam('StructuralArm',origin,tip,h*.26,h*.18,arm_mat,h*.035)
        else:m.rod('StructuralArm',origin,tip,h*.14,arm_mat,segs=28)
        m.rod('ArmLock',mix(origin,tip,.23),mix(origin,tip,.35),h*.18,'metal' if ident.startswith('griff') else paint)
        if ident=='freefly-alta-x':m.rod('ArmBrace',(sx*w*.25,-h*.5,sz*l*.2),mix(origin,tip,.67),h*.035,'metal')
        inverted=ident in ['dji-matrice-350-rtk','dji-matrice-400','dji-matrice-30t']
        motor(m,tip,h*.27,r,i,coax=coax,paint=paint,downward=inverted)
        if inverted:
            m.rod('MotorUpperTower',add(tip,(0,h*.12,0)),add(tip,(0,h*.64,0)),h*.17,'dark',segs=32)
            m.rod('UpperTowerCap',add(tip,(0,h*.62,0)),add(tip,(0,h*.69,0)),h*.175,paint,segs=32)
        m.box('NavigationLamp',add(tip,(0,-h*.15,sz*h*.20)),(h*.25,h*.09,h*.10),'led_red' if sz>0 else 'led_green',h*.015)
    if ident.startswith('griff'):
        for sx in [-1,1]:
            for sz in [-1,1]:
                foot=(sx*w*.77,-gear,sz*l*.36)
                m.rod('IndependentLandingLeg',(sx*w*.30,-h*.20,sz*l*.28),foot,h*.065,'white')
                m.box('LandingFootPlate',foot,(h*.3,h*.065,h*.35),'rubber',h*.03)
                m.screw('FootBolt',add(foot,(0,h*.05,0)),h*.028)
        m.decal('griff-brand',(0,h*.497,l*.08),w*.6,w*.15)
    elif ident=='dji-matrice-30t':
        for sx in [-1,1]:
            for sz in [-1,1]:m.rod('MotorLandingLeg',(sx*x,-h*.10,sz*z),(sx*x,-h*.72,sz*z),h*.062,'dark')
    else:m.skids(w*1.5,-gear,l*1.2,-h*.28,'carbon',mount_w=w*.65,mount_z=l*.23)
    if ident.startswith('dji-matrice'):
        m.camera((0,-h*.90,l*.40),w*.62,4 if ident!='dji-matrice-350-rtk' else 3)
        if ident!='dji-matrice-30t':
            for side in [-1,1]:antenna(m,side*w*.42,h*.50,-l*.20,h*.34)
        for side in [-1,1]:
            m.rod('FrontObstacleSensor',(side*w*.23,h*.19,l*.405),(side*w*.23,h*.19,l*.425),w*.064,'glass',segs=32)
        if ident=='dji-matrice-400':m.rod('TopLidar',(0,h*.48,l*.16),(0,h*.75,l*.16),w*.22,'dark',segs=32)
    elif ident.startswith('griff'):
        m.camera((0,-h*.05,l*.5),w*.20,1,'dark')
    if ident=='dji-flycart-30':
        m.box('CargoBox',(0,-gear*.65,0),(w*.90,gear*.5,l*.80),'dark',.04)
        for zz in [-l*.25,l*.25]:
            m.box('CargoCarrier',(0,-h*.53,zz),(w*.66,.055,.06),'carbon',.009)
            for sx in [-1,1]:m.rod('CargoHanger',(sx*w*.25,-h*.5,zz),(sx*w*.25,-gear*.42,zz),.018,'metal')
            m.box('CargoLatch',(0,-gear*.40,zz),(w*.6,.040,.05),'metal',.007)
        for side in [-1,1]:antenna(m,side*w*.3,h*.5,-l*.18,h*.8)

def special_multi(m,ident):
    if ident=='fotokite-sigma':
        # Six motors: four corners and the front/rear midpoints, not eight.
        w=.43;l=.43;h=.065
        corners=[(-w/2,0,-l/2),(w/2,0,-l/2),(w/2,0,l/2),(-w/2,0,l/2)]
        for a,b in zip(corners,corners[1:]+corners[:1]):m.rod('PerimeterFrame',a,b,.012,'carbon')
        m.box('WhiteController',(0,.027,0),(.11,.045,.16),'white',.012)
        positions=corners+[(0,0,-l/2),(0,0,l/2)]
        # The four corners take the diagonal rule and already cancel; the two centreline
        # motors have to be told, or both default to +1 and the hex has a standing
        # reaction torque it cannot trim. Front and rear form a counter-rotating pair.
        spins=[None,None,None,None,1,-1]
        for i,c in enumerate(positions,1):
            m.rod('InnerBrace',(0,0,0),c,.009,'carbon');motor(m,c,.013,.075,i,direction=spins[i-1])
        m.rod('OrangeSwitch',(0,.048,0),(0,.052,0),.015,'orange',segs=24)
        m.camera((0,-.055,.18),.064,2,'metal')
        m.rod('TetherConnector',(0,-.004,0),(0,-.09,0),.004,'copper')
    elif ident=='everdrone-first-on-scene':
        r=.53;h=.10
        outline=[(.080,-.20),(.13,-.11),(.11,.13),(.06,.20),(-.06,.20),(-.11,.13),(-.13,-.11),(-.08,-.20)]
        m.shell('MedicalCore',outline,[(.8,-.05),(1,0),(.89,.04),(.6,.057)],'white')
        m.rod('MedicalCanister',(.07,-.23,0),(.07,-.04,0),.058,'yellow',segs=40)
        m.rod('CanisterLid',(.07,-.047,0),(.07,-.033,0),.061,'dark',segs=40)
        for side in [-1,1]:m.box('MedicalCase',(side*.066,-.14,.12),(.095,.16,.10),'red',.012)
        tips=[]
        for i in range(6):
            a=2*pi*i/6;c=(r*cos(a),0,r*sin(a));tips.append(c)
            m.rod('HexArm',(0,0,0),c,.022,'red');motor(m,c,.026,.205,i+1,direction=1 if i%2 else -1)
            m.rod('MotorArmLock',mix((0,0,0),c,.77),mix((0,0,0),c,.9),.026,'metal')
        m.skids(.50,-.32,.55,-.03,mount_w=.18,mount_z=.115)
        for sx in [-1,1]:
            # Molded upper fairing encloses the front leg root, as in E2 imagery.
            m.beam('LandingRootFairing',(sx*.084,-.022,.115),(sx*.145,-.145,.139),.043,.028,'white',.010)
        m.camera((0,-.1,.18),.1,3,mount=(0,-.036,.12))
    elif ident=='matternet-m2':
        m.hull('DeliveryShell',[(-.20,.07,.10,0),(-.12,.14,.10,0),(.10,.15,.13,0),(.21,.085,.09,.02)],'white')
        m.box('PackagePod',(0,-.115,-.03),(.19,.22,.24),'white',.032)
        for i,(sx,sz) in enumerate([(-1,1),(1,1),(-1,-1),(1,-1)],1):
            c=(sx*.28,.08,sz*.26)
            m.tube('CurvedArm',[(sx*.09,0,sz*.10),(sx*.17,.035,sz*.16),c],.026,'white',steps=10,segs=24)
            m.ellipsoid('MotorPod',c,(.06,.04,.073),'white');motor(m,c,.025,.17,i,paint='whiteprop')
            m.rod('ShortLeg',add(c,(0,-.02,0)),(sx*.28,-.22,sz*.26),.012,'white')
        m.decal('matternet-brand',(0,.105,.025),.095,.024)
        m.box('PayloadDoor',(0,-.218,-.03),(.18,.012,.20),'red',.015)
        for sx in [-1,1]:
            for zz in [-.12,.07]:m.tube('PodHandle',[(sx*.089,-.14,zz),(sx*.14,-.15,zz),(sx*.14,-.19,zz),(sx*.089,-.19,zz)],.004,'dark',steps=4)

def racing(m,profile):
    ident=profile['id'];width=profile['dimensions']['unfoldedMillimeters'][0]/1000
    guarded=ident in ['fpv-tiny-whoop-65','fpv-cinewhoop-3']
    r={'fpv-tiny-whoop-65':.0155,'fpv-micro-racer-25':.03175,'fpv-racer-5':.0635,'fpv-spec-5':.0635,'fpv-long-range-7':.0889,'fpv-open-class':.127,'fpv-cinewhoop-3':.0381}[ident]
    a=.065/(2*sqrt(2)) if ident=='fpv-tiny-whoop-65' else width*(.285 if guarded else .31)
    s=width/.25;h=.023*s
    m.box('BottomCarbonPlate',(0,0,0),(.043*s,.004*s,.085*s),'carbon',.003*s)
    m.box('FlightStack',(0,.012*s,0),(.03*s,.016*s,.03*s),'dark',.002*s)
    m.box('TopCarbonPlate',(0,.027*s,0),(.043*s,.004*s,.073*s),'carbon',.003*s)
    if not ident.startswith('fpv-tiny'):
        m.box('BatteryFoamPad',(0,.031*s,-.013*s),(.035*s,.006*s,.059*s),'rubber',.001*s)
        m.box('BatteryPack',(0,.047*s,-.013*s),(.037*s,.03*s,.062*s),'green' if ident!='fpv-spec-5' else 'yellow',.005*s)
        for z in [-.03*s,.006*s]:m.box('BatteryStrap',(0,.063*s,z),(.041*s,.004*s,.008*s),'rubber',.001*s)
        m.box('AntennaMount',(0,.027*s,-.043*s),(.015*s,.008*s,.021*s),'orange',.002*s)
        antenna(m,0,.025*s,-.048*s,.035*s)
    else:m.ellipsoid('TinyWhoopCanopy',(0,.019*s,.007*s),(.026*s,.036*s,.034*s),'orange')
    for i,(sx,sz) in enumerate([(-1,1),(1,1),(-1,-1),(1,-1)],1):
        c=(sx*a,0,sz*a*(1.15 if ident=='fpv-long-range-7' else 1))
        m.beam('FlatCarbonArm',(0,0,0),c,.012*s,.005*s,'carbon',.001*s)
        motor(m,c,.013*s,r,i,blades=2 if ident=='fpv-long-range-7' else 3)
        if guarded:
            m.profiled_ring('Duct',add(c,(0,.004*s,0)),r*1.08,[(-.001*s,-.009*s),(.002*s,-.008*s),(.003*s,.008*s),(.001*s,.010*s),(-.001*s,.008*s)],'dark')
            for j in range(3):
                t=j*2*pi/3
                m.rod('DuctBrace',add(c,(0,-.004*s,0)),add(c,(r*cos(t),-.004*s,r*sin(t))),.0014*s,'dark')
        for dz in [-.006*s,.006*s]:m.rod('FrameScrew',(sx*.014*s,0,dz),(sx*.014*s,.029*s,dz),.002*s,'metal',segs=8)
    m.box('FPVCamera',(0,.017*s,.038*s),(.025*s,.023*s,.021*s),'dark',.003*s)
    m.rod('FocalRing',(0,.017*s,.048*s),(0,.017*s,.056*s),.009*s,'metal')
    m.rod('FPVLens',(0,.017*s,.056*s),(0,.017*s,.057*s),.007*s,'glass')
    for side in [-1,1]:
        m.box('CameraSidePlate',(side*.016*s,.014*s,.034*s),(.003*s,.034*s,.025*s),'carbon',.002*s)
        for z in [-.029*s,.024*s]:m.screw('FrameScrewHead',(side*.014*s,.029*s,z),.002*s)
    for j in range(3):
        m.box('BoardEdge',(0,(.008+j*.005)*s,0),(.030*s,.001*s,.031*s),'green',.001*s)
        for side in [-1,1]:m.box('Connector',(side*.017*s,(.008+j*.005)*s,0),(.006*s,.003*s,.009*s),'black',.0005*s)
    if not ident=='fpv-tiny-whoop-65':
        m.tube('VisibleBatteryLead',[(.013*s,.045*s,-.035*s),(.025*s,.033*s,-.043*s),(.020*s,.020*s,-.022*s)],.0015*s,'red',steps=6)
        m.tube('VisibleGroundLead',[(.010*s,.045*s,-.035*s),(.022*s,.034*s,-.047*s),(.017*s,.020*s,-.024*s)],.0015*s,'black',steps=6)
        m.box('PowerConnector',(.022*s,.023*s,-.031*s),(.008*s,.007*s,.012*s),'yellow',.001*s)
    if ident in ['fpv-long-range-7','fpv-open-class']:
        m.box('GPSBracket',(0,.024*s,-.045*s),(.017*s,.006*s,.030*s),'orange',.002*s)
        m.box('GPSMount',(0,.028*s,-.060*s),(.025*s,.016*s,.022*s),'orange',.003*s)
        m.box('GPSPatch',(0,.038*s,-.060*s),(.017*s,.005*s,.017*s),'white',.002*s)
        for side in [-1,1]:m.rod('ReceiverAntenna',(0,.021*s,-.042*s),(side*.041*s,.038*s,-.069*s),.0009*s,'dark')
    if ident=='fpv-cinewhoop-3':
        for sx in [-1,1]:m.beam('ActionCameraSupport',(sx*.014*s,.025*s,.033*s),(sx*.014*s,.056*s,.041*s),.006*s,.009*s,'orange',.002*s)
        m.box('ActionCameraMount',(0,.056*s,.041*s),(.035*s,.006*s,.023*s),'orange',.003*s)
        m.box('ActionCamera',(0,.074*s,.044*s),(.034*s,.031*s,.017*s),'dark',.003*s)
        m.rod('ActionLens',(.008*s,.078*s,.052*s),(.008*s,.078*s,.057*s),.008*s,'glass')

def conceptual(m,ident):
    cfg={'wildfire-ember-40':(6,False,.90,'orange'),'pyrolift-talon-60':(6,False,1.25,'red'),
         'colossus-ca8-vulcan':(4,True,2.0,'dark'),'colossus-ca12-atlas':(6,True,2.5,'yellow'),
         'agrowing-titan-at40':(4,True,1.50,'white')}[ident]
    n,coax,r,paint=cfg;h=r*.2
    m.box('ConceptChassis',(0,0,0),(r*.52,h,r*.70),paint,h*.20)
    for i in range(n):
        a=2*pi*i/n+(pi/4 if n==4 else 0);c=(cos(a)*r,0,sin(a)*r)
        m.rod('Arm',(0,0,0),c,h*.12,'carbon');motor(m,c,h*.22,r*.34,i+1,direction=1 if i%2 else -1)
        if coax:
            m.rod('LowerMotor',add(c,(0,-h*.10,0)),add(c,(0,-h*.6,0)),h*.22,'dark')
            m.prop(f'Rotor_{n+i+1:02}',add(c,(0,-h*.65,0)),r*.34,angle=1.2)
    m.skids(r*.70,-r*.5,r*.88,-h*.35)
    if ident=='agrowing-titan-at40':
        m.box('SprayTank',(0,-r*.22,0),(r*.51,r*.44,r*.62),'white',r*.09)
        m.rod('FillCap',(0,h*.49,0),(0,h*.7,0),r*.08,'green')
        for sx in [-1,1]:
            m.rod('SprayBoom',(0,-r*.39,0),(sx*r*.95,-r*.39,0),r*.016,'metal')
            for u in [.4,.7,.9]:m.rod('Nozzle',(sx*r*u,-r*.39,0),(sx*r*u,-r*.44,0),r*.024,'blue')
    else:
        m.rod('HoseSpool',(-r*.17,-r*.15,0),(r*.17,-r*.15,0),r*.19,'dark',segs=32)
        for sx in [-1,1]:m.rod('SpoolFlange',(sx*r*.19,-r*.15,0),(sx*r*.21,-r*.15,0),r*.24,paint,segs=32)

def tandem(m):
    # Unknown published dimensions: explicit nominal 2.1 m fuselage estimate.
    for z in [-.74,.74]:
        side=[(.040,z-.28),(.115,z-.15),(.130,z+.03),(.095,z+.19),(.045,z+.29)]
        # Local outline for the teardrop motor cover.
        contour=[(x,zz-z) for x,zz in side]+[(-x,zz-z) for x,zz in reversed(side)]
        start=len(m.parts)
        m.shell('RotorFairing',contour,[(.75,-.03),(1,.035),(.8,.13),(.4,.185)],'carbon')
        for part in m.parts[start:]:part['points']=[add(p,(0,0,z)) for p in part['points']]
        m.rod('MainRotorMast',(0,.10,z),(0,.35,z),.028,'metal')
        # A tandem cancels torque between its two rotors, so they must be told to turn
        # opposite ways: both sit on the centreline, where the diagonal rule is silent.
        m.prop('Rotor_Front' if z>0 else 'Rotor_Rear',(0,.36,z),.72,blades=2,direction=-1 if z>0 else 1)
        for side in [-1,1]:
            m.rod('LandingLeg',(side*.08,0,z),(side*.37,-.56,z+.10),.025,'carbon')
            m.rod('SkidFoot',(side*.37,-.56,z-.11),(side*.37,-.56,z+.28),.018,'dark')
        m.decal('avidrone-brand',(0,.183,z),.14,.035)
        for sx in [-1,1]:
            for zz in [-.12,.12]:m.screw('PodFastener',(sx*.088,.095,z+zz),.006)
    for side in [-1,1]:
        m.rod('LongitudinalBoom',(side*.065,0,-.8),(side*.065,0,.8),.023,'carbon')
    m.box('PayloadRail',(0,-.10,0),(.13,.09,1.24),'carbon',.01)
    for z in [-.40,0,.40]:m.rod('CrossBrace',(-.08,-.06,z),(.08,.06,z+.12),.01,'metal')
    for z in [-.5,-.3,-.1,.1,.3,.5]:
        for sx in [-1,1]:m.box('CargoRailMount',(sx*.067,-.075,z),(.080,.035,.055),'metal',.005)

def fin(m,name,x,z,y,height,chord,mat='gray',cant=0):
    tipx=x+cant*height
    m.plate(name,[(x,y,z+chord*.5),(x,y,z-chord*.5),(tipx,y+height,z-chord*.45),(tipx,y+height,z+chord*.1)],max(chord*.025,.006),mat,axis=(1,0,0))

def wing_pair(m,stations,mat='gray',name='MainWing'):
    for side in [-1,1]:m.wing(name,stations,mat,side)

def fuselage(m,L,width,height,paint='lightgray',hump=False):
    m.hull('Fuselage',[(-L*.48,width*.17,height*.20,0),(-L*.35,width*.38,height*.37,0),
       (-L*.12,width*.47,height*.46,0),(L*.20,width*.5,height*(.65 if hump else .49),height*.08),
       (L*.39,width*.37,height*.42,0),(L*.50,width*.02,height*.04,-height*.07)],paint,segs=32,subdiv=4)

def twinboom(m,ident,W,L):
    isshadow=ident=='rq-7b-shadow';ft=ident=='ft5-los';integ=ident=='rq-21-integrator'
    wl=W*.10;h=L*.10;bodyL=L*(.65 if ft else .60)
    fuselage(m,bodyL,wl,h)
    wing_pair(m,[(0,L*.10,-L*.20,h*.48,h*.18),(W*.17,L*.10,-L*.20,h*.48,h*.16),(W*.5,L*.015,-L*.17,h*.54,h*.08)])
    # Broad molded saddle overlaps the wing and fuselage along its length;
    # its rounded shoulders remove the former tangential, pinched intersection.
    m.hull('WingRootFairing',[(-L*.225,wl*.20,h*.065,h*.36),
        (-L*.18,wl*.55,h*.14,h*.43),(-L*.075,wl*.69,h*.19,h*.43),
        (L*.065,wl*.56,h*.19,h*.43),(L*.115,wl*.36,h*.13,h*.39),
        (L*.15,wl*.12,h*.035,h*.36)],'lightgray',segs=56,subdiv=10)
    bx=W*(.16 if ft else .12);end=-L*.53
    for side in [-1,1]:
        x=side*bx;m.rod('TailBoom',(x,h*.37,L*.04),(x,h*.30,end),L*.017,'lightgray',r2=L*.010)
        if isshadow:
            fin(m,'TwinFin',x,end+L*.08,h*.26,L*.17,L*.22,'lightgray')
        elif ft:
            fin(m,'TwinFin',x,end+L*.07,h*.24,L*.17,L*.21,'lightgray')
        else:
            # Inverted V connecting the two booms, visible in Mk 4.7 / Integrator photographs.
            m.plate('InvertedVTail',[(0,h*.30+L*.18,end+L*.12),(0,h*.30+L*.18,end-L*.06),(x,h*.28,end-L*.06),(x,h*.28,end+L*.12)],L*.012,'lightgray',axis=(side*.5,.7,0))
        if integ:fin(m,'Winglet',side*W*.495,-L*.09,h*.52,L*.17,L*.12,'white')
    if isshadow or ft:m.box('Tailplane',(0,h*.3,end+L*.03),(bx*2,L*.02,L*.17),'lightgray',L*.007)
    if ft:
        for i,side in enumerate([-1,1],1):
            c=(side*W*.135,h*.76,L*.12)
            m.ellipsoid('EngineNacelle',c,(L*.055,L*.055,L*.16),'gray')
            start=len(m.parts)
            m.hull('NacelleWingFillet',[(-L*.09,L*.012,h*.03,h*.45),
                (-L*.03,L*.060,h*.13,h*.53),(L*.05,L*.079,h*.23,h*.59),
                (L*.13,L*.060,h*.28,h*.64),(L*.18,L*.025,h*.19,h*.65)],'gray',segs=48,subdiv=10)
            for p in m.parts[start:]:p['points']=[add(v,(c[0],0,0)) for v in p['points']]
            # Offset lofts must not acquire centerline service seams.
            m.hull_specs.pop()
            m.prop(f'Propeller_{i}',add(c,(0,0,L*.165)),L*.18,axis='z',blades=2)
    else:
        m.rod('EngineExterior',(0,0,-bodyL*.45),(0,0,-bodyL*.60),h*.5,'dark')
        m.prop('Pusher',(0,0,-bodyL*.62),L*.14,axis='z',blades=2)
    m.camera((0,-h*.7,bodyL*.24),L*.083,2,'lightgray',True)
    m.rod('NoseProbe',(0,0,bodyL*.5),(0,0,bodyL*.65),L*.003,'metal')
    if isshadow or ft:m.wheels(L,bodyy=-h*.25,wide=.15,scale=.8,nose_z=L*.23)

def male(m,ident,W,L):
    mq=ident.startswith('mq-9');b=ident=='mq-9b-skyguardian';h=L*.104;w=L*.120
    fuselage(m,L,w,h,hump=True)
    wing_pair(m,[(0,L*.09,-L*.14,h*.34,h*.35),(W*.12,L*.06,-L*.15,h*.36,h*.23),(W*.5,-L*.10,-L*.185,h*.49,h*.065)])
    for side in [-1,1]:
        # Upward canted tail surfaces; MQ-9 also has its ventral center fin.
        m.wing('VTail',[(0,-L*.29,-L*.46,0,h*.11),(W*.08,-L*.38,-L*.52,L*.15,h*.055)],'lightgray',side)
        if b:fin(m,'Winglet',side*W*.499,-L*.145,h*.45,L*.075,L*.095,'lightgray',side*.15)
        for station in [.17,.28]:
            m.box('EmptyPylon',(side*W*station,h*.22,-L*.05),(w*.075,h*.40,L*.10),'lightgray',w*.02)
    if mq:fin(m,'VentralFin',0,-L*.415,-h*.13,-L*.105,L*.14,'lightgray')
    m.rod('EngineSpinner',(0,0,-L*.47),(0,0,-L*.517),w*.22,'dark')
    m.prop('Pusher',(0,0,-L*.525),L*.115,axis='z',blades=4 if mq else 3)
    m.camera((0,-h*.77,L*.27),L*.068,2,'lightgray',True)
    m.wheels(L,bodyy=-h*.3,wide=.15,scale=.65)
    antenna(m,0,h*.44,-L*.12,L*.035)
    m.decal('mq9-brand' if mq else 'hermes-brand',(0,h*.568,L*.22),w*.55,w*.14)
    for side in [-1,1]:
        m.box('CoolingIntake',(side*w*.405,0,-L*.29),(w*.12,h*.25,L*.09),'dark',h*.055)
        m.rod('StaticDischargeAntenna',(side*w*.30,h*.31,-L*.15),(side*w*.3,h*.8,-L*.17),L*.002,'dark')

def survey(m,ident,W,L):
    if ident=='quantum-systems-trinity-pro':trinity(m,W,L);return
    if ident=='zipline-platform-1':zipline(m,W,L);return
    if ident in ['sensefly-ebee-tac','epfl-delta-wing-uav']:flying_wing(m,ident,W,L);return
    if ident=='wingcopter-198':
        # Manufacturer's 198: four inner tilting rotors plus four outer lift
        # rotors. The eight motor axes are separate, never coaxial.
        h=L*.12
        m.hull('WingcopterBody',[(-L*.43,W*.012,h*.15,.012),(-L*.20,W*.052,h*.36,0),
            (L*.06,W*.085,h*.50,0),(L*.27,W*.078,h*.44,-.006),(L*.38,W*.050,h*.28,-.015),(L*.405,W*.018,h*.10,-.017)],'white',48)
        for side in [-1,1]:
            m.wing('MainWing',[(0,L*.21,-L*.19,0,h*.75),(W*.15,L*.16,-L*.19,0,h*.45),(W*.39,L*.085,-L*.19,.012,h*.18),(W*.5,L*.015,-L*.18,.065,h*.07)],'white',side)
            x=side*W*.20
            m.beam('MoldedTiltBoom',(x,-.018,-L*.41),(x,-.018,L*.405),W*.031,h*.28,'white',.017)
            for end in [-1,1]:
                c=(x,.025 if end>0 else -.025,end*L*.385)
                i=(0 if side<0 else 2)+(1 if end<0 else 2)
                m.ellipsoid('TiltMotorYoke',(x,-.01,c[2]),(W*.022,h*.27,L*.04),'white',24,12)
                start=len(m.parts)
                m.rod('TiltMotorCarrier',(x,-.016,c[2]),c,W*.012,'white')
                motor(m,c,W*.017,W*.117,i,downward=end<0)
                m.tilt(f'Motor_{i:02}',(x,-.016,c[2]),start,0,90 if end>0 else -90)
                m.rod('TiltHingePin',(x-W*.020,-.016,c[2]),(x+W*.020,-.016,c[2]),W*.006,'metal')
                xx=side*W*.39;zz=L*.12 if end>0 else -L*.225
                cy=.017 if end>0 else -.005
                m.beam('LiftMotorWingRoot',(xx,.016,-L*.015),(xx,cy,zz),W*.026,h*.21,'white',.012)
                motor(m,(xx,cy,zz),W*.015,W*.078,i+4,downward=end<0)
                m.rotors[-1]['preview_cruise_spin']=False
            m.wing('VTail',[(0,-L*.21,-L*.43,.012,.026),(W*.22,-L*.38,-L*.57,.28,.014)],'white',side)
            fin(m,'SweptWinglet',side*W*.491,-L*.09,.055,W*.105,L*.19,'white',side*.32)
            # A continuous swept molded leg grows from the wing's underside.
            gx=side*W*.145
            m.plate('MoldedLandingLeg',[(gx,.01,L*.080),(gx,.01,-L*.025),
                (gx,-L*.265,L*.075),(gx,-L*.285,L*.26),(gx,-L*.285,L*.10)],W*.018,'white',axis=(1,0,0))
            m.beam('MoldedSkid',(gx,-L*.285,-L*.21),(gx,-L*.285,L*.37),W*.029,h*.10,'white',.008)
            m.rod('WingtipLightHousing',(side*W*.45,.045,L*.005),(side*W*.45,.05,L*.005),W*.016,'white')
        m.hull('DeliveryPod',[(-L*.23,W*.035,h*.32,-L*.19),(-L*.10,W*.082,h*.58,-L*.18),
            (L*.14,W*.083,h*.59,-L*.18),(L*.27,W*.05,h*.35,-L*.18),(L*.30,W*.005,h*.09,-L*.18)],'white',40)
        for zz in [-L*.10,L*.12]:m.box('PodSuspension',(0,-L*.10,zz),(W*.055,L*.13,L*.034),'white',.009)
        m.rod('NoseOptic',(0,-.015,L*.398),(0,-.015,L*.407),W*.014,'glass',segs=32)
        return
    if ident=='wingtraone-gen-ii':
        m.transition=dict(mechanism='tailsitter',duration_seconds=12,pivots=[],body_node='Geometry',hover_degrees=-90,cruise_degrees=0)
        W=1.25;L=.72
        m.hull('OrangeCenter',[(-.34,.075,.05,0),(-.10,.125,.08,0),(.28,.12,.075,0),(.36,.065,.055,0)],'orange')
        wing_pair(m,[(.03,.27,-.34,0,.105),(.49,.19,-.32,0,.047),(.60,.14,-.25,0,.02),(.625,.08,-.20,0,.007)],'orange')
        for side in [-1,1]:
            m.rod('Motor',(side*.30,0,.20),(side*.30,0,.32),.031,'dark')
            m.prop('Rotor_Left' if side<0 else 'Rotor_Right',(side*.30,0,.335),.17,axis='z')
        # The aircraft is supplied in cruise orientation; its tailstand is still modeled.
        for x in [-.075,.075]:m.rod('TailStand',(x,0,-.25),(x,-.23,-.49),.010,'white')
        m.plate('TailBlade',[(0,0,-.27),(0,0,-.52),(0,.26,-.57),(0,.20,-.35)],.009,'white',axis=(1,0,0))
        m.rod('BellyCamera',(0,-.074,.02),(0,-.081,.02),.038,'glass',segs=24)
        m.decal('wingtra-brand',(0,.081,.07),.13,.033)
        m.tube('CenterHatchSeam',[(-.055,.066,.25),(.055,.066,.25),(.065,.080,-.04),(-.065,.080,-.04)],.0008,'seam',True,5)
        for sx in [-1,1]:
            for z in [-.12,.12]:m.screw('WingLock',(sx*.13,.046,z),.0023,hosts=['MainWing'])
        return
    if ident=='sensefly-ebee-tac' or ident=='epfl-delta-wing-uav':
        epfl=ident.startswith('epfl');paint='foam' if epfl else 'dark'
        fuselage(m,L*.77,W*.20,L*.20,paint)
        stations=[(0,L*.34,-L*.36,0,L*.14),(W*.17,L*.26,-L*.38,0,L*.11),(W*.5,-L*.19,-L*.37,L*.03,L*.025)]
        wing_pair(m,stations,paint)
        if epfl:
            wing_pair(m,[(W*.20,L*.225,-L*.38,L*.015,L*.1),(W*.50,-L*.19,-L*.37,L*.032,L*.026)],'red','RedWingPanel')
            for side in [-1,1]:fin(m,'InboardFin',side*W*.13,-L*.24,L*.05,L*.21,L*.19,'white')
        else:
            for side in [-1,1]:fin(m,'Winglet',side*W*.499,-L*.275,L*.03,L*.11,L*.18,'dark')
            # Small camouflage color patches are geometry, not borrowed photo textures.
            for side in [-1,1]:
                for j in range(6):m.box('CamouflagePatch',(side*W*(.17+j*.047),L*.06-j*L*.007,-L*.24),(W*.043,.0015,L*.075),'gray')
        m.box('AvionicsHatch',(0,L*.11,-L*.04),(W*.18,L*.025,L*.29),'dark',L*.02)
        m.prop('Pusher',(0,L*.055,-L*.45),L*.18,axis='z')
        return
    if ident=='zipline-platform-1':
        fuselage(m,L,.29,.23,'white')
        wing_pair(m,[(0,.15,-.12,.06,.055),(W*.5,.10,-.10,.07,.018)],'red')
        m.rod('TailBoom',(0,.035,-L*.22),(0,.11,-L*.60),.035,'white',r2=.025)
        wing_pair(m,[(0,-L*.42,-L*.61,.11,.025),(W*.13,-L*.45,-L*.60,.11,.012)],'white','Tailplane')
        fin(m,'TailFin',0,-L*.50,.11,.29,.27,'white')
        m.prop('Pusher',(0,.10,-L*.66),.29,axis='z')
        return
    # Trinity Pro and Wingcopter have different lifting-rotor layouts.
    wc=ident=='wingcopter-198';paint='white';h=L*.10
    fuselage(m,L*.80,W*.11,h*1.3,paint)
    wing_pair(m,[(0,L*.11,-L*.15,0,h*.26),(W*.5,L*.025,-L*.145,.035,h*.08)],'white' if wc else 'yellow')
    if wc:
        for side in [-1,1]:
            x=side*W*.31
            m.rod('TiltRotorBoom',(x,0,-L*.46),(x,0,L*.46),W*.019,'white')
            for end in [-1,1]:
                i=(0 if side<0 else 2)+(1 if end<0 else 2)
                motor(m,(x,.025,end*L*.40),W*.022,W*.155,i,coax=True)
            fin(m,'Winglet',side*W*.49,-L*.085,.01,W*.10,L*.16,'white',side*.45)
        # Distinct white V-tail rising behind the central hull.
        for side in [-1,1]:m.wing('VTail',[(0,-L*.15,-L*.40,.035,.025),(W*.21,-L*.37,-L*.54,.25,.012)],'white',side)
        m.skids(W*.32,-L*.26,L*.66,-h*.3,'white')
        m.box('DeliveryPod',(0,-h*1.05,.015),(W*.16,h*1.30,L*.42),'white',h*.30)
    else:
        for i,side in enumerate([-1,1],1):
            x=side*W*.24;m.rod('FrontRotorBoom',(x,0,-L*.12),(x,0,L*.40),W*.014,'white')
            motor(m,(x,.02,L*.40),W*.018,W*.112,i)
        m.rod('TailBoom',(0,0,-L*.14),(0,.015,-L*.56),W*.019,'white',r2=W*.01)
        motor(m,(0,.02,-L*.54),W*.018,W*.11,3)
        for side in [-1,1]:m.wing('VTail',[(0,-L*.35,-L*.54,.01,.015),(W*.14,-L*.43,-L*.56,.20,.008)],'white',side)
        m.rod('SurveyLens',(0,-h*.7,L*.12),(0,-h*.78,L*.12),W*.025,'glass')

def deltas(m,ident,W,L):
    canard=ident in ['iai-harop','iai-harpy-ng'];ng=ident=='iai-harpy-ng'
    if ident=='ncstate-bwb-delta':
        blended_delta(m,W,L);return
        wing_pair(m,[(0,L*.5,-L*.5,0,L*.15),(W*.22,L*.31,-L*.43,0,L*.10),(W*.5,-L*.33,-L*.43,0,L*.014)],'white')
        m.ellipsoid('JetCover',(0,L*.10,-L*.20),(L*.085,L*.085,L*.22),'silver')
        m.rod('JetOpening',(0,L*.10,-L*.40),(0,L*.10,-L*.44),L*.048,'dark')
        return
    fuselage(m,L,L*.135,L*.13,'lightgray')
    wing_pair(m,[(0,L*.23,-L*.41,0,L*.05),(W*.50,-L*.27,-L*.41,0,L*.014)],'lightgray')
    if canard:
        wing_pair(m,[(0,L*.30,L*.15,0,L*.015),(W*.21,L*.29,L*.17,0,L*.008)],'lightgray','Canard')
        if not ng:m.camera((0,-L*.074,L*.42),L*.087,1,'gray',True)
        for side in [-1,1]:fin(m,'WingtipFin',side*W*.49,-L*.34,0,L*.17,L*.23,'lightgray',side*.15)
    else:
        for side in [-1,1]:fin(m,'WingtipFin',side*W*.49,-L*.34,0,L*.16,L*.20,'lightgray')
        m.ellipsoid('RoundedNose',(0,0,L*.42),(L*.065,L*.065,L*.14),'lightgray')
    m.rod('PusherMotorMount',(0,0,-L*.465),(0,0,-L*.507),L*.023,'metal')
    m.prop('Pusher',(0,0,-L*.51),L*.16,axis='z')

def jet(m,ident,W,L):
    himat=ident=='rockwell-himat';x10=ident=='north-american-x-10';quarter=ident.startswith('hermeus');fire=ident.startswith('ryan');aqm=ident.startswith('northrop');karrar=ident=='hesa-karrar'
    paint='orange' if fire else 'silver' if quarter else 'green' if karrar else 'white' if himat or x10 else 'metal'
    w=L*(.105 if x10 else .060 if aqm else .125 if quarter else .13 if karrar else .12 if himat else .095);h=w*(.72 if quarter or himat else .94)
    m.hull('JetFuselage',[(-L*.49,w*.33,h*.38,0),(-L*.34,w*.45,h*.48,0),(-L*.08,w*.50,h*.50,0),
        (L*.18,w*.47,h*.48,0),(L*.32,w*.34,h*.34,0),(L*.42,w*.17,h*.18,0),(L*.49,w*.005,h*.008,0)],paint,segs=48,subdiv=7)
    if quarter:
        # Photographed Mk 2.1: swept trapezoidal wing, conventional horizontal tail,
        # single upright fin and a chin intake. Do not substitute Mk 0 imagery.
        stations=[(0,L*.02,-L*.26,0,h*.14),(W*.5,-L*.13,-L*.27,0,h*.045)]
    elif fire:
        stations=[(0,-L*.06,-L*.32,0,h*.18),(W*.5,-L*.22,-L*.31,0,h*.045)]
    elif aqm:
        stations=[(0,-L*.21,-L*.45,0,h*.14),(W*.5,-L*.35,-L*.46,0,h*.04)]
    elif himat:
        stations=[(0,L*.09,-L*.39,-h*.2,h*.20),(W*.29,-L*.06,-L*.36,-h*.18,h*.10),(W*.5,-L*.17,-L*.35,-h*.16,h*.045)]
    elif x10:
        stations=[(0,L*.08,-L*.44,-h*.15,h*.18),(W*.5,-L*.30,-L*.46,-h*.12,h*.05)]
    else:
        stations=[(0,L*.055,-L*.22,0,h*.19),(W*.5,-L*.05,-L*.17,0,h*.07)]
    wing_pair(m,stations,paint)
    if himat or x10:
        wing_pair(m,[(0,L*.25,L*.12,0,h*.09),(W*(.22 if himat else .20),L*.22,L*.11,0,h*.035)],'red' if himat or x10 else paint,'Canard')
    if quarter or fire or karrar:
        wing_pair(m,[(0,-L*.32,-L*.48,0,h*.12),(W*.23,-L*.39,-L*.49,0,h*.045)],paint,'Tailplane')
    if himat or x10:
        for side in [-1,1]:fin(m,'TwinVerticalFin',side*(W*.23 if himat else w*.56),-L*(.25 if himat else .35),h*(-.20 if himat else .10),L*.18,L*.20,'red' if himat else 'white',side*.08)
    else:fin(m,'VerticalFin',0,-L*.36,h*.30,L*(.145 if quarter else .13),L*.21,paint)
    if quarter:
        m.ellipsoid('ChinIntakeFairing',(0,-h*.49,L*.14),(w*.39,h*.34,L*.11),'silver')
        m.rod('ChinIntakeLip',(0,-h*.47,L*.18),(0,-h*.47,L*.25),w*.29,'metal')
        m.rod('IntakeDarkSurface',(0,-h*.47,L*.251),(0,-h*.47,L*.254),w*.24,'black')
    elif fire:
        m.ellipsoid('VentralNacelle',(0,-h*.63,-L*.21),(w*.4,h*.43,L*.23),'orange')
        m.rod('Intake',(0,-h*.63,-L*.01),(0,-h*.63,L*.015),w*.29,'dark')
    elif karrar:
        m.ellipsoid('DorsalJet',(0,h*.50,-L*.19),(w*.32,h*.38,L*.19),'olive')
        m.rod('TopIntake',(0,h*.60,-L*.04),(0,h*.60,.0),w*.25,'dark')
    elif himat:
        m.box('VentralIntake',(0,-h*.48,L*.07),(w*.72,h*.40,L*.21),'white',h*.10)
        m.box('IntakeOpening',(0,-h*.48,L*.179),(w*.51,h*.26,L*.007),'dark',h*.03)
        for side in [-1,1]:
            m.rod('Skid',(side*w*.8,-h*.85,-L*.25),(side*w*.8,-h*.85,-L*.05),h*.028,'metal')
            for zz in [-L*.22,-L*.08]:m.rod('SkidBracket',(side*w*.30,-h*.3,zz),(side*w*.8,-h*.85,zz),h*.025,'metal')
    elif x10:
        for side in [-1,1]:
            x=side*w*.49
            m.rod('EngineNacelle',(x,-h*.1,-L*.49),(x,-h*.1,L*.04),w*.30,'white',segs=28)
            m.rod('SideIntake',(x,-h*.1,L*.045),(x,-h*.1,L*.055),w*.24,'dark',segs=28)
    outlets=[(-w*.49,-h*.10),(w*.49,-h*.10)] if x10 else [(0,0)]
    for x,y in outlets:
        m.rod('ExhaustRim',(x,y,-L*.49),(x,y,-L*.51),w*.31,'metal',segs=28)
        m.rod('ExhaustInterior',(x,y,-L*.508),(x,y,-L*.515),w*.255,'dark',segs=28)
    if quarter or x10:m.wheels(L,bodyy=-h*.3,wide=.115,scale=.55)
    if himat or aqm or fire:
        m.rod('NoseProbe',(0,0,L*.48),(0,0,L*.56),L*.0018,'metal')
    if himat or x10:
        m.box('RedDorsalStripe',(0,h*.493,-L*.08),(w*.22,h*.013,L*.36),'red')
    if himat:m.decal('himat-brand',(0,h*.5,L*.08),w*.7,w*.175)
    if quarter:m.decal('quarterhorse-brand',(0,h*.5,L*.0),w*.7,w*.175)
    for side in [-1,1]:
        # Access-cover fasteners and external cooling slots along aft fairings.
        for j in range(11):
            z=-L*.29+j*L*.035
            m.rod('AftPanelFastener',(side*w*.43,h*.18,z),(side*w*.438,h*.18,z),L*.0011,'seam',segs=8)
        for j in range(5):m.box('EngineServiceVent',(side*w*.44,-h*.10,-L*.30+j*L*.025),(w*.005,h*.10,L*.007),'dark',L*.001)

def build(profile):
    ident=profile['id'];m=Model(ident,profile['name']);d=profile['dimensions']
    W=d.get('wingspanMillimeters',2000)/1000;L=d.get('fuselageLengthMillimeters',9000 if ident=='hermes-900' else 1000)/1000
    if ident in ['dji-mavic-3t','dji-mavic-4-pro','dji-matrice-4t','dji-matrice-4td-dock-3','skydio-x10']:compact(m,ident)
    elif ident=='dji-phantom-3-standard':phantom(m)
    elif ident in ['dji-neo','brinc-lemur-2']:guarded(m,ident)
    elif ident in ['dji-matrice-350-rtk','dji-matrice-30t','dji-matrice-400','dji-flycart-30','freefly-alta-x','griff-30','griff-60']:industrial(m,ident)
    elif ident in ['fotokite-sigma','everdrone-first-on-scene','matternet-m2']:special_multi(m,ident)
    elif profile['kind']=='class':racing(m,profile)
    elif profile['kind']=='concept':conceptual(m,ident)
    elif ident=='avidrone-490tl':tandem(m)
    elif ident in ['ft5-los','rq-21-integrator','rq-7b-shadow','aerosonde-mk-4-7']:twinboom(m,ident,W,L)
    elif ident in ['mq-9a-reaper','mq-9b-skyguardian','hermes-900']:male(m,ident,W,L)
    elif ident in ['wingtraone-gen-ii','sensefly-ebee-tac','epfl-delta-wing-uav','zipline-platform-1','wingcopter-198','quantum-systems-trinity-pro']:survey(m,ident,W,L)
    elif ident in ['iai-harpy','iai-harop','iai-harpy-ng','ncstate-bwb-delta']:deltas(m,ident,W,L)
    else:jet(m,ident,W,L)
    surface_details(m,profile)
    # Use the project's published span/length/height as the final exterior envelope.
    # Multirotor dimensions often explicitly exclude propellers; those are anchored
    # at their motor spacing instead and must not be fit to the bare-body box.
    low,high=m.bounds();factors=[1.,1.,1.]
    for axis,key in [(0,'wingspanMillimeters'),(2,'fuselageLengthMillimeters'),(1,'heightMillimeters')]:
        if key in d:factors[axis]=d[key]/1000/(high[axis]-low[axis])
    if ident=='dji-neo':factors=[.157/(high[0]-low[0]),.0485/(high[1]-low[1]),.130/(high[2]-low[2])]
    if ident=='brinc-lemur-2':factors=[.405/(high[0]-low[0]),.099/(high[1]-low[1]),.332/(high[2]-low[2])]
    m.scale(factors)
    return m
