"""Adversarial fixtures for the geometric audit, independent of aircraft builders."""
from geometry import Model
from check_connections import Solid,contact,inside
import numpy as np
m=Model('fixture','Fixture')
m.box('A',(0,0,0),(2,2,2));m.box('B',(2,0,0),(2,2,2));m.box('Gap',(2.002,0,0),(2,2,2));m.box('Inside',(0,0,0),(.1,.1,.1))
a,b,gap,inner=[Solid(p) for p in m.parts]
assert contact(a,b,1e-6), 'Coplanar shared face must connect'
assert not contact(a,gap,1e-4), 'A two millimetre gap must fail'
assert contact(a,inner,1e-6), 'Entirely embedded component must connect'
assert inside(np.array([[0,0,0]]),a) and not inside(np.array([[3,0,0]]),a)
m=Model('fixture','Fixture');m.ring('Guard',(0,0,0),1,.1,.2);m.rod('Motor',(0,-.1,0),(0,.1,0),.1)
assert not contact(*[Solid(p) for p in m.parts],1e-5), 'Overlapping bounding boxes do not connect a motor across a ring hole'
m=Model('fixture','Fixture');m.rod('X',(-2,0,0),(2,0,0),.025);m.rod('Z',(0,0,-2),(0,0,2),.025)
assert contact(*[Solid(p) for p in m.parts],1e-6), 'Crossing thin rods must connect without contained end vertices'
print('PASS: solid containment, shared faces, real gaps, ring holes, crossing rods.')
