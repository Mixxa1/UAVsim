"""Cache public research material outside the delivered asset collection.

Reference photographs/renders remain research inputs, not exported textures.
Usage: python3 research_expansion.py /tmp/uav-expansion-research
"""
import concurrent.futures
import html
import json
from pathlib import Path
import re
import sys
import urllib.request

from expansion_catalog import CATALOG, DATE


def get(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(request, timeout=35) as response:
        return response.read(), response.url, response.headers.get_content_type()


def research(profile, output):
    ident = profile['id']
    folder = output / ident
    folder.mkdir(parents=True, exist_ok=True)
    record = dict(id=ident, requested_url=profile['source_url'], checked_on=DATE,
                  published_dimensions=profile['published'], images=[])
    try:
        data, resolved, mime = get(profile['source_url'])
        record.update(resolved_url=resolved, mime_type=mime, bytes=len(data), status='fetched')
        if mime == 'application/pdf' or data.startswith(b'%PDF'):
            (folder / 'source.pdf').write_bytes(data)
        else:
            text = data.decode('utf-8', errors='replace')
            (folder / 'source.html').write_text(text)
            text = html.unescape(text).replace('\\/', '/')
            # Product filenames and nearby img alt text help exclude nav/footer art.
            tokens = [t.lower() for t in re.findall(r'[A-Za-z0-9]+', profile['name'])
                      if len(t) > 2 and t.lower() not in ('aerovironment', 'aeronautics', 'leonardo')]
            candidates = {}
            for match in re.finditer(r'https?://[^\s\"<>;()]+?\.(?:png|jpe?g|webp)', text):
                url = match.group(0)
                nearby = text[max(0, match.start()-180):match.end()+180].lower()
                lower = url.lower()
                if any(t in lower for t in ('logo', 'icon', 'footer', 'flag', 'cookie')):
                    continue
                score = sum(5 for token in tokens if token in lower)
                score += sum(1 for token in tokens if token in nearby)
                score += 2 if any(word in lower for word in ('hero', 'front', 'top', 'flying', 'standing', 'render')) else 0
                if re.search(r'-\d{2,4}x\d{2,4}\.', lower):
                    score -= 4
                if score > 0:
                    candidates[url] = max(score, candidates.get(url, 0))
            for i, url in enumerate(sorted(candidates, key=lambda u: -candidates[u])[:3]):
                try:
                    image, _, image_mime = get(url)
                    if not image_mime.startswith('image/'):
                        continue
                    path = folder / f'reference-{i}.image'
                    path.write_bytes(image)
                    record['images'].append(dict(url=url, local_file=path.name, bytes=len(image),
                                                  type='Manufacturer image; photo/render status checked visually'))
                except Exception as error:
                    record['images'].append(dict(url=url, error=str(error)))
    except Exception as error:
        record.update(status='not_fetched', error=str(error))
    (folder / 'provenance.json').write_text(json.dumps(record, ensure_ascii=False, indent=2)+'\n')
    print(ident, record['status'], len([i for i in record['images'] if 'local_file' in i]), 'images', flush=True)
    return record


if __name__ == '__main__':
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        records = list(pool.map(lambda p: research(p, output), CATALOG))
    (output / 'research.json').write_text(json.dumps(records, ensure_ascii=False, indent=2)+'\n')
