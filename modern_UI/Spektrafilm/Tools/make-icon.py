#!/usr/bin/env python3
# make-icon.py -- draws Spektraplus.icon/Assets/base-to-paper.png: the orange
# film base above, warm paper below, the change between them shaped like a
# film's characteristic curve, with fine light and dark grain where the tone
# changes. One baked layer, so the glass material only lights the icon's edge.
#   python3 Tools/make-icon.py Spektrafilm/Spektraplus.icon/Assets

import sys, zlib, struct, random, math
out = sys.argv[1]
BASE=(0xC8,0x74,0x3A); WARM=(0xF4,0xED,0xE0)
def curve(u):          # the film's characteristic curve, 0..1 -> 0..1
    lo=1/(1+math.exp(5)); hi=1/(1+math.exp(-5))
    return (1/(1+math.exp(-10*(u-0.5)))-lo)/(hi-lo)
a,b=0.5-0.275,0.5+0.275
N=1024; rnd=random.Random(11)
rows=[]
for y in range(N):
    v=y/(N-1)
    t=0 if v<a else 1 if v>b else curve((v-a)/(b-a))
    base=[BASE[i]+(WARM[i]-BASE[i])*t for i in range(3)]
    band=max(0.0,1-abs(v-0.5)/0.38)            # grain where the tone changes
    row=bytearray([0])
    for x in range(N):
        g=rnd.gauss(0,1)
        amt=0
        if abs(g)>0.9: amt=min(1,(abs(g)-0.9)*0.55)*band*0.55
        if g>0:  tgt=(0x3D,0x1C,0x0A)           # a dark grain
        else:    tgt=(0xFF,0xFB,0xF2)           # a light one
        row+=bytes(int(round(base[i]+(tgt[i]-base[i])*amt)) for i in range(3))
    rows.append(bytes(row))
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
open(f'{out}/base-to-paper.png','wb').write(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',N,N,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows),9))+chunk(b'IEND',b''))
