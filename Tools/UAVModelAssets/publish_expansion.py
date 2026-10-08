"""Publish the verified offline gallery, contact sheet and portable ZIP packages."""
import html
import json
from pathlib import Path
import zipfile
from PIL import Image, ImageChops, ImageDraw, ImageFont
from validate_expansion import validate, OUT, ROOT


def publish():
    result=validate()
    models=json.loads((OUT/'manifest.json').read_text())['models']
    n=len(models);copters=sum(m['category']=='multicopter' for m in models)
    vtol=sum(m['category']=='vtol' for m in models);winged=n-copters
    mechanisms=[m['mechanics'] for m in models if m.get('mechanics')]
    flap_count=sum(m['has_flaps'] for m in mechanisms)
    gear_count=sum(m['retractable_gear'] for m in mechanisms)
    animated_zip=f'UAVModels-{n}-animated.zip';source_zip=f'UAVModels-{n}-source-and-previews.zip'
    thumbs=OUT/'previews/thumbs';thumbs.mkdir(exist_ok=True)
    font_path='/System/Library/Fonts/Supplemental/Arial.ttf'
    font=ImageFont.truetype(font_path,20)
    tiles=[]
    for model in models:
        image=Image.open(OUT/model['preview']).convert('RGB')
        bg=Image.new('RGB',image.size,image.getpixel((0,0)))
        difference=ImageChops.difference(image,bg)
        channels=difference.split()
        mask=ImageChops.lighter(ImageChops.lighter(channels[0],channels[1]),channels[2]).point(lambda p:255 if p>7 else 0)
        box=mask.getbbox()
        if box:
            x0,y0,x1,y1=box;pad=35
            image=image.crop((max(0,x0-pad),max(0,y0-pad),min(image.width,x1+pad),min(image.height,y1+pad)))
        image.thumbnail((620,410))
        tile=Image.new('RGB',(660,455),'#f0f3f5')
        tile.paste(image,((660-image.width)//2,(410-image.height)//2))
        d=ImageDraw.Draw(tile);d.text((20,420),model['name'],fill='#20303a',font=font)
        tile.save(thumbs/(model['id']+'.jpg'),quality=93)
        tiles.append(tile)
    sheet=Image.new('RGB',(1980,455*-(-n//3)),'#f0f3f5')
    for i,tile in enumerate(tiles):sheet.paste(tile,((i%3)*660,(i//3)*455))
    sheet.save(OUT/'previews/overview.jpg',quality=93)
    # Readable ten-aircraft sheets are useful for reviewing the entire collection.
    for page in range(-(-n//10)):
        group=tiles[page*10:(page+1)*10]
        image=Image.new('RGB',(1320,455*-(-len(group)//2)),'#f0f3f5')
        for i,tile in enumerate(group):image.paste(tile,((i%2)*660,(i//2)*455))
        image.save(OUT/'previews'/f'overview-{page+1}.jpg',quality=93)
    data=json.dumps(models,ensure_ascii=False).replace('</','<\\/')
    page='''<!doctype html>
<html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>__N__ новых БЛА · USDZ</title>
<style>
:root{font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#152b38;background:#eef2f5;--green:#087c63}*{box-sizing:border-box}body{margin:0}button,input,a{font:inherit}button,a{touch-action:manipulation}a{color:var(--green)}.wrap{max-width:1480px;margin:auto;padding:40px 32px}header{display:flex;gap:30px;align-items:center;justify-content:space-between}h1{font-size:clamp(32px,4vw,55px);letter-spacing:-2px;line-height:1.1;margin:12px 0 16px}.eyebrow{font-size:12px;letter-spacing:2px;text-transform:uppercase;color:#527284}header p{max-width:680px;color:#55707f;margin:0}.downloads{display:flex;flex-wrap:wrap;gap:10px;margin:25px 0}.downloads a,.primary{background:#163847;color:white;padding:11px 18px;border-radius:10px;text-decoration:none;border:0;cursor:pointer}.downloads a.secondary{background:white;color:#163847;border:1px solid #c7d5dd}.summary{background:white;border:1px solid #dce5eb;border-radius:18px;padding:23px 30px;min-width:260px}.summary strong{font-size:34px;line-height:1}.summary p{font-size:13px;margin:6px 0}.verified{display:inline-flex;align-items:center;gap:6px;color:var(--green);font-size:12px;background:#e2f4ed;padding:4px 9px;border-radius:20px}.verified:before{content:'●';font-size:8px}.toolbar{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin:34px 0 20px}.toolbar input{border:1px solid #c8d8e1;background:white;border-radius:10px;padding:11px 15px;flex:1;min-width:240px}.filters{display:flex;gap:5px;flex-wrap:wrap}.filters button{border:1px solid #c8d8e1;border-radius:9px;background:white;color:#355360;padding:10px 14px;cursor:pointer}.filters .selected{background:#163847;color:white;border-color:#163847}.count{font-size:13px;color:#657e8a}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px}.card{background:white;border:1px solid #dae4ea;border-radius:17px;overflow:hidden}.picture{border:0;display:block;background:#f0f3f5;width:100%;padding:0;cursor:pointer}.picture img{width:100%;aspect-ratio:660/410;object-fit:cover;display:block}.content{padding:19px 20px}.content h2{font-size:19px;letter-spacing:-.3px;line-height:1.25;margin:10px 0 8px}.small{font-size:12px;color:#6e8591}.meta{display:flex;justify-content:space-between;gap:8px}.actions{display:flex;gap:16px;margin-top:17px;align-items:center}.actions a{font-size:13px;text-decoration:none;font-weight:600}.textbutton{border:0;background:none;color:#163847;padding:0;cursor:pointer;font-size:13px}.category{font-size:11px;font-weight:650;letter-spacing:.7px;color:#607d8a;text-transform:uppercase}.note{max-width:940px;color:#64818e;font-size:13px;margin:28px 0 0}.empty{grid-column:1/-1;padding:50px;text-align:center}dialog{border:0;border-radius:20px;max-width:1160px;width:94vw;padding:0;box-shadow:0 20px 90px #10293555}dialog::backdrop{background:#102833aa;backdrop-filter:blur(6px)}.modalhead{display:flex;align-items:center;justify-content:space-between;padding:20px 25px;border-bottom:1px solid #e1e8ed}.modalhead h2{margin:0;font-size:24px}.close{background:#eef3f5;border:0;border-radius:50%;width:34px;height:34px;cursor:pointer}.modalbody{display:grid;grid-template-columns:1.5fr 1fr}.stage{background:#f0f3f5}.stage img{width:100%;display:block;aspect-ratio:1100/800;object-fit:contain}.angles{display:flex;gap:5px;flex-wrap:wrap;padding:15px}.angles button{padding:7px 10px;background:white;border:1px solid #cfdee6;border-radius:7px;cursor:pointer;font-size:12px}.angles .active{background:#163847;color:white;border-color:#163847}.details{padding:24px}.details h3{font-size:12px;color:#62818e;letter-spacing:1px;text-transform:uppercase;margin:22px 0 7px}.details p{font-size:14px;margin:0 0 12px}.details dl{display:grid;grid-template-columns:1fr 1fr;font-size:13px;gap:6px;margin:17px 0}.details dt{color:#6f8692}.details dd{margin:0;text-align:right}.details .primary{display:block;text-align:center;text-decoration:none;margin:20px 0 12px}.details .source{font-size:13px}.modalnote{font-size:12px!important;color:#78909b}.foot{font-size:12px;color:#8397a1;margin-top:35px}@media(max-width:1050px){.grid{grid-template-columns:repeat(2,1fr)}header{align-items:flex-start}.summary{min-width:210px}}@media(max-width:700px){.wrap{padding:25px 16px}.grid{grid-template-columns:1fr}header{display:block}.summary{margin-top:20px}.modalbody{grid-template-columns:1fr}h1{letter-spacing:-1px}}
</style>
<main class="wrap"><header><div><span class="eyebrow">Коллекция · 06 октября 2026</span><h1>__N__ новых моделей БЛА</h1><p>__MIX__. Детальные корпуса, двигатели, оптика, крепления и встроенные анимации в самостоятельных USDZ-файлах.</p><div class="downloads"><a href="__ANIMATED_ZIP__" download>Скачать __N__ USDZ</a><a class="secondary" href="__SOURCE_ZIP__" download>Исходники и превью</a></div></div><aside class="summary"><strong>__N__ / __N__</strong><p>моделей с анимацией</p><span class="verified">ARKit + SceneKit</span><p>Метры · вверх Y · нос +Z</p></aside></header>
<div class="toolbar"><input id="search" type="search" aria-label="Поиск аппарата" placeholder="Поиск по названию или производителю"><div class="filters"><button class="selected" data-category="all">Все __N__</button><button data-category="fixed-wing">Самолёты __FW__</button><button data-category="vtol">VTOL __VTOL__</button><button data-category="multicopter">Коптеры __COPTERS__</button></div><span class="count" id="count"></span></div><div class="grid" id="grid"></div>
<p class="note">Это авторские визуальные реконструкции по открытым материалам производителей. Основные опубликованные размеры служат ориентиром масштаба; кривизна поверхностей и мелкие детали остаются оценочными. В карточке каждого аппарата указаны источник и проверенные размеры.</p><p class="foot">Пять ракурсов каждого аппарата, отдельный GIF движения и редактируемый USDA. Результаты проверки: <a href="validation-summary.json">validation-summary.json</a>. Источники: <a href="reference-manifest.json">reference-manifest.json</a>.</p></main>
<dialog id="viewer"><div class="modalhead"><h2 id="title"></h2><button class="close" aria-label="Закрыть" onclick="closeViewer()">×</button></div><div class="modalbody"><div class="stage"><img id="large" alt=""><div class="angles" id="angles"></div></div><div class="details" id="details"></div></div></dialog>
<script>
const models=__DATA__;const labels={'fixed-wing':'Самолёт','vtol':'Самолёт VTOL','multicopter':'Мультикоптер'};let category='all',current=null;
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));const number=n=>n.toLocaleString('ru-RU');
function render(){const q=document.getElementById('search').value.toLowerCase();const filtered=models.filter(m=>(category==='all'||m.category===category)&&(`${m.name} ${m.id}`).toLowerCase().includes(q));document.getElementById('count').textContent=`${filtered.length} аппаратов`;document.getElementById('grid').innerHTML=filtered.map(m=>`<article class="card"><button class="picture" onclick="openViewer('${m.id}')" aria-label="Просмотр ${esc(m.name)}"><img loading="lazy" src="previews/thumbs/${m.id}.jpg" alt="${esc(m.name)}"></button><div class="content"><div class="meta"><span class="category">${labels[m.category]}</span><span class="verified">Анимация</span></div><h2>${esc(m.name)}</h2><div class="small">${number(m.triangles)} треугольников · ${m.mesh_count} деталей · ${(m.bytes/1048576).toFixed(2)} МБ</div><div class="actions"><a href="${m.file}" download>Скачать USDZ ↓</a><button class="textbutton" onclick="openViewer('${m.id}')">Ракурсы и движение →</button></div></div></article>`).join('')||'<p class="empty">Аппараты не найдены</p>'}
function view(suffix){const ext=suffix==='-animated'||suffix==='-gear-cycle'?'.gif':'.png';document.getElementById('large').src=`previews/${current.id}${suffix}${ext}`;document.querySelectorAll('.angles button').forEach(b=>b.classList.toggle('active',b.dataset.suffix===suffix))}
function openViewer(id){current=models.find(m=>m.id===id);document.getElementById('title').textContent=current.name;document.getElementById('large').alt=current.name;let views=[['Анимация','-animated'],['Изометрия',''],['Сверху','-top'],['Сбоку','-side'],['Спереди','-front'],['Снизу','-underside']];if(current.transition?.mechanism==='tailsitter')views.push(['Вертикально','-hover'],['Переход','-transition']);if(current.mechanics?.retractable_gear)views.push(['Шасси: цикл','-gear-cycle'],['Шасси выпущено','-gear-down'],['Шасси убрано','-gear-up']);document.getElementById('angles').innerHTML=views.map(([label,suffix])=>`<button data-suffix="${suffix}" onclick="view('${suffix}')">${label}</button>`).join('');const anim=current.transition?.mechanism==='tailsitter'?'Переход: вертикальный взлёт → горизонтальный полёт → возврат. Винты вращаются независимо.':current.transition?.mechanism==='quadplane'?'Вращение винтов с остановкой подъёмных роторов в фазе крейсерского полёта.':current.rotors.length?'Вращение винтов'+(current.rigs.length?' и движение камеры.':'.'):'Движение передних управляющих поверхностей.';document.getElementById('details').innerHTML=`<span class="verified">Проверено ARKit / SceneKit</span><h3>Размеры из источника</h3><p>${esc(current.published_dimensions)}</p><h3>Анимация</h3><p>${anim}</p><dl><dt>Цикл</dt><dd>${current.animation.duration_seconds} с</dd><dt>Частота ключей</dt><dd>60 кадров/с</dd><dt>Анимируемые узлы</dt><dd>${current.rotors.length+current.rigs.length+(current.transition?.mechanism==='tailsitter'?1:0)}</dd><dt>Меши</dt><dd>${current.mesh_count}</dd><dt>Треугольники</dt><dd>${number(current.triangles)}</dd><dt>Материалы</dt><dd>${current.material_count}</dd></dl><a class="primary" download href="${current.file}">Скачать ${esc(current.name)}.usdz</a><a class="source" target="_blank" rel="noopener" href="${current.source_url}">Материалы производителя ↗</a><p class="modalnote" style="margin-top:18px">Показанное движение отрендерено из этого USDZ. Демонстрационная скорость винтов — 120 об/мин. Неопубликованные размеры деталей оценочные.</p>`;view('-animated');document.getElementById('viewer').showModal()}
function closeViewer(){document.getElementById('viewer').close();document.getElementById('large').removeAttribute('src')}
document.getElementById('viewer').addEventListener('close',()=>document.getElementById('large').removeAttribute('src'));document.getElementById('viewer').addEventListener('click',event=>{if(event.target.id==='viewer')closeViewer()});document.getElementById('search').addEventListener('input',render);document.querySelectorAll('.filters button').forEach(b=>b.addEventListener('click',()=>{category=b.dataset.category;document.querySelectorAll('.filters button').forEach(x=>x.classList.toggle('selected',x===b));render()}));render();
</script></html>'''
    for token,value in [('__N__',n),('__FW__',winged-vtol),('__VTOL__',vtol),('__COPTERS__',copters),
                        ('__MIX__',f"{count_ru(winged,'крылатый аппарат','крылатых аппарата','крылатых аппаратов')} и {count_ru(copters,'коптер','коптера','коптеров')}"),
                        ('__ANIMATED_ZIP__',animated_zip),('__SOURCE_ZIP__',source_zip)]:
        page=page.replace(token,str(value))
    (OUT/'catalog.html').write_text(page.replace('__DATA__',data))
    lines=[f'# {n} дополнительных моделей БЛА','',
           f"{count_ru(winged,'самолётный аппарат','самолётных аппарата','самолётных аппаратов')} (включая {vtol} VTOL) и {count_ru(copters,'коптер','коптера','коптеров')}. "
           f'Все {n} USDZ имеют встроенную анимацию, собственные материалы и текстуры. Это авторские приближённые визуальные реконструкции по открытым референсам, а не заводские CAD.','',
           f'[Открыть каталог](catalog.html) · [{n} USDZ]({animated_zip}) · [Исходники и превью]({source_zip})','',
           '## Содержимое','',
           f'- `models/`: {n} самостоятельных USDZ. Внешние фотографии и сетевые ресурсы им не требуются.',
           '- `sources/`: редактируемые USDA и оригинальные процедурные текстуры/маркировки.',
           '- `previews/`: пять ракурсов и GIF каждого аппарата, обзор всей коллекции.',
           '- `manifest.json`: размеры, анимируемые узлы, материалы и SHA-256.',
           '- `reference-manifest.json`: источники, опубликованные размеры и параметры визуальной реконструкции.',
           '- `validation/`, `validation-summary.json`, `connection-audit.json`: результаты проверок.','',
           '## Анимация и масштаб','',
           'Единицы — метры, вверх +Y, нос +Z. Имена вращающихся узлов и осей перечислены в manifest. Статические опоры остаются неподвижными; винт вращается вокруг собственного локального центра. У коптеров направления на противоположных углах совпадают.','',
           'Обычный цикл длится 2 секунды, цикл VTOL — 12 секунд. Частота ключей — 60 кадров/с; вращение до 120 об/мин замедлено для просмотра. Камеры с подвесом выполняют небольшой панорамный или наклонный ход. WingtraRAY поворачивает весь аппарат между вертикальной и горизонтальной ориентациями. У CW-20E, JUMP 20 и DeltaQuad Evo подъёмные винты останавливаются в крейсерской фазе и запускаются при возврате. Роторы, камера и управляющие поверхности сохраняют отдельные узлы.','',
           'Коллекция подключена к симулятору UAVsim через install_expansion.py. Во время полёта демонстрационные циклы отключаются; скорость винтов, камеры и управляющие поверхности читают состояние симуляции. Лётные профили имеют оценочные параметры, отдельно отмеченные в каталоге приложения. Внешний размах крыла, включая наклонные законцовки, привязан к указанному размаху; положение лопастей влияет на статические границы. Размеры, которые источник не публикует, отмечены как оценочные. Для WingtraRAY опубликованный размер не включает посадочный киль.','',
           '## Живая механика в приложении','',
           f'У всех {len(mechanisms)} крылатых моделей выделены шарниры рулей: элероны и рули высоты либо элевоны, рули направления и V-образное смешивание по конструкции аппарата. Закрылки есть у {flap_count} моделей; убираемые стойки и створки — у {gear_count} (Heron TP, Falco Xplorer и P.1HH). Коптеры сохраняют вращение винтов и подвесы камер.','',
           'В панели «Полёт» → «Механизация» доступны автоматический режим закрылков и шасси, взлётное/посадочное положение и ручной выпуск/уборка. Рули получают фактические положения физических сервоприводов, включая задержку и заклинивание. Закрылки меняют подъёмную силу, сопротивление и моменты; шасси меняет сопротивление и контакты колёс. Створки открываются перед движением стоек и закрываются после фиксации. Ограничения и времена приводов рассчитываются для выбранного аппарата. Чрезмерные нагрузки могут повредить панели, стойки и створки; незапертые стойки не удерживают аппарат при контакте с землёй.','',
           'У каждого из восьми аппаратов с закрылками своя длина, хорда, сужение и раскладка секций. У двухбалочных аппаратов оставлены промежутки под балки, у P.1HH — под мотогондолы. Доли площадей и хорд измерены по тем же сеткам и записаны в `mechanics.flap_geometry`; коэффициенты читают эти значения. Щелевые панели и закрылки Фаулера перемещаются на направляющих с подвижными опорами; передние закрылки P.1HH связаны с основным приводом.','',
           '[Heron TP: уборка/выпуск шасси](previews/iai-heron-tp-gear-cycle.gif) · [Falco Xplorer: уборка/выпуск](previews/leonardo-falco-xplorer-gear-cycle.gif) · [P.1HH: уборка/выпуск](previews/piaggio-p1hh-hammerhead-gear-cycle.gif)','',
           'Положение осей, кинематика, углы, времена приводов и аэродинамические поправки являются оценочными. Состояния узлов записываются существующим replay; команды механизации сохраняются с проектом.','',
           '## Проверки','',
           f'Все {n} файлов проходят системный usdchecker --arkit и импортируются в SceneKit. Проверены {result["animated_nodes"]} движущихся узла, совпадение начала и конца циклов, оси шарниров и траектории направляющих. У шасси проверены полная уборка всех стоек и закрытие створок. Во всех {n} моделях статический граф контактов сеток связный; не обнаружены отдельные детали или неподдержанные ступицы. Проверены CRC, 64-байтное выравнивание USDZ, наличие текстур и SHA-256 именно отрендеренных файлов.','',
           'Эти проверки подтверждают совместимость файлов, воспроизведение и соединения в исходной позе. Они не подтверждают заводскую точность, механическую прочность или весь диапазон кинематических зазоров. Исходный вывод валидатора macOS сохранён; возможная диагностика повторной регистрации UsdShade не заменяет проверку итогового Success.','',
           '## Аппараты и источники','',
           '| Аппарат | Класс | Опубликованные размеры / масштаб | Источник |','|---|---|---|---|']
    for m in models:lines.append(f'| {m["name"]} | {labels_ru(m["category"])} | {m["published_dimensions"]} | [Источник]({m["source_url"]}) |')
    lines+=['','## Индивидуальная геометрия закрылков','',
            'Площади относятся к авторской сетке. Доля крыла — площадь участков крыла перед закрылками; доля хорды — площадь панелей, делённая на площадь этих участков. Размеры оценочные.','',
            '| Аппарат | Секций на крыло | Доля крыла | Средняя доля хорды |','|---|---:|---:|---:|']
    for m in models:
        geometry=(m.get('mechanics') or {}).get('flap_geometry')
        if not geometry:continue
        panels=geometry['panels'];covered=sum(p['covered_area_fraction'] for p in panels)
        chord=sum(p['panel_area_fraction'] for p in panels)/covered
        lines.append(f'| {m["name"]} | {len(panels)//2} | {covered*100:.1f}% | {chord*100:.1f}% |')
    lines+=['','## Воспроизводимая сборка','',
            'В репозитории UAVsim: `Tools/UAVModelAssets/build_expansion.py` создаёт ассеты, `audit_expansion.py` проверяет соединения, `render_expansion.swift` создаёт нативные превью, `validate_expansion.py` проверяет готовый набор, `publish_expansion.py` собирает каталог и архивы. Для Python нужны Pillow и NumPy; USD-инструменты и Swift используются системные macOS.','',
            'Пример последовательности:','', '```sh',
            'python3 Tools/UAVModelAssets/build_expansion.py',
            'python3 Tools/UAVModelAssets/audit_expansion.py',
            'swiftc Tools/UAVModelAssets/render_expansion.swift -o /tmp/render-uav-expansion',
            '/tmp/render-uav-expansion Assets/UAVModels-Expansion',
            'python3 Tools/UAVModelAssets/publish_expansion.py','```','']
    (OUT/'README.md').write_text('\n'.join(lines))
    with zipfile.ZipFile(OUT/animated_zip,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for m in models:archive.write(OUT/m['file'],m['file'])
        for m in models:
            if (m.get('mechanics') or {}).get('retractable_gear'):
                for suffix in ('-gear-cycle.gif','-gear-down.png','-gear-transit.png','-gear-up.png'):
                    name=f'previews/{m["id"]}{suffix}';archive.write(OUT/name,name)
        for name in ('README.md','manifest.json','reference-manifest.json','validation-summary.json'):
            archive.write(OUT/name,name)
    with zipfile.ZipFile(OUT/source_zip,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for folder in ('models','sources','previews','validation'):
            for path in sorted((OUT/folder).rglob('*')):
                if path.is_file() and not path.name.startswith('review-sheet-'):archive.write(path,str(path.relative_to(OUT)))
        for name in ('catalog.html','README.md','manifest.json','reference-manifest.json','validation-summary.json','connection-audit.json'):
            archive.write(OUT/name,name)
    print(f'Published {n} animated USDZ, gallery, source archive and preview sheets.')


def count_ru(n,one,few,many):
    form=one if n%10==1 and n%100!=11 else few if 2<=n%10<=4 and not 12<=n%100<=14 else many
    return f'{n} {form}'


def labels_ru(category):
    return {'fixed-wing':'Самолёт','vtol':'Самолёт VTOL','multicopter':'Мультикоптер'}[category]


if __name__=='__main__':publish()
