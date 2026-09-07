"""Generate an offline review catalogue and a portable collection with an offline review catalogue."""
from pathlib import Path
import json,html,zipfile
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'Assets/UAVModels'
models=json.loads((OUT/'manifest.json').read_text())['models']
refs={r['id']:r for r in json.loads((OUT/'reference-manifest.json').read_text())['references']}
profiles={r['id']:r for r in json.loads((ROOT/'Tools/UAVModelAssets/catalog_snapshot.json').read_text())}
connections={r['id']:r for r in json.loads((OUT/'connection-audit.json').read_text())['models']}
NOTES={
 'dji-neo':'Исправлены ширина и длина, расстояния между кольцами, скульптурный корпус, углубление камеры и форма трёхлопастных винтов. Съёмных верхних решёток нет — как на вашем фото. Добавлены швы, кнопки, нижние опоры моторов, датчики и крепёж.',
 'dji-matrice-350-rtk':'Уточнены ориентация рамы, диагональ 895 мм, нижнее расположение винтов и высота стоек. Добавлены контуры корпуса, вентиляция, крепёж и оптика.',
 'dji-matrice-400':'Исправлены ширина и длина рамы и нижнее расположение винтов. Уточнены корпус, моторные стойки, посадочные опоры и верхний блок датчиков.',
 'dji-flycart-30':'Восемь соосных винтов диаметром 1375 мм. Уточнены расстояния между моторами, грузовой отсек, батареи и шасси.',
 'dji-mavic-3t':'Уточнены пропорции рамы, формованный корпус и разная высота передних и задних лучей. Добавлены шарниры, оптические оправы и швы.',
 'dji-matrice-4t':'Формованный корпус, многосенсорный модуль, верхняя антенна, плоские лучи, шарниры, вентиляция и крепёж.',
 'dji-matrice-30t':'Убраны длинные лыжи; короткие опоры расположены у моторов. Исправлена посадка винтов и добавлены детали корпуса.',
 'dji-matrice-4td-dock-3':'Модель летающего аппарата 4TD с жёсткими лучами, верхней антенной и камерным блоком. Наземная станция Dock 3 не входит в этот файл.',
 'dji-mavic-4-pro':'Сферический подвес камеры, формованный корпус, шарниры лучей и видимые датчики. Размеры корпуса оценены по изображениям.',
 'dji-phantom-3-standard':'Камера соединена с корпусом площадкой, четырьмя демпферами и кронштейном подвеса. Исправлены крепления шасси, посадка оптики, кнопки и крепежа.',
 'fotokite-sigma':'Шесть моторов на углах и серединах передней/задней стороны квадратной рамы. Добавлены внутренние распорки, корпус и подвес камеры.',
 'everdrone-first-on-scene':'Исправлена симметрия шести лучей; стойки шасси входят в корпус через гнёзда и передние обтекатели. Добавлено крепление камеры. За основу взят E2; в проекте указано имя сервиса, точная ревизия не определена.',
 'zipline-platform-1':'Исправлен V-образный хвост; уточнены широкий грузовой нос, прямое красное крыло и два кормовых винта. Поколение P1 и мелкие детали установки винтов оценочные.',
 'wingcopter-198':'Исправлена компоновка: восемь разнесённых моторов — четыре внутренних поворотных и четыре внешних подъёмных. Перестроены крыло, грузовой обтекатель и цельные посадочные стойки, соединённые с крылом и лыжами.',
 'matternet-m2':'Уточнены изогнутые лучи, обтекатели моторов, центральный контейнер, крышка грузового отсека и ручки.',
 'skydio-x10':'Исправлены цвет и пропорции корпуса, прямоугольные лучи, трёхлопастные винты и передний модуль. Габарит из проекта 351×351×160 мм не принят за размер раскрытого аппарата.',
 'brinc-lemur-2':'Перестроены двухуровневая защита, плоская рама, высокий передний блок сенсоров и нижний динамик. Добавлены лампы, стойки, крепёж и вентиляция.',
 'freefly-alta-x':'Открытая карбоновая рама, центральный восьмигранный узел, батареи с ремнями, распорки и подвесное крепление.',
 'griff-30':'Длинный белый корпус, четыре винта, плоские лучи и отдельные посадочные ноги вместо лыж. Размеры оценочные.',
 'griff-60':'Восемь соосных винтов; белый корпус и отдельные посадочные ноги. Общий баннер с Griff 30 не использован как фото Griff 60.',
 'avidrone-490tl':'Два продольных несущих винта, каплевидные обтекатели, открытые грузовые направляющие и наклонные опоры. Масштаб оценочный.',
 'wingtraone-gen-ii':'Широкое оранжевое крыло, два винта, камера и белая хвостовая опора. Показан в горизонтальном полётном положении. Фото нового WingtraRAY исключены.',
 'quantum-systems-trinity-pro':'Исправлены цвет, обычное хвостовое оперение и мотор на вершине единственного киля. Три винта представлены в положении горизонтального полёта.',
 'mq-9b-skyguardian':'Уточнены объём носа, законцовки длинного крыла, V-образный хвост, нижний киль, шасси и четырёхлопастный толкающий винт.',
 'hermes-900':'Уточнены объём передней части, V-образный хвост, трёхлопастный винт, оптический подвес и шасси.',
 'ft5-los':'Две двигательные гондолы, две хвостовые балки, высокое крыло и соединяющая хвостовая поверхность; проработаны винты и шасси.',
 'sensefly-ebee-tac':'Исправлен глубокий V-образный вырез задней кромки. Добавлены оригинальный пятнистый материал, верхний люк, задний винт и нижняя камера.',
 'rq-21-integrator':'Высокое крыло с законцовками, две балки и перевёрнутый V-образный хвост. Добавлены швы панелей и детали носовой оптики.',
 'aerosonde-mk-4-7':'Фиксированное крыло, две балки, перевёрнутый V-образный хвост и задний винт. Изображения Mk 4.8 VTOL исключены.',
 'rq-7b-shadow':'Две хвостовые балки, два киля с соединяющим стабилизатором, задний винт и колёсное шасси.',
 'mq-9a-reaper':'Крыло без законцовок MQ-9B, V-образный хвост и нижний киль. Уточнены фюзеляж, оптика, шасси и четырёхлопастный винт.',
 'iai-harpy':'Дельта без переднего оперения, округлая носовая часть, концевые кили и задний винт; внешняя визуальная модель без внутренних устройств.',
 'iai-harop':'Дельта с передним оперением, концевыми килями, носовым оптическим блоком и задним винтом.',
 'iai-harpy-ng':'Ограниченная подтверждённость: доступна иллюстрация производителя, а не проверенное фото конкретного NG. Использован приблизительный внешний облик семейства с не-оптическим носом.',
 'epfl-delta-wing-uav':'Исправлено переднее положение винта. Белая центральная часть, красные внешние панели, два внутренних киля и верхний люк сопоставлены с рисунком 1 и фото на рисунке 6 статьи.',
 'ncstate-bwb-delta':'Добавлены два внутренних киля, пересмотрена форма внешних панелей, обтекатель двигателя и люк по фотографии Figure 6 на стр. 29 отчёта NASA.',
 'hesa-karrar':'Уточнены объём зелёного фюзеляжа, верхний воздухозаборник и обычное хвостовое оперение; добавлены наружные швы и панели.',
 'ryan-bqm-34f-firebee-ii':'Использован длинноносый Firebee II: нижняя гондола, стреловидные поверхности и оранжевая окраска. Фото коротконосого Firebee исключены.',
 'northrop-aqm-35a':'Уточнён длинный цилиндрический корпус; убрано неподтверждённое переднее оперение. Добавлены панели, наружные крепления и выхлопная часть.',
 'northrop-aqm-35b':'Ограниченная подтверждённость: использованы фото семейства A/Q-4 и размеры варианта B из проекта. Фото именно B не найдено; различия мелких деталей не подтверждены.',
 'rockwell-himat':'Уточнены полнота фюзеляжа, переднее оперение, два киля, нижний воздухозаборник и красно-белая окраска.',
 'hermeus-quarterhorse-mk21':'Использован именно Mk 2.1: уточнены полнота корпуса, стреловидное крыло, обычный хвост, нижний воздухозаборник и шасси.',
 'north-american-x-10':'Уточнены широкая задняя часть, две гондолы, два киля, переднее оперение и колёсное шасси.',
}
NOTES['wingtraone-gen-ii']='Переход из вертикального положения в горизонтальное выполняется наклоном всего аппарата. Винты сохраняют положение относительно крыла и продолжают вращаться. Фото WingtraRAY исключены.'
NOTES['quantum-systems-trinity-pro']='Три моторных узла поворачиваются вместе с винтами. В демонстрационном крейсерском режиме передние винты плавно останавливаются, задний продолжает вращаться. Геометрия шарниров оценочная.'
NOTES['wingcopter-198']+=' Четыре внутренних мотора с винтами наклоняются на шарнирах; внешние сохраняют вертикальные оси и останавливаются в демонстрационном крейсерском режиме.'
NOTES['sensefly-ebee-tac']+=' Крыло и центральная часть образуют непрерывную обшивку; крышка повторяет её кривизну и больше не прорезается корпусом.'
NOTES['epfl-delta-wing-uav']+=' Крышка повторяет поверхность объединённого центрального участка крыла.'
NOTES['ncstate-bwb-delta']+=' Маркировка и люк встроены в сетку обшивки: совпадающие наложенные поверхности удалены.'
for ident in ['ft5-los','rq-21-integrator','rq-7b-shadow','aerosonde-mk-4-7']:
 NOTES[ident]+=' Добавлен округлый обтекатель стыка крыла с корпусом.'
NOTES['ft5-los']+=' Основания моторных гондол расширены плавными обтекателями.'
DATA=[];audit=[]
for m in models:
 r=refs[m['id']];p=profiles[m['id']]
 note=NOTES.get(m['id'],'Типовой FPV-класс: уточнены размер винтов, плоская рама, стойки, крепления камеры, аккумулятор и проводка.' if m['kind']=='class' else 'Вымышленный аппарат проекта. Проработаны рама, крепления, грузовые узлы, посадочные опоры и соосные/отдельные винты; реального прототипа нет.')
 kind='Фото' if 'photograph' in r['evidence_kind'] else 'Иллюстрация' if 'illustration' in r['evidence_kind'] else 'Изображение модели' if m['kind']=='real' else 'FPV-класс' if m['kind']=='class' else 'Концепт'
 data=dict(id=m['id'],name=m['name'],category=m['kind'],type=p['type'],file=m['file'],preview=m['preview'],
  reference=r.get('local_reference'),source=r.get('source_page_url',r.get('catalogue_source_url')),kind=kind,note=note,
  transition=bool(m.get('transition')),rotors=len(m['rotors']),size=round(m['bytes']/1024),limited=m['id'] in ['iai-harpy-ng','northrop-aqm-35b'])
 if m['id'] in ['wildfire-ember-40','pyrolift-talon-60','colossus-ca12-atlas']:data['note']+=' Шесть лучей расставлены через 60° и симметрично относительно продольной оси корпуса.'
 cr=connections[m['id']]
 DATA.append(data);audit.append(dict(id=m['id'],assessment='visual_reconstruction_with_estimated_details',review=data['note'],views=['perspective','top','side','front','underside'],reference_kind=r['evidence_kind'],source=data['source'],geometry_sha256=m['geometry_sha256'],connected_components=cr['component_count'],unsupported_parts=len(cr['islands']),rotor_hubs_supported=all(b['stationary_contacts'] for b in cr['rotor_bearings'])))
(OUT/'geometry-audit.json').write_text(json.dumps(dict(date='2026-09-07',scope='All 55 catalogue entries; five native-render views, triangle contacts, mounting points and rotor bearings. Visual checks are not metrological certification.',models=audit),ensure_ascii=False,indent=2)+'\n')
page='''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>UAVsim · Модели аппаратов</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f1f3f4;color:#17212b;font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:inherit}header{padding:24px 4vw;background:#15252e;color:white;display:flex;justify-content:space-between;align-items:center}header b{letter-spacing:.1em}header a{text-decoration:none;padding:10px 16px;border:1px solid #6a818b;border-radius:10px}.wrap{max-width:1500px;margin:auto;padding:30px 4vw}h1{font-size:42px;letter-spacing:-.045em;margin:0 0 16px;line-height:1.05}h2{font-size:23px;letter-spacing:-.02em}p{line-height:1.6;color:#596670}.hero{display:grid;grid-template-columns:1.4fr 1fr;align-items:center;background:#e9eef0;border-radius:22px;overflow:hidden}.hero img{width:100%;display:block}.intro{padding:32px 36px 32px 0}.eyebrow{font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#497780}.primary{display:inline-block;background:#146470;color:white;border-radius:9px;padding:12px 18px;text-decoration:none}.stats{display:flex;gap:30px;margin:28px 0}.stats strong{font-size:25px;display:block}.stats span{font-size:12px;color:#5c6b72}.toolbar{position:sticky;top:0;z-index:3;background:#f1f3f4ee;backdrop-filter:blur(12px);padding:16px 0;display:flex;gap:10px;align-items:center;flex-wrap:wrap}input,select,button{font:inherit;border:1px solid #d2dadd;background:white;border-radius:8px;padding:10px 12px;color:#283b45}input{min-width:240px;flex:1}button{cursor:pointer}button.active{background:#163c46;color:white;border-color:#163c46}.count{font-size:12px;color:#67767e;width:100%;padding:3px 0}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px}.card{background:#fff;border:1px solid #e1e6e8;border-radius:16px;overflow:hidden}.visual{position:relative;height:230px;background:#edf1f3;display:flex;align-items:center;justify-content:center;overflow:hidden}.visual img{height:100%;width:100%;object-fit:contain}.visual .badge{position:absolute;left:14px;top:12px;font-size:10px;text-transform:uppercase;letter-spacing:.07em;background:#ffffffdd;padding:6px 8px;border-radius:20px}.body{padding:18px}.body h3{font-size:18px;margin:0 0 6px;min-height:22px}.meta{font-size:12px;color:#657681}.note{font-size:13px;line-height:1.5;margin:12px 0}.links{display:flex;gap:16px;align-items:center;margin-top:18px}.links a{text-decoration:none;font-size:13px}.links .open{background:#e8f2f3;color:#125c67;padding:9px 12px;border-radius:8px;font-weight:600}.limited{color:#96650c}.placeholder{padding:25px;text-align:center;color:#6e7f87}.about{margin:28px 0;padding:22px;background:#e7edef;border-radius:14px;font-size:13px;line-height:1.6}.empty{padding:50px;text-align:center;grid-column:1/-1;color:#6a7980}footer{color:#728087;font-size:12px;padding:25px 0}details summary{cursor:pointer;color:#53666e;font-size:12px}details p{font-size:12px}@media(min-width:1350px){.grid{grid-template-columns:repeat(4,minmax(0,1fr))}}@media(max-width:900px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.hero{grid-template-columns:1fr}.intro{padding:24px}h1{font-size:34px}}@media(max-width:550px){.grid{grid-template-columns:1fr}.wrap{padding:20px}header{padding:18px}.stats{gap:18px}.toolbar{position:static}.visual{height:260px}}
</style>
<header><b>UAVsim / AIRCRAFT</b><a href="UAVModels-55-animated-usdz.zip" download>Скачать все USDZ ↓</a></header><main class="wrap">
<section class="hero"><img src="previews/dji-neo-animated.gif" alt="Обновлённый DJI Neo с вращающимися винтами"><div class="intro"><div class="eyebrow">Обновлённая коллекция · 55 аппаратов</div><h1>Форма, детали<br>и движение.</h1><p>Модели по каталогу проекта и открытым референсам. Исправлены пропорции и компоновка; винты вращаются вокруг собственных осей.</p><a class="primary" href="models/dji-neo.usdz">Открыть DJI Neo ↗</a><p style="font-size:12px">Ниже можно сравнить ракурсы с изображениями прототипов.</p></div></section>
<div class="stats"><div><strong>55</strong><span>USDZ-файлов</span></div><div><strong>5</strong><span>ракурсов каждого</span></div><div><strong>3 VTOL</strong><span>анимации перехода</span></div></div>
<div class="toolbar"><input id="search" placeholder="Найти аппарат…" aria-label="Поиск аппарата"><select id="category" aria-label="Тип записи"><option value="all">Все аппараты</option><option value="real">Реальные прототипы</option><option value="class">FPV-классы</option><option value="concept">Концепты проекта</option></select><div id="views"></div><div class="count" id="count"></div></div>
<section class="grid" id="grid"></section><div class="about">Это визуальные реконструкции по изображениям. Кривизна поверхностей и мелкие размеры оценены; точность заводских CAD-моделей не заявляется. Для Harpy NG и AQM-35B точная модификация не подтверждена фотографиями. Семь записей — FPV-классы, пять — вымышленные аппараты проекта.<br>Скорость вращения специально замедлена для просмотра. У реактивных аппаратов без наружных винтов такой анимации нет.</div>
<footer>Референсы сохраняют права исходных авторов и не встроены в материалы моделей. <a href="README.md">Описание файлов и проверки</a> · <a href="reference-manifest.json">Источники</a> · <a href="validation-summary.json">Результаты проверки</a></footer></main>
<script>const data=__DATA__;let view='';const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));const views=[['','Ракурс'],['-top','Сверху'],['-side','Сбоку'],['-front','Спереди'],['-underside','Снизу'],['transition','Переход VTOL'],['reference','Референс']];function render(){document.getElementById('views').innerHTML=views.map(([v,t])=>`<button class="${v===view?'active':''}" data-view="${v}">${t}</button>`).join(' ');document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>{view=b.dataset.view;render()});let q=document.getElementById('search').value.toLowerCase(),cat=document.getElementById('category').value;let rows=data.filter(m=>(m.name+' '+m.id).toLowerCase().includes(q)&&(cat==='all'||m.category===cat));document.getElementById('count').textContent=`Показано ${rows.length} из 55`;document.getElementById('grid').innerHTML=rows.map(m=>{let image=view==='reference'?m.reference:view==='transition'?(m.transition?`previews/${m.id}-transition.gif`:m.preview):`previews/${m.id}${view}.png`;return `<article class="card"><div class="visual">${image?`<img loading="lazy" src="${escape(image)}" alt="${escape(m.name)}">`:`<div class="placeholder">${m.category==='concept'?'Вымышленный аппарат проекта':'Собирательный FPV-класс'}<br>Единственного реального прототипа нет</div>`}<span class="badge">${escape(m.kind)}</span></div><div class="body"><h3>${escape(m.name)}</h3><div class="meta">USDZ · ${m.size} КБ · ${m.rotors?`${m.rotors} вращающихся винтов`:'Без наружных винтов'}</div><p class="note ${m.limited?'limited':''}">${escape(m.note)}</p><div class="links"><a class="open" href="${escape(m.file)}">Открыть модель ↗</a>${m.source&&m.category==='real'?`<a href="${escape(m.source)}" target="_blank" rel="noopener">Источник ↗</a>`:''}</div></div></article>`}).join('')||'<p class="empty">Аппараты не найдены</p>';}document.getElementById('search').oninput=render;document.getElementById('category').onchange=render;render();</script></html>'''
(OUT/'catalog.html').write_text(page.replace('__DATA__',json.dumps(DATA,ensure_ascii=False).replace('</','<\\/')))
readme=f'''# Модели UAVsim

55 самостоятельных USDZ-файлов: 43 записи реальных аппаратов, 7 типовых FPV-классов и 5 вымышленных концептов проекта. Геометрия уточнена по изображениям, добавлены наружные детали и вращение винтов.

Откройте [визуальный каталог](catalog.html), [Neo](models/dji-neo.usdz) или [архив всех моделей](UAVModels-55-animated-usdz.zip). В Finder USDZ можно открыть пробелом. [Превью вращения Neo](previews/dji-neo-animated.gif).

## Что входит

- `models/` — готовые USDZ с материалами внутри каждого файла.
- `previews/` — пять ракурсов, включая вид снизу, контрольный кадр движения, GIF Neo и три GIF перехода VTOL; для VTOL также кадры hover / transition / cruise.
- `reference-photos/` — отобранные изображения и фотографии прототипов.
- `reference-manifest.json` — происхождение и тип каждого референса.
- `geometry-audit.json` — результаты визуальной сверки по каждому аппарату.
- `sources/` — редактируемые USDA и оригинальные текстуры.
- `manifest.json` — размеры, имена узлов, контрольные суммы и параметры анимации.
- `validation-summary.json` и `validation/` — проверки готовых файлов.
- `connection-audit.json` — контакты треугольников, соединения стоек и опор ступиц.

## Точность и конфигурации

Это авторские визуальные реконструкции, а не фотограмметрия или заводские CAD. Основные размеры и компоновка проверялись по доступным источникам; кривизна, мелкие детали и часть размеров остаются оценочными. Изображения производителя могут быть рендерами — они не выданы за фотографии.

Neo соответствует присланной фотографии без съёмных верхних решёток: ширина 157 мм, длина 130 мм, высота модели 48,5 мм. Порядок размеров исправлен по [спецификации DJI](https://www.dji.com/neo/specs). У Matrice 350 и 400 исправлены направления ширины/длины и нижнее расположение винтов; диаметр винтов FlyCart 30 уточнён по [DJI](https://www.dji.com/flycart-30/specs).

У Skydio X10 габарит 351×351×160 мм из проекта не соответствует раскрытому аппарату. Использован внешний облик и ориентир раскрытого размера из [данных Skydio](https://www.skydio.com/x10/technical-specs). Поза лопастей влияет на границы статического кадра.

Для Harpy NG найдено изображение в буклете производителя; точного фото этой ревизии не подтверждено. AQM-35B основан на фото семейства A/Q-4 и размерах B из проекта; мелкие различия ревизий не подтверждены. Everdrone First on Scene — имя сервиса; выбран E2. Модель «4TD + Dock 3» содержит летающий аппарат, без наземного дока. Для WingtraOne, Trinity Pro и Wingcopter 198 встроен цикл перехода между вертикальным и горизонтальным полётом. Концепты и FPV-классы не имеют единственного серийного прототипа.

EPFL уточнён по [статье авторов, рисунки 1 и 6](https://link.springer.com/article/10.1007/s13272-024-00727-9). BWB DELTA — по [отчёту NASA, Figure 6, печатная стр. 29](https://ntrs.nasa.gov/api/citations/20050169564/downloads/20050169564.pdf?attachment=true).

## Вращение и подключение

Винты имеют отдельные узлы `/Aircraft/Geometry/Rotor_*`, `Pusher*`, `Tractor*` или `Propeller_*`; точные пути перечислены в `manifest.json`. Центр каждого узла находится на оси мотора. Ось Y используется для горизонтальных винтов, Z — для продольных. Стойки и защитные кольца остаются неподвижными. У VTOL мотор и винт находятся внутри общего поворотного узла. В соосных парах винты вращаются навстречу друг другу.

Анимация встроена в USDZ: для обычных винтов цикл 2 секунды (121 ключ), для трёх переходных VTOL — 12 секунд (721 ключ). Частота 60 кадров/с, вращение до 120 об/мин для наглядного просмотра. Это демонстрационная скорость. Циклическое воспроизведение зависит от просмотрщика; в macOS SceneKit подтверждены движение, неподвижность центров и совпадение начала/конца цикла. Для управления скоростью в приложении следует отключить импортированную анимацию и вращать указанные узлы из симуляции.

Единицы — метры, вверх +Y, нос +Z. Обновлённые файлы и manifest синхронизированы с `DroneUAVDemo/Resources/Models/UAVModels/`. Загрузчик приложения отключает встроенный демонстрационный цикл и передаёт поворотные узлы существующему управлению VTOL; ориентацией Wingtra управляет физика всего аппарата. Подробности — [VTOL-transitions.md](VTOL-transitions.md).

## Соединения и расстановка

При повторной проверке устранены разрывы креплений у всех 55 моделей: подвес Phantom, шасси Everdrone и Wingcopter, нижние моторы соосных пар, колёсные стойки самолётов, площадки оборудования, оптика и крепёж. Маркировки уложены на поверхности корпусов. У Everdrone, Wildfire Ember, Pyrolift Talon и Colossus CA12 шесть лучей расположены симметрично с шагом 60°.

Wingcopter 198 перестроен по [изображению производителя](https://wingcopter.com/wingcopter-198): восемь разнесённых моторов вместо прежних четырёх соосных пар, четыре внутренних поворотных узла и четыре внешних подъёмных, цельные посадочные стойки.

## Проверки

У всех 55 моделей проверены контакты реальных треугольников и вложенных объёмов; отдельных геометрических островов не обнаружено. Допуск проверки — не более 0,2 мм (для маленьких аппаратов меньше). Отдельно проверяются корневые точки стоек и контакты вращающихся ступиц с неподвижными моторами. Пересечение одних лишь габаритных прямоугольников не считается соединением. Проверка не подтверждает заводскую точность размеров или механическую прочность.

Все USDZ проверяются системным валидатором ARKit, затем импортируются и рендерятся в SceneKit. Проверяются контрольные суммы именно отрендеренных файлов, выравнивание USDZ, наличие всех текстур, число мешей, оси и неподвижность центров вращения, замыкание цикла. Штатный валидатор macOS может дополнительно печатать диагностическое сообщение о повторной регистрации UsdShade; исходный вывод сохранён, итог валидатора — `Success`.

Фотографии служат исследовательскими референсами и не встроены в USDZ. Карбон, пятнистый материал и текстовые маркировки созданы отдельно. Права на исходные фотографии принадлежат их авторам.

Воспроизводимая сборка и проверка находятся в `Tools/UAVModelAssets/` в корне проекта.
'''
(OUT/'README.md').write_text(readme)
with zipfile.ZipFile(OUT/'UAVModels-55-animated-usdz.zip','w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
 for p in sorted((OUT/'models').glob('*.usdz')):z.write(p,'models/'+p.name)
 for folder in ['previews','reference-photos','sources','validation']:
  for p in sorted((OUT/folder).rglob('*')):
   if p.is_file():z.write(p,str(p.relative_to(OUT)))
 for name in ['catalog.html','manifest.json','reference-manifest.json','geometry-audit.json','connection-audit.json','README.md','VTOL-transitions.md','transition-validation.json','validation-summary.json']:
  if (OUT/name).exists():z.write(OUT/name,name)
print(f'Published {len(DATA)} catalogue cards and USDZ archive.')
