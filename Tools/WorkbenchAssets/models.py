"""Original detailed models for every built-in Workbench entry."""
import copy
import math
import numpy as np
from authoring import Asset, color_material, add, sub, mul, mix, unit, cross, norm, spline
from perforation import panel

PI = math.pi


def rotate_parts(m, start, angle, axis="y", center=(0, 0, 0)):
    c, s = math.cos(angle), math.sin(angle)
    def rotate(p):
        x, y, z = p
        if axis == "y":
            return (c*x+s*z, y, -s*x+c*z)
        if axis == "x":
            return (x, c*y-s*z, s*y+c*z)
        return (c*x-s*y, s*x+c*y, z)
    for part in m.parts[start:]:
        part["points"] = [add(center, rotate(sub(p, center))) for p in part["points"]]
        part["normals"] = [rotate(p) for p in part["normals"]]


def annular_sector(m, name, r0, r1, y0, y1, a0, a1, mat, steps=10):
    pts = []
    for y, r in [(y0, r0), (y0, r1), (y1, r1), (y1, r0)]:
        pts.extend((r*math.cos(a), y, r*math.sin(a)) for a in np.linspace(a0, a1, steps+1))
    n = steps+1
    faces = []
    for k in range(4):
        for i in range(steps):
            faces.append((k*n+i, k*n+i+1, ((k+1)%4)*n+i+1, ((k+1)%4)*n+i))
    faces.extend([(0, n, 2*n, 3*n), (n-1, 4*n-1, 3*n-1, 2*n-1)])
    m.mesh(name, pts, faces, mat, True)


def motor(m):
    s = m.spec
    d, h, _ = s["size"]
    r = d/2
    baseh = max(h*.11, .0007)
    m.group = "Stator"
    m.cylinder("MachinedBase", (0, baseh/2, 0), r*.95, baseh, "black_metal")
    m.washer("MountingLip", (0, baseh*.75, 0), r*1.015, r*.84, baseh*.35, "alloy")
    m.cylinder("StatorCore", (0, h*.32, 0), r*.37, h*.39, "black_metal")
    m.cylinder("StatorMountSleeve", (0, h*.15, 0), r*.31, h*.12, "alloy")
    poles = 9 if d < .02 else 12
    wire_r = d*.0065
    for j in range(poles):
        a = j*2*PI/poles
        start = len(m.parts)
        m.box("StatorTooth", (r*.57, h*.33, 0), (r*.44, h*.36, r*.16), "alloy", wire_r)
        for k in range(7):
            y = h*.22+k*h*.040
            points = [(r*.40, y, -r*.115), (r*.77, y, -r*.115),
                      (r*.80, y, 0), (r*.77, y, r*.115),
                      (r*.40, y, r*.115), (r*.36, y, 0)]
            m.tube("EnamelCopperWinding", points, wire_r, "copper", closed=True, steps=3, segs=8)
        rotate_parts(m, start, -a)
    for j in range(4):
        a = PI/4+j*PI/2
        m.fastener((r*.69*math.cos(a), baseh*.95, r*.69*math.sin(a)), d*.035)
    m.group = "RotorBell"
    low, high = h*.24, h*.73
    m.washer("BellLowerRim", (0, low, 0), r, r*.86, h*.08, m.accent)
    m.washer("BellUpperRim", (0, high, 0), r*.91, r*.78, h*.07, m.accent)
    # Open bell windows and top spokes expose the actual coils and stator.
    for j in range(poles):
        a = j*2*PI/poles
        annular_sector(m, "BellWindowWeb", r*.88, r*.98, low, high, a-.105, a+.105, m.accent)
        start = len(m.parts)
        m.beam("VentilatedBellSpoke", (r*.28, high+h*.04, 0), (r*.86, high, 0),
               d*.055, h*.04, m.accent, d*.013)
        rotate_parts(m, start, -a)
        annular_sector(m, "RotorMagnet", r*.835, r*.895, low+h*.07, high-h*.08,
                       a-.085, a+.085, "black_metal", 5)
    m.cylinder("BearingBoss", (0, high+h*.04, 0), r*.29, h*.13, m.accent)
    m.washer("BearingRace", (0, high+h*.112, 0), r*.19, r*.11, h*.017, "steel")
    shaft_radius = s["params"].get("motorShaftMm", max(d*150, 1.0))*.0005
    shaft_radius = min(shaft_radius, r*.16)
    m.cylinder("OutputShaft", (0, h*.885, 0), shaft_radius, h*.23, "steel", segs=64)
    if d >= .019:
        m.cylinder("PropLockNut", (0, h*.986, 0), shaft_radius*1.65, h*.065, "steel", segs=6)
        m.washer("PropWasher", (0, h*.935, 0), shaft_radius*1.85, shaft_radius*1.03, h*.021, "alloy")
        for j in range(8):
            m.torus("ShaftThread", (0, h*(.92+j*.009), 0), shaft_radius, shaft_radius*.037, "steel", segs=48)
    m.group = "Leads"
    # Short attached phase leads, tucked against the motor base.
    for j in range(3):
        x = (j-1)*d*.10
        m.cable("PhaseWire", [(x, baseh*.6, -r*.66), (x, baseh*.1, -r*.92),
                             (x, -d*.018, -r*1.02)], d*.016)
        m.cylinder("PhaseTerminal", (x, -d*.018, -r*1.03), d*.019, d*.085, "gold", "z", 20)
    m.notes += ["Open ventilation windows, enamel copper windings, individual stator poles, magnets, bearings, threaded shaft."]


def propeller(m):
    p = m.spec["params"]
    radius = p["propDiameterInch"]*.0254*.5
    count = int(p["propBladeCount"])
    pitch = p["propPitchInch"]*.0254
    folding = "folding" in m.id
    hubr = max(.0030, radius*.073)
    h = max(.0022, radius*.040)
    bore = min(hubr*.39, .0025)
    m.group = "Hub"
    m.washer("MouldedHubWithBore", (0, 0, 0), hubr, bore, h, m.plastic)
    m.washer("HubShoulder", (0, h*.45, 0), hubr*.81, bore, h*.14, m.plastic)
    if folding:
        # Rounded spinner with separate blade-root hinges.
        profile = [(hubr*1.15, 0), (hubr*1.1, hubr*.40), (hubr*.92, hubr*.85),
                   (hubr*.62, hubr*1.18), (hubr*.25, hubr*1.42), (.00005, hubr*1.48), (.00005, 0)]
        m.profiled_ring("RoundedSpinner", (0, h*.55, 0), 0, profile, "alloy", 96)
    for b in range(count):
        m.group = "Blade_" + str(b+1)
        start = len(m.parts)
        points, faces = [], []
        nspan, nsection = 48, 40
        for i in range(nspan+1):
            t = i/nspan
            span = .062+.938*t
            x = radius*span
            chord = radius*(.072 + .178*math.sin(PI*t)**.86)*(1-.86*t**9)
            sweep = radius*(.04*t+.08*t*t)
            twist = min(math.radians(62), math.atan(pitch/(2*PI*max(x, radius*.12))))
            for j in range(nsection):
                a = 2*PI*j/nsection
                u = (1-math.cos(a))/2
                thick = 5*.105*(.2969*math.sqrt(u)-.1260*u-.3516*u*u+.2843*u**3-.1036*u**4)
                camber = .02*4*u*(1-u)
                y = chord*(camber+math.copysign(thick, math.sin(a)))
                z = (u-.45)*chord
                yy = y*math.cos(twist)-z*math.sin(twist)
                zz = y*math.sin(twist)+z*math.cos(twist)+sweep
                points.append((x, yy, zz))
        for i in range(nspan):
            for j in range(nsection):
                a = i*nsection+j
                k = i*nsection+(j+1)%nsection
                faces.append((a, k, k+nsection, a+nsection))
        faces += [tuple(range(nsection-1, -1, -1)), tuple(nspan*nsection+j for j in range(nsection))]
        blade_mat = "carbon" if folding else m.plastic
        m.mesh("TwistedAirfoilBlade", points, faces, blade_mat, True)
        if folding:
            m.box("BladeRootClamp", (radius*.088, 0, 0), (radius*.10, h*.82, radius*.065), "black_metal", radius*.008)
            m.cylinder("BladeHingePin", (radius*.088, 0, 0), radius*.019, h*1.3, "steel", segs=48)
            m.fastener((radius*.088, h*.70, 0), radius*.024)
        rotate_parts(m, start, b*2*PI/count)
    m.notes += ["Closed airfoil sections, continuous radial pitch twist, tapered swept blade tips and open shaft bore."]


def battery(m):
    s = m.spec
    length, height, width = s["size"]
    cells = int(s["params"]["batteryCells"])
    cap = int(s["params"]["batteryCapacityMah"])
    m.group = "Pack"
    m.box("HeatShrinkEnvelope", (0, 0, 0), (width, height, length), m.plastic, min(width, height)*.11)
    # End caps are beneath the shrink-wrap, not overlapping outer cuboids.
    band = max(length*.022, .0007)
    for z in [-length*.454, length*.454]:
        m.box("InternalEndProtection", (0, 0, z), (width*.90, height*.86, band), "polymer", min(width, height)*.09)
    if "liion" in m.id or "Li-Ion" in s["name"]:
        for x in [-width*.25, width*.25]:
            for y in [-height*.24, height*.24]:
                m.cylinder("CellEndRelief", (x, y, -length*.496), min(width, height)*.22,
                           length*.006, "polymer", "z", 64)
                m.washer("CellInsulatorRing", (x, y, -length*.501), min(width, height)*.155,
                         min(width, height)*.07, length*.003, "ceramic", "z")
    else:
        for i in range(1, cells):
            y = -height*.43+height*.86*i/cells
            for side in [-1, 1]:
                m.beam("PouchLaminateEdge", (side*width*.495, y, -length*.445),
                       (side*width*.495, y, length*.445), height*.008, height*.008, "silver_foil")
    m.label((0, height*.501+.00003, -length*.070), (width*.77, length*.48),
            f"{cells}S  {cap} mAh", f"{cells*3.7:.1f}V   {s['params'].get('batteryContinuousC', 0):.0f}C", host="HeatShrinkEnvelope")
    # A real retention strap wraps the two sides and underside.
    strapz = length*.275
    m.box("RetentionStrapTop", (0, height*.52, strapz), (width*1.022, height*.032, length*.07), "strap", height*.01)
    for side in [-1, 1]:
        m.box("RetentionStrapSide", (side*width*.508, 0, strapz), (width*.022, height*1.02, length*.07), "strap", width*.006)
    m.box("RetentionStrapBottom", (0, -height*.507, strapz), (width*1.02, height*.02, length*.07), "strap", height*.008)
    m.box("StrapBuckle", (width*.33, height*.537, strapz), (width*.24, height*.035, length*.088), "polymer", width*.012)
    terminal = min(max(width*.44, .008), .018)
    m.group = "Connectors"
    socket_c = (0, 0, -length*.506)
    terminal_face = socket_c[2]-.0011
    start = len(m.parts)
    panel(m, "PowerSocket", socket_c, terminal, max(height*.28, .005), .0022,
          [(x, 0, .00115) for x in [-terminal*.20, terminal*.20]], "yellow", .0006)
    rotate_parts(m, start, PI/2, "x", socket_c)
    for x in [-terminal*.20, terminal*.20]:
        m.washer("GoldTerminal", (x, 0, terminal_face+.00045), .00125, .00078, .0013, "gold", "z", 48)
        m.cylinder("SocketInterior", (x, 0, terminal_face+.00105), .00074, .0001, "seam", "z", 32)
    if cells > 1:
        # Balance connector and individual attached silicone leads.
        pitch = min(width*.06, .00125)
        plug = (-width*.26, -height*.18, -length*.515)
        m.header(plug, min(cells+1, 9), pitch)
        for i in range(min(cells+1, 9)):
            x = plug[0]+(i-cells/2)*pitch
            m.cable("BalanceLead", [(x, -height*.16, -length*.475),
                                    (x, -height*.20, -length*.501), (x, plug[1], plug[2])], pitch*.19,
                    "red" if i == 0 else "wire_black" if i == cells else "wire_white")
    m.notes += ["Shrink-wrap finish, pouch/cell end detail, printed specifications, woven retention strap, power and balance contacts."]


def chip(m, c, size, pins=8, label=None):
    w, h, l = size
    m.box("ICPackage", c, size, "silicon", min(w, l)*.035)
    for j in range(pins):
        for side in [-1, 1]:
            z = c[2]+(j-(pins-1)/2)*l/(pins+.8)
            m.box("GullWingICPin", (c[0]+side*w*.56, c[1]-h*.19, z), (w*.18, h*.23, l/(pins+2)*.41), "solder", h*.04)
    for j in range(pins):
        for side in [-1, 1]:
            x = c[0]+(j-(pins-1)/2)*w/(pins+.8)
            m.box("GullWingICPin", (x, c[1]-h*.19, c[2]+side*l*.56), (w/(pins+2)*.41, h*.23, l*.18), "solder", h*.04)
    m.cylinder("PinOneMark", (c[0]-w*.32, c[1]+h*.504, c[2]+l*.31), w*.040, h*.003, "alloy", segs=20)


def smd(m, c, w, l, h, mat="ceramic"):
    m.box("SMDComponent", c, (w, h, l), mat, h*.09)
    for side in [-1, 1]:
        m.box("SMDEndTermination", (c[0]+side*w*.42, c[1], c[2]), (w*.17, h*1.08, l*1.02), "solder", h*.06)


def electronics(m):
    s = m.spec
    w, height, length = s["size"]
    power = s["kind"] == "esc"
    encased = "wing" in m.id or "powerhub" in m.id or "autopilot" in m.id
    t = min(height*.23, .0015)
    m.group = "CircuitBoard"
    mount = s["params"].get("flightControllerMountMm", min(w, length)*1000*.76)/1000
    mount = min(mount, min(w, length)*.86)
    mounting_holes = [(x, z, min(w, length)*.035) for x in [-mount/2, mount/2] for z in [-mount/2, mount/2]]
    panel(m, "FR4Board", (0, 0, 0), w, length, t, mounting_holes, m.board, min(w, length)*.035)
    # FR4 edge layers: a copper substrate stripe between two solder-mask faces.
    for x in [-w*.501, w*.501]:
        m.box("FR4LaminateEdge", (x, -t*.04, 0), (t*.07, t*.38, length*.92), "ceramic")
    y = t*.5
    pad_pitch = min(w, length)*.135
    for side in [-1, 1]:
        for i in range(-3, 4):
            c = (i*pad_pitch, y+.00004, side*length*.455)
            m.box("GoldPlatedSolderPad", c, (w*.058, .00008, length*.046), "gold", .00004)
            m.cable("SolderMaskTrace", [c, (c[0], y+.000023, side*length*.37),
                                      (c[0]*.7, y+.000023, side*length*.30)], w*.0028, "gold")
    if power:
        banks = 5 if "5x" in m.id else 4
        for row in range(banks):
            z = -length*.30+row*length*.60/(banks-1)
            for side in [-1, 1]:
                chip(m, (side*w*.23, y+height*.075, z), (w*.23, height*.15, length*.115), 4)
                smd(m, (side*w*.41, y+height*.040, z), w*.09, length*.06, height*.08, "silicon")
        m.box("CurrentShunt", (0, y+height*.05, -length*.29), (w*.20, height*.12, length*.05), "alloy", height*.018)
        for j in range(2):
            m.cylinder("ElectrolyticCapacitor", (w*(-.12+j*.24), y+height*.16, -length*.35), w*.075, height*.31, "black_metal", segs=56)
            m.cylinder("CapacitorTop", (w*(-.12+j*.24), y+height*.319, -length*.35), w*.063, height*.012, "alloy", segs=40)
        chip(m, (0, y+height*.08, length*.22), (w*.17, height*.16, length*.13), 6)
    else:
        chip(m, (0, y+height*.085, 0), (w*.34, height*.17, length*.34), 12)
        chip(m, (w*.25, y+height*.075, -length*.25), (w*.13, height*.15, length*.14), 5)
        m.box("CrystalOscillator", (-w*.27, y+height*.060, -length*.23), (w*.15, height*.12, length*.084), "alloy", height*.026)
        m.box("BarometerCan", (-w*.27, y+height*.055, length*.18), (w*.12, height*.11, length*.14), "alloy", height*.02)
        m.cylinder("PressurePort", (-w*.27, y+height*.111, length*.18), w*.009, height*.006, "seam", segs=24)
        # USB-C: an open metal shell, dark cavity and individual pins.
        usbw, usbh = min(w*.25, .009), min(height*.49, .003)
        for side in [-1, 1]:
            m.box("USBShellHorizontal", (0, side*usbh*.43, length*.497), (usbw, usbh*.14, length*.095), "steel", usbh*.045)
            m.box("USBShellSide", (side*usbw*.46, 0, length*.497), (usbw*.08, usbh*.86, length*.095), "steel", usbh*.040)
        m.box("USBBack", (0, 0, length*.451), (usbw, usbh*.97, length*.006), "steel", usbh*.040)
        m.box("USBTongue", (0, -usbh*.02, length*.498), (usbw*.61, usbh*.14, length*.093), "ceramic")
        for i in range(12):
            m.box("USBContact", ((i-5.5)*usbw*.045, usbh*.053, length*.532), (usbw*.025, usbh*.035, length*.019), "gold")
    rng = np.random.default_rng(int.from_bytes(m.id.encode()[:8], "little"))
    for j in range(30 if not power else 20):
        side = -1 if j%2 else 1
        x, z = side*w*.38, (j//2-7)*length*.050
        if abs(z) < length*.37:
            smd(m, (x, y+height*.03, z), w*.035, length*.038, height*.06,
                "ceramic" if rng.random() > .45 else "silicon")
    # Underside regulators and passives are visible when inspecting the part.
    for x in [-w*.19, w*.19]:
        m.box("BacksideRegulator", (x, -y-height*.05, 0), (w*.15, height*.1, length*.20), "silicon", height*.014)
    mount = s["params"].get("flightControllerMountMm", min(w, length)*1000*.76)/1000
    mount = min(mount, min(w, length)*.86)
    for x in [-mount/2, mount/2]:
        for z in [-mount/2, mount/2]:
            m.washer("MountPlating", (x, y+.00015, z), min(w, length)*.061,
                     min(w, length)*.035, .00018, "gold")
            m.washer("SiliconeGrommet", (x, -y-.0003, z), min(w, length)*.067,
                     min(w, length)*.035, height*.13, "rubber")
    m.header((w*.34, y+height*.12, length*.30), 6, min(w*.03, .00125))
    m.box("LEDPackage", (-w*.36, y+height*.06, length*.37), (w*.055, height*.12, length*.051), "ceramic", height*.02)
    m.cylinder("StatusLED", (-w*.36, y+height*.11, length*.37), w*.02, height*.04, "led", segs=24)
    if encased:
        m.group = "HeatSink" if power else "AutopilotHousing"
        m.box("LowerCase", (0, -height*.27, 0), (w*1.01, height*.30, length*1.01), "black_metal", min(w, length)*.028)
        m.box("HeatSinkBase", (0, height*.23, 0), (w*.92, height*.12, length*.71), "alloy", height*.035)
        for x in [-w*.43, w*.43]:
            for z in [-length*.39, length*.39]:
                m.cylinder("CaseScrewBoss", (x, height*.22, z), min(w, length)*.038, height*.23, "black_metal", segs=40)
        for j in range(9):
            x = (j-4)*w*.09
            m.box("CoolingFin", (x, height*.34, 0), (w*.034, height*.21, length*.63), "alloy", height*.027)
        for x in [-w*.43, w*.43]:
            for z in [-length*.39, length*.39]:
                radius = min(w, length)*.026
                m.fastener((x, height*.335+radius*.16, z), radius)
    m.notes += ["Two-sided PCB, fine gull-wing IC pins, SMD passives, solder pads, exposed traces, connectors and plated mounting rings."]


def receiver(m):
    w, h, l = m.spec["size"]
    m.group = "ReceiverModule"
    m.box("ReceiverPCB", (0, -h*.22, 0), (w, h*.22, l), m.board, min(w, l)*.04)
    m.box("RFShield", (0, h*.10, -l*.07), (w*.73, h*.58, l*.64), "alloy", h*.08)
    for x in [-w*.30, w*.30]:
        m.washer("UFLShield", (x, h*.065, -l*.41), .00098, .00052, .0007, "gold", segs=40)
        m.cylinder("UFLInsulator", (x, h*.067, -l*.41), .00048, .00072, "ceramic", segs=32)
        m.cylinder("UFLPin", (x, h*.067, -l*.41), .00016, .00075, "gold", segs=16)
    for i in range(4):
        x = (i-1.5)*w*.19
        m.box("SignalPad", (x, -h*.099, l*.44), (w*.095, .00008, l*.07), "gold", .00004)
        smd(m, (x, -h*.03, l*.24), w*.075, l*.085, h*.1, "silicon")
    for side in [-1, 1]:
        for j in range(5):
            m.box("ShieldSolderTab", (side*w*.374, h*.02, (j-2)*l*.12-l*.06),
                  (w*.048, h*.16, l*.040), "solder", h*.035)
    m.cylinder("LinkLED", (w*.38, h*.02, l*.27), w*.038, h*.09, "led", segs=32)
    m.box("BindButton", (-w*.36, h*.035, l*.29), (w*.14, h*.20, l*.11), "ceramic", h*.04)
    freq = m.spec["params"].get("receiverFrequencyMHz", 2400)
    m.label((0, h*.397, -l*.07), (w*.62, l*.36), f"{freq/1000:g} GHz" if freq >= 1000 else f"{freq:g} MHz", "DIVERSITY RX", light=True)
    m.notes += ["RF shielding can, solder tabs, dual U.FL coaxial sockets, bind switch, status LED and signal pads."]


def camera(m):
    w, h, depth = m.spec["size"]
    action = "action" in m.id
    mapping = "mapping" in m.id
    m.group = "CameraBody"
    m.box("CameraHousing", (0, 0, 0), (w, h, depth), m.plastic, min(w, h)*.12)
    m.box("FrontHousingLip", (0, 0, depth*.474), (w*.97, h*.96, depth*.065), "polymer", min(w, h)*.09)
    for x in [-w*.40, w*.40]:
        for y in [-h*.39, h*.39]:
            m.fastener((x, y, depth*.511), min(w, h)*.038, "z")
    m.group = "LensAssembly"
    r = min(w, h)*(.235 if action else .29)
    x = w*.20 if action else 0
    m.lens((x, 0, depth*.48), r, depth*(.29 if mapping else .20))
    if action:
        m.group = "Controls"
        m.box("RearDisplayBezel", (0, 0, -depth*.501), (w*.86, h*.77, depth*.025), "polymer", h*.055)
        m.box("DisplayGlass", (0, 0, -depth*.517), (w*.76, h*.66, depth*.015), "glass", h*.035)
        m.box("FrontStatusScreen", (-w*.27, h*.11, depth*.505), (w*.24, h*.28, depth*.012), "glass", h*.024)
        m.cylinder("ShutterButton", (w*.19, h*.51, 0), h*.12, h*.052, "polymer", segs=64)
        m.cylinder("RecordMark", (w*.19, h*.538, 0), h*.046, h*.003, "red", segs=32)
        for j in range(5):
            m.box("MicrophonePort", (-w*.43+j*w*.020, h*.37, depth*.506), (w*.009, h*.055, depth*.004), "seam", w*.003)
    else:
        for side in [-1, 1]:
            m.cylinder("MountingBoss", (side*w*.496, 0, 0), h*.12, w*.08, "black_metal", "x", 48)
            m.fastener((side*w*.541, 0, 0), h*.067, "x")
        for j in range(8):
            m.box("RearCoolingFin", ((j-3.5)*w*.10, 0, -depth*.51), (w*.025, h*.72, depth*.06), "black_metal", w*.009)
        m.header((0, -h*.25, -depth*.52), 6, min(w*.055, .00125), facing=-1)
    m.label((0, h*.502, -depth*.13), (w*.65, depth*.37), "4K" if action else "GLOBAL" if mapping else "FPV",
            f"{m.spec['params'].get('cameraFovDegrees', 0):g} DEG")
    m.notes += ["Separate housing halves, fasteners, machined lens barrel, focus grip, recessed coated optical glass and connectors."]


def gps(m):
    w, h, l = m.spec["size"]
    m.group = "GNSSModule"
    circular = m.spec["shape"] == "cylinder"
    dual = "dual" in m.id
    if circular:
        m.cylinder("GNSSPuckBase", (0, -h*.16, 0), w*.5, h*.66, "polymer")
        m.washer("PuckGasket", (0, h*.19, 0), w*.505, w*.455, h*.07, "rubber")
        m.cylinder("Radome", (0, h*.27, 0), w*.49, h*.43, "white")
        for j in range(4):
            a = PI/4+j*PI/2
            m.fastener((w*.37*math.cos(a), h*.485, w*.37*math.sin(a)), w*.023)
        m.label((0, h*.491, 0), (w*.51, l*.26), "M10", "GNSS / COMPASS", light=True)
    else:
        m.box("GNSSPCB", (0, -h*.21, 0), (w, h*.21, l), m.board, min(w, l)*.065)
        positions = [-w*.265, w*.265] if dual else [0]
        patch = min(w*(.38 if dual else .72), l*.78)
        for x in positions:
            m.box("CeramicPatchAntenna", (x, h*.065, 0), (patch, h*.47, patch), "ceramic", h*.070)
            m.box("SilverAntennaElectrode", (x, h*.304, 0), (patch*.91, h*.012, patch*.91), "silver_foil", patch*.05)
            m.cylinder("AntennaFeed", (x, h*.316, 0), patch*.026, h*.012, "gold", segs=32)
        for j in range(4):
            smd(m, ((j-1.5)*w*.17, -h*.050, l*.43), w*.065, l*.07, h*.11)
        m.box("GNSSShieldCan", (0, -h*.42, 0), (w*.67, h*.22, l*.61), "alloy", h*.040)
        m.header((0, -h*.17, l*.497), 6, min(w*.04, .00125))
    m.notes += ["Ceramic antenna patch or sealed GNSS radome, antenna electrode, RF shielding and connector pins."]


def sensor(m):
    w, h, l = m.spec["size"]
    m.group = "SensorHousing"
    if "lidar" in m.id or "obstacle" in m.id:
        m.cylinder("SensorBase", (0, -h*.22, 0), w*.48, h*.48, "black_metal")
        m.washer("MidGasket", (0, 0, 0), w*.496, w*.42, h*.07, "rubber")
        m.cylinder("OpticalBand", (0, h*.17, 0), w*.486, h*.32, "glass")
        m.cylinder("SensorCap", (0, h*.40, 0), w*.49, h*.19, m.accent)
        sectors = 6 if "obstacle" in m.id else 4
        for j in range(sectors):
            a = j*2*PI/sectors
            start = len(m.parts)
            m.lens((0, h*.16, w*.478), h*.16, w*.026)
            rotate_parts(m, start, a)
        for j in range(4):
            a = PI/4+j*PI/2
            m.fastener((w*.35*math.cos(a), h*.501, w*.35*math.sin(a)), w*.025)
        m.label((0, h*.502, 0), (w*.47, w*.24), "ToF 360" if sectors == 6 else "LiDAR", "RANGE MODULE")
    else:
        m.box("SealedSensorCase", (0, 0, 0), (w, h, l), m.plastic, min(w, h, l)*.15)
        edge = min(w, h, l)*.15
        m.tube("HousingSeam", [(x, -h*.06, z) for x, z in rounded_outline(w, l, edge)],
               min(w, l)*.006, "seam", closed=True, steps=1, segs=8)
        for x in [-w*.39, w*.39]:
            for z in [-l*.37, l*.37]:
                m.fastener((x, h*.502, z), min(w, l)*.032)
        if "air-quality" in m.id:
            for row in range(4):
                for col in range(11):
                    c = ((col-5)*w*.062, (row-1.5)*h*.16, l*.501)
                    m.box("VentOpening", c, (w*.025, h*.075, l*.004), "seam", w*.008)
            for side in [-1, 1]:
                m.cylinder("SamplingPort", (side*w*.497, 0, 0), h*.17, w*.06, "alloy", "x")
                m.washer("SamplingPortBore", (side*w*.529, 0, 0), h*.14, h*.092, w*.007, "seam", "x")
            m.label((0, h*.502, 0), (w*.67, l*.49), "AIR QUALITY", "PM / CO2 / RH")
        elif "radar" in m.id:
            for x in [-w*.22, w*.22]:
                m.box("RadarRadome", (x, 0, l*.51), (w*.33, h*.66, l*.035), "ceramic", h*.08)
                m.box("RadomeGasket", (x, 0, l*.497), (w*.36, h*.74, l*.009), "rubber", h*.085)
            m.label((0, h*.501, 0), (w*.66, l*.48), "RADAR 120", "ALTIMETER")
        elif "optical-flow" in m.id:
            start = len(m.parts)
            m.lens((0, 0, h*.48), w*.20, h*.19)
            # Optical-flow sensor faces down, matching the existing mount logic.
            rotate_parts(m, start, PI/2, "x")
            m.label((0, h*.501, 0), (w*.66, l*.49), "FLOW", "OPTICAL MOTION")
        else:
            for x in [-w*.22, w*.22]:
                m.lens((x, 0, l*.491), h*.23, l*.12)
            m.label((0, h*.501, 0), (w*.63, l*.45), "RANGE", "LASER ToF")
        m.header((0, -h*.18, -l*.50), 4, min(w*.05, .00125), facing=-1)
    m.notes += ["Distinct sensor-specific optical/radar/air-sampling geometry, housing gaskets, connectors and fasteners."]


def gimbal(m):
    w, h, l = m.spec["size"]
    thermal = "thermal" in m.id
    m.group = "GimbalMount"
    m.box("IsolationPlate", (0, h*.47, 0), (w*.76, h*.070, l*.55), "black_metal", w*.035)
    for x in [-w*.25, w*.25]:
        for z in [-l*.18, l*.18]:
            m.ellipsoid("ElastomerDamper", (x, h*.40, z), (w*.068, h*.067, l*.068), "rubber", 32, 16)
            m.fastener((x, h*.51, z), w*.035)
    m.box("LowerIsolationPlate", (0, h*.333, 0), (w*.70, h*.046, l*.52), "black_metal", w*.03)
    m.cylinder("YawMotor", (0, h*.31, 0), w*.16, h*.16, "black_metal")
    for side in [-1, 1]:
        m.beam("MachinedYoke", (side*w*.43, h*.25, 0), (side*w*.43, -h*.11, 0), w*.070, l*.12, "alloy", w*.018)
        m.cylinder("PitchMotor", (side*w*.40, -h*.09, 0), h*.12, w*.09, "black_metal", "x")
        m.fastener((side*w*.452, -h*.09, 0), w*.038, "x")
    m.beam("YokeCrossbar", (-w*.43, h*.26, 0), (w*.43, h*.26, 0), w*.075, l*.12, "alloy", w*.02)
    m.group = "GimbalSensor"
    m.ellipsoid("SensorTurret", (0, -h*.09, 0), (w*.37, h*.33, l*.38), m.plastic, 80, 40)
    m.washer("TurretEquator", (0, -h*.09, 0), w*.375, w*.361, h*.015, "seam")
    m.lens((0, -h*.09, l*.30), w*.18, l*.14, ir=thermal)
    if thermal:
        m.lens((w*.20, h*.055, l*.29), w*.065, l*.09)
    m.cable("FlexHarness", [(0, h*.26, -l*.10), (-w*.27, h*.15, -l*.16),
                            (-w*.30, -h*.06, -l*.15)], w*.014)
    m.notes += ["Two articulated axes, machined yoke, motor housings, vibration dampers, optical turret and attached flex harness."]


def payload(m):
    w, h, l = m.spec["size"]
    if "gimbal" in m.id:
        return gimbal(m)
    m.group = "PayloadMount"
    m.box("MountingPlate", (0, h*.43, 0), (w*.73, h*.10, l*.73), "black_metal", min(w, l)*.045)
    for x in [-w*.26, w*.26]:
        for z in [-l*.26, l*.26]:
            radius = min(w, l)*.035
            m.fastener((x, h*.48+radius*.16, z), radius)
            m.box("PayloadMountSaddle", (x, h*.373, z), (w*.08, h*.04, l*.08), "black_metal", min(w, l)*.012)
    m.group = "PayloadBody"
    if "lidar" in m.id:
        m.cylinder("ScannerBase", (0, -h*.23, 0), w*.46, h*.46, "black_metal")
        m.cylinder("ScannerWindow", (0, h*.10, 0), w*.465, h*.23, "glass")
        m.cylinder("ScannerCap", (0, h*.29, 0), w*.47, h*.19, m.accent)
        for j in range(10):
            a = j*2*PI/10
            start = len(m.parts)
            m.box("HeatSinkFin", (0, -h*.20, w*.46), (w*.065, h*.34, w*.08), "alloy", w*.016)
            rotate_parts(m, start, a)
        for j in range(3):
            a = j*2*PI/3
            start = len(m.parts)
            m.lens((0, h*.07, w*.43), h*.083, w*.064)
            rotate_parts(m, start, a)
        m.label((0, h*.4, 0), (w*.47, l*.24), "SURVEY LiDAR", "240K POINTS / SEC")
    elif "multispectral" in m.id:
        m.box("SpectralCameraCase", (0, -h*.03, 0), (w, h*.79, l), m.plastic, h*.10)
        for j, (x, y) in enumerate([(-.25, -.20), (.25, -.20), (-.25, .20), (.25, .20), (0, 0)]):
            m.lens((x*w, y*h, l*.495), min(w, h)*(.10 if j == 4 else .12), l*.12, ir=j > 0)
        m.header((0, -h*.20, -l*.5), 8, .00125, facing=-1)
        m.label((0, h*.371, -l*.09), (w*.62, l*.47), "5 BAND", "RGB / RED / EDGE / NIR")
    elif "cargo-release" in m.id:
        m.box("LockActuatorCase", (0, 0, -l*.12), (w*.70, h*.71, l*.72), "alloy", h*.07)
        for side in [-1, 1]:
            m.beam("LockCheek", (side*w*.25, h*.17, l*.17), (side*w*.25, -h*.40, l*.17), w*.050, l*.25, "black_metal", w*.012)
        m.cylinder("LatchPin", (0, -h*.19, l*.20), h*.075, w*.60, "steel", "x")
        m.torus("CargoHook", (0, -h*.43, l*.20), h*.24, h*.055, "steel", "x", 80)
        m.box("SafetyLever", (w*.33, 0, l*.13), (w*.065, h*.44, l*.20), "red", w*.018)
        m.header((0, -h*.10, -l*.50), 4, .00125, facing=-1)
        m.label((0, h*.363, -l*.12), (w*.53, l*.38), "RELEASE", "DUAL LOCK / 2 KG")
    elif "delivery" in m.id:
        m.box("ContainerBody", (0, -h*.065, 0), (w, h*.80, l), m.plastic, h*.105)
        m.box("LidGasket", (0, h*.30, 0), (w*1.004, h*.025, l*1.004), "rubber", h*.10)
        m.box("ContainerLid", (0, h*.342, 0), (w, h*.08, l), "white", h*.034)
        for side in [-1, 1]:
            m.box("LatchBase", (side*w*.25, h*.23, l*.505), (w*.09, h*.24, l*.036), "polymer", h*.026)
            m.box("LatchLever", (side*w*.25, h*.245, l*.527), (w*.071, h*.18, l*.020), "alloy", h*.015)
            m.cylinder("HingeAxle", (side*w*.28, h*.31, -l*.502), h*.025, w*.17, "steel", "x")
        for j in range(4):
            m.box("ContainerReinforcingRib", ((j-1.5)*w*.21, -h*.22, l*.492), (w*.025, h*.42, l*.018), "white", w*.008)
        m.label((0, h*.383, 0), (w*.45, l*.41), "DELIVERY", "1.5 L / SEALED", light=True)
    elif "sprayer" in m.id:
        m.cylinder("TankWall", (0, -h*.055, 0), w*.43, h*.79, "white", segs=112)
        m.ellipsoid("TankShoulder", (0, h*.315, 0), (w*.43, h*.105, w*.43), "white", 96, 24)
        m.ellipsoid("TankBase", (0, -h*.41, 0), (w*.43, h*.059, w*.43), "white", 80, 20)
        m.cylinder("FillerNeck", (0, h*.405, 0), w*.14, h*.08, "polymer")
        m.cylinder("FillerCap", (0, h*.445, 0), w*.18, h*.055, m.accent)
        for j in range(24):
            a = j*2*PI/24
            m.box("CapGrip", (w*.178*math.cos(a), h*.447, w*.178*math.sin(a)), (w*.021, h*.043, w*.021), "polymer", w*.005)
        m.box("PumpHousing", (0, -h*.405, -w*.19), (w*.39, h*.11, w*.28), "black_metal", h*.022)
        for side in [-1, 1]:
            m.cable("DeliveryHose", [(0, -h*.42, 0), (side*w*.26, -h*.46, 0), (side*w*.55, -h*.44, 0)], w*.022)
            m.cylinder("BrassNozzle", (side*w*.55, -h*.48, 0), w*.046, h*.075, "gold", segs=48)
            m.washer("NozzleOrifice", (side*w*.55, -h*.5195, 0), w*.031, w*.012, h*.005, "steel")
        m.notes.append("Closed tank, ribbed filler cap, pump, attached hoses and twin brass nozzles.")
    elif "searchlight" in m.id:
        m.cylinder("LampBody", (0, 0, 0), w*.43, l*.75, "black_metal", "z", 96)
        for j in range(12):
            a = j*2*PI/12
            start = len(m.parts)
            m.box("LampHeatSinkFin", (0, w*.425, -l*.10), (w*.043, w*.080, l*.47), "alloy", w*.013)
            rotate_parts(m, start, a, "z")
        m.washer("ReflectorBezel", (0, 0, l*.384), w*.47, w*.37, l*.062, m.accent, "z", 96)
        m.cylinder("Reflector", (0, 0, l*.39), w*.36, l*.045, "steel", "z", 96)
        for j in range(7):
            x, y = (0, 0) if j == 0 else (w*.23*math.cos(j*PI/3), w*.23*math.sin(j*PI/3))
            m.ellipsoid("LEDOptic", (x, y, l*.432), (w*.095, w*.095, l*.037), "glass", 40, 16)
        for side in [-1, 1]:
            m.beam("LampYoke", (side*w*.47, h*.38, 0), (side*w*.47, 0, 0), w*.07, l*.15, "alloy", w*.015)
            m.fastener((side*w*.51, 0, 0), w*.046, "x")
    m.notes += ["Dedicated mechanical design, mounting plate, fasteners and hardware appropriate to the payload."]


def servo(m):
    w, h, l = m.spec["size"]
    m.group = "ServoCase"
    if "linear" in m.id:
        m.box("LinearServoPCB", (0, -h*.34, 0), (w, h*.13, l), m.board, l*.03)
        m.cylinder("MicroMotor", (-w*.24, 0, 0), l*.25, h*.45, "alloy")
        m.cylinder("MicroMotorMount", (-w*.24, -h*.25, 0), l*.28, h*.09, "polymer", segs=48)
        m.cylinder("LeadScrew", (w*.20, 0, 0), l*.077, h*.76, "steel")
        for j in range(19):
            m.torus("LeadScrewThread", (w*.20, -h*.35+j*h*.038, 0), l*.078, l*.016, "steel", segs=40)
        m.box("LinearCarriage", (w*.20, h*.09, 0), (w*.22, h*.13, l*.71), "ceramic", l*.04)
        m.cylinder("LinkagePin", (w*.20, h*.09, l*.44), l*.08, l*.26, "steel", "z")
    else:
        m.box("ServoShell", (0, 0, 0), (w, h, l), m.plastic, min(w, l)*.09)
        for y in [-h*.29, h*.24]:
            m.tube("CaseSplit", [(x, y, z) for x, z in rounded_outline(w, l, min(w, l)*.09)],
                   min(w, l)*.006, "seam", closed=True, steps=1, segs=8)
        for side in [-1, 1]:
            panel(m, "MountingEar", (side*w*.59, h*.24, 0), w*.23, l*.60, h*.080,
                  [(side*w*.01, 0, l*.080)], "polymer", l*.065)
            m.washer("MountingEarHole", (side*w*.60, h*.282, 0), l*.145, l*.080, h*.006, "steel")
        m.group = "OutputHorn"
        m.cylinder("OutputBoss", (-w*.20, h*.52, 0), l*.24, h*.12, "black_metal")
        m.cylinder("SplineShaft", (-w*.20, h*.589, 0), l*.11, h*.08, "steel", segs=24)
        hole_x = [w*(-.02+j*.17) for j in range(3)]
        panel(m, "ServoHorn", (w*.05, h*.61, 0), w*.78, l*.26, h*.065,
              [(x-w*.05, 0, l*.047) for x in hole_x], "ceramic", l*.080)
        for j in range(3):
            m.washer("HornLinkageHole", (w*(-.02+j*.17), h*.645, 0), l*.085, l*.047, h*.006, "alloy", segs=32)
        m.fastener((-w*.20, h*.6425+l*.13*.16, 0), l*.13)
        for x in [-w*.38, w*.38]:
            for z in [-l*.34, l*.34]:
                m.fastener((x, -h*.48, z), l*.075)
        m.label((0, 0, l*.501), (w*.70, h*.38), "HV SERVO" if "hv" in m.id else "DIGITAL", "METAL GEAR" if "metal" in m.id else "CORE DRIVE", axis="z", host="ServoShell")
    m.group = "ServoLead"
    for j, mat in enumerate(["wire_black", "red", "yellow"]):
        z = (j-1)*l*.095
        m.cable("ServoCable", [(w*.40, -h*.33, z), (w*.57, -h*.39, z),
                              (w*.70, -h*.42, z)], l*.035, mat)
    plug = (w*.74, -h*.42, 0)
    start = len(m.parts)
    panel(m, "ServoPlug", plug, l*.20, l*.47, w*.15,
          [(0, (j-1)*l*.095, l*.040) for j in range(3)], "polymer", l*.035)
    rotate_parts(m, start, -PI/2, "z", plug)
    for j in range(3):
        m.washer("ServoSocketContact", (w*.815, -h*.42, (j-1)*l*.095), l*.040,
                 l*.025, w*.010, "gold", "x", 40)
    m.notes += ["Case splits, mounting ears, output spline/horn or linear lead screw, attached three-wire lead and connector."]


def landing_gear(m):
    w, h, l = m.spec["size"]
    m.group = "LandingGear"
    if "micro-guards" in m.id:
        pipe = max(h*.10, .0015)
        m.torus("MotorGuardRing", (0, 0, 0), w*.42, pipe, "rubber", segs=112)
        for j in range(4):
            a = j*PI/2
            c = (math.sin(a)*w*.42, -h*.17, math.cos(a)*w*.42)
            m.cylinder("LandingFootStem", c, pipe*.68, h*.34, "rubber", segs=48)
            m.ellipsoid("LandingFoot", (math.sin(a)*w*.42, -h*.34, math.cos(a)*w*.42),
                        (h*.19, h*.20, h*.19), "rubber", 48, 24)
    elif "cine-bumpers" in m.id:
        top = -h*.18+max(h*.82, .020)*.5
        for x in [-w*.34, w*.34]:
            for z in [-l*.34, l*.34]:
                m.cylinder("TPUFoot", (x, top-h*.41, z), max(h*.19, .004), h*.82, "rubber")
                m.ellipsoid("TPURoundedFoot", (x, top-h*.82, z), (h*.19, h*.11, h*.19), "rubber", 48, 20)
                for j in range(5):
                    m.torus("PrintedTPULayer", (x, top-h*(.14+j*.11), z), h*.19, h*.005, "polymer", segs=64)
    elif "retractable" in m.id:
        for side in [-1, 1]:
            x = side*w*.31
            m.cylinder("RetractActuator", (x, h*.27, 0), l*.16, w*.10, m.accent, "x")
            m.fastener((x+side*(w*.05+l*.085*.16), h*.27, 0), l*.085, "x", facing=side)
            m.rod("LegHingeLink", (x, h*.27, 0), (x, h*.22, 0), max(l*.067, .0035), "alloy", segs=48)
            foot_r = max(l*.055, .003)
            m.rod("CarbonLeg", (x, h*.22, 0), (x*1.18, -h*.40+foot_r*.2, 0), max(l*.045, .0025), "carbon", segs=56)
            m.box("TrunnionMount", (x, h*.27+l*.16-.002, 0), (w*.10, .004, l*.22), "black_metal", .001)
            m.cylinder("Skid", (x*1.18, -h*.40, 0), max(l*.055, .003), max(l*.62, .045), "rubber", "z")
            m.rod("ActuatorLinkBoss", (x, h*.27, 0), (x-side*w*.021, h*.22, -l*.08), .0025, "alloy", segs=40)
            m.rod("ActuatorPushrod", (x-side*w*.021, h*.22, -l*.08),
                  (x*1.14, -h*.28, -l*.08), .0018, "steel", segs=40)
    else:
        for x in [-w*.34, w*.34]:
            for side in [-1, 1]:
                upper = (x, h*.45, side*l*.13)
                lower = (x, -h*.30+.00025, side*l*.34)
                m.rod("CarbonStrut", upper, lower, .0023, "carbon", segs=56)
                m.washer("UpperStrutCollar", add(upper, (0, -.0023, 0)), .0032, .0021, .004, "alloy")
                m.rod("FootCollar", mix(upper, lower, .84), lower, .0028, "polymer", segs=48)
            skidlen = max(l*.85, .055)
            m.cylinder("SkidTube", (x, -h*.30, 0), .0025, skidlen, "carbon", "z")
            for side in [-1, 1]:
                m.ellipsoid("RubberEndCap", (x, -h*.30, side*skidlen*.5), (.00265, .00265, .0035), "rubber", 40, 16)
    m.notes += ["Carbon struts, collars, skid caps, soft TPU feet or retract actuator with linkage; root positions match the placement engine."]


def rounded_outline(w, l, radius, n=12):
    result = []
    for cx, cz, a0 in [(w/2-radius, l/2-radius, 0), (-w/2+radius, l/2-radius, PI/2),
                       (-w/2+radius, -l/2+radius, PI), (w/2-radius, -l/2+radius, 3*PI/2)]:
        result.extend((cx+radius*math.cos(a), cz+radius*math.sin(a)) for a in np.linspace(a0, a0+PI/2, n, endpoint=False))
    return result


def slotted_plate(m, c, w, l, thickness, hole_w, hole_l, mat="carbon"):
    outer = rounded_outline(w, l, min(w, l)*.10)
    inner = rounded_outline(hole_w, hole_l, min(hole_w, hole_l)*.15)
    n = len(outer)
    pts = [add(c, (x, y, z)) for y, curve in [(-thickness/2, outer), (-thickness/2, inner),
           (thickness/2, outer), (thickness/2, inner)] for x, z in curve]
    faces = []
    for i in range(n):
        j = (i+1)%n
        faces += [(i, j, j+n, i+n), (i+2*n, i+3*n, j+3*n, j+2*n),
                  (i, i+2*n, j+2*n, j), (i+n, j+n, j+3*n, i+3*n)]
    m.mesh("SlottedCarbonPlate", pts, faces, mat)
    for y in [-thickness*.32, 0, thickness*.32]:
        m.tube("CarbonLaminateEdge", [add(c, (x, y, z)) for x, z in outer],
               thickness*.018, "carbon_edge", closed=True, steps=1, segs=6)


def multicopter_frame(m):
    s = m.spec
    arm = s["arm_length"]
    micro = s["family"] == "tinyWhoop"
    height = s["size"][1]
    dw = max(arm*.78, .026) if micro else min(max(arm*.54, .060), .092)
    dl = max(arm*.92, .030) if micro else min(max(arm*.68, .076), .116)
    top = max(s["fc_bay"][1]+.007, .009) if micro else max(s["fc_bay"][1]+.020, min(max(height*.28, .028), .050))
    low_t, upper_t = (.0022, .0018) if micro else (.0042, .0030)
    frame_mat = m.plastic if micro else "carbon"
    m.group = "FrameDeck"
    slotted_plate(m, (0, 0, 0), dw, dl, low_t, dw*.35, dl*.50, frame_mat)
    slotted_plate(m, (0, top-upper_t/2, 0), dw*.84, dl*.76, upper_t, dw*.28, dl*.49, frame_mat)
    for x in [-dw*.19, dw*.19]:
        m.box("ElectronicsRail", (x, 0, 0), (dw*.083, low_t, dl*.68), frame_mat, low_t*.17)
    standoff = top-upper_t
    for x in [-dw*.31, dw*.31]:
        for z in [-dl*.25, dl*.25]:
            rr = .0007 if micro else .00145
            m.cylinder("StackStandoff", (x, standoff/2, z), rr, standoff, m.accent, segs=6)
            for y in [standoff*.06, standoff*.94]:
                m.washer("StandoffShoulder", (x, y, z), rr*1.17, rr*.70, standoff*.023, "alloy")
            head_r = .0010 if micro else .0020
            m.fastener((x, top+head_r*.16, z), head_r)
    m.group = "FrameArms"
    arm_w = max(arm*.11, .0032) if micro else max(arm*.095, .0090)
    arm_h = .0022 if micro else .0045
    padr = max(.007, s["stator_max"]*.0005+.003)
    for x, _, z in s["mounts"]:
        direction = unit((x, 0, z))
        inner = mul(direction, dw*.34)
        mount = (x, 0, z)
        # Recess the beam into the pad underside. Equal top planes used to
        # z-fight into the triangular tears visible on the mounting discs.
        arm_end = sub(mount, mul(direction, padr*.82))
        m.beam("ReplaceableArm", add(inner, (0, -arm_h*.045, 0)),
               add(arm_end, (0, -arm_h*.045, 0)), arm_w, arm_h*.91, frame_mat, arm_h*.13)
        m.washer("MotorMountPlate", mount, padr, padr*.24, arm_h, frame_mat, segs=80)
        # Narrow open-centre motor pad avoids a filled cosmetic centre disc.
        for j in range(4):
            a = PI/4+j*PI/2
            q = add(mount, (math.cos(a)*padr*.55, arm_h*.54, math.sin(a)*padr*.55))
            m.washer("MotorMountBushing", q, padr*.105, padr*.055, arm_h*.11, "alloy", segs=32)
        m.fastener(add(inner, (0, arm_h*.41+arm_w*.12*.16, 0)), arm_w*.12)
        if not micro:
            v = (-direction[2], 0, direction[0])
            for t in [.35, .62]:
                q = mix(inner, mount, t)
                m.beam("ArmHarnessClip", add(q, mul(v, -arm_w*.50)), add(q, mul(v, arm_w*.50)),
                       arm_w*.13, arm_h*.14, "polymer", .0003)
    has_ducts = micro or (s["family"] == "cinematic" and s["prop_max"] <= 3.5)
    if has_ducts:
        m.group = "PropellerDucts"
        prop_r = s["prop_max"]*.0254*.5
        nearest = min(norm(sub(a, b)) for i, a in enumerate(s["mounts"]) for b in s["mounts"][i+1:])
        rr = prop_r+max(prop_r*.014, .00022)
        wall = min(.00145 if micro else .0030, nearest*.5-rr-.00018)
        assert wall > .00035, "Ducts cannot fit the catalog motor spacing"
        th = wall/1.75
        dh = .006 if micro else .010
        reference_motor_h = .011 if s["id"] == "frame-whoop75" else .010 if micro else .017
        duct_y = reference_motor_h + (.0014 if micro else .0026) - .0005
        for x, _, z in s["mounts"]:
            c = (x, duct_y, z)
            profile = [(rr, -dh*.44), (rr+th*.15, -dh*.50), (rr+th*1.45, -dh*.50),
                       (rr+th*1.75, -dh*.35), (rr+th*1.75, dh*.37),
                       (rr+th*1.42, dh*.52), (rr+th*.30, dh*.52), (rr, dh*.40)]
            m.profiled_ring("RoundedDuctWall", c, 0, profile, m.plastic, 128)
            for j in range(4):
                a = j*PI/2
                endpoint = rr+wall*.45
                m.beam("DuctSupport", (x+math.cos(a)*padr*.62, arm_h*.08, z+math.sin(a)*padr*.62),
                       (x+endpoint*math.cos(a), c[1]-dh*.44, z+endpoint*math.sin(a)),
                       th*.83, th*.63, m.plastic, th*.15)
            if not micro:
                m.torus("FoamBumperLip", add(c, (0, dh*.34, 0)), rr+th*1.90, th*.47, "rubber", segs=128)
    if not micro:
        m.group = "CameraCage"
        for x in [-dw*.34, dw*.34]:
            m.cylinder("CameraCagePost", (x, .014, dl*.34), .00155, .028, m.accent, segs=48)
            m.fastener((x, .0284, dl*.34), .0020)
            m.box("CameraSideBracket", (x, .012, dl*.42), (.0018, .021, .018), "carbon", .001)
            m.washer("CameraAdjustmentBoss", (x, .012, dl*.421), .0020, .0010, .0022, "alloy", "x", 32)
        m.label((0, top+.00003, -dl*.318), (dw*.54, dl*.082), s["name"].split(" ")[0].upper(), "CARBON AIRFRAME", host="SlottedCarbonPlate")
    m.notes += ["Slotted layered decks, replaceable arms, open-centre motor pads, mounting bushings, hex standoffs, recessed fasteners and camera cage."]


def wing_segment(m, name, span, root_chord, tip_chord, lead0, lead1, thickness,
                 side, t0=0, t1=1, u0=0, u1=1, mat="white", ybase=0, dihedral=0):
    points, faces = [], []
    nr, ns = max(6, int((t1-t0)*42)), 48
    for i in range(nr+1):
        t = t0+(t1-t0)*i/nr
        chord = root_chord*(1-t)+tip_chord*t
        lead = lead0*(1-t)+lead1*t
        local_thickness = thickness*(1-.42*t)
        for j in range(ns):
            a = 2*PI*j/ns
            u = u0+(u1-u0)*(1-math.cos(a))/2
            foil = 5*(.2969*math.sqrt(u)-.1260*u-.3516*u*u+.2843*u**3-.1036*u**4)
            camber = local_thickness*.075*4*u*(1-u)
            y = ybase+dihedral*t+camber-local_thickness*.05 + math.copysign(local_thickness*.5*foil/.5, math.sin(a))
            # NACA thickness expression at its maximum is about .5 for unit t.
            points.append((side*t*span, y, lead-u*chord))
    for i in range(nr):
        for j in range(ns):
            a = i*ns+j
            b = i*ns+(j+1)%ns
            faces.append((a, b, b+ns, a+ns))
    faces += [tuple(range(ns-1, -1, -1)), tuple(nr*ns+j for j in range(ns))]
    m.mesh(name, points, faces, mat, True)
    if t0 == 0:
        for j in range(ns):
            n = m.parts[-1]["normals"][j]
            m.parts[-1]["normals"][j] = unit((0, n[1], n[2]))


def lifting_frame(m):
    s = m.spec
    span, height, length = s["size"]
    area = max(s["wing_area"], span*length*.18)
    mean = min(max(area/span, length*.20), length*.52)
    root_chord, tip_chord = mean*1.38, mean*.62
    br = min(max(height*.23, span*.025), max(mean*.21, .038))
    thick = min(max(mean*.055, .010), .024)
    lead0, lead1 = length*.16, length*.035
    skin = color_material("airframe_skin_"+m.id.replace("-", "_"), "#D9DFDC", .42, .025, "paint")
    accent = color_material("airframe_accent_"+m.id.replace("-", "_"), "#607E72" if "vtol" in m.id else "#3E728F", .43, .12, "paint")
    m.group = "Wing"
    for side in [-1, 1]:
        # The trailing control surface is physically separated from its pocket.
        wing_segment(m, "WingRootPanel", span/2, root_chord, tip_chord, lead0, lead1, thick, side, 0, .28, mat=skin)
        wing_segment(m, "WingOuterLeadingPanel", span/2, root_chord, tip_chord, lead0, lead1, thick, side, .28, .88, 0, .766, skin)
        wing_segment(m, "Aileron", span/2, root_chord, tip_chord, lead0, lead1, thick, side, .282, .878, .774, 1, skin)
        wing_segment(m, "WingTipPanel", span/2, root_chord, tip_chord, lead0, lead1, thick, side, .88, 1, mat=skin)
        # Hinge pins and low-profile service covers lie on the authored skin.
        for t in [.37, .63, .81]:
            chord = root_chord*(1-t)+tip_chord*t
            lead = lead0*(1-t)+lead1*t
            x = side*span*.5*t
            m.cylinder("AileronHingePin", (x, -.0004, lead-chord*.77), .0010, .012, "steel", "x", 32)
        t = .59
        chord, lead = mix((root_chord,), (tip_chord,), t)[0], lead0*(1-t)+lead1*t
        x, z = side*span*.5*t, lead-chord*.38
        y = thick*.40*(1-.42*t)
        m.box("ServoAccessCover", (x, y, z), (span*.041, .0010, chord*.22), "white", .003)
        for dx in [-span*.015, span*.015]:
            m.fastener((x+dx, y+.00065, z), .0011)
        m.box("AileronControlHorn", (x, thick*.12, lead-chord*.91), (.0020, .012, .012), "alloy", .0006)
        m.rod("AileronPushrod", (x, y+.0012, z-chord*.09), (x, thick*.12+.007, lead-chord*.91), .0007, "steel", segs=24)
        # Protective tip strip follows the airfoil rather than hovering above it.
        wing_segment(m, "WingTipAccent", span/2, root_chord, tip_chord, lead0, lead1, thick*1.008,
                     side, .965, 1, mat=accent)
    # Two genuine spar joiner sleeves at the wing root.
    for z in [lead0-root_chord*.26, lead0-root_chord*.54]:
        m.cylinder("WingJoinerTube", (0, -.001, z), .0040, span*.12, "carbon", "x", 64)
    m.group = "Fuselage"
    center_y = br*.12
    join_z = length*.265
    sections = [(-length*.448, br*.045, br*.10, center_y),
                (-length*.397, br*.27, br*.37, center_y),
                (-length*.30, br*.64, br*.80, center_y),
                (-length*.20, br*.95, br*.97, center_y),
                (0, br, br, center_y),
                (length*.17, br*.94, br*.93, center_y),
                (join_z, br*.84, br*.88, center_y)]
    m.hull("LoftedCompositeFuselage", sections, skin, segs=112, subdiv=12)
    # Longitudinal mould split follows the real cross-sections on both sides.
    fine = spline(sections, 12)
    for side in [-1, 1]:
        m.tube("FuselageMouldSeam", [(side*rx*1.001, cy, z) for z, rx, ry, cy in fine], .00025, "seam", steps=1, segs=8)
    # A conforming segmented access hatch follows the fuselage crown.
    m.group = "AvionicsHatch"
    hstart, hend = -length*.255, length*.10
    hatch_rings = [q for q in fine if hstart <= q[0] <= hend]
    pts, faces = [], []
    nh = 28
    for z, rx, ry, cy in hatch_rings:
        for a in np.linspace(PI*.30, PI*.70, nh+1):
            pts.append((rx*math.cos(a)*1.007, cy+ry*math.sin(a)*1.007, z))
    for i in range(len(hatch_rings)-1):
        for j in range(nh):
            a = i*(nh+1)+j
            faces.append((a, a+1, a+nh+2, a+nh+1))
    m.mesh("ConformingServiceHatch", pts, faces, "carbon", True)
    m.parts[-1]["double_sided"] = True
    for z, rx, ry, cy in [hatch_rings[1], hatch_rings[-2]]:
        for side in [-1, 1]:
            m.fastener((side*rx*.43, cy+ry*.907+.0006, z), .00135)
    for z, rx, ry, cy in [hatch_rings[0], hatch_rings[-1]]:
        m.tube("HatchSeal", [(rx*math.cos(a)*1.009, cy+ry*math.sin(a)*1.009, z)
                            for a in np.linspace(PI*.30, PI*.70, 24)], .0005, "rubber", steps=1, segs=8)
    m.group = "Nose"
    mount = s["mounts"][-1]
    firewall_z, firewall_y = mount[2], mount[1]
    radius = min(max(s["stator_max"]*.0005+.003, br*.42), br*.72)
    rearz = join_z
    m.hull("MotorCowling", [(rearz, br*.84, br*.88, center_y),
                           ((rearz+firewall_z)*.5, br*.75, br*.76, (center_y+firewall_y)/2),
                           (firewall_z-.0042, radius*.95, radius*.95, firewall_y)], accent, 96, 12)
    m.tube("CowlingJointSeal", [(br*.84*math.cos(a), center_y+br*.88*math.sin(a), rearz)
                               for a in np.linspace(0, 2*PI, 96, endpoint=False)], .00022, "rubber", closed=True, steps=1, segs=8)
    m.cylinder("MotorFirewall", (0, firewall_y, firewall_z-.0021), radius, .0042, "carbon", "z", 96)
    for j in range(4):
        a = PI/4+j*PI/2
        m.fastener((radius*.72*math.cos(a), firewall_y+radius*.72*math.sin(a), firewall_z+.0013*.16), .0013, "z")
    # Side cooling ports stay on the cowling, with intake rims and dark recesses.
    for side in [-1, 1]:
        m.box("CowlingAirIntake", (side*br*.285, firewall_y, firewall_z-.033), (.0011, br*.26, br*.50), "seam", .002)
    m.group = "Tail"
    tailspan = span*.31
    tailchord = max(length*.145, .070)
    tailz = -length*.39
    for side in [-1, 1]:
        wing_segment(m, "HorizontalStabilizer", tailspan/2, tailchord, tailchord*.78,
                     tailz+tailchord*.5, tailz+tailchord*.30, max(thick*.58, .006), side, mat=skin)
        t = .63
        m.box("ElevatorControlHorn", (side*tailspan*.19, .009, tailz-tailchord*.34), (.0018, .012, .010), "alloy", .0005)
    # Vertical fin: a profiled wing in X-Z is rotated into the Y-Z plane.
    start = len(m.parts)
    fin_h = max(height*.66, length*.105)
    wing_segment(m, "VerticalTailFin", fin_h, tailchord, tailchord*.40,
                 tailz+tailchord*.48, tailz+tailchord*.08, max(thick*.40, .004), 1, mat=skin)
    rotate_parts(m, start, PI/2, "z")
    m.cable("RudderHingeSeam", [(0, .012, tailz-tailchord*.36),
                              (0, fin_h*.54, tailz-tailchord*.30),
                              (0, fin_h*.87, tailz-tailchord*.20)], .0004, "seam")
    if s["architecture"] == "liftCruiseVTOL":
        for side in [-1, 1]:
            m.group = "VTOLBoomLeft" if side < 0 else "VTOLBoomRight"
            mounts = sorted([p for p in s["mounts"][:-1] if p[0]*side > 0], key=lambda p: p[2])
            first, last = mounts[0], mounts[-1]
            by = min(first[1], last[1])-.006
            m.beam("CarbonLiftBoom", (first[0], by, first[2]), (last[0], by, last[2]),
                   max(span*.018, .020), .012, "carbon", .003)
            for mount in mounts:
                radius = max(s["stator_max"]*.0005+.006, .017)
                m.washer("LiftMotorPlate", (mount[0], mount[1]-.002, mount[2]), radius, .003,
                         .004, "carbon", segs=96)
                for j in range(4):
                    a = PI/4+j*PI/2
                    m.washer("LiftMotorMountBushing", (mount[0]+radius*.55*math.cos(a), mount[1]+.0002,
                                                      mount[2]+radius*.55*math.sin(a)), .0020, .0011, .0005, "steel", segs=32)
            for z in [lead0-root_chord*.24, lead0-root_chord*.57]:
                m.box("WingBoomSaddle", (first[0], .006, z), (span*.023, .012, .031), "carbon", .0015)
                m.box("BoomWingClamp", (first[0], by, z), (span*.022, .019, .025), "alloy", .002)
                for dx in [-span*.007, span*.007]:
                    m.fastener((first[0]+dx, by+.0095+.0015*.16, z), .0015)
    m.notes += ["Smooth lofted fuselage, profiled closed wings, separate ailerons, hinge pins, pushrods, access covers, conforming hatch and motor firewall."]


BUILDERS = {"motor": motor, "propeller": propeller, "battery": battery, "esc": electronics,
            "flightController": electronics, "receiver": receiver, "camera": camera,
            "gps": gps, "sensor": sensor, "payload": payload, "servo": servo, "landingGear": landing_gear}


def build(spec):
    m = Asset(spec)
    if spec["kind"] == "frame":
        (multicopter_frame if spec["architecture"] == "multicopter" else lifting_frame)(m)
    else:
        BUILDERS[spec["kind"]](m)
    return m


def airframe_parts(asset):
    """Retain the frame datum so parts line up exactly when reassembled."""
    for role, groups in [("wing", {"Wing"}), ("fuselage", {"Fuselage", "Nose", "AvionicsHatch"})]:
        spec = dict(asset.spec, id=asset.id+"-"+role, name=asset.name+" — "+role, kind=role)
        m = Asset(spec)
        m.parts = copy.deepcopy([p for p in asset.parts if p["section"] in groups])
        m.notes = [f"Exact {role} subset of {asset.id}; coordinates retain its assembly datum."]
        yield m
