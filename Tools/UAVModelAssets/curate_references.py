"""Publish only visually reviewed reference images and their provenance.

Keep unreviewed downloads out of the deliverable. Image searches are discovery
only; result captions are not treated as technical evidence.
"""
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'Assets/UAVModels'
CACHE=ROOT/'.build/UAVModelResearch'
RAW=CACHE if CACHE.exists() else OUT/'references'

# file stem, evidence kind, observation (from visual inspection, not search captions)
SELECTED={
 'dji-matrice-350-rtk':('candidate-1','official_product_image','X frame, landing skids, twin top antenna masts and suspended camera.'),
 'dji-flycart-30':('candidate-1','official_product_image','Four arms with eight coaxial propellers, cargo bay and landing skids.'),
 'dji-mavic-3t':('candidate-1','official_product_image','Gray folding quad with a rectangular multisensor gimbal.'),
 'dji-matrice-4t':('candidate-1','official_product_image','Light gray folding quad with a larger multisensor front module.'),
 'dji-matrice-30t':('candidate-1','official_product_image','Compact dark enterprise body and short landing feet; four rotors.'),
 'dji-matrice-400':('candidate-1','official_product_image','Gray central shell, long carbon arms and high landing gear.'),
 'fotokite-sigma':('search-2','product_photograph','Six rotors at four frame corners and the front/rear midpoints, square carbon perimeter.'),
 'everdrone-first-on-scene':('candidate-1','official_product_image','E2 selected as the representative First on Scene aircraft: white/red hexacopter and medical pod. The catalogue names a service, not an unambiguous airframe revision.'),
 'zipline-platform-1':('museum','museum_photograph','Museum P1 airframe, straight red wing, broad cargo nose and V-tail. Twin aft propeller installation is visually estimated; exact generation is not specified by the project.'),
 'wingcopter-198':('candidate-4','official_product_image','Eight separate motor stations: four inner tilting rotors on longitudinal booms and four outer lift rotors. White blended wing, V-tail and molded landing legs with skids.'),
 'matternet-m2':('search-2','photograph','White delivery quad with upswept arms and central underslung delivery pod.'),
 'skydio-x10':('full-airframe','official_product_image','Gray airframe, rectangular folding arms, three-blade propellers and large front sensor assembly. Official unfolded envelope is 790×650×145 mm; project 351×351×160 mm is not used as the flying envelope.'),
 'dji-matrice-4td-dock-3':('search-2','product_image','Matrice 4TD aircraft with rigid arms, top antenna and multi-camera gimbal. This USDZ contains the aircraft only; Dock 3 ground station is not part of the flying airframe.'),
 'brinc-lemur-2':('candidate-1','official_product_image','Dark indoor quad with guard cage and front sensor stack.'),
 'dji-mavic-4-pro':('candidate-1','official_product_image','Gray folding airframe and distinctive spherical camera pod.'),
 'dji-neo':('provided-top','user_provided_photograph','User-supplied top photograph: 157 mm wide, 130 mm long, permanent circular rims with removable upper guards absent, close rotor spacing, molded waist and recessed camera. Side details additionally referenced to DJI imagery. Author-estimated detail, not a measured scan.'),
 'dji-phantom-3-standard':('search-1','photograph','White molded arms, red arm bands, white propellers and skid landing gear.'),
 'freefly-alta-x':('search-2','photograph','Large open carbon quad, central battery stack and slim landing gear.'),
 'griff-30':('search-1','product_photograph','Long white central shell, four arms, copper motor details and removable landing legs.'),
 'griff-60':('primary-image-2','official_product_image','Long white shell and four arms with eight coaxial propellers. The shared site banner depicts Griff 30 and was rejected for the 60.'),
 'avidrone-490tl':('candidate-2','photograph','Tandem rotor pods connected by a narrow central structure; splayed landing struts.'),
 'wingtraone-gen-ii':('search-1','product_image','Orange broad tail-sitter wing, two forward propellers, white tail stand. Newer WingtraRAY imagery on the redirected manufacturer page was rejected.'),
 'quantum-systems-trinity-pro':('full-airframe','official_product_image','Gray foam airframe with yellow markings; conventional horizontal tail, tall single fin and motor on top of fin. All three propellers modeled in cruise orientation.'),
 'mq-9b-skyguardian':('search-1','photograph','Long narrow wing with tip winglets, up-canted V-tail and pusher propeller.'),
 'hermes-900':('search-2','photograph','Bulbous forward upper fuselage, long straight wings, V-tail and pusher.'),
 'ft5-los':('candidate-4','photograph','Twin-boom aircraft with paired engine nacelles and high rectangular wing.'),
 'sensefly-ebee-tac':('candidate-1','official_product_image','Dark flying-wing survey aircraft. Camouflage is represented by approximate original geometry patches.'),
 'rq-21-integrator':('search-2','photograph','Narrow high wing, wingtip fins, twin booms and inverted V-tail; nose sensor turret.'),
 'aerosonde-mk-4-7':('search-1','photograph','Fixed-wing Mk 4.7 with rear pusher and inverted V-tail. Mk 4.8 VTOL imagery was rejected.'),
 'rq-7b-shadow':('search-3','photograph','Twin boom aircraft with separate vertical tail surfaces and a connecting tailplane.'),
 'mq-9a-reaper':('candidate-1','official_product_image','Shorter wing than MQ-9B, no MQ-9B tip winglets, V-tail and ventral fin.'),
 'iai-harpy':('candidate-1','photograph','Original Harpy exhibition airframe: tailless delta with tip fins, rounded nose and rear propeller.'),
 'iai-harop':('search-1','photograph','Delta plus canards, wingtip fins and rounded optical nose module.'),
 'iai-harpy-ng':('extracted-0','manufacturer_illustration','Manufacturer brochure illustration, not a verified photograph. Harop-family exterior is used with a simplified non-optical nose; exact NG revision is uncertain.'),
 'epfl-delta-wing-uav':('figure-6','paper_photograph','Figure 6 shows the real laboratory airframe. Figure 1 additionally informs the red outer-wing configuration, central white body, two inboard vertical fins and front tractor propeller.'),
 'ncstate-bwb-delta':('reference-photo','paper_photograph','NC State BWB DELTA photograph in the NASA-hosted thesis/report; broad blended wing and central dorsal engine fairing.'),
 'hesa-karrar':('candidate-1','photograph','Exhibited green airframe with cylindrical body, dorsal engine intake and conventional aft surfaces.'),
 'ryan-bqm-34f-firebee-ii':('search-2','photograph','Orange museum Firebee II with long pointed nose and ventral nacelle; shorter subsonic Firebee photos were rejected.'),
 'northrop-aqm-35a':('candidate-1','archive_photograph','Archival Q-4/AQM-35A family exterior photograph, long slender body and small surfaces.'),
 'northrop-aqm-35b':('candidate-1','related_variant_photograph','Same Q-4/AQM-35A archive photo as the A model. A verified B-specific photograph was not located. Variant dimensions follow the project; visual details are tentative.'),
 'rockwell-himat':('search-3','archive_photograph','NASA HiMAT in flight, white/red body, canards and twin vertical fins. ER-2 image returned by search was rejected.'),
 'hermeus-quarterhorse-mk21':('search-3','photograph','Mk 2.1 photographed on a runway from above: swept wings, horizontal tail, single fin and chin intake.'),
 'north-american-x-10':('search-3','photograph','Museum X-10 with white/red livery, canards, paired aft engines and twin fins.'),
}

def make():
    candidates=json.loads((RAW/'candidates.json').read_text())
    supplements=json.loads((RAW/'supplements.json').read_text())
    searches=json.loads((RAW/'image_search_results.json').read_text())
    source_by_file={}
    for row in candidates:
        for im in row['images']:source_by_file[(row['id'],Path(im['file']).stem)]={'image_url':im['url'],'source_page_url':row['page']}
    for row in supplements:source_by_file[(row['id'],Path(row['file']).stem)]={'image_url':row['url']}
    for row in searches:
        for i,im in enumerate(row['images'],1):
            key=(row['id'],f'search-{i}')
            source_by_file.setdefault(key,{})
            if im.get('page'):source_by_file[key]['source_page_url']=im['page']
    explicit={
      ('dji-neo','provided-top'):{'source_page_url':'https://www.dji.com/neo/specs','image_provenance':'User attachment, top photograph; original pixels preserved.'},
      ('skydio-x10','full-airframe'):{'source_page_url':'https://www.skydio.com/x10','image_url':'https://cdn.sanity.io/images/mgxz50fq/production-v3-red/3de3cab301639f41b671fbee417b7ef92f75a24d-768x411.png'},
      ('quantum-systems-trinity-pro','full-airframe'):{'source_page_url':'https://lp.quantum-systems.com/thank-you-ungated-trinity-pro-brochure','image_url':'https://lp.quantum-systems.com/hs-fs/hubfs/Test.png?height=733&name=Test.png&width=1200'},
      ('zipline-platform-1','museum'):{'source_page_url':'https://www.flickr.com/photos/sdasmarchives/53896710902','image_url':'https://live.staticflickr.com/65535/53896710902_c254c75dfe_o.jpg','credit':'San Diego Air & Space Museum Archives'},
      ('epfl-delta-wing-uav','figure-6'):{'source_page_url':'https://link.springer.com/article/10.1007/s13272-024-00727-9','image_url':'https://media.springernature.com/full/springer-static/image/art%3A10.1007%2Fs13272-024-00727-9/MediaObjects/13272_2024_727_Fig6_HTML.png'},
      ('iai-harpy-ng','extracted-0'):{'source_page_url':'https://www.iai.co.il/wp-content/uploads/2025/10/MSL-HARPY-NG-Brochure.pdf','extraction':'Complete JPEG image stream extracted from the partially received PDF; original pixels preserved.'},
      ('ncstate-bwb-delta','reference-photo'):{'source_page_url':'https://ntrs.nasa.gov/api/citations/20050169564/downloads/20050169564.pdf?attachment=true','extraction':'Rendered reference photograph page from the complete NASA-hosted PDF.'},
    }
    source_by_file.update(explicit)
    profiles=json.loads((ROOT/'Tools/UAVModelAssets/catalog_snapshot.json').read_text());rows=[]
    destdir=OUT/'reference-photos';destdir.mkdir(exist_ok=True)
    for p in profiles:
        row=dict(id=p['id'],name=p['name'],catalogue_kind=p['kind'],catalogue_source_url=p['source'],reviewed_on='2026-09-07')
        if p['id'] in SELECTED:
            stem,kind,notes=SELECTED[p['id']];files=list((RAW/p['id']).glob(stem+'.*'))
            row.update(evidence_kind=kind,notes=notes,**source_by_file.get((p['id'],stem),{}))
            if files:
                src=files[0];dst=destdir/(p['id']+src.suffix);shutil.copy2(src,dst)
                row['local_reference']='reference-photos/'+dst.name
                row['visual_review']='completed'
            else:row['visual_review']='not_completed';row['notes']+=' Reference image file unavailable; rely on documented source with reduced confidence.'
        elif p['kind']=='class':
            row.update(evidence_kind='representative_class',notes='A class of custom builds, not a specific product. Geometry follows the catalogue dimensions and common FPV construction; no exact product photograph exists for this profile.')
        else:row.update(evidence_kind='fictional_concept',notes='Explicitly fictional in UAVReferenceCatalog.swift. No real product photograph is claimed.')
        rows.append(row)
    (OUT/'reference-manifest.json').write_text(json.dumps(dict(schema_version=1,rights='Reference images retain the rights of their original authors. Used only for visual research; no reference image is embedded in the USDZ models.',references=rows),ensure_ascii=False,indent=2)+'\n')
    return rows

if __name__=='__main__':make()
