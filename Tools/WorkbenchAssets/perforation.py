"""Closed panels with real through-holes, using checked contour triangulation."""
import math
from authoring import add


def cross2(a, b, c):
    return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])


def signed_area(points):
    return sum(a[0]*b[1]-b[0]*a[1] for a, b in zip(points, points[1:]+points[:1]))/2


def rounded_rectangle(w, l, r, steps=8):
    points = []
    for x, z, start in [(w/2-r, l/2-r, 0), (-w/2+r, l/2-r, math.pi/2),
                        (-w/2+r, -l/2+r, math.pi), (w/2-r, -l/2+r, 3*math.pi/2)]:
        for j in range(steps):
            a = start+j/steps*math.pi/2
            points.append((x+r*math.cos(a), z+r*math.sin(a)))
    return points


def triangulate(outer, holes):
    polygon = outer[:]
    for hole in sorted(holes, key=lambda p: max(v[0] for v in p), reverse=True):
        hi = max(range(len(hole)), key=lambda i: hole[i][0])
        hx, hz = hole[hi]
        hits = []
        for i, (a, b) in enumerate(zip(polygon, polygon[1:]+polygon[:1])):
            if (a[1] <= hz < b[1]) or (b[1] <= hz < a[1]):
                t = (hz-a[1])/(b[1]-a[1])
                x = a[0]+t*(b[0]-a[0])
                if x > hx+1e-12:
                    hits.append((x, i, (x, hz)))
        if not hits:
            raise ValueError("Hole has no bridge to outer boundary")
        _, i, bridge = min(hits)
        polygon.insert(i+1, bridge)
        polygon[i+2:i+2] = hole[hi:]+hole[:hi]+[hole[hi], bridge]
    active = list(range(len(polygon)))
    faces = []
    epsilon = 1e-15
    while len(active) > 3:
        found = False
        for j, middle in enumerate(active):
            left, right = active[j-1], active[(j+1)%len(active)]
            a, b, c = polygon[left], polygon[middle], polygon[right]
            if cross2(a, b, c) <= epsilon:
                continue
            contains = False
            for index in active:
                p = polygon[index]
                if p == a or p == b or p == c:
                    continue
                if cross2(a, b, p) >= -epsilon and cross2(b, c, p) >= -epsilon and cross2(c, a, p) >= -epsilon:
                    contains = True
                    break
            if not contains:
                faces.append((left, middle, right))
                active.pop(j)
                found = True
                break
        if not found:
            for j, middle in enumerate(active):
                a, c = polygon[active[j-1]], polygon[active[(j+1)%len(active)]]
                if abs(cross2(a, polygon[middle], c)) <= epsilon:
                    active.pop(j)
                    found = True
                    break
            if not found:
                raise ValueError("Cannot triangulate perforated panel")
    if len(active) == 3 and cross2(*(polygon[i] for i in active)) > epsilon:
        faces.append(tuple(active))
    area = sum(cross2(*(polygon[i] for i in f))/2 for f in faces)
    expected = signed_area(outer)+sum(signed_area(h) for h in holes)
    if abs(area-expected) > max(1e-12, expected*1e-7):
        raise ValueError(f"Perforation area mismatch: {area} != {expected}")
    return polygon, faces


def panel(m, name, center, width, length, thickness, holes, material, radius=None):
    outer = rounded_rectangle(width, length, radius or min(width, length)*.06)
    loops = [[(x+r*math.cos(-j*2*math.pi/32), z+r*math.sin(-j*2*math.pi/32)) for j in range(32)]
             for x, z, r in holes]
    contour, triangles = triangulate(outer, loops)
    points = [add(center, (x, y, z)) for y in [-thickness/2, thickness/2] for x, z in contour]
    n = len(contour)
    faces = [f for f in triangles]+[(a+n, c+n, b+n) for a, b, c in triangles]
    for loop in [outer]+loops:
        start = len(points)
        points.extend(add(center, (x, y, z)) for y in [-thickness/2, thickness/2] for x, z in loop)
        k = len(loop)
        for j in range(k):
            a, b = start+j, start+(j+1)%k
            faces.append((a, a+k, b+k, b))
    m.mesh(name, points, faces, material)
