"""Create the offline inspection catalog, contact sheets and deliverable archive."""
from pathlib import Path
import html
import json
import math
import sys
import zipfile
from PIL import Image, ImageDraw
from authoring import OUT, ROOT, font

KINDS = {
    "frame": "Рамы", "motor": "Двигатели", "propeller": "Пропеллеры", "battery": "Аккумуляторы",
    "esc": "ESC", "servo": "Сервоприводы", "flightController": "Полётные контроллеры",
    "receiver": "Приёмники", "camera": "Камеры", "gps": "GPS", "sensor": "Датчики",
    "payload": "Полезная нагрузка", "landingGear": "Шасси", "fuselage": "Фюзеляжи", "wing": "Крылья",
}
manifest = json.loads((OUT/"manifest.json").read_text())
rows = sorted(manifest["models"], key=lambda r: (list(KINDS).index(r["kind"]), r["id"]))
render = json.loads((OUT/"previews/render-report.json").read_text())
assert {r["id"] for r in render} == {r["id"] for r in rows}

def sheet(items, path, title, cols=4, tile=(380, 326)):
    tw, th = tile
    image = Image.new("RGB", (cols*tw, 90+math.ceil(len(items)/cols)*th), (20, 28, 35))
    draw = ImageDraw.Draw(image)
    draw.text((22, 21), title, fill=(231, 238, 233), font=font(28))
    for i, row in enumerate(items):
        x, y = (i%cols)*tw, 90+(i//cols)*th
        preview = Image.open(OUT/row["preview"]).convert("RGB")
        preview.thumbnail((tw-16, th-55), Image.Resampling.LANCZOS)
        image.paste(preview, (x+(tw-preview.width)//2, y))
        draw.text((x+13, y+th-47), row["name"][:35], fill=(213, 224, 220), font=font(16))
        draw.text((x+13, y+th-25), row["id"][:43], fill=(137, 161, 171), font=font(12))
    image.save(path, optimize=True)

for kind, label in KINDS.items():
    items = [r for r in rows if r["kind"] == kind]
    sheet(items, OUT/"previews"/("contact-"+kind+".png"), label)
featured_ids = ["frame-fixedwing-survey-s1", "frame-5inch-freestyle", "motor-2207-1900kv", "fc-f405",
                "camera-mapping-24mp", "battery-6s-1300", "sensor-obstacle-array", "payload-thermal-gimbal"]
sheet([next(r for r in rows if r["id"] == ident) for ident in featured_ids],
      OUT/"overview.png", "WORKBENCH  /  119 USDZ", tile=(400, 355))

buttons = '<button class="filter active" data-kind="all">Все <span>119</span></button>'
for kind, label in KINDS.items():
    count = sum(r["kind"] == kind for r in rows)
    buttons += f'<button class="filter" data-kind="{kind}">{label} <span>{count}</span></button>'
cards = []
for i, row in enumerate(rows):
    cards.append(f'''<article data-kind="{row['kind']}" data-search="{html.escape((row['name']+' '+row['id']+' '+row['brand']).lower())}">
    <button class="image" data-index="{i}" aria-label="Открыть {html.escape(row['name'])}"><img loading="lazy" src="{row['preview']}" alt="{html.escape(row['name'])}"></button>
    <div class="card-body"><small>{KINDS[row['kind']]}</small><h2>{html.escape(row['name'])}</h2>
    <div class="card-foot"><span>{row['triangles']:,} треуг. · {row['bytes']/1048576:.1f} МБ</span><a href="{row['file']}" download>USDZ ↗</a></div></div></article>''')
document = r'''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Workbench — каталог USDZ</title><style>
:root{color-scheme:dark;font-family:Inter,ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#dfebe5;background:#10191f}
*{box-sizing:border-box}body{margin:0}header,main{max-width:1580px;margin:auto;padding:32px 38px}header{padding-top:52px;padding-bottom:20px}
.eyebrow{font-size:12px;letter-spacing:.20em;color:#77bcad}h1{font-weight:550;letter-spacing:-.035em;font-size:48px;margin:17px 0 12px}header p{color:#9db0bb;line-height:1.7;max-width:760px;margin-bottom:23px}
.actions{display:flex;gap:12px;align-items:center;flex-wrap:wrap}.actions a,.download{border:1px solid #365b55;background:#17332f;color:#c6ecdf;border-radius:8px;padding:12px 19px;text-decoration:none;font-size:13px}.actions small{color:#8298a3}
.toolbar{position:sticky;top:0;background:#10191ff4;padding:20px 0;z-index:2;backdrop-filter:blur(14px)}input{width:100%;padding:14px 17px;background:#1b2831;border:1px solid #35454d;border-radius:9px;color:#e9efed;font-size:14px;margin-bottom:15px;outline:none}input:focus{border-color:#80c7b7}
.filters{display:flex;gap:8px;flex-wrap:wrap}.filter{background:#17242c;border:1px solid #2b3c45;border-radius:7px;padding:9px 12px;color:#a9bcc4;cursor:pointer;font:inherit;font-size:12px}.filter span{color:#6f8994;padding-left:5px}.filter.active{background:#23443d;border-color:#4d8377;color:#d8f1e5}.filter.active span{color:#9bc8b9}
.count{font-size:12px;color:#7d98a3;margin:6px 0 17px}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:17px}article{overflow:hidden;border-radius:11px;background:#18252e;border:1px solid #2a3a44;transition:border-color .15s}article:hover{border-color:#577f77}.image{width:100%;padding:0;border:0;background:#202a32;cursor:zoom-in;aspect-ratio:4/3;display:block}.image img{width:100%;height:100%;object-fit:cover;display:block}.card-body{padding:17px 17px 15px}.card-body small{color:#7eaaa0;font-size:11px}h2{font-size:16px;font-weight:550;line-height:1.35;margin:8px 0 18px}.card-foot{display:flex;align-items:center;justify-content:space-between;gap:9px;font-size:11px;color:#8098a4}.card-foot a{color:#bcdfd0;text-decoration:none;padding:6px 8px;background:#263a3b;border-radius:5px}article[hidden]{display:none}
dialog{border:1px solid #40555d;border-radius:14px;background:#15222b;color:#dfebe5;padding:0;max-width:1220px;width:calc(100vw - 38px);max-height:94vh}dialog::backdrop{background:#030a10d9;backdrop-filter:blur(7px)}.modal-head{padding:17px 23px;display:flex;justify-content:space-between;align-items:center}.modal-head h2{margin:0;font-size:20px}.close{background:transparent;border:0;color:#9eb5bd;font-size:28px;cursor:pointer}.hero{display:block;width:100%;height:min(66vh,760px);object-fit:contain;background:#202a32}.modal-foot{padding:18px 23px 24px;display:flex;justify-content:space-between;gap:17px;align-items:center;flex-wrap:wrap}.views{display:flex;gap:8px;flex-wrap:wrap}.views button{background:#263945;border:1px solid #3f5661;border-radius:6px;padding:9px 13px;color:#d0ddd8;cursor:pointer}.views button.active{background:#315b50;border-color:#629889}.dimensions{color:#8ba7b1;font-size:12px;line-height:1.8}.end{margin-top:28px;color:#6f8994;font-size:12px;line-height:1.8;padding-bottom:24px}
@media(max-width:1180px){.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:800px){.toolbar{position:static}.grid{grid-template-columns:repeat(2,minmax(0,1fr))}header,main{padding-left:20px;padding-right:20px}h1{font-size:36px}}@media(max-width:480px){.grid{grid-template-columns:1fr}.hero{height:45vh}.modal-foot{gap:10px}}
</style><header><div class="eyebrow">UAVSIM / ORIGINAL ASSET LIBRARY</div><h1>Workbench в деталях.</h1>
<p>101 компонент, 14 рам и четыре отдельные детали самолётных конструкций. Карбон, металл, печатные платы, оптика и крепёж — в масштабе 1:1. Каждая USDZ содержит геометрию и материалы.</p>
<div class="actions"><a href="Workbench-119-USDZ.zip" download>Скачать 119 USDZ ↓</a><small>+Y вверх · +Z вперёд · размеры в метрах</small></div></header>
<main><div class="toolbar"><input id="search" placeholder="Найти модель, бренд или артикул…" aria-label="Поиск моделей"><div class="filters">BUTTONS</div></div><div class="count" id="count"></div><div class="grid">CARDS</div>
<div class="end">Фюзеляжи и крылья сохраняют начало координат своей рамы и точно совмещаются при сборке. Размеры корпусов и точки установки согласованы с каталогом UAVSim.<br>Оригинальные модели для визуализации; измеренные свойства деталей и инженерная геометрия хранятся в проекте.</div></main>
<dialog id="viewer"><div class="modal-head"><h2 id="title"></h2><button class="close" aria-label="Закрыть">×</button></div><img class="hero" id="hero" alt=""><div class="modal-foot"><div><div class="views"><button data-view="" class="active">Общий вид</button><button data-view="-top">Сверху</button><button data-view="-rear">Сзади</button><button data-view="-side">Сбоку</button><button data-view="-underside">Снизу</button><button data-view="-front">Спереди</button></div><div class="dimensions" id="dimensions"></div></div><a class="download" id="download" download>Скачать USDZ ↓</a></div></dialog>
<script>const models=MODELS;let kind='all',selected;const cards=[...document.querySelectorAll('article')];const query=document.querySelector('#search');function filter(){const q=query.value.trim().toLowerCase();let n=0;cards.forEach(c=>{c.hidden=(kind!=='all'&&c.dataset.kind!==kind)||!c.dataset.search.includes(q);if(!c.hidden)n++});document.querySelector('#count').textContent=`${n} моделей`;}query.addEventListener('input',filter);document.querySelectorAll('.filter').forEach(b=>b.onclick=()=>{kind=b.dataset.kind;document.querySelectorAll('.filter').forEach(x=>x.classList.toggle('active',x===b));filter()});filter();const viewer=document.querySelector('#viewer');function view(suffix){document.querySelector('#hero').src='previews/'+selected.id+suffix+'.png';document.querySelectorAll('.views button').forEach(b=>b.classList.toggle('active',b.dataset.view===suffix));}document.querySelectorAll('.image').forEach(b=>b.onclick=()=>{selected=models[Number(b.dataset.index)];document.querySelector('#title').textContent=selected.name;document.querySelector('#download').href=selected.file;document.querySelector('#hero').alt=selected.name;document.querySelector('#dimensions').textContent=selected.bounds_size_m.map(x=>(x*1000).toFixed(1)).join(' × ')+' мм · '+selected.triangles.toLocaleString('ru')+' треугольников';view('');viewer.showModal();});document.querySelectorAll('.views button').forEach(b=>b.onclick=()=>view(b.dataset.view));document.querySelector('.close').onclick=()=>viewer.close();viewer.addEventListener('click',e=>{if(e.target===viewer)viewer.close()});</script></html>'''
document = document.replace("BUTTONS", buttons).replace("CARDS", "\n".join(cards)).replace("MODELS", json.dumps(rows, ensure_ascii=False))
(OUT/"catalog.html").write_text(document)

readme = """# Workbench — 119 original USDZ models

101 built-in components, 14 complete frames and 4 standalone airframe parts.

- Metres; +Y up; +Z forward. Motor/propeller axes are local +Y.
- USDZ packages contain USDC meshes and all referenced PBR textures.
- Every asset passes macOS usdchecker --arkit and native SceneKit import.
- Labels are projected onto their host surfaces; drilled panels have real through-holes.
- Support audit flags isolated meshes; independent two-/four-module gear kits are explicit.
- Separate Surveyor S1 and Aquila LC-4 wings/fuselages retain their assembly datum.
- Original representative designs based on the project's catalog dimensions;
  these are display assets, not measured commercial replicas or manufacturing CAD.

The archive contains the ready-to-use USDZ files, manifest and inspection reports.
In the authoring folder beside the archive, open `catalog.html` in a browser to browse the six native-rendered views of every asset.

The application uses `DroneUAVDemo/Resources/Models/WorkbenchParts` through
`WorkbenchModelAssetLibrary`, for both Workbench previews and assembled vehicles.
Custom dimensions/parameters and imported CAD continue to use their authored
procedural/CAD geometry. Materials are copied per instance to isolate highlights.

Rebuild with the bundled Python runtime (numpy/Pillow):

    python3 Tools/WorkbenchAssets/build.py --install
    swiftc -O Tools/WorkbenchAssets/render.swift -o /tmp/workbench-model-render
    /tmp/workbench-model-render Assets/WorkbenchModels/models Assets/WorkbenchModels/previews
    python3 Tools/WorkbenchAssets/publish.py
    bash Tools/WorkbenchAssets/probe.sh

Native render/Swift macro compilation requires system services accessible outside
the Codex command sandbox. No internet, model downloads or external textures are
required. Generator sources live in `Tools/WorkbenchAssets`; USDA and all original
texture maps are preserved in `sources`.
"""
(OUT/"README.md").write_text(readme)
if "--no-archive" in sys.argv:
    print(f"Published catalog and contact sheets for {len(rows)} models; archive unchanged")
    raise SystemExit(0)
archive = OUT/"Workbench-119-USDZ.zip"
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for name in ["README.md", "manifest.json", "validation-summary.json", "support-audit.json", "overview.png"]:
        z.write(OUT/name, "Workbench-119-USDZ/"+name)
    for row in rows:
        z.write(OUT/row["file"], "Workbench-119-USDZ/"+row["file"])
# Inspect archive membership without spending a second full decompression pass.
with zipfile.ZipFile(archive) as z:
    assert len([n for n in z.namelist() if n.endswith(".usdz")]) == 119
print(f"Published {len(rows)} models; {archive.stat().st_size/1048576:.1f} MiB archive; {len(render)*6} preview views")
