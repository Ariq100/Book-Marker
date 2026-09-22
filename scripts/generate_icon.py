# Generates the Book Marker app icon (1024x1024, no alpha — App Store requirement).
# Usage: python3 scripts/generate_icon.py "Book Marker/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
# Requires Pillow. The same PNG is copied to Logo.imageset for use inside the app.

from PIL import Image, ImageDraw, ImageFilter
import sys
N=4096; F=N/1024
def s(v): return int(v*F)
# Background: diagonal indigo -> violet gradient
top=(79,70,229); bot=(124,58,237)
bg=Image.new("RGB",(N,N))
M=int(N*1.5); px=Image.linear_gradient("L").resize((M,M)).rotate(-35, resample=Image.BICUBIC).crop(((M-N)//2,(M-N)//2,(M-N)//2+N,(M-N)//2+N))
bg=Image.composite(Image.new("RGB",(N,N),bot),Image.new("RGB",(N,N),top),px)
# subtle soft glow
glow=Image.new("L",(N,N),0); ImageDraw.Draw(glow).ellipse([s(150),s(80),s(870),s(700)],fill=70)
glow=glow.filter(ImageFilter.GaussianBlur(s(140)))
bg=Image.composite(Image.new("RGB",(N,N),(255,255,255)),bg,glow)

d=ImageDraw.Draw(bg,"RGBA")
cx=512
# shadow under book
sh=Image.new("L",(N,N),0); ImageDraw.Draw(sh).rounded_rectangle([s(190),s(330),s(834),s(790)],radius=s(40),fill=110)
sh=sh.filter(ImageFilter.GaussianBlur(s(28)))
bg=Image.composite(Image.new("RGB",(N,N),(40,20,110)),bg,sh.point(lambda v: v))
d=ImageDraw.Draw(bg,"RGBA")
# Open book: two pages as polygons with a curved top edge
def page(left):
    pts=[]
    import math
    if left:
        x0,x1=s(200),s(cx-8)
    else:
        x0,x1=s(cx+8),s(824)
    steps=60
    for i in range(steps+1):
        t=i/steps; x=x0+(x1-x0)*t
        # top edge dips toward spine
        u=(1-t) if not left else t
        y=s(300)+s(40)*(u**2)  # higher at outer edge
        y=s(340)-s(40)*((1-u)**1.6)
        pts.append((x,y))
    for i in range(steps,-1,-1):
        t=i/steps; x=x0+(x1-x0)*t
        u=(1-t) if not left else t
        y=s(780)-s(28)*((1-u)**1.6)
        pts.append((x,y))
    return pts
d.polygon(page(True),fill=(255,255,255))
d.polygon(page(False),fill=(246,244,255))
# spine line
d.line([(s(cx),s(345)),(s(cx),s(785))],fill=(200,195,235),width=s(6))
# text lines
def lines(x0,x1,left):
    ys=[410,465,520,575,630,685]
    for k,y in enumerate(ys):
        w=x1-x0 - (s(70) if k==len(ys)-1 else 0)
        if not left and k<2: w=x1-x0-s(95)
        d.rounded_rectangle([x0,s(y),x0+w,s(y)+s(16)],radius=s(8),fill=(190,186,225))
lines(s(250),s(cx-50),True)
lines(s(cx+50),s(774),False)
# yellow highlighter swipe over one line on the right page (multiply-like: draw translucent yellow)
hl=Image.new("RGBA",(N,N),(0,0,0,0)); hd=ImageDraw.Draw(hl)
hd.rounded_rectangle([s(cx+38),s(500),s(786),s(556)],radius=s(12),fill=(255,214,0,170))
bg=Image.alpha_composite(bg.convert("RGBA"),hl).convert("RGB")
d=ImageDraw.Draw(bg,"RGBA")
# bookmark ribbon hanging from top of right page
rx0,rx1=s(720),s(772)
d.polygon([(rx0,s(262)),(rx1,s(262)),(rx1,s(455)),((rx0+rx1)//2,s(422)),(rx0,s(455))],fill=(244,63,94))
d.polygon([(rx0,s(262)),(rx1,s(262)),(rx1,s(280)),(rx0,s(280))],fill=(225,29,72))
out=bg.resize((1024,1024),Image.LANCZOS)
out.save(sys.argv[1],"PNG")
