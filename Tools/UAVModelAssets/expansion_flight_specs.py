"""Simulation baselines for the exterior collection.

Identity/dimensions use the accompanying manufacturer references. These are
representative flight settings, not flight-test-certified performance tables.
Unpublished masses, battery budgets, fuel loads and engine ratings are estimates.
"""


def flight(manufacturer, country, mass, payload, minutes, cruise, maximum, minimum,
           energy, launch, *, battery=0, fuel=0, engine=None, power=None, thrust=None,
           engines=1, video='tacticalAdaptive', camera=None, wind=12):
    return dict(manufacturer=manufacturer,country=country,mass_kg=mass,payload_mass_kg=payload,
                battery_mass_kg=battery,flight_minutes=minutes,cruise_speed_mps=cruise,
                max_speed_mps=maximum,min_speed_mps=minimum,battery_energy_wh=energy,
                launch_mode=launch,wind_speed_mps=wind,fuel_mass_kg=fuel,engine_type=engine,
                rated_power_kw=power,rated_thrust_n=thrust,engine_count=engines,
                video_preset=video,camera_module_id=camera)


SPECS = {
 'wingtra-ray': flight('Wingtra','Switzerland',6,1,59,19,22,12,350,'vtol',battery=1.6,video='bvlosAdaptive'),
 'ageagle-ebee-x': flight('AgEagle / senseFly','Switzerland',1.6,.25,90,16,30,11,74.5,'handLaunch',battery=.42,video='bvlosAdaptive'),
 'delair-dt26-open-payload': flight('Delair','France',18.5,3,170,16.7,28,14,1400,'catapult',battery=6,video='bvlosAdaptive'),
 'jouav-cw-20e': flight('JOUAV','China',24.9,5,150,20,32,15,2200,'vtol',battery=8,video='bvlosAdaptive'),
 'delair-ux11': flight('Delair','France',1.4,.20,59,15,23,10,70,'handLaunch',battery=.32,video='bvlosAdaptive'),
 'c-astral-bramor-c4eye': flight('C-Astral','Slovenia',4.5,.8,180,16,22,12,320,'catapult',battery=1.5),
 'aerovironment-puma-le': flight('AeroVironment','United States',12.4,2.5,390,17,23,13,1200,'handLaunch',battery=4),
 'tekever-ar3': flight('TEKEVER','Portugal',25,4,960,23.6,36,17,60,'catapult',battery=.3,fuel=5,engine='pistonTwoStroke',power=4),
 'deltaquad-evo': flight('DeltaQuad','Netherlands',10,1,272,16.54,28,12,976.8,'vtol',battery=4,video='bvlosAdaptive'),
 'tekever-ar5': flight('TEKEVER','Portugal',180,50,1200,27.8,50,22,150,'runway',battery=1,fuel=35,engine='pistonTwoStroke',power=16,engines=2),
 'aerovironment-raven-b': flight('AeroVironment','United States',1.9,.25,90,15,25,10,90,'handLaunch',battery=.5),
 'aerovironment-puma-3-ae': flight('AeroVironment','United States',7,1.8,180,17,23,12,600,'handLaunch',battery=2),
 'aerovironment-jump-20': flight('AeroVironment','United States',97.5,13.6,840,28,40,22,1000,'vtol',battery=5,fuel=20,engine='pistonFourStroke',power=12),
 'insitu-scaneagle': flight('Insitu','United States',28,8,1080,27,41.2,18,60,'catapult',battery=.3,fuel=5,engine='pistonTwoStroke',power=1.5),
 'aeronautics-orbiter-3': flight('Aeronautics','Israel',32,5,600,25,36,16,1600,'catapult',battery=7),
 'aeronautics-orbiter-4': flight('Aeronautics','Israel',50,12,1440,27,40,18,80,'catapult',battery=.4,fuel=10,engine='pistonFourStroke',power=4),
 'aeronautics-aerostar': flight('Aeronautics','Israel',230,50,720,34,55,22,200,'runway',battery=2,fuel=40,engine='pistonFourStroke',power=38),
 'elbit-hermes-450': flight('Elbit Systems','Israel',550,180,1020,36,49,24,300,'runway',battery=3,fuel=100,engine='wankelRotary',power=39),
 'iai-heron-mk-ii': flight('IAI','Israel',1430,470,2700,40,60,27,600,'runway',battery=5,fuel=250,engine='pistonFourStroke',power=119),
 'iai-heron-tp': flight('IAI','Israel',5400,1000,1800,90,113,45,1000,'runway',battery=12,fuel=1800,engine='turboprop',power=895),
 'leonardo-falco-evo': flight('Leonardo','Italy',650,100,1080,38,65,25,300,'runway',battery=3,fuel=120,engine='pistonFourStroke',power=58),
 'leonardo-falco-xplorer': flight('Leonardo','Italy',1300,350,1440,50,72,30,500,'runway',battery=5,fuel=260,engine='pistonFourStroke',power=125),
 'piaggio-p1hh-hammerhead': flight('Piaggio Aerospace','Italy',6146,500,960,110,204,62,1400,'runway',battery=15,fuel=1700,engine='turboprop',power=638,engines=2),
 'dji-mini-5-pro': flight('DJI','China',.2499,0,36,10,18,0,19.52,'vertical',battery=.0712,video='djiO4Consumer',camera='dji-mini-5-pro-camera'),
 'dji-avata-2': flight('DJI','China',.377,0,23,16,27,0,31.7,'vertical',battery=.064,video='djiO4Consumer',camera='dji-avata-2-camera',wind=10.7),
 'autel-evo-max-4t-v2': flight('Autel Robotics','China',1.999,.28,42,14,23,0,120,'vertical',battery=.52,video='industrialAdaptive',camera='autel-fusion-4t-v2'),
}
