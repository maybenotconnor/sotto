#!/usr/bin/env python3
"""Convert the Sotto glyph's stroked centerlines to filled outline paths.

Icon Composer's Liquid Glass renderer mishandles stroked SVG paths (hollow
centers / breaks), so we emit filled outlines: each line becomes a closed
contour = top offset edge -> round end cap -> bottom offset edge -> round
start cap. Curves are densely flattened; offset is exact per-sample normal.
"""
import math

R = 25.6  # half of stroke width 51.2 (1024-unit canvas)

def cubic(p0, c1, c2, p1, n=96):
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = mt**3*p0[0] + 3*mt*mt*t*c1[0] + 3*mt*t*t*c2[0] + t**3*p1[0]
        y = mt**3*p0[1] + 3*mt*mt*t*c1[1] + 3*mt*t*t*c2[1] + t**3*p1[1]
        pts.append((x, y))
    return pts

def dedupe(pts, eps=1e-6):
    out = [pts[0]]
    for p in pts[1:]:
        if abs(p[0]-out[-1][0]) > eps or abs(p[1]-out[-1][1]) > eps:
            out.append(p)
    return out

def normals(pts):
    """Left normal per point (average of adjacent segment normals)."""
    segn = []
    for a, b in zip(pts, pts[1:]):
        dx, dy = b[0]-a[0], b[1]-a[1]
        L = math.hypot(dx, dy)
        segn.append((dy/L, -dx/L))  # left normal in y-down coords = 'top' side
    out = []
    for i in range(len(pts)):
        if i == 0:
            n = segn[0]
        elif i == len(pts)-1:
            n = segn[-1]
        else:
            nx = segn[i-1][0]+segn[i][0]
            ny = segn[i-1][1]+segn[i][1]
            L = math.hypot(nx, ny) or 1.0
            n = (nx/L, ny/L)
        out.append(n)
    return out

def outline(pts):
    pts = dedupe(pts)
    ns = normals(pts)
    top = [(p[0]+n[0]*R, p[1]+n[1]*R) for p, n in zip(pts, ns)]
    bot = [(p[0]-n[0]*R, p[1]-n[1]*R) for p, n in zip(pts, ns)]
    f = lambda v: f"{v:.2f}".rstrip('0').rstrip('.')
    d = [f"M{f(top[0][0])} {f(top[0][1])}"]
    d += [f"L{f(x)} {f(y)}" for x, y in top[1:]]
    d.append(f"A{R} {R} 0 0 1 {f(bot[-1][0])} {f(bot[-1][1])}")  # end cap
    d += [f"L{f(x)} {f(y)}" for x, y in reversed(bot[:-1])]
    d.append(f"A{R} {R} 0 0 1 {f(top[0][0])} {f(top[0][1])}")    # start cap
    d.append("Z")
    return ' '.join(d)

# Speech line: calm decaying wave settling into the rule (centerline)
wave = []
wave += cubic((166.4, 332.8), (182.4, 304.0), (204.8, 268.8), (230.4, 268.8))
wave += cubic((230.4, 268.8), (281.6, 268.8), (294.4, 384.0), (345.6, 384.0))[1:]
wave += cubic((345.6, 384.0), (390.4, 384.0), (390.4, 300.8), (435.2, 300.8))[1:]
wave += cubic((435.2, 300.8), (460.8, 300.8), (473.6, 332.8), (499.2, 332.8))[1:]
wave.append((857.6, 332.8))

transcript = [(166.4, 550.4), (857.6, 550.4)]
closing = [(166.4, 768.0), (627.2, 768.0)]

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <path fill="#000000" d="{outline(wave)}"/>
  <path fill="#000000" fill-opacity="0.8" d="{outline(transcript)}"/>
  <path fill="#000000" fill-opacity="0.8" d="{outline(closing)}"/>
</svg>
'''
import sys
open(sys.argv[1], 'w').write(svg)
print(f"wrote {sys.argv[1]}: wave outline pts={2*len(dedupe(wave))}")
