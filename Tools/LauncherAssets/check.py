"""Physical mesh contacts at three carriage positions; native import checked separately."""
import copy,json,sys
from pathlib import Path
from build import build,CONFIGS,OUT,ROOT
sys.path.insert(0,str(ROOT/'Tools/UAVModelAssets'))
from check_connections import audit
from geometry import add,mul
rows=[]
for c in CONFIGS:
 m=build(c)
 for phase in [0,.5,1]:
  posed=copy.deepcopy(m)
  for p in posed.parts:
   if p.get('moving'):p['points']=[add(v,mul(m.motion_vector,phase)) for v in p['points']]
  report=audit({},posed);report['carriage_phase']=phase;rows.append(report)
(OUT/'connection-audit.json').write_text(json.dumps(dict(models=rows),indent=2)+'\n')
print('Total disconnected components:',sum(len(r['islands']) for r in rows))
