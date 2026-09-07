"""Small, deterministic cosmetic mesh authoring library (metres, Y up, +Z nose).

Only exterior display geometry. It contains no airfoil data, performance model,
manufacturing geometry, electronics, or functional internal components.
"""
from math import sin, cos, pi, sqrt
import json
import re
import hashlib

def add(a,b):return tuple(x+y for x,y in zip(a,b))
def sub(a,b):return tuple(x-y for x,y in zip(a,b))
def mul(a,s):return tuple(x*s for x in a)
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def cross(a,b):return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def norm(a):return sqrt(dot(a,a))
def unit(a):return mul(a,1/max(norm(a),1e-12))
def mix(a,b,t):return add(mul(a,1-t),mul(b,t))
def safe(s):return re.sub(r'[^A-Za-z0-9_]','_',s)
def tup(a):return '('+', '.join(f'{v:.7g}' for v in a)+')'
def array(a):return '['+', '.join(str(v) for v in a)+']'

def spline(points,steps=6,closed=False):
    """Catmull–Rom interpolation for exterior curves, not engineering profiles."""
    out=[];n=len(points)
    for i in range(n if closed else n-1):
        a=points[(i-1)%n] if closed or i else points[0]
        b=points[i];c=points[(i+1)%n]
        d=points[(i+2)%n] if closed or i+2<n else points[-1]
        for j in range(steps):
            t=j/steps
            out.append(tuple(.5*(2*b[k]+(-a[k]+c[k])*t+(2*a[k]-5*b[k]+4*c[k]-d[k])*t*t+(-a[k]+3*b[k]-3*c[k]+d[k])*t*t*t) for k in range(len(b))))
    if not closed:out.append(points[-1])
    return out

COLORS={
 'white':('#e0e2e0',.48,.0),'gray':('#828a91',.48,.03),
 'lightgray':('#bac2c7',.37,.15),'dark':('#252b30',.44,.1),
 'carbon':('#20252b',.48,.05),'rubber':('#11151a',.8,0),
 'metal':('#99a5af',.29,.8),'copper':('#a77f57',.32,.65),
 'black':('#24282c',.28,.15),'glass':('#122b3c',.1,.4),
 'red':('#c73532',.35,.06),'orange':('#f17d24',.4,.02),
 'yellow':('#e4bd23',.45,.02),'blue':('#285991',.38,.1),
 'green':('#386750',.44,.03),'olive':('#727d4d',.5,.03),
 'foam':('#cdcec4',.9,0),'silver':('#adb8c3',.27,.75),
 'led_red':('#ff4031',.3,0),'led_green':('#56df9e',.3,0),
 'neo_shell':('#c9ccca',.54,0),'neo_blade':('#353a3d',.43,.03),
 'seam':('#62686b',.67,0),'label':('#edece8',.6,0),
}
TEXTURES={'carbon':('carbon.png',False,5),'ebee_pattern':('ebee-speckle.png',False,2)}
COLORS['ebee_pattern']=('#cccccc',.86,0)

class Model:
    def __init__(self,ident,name):
        self.id=ident;self.name=name;self.parts=[];self.counters={};self.rotors=[];self.wing_specs=[];self.hull_specs=[];self.joints=[];self.pivots=[];self.transition=None
    def tilt(self,name,center,start,hover,cruise):
        """Rigid motor assembly; the propeller spins inside this hinged parent."""
        name='VTOLTilt_'+safe(name)
        parts=self.parts[start:]
        rotors=[r for r in self.rotors if any(p['group']==r['name'] for p in parts)]
        for p in parts:p['pivot']=name
        for r in rotors:r['pivot']=name
        self.pivots.append(dict(name=name,center=center,hover_degrees=hover,cruise_degrees=cruise,
            rotors=[r['name'] for r in rotors],parts=[p['name'] for p in parts if not p['group']]))
        self.transition=dict(mechanism='tilt_rotor',duration_seconds=12,pivots=self.pivots)
    def transition_fraction(self,t):
        # 0..2 hover, 2..5 transition, 5..7 cruise, 7..10 return, 10..12 hover.
        u=max(0,min(1,(t-2)/3)) if t<=7 else 1-max(0,min(1,(t-7)/3))
        return u*u*(3-2*u)
    def rotor_angle(self,r,t):
        if r.get('preview_cruise_spin',True):return t*720*r['direction']
        def integral(u):return u**3-.5*u**4
        if t<=2:running=t
        elif t<=5:running=t-3*integral((t-2)/3)
        elif t<=7:running=3.5
        elif t<=10:running=3.5+3*integral((t-7)/3)
        else:running=t-5
        return running*720*r['direction']
    def joint(self,name,anchor,parents):
        self.joints.append(dict(name=name,anchor=anchor,parents=parents))
    def fingerprint(self):
        data=[{k:p[k] for k in ['name','points','faces','material','group']} for p in self.parts]
        return hashlib.sha256(json.dumps(data,separators=(',',':')).encode()).hexdigest()
    def mesh(self,name,points,faces,mat='gray',smooth=False,group=None):
        # Drop zero-area triangles and compute actual outward geometric normals.
        triangles=[]
        for face in faces:
            for i in range(1,len(face)-1):
                f=(face[0],face[i],face[i+1])
                if norm(cross(sub(points[f[1]],points[f[0]]),sub(points[f[2]],points[f[0]])))>1e-13:
                    triangles.append(f)
        if not triangles:return
        # All authored parts are closed solids. Normalize winding before deriving
        # normals, including orientation changes from a propeller's axis swap.
        center=tuple(sum(p[k] for p in points)/len(points) for k in range(3))
        volume=sum(dot(sub(points[a],center),cross(sub(points[b],center),sub(points[c],center))) for a,b,c in triangles)/6
        if volume<0:triangles=[(a,c,b) for a,b,c in triangles]
        normals=[]
        if smooth:
            ns=[(0,0,0) for _ in points]
            for f in triangles:
                n=cross(sub(points[f[1]],points[f[0]]),sub(points[f[2]],points[f[0]]))
                for j in f:ns[j]=add(ns[j],n)
            normals=[unit(n) for n in ns]
        else:
            normals=[unit(cross(sub(points[f[1]],points[f[0]]),sub(points[f[2]],points[f[0]]))) for f in triangles for _ in f]
        nm=safe(name);cnt=self.counters.get(nm,0)+1;self.counters[nm]=cnt
        self.parts.append(dict(name=f'{nm}_{cnt:02}',points=points,faces=triangles,normals=normals,
                               interpolation='vertex' if smooth else 'faceVarying',material=mat,group=group))
    def box(self,name,c,size,mat='gray',bevel=0):
        h=mul(size,.5);p=[];f=[]
        if bevel<=0:
            p=[add(c,(x*h[0],y*h[1],z*h[2])) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
            f=[(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(1,2,6,5),(0,4,7,3)]
            self.mesh(name,p,f,mat);return
        r=min(bevel,min(h)*.9)
        # Six gridded planes projected onto a rounded cuboid.
        for axis in range(3):
            u=(axis+1)%3;v=(axis+2)%3
            coords=lambda hh:[-hh,-hh+r*.5,-hh+r,hh-r,hh-r*.5,hh]
            cu,cv=coords(h[u]),coords(h[v]);n=len(cu)
            for sign in [-1,1]:
                start=len(p)
                for a in cu:
                    for b in cv:
                        q=[0.,0.,0.];q[axis]=sign*h[axis];q[u]=a;q[v]=b
                        core=tuple(max(-h[k]+r,min(h[k]-r,q[k])) for k in range(3))
                        p.append(add(c,add(core,mul(unit(sub(q,core)),r))))
                for i in range(n-1):
                    for j in range(n-1):
                        a=start+i*n+j;quad=(a,a+n,a+n+1,a+1)
                        f.append(quad if sign>0 else quad[::-1])
        self.mesh(name,p,f,mat,True)
    def ellipsoid(self,name,c,r,mat='gray',segs=24,rings=12):
        p=[];f=[]
        for j in range(rings+1):
            lat=pi*j/rings
            for i in range(segs):
                a=2*pi*i/segs
                p.append(add(c,(r[0]*sin(lat)*cos(a),r[1]*cos(lat),r[2]*sin(lat)*sin(a))))
        for j in range(rings):
            for i in range(segs):
                a=j*segs+i;b=j*segs+(i+1)%segs
                f.append((a,b,b+segs,a+segs))
        self.mesh(name,p,f,mat,True)
    def beam(self,name,a,b,width,height,mat='gray',bevel=0):
        """Rounded rectangular extrusion oriented between two exterior anchors."""
        axis=unit(sub(b,a));v=unit(cross((0,1,0) if abs(axis[1])<.95 else (1,0,0),axis));u=cross(axis,v);c=mix(a,b,.5)
        self.box(name,(0,0,0),(width,height,norm(sub(b,a))),mat,bevel)
        part=self.parts[-1]
        rotate=lambda p:add(add(mul(v,p[0]),mul(u,p[1])),mul(axis,p[2]))
        part['points']=[add(c,rotate(p)) for p in part['points']]
        part['normals']=[rotate(p) for p in part['normals']]
    def rod(self,name,a,b,r,mat='carbon',r2=None,segs=24,group=None):
        r2=r if r2 is None else r2;axis=unit(sub(b,a))
        v=unit(cross(axis,(0,1,0) if abs(axis[1])<.9 else (1,0,0)));w=cross(axis,v)
        p=[add(c,add(mul(v,rr*cos(2*pi*i/segs)),mul(w,rr*sin(2*pi*i/segs)))) for c,rr in [(a,r),(b,r2)] for i in range(segs)]
        # Duplicate cap vertices so normals stay sharp at the rim.
        p+=p[:];f=[tuple(reversed(range(2*segs,3*segs))),tuple(range(3*segs,4*segs))]
        for i in range(segs):
            j=(i+1)%segs;f.append((i,j,j+segs,i+segs))
        self.mesh(name,p,f,mat,True,group)
    def ring(self,name,c,r,t,h,mat='carbon',segs=80):
        p=[]
        for y,rr in [(-h/2,r-t/2),(-h/2,r+t/2),(h/2,r+t/2),(h/2,r-t/2)]:
            p.extend(add(c,(rr*cos(i*2*pi/segs),y,rr*sin(i*2*pi/segs))) for i in range(segs))
        f=[]
        for k in range(4):
            for i in range(segs):
                j=(i+1)%segs;f.append((k*segs+i,k*segs+j,((k+1)%4)*segs+j,((k+1)%4)*segs+i))
        self.mesh(name,p,f,mat,True)
    def profiled_ring(self,name,c,r,profile,mat='gray',segs=96,axis='y'):
        """Revolve a (radial offset, height) cosmetic rim cross-section."""
        orient=lambda x,y,z:(y,x,z) if axis=='x' else (x,z,y) if axis=='z' else (x,y,z)
        p=[add(c,orient((r+dr)*cos(i*2*pi/segs),y,(r+dr)*sin(i*2*pi/segs))) for dr,y in profile for i in range(segs)]
        f=[]
        for j in range(len(profile)):
            for i in range(segs):
                k=(i+1)%segs;nj=(j+1)%len(profile)
                f.append((j*segs+i,j*segs+k,nj*segs+k,nj*segs+i))
        self.mesh(name,p,f,mat,True)
    def tube(self,name,points,r,mat='seam',closed=False,steps=4,segs=8,group=None):
        curve=spline(points,steps,closed) if steps>1 else points
        p=[];n=len(curve)
        for i,c in enumerate(curve):
            axis=unit(sub(curve[(i+1)%n] if closed or i<n-1 else curve[i],curve[(i-1)%n] if closed or i else curve[0]))
            v=unit(cross(axis,(0,1,0) if abs(axis[1])<.9 else (1,0,0)));w=cross(axis,v)
            p.extend(add(c,add(mul(v,r*cos(j*2*pi/segs)),mul(w,r*sin(j*2*pi/segs)))) for j in range(segs))
        f=[]
        for i in range(n if closed else n-1):
            for j in range(segs):f.append((i*segs+j,i*segs+(j+1)%segs,((i+1)%n)*segs+(j+1)%segs,((i+1)%n)*segs+j))
        if not closed:f += [tuple(range(segs-1,-1,-1)),tuple((n-1)*segs+j for j in range(segs))]
        self.mesh(name,p,f,mat,True,group)
    def shell(self,name,outline,levels,mat='gray',steps=5):
        """Soft molded shell, star-shaped XZ contour and (scale,Y) levels."""
        curve=spline(outline,steps,True);n=len(curve)
        p=[(x*s,y,z*s) for s,y in levels for x,z in curve]
        f=[]
        for j in range(len(levels)-1):
            for i in range(n):f.append((j*n+i,j*n+(i+1)%n,(j+1)*n+(i+1)%n,(j+1)*n+i))
        # Center fans support the intentional waisted, non-convex contour.
        for j in [0,len(levels)-1]:
            ci=len(p);p.append((0,levels[j][1],0))
            for i in range(n):f.append((ci,j*n+(i+1)%n,j*n+i) if j==0 else (ci,j*n+i,j*n+(i+1)%n))
        self.mesh(name,p,f,mat,True)
    def surface_point(self,c,hosts,axis='y'):
        """Closest actual triangle surface along the chosen axis (for skin details)."""
        k={'x':0,'y':1,'z':2}[axis];uv=[i for i in range(3) if i!=k];hits=[]
        for part in self.parts:
            if not any(part['name'].startswith(h+'_') for h in hosts):continue
            pts=part['points']
            if '_surface_bounds' not in part:part['_surface_bounds']=(tuple(min(p[i] for p in pts) for i in range(3)),tuple(max(p[i] for p in pts) for i in range(3)))
            lo,hi=part['_surface_bounds']
            if any(c[j]<lo[j]-1e-9 or c[j]>hi[j]+1e-9 for j in uv):continue
            for ids in part['faces']:
                a,b,d=[pts[i] for i in ids]
                e=(b[uv[0]]-a[uv[0]],b[uv[1]]-a[uv[1]]);f=(d[uv[0]]-a[uv[0]],d[uv[1]]-a[uv[1]])
                det=e[0]*f[1]-e[1]*f[0]
                if abs(det)<1e-16:continue
                q=(c[uv[0]]-a[uv[0]],c[uv[1]]-a[uv[1]])
                u=(q[0]*f[1]-q[1]*f[0])/det;v=(e[0]*q[1]-e[1]*q[0])/det
                if u>=-1e-8 and v>=-1e-8 and u+v<=1+1e-8:hits.append(a[k]+u*(b[k]-a[k])+v*(d[k]-a[k]))
        if not hits:raise ValueError(f'{self.id}: no surface under {c} on {hosts}')
        out=list(c);out[k]=min(hits,key=lambda v:abs(v-c[k]));return tuple(out)
    def screw(self,name,c,r,axis='y',mat='metal',group=None,hosts=None,facing=1):
        if hosts:c=self.surface_point(c,hosts,axis)
        v=(0,r*.22*facing,0) if axis=='y' else (0,0,r*.22*facing)
        self.rod(name,c,add(c,v),r,mat,segs=16,group=group)
        for a in [0,pi/2]:
            u=(cos(a)*r*.64,r*.25*facing,sin(a)*r*.64) if axis=='y' else (cos(a)*r*.64,sin(a)*r*.64,r*.25*facing)
            vv=(-u[0],u[1],-u[2]) if axis=='y' else (-u[0],-u[1],u[2])
            self.rod('ScrewRecess',add(c,u),add(c,vv),r*.08,'black',segs=6,group=group)
    def decal(self,texture,c,w,h,axis='y'):
        mat='decal_'+safe(texture);COLORS[mat]=('#ffffff',.62,0);TEXTURES[mat]=(texture+'.png',True,1)
        # Draped onto the existing skin; a flat label above a curved fuselage floats.
        hosts=[p['name'].rsplit('_',1)[0] for p in self.parts if not p['group'] and not p['material'].startswith('decal_')]
        points=[];uv=[];n=8;faces=[];k=1 if axis=='y' else 2
        for i in range(n+1):
            for j in range(n+1):
                x=(i/n-.5)*w;z=(j/n-.5)*h;q=add(c,(x,0,z) if axis=='y' else (x,z,0))
                p=list(self.surface_point(q,hosts,axis));p[k]+=.000001;points.append(tuple(p));uv.append((i/n,1-j/n))
        for i in range(n):
            for j in range(n):
                a=i*(n+1)+j;faces.append((a,a+1,a+n+2,a+n+1) if axis=='y' else (a,a+n+1,a+n+2,a+1))
        self.mesh('Marking',points,faces,mat,True);self.parts[-1]['uv']=uv
    def surface_patch(self,name,outline,hosts,mat='dark'):
        """Paint by splitting host triangles: no coincident overlay or z fighting.

        Convex footprint in XZ. Both colours keep the exact original surface and
        interpolated normals, including along the newly cut material boundary.
        """
        area=sum(a[0]*b[2]-b[0]*a[2] for a,b in zip(outline,outline[1:]+outline[:1]))
        edge_sign=1 if area>0 else -1
        painted=[]
        def clip(poly,a,b,sign):
            def dist(v):return sign*((b[0]-a[0])*(v[0][2]-a[2])-(b[2]-a[2])*(v[0][0]-a[0]))
            out=[]
            for p,q in zip(poly,poly[1:]+poly[:1]):
                dp,dq=dist(p),dist(q)
                if dp>=-1e-12:out.append(p)
                if (dp>1e-12 and dq< -1e-12) or (dp< -1e-12 and dq>1e-12):
                    t=dp/(dp-dq);out.append((mix(p[0],q[0],t),unit(mix(p[1],q[1],t))))
            return out
        def arrays(polys):
            pts=[];normals=[];faces=[]
            for poly in polys:
                n=len(pts);pts.extend(v[0] for v in poly);normals.extend(v[1] for v in poly)
                for j in range(1,len(poly)-1):
                    f=(n,n+j,n+j+1)
                    if norm(cross(sub(pts[f[1]],pts[f[0]]),sub(pts[f[2]],pts[f[0]])))>1e-13:faces.append(f)
            return dict(points=pts,normals=normals,faces=faces,interpolation='vertex')
        for p in list(self.parts):
            if not any(p['name'].startswith(h+'_') for h in hosts):continue
            retained=[]
            for fi,face in enumerate(p['faces']):
                poly=[(p['points'][v],p['normals'][v if p['interpolation']=='vertex' else fi*3+j]) for j,v in enumerate(face)]
                if cross(sub(poly[1][0],poly[0][0]),sub(poly[2][0],poly[0][0]))[1]<=0:
                    retained.append(poly);continue
                for a,b in zip(outline,outline[1:]+outline[:1]):
                    outside=clip(poly,a,b,-edge_sign)
                    if len(outside)>=3:retained.append(outside)
                    poly=clip(poly,a,b,edge_sign)
                    if len(poly)<3:break
                if len(poly)>=3:painted.append(poly)
            p.update(arrays(retained));p.pop('_surface_bounds',None)
        if painted:
            data=arrays(painted);self.mesh(name,data['points'],data['faces'],mat,True)
            self.parts[-1].update(data)
    def hull(self,name,sections,mat='gray',segs=28,subdiv=3):
        # Each ring = (z, horizontal radius, vertical radius, center y).
        rings=spline(sections,max(subdiv,6));p=[];f=[]
        for z,rx,ry,y in rings:
            p.extend((rx*cos(i*2*pi/segs),y+ry*sin(i*2*pi/segs),z) for i in range(segs))
        for j in range(len(rings)-1):
            for i in range(segs):
                a=j*segs+i;b=j*segs+(i+1)%segs;f.append((a,b,b+segs,a+segs))
        f += [tuple(range(segs-1,-1,-1)),tuple((len(rings)-1)*segs+i for i in range(segs))]
        self.mesh(name,p,f,mat,True)
        self.hull_specs.append((name,rings,mat))
    def plate(self,name,outline,thickness,mat='gray',axis=(0,1,0)):
        p=[add(v,mul(axis,t)) for t in [-thickness/2,thickness/2] for v in outline];n=len(outline)
        f=[tuple(range(n-1,-1,-1)),tuple(range(n,2*n))]
        for i in range(n):j=(i+1)%n;f.append((i,j,j+n,i+n))
        # Orient faces away from the centroid (outlines are convex).
        cen=mul(tuple(sum(v[k] for v in p) for k in range(3)),1/len(p));out=[]
        for face in f:
            normal=cross(sub(p[face[1]],p[face[0]]),sub(p[face[2]],p[face[0]]))
            mid=mul(tuple(sum(p[i][k] for i in face) for k in range(3)),1/len(face))
            out.append(face if dot(normal,sub(mid,cen))>=0 else face[::-1])
        self.mesh(name,p,out,mat)
    def wing(self,name,stations,mat='gray',side=1,curved=False):
        # Cosmetic curved section, not a measured aerodynamic profile.
        # station = (x, leading z, trailing z, center y, visual thickness)
        self.wing_specs.append((name,stations,mat,side))
        if curved:
            mirror=(-stations[1][0],)+tuple(stations[1][1:])
            stations=spline([mirror]+stations,10)[10:]
        else:stations=[mix(a,b,i/5) for a,b in zip(stations,stations[1:]) for i in range(5)]+[stations[-1]]
        p=[];n=40
        for x,lead,trail,y,t in stations:
            for j in range(n):
                a=2*pi*j/n;u=(1-cos(a))/2
                p.append((side*x,y+t/2*sin(a),lead+(trail-lead)*u))
        f=[]
        for k in range(len(stations)-1):
            for j in range(n):
                a=k*n+j;b=k*n+(j+1)%n;face=(a,b,b+n,a+n)
                f.append(face if side>0 else face[::-1])
        f.append(tuple(range(n-1,-1,-1)) if side>0 else tuple(range(n)))
        cap=tuple((len(stations)-1)*n+j for j in range(n));f.append(cap if side>0 else cap[::-1])
        self.mesh(name,p,f,mat,True)
        if abs(stations[0][0])<1e-10:
            # The opposite half-wing supplies the continuation at the centreline.
            for i in range(n):
                nn=self.parts[-1]['normals'][i];self.parts[-1]['normals'][i]=unit((0,nn[1],nn[2]))
    def prop(self,name,c,r,axis='y',blades=2,mat='carbon',angle=.3,hub=True,wide=False,direction=None):
        group=safe(name)
        # Diagonal rule: on an X layout, rotors facing each other across the frame turn
        # the same way. It says nothing about a rotor standing on a centreline, where
        # the product is zero and every such rotor comes out +1 — harmless for a single
        # tractor or pusher, but it left the Fotokite's two mid-side motors and both of
        # the Avidrone's tandem rotors turning the same way, so neither airframe could
        # trim its own reaction torque. Those call sites now pass `direction` explicitly.
        direction=direction or (-1 if c[0]*c[2]<0 else 1)
        # Opposite direction for the second rotor at a coaxial station.
        peer=next((q for q in self.rotors if abs(q['center'][0]-c[0])<1e-6 and abs(q['center'][2]-c[2])<1e-6 and axis==q['axis']=='y'),None)
        if peer:direction=-peer['direction']
        self.rotors.append(dict(name=group,center=c,axis=axis,blades=blades,radius_m=r,direction=direction,preview_rpm=120))
        # Vertex coordinates remain global; exporter converts to group-local space.
        if hub:
            off=(0,r*.11,0) if axis=='y' else (0,0,r*.11)
            self.rod('PropHub',sub(c,off),add(c,off),r*.12,'dark',segs=20,group=group)
        for b in range(blades):
            a=angle+2*pi*b/blades;points=[]
            controls=[(.12,.065,0),(.28,.15,.025),(.52,.19,.07),(.76,.155,.09),(.91,.11,.10),(.99,.035,.08),(1,.002,.065)] if wide else [(.10,.05,0),(.22,.08,.012),(.44,.092,.028),(.71,.073,.055),(.92,.047,.07),(.995,.012,.066),(1,.001,.062)]
            sections=spline(controls,5)
            for thickness in [-.012,.012]:
                for span,width,sweep in sections:
                    for edge in [-1,1]:
                        x=span*r;z=(edge*width+sweep)*r*direction;y=(edge*.026*(1-span)+thickness*.55)*r
                        xx=x*cos(a)-z*sin(a);zz=x*sin(a)+z*cos(a)
                        q=(xx,y,zz) if axis=='y' else (xx,zz,y)
                        points.append(add(c,q))
            faces=[];nn=len(sections)*2
            for k in range(len(sections)-1):
                j=k*2;faces.extend([(j,j+2,j+3,j+1),(j+nn+1,j+nn+3,j+nn+2,j+nn)])
                faces.extend([(j,j+nn,j+nn+2,j+2),(j+1,j+3,j+nn+3,j+nn+1)])
            faces.extend([(0,1,nn+1,nn),(nn-2,2*nn-2,2*nn-1,nn-1)])
            self.mesh('Blade',points,faces,mat,True,group)
    def camera(self,c,s=.06,lenses=1,mat='dark',ball=False,mount=None):
        x,y,z=c
        parents=[p['name'] for p in self.parts if not p['group']]
        self.rod('GimbalNeck',(x,y+s*.46,z),(x,y+s*.80,z),s*.13,'dark')
        if mount:
            self.joint('CameraMount',mount,parents)
            mx,my,mz=mount
            self.box('GimbalMountPlate',mount,(s*.95,s*.12,s*.72),'metal',s*.04)
            lower=(mx,my-s*.22,mz)
            self.box('GimbalIsolationPlate',lower,(s*.95,s*.08,s*.72),'metal',s*.03)
            for sx in [-1,1]:
                for sz in [-1,1]:
                    a=(mx+sx*s*.33,my,mz+sz*s*.23);b=add(a,(0,-s*.24,0))
                    self.ellipsoid('VibrationDamper',mix(a,b,.5),(s*.11,s*.15,s*.11),'rubber',16,8)
            self.beam('GimbalSuspensionBracket',lower,(x,y+s*.77,z),s*.26,s*.20,'metal',s*.035)
        self.rod('GimbalYoke',(x-s*.62,y,z),(x+s*.62,y,z),s*.09,'metal')
        if ball:self.ellipsoid('SensorTurret',c,(s*.65,s*.6,s*.65),mat)
        else:self.box('CameraHousing',c,(s*1.2,s,s*.85),mat,s*.12)
        arrangement={1:[(0,0,.3)],2:[(-.28,0,.23),(.26,0,.27)],3:[(.28,.2,.20),(.28,-.22,.16),(-.27,0,.29)],4:[(-.26,.23,.18),(.26,.23,.21),(-.26,-.23,.21),(.26,-.23,.14)],5:[(-.29,.28,.17),(.25,.28,.20),(-.28,-.25,.21),(.25,-.20,.13),(0,.02,.11)]}
        for dx,dy,r in arrangement[min(lenses,5)]:
            p=(x+dx*s,y+dy*s,z+s*.39);end=z+s*(.72 if ball else .51)
            self.rod('LensRim',p,(p[0],p[1],end),s*r,'dark',segs=40)
            self.profiled_ring('OpticalBezel',(p[0],p[1],end+s*.005),s*r*.86,[(s*r*.10*cos(j*2*pi/8),s*.01*sin(j*2*pi/8)) for j in range(8)],'metal',48,axis='z')
            self.rod('OpticalGlass',(p[0],p[1],end-s*.008),(p[0],p[1],end+s*.006),s*r*.78,'glass',segs=40)
        for sx in [-1,1]:
            if not ball:self.screw('CameraCaseScrew',(x+sx*s*.46,y+s*.35,z+s*.42),s*.025,axis='z')
            self.rod('GimbalPivot',(x+sx*s*.58,y,z),(x+sx*s*.66,y,z),s*.14,'dark',segs=32)
        if not ball:
            for j in range(7):self.box('CameraCoolingFin',(x-s*.42+j*s*.14,y+s*.45,z-s*.03),(s*.035,s*.12,s*.45),'seam',s*.012)
    def skids(self,w,y,l,top_y,mat='carbon',mount_w=None,mount_z=None):
        mount_w=w*.64 if mount_w is None else mount_w
        mount_z=l*.28 if mount_z is None else mount_z
        parents=[p['name'] for p in self.parts if not p['group']]
        for side in [-1,1]:
            x=side*w/2
            self.rod('Skid',(x,y,-l*.48),(x,y,l*.48),l*.017,mat)
            for end in [-1,1]:
                anchor=(side*mount_w/2,top_y,end*mount_z)
                self.joint('LandingStrutRoot',anchor,parents)
                self.rod('LandingStrut',anchor,(x,y,end*l*.32),l*.012,mat)
                self.box('LandingStrutSocket',anchor,(l*.05,l*.055,l*.08),mat,l*.008)
                self.rod('FootEnd',(x,y,end*l*.48),(x,y+l*.05,end*l*.55),l*.017,mat)
    def wheels(self,length,bodyy=0,wide=.22,scale=1,nose_z=None):
        parents=[p['name'] for p in self.parts if not p['group']]
        for x,z in [(0,length*.32 if nose_z is None else nose_z),(-length*wide,-length*.17),(length*wide,-length*.17)]:
            y=bodyy-length*.17
            # Main legs retract into the fuselage: mount at its belly, not outside
            # its width. The upper cross-strut is a continuous load path.
            mount=(x*.18,bodyy,z)
            self.joint('LandingGearTrunnion',mount,parents)
            self.rod('GearLeg',mount,(x,y,z),length*.011,'metal')
            self.ellipsoid('GearTrunnion',mount,(length*.021,length*.018,length*.031),'gray',16,8)
            r=length*.04*scale
            self.profiled_ring('RoundedTyre',(x,y,z),r*.79,[(r*.21*cos(j*2*pi/12),r*.24*sin(j*2*pi/12)) for j in range(12)],'rubber',64,axis='x')
            self.rod('WheelHub',(x-r*.30,y,z),(x+r*.30,y,z),r*.46,'metal',segs=24)
            self.rod('StrutPiston',mix(mount,(x,y,z),.12),mix(mount,(x,y,z),.8),length*.012,'silver')
            for side in [-1,1]:
                self.rod('GearFork',mix(mount,(x,y,z),.80),(x+side*r*.35,y,z),length*.008,'gray')
                for j in range(6):
                    a=j*pi/3;cy=y+cos(a)*r*.30;cz=z+sin(a)*r*.30
                    self.rod('WheelBolt',(x+side*r*.29,cy,cz),(x+side*r*.32,cy,cz),r*.05,'dark',segs=8)
            self.rod('GearBrace',(x*.10,bodyy,z-length*.08),mix(mount,(x,y,z),.65),length*.005,'metal')
    def bounds(self):
        pts=[p for part in self.parts for p in part['points']]
        return tuple(min(p[k] for p in pts) for k in range(3)),tuple(max(p[k] for p in pts) for k in range(3))
    def scale(self,factors):
        rotor_by_name={r['name']:r for r in self.rotors}
        for part in self.parts:
            local_factors=factors
            if part['group']:
                r=rotor_by_name[part['group']];c=r['center'];radial=(factors[0]+factors[2 if r['axis']=='y' else 1])/2
                local_factors=[radial]*3
                part['points']=[tuple(c[k]*factors[k]+(p[k]-c[k])*radial for k in range(3)) for p in part['points']]
            else:part['points']=[tuple(p[k]*factors[k] for k in range(3)) for p in part['points']]
            part['normals']=[unit(tuple(n[k]/local_factors[k] for k in range(3))) for n in part['normals']]
        for rotor in self.rotors:
            rotor['center']=tuple(rotor['center'][k]*factors[k] for k in range(3))
            rotor['radius_m']*=(factors[0]+factors[2 if rotor['axis']=='y' else 1])/2
        for joint in self.joints:joint['anchor']=tuple(joint['anchor'][i]*factors[i] for i in range(3))
        for pivot in self.pivots:pivot['center']=tuple(pivot['center'][i]*factors[i] for i in range(3))
    def write(self,path,metadata):
        end=720 if self.transition else 120
        low,high=self.bounds();lines=['#usda 1.0','(','    defaultPrim = "Aircraft"','    metersPerUnit = 1','    upAxis = "Y"',
            '    startTimeCode = 0',f'    endTimeCode = {end}','    timeCodesPerSecond = 60','    framesPerSecond = 60',')',
            'def Xform "Aircraft" (','    kind = "component"',f'    documentation = {json.dumps(self.name+"; approximate exterior visualization, not CAD.")}',
            '    customData = {',f'        string catalogID = {json.dumps(self.id)}',f'        string provenance = {json.dumps(metadata)}','        string forwardAxis = "+Z"','    }',')','{']
        lines+=['    def Scope "Materials"','    {']
        for mat in sorted({p['material'] for p in self.parts}):
            hexcolor,rough,metal=COLORS[mat];srgb=[int(hexcolor[k:k+2],16)/255 for k in [1,3,5]]
            rgb=[v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in srgb]
            lines += [f'        def Material "{mat}"','        {',f'            token outputs:surface.connect = </Aircraft/Materials/{mat}/Surface.outputs:surface>',
                '            def Shader "Surface"','            {','                uniform token info:id = "UsdPreviewSurface"',
                f'                color3f inputs:diffuseColor = {tup(rgb)}',f'                float inputs:roughness = {rough}',f'                float inputs:metallic = {metal}',
                '                token outputs:surface','            }']
            if mat in TEXTURES:
                tex,alpha,_=TEXTURES[mat]
                # Put texture connections in the existing surface shader.
                pos=len(lines)-1
                lines[pos:pos]=[f'                color3f inputs:diffuseColor.connect = </Aircraft/Materials/{mat}/Texture.outputs:rgb>']
                if alpha:lines[pos:pos]=[f'                float inputs:opacity.connect = </Aircraft/Materials/{mat}/Texture.outputs:a>','                float inputs:opacityThreshold = 0.05']
                lines += ['            def Shader "UV"','            {','                uniform token info:id = "UsdPrimvarReader_float2"','                string inputs:varname = "st"','                float2 outputs:result','            }',
                    '            def Shader "Texture"','            {','                uniform token info:id = "UsdUVTexture"',f'                asset inputs:file = @textures/{tex}@',
                    '                token inputs:sourceColorSpace = "sRGB"','                token inputs:wrapS = "repeat"','                token inputs:wrapT = "repeat"',
                    f'                float2 inputs:st.connect = </Aircraft/Materials/{mat}/UV.outputs:result>',
                    '                float3 outputs:rgb','                float outputs:a','            }']
            lines+=['        }']
        lines+=['    }','    def Xform "Geometry"','    {']
        if self.transition and self.transition['mechanism']=='tailsitter':
            lines += ['        float xformOp:rotateX = 0',
                '        float xformOp:rotateX.timeSamples = {'+', '.join(f'{t}: {-90*(1-self.transition_fraction(t/60)):.7g}' for t in range(end+1))+'}',
                '        uniform token[] xformOpOrder = ["xformOp:rotateX"]']
        groups={None:[p for p in self.parts if p['group'] is None and not p.get('pivot')]}
        for pivot in self.pivots:
            groups[pivot['name']]=[p for p in self.parts if p.get('pivot')==pivot['name'] and not p['group']]
            for r in self.rotors:
                if r.get('pivot')==pivot['name']:groups[r['name']]=[p for p in self.parts if p['group']==r['name']]
        for r in self.rotors:
            if not r.get('pivot'):groups[r['name']]=[p for p in self.parts if p['group']==r['name']]
        for group,parts in groups.items():
            origin=(0,0,0)
            pivot=next((p for p in self.pivots if p['name']==group),None)
            if pivot:
                origin=pivot['center']
                lines += [f'        def Xform "{group}"','        {',f'            double3 xformOp:translate = {tup(origin)}',
                    '            float xformOp:rotateX = 0',
                    '            float xformOp:rotateX.timeSamples = {'+', '.join(f'{t}: {pivot["hover_degrees"]+(pivot["cruise_degrees"]-pivot["hover_degrees"])*self.transition_fraction(t/60):.7g}' for t in range(end+1))+'}',
                    '            uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateX"]']
            elif group:
                r=next(r for r in self.rotors if r['name']==group);origin=r['center']
                # Static motor and spinning rotor are siblings under one hinge.
                parent=next((p for p in self.pivots if p['name']==r.get('pivot')),None)
                translation=sub(origin,parent['center']) if parent else origin
                spin='xformOp:rotate'+r['axis'].upper()
                lines += [f'        def Xform "{group}"','        {',f'            double3 xformOp:translate = {tup(translation)}',
                    f'            float {spin} = 0',
                    f'            float {spin}.timeSamples = {{'+', '.join(f'{t}: {self.rotor_angle(r,t/60):.9g}' for t in range(end+1))+'}',
                    f'            uniform token[] xformOpOrder = ["xformOp:translate", "{spin}"]',
                    f'            custom token rotationAxis = "{r["axis"].upper()}"',
                    '            custom string animationNote = "Cyclic demonstration at 120 rpm; not a physical motor speed"']
            for part in parts:
                pts=[sub(p,origin) for p in part['points']];mn=tuple(min(p[k] for p in pts) for k in range(3));mx=tuple(max(p[k] for p in pts) for k in range(3))
                lines += [f'            def Mesh "{part["name"]}" (prepend apiSchemas = ["MaterialBindingAPI"])','            {',
                    '                uniform token subdivisionScheme = "none"','                uniform token orientation = "rightHanded"','                bool doubleSided = false',
                    f'                point3f[] points = [{", ".join(tup(p) for p in pts)}]',
                    f'                int[] faceVertexCounts = {array([3]*len(part["faces"]))}',
                    f'                int[] faceVertexIndices = {array([j for f in part["faces"] for j in f])}',
                    f'                normal3f[] normals = [{", ".join(tup(n) for n in part["normals"])}] (interpolation = "{part["interpolation"]}")',
                    f'                float3[] extent = [{tup(mn)}, {tup(mx)}]',
                    f'                rel material:binding = </Aircraft/Materials/{part["material"]}>','            }']
                if part['material'] in TEXTURES:
                    scale=TEXTURES[part['material']][2];uv=[]
                    for face in part['faces']:
                        normal=cross(sub(pts[face[1]],pts[face[0]]),sub(pts[face[2]],pts[face[0]]))
                        axis=max(range(3),key=lambda k:abs(normal[k]));axes=[k for k in range(3) if k!=axis]
                        uv.extend(part['uv'][i] if 'uv' in part else tuple(pts[i][k]*scale for k in axes) for i in face)
                    lines[-1:-1]=[f'                texCoord2f[] primvars:st = [{", ".join(tup(p) for p in uv)}] (interpolation = "faceVarying")']
            if group and not pivot:lines+=['        }']
            if group and not pivot and parent and group==parent['rotors'][-1]:lines+=['        }']
        lines+=['    }','}'];path.write_text('\n'.join(lines)+'\n')
