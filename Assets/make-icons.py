# 生成 Threadturn 图标：绿底白线「掉头线 + 点」，输出 icns 和菜单栏模板图
import subprocess
from AppKit import NSBezierPath, NSColor, NSBitmapImageRep, NSGraphicsContext, NSPNGFileType
from Foundation import NSMakeRect, NSMakePoint
GREEN=(0x2F/255,0x5E/255,0x43/255)
def glyph(S, stroke, color, dot_scale=1.15, inset=0.0):
    k=1-2*inset
    def P(x,y): return NSMakePoint((inset+x*k)*S, (1-(inset+y*k))*S)
    p=NSBezierPath.bezierPath(); p.setLineWidth_(stroke*S*k); p.setLineCapStyle_(1); p.setLineJoinStyle_(1)
    r=0.20
    p.moveToPoint_(P(0.28,0.30)); p.lineToPoint_(P(0.54,0.30))
    cx,cy=P(0.54,0.50)
    p.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise_((cx,cy),r*S*k,90,-90,True)
    p.lineToPoint_(P(0.46,0.70))
    color.setStroke(); p.stroke()
    dr=stroke*S*k*dot_scale/2; x,y=P(0.28,0.70)
    color.setFill(); NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(x-dr,y-dr,2*dr,2*dr)).fill()
def render(size, draw, out):
    rep=NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(None,size,size,8,4,True,False,"NSCalibratedRGBColorSpace",0,0)
    ctx=NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.setCurrentContext_(ctx); ctx.setShouldAntialias_(True)
    draw(size); NSGraphicsContext.restoreGraphicsState()
    open(out,'wb').write(bytes(rep.representationUsingType_properties_(NSPNGFileType,None)))
def app_icon(S):
    m=S*0.10; rr=NSMakeRect(m,m,S-2*m,S-2*m)
    NSColor.colorWithCalibratedRed_green_blue_alpha_(*GREEN,1).setFill()
    NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(rr,(S-2*m)*0.225,(S-2*m)*0.225).fill()
    glyph(S,0.10,NSColor.colorWithCalibratedRed_green_blue_alpha_(0.98,0.98,0.96,1),inset=0.10)
def menubar(S):
    glyph(S,0.13,NSColor.blackColor(),dot_scale=1.2,inset=0.06)
for s in (16,32,128,256,512):
    render(s,app_icon,f'Assets/Threadturn.iconset/icon_{s}x{s}.png'); render(s*2,app_icon,f'Assets/Threadturn.iconset/icon_{s}x{s}@2x.png')
subprocess.run(['iconutil','-c','icns','Assets/Threadturn.iconset','-o','Assets/Threadturn.icns'],check=True)
render(18,menubar,'Assets/MenuBarIcon.png'); render(36,menubar,'Assets/MenuBarIcon@2x.png')
render(512,app_icon,'Assets/preview-icon.png'); render(144,menubar,'Assets/preview-menubar.png')
print("icons ok")
