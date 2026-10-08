"""Install the validated USDZ collection and its runtime catalogue into UAVsim."""
import hashlib
import json
from pathlib import Path
import shutil
from expansion_flight_specs import SPECS

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'Assets/UAVModels-Expansion'
TARGET=ROOT/'DroneUAVDemo/Resources/Models/UAVModels'


def install():
    source=json.loads((SOURCE/'manifest.json').read_text())
    target=json.loads((TARGET/'manifest.json').read_text())
    byid={m['id']:m for m in target['models']}
    assert set(SPECS)=={m['id'] for m in source['models']}
    for row in source['models']:
        ident=row['id'];path=SOURCE/row['file']
        assert hashlib.sha256(path.read_bytes()).hexdigest()==row['sha256']
        spec=dict(SPECS[ident])
        if row['category']=='multicopter':
            dims={'dji-mini-5-pro':[380,304,91],'dji-avata-2':[212,185,64],
                  'autel-evo-max-4t-v2':[657,563,147]}[ident]
        else:
            dims=[row['wingspan_m']*1000,row['nominal_length_m']*1000,row['static_bounds_size_m'][1]*1000]
        spec['dimensions_mm']=dims
        spec['estimated_fields']=['empty_mass','payload_budget','wing_coefficients','climb_rates',
            'battery_mass','engine_rating','fuel_load','decoder_behavior']
        installed=dict(row,runtime_profile=spec)
        if installed.get('transition') and installed['transition']['mechanism']=='tailsitter':
            installed['transition']=dict(installed['transition'],body_node='Geometry')
        if spec['engine_type']=='turbojet':
            installed['jet_exhaust_center']=[0,0,row['static_bounds_min_m'][2]]
        existing=byid.get(ident)
        if existing and existing.get('runtime_profile') is None:
            raise RuntimeError('Refusing to replace an unrelated existing model: '+ident)
        shutil.copy2(path,TARGET/path.name)
        byid[ident]=installed
    target.update(date='2026-10-06',models=list(byid.values()),
                  expansion_generator='Tools/UAVModelAssets/install_expansion.py')
    (TARGET/'manifest.json').write_text(json.dumps(target,ensure_ascii=False,indent=2)+'\n')
    print(f'Installed {len(source["models"])} animated models; runtime library now contains {len(byid)} aircraft.')


if __name__=='__main__':install()
