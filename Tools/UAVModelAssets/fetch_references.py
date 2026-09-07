"""Download public reference pages and candidate images; never use photos as textures.

Uses curl for network access. Run from any directory. Downloaded candidates still
require visual review; a successful HTTP response is not evidence of a model match.
"""
import concurrent.futures
import html
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urljoin, urlparse

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'Assets/UAVModels/references'
OVERRIDES = {
    'dji-mavic-4-pro': 'https://www.dji.com/mavic-4-pro',
    'dji-phantom-3-standard': 'https://www.dji.com/phantom-3-standard',
    'everdrone-first-on-scene': 'https://everdrone.com/news/2023/10/24/e2-drone-to-revolutionize-emergency-response/',
    'griff-30': 'https://www.griffaviation.com/products',
    'griff-60': 'https://www.griffaviation.com/products',
    'avidrone-490tl': 'https://avidrone.com/defense/490tl/',
    'wingtraone-gen-ii': 'https://wingtra.com/mapping-drone-wingtraone/',
    'quantum-systems-trinity-pro': 'https://quantum-systems.com/trinity-pro/',
    'hermes-900': 'https://www.elbitsystems.com/autonomous/hermes-900',
    'ft5-los': 'https://www.wbgroup.pl/en/produkt/ft-5-los-tactical-uav/',
    'aerosonde-mk-4-7': 'https://www.textronsystems.com/products/aerosonde-uas',
    'rq-7b-shadow': 'https://www.army.mil/article/118146/shadow_unmanned_aircraft_system',
    'iai-harop': 'https://www.iai.co.il/p/harop',
    'iai-harpy-ng': 'https://www.iai.co.il/p/harpy',
    'ryan-bqm-34f-firebee-ii': 'https://www.nationalmuseum.af.mil/Visit/Museum-Exhibits/Fact-Sheets/Display/Article/195776/ryan-bqm-34f-firebee-ii/',
    'northrop-aqm-35a': 'https://www.designation-systems.net/dusrm/m-35.html',
    'northrop-aqm-35b': 'https://www.designation-systems.net/dusrm/m-35.html',
    'rockwell-himat': 'https://www.nasa.gov/gallery/highly-maneuverable-aircraft-technology-himat/',
    'hermeus-quarterhorse-mk21': 'https://www.hermeus.com/article/hermeus-achieves-its-first-unmanned-supersonic-flight',
    'north-american-x-10': 'https://www.nationalmuseum.af.mil/Visit/Museum-Exhibits/Fact-Sheets/Display/Article/195756/north-american-x-10/',
}

def fetch(url, destination):
    r = subprocess.run(['curl', '--http1.1', '-L', '-f', '-sS', '--max-time', '25',
                        '-A', 'Mozilla/5.0 UAVsim reference research', url, '-o', str(destination)],
                       capture_output=True, text=True)
    return r.returncode == 0, r.stderr.strip()[:150]

def candidates(s, url):
    result = []
    for tag in re.findall(r'<meta\b[^>]+>', s, re.I):
        if re.search(r'(?:property|name)=[\"\'](?:og:image|twitter:image)[\"\']', tag):
            m = re.search(r'content=["\']([^"\']+)', tag)
            if m: result.append((100, urljoin(url, html.unescape(m[1])), 'social-image'))
    for tag in re.findall(r'<img\b[^>]+>', s, re.I):
        alt = re.search(r'alt=["\']([^"\']*)', tag)
        alt = html.unescape(alt[1]) if alt else ''
        for m in re.finditer(r'(?:src|data-src|data-original)=["\']([^"\']+)', tag):
            src = urljoin(url, html.unescape(m[1]))
            if not src.startswith('http') or any(k in src.lower() for k in ['.svg','logo','icon','favicon','avatar']): continue
            score = 10 + (15 if alt else 0) + (15 if any(k in (src+alt).lower() for k in ['drone','aircraft','product','hero','himat','griff','490','ft-5','shadow']) else 0)
            result.append((score, src, alt))
    # Background images are common in aircraft manufacturers' product pages.
    for m in re.finditer(r'url\(["\']?([^\)"\']+\.(?:jpg|png|webp)(?:\?[^\)"\']*)?)["\']?\)', s):
        result.append((30, urljoin(url, html.unescape(m[1])), 'background-image'))
    seen=set()
    return [dict(url=u,caption=a,score=p) for p,u,a in sorted(result, reverse=True) if not (u in seen or seen.add(u))][:12]

def process(profile):
    ident = profile['id']
    url = OVERRIDES.get(ident, profile['source'])
    if not url or profile['kind'] != 'real': return None
    url = re.sub(r'/specs$', '', url)
    folder=OUT/ident
    folder.mkdir(parents=True, exist_ok=True)
    page=folder/'page.html'
    ok,error=fetch(url,page)
    row=dict(id=ident,page=url,download_ok=ok,error=error,images=[])
    if ok:
        for i,item in enumerate(candidates(page.read_text(errors='replace'), url)):
            if i >= 4: break
            ext=Path(urlparse(item['url']).path).suffix.lower()
            if ext not in ['.jpg','.jpeg','.webp','.png','.gif']:ext='.jpg'
            dest=folder/f'candidate-{i+1}{ext}'
            success,err=fetch(item['url'],dest)
            item.update(file=str(dest.relative_to(ROOT)),download_ok=success,error=err)
            row['images'].append(item)
    print(f"{ident}: page={ok}, images={sum(x['download_ok'] for x in row['images'])}",flush=True)
    return row

if __name__ == '__main__':
    profiles=json.loads((ROOT/'Tools/UAVModelAssets/catalog_snapshot.json').read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        rows=[r for r in pool.map(process,profiles) if r]
    (OUT/'candidates.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
