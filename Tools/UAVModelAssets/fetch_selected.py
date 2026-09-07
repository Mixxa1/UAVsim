"""Fetch image-search candidates and primary-source supplements for manual review."""
from fetch_references import ROOT, OUT, fetch, candidates
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
from urllib.parse import urlparse

SUPPLEMENTS = {
    'epfl-delta-wing-uav': ['https://media.springernature.com/full/springer-static/image/art%3A10.1007%2Fs13272-024-00727-9/MediaObjects/13272_2024_727_Fig1_HTML.png'],
    'ncstate-bwb-delta': ['https://ntrs.nasa.gov/api/citations/20050169564/downloads/20050169564.pdf'],
    'iai-harpy-ng': ['https://www.iai.co.il/wp-content/uploads/2025/10/MSL-HARPY-NG-Brochure.pdf'],
}
PAGES = {
    'mq-9b-skyguardian':'https://www.ga-asi.com/remotely-piloted-aircraft/mq-9b-skyguardian',
    'hermes-900':'https://www.elbitsystems.com/autonomous/aerial/male-unmanned-aircraft-systems/hermes-900',
    'griff-30':'https://www.griffaviation.com/products/griff-30',
    'griff-60':'https://www.griffaviation.com/products/griff-60',
}

def get(task):
    ident,url,label=task
    folder=OUT/ident;folder.mkdir(exist_ok=True,parents=True)
    ext=Path(urlparse(url).path).suffix.lower()
    if ext not in ['.png','.webp','.jpg','.jpeg','.pdf','.gif']:ext='.jpg'
    dest=folder/(label+ext)
    ok,error=fetch(url,dest)
    print(ident,label,ok,flush=True)
    return dict(id=ident,url=url,file=str(dest.relative_to(ROOT)),download_ok=ok,error=error)

if __name__=='__main__':
    tasks=[]
    for row in json.loads((OUT/'image_search_results.json').read_text()):
        # Obvious mismatches rejected before download.
        if row['id'] in ['iai-harpy-ng','ncstate-bwb-delta']:continue
        for i,img in enumerate(row['images']):
            tasks.append((row['id'],img['url'],f'search-{i+1}'))
    for ident,urls in SUPPLEMENTS.items():
        for i,u in enumerate(urls):tasks.append((ident,u,f'primary-{i+1}'))
    with ThreadPoolExecutor(max_workers=8) as pool:
        rows=list(pool.map(get,tasks))
    for ident,url in PAGES.items():
        p=OUT/ident/'primary-page.html'
        ok,_=fetch(url,p)
        if ok:
            imgs=candidates(p.read_text(errors='replace'),url)
            with ThreadPoolExecutor(max_workers=4) as pool:
                rows.extend(pool.map(get,[(ident,x['url'],f'primary-image-{i+1}') for i,x in enumerate(imgs[:4])]))
    (OUT/'supplements.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
