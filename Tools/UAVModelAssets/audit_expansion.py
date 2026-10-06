"""Triangle-level attachment audit of the expansion; reuses the established auditor."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import json
from pathlib import Path
from expansion_catalog import CATALOG
from expansion_airframes import build
from check_connections import audit

OUT=Path(__file__).resolve().parents[2]/'Assets/UAVModels-Expansion'


def one(profile):
    return audit(profile,build(profile))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--only');parser.add_argument('--workers',type=int,default=4)
    args=parser.parse_args()
    profiles=[p for p in CATALOG if not args.only or p['id'] in args.only.split(',')]
    with ProcessPoolExecutor(max_workers=args.workers) as pool:rows=list(pool.map(one,profiles))
    target=OUT/'connection-audit.json'
    if args.only and target.exists():
        byid={r['id']:r for r in json.loads(target.read_text())['models']}
        byid.update({r['id']:r for r in rows});rows=[byid[p['id']] for p in CATALOG if p['id'] in byid]
    target.write_text(json.dumps(dict(method='Triangle contacts, proximity and solid containment; static authoring pose.',models=rows),indent=2)+'\n')
