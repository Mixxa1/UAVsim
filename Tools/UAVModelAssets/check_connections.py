"""Independent triangle-level contact audit of authored exterior meshes.

AABB broad phase, triangle BVH, segment/triangle intersections, point/triangle
proximity and odd/even ray containment. No scene-parent shortcut: a child node
is not necessarily attached. Cosmetic decals are checked with the same tolerance.
This checks connected solids; it cannot establish mechanical plausibility.
"""
import argparse,json,time
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor
import numpy as np
from airframes import build
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'Assets/UAVModels'

class Solid:
 def __init__(self,p):
  self.name=p['name'];self.points=np.unique(np.asarray(p['points']),axis=0)
  self.tris=np.asarray(p['points'])[p['faces']];self.lo=self.tris.min(axis=1);self.hi=self.tris.max(axis=1)
  self.low=self.lo.min(axis=0);self.high=self.hi.max(axis=0);self.tree=self.bvh(np.arange(len(self.tris)))
 def bvh(self,ids):
  low=self.lo[ids].min(axis=0);high=self.hi[ids].max(axis=0)
  if len(ids)<=16:return(low,high,ids,None)
  mids=(self.lo[ids]+self.hi[ids])/2;k=np.argmax(high-low);order=ids[np.argsort(mids[:,k])];n=len(ids)//2
  return(low,high,self.bvh(order[:n]),self.bvh(order[n:]))

def inside(points,s):
 # Offset direction avoids coincident axis-aligned seams. Count distinct hits.
 if not len(points):return False
 v=np.array([1.,.271829,.143611]);a,b,c=np.moveaxis(s.tris,1,0);e1=b-a;e2=c-a
 h=np.cross(v,e2);det=(e1*h).sum(axis=1);ok=np.abs(det)>1e-16
 inv=np.zeros_like(det);inv[ok]=1/det[ok]
 for p in points:
  d=p-a;u=(d*h).sum(axis=1)*inv;q=np.cross(d,e1);vv=(q*v).sum(axis=1)*inv;t=(q*e2).sum(axis=1)*inv
  hits=np.sort(t[ok&(u>=0)&(vv>=0)&(u+vv<=1)&(t>1e-10)])
  if len(hits) and (1+np.count_nonzero(np.diff(hits)>1e-8))%2:return True
 return False

def segments_hit(tris,other):
 # Every triangle edge against each opposite triangle, in a small BVH leaf.
 starts=tris.reshape(-1,3);ends=tris[:,[1,2,0],:].reshape(-1,3);v=ends-starts
 a=other[:,0];e1=other[:,1]-a;e2=other[:,2]-a
 h=np.cross(v[:,None,:],e2[None,:,:]);det=np.einsum('jk,ijk->ij',e1,h)
 ok=np.abs(det)>1e-18;inv=np.zeros_like(det);inv[ok]=1/det[ok]
 d=starts[:,None,:]-a[None,:,:];u=np.einsum('ijk,ijk->ij',d,h)*inv;q=np.cross(d,e1[None,:,:])
 vv=np.einsum('ik,ijk->ij',v,q)*inv;t=np.einsum('jk,ijk->ij',e2,q)*inv
 return np.any(ok&(u>=-1e-9)&(vv>=-1e-9)&(u+vv<=1+1e-9)&(t>=-1e-9)&(t<=1+1e-9))

def points_near(points,tris,tol):
 a=tris[:,0];b=tris[:,1];c=tris[:,2];ab=b-a;ac=c-a;n=np.cross(ab,ac);n2=(n*n).sum(axis=1)
 ap=points[:,None,:]-a[None,:,:];signed=np.einsum('ijk,jk->ij',ap,n);dist2=signed*signed/np.maximum(n2,1e-30)
 # Barycentric plane projection, with edge-distance fallback.
 d00=(ab*ab).sum(axis=1);d01=(ab*ac).sum(axis=1);d11=(ac*ac).sum(axis=1)
 d20=np.einsum('ijk,jk->ij',ap,ab);d21=np.einsum('ijk,jk->ij',ap,ac);den=np.maximum(d00*d11-d01*d01,1e-30)
 v=(d11*d20-d01*d21)/den;w=(d00*d21-d01*d20)/den
 if np.any((v>=0)&(w>=0)&(v+w<=1)&(dist2<=tol*tol)):return True
 for start,end in [(a,b),(b,c),(c,a)]:
  edge=end-start;delta=points[:,None,:]-start[None,:,:]
  t=np.clip(np.einsum('ijk,jk->ij',delta,edge)/np.maximum((edge*edge).sum(axis=1),1e-30),0,1)
  diff=delta-t[:,:,None]*edge[None,:,:]
  if np.any(np.einsum('ijk,ijk->ij',diff,diff)<=tol*tol):return True
 return False

def contact(a,b,tol):
 if np.any(a.low>b.high+tol) or np.any(b.low>a.high+tol):return False
 # Containment is indispensable for overlapping/embedded solids.
 for aa,bb in [(a,b),(b,a)]:
  ps=aa.points[np.all((aa.points>=bb.low)&(aa.points<=bb.high),axis=1)]
  if len(ps) and inside(ps[np.linspace(0,len(ps)-1,min(9,len(ps)),dtype=int)],bb):return True
 queue=[(a.tree,b.tree)]
 while queue:
  u,v=queue.pop()
  if np.any(u[0]>v[1]+tol) or np.any(v[0]>u[1]+tol):continue
  if u[3] is None and v[3] is None:
   ta=a.tris[u[2]];tb=b.tris[v[2]]
   if segments_hit(ta,tb) or segments_hit(tb,ta) or points_near(ta.reshape(-1,3),tb,tol) or points_near(tb.reshape(-1,3),ta,tol):return True
  elif v[3] is None or (u[3] is not None and np.prod(u[1]-u[0])>=np.prod(v[1]-v[0])):
   queue.extend([(u[2],v),(u[3],v)])
  else:queue.extend([(u,v[2]),(u,v[3])])
 return False

def audit(profile,model=None):
 start=time.time();m=model if model is not None else build(profile);solids=[Solid(p) for p in m.parts];parent=list(range(len(solids)))
 def root(i):
  while parent[i]!=i:parent[i]=parent[parent[i]];i=parent[i]
  return i
 low,high=m.bounds();span=max(np.subtract(high,low));tol=min(.0002,span*.00005)
 # Larger solids first makes union skipping effective without hiding islands.
 order=sorted(range(len(solids)),key=lambda i:-np.prod(solids[i].high-solids[i].low))
 tests=0
 for n,i in enumerate(order):
  a=solids[i]
  for j in order[n+1:]:
   if root(i)==root(j):continue
   b=solids[j]
   if np.any(a.low>b.high+tol) or np.any(b.low>a.high+tol):continue
   tests+=1
   if contact(a,b,tol):parent[root(j)]=root(i)
 groups={}
 for i in range(len(solids)):groups.setdefault(root(i),[]).append(i)
 groups=sorted(groups.values(),key=lambda ids:-sum(len(solids[i].tris) for i in ids))
 islands=[]
 for ids in groups[1:]:
  lo=np.min([solids[i].low for i in ids],axis=0);hi=np.max([solids[i].high for i in ids],axis=0)
  islands.append(dict(parts=[solids[i].name for i in ids],center=((lo+hi)/2).tolist(),size=(hi-lo).tolist()))
 joints=[]
 for joint in m.joints:
  point=np.array([joint['anchor']]);hits=[]
  for s in solids:
   if s.name not in joint['parents'] or np.any(point[0]<s.low-tol) or np.any(point[0]>s.high+tol):continue
   if inside(point,s) or points_near(point,s.tris,tol):hits.append(s.name)
  joints.append(dict(name=joint['name'],anchor=joint['anchor'],attached_to=hits))
 bearings=[]
 for r in m.rotors:
  hubs=[solids[i] for i,p in enumerate(m.parts) if p['group']==r['name'] and p['name'].startswith(('PropHub_','PropellerHub_'))]
  fixed=[solids[i] for i,p in enumerate(m.parts) if not p['group']]
  hits=[s.name for s in fixed if any(contact(h,s,tol) for h in hubs)]
  bearings.append(dict(rotor=r['name'],stationary_contacts=hits))
 row=dict(id=m.id,geometry_sha256=m.fingerprint(),mesh_count=len(solids),contact_tolerance_m=tol,component_count=len(groups),islands=islands,joints=joints,rotor_bearings=bearings,triangle_pairs_examined=tests,seconds=round(time.time()-start,2))
 print(f'{m.id}: {len(groups)} components, {len(islands)} islands, {sum(not j["attached_to"] for j in joints)} loose mounts, {sum(not b["stationary_contacts"] for b in bearings)} loose hubs, {row["seconds"]}s',flush=True)
 return row

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--only');p.add_argument('--workers',type=int,default=4);p.add_argument('--output',default=str(OUT/'connection-audit.json'));args=p.parse_args()
 profiles=json.loads((ROOT/'Tools/UAVModelAssets/catalog_snapshot.json').read_text())
 if args.only:profiles=[p for p in profiles if p['id'] in args.only.split(',')]
 with ProcessPoolExecutor(max_workers=args.workers) as pool:rows=list(pool.map(audit,profiles))
 Path(args.output).write_text(json.dumps(dict(method='Triangle contacts and solid containment; no parent-node shortcuts',models=rows),indent=2)+'\n')
 print('ISLANDS:',sum(len(r['islands']) for r in rows))
