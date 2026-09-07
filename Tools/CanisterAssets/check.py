import copy,json,sys
from build import build,CONFIGS,OUT,ROOT,rotate_x
sys.path.insert(0,str(ROOT/'Tools/UAVModelAssets'))
from check_connections import audit
from geometry import add,sub
rows=[]
for c in CONFIGS:
 m=build(c)
 for angle in ([0,45,90] if c['cols']>1 else [0]):
  posed=copy.deepcopy(m)
  for p in posed.parts:
   if 'cover' in p:p['points']=[add(p['hinge'],rotate_x(sub(v,p['hinge']),-angle)) for v in p['points']]
  report=audit({},posed);report['cover_angle']=angle;rows.append(report)
(OUT/'connection-audit.json').write_text(json.dumps(dict(models=rows),indent=2)+'\n')
print('Total islands:',sum(len(r['islands']) for r in rows))
