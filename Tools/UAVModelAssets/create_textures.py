"""Create original cosmetic materials. No source photograph is used as a texture."""
from pathlib import Path
import random
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parents[2]/'Assets/UAVModels/sources/textures'
ROOT.mkdir(parents=True,exist_ok=True)
rng=random.Random(4128)
n=512
im=Image.new('RGB',(n,n));px=im.load()
for y in range(n):
 for x in range(n):
  a=(x+y)//12%4;b=(x-y)//12%4
  warp=(a<2) if b<2 else (a>=2)
  value=31+int(9*((x if warp else y)%12)/12)+rng.randrange(-2,3)
  px[x,y]=(value,value+3,value+5)
im.save(ROOT/'carbon.png')
im=Image.new('RGB',(1024,1024),'#c3c4bc');d=ImageDraw.Draw(im)
for _ in range(65000):
 x=rng.randrange(1024);y=rng.randrange(1024);r=rng.choice([1,1,2,3,4])
 d.rectangle((x,y,x+r,y+r),fill=rng.choice(['#262a2b','#5f6665','#a0a59f','#d6d6cc']))
im.save(ROOT/'ebee-speckle.png')
fontfile='/System/Library/Fonts/Helvetica.ttc'
labels={'neo-brand':'DJI','mavic-brand':'DJI','skydio-brand':'SKYDIO','phantom-brand':'PHANTOM',
 'wingtra-brand':'Wingtra','trinity-brand':'TRINITY PRO','zipline-brand':'Zipline',
 'griff-brand':'GRIFF','freefly-brand':'FREEFLY','avidrone-brand':'AVIDRONE',
 'brinc-brand':'BRINC','himat-brand':'NASA','quarterhorse-brand':'HERMEUS',
 'mq9-brand':'MQ-9','hermes-brand':'HERMES 900','fotokite-brand':'FOTOKITE',
 'matternet-brand':'MATTERNET','wingcopter-brand':'WINGCOPTER'}
for name,label in labels.items():
 im=Image.new('RGBA',(1024,256),(0,0,0,0));d=ImageDraw.Draw(im);f=ImageFont.truetype(fontfile,170)
 b=d.textbbox((0,0),label,font=f)
 while b[2]-b[0]>980:
  f=ImageFont.truetype(fontfile,f.size-5);b=d.textbbox((0,0),label,font=f)
 color='#eeeeea' if name in ['neo-brand','skydio-brand','freefly-brand','avidrone-brand','brinc-brand','fotokite-brand'] else '#30363a'
 if name=='himat-brand':color='#cc3333'
 d.text(((1024-b[2]+b[0])/2,(256-b[3]+b[1])/2-b[1]),label,font=f,fill=color)
 im.save(ROOT/(name+'.png'))
print('Created original weave, surface pattern and identification decals.')
