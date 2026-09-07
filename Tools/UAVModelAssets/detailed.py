"""Individual photo-guided exterior refinements; all dimensions in metres.

Cosmetic details are visually estimated, not recovered CAD or manufacturing data.
"""
from math import sin, cos, pi
from geometry import add, mix, spline

def neo(m):
    # DJI's L×W×H is 130×157×48.5 mm, not W×L×H. Configuration follows
    # the user's top photograph: permanent circular rims, removable top cages off.
    shell='neo_shell'
    side=[(.012,-.060),(.018,-.055),(.023,-.048),(.022,-.031),
          (.020,-.016),(.034,-.007),(.038,0),(.030,.009),
          (.021,.020),(.017,.042),(.014,.056),(.012,.061)]
    outline=side+[(-x,z) for x,z in reversed(side)]
    m.shell('SculptedLowerShell',outline,[(.75,-.024),(.94,-.020),(1,-.011),(1,.001),(.91,.007)],shell)
    # A narrow crown descends into the gimbal recess; the waist blends into rims.
    crown=[(.010,-.060),(.015,-.054),(.016,-.035),(.014,-.008),(.014,.020),(.013,.042),(.010,.050)]
    crown += [(-x,z) for x,z in reversed(crown)]
    m.shell('ContinuousUpperCrown',crown,[(1,-.004),(1.05,.006),(.95,.014),(.80,.0175),(.40,.0182)],shell)
    m.tube('BodySplitLine',[(x*.976,-.014,z*.98) for x,z in outline],.00022,'seam',True,4,6)
    radius=.03075
    for i,(sx,sz) in enumerate([(-1,1),(1,1),(-1,-1),(1,-1)],1):
        c=(sx*.04775,-.001,sz*.0320)
        m.profiled_ring('MoldedProtectiveRim',c,radius,
            [(-.0024,-.007),(-.0005,-.009),(.0002,-.006),(.0002,.003),(-.0003,.007),(-.0012,.008),(-.0025,.0055),(-.0030,-.003)],shell)
        # Low structural spokes and the circular motor carrier sit below blades.
        m.profiled_ring('MotorCarrier',add(c,(0,-.010,0)),.0112,
            [(-.0005,-.0005),(.0005,-.0005),(.0006,.0005),(-.0004,.0006)],shell,64)
        for j in range(3):
            a=j*2*pi/3+(0 if sx<0 else pi)
            m.tube('LowerMotorSpoke',[add(c,(0,-.009,0)),add(c,(cos(a)*.013,-.010,sin(a)*.013)),add(c,(cos(a)*.028,-.005,sin(a)*.028))],.0009,shell,steps=5)
        m.rod('MotorBase',add(c,(0,-.009,0)),add(c,(0,-.004,0)),.0048,'seam',segs=32)
        m.rod('MotorBell',add(c,(0,-.004,0)),add(c,(0,.0015,0)),.0050,'neo_blade',segs=32)
        for a in range(8):
            t=a*pi/4
            m.rod('MotorVent',add(c,(cos(t)*.0046,-.0003,sin(t)*.0046)),add(c,(cos(t)*.0046,.001,sin(t)*.0046)),.0003,'black',segs=6)
        pc=add(c,(0,.0022,0));name=f'Rotor_{i:02}'
        m.prop(name,pc,.0254,blades=3,mat='neo_blade',angle=.20 if sx<0 else .85,wide=True,hub=False)
        m.rod('PropellerHub',add(pc,(0,-.0009,0)),add(pc,(0,.0011,0)),.0038,'neo_blade',group=name)
        m.screw('RotorRetainer',add(pc,(0,.00108,0)),.0015,group=name)
        for dx,dz in [(-.002,0),(.002,0)]:m.screw('PropMountScrew',add(pc,(dx,.00108,dz)),.00055,group=name)
        # Lower pad, fastener and shell/rim junction details.
        m.box('LandingPad',add(c,(sx*.007,-.019,sz*.009)),(.009,.003,.014),'rubber',.0015)
        m.beam('MoldedMotorFoot',add(c,(0,-.008,0)),add(c,(sx*.007,-.019,sz*.009)),.006,.008,shell,.002)
        m.screw('RimFastener',add(c,(-sx*.027,-.004,-sz*.009)),.00085,hosts=['MoldedProtectiveRim'])
    # Recessed front camera: black pocket and cylindrical single-axis gimbal.
    m.box('RecessedNosePocket',(0,-.006,.052),(.021,.023,.020),'black',.0035)
    for sx in [-1,1]:
        m.box('NoseCheek',(sx*.0125,-.009,.055),(.004,.023,.018),shell,.002)
        m.rod('CameraTiltPin',(sx*.009,-.008,.056),(sx*.012,-.008,.056),.0024,'metal')
    m.box('GimbalCamera',(0,-.007,.057),(.017,.014,.012),'neo_blade',.003)
    m.rod('LensBezel',(0,-.007,.062),(0,-.007,.064),.0062,'black',segs=40)
    m.rod('LensCoating',(0,-.007,.0639),(0,-.007,.0643),.0047,'glass',segs=40)
    for x in [-.0075,-.005,-.0025,0,.0025,.005,.0075]:
        m.box('GimbalCoolingFin',(x,.0035,.054),(.0012,.003,.009),'seam',.00025)
    # Top controls, recessed switch borders, indicator dots and fine shell seam.
    m.box('RearPowerButtonBorder',(0,.0177,-.050),(.011,.0007,.007),'seam',.002)
    m.box('RearPowerButton',(0,.0182,-.050),(.0102,.0007,.0062),shell,.0018)
    m.box('ModePanelBorder',(0,.0176,.027),(.020,.0007,.027),'seam',.002)
    m.box('ModePanel',(0,.0181,.027),(.0194,.0007,.0264),shell,.0018)
    m.box('ModeButtonBorder',(0,.01865,.035),(.010,.0005,.006),'seam',.0015)
    m.box('ModeButton',(0,.019,.035),(.0092,.0005,.0052),shell,.0013)
    for j in range(3):
        for sx in [-1,1]:
            x=sx*.005;z=.018+j*.005
            m.rod('ModeIndicator',(x,.0184,z),(x,.0188,z),.0007,'led_green' if j==0 and sx<0 else 'label',segs=12)
    for j in range(4):
        c=m.surface_point((-.003+j*.002,.0186,-.055),['ContinuousUpperCrown'])
        m.box('BatteryLED',c,(.0008,.0002,.00045),'led_green',.0001)
    m.decal('neo-brand',(0,.0186,-.039),.010,.003)
    # Bottom-facing optics and rear USB/battery interfaces are exterior only.
    m.box('BottomOpticsPlate',(0,-.0242,.009),(.021,.0015,.015),'neo_blade',.003)
    for x in [-.005,.005]:m.rod('DownwardOptic',(x,-.026,.009),(x,-.0248,.009),.0027,'glass',segs=24)
    m.box('BatteryEnd',(0,-.009,-.057),(.024,.017,.007),shell,.002)
    m.box('USBInset',(0,-.007,-.061),(.009,.0035,.001),'black',.001)
    for j in range(8):m.box('UnderVent',(-.009+j*.0026,-.0241,-.020),(.0009,.0008,.012),'seam',.0003)
    for x,z in [(-.010,-.045),(.010,-.045),(-.011,.026),(.011,.026)]:m.screw('ShellScrew',(x,-.023,z),.0007)

def lemur(m):
    m.box('CarbonLowerDeck',(0,-.020,0),(.084,.009,.236),'carbon',.006)
    m.box('ElectronicsEnclosure',(0,.005,-.016),(.074,.039,.176),'dark',.008)
    m.box('BatteryTray',(0,-.037,-.020),(.068,.027,.159),'black',.006)
    m.box('UpperDeck',(0,.027,-.025),(.079,.006,.177),'carbon',.006)
    for i,(sx,sz) in enumerate([(-1,1),(1,1),(-1,-1),(1,-1)],1):
        c=(sx*.120,0,sz*.080)
        a=(sx*.024,-.011,sz*.065)
        m.plate('CarbonArm',[add(a,(0,0,-.009)),add(c,(0,0,-.012)),add(c,(0,0,.012)),add(a,(0,0,.009))],.007,'carbon')
        for y in [-.021,.025]:m.profiled_ring('ProtectiveCageRing',add(c,(0,y,0)),.0815,[(-.002,-.002),(.001,-.002),(.001,.002),(-.002,.002)],'dark',96)
        for j in range(6):
            t=j*pi/3
            m.rod('CagePost',add(c,(.080*cos(t),-.021,.080*sin(t))),add(c,(.080*cos(t),.025,.080*sin(t))),.0018,'dark',segs=12)
        for j in range(3):
            t=j*2*pi/3
            m.rod('GuardCarrier',add(c,(0,-.014,0)),add(c,(.080*cos(t),-.021,.080*sin(t))),.0025,'carbon')
        m.rod('Motor',(c[0],-.014,c[2]),(c[0],.009,c[2]),.013,'dark',segs=32)
        m.prop(f'Rotor_{i:02}',add(c,(0,.011,0)),.0745,blades=2,wide=True)
        m.screw('RotorScrew',add(c,(0,.0191,0)),.0025,group=f'Rotor_{i:02}')
    # Tall upright sensor face, recessed main optics and lower speaker.
    m.box('FrontSensorStack',(0,.040,.095),(.083,.055,.039),'dark',.008)
    for x,y,r,mat in [(-.029,.055,.009,'glass'),(.029,.055,.009,'glass'),(0,.055,.007,'label'),(-.015,.033,.009,'blue'),(.016,.033,.008,'glass')]:
        m.rod('SensorRim',(x,y,.114),(x,y,.119),r*1.2,'black',segs=32)
        m.rod('SensorGlass',(x,y,.119),(x,y,.120),r,mat,segs=32)
    m.box('NoseLoudspeakerPlate',(0,-.014,.118),(.067,.050,.014),'carbon',.007)
    m.rod('SpeakerRim',(0,-.014,.125),(0,-.014,.127),.019,'black',segs=48)
    m.rod('SpeakerCone',(0,-.014,.127),(0,-.014,.128),.016,'dark',segs=48)
    for j in range(9):
        for i in range(9):
            x=(i-4)*.003;dy=(j-4)*.003
            if x*x+dy*dy<.00018:m.rod('SpeakerPerforation',(x,-.014+dy,.128),(x,-.014+dy,.1284),.0005,'black',segs=6)
    for sx in [-1,1]:
        m.beam('LampMountBracket',(sx*.035,.025,.082),(sx*.059,.027,.088),.013,.012,'carbon',.002)
        m.rod('FrontLampBody',(sx*.059,.027,.085),(sx*.059,.027,.104),.013,'metal')
        m.rod('FrontLamp',(sx*.059,.027,.103),(sx*.059,.027,.107),.010,'glass')
        m.rod('RadioAntenna',(sx*.027,.025,-.087),(sx*.041,.058,-.120),.002,'rubber')
        for z in [-.072,0,.066]:m.screw('DeckFastener',(sx*.031,.031,z),.0016,hosts=['UpperDeck','FrontSensorStack','ElectronicsEnclosure'])
    for j in range(10):m.box('CoolingSlot',(-.025+j*.0055,.030,-.040),(.0018,.001,.030),'black',.0004)
    m.decal('brinc-brand',(0,.0315,.009),.040,.010)

def trinity(m,W,L):
    # Flight-mode photograph from Quantum Systems: three tractor motors,
    # conventional horizontal tail and a motor at the top of the single fin.
    grey='foam';h=L*.115
    m.hull('TrinityMoldedBody',[(-L*.45,.018,h*.13,h*.12),(-L*.29,W*.023,h*.24,h*.11),
        (-L*.11,W*.047,h*.45,0),(L*.19,W*.066,h*.55,-h*.15),(L*.36,W*.040,h*.30,-h*.22),(L*.42,.006,h*.06,-h*.25)],grey,segs=40)
    for side in [-1,1]:
        st=[(0,L*.10,-L*.12,.010,h*.55),(W*.23,L*.095,-L*.11,.012,h*.33),(W*.45,L*.04,-L*.085,.018,h*.13),(W*.50,L*.004,-L*.055,.018,h*.014)]
        m.wing('MainWing',st,grey,side)
        m.wing('YellowWingStripe',[(W*.13,L*.067,L*.015,.041,h*.08),(W*.44,L*.035,-L*.005,.031,h*.03),(W*.485,.001,-L*.020,.023,h*.012)],'yellow',side)
        x=side*W*.215
        m.ellipsoid('WingMotorNacelle',(x,.017,L*.091),(W*.025,h*.30,L*.115),grey,32,16)
        start=len(m.parts)
        m.ellipsoid('TiltBearing',(x,.017,L*.176),(W*.015,W*.015,W*.015),'metal',24,12)
        m.rod('TractorMotor',(x,.017,L*.176),(x,.017,L*.220),W*.014,'black',segs=32)
        m.prop('Rotor_Left' if side<0 else 'Rotor_Right',(x,.017,L*.228),W*.086,axis='z',blades=2)
        m.rotors[-1]['preview_cruise_spin']=False
        m.tilt('Left' if side<0 else 'Right',(x,.017,L*.176),start,-90,0)
        m.wing('Tailplane',[(0,-L*.31,-L*.49,h*.12,h*.11),(W*.15,-L*.37,-L*.50,h*.15,h*.04)],grey,side)
        c=m.surface_point((x,.044,-L*.05),['MainWing'])
        m.rod('WingBolt',c,add(c,(0,.003,0)),W*.003,'seam')
    m.plate('TallSingleFin',[(0,h*.12,-L*.31),(0,h*.12,-L*.50),(0,h*2.0,-L*.48),(0,h*2.12,-L*.36)],W*.012,grey,axis=(1,0,0))
    m.ellipsoid('TailMotorFairing',(0,h*2.04,-L*.40),(W*.02,h*.18,L*.075),grey,32,12)
    start=len(m.parts)
    m.ellipsoid('TiltBearing',(0,h*2.04,-L*.35),(W*.015,W*.015,W*.015),'metal',24,12)
    m.rod('TailMotor',(0,h*2.04,-L*.35),(0,h*2.04,-L*.30),W*.014,'black')
    m.prop('Rotor_Tail',(0,h*2.04,-L*.292),W*.086,axis='z',blades=2,direction=-1)
    m.tilt('Tail',(0,h*2.04,-L*.35),start,-90,0)
    m.box('GNSSCover',(0,h*.51,.035),(W*.028,h*.13,L*.037),'dark',h*.025)
    m.rod('PitotMast',(0,h*.18,L*.25),(0,h*.90,L*.26),W*.010,grey)
    m.rod('PitotProbe',(0,h*.90,L*.26),(0,h*.90,L*.40),W*.002,'metal')
    m.box('PayloadBay',(0,-h*.60,L*.17),(W*.071,h*.20,L*.20),'dark',h*.045)
    m.rod('SurveyLens',(0,-h*.69,L*.17),(0,-h*.75,L*.17),W*.021,'glass')
    m.decal('trinity-brand',(W*.32,h*.28,-L*.015),W*.22,W*.045)

def zipline(m,W,L):
    # Museum P1: broad square-ended cargo nose, red straight wing, V-tail.
    h=L*.12
    m.hull('CargoFuselage',[(-L*.18,W*.018,h*.20,0),(-L*.09,W*.060,h*.43,-h*.05),
        (L*.20,W*.065,h*.52,0),(L*.38,W*.055,h*.44,0),(L*.42,W*.034,h*.31,0)],'white',segs=36)
    for side in [-1,1]:
        m.wing('RedMainWing',[(0,L*.16,-L*.025,h*.47,h*.23),(W*.47,L*.14,-L*.02,h*.46,h*.10),(W*.50,L*.12,L*.001,h*.46,h*.04)],'red',side)
        m.wing('VTail',[(0,-L*.34,-L*.49,h*.03,h*.06),(W*.13,-L*.38,-L*.52,h*1.45,h*.035)],'white',side)
    m.rod('TailBoom',(0,0,-L*.08),(0,h*.03,-L*.49),W*.012,'white',r2=W*.007)
    # P1's pair of independently powered propellers share the aft centerline.
    for i,z in enumerate([-L*.33,-L*.365],1):
        m.rod('AftMotor',(0,h*1.57,z-.008),(0,h*1.57,z+.018),W*.017,'black')
        m.prop(f'Pusher_{i}',(0,h*1.57,z-.012),W*.080,axis='z',blades=2,direction=1 if i==1 else -1)
    m.rod('MotorPylon',(0,h*.04,-L*.42),(0,h*1.57,-L*.35),W*.015,'white')
    m.box('DeliveryDoor',(0,-h*.49,L*.16),(W*.092,h*.025,L*.23),'white',h*.04)
    m.tube('RecoveryHook',[(0,-h*.03,-L*.35),(0,-h*.10,-L*.60),(0,-h*.16,-L*.62)],W*.0018,'metal',steps=4)
    m.decal('zipline-brand',(0,h*.522,L*.19),W*.06,W*.015)

def flying_wing(m,ident,W,L):
    epfl=ident.startswith('epfl');paint='foam' if epfl else 'ebee_pattern'
    # eBee has a deep chevron trailing edge; EPFL uses Xeno-derived panels.
    if epfl:
        st=[(0,L*.40,-L*.32,0,L*.14),(W*.17,L*.27,-L*.34,0,L*.10),(W*.43,-L*.10,-L*.39,L*.026,L*.045),(W*.50,-L*.18,-L*.37,L*.040,L*.013)]
    else:
        st=[(0,L*.47,-L*.14,0,L*.17),(W*.15,L*.28,-L*.18,0,L*.11),(W*.29,L*.07,-L*.34,L*.015,L*.065),(W*.50,-L*.20,-L*.49,L*.03,L*.012)]
    # One continuous wing/body skin replaces the intersecting ellipsoid and lid.
    st[0]=(0,L*.47,-L*.215,L*.005,L*.18)
    st.insert(1,(W*.07,L*.40,-L*.20,L*.005,L*.16))
    for side in [-1,1]:m.wing('MainWing',st,paint,side,curved=True)
    x=W*.0675;z0=-L*.09;z1=L*.24;r=L*.022
    outline=[(-x+r,0,z0),(x-r,0,z0),(x,0,z0+r),(x,0,z1-r),(x-r,0,z1),(-x+r,0,z1),(-x,0,z1-r),(-x,0,z0+r)]
    m.surface_patch('InstrumentHatch',outline,['MainWing'],'black')
    if epfl:
        for side in [-1,1]:
            m.wing('RedOuterPanel',[(W*.22,L*.19,-L*.357,L*.012,L*.080),(W*.43,-L*.10,-L*.39,L*.027,L*.046),(W*.50,-L*.18,-L*.37,L*.041,L*.014)],'red',side)
            x=side*W*.13
            m.plate('InboardVerticalFin',[(x,.035,-L*.12),(x,.035,-L*.36),(x,L*.23,-L*.34),(x,L*.27,-L*.20)],W*.008,'white',axis=(1,0,0))
        m.rod('FrontMotor',(0,L*.062,L*.30),(0,L*.062,L*.39),W*.022,'dark')
        m.prop('Tractor',(0,L*.062,L*.405),W*.11,axis='z',blades=2)
        m.rod('GNSSAntenna',(0,L*.07,-L*.10),(0,L*.10,-L*.10),W*.027,'yellow')
    else:
        m.rod('RearMotor',(0,.02,-L*.16),(0,.02,-L*.278),W*.018,'metal')
        m.prop('Pusher',(0,.02,-L*.28),W*.093,axis='z',blades=2)
        m.rod('BellySensor',(0,-L*.082,L*.16),(0,-L*.092,L*.16),W*.024,'glass')
    for sx in [-1,1]:
        for z in [-L*.07,L*.22]:m.screw('HatchRetainer',(sx*W*.053,L*.084,z),W*.0018,hosts=['InstrumentHatch'])

def blended_delta(m,W,L):
    # Figure 6, NASA report 20050169564, printed p.29: central delta with
    # swept removable outer panels and two tall inboard vertical fins.
    for side in [-1,1]:
        m.wing('BlendedWing',[(0,L*.49,-L*.43,0,L*.15),(W*.15,L*.25,-L*.40,0,L*.095),(W*.29,L*.05,-L*.42,0,L*.065),(W*.5,-L*.34,-L*.44,.008,L*.015)],'white',side)
        x=side*W*.095
        m.plate('TwinInboardFin',[(x,.06,-L*.18),(x,.06,-L*.44),(x,L*.26,-L*.40),(x,L*.28,-L*.25)],W*.006,'white',axis=(1,0,0))
        for j in range(3):
            z=L*(.08+j*.085)
            m.surface_patch('ChevronMarking',[(0,L*.076,z+.045),(side*W*.060,L*.058,z-.08),(side*W*.051,L*.061,z-.09),(0,L*.077,z+.013)],['BlendedWing'])
    m.ellipsoid('DorsalEngineHousing',(0,L*.098,-L*.24),(W*.034,L*.07,L*.16),'silver',40,20)
    m.rod('EngineLip',(0,L*.10,-L*.34),(0,L*.10,-L*.42),W*.027,'metal',segs=40)
    m.rod('DarkOutlet',(0,L*.10,-L*.419),(0,L*.10,-L*.425),W*.022,'black',segs=40)
    m.surface_patch('ForwardAccessHatch',[(-W*.0335,0,L*.03),(W*.0335,0,L*.03),(W*.0335,0,L*.21),(-W*.0335,0,L*.21)],['BlendedWing','ChevronMarking'],'white')
    for x in [-W*.027,W*.027]:
        for z in [L*.04,L*.19]:m.screw('HatchScrew',(x,L*.081,z),W*.0012,hosts=['ForwardAccessHatch'])

def surface_details(m,profile):
    """Surface joints follow the actual authored hull/wing curves, not floating boxes."""
    if profile['id']=='dji-neo':return
    # Delicate skin joins at fuselage stations. These are cosmetic estimates.
    for name,rings,paint in list(m.hull_specs):
        if len(rings)<12:continue
        for idx in [len(rings)//5,len(rings)*3//4]:
            z,rx,ry,y=rings[idx];rad=min(rx,ry)*.006
            curve=[(rx*1.002*cos(j*2*pi/64),y+ry*1.002*sin(j*2*pi/64),z) for j in range(64)]
            m.tube('FuselagePanelJoint',curve,max(rad,.00015),'seam',True,1,6)
        # Forward top service cover following the curved shell.
        segment=rings[len(rings)//3:len(rings)*2//3]
        for sign in [-1,1]:
            curve=[m.surface_point((sign*rx*.52,y+ry*.856,z),[name]) for z,rx,ry,y in segment]
            if len(curve)>1:m.tube('ServicePanelEdge',curve,max(min(r[1] for r in segment)*.005,.00015),'seam',steps=1,segs=6)
    for name,stations,paint,side in list(m.wing_specs):
        if any(x in name for x in ['Stripe','Panel','Chevron']):continue
        span=abs(stations[-1][0]-stations[0][0]);rad=max(span*.00065,.00015)
        if span<.015:continue
        line=[]
        for a,b in zip(stations,stations[1:]):
            for i in range(5):
                x,lead,trail,y,t=mix(a,b,i/4)
                if x<stations[-1][0]*.2:continue
                u=.76
                line.append((side*x,y+t*.4275+rad*.7,lead+(trail-lead)*u))
        if len(line)>1:m.tube('ControlSurfaceJoint',line,rad,'seam',steps=1,segs=6)
        if len(stations)>2:
            x,lead,trail,y,t=stations[1]
            curve=[(side*x,y+t/2*sin(pi*i/20)+rad*.7,lead+(trail-lead)*(1-cos(pi*i/20))/2) for i in range(21)]
            m.tube('WingAssemblyJoint',curve,rad,'seam',steps=1,segs=6)
        # Small hinge fairings along the trailing surface, positioned on its skin.
        a,b=stations[-2:]
        for u in [.26,.67]:
            x,lead,trail,y,t=mix(a,b,u)
            m.rod('HingeFairing',(side*x,y+t*.32,lead+(trail-lead)*.84),(side*x,y+t*.27,lead+(trail-lead)*.90),rad*1.7,paint,segs=10)
    # Rotor retention and the visible motor's upper cooling ring. The motor stays
    # stationary; hub fasteners and blade-tip markings share the rotating parent.
    for rotor in list(m.rotors):
        c=rotor['center'];r=rotor['radius_m'];axis=rotor['axis'];g=rotor['name']
        ms=rotor.get('motor_side',-1)
        off=(0,-ms*r*.108,0) if axis=='y' else (0,0,r*.108)
        m.screw('HubRetainer',add(c,off),r*.026,axis,group=g,facing=-ms if axis=='y' else 1)
