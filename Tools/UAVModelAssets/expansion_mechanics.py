"""Articulated exterior surfaces; hinge locations/travel are visual estimates.

Splits the existing skin (including its paint and labels), retains its normals
and UVs, and closes both sides of each cut. No second wing is overlaid on top.
Axes use the asset convention: metres, Y up, nose +Z.
"""
from math import atan2, cos, sin, pi
from geometry import add, sub, mul, mix, unit, dot, cross, norm

# Only these airframes receive stowing wheel rigs. The other wheel/skid
# assemblies remain fixed. Exterior reference URLs accompany each manifest entry.
RETRACTABLE = {'iai-heron-tp', 'leonardo-falco-xplorer', 'piaggio-p1hh-hammerhead'}
FLAPS = {'ar5', 'twinboom', 'male', 'piaggio'}
FLYING_WINGS = {'ray', 'ebee', 'ux11', 'bramor', 'orbiter', 'deltaquad', 'scaneagle'}

# Exterior reconstructions, not published engineering dimensions. Twin-boom
# wings leave a fixed strip at the boom; P.1HH also leaves its engine nacelles
# clear. Ratios are measured on EACH authored wing after these cuts, not fed
# to the polar as a second set of arbitrary aerodynamic coefficients.
# Segments: start/end along the half-span, root/tip fraction of wing chord.
FLAP_DESIGNS = {
    'tekever-ar5': dict(type='plain', segments=[(.09,.21,.23,.21),(.31,.52,.22,.18)], aileron=(.60,.93)),
    'aeronautics-aerostar': dict(type='plain', segments=[(.10,.205,.29,.27),(.285,.55,.27,.23)], aileron=(.62,.94)),
    'elbit-hermes-450': dict(type='plain', segments=[(.10,.56,.32,.25)], aileron=(.63,.94)),
    'leonardo-falco-evo': dict(type='plain', segments=[(.085,.195,.35,.32),(.29,.565,.32,.28)], aileron=(.64,.95)),
    'leonardo-falco-xplorer': dict(type='singleSlotted', segments=[(.115,.59,.33,.27)], aileron=(.66,.95), slot=.018),
    'iai-heron-mk-ii': dict(type='singleSlotted', segments=[(.085,.205,.30,.28),(.29,.57,.28,.24)], aileron=(.64,.95), slot=.014),
    'iai-heron-tp': dict(type='singleSlotted', segments=[(.075,.20,.34,.31),(.285,.615,.31,.27)], aileron=(.68,.95), slot=.020),
    'piaggio-p1hh-hammerhead': dict(type='fowler', segments=[(.10,.36,.34,.30),(.525,.735,.29,.25)], aileron=(.79,.97), slot=.025, aft=.60),
}


def station(stations, x):
    for a, b in zip(stations, stations[1:]):
        if a[0] <= x <= b[0]:
            return mix(a, b, (x-a[0])/max(1e-12, b[0]-a[0]))
    return stations[0] if x < stations[0][0] else stations[-1]


def vertex(part, fi, j, index):
    normal = part['normals'][index if part['interpolation']=='vertex' else fi*3+j]
    return (part['points'][index], normal, part.get('uv', [])[index] if 'uv' in part else None)


def interpolate(a, b, t):
    return (mix(a[0], b[0], t), unit(mix(a[1], b[1], t)),
            mix(a[2], b[2], t) if a[2] is not None else None)


def clip(poly, normal, offset, sign):
    output = []
    for a, b in zip(poly, poly[1:]+poly[:1]):
        da, db = sign*(dot(a[0], normal)-offset), sign*(dot(b[0], normal)-offset)
        if da >= -1e-11:
            output.append(a)
        if (da > 1e-11 and db < -1e-11) or (da < -1e-11 and db > 1e-11):
            output.append(interpolate(a, b, da/(da-db)))
    return output


def arrays(polys):
    points, normals, uv, faces = [], [], [], []
    for poly in polys:
        if len(poly) < 3:
            continue
        start = len(points)
        points.extend(v[0] for v in poly); normals.extend(v[1] for v in poly)
        if poly[0][2] is not None:
            uv.extend(v[2] for v in poly)
        for j in range(1, len(poly)-1):
            face = (start, start+j, start+j+1)
            if norm(cross(sub(points[face[1]], points[face[0]]),
                          sub(points[face[2]], points[face[0]]))) > 1e-13:
                faces.append(face)
    result = dict(points=points, normals=normals, faces=faces, interpolation='vertex')
    if uv:
        result['uv'] = uv
    return result


def cap(points, normal):
    normal = unit(normal)
    unique = {tuple(round(v, 10) for v in p): p for p in points}
    points = list(unique.values())
    if len(points) < 3:
        return []
    center = mul(tuple(sum(p[k] for p in points) for k in range(3)), 1/len(points))
    u = unit(cross(normal, (0, 1, 0) if abs(normal[1]) < .9 else (1, 0, 0)))
    v = cross(normal, u)
    points.sort(key=lambda p: atan2(dot(sub(p, center), v), dot(sub(p, center), u)))
    return [(p, normal, None) for p in points]


def partition(m, candidates, planes, name, paint):
    """Convex half-space extraction, carrying paint/UV pieces with the shell."""
    inside = []
    outside = []
    for part in candidates:
        polys = [[vertex(part, fi, j, i) for j, i in enumerate(face)]
                 for fi, face in enumerate(part['faces'])]
        inside.append((part, polys))
    for normal, offset in planes:
        remaining = []; intersections = []
        for part, polys in inside:
            keep, leave = [], []
            for poly in polys:
                a, b = clip(poly, normal, offset, 1), clip(poly, normal, offset, -1)
                if len(a) >= 3: keep.append(a)
                if len(b) >= 3: leave.append(b)
                if part.get('_closed_skin') and len(a) >= 3 and len(b) >= 3:
                    intersections.extend(v[0] for v in a if abs(dot(v[0], normal)-offset) < 1e-8)
            if keep: remaining.append((part, keep))
            if leave: outside.append((part, leave))
        # Capping the UNION preserves material patches cut from the original shell.
        boundary = cap(intersections, normal)
        if boundary:
            template = dict(name=name+'CutCap', material=paint, group=None,
                            _closed_skin=True, _wing_owner=candidates[0].get('_wing_owner'))
            remaining.append((template, [[(p, mul(n, -1), uv) for p, n, uv in boundary[::-1]]]))
            outside.append((template, [boundary]))
        inside = remaining
    m.parts = [p for p in m.parts if all(p is not c for c in candidates)]
    moving = []
    for pieces, suffix in [(outside, 'Fixed'), (inside, 'Moving')]:
        # Merge pieces of one mesh so repeated plane cuts do not multiply draw calls.
        merged = {}
        for part, polys in pieces:
            key = (part['name'], part['material'])
            merged.setdefault(key, (part, []))[1].extend(polys)
        for (original, material), (part, polys) in merged.items():
            data = arrays(polys)
            if not data['faces']: continue
            key = name+suffix+original
            count = m.counters.get(key, 0)+1; m.counters[key] = count
            result = dict(part, **data, name=f'{key}_{count:02}')
            result.pop('_surface_bounds', None)
            if 'uv' not in data: result.pop('uv', None)
            m.parts.append(result)
            if suffix == 'Moving': moving.append(result)
    return moving


def surface(m, host, stations, side, first, last, fraction, label, mixing, tip_fraction=None, design=None):
    start, end = stations[-1][0]*first, stations[-1][0]*last
    a, b = station(stations, start), station(stations, end)
    # A straight local hinge interpolates the authored station contours.
    pa = (side*start, a[3], a[2]+(a[1]-a[2])*fraction)
    pb = (side*end, b[3], b[2]+(b[1]-b[2])*(fraction if tip_fraction is None else tip_fraction))
    slope = (pb[2]-pa[2])/(pb[0]-pa[0])
    rear_normal = (slope, 0, -1)
    planes = [((side, 0, 0), start), ((-side, 0, 0), -end),
              (rear_normal, dot(rear_normal, pa))]
    assigned = {name for rig in m.rigs for name in rig['parts']}
    candidates = [p for p in m.parts if host in p.get('_wing_owner', []) and p['name'] not in assigned]
    name = label+('Left' if side < 0 else 'Right')
    moving = partition(m, candidates, planes, name, candidates[0]['material'])
    axis = unit(mul(sub(pb, pa), side))  # positive X for BOTH half-wings
    # A narrow hinge shaft stays on the fixed panel, with the moving skin touching it.
    m.rod(host+'ActuatorHinge', pa, pb, max(.00035, stations[-1][0]*.001), 'metal', segs=12)
    properties=dict(axis_vector=axis, mixing=mixing)
    # Slotted and Fowler panels move away from the fixed trailing edge. The
    # moving frame rides its rail; rotation is still about its own local hinge.
    if design and 'flap' in mixing:
        flap_chord=((pa[2]-a[2])+(pb[2]-b[2]))*.5
        properties['travel_vector_m']=(0,-flap_chord*design.get('slot',0),-flap_chord*design.get('aft',0))
        if norm(properties['travel_vector_m'])>1e-8:
            # A bearing centred ON the hinge axis does not orbit as the flap
            # rotates. It slides along the fixed rail with the traveling frame.
            # This keeps the deployed flap attached throughout the animation.
            for t in (.24,.76):
                bearing=mix(pa,pb,t)
                radius=max(.001,flap_chord*.028)
                m.rod(host+'FlapGuideRail',bearing,add(bearing,properties['travel_vector_m']),radius*.55,'metal',segs=16)
                begin=len(m.parts)
                m.ellipsoid('FlapSliderBearing',bearing,(radius,radius,radius),'anodized',24,12)
                moving.extend(m.parts[begin:])
    m.rig(name, mul(add(pa, pb), .5), 'vector', moving, 30 if 'flap' in mixing else 28, 'control_surface', **properties)
    if design:
        # Integrate the same piecewise-linear outline the skin was cut from.
        cuts=sorted({start,end,*[st[0] for st in stations if start<st[0]<end]})
        covered=panel_area=moment=0
        for x0,x1 in zip(cuts,cuts[1:]):
            st0,st1=station(stations,x0),station(stations,x1)
            w0,w1=st0[1]-st0[2],st1[1]-st1[2]
            h0=pa[2]+(pb[2]-pa[2])*(x0-start)/(end-start)
            h1=pa[2]+(pb[2]-pa[2])*(x1-start)/(end-start)
            f0,f1=max(0,h0-st0[2]),max(0,h1-st1[2])
            dx=x1-x0
            covered+=dx*(w0+w1)/2
            panel_area+=dx*(f0+f1)/2
            moment+=dx*(x0*(w0+w1)/2+dx*(w0/6+w1/3))
        half_area=sum((b[0]-a[0])*((a[1]-a[2])+(b[1]-b[2]))/2 for a,b in zip(stations,stations[1:]))
        # Closed upper/lower skins project to twice the footprint. Vertical
        # hinge/span caps project to zero; cosmetic screws/labels are excluded.
        measured=sum(abs(cross(sub(p['points'][b],p['points'][a]),sub(p['points'][c],p['points'][a]))[1])*.25
            for p in moving if p.get('_closed_skin') for a,b,c in p['faces'])
        assert abs(measured-panel_area)<max(1e-6,panel_area*1e-5),(name,measured,panel_area)
        return dict(name=name,side=side,span_start=first,span_end=last,
            chord_root_ratio=fraction,chord_tip_ratio=tip_fraction if tip_fraction is not None else fraction,
            chord_ratio=panel_area/covered,covered_area_m2=covered,panel_area_m2=panel_area,
            mesh_projected_area_m2=measured,
            covered_area_fraction=covered/(2*half_area),panel_area_fraction=panel_area/(2*half_area),
            lateral_arm=moment/covered/(2*stations[-1][0]),hinge_start=pa,hinge_end=pb,
            travel_vector_m=properties['travel_vector_m'])


def rudder(m, spec):
    name, x, y, z, height, chord, cant, sweep, paint = spec
    if name not in ('VerticalTail', 'TailFin'):
        return
    # One rudder per physical fin; winglets and tailsitter feet are fixed.
    owner = spec
    candidates = [p for p in m.parts if p.get('_fin_owner') == owner]
    a, b = .06, .94
    def hinge(t):
        lead = z+chord*(.48-sweep*t); trail = z+chord*(-.52+.22*t)
        return (x+cant*height*t, y+height*t, trail+(lead-trail)*.30)
    pa, pb = hinge(a), hinge(b)
    direction = 1 if height > 0 else -1
    slope = (pb[2]-pa[2])/(pb[1]-pa[1])
    normal = (0, slope, -1)
    planes = [((0, direction, 0), direction*pa[1]),
              ((0, -direction, 0), -direction*pb[1]), (normal, dot(normal, pa))]
    index = len([r for r in m.rigs if r.get('mixing', {}).get('rudder') == 1])+1
    label = f'{name}Rudder{index:02}'
    moving = partition(m, candidates, planes, label, paint)
    m.rod(name+'RudderShaft', pa, pb, abs(height)*.003, 'metal', segs=12)
    m.rig(label, mul(add(pa, pb), .5), 'vector', moving, 24, 'control_surface',
          axis_vector=unit(sub(pb, pa)), mixing={'rudder': 1})


def author(m, profile):
    if profile['category'] == 'multicopter':
        return
    kind = profile['layout']
    design=FLAP_DESIGNS.get(profile['id'])
    flap_panels=[]
    wing_area=0
    # Remove inspection-only hinge paint; real shafts are added at the actual cuts.
    m.parts = [p for p in m.parts if not p['name'].startswith('ControlSurfaceHinge_')
               and not (p.get('_fin_owner') and 'RudderHinge' in p['name'])]
    for host, stations, paint, side in m.wing_specs:
        if host.startswith('ForwardWing'):
            # The Avanti-derived forward wing's flap follows the main drive,
            # supplying the trim compensation already present in the physics.
            if kind=='piaggio':
                surface(m,host,stations,side,.12,.91,.25,'ForwardWingFlap',{'flap':-1},
                        tip_fraction=.20,design=dict(type='plain'))
            continue
        if host.startswith('MainWing'):
            if kind in FLYING_WINGS:
                surface(m, host, stations, side, .24, .91, .26, 'MainWingElevon',
                        {'elevator': 1, 'aileron': side})
            else:
                aileron=design['aileron'] if design else (.57,.92)
                surface(m, host, stations, side, *aileron, .27, 'MainWingAileron', {'aileron': side})
                if kind in FLAPS:
                    assert design, 'Missing individual flap geometry: '+profile['id']
                    for index,(first,last,root,tip) in enumerate(design['segments']):
                        flap_panels.append(surface(m,host,stations,side,first,last,root,
                            f'MainWingFlap{index+1:02}',{'flap':-1},tip_fraction=tip,design=design))
                    wing_area+=sum((b[0]-a[0])*((a[1]-a[2])+(b[1]-b[2]))/2 for a,b in zip(stations,stations[1:]))
        else:
            mixing = {'elevator': 1}
            if 'VTail' in host:
                slope_sign = 1 if stations[-1][3] > stations[0][3] else -1
                mixing['rudder'] = side*slope_sign
            surface(m, host, stations, side, .10, .94, .32, host+'Elevator', mixing)
    for spec in m.fin_specs:
        rudder(m, spec)
    gear = [r for r in m.rigs if r['role']=='landing_gear']
    m.mechanics = dict(has_flaps=kind in FLAPS, retractable_gear=bool(gear),
        flap_max_degrees=30,
        flap_geometry=dict(type=design['type'],wing_planform_area_m2=wing_area,panels=flap_panels,
            source_url=profile['source_url'],accuracy='Estimated panel outlines from exterior references; ratios/areas are exact for this authored mesh, not factory measurements.') if design else None,
        gear_hinges=[dict(center=r['center'], axis_vector=r['axis_vector'],
            retracted_degrees=r['amplitude_degrees']*r['mixing']['gear']) for r in gear],
        accuracy='Estimated exterior hinge positions and geometry; flight characteristics are derived from the model and flight profile, not manufacturer control laws.')
