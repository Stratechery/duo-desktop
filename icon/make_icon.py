#!/usr/bin/env python3
"""Duo Desktop app icon drafts from the owner's 2026-11-21 sketch. Writes SVGs; PNGs via ImageMagick."""
import os
OUT = os.path.dirname(os.path.abspath(__file__))
S, ORANGE, WHITE = 1024, "#FAA634", "#FFFFFF"
L, R = 164, 860            # content left/right (generous margin)
W = R - L                  # 696
G = 28                     # gap between the three bands / boxes

def rect(x, y, w, h, r):
    return f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{r:.1f}" ry="{r:.1f}" fill="{WHITE}"/>'

def icon(key_rows, bars=False, cols=7, m=1.0):
    # m widens every gap between white boxes (E1 = 1.5, E2 = 2); boxes shrink so the overall
    # size and outer margin stay as B's. m = 1 gives the original drawings unchanged.
    screen_h, mid_h = 252, 150
    kg = 16 if key_rows == 4 else 20
    kh = 48 if key_rows == 4 else 64
    if bars:
        kh, kg = 56, 36    # three keyboard bars: ~3.3 px thick, ~2.1 px apart at 60 px
    g, kg0, kh0 = G * m, kg, kh
    total = screen_h + 2 * G + mid_h + key_rows * kh + (key_rows - 1) * kg   # B's overall height
    kg = kg0 * m
    fh = (total - 2 * g - (key_rows - 1) * kg) / (total - 2 * G - (key_rows - 1) * kg0)  # box-height shrink
    screen_h, mid_h, kh = screen_h * fh, mid_h * fh, kh * fh
    fw = (W - 2 * g) / (W - 2 * G)                                          # box-row width shrink
    y = (S - total) / 2
    parts = [f'<rect x="0" y="0" width="{S}" height="{S}" fill="{ORANGE}"/>']
    parts.append(rect(L, y, W, screen_h, 40 * fh)); y += screen_h + g      # screen
    w1, w2 = 104 * fw, 220 * fw; w3 = W - w1 - w2 - 2 * g                   # click buttons, keys, trackpad
    mr = 26 * min(fh, fw)
    parts.append(rect(L, y, w1, mid_h, mr))
    parts.append(rect(L + w1 + g, y, w2, mid_h, mr))
    parts.append(rect(L + w1 + w2 + 2 * g, y, w3, mid_h, mr)); y += mid_h + g
    u = (W - (cols - 1) * kg) / cols                                        # one key width, cols per row
    ku = u / ((W - 6 * kg0) / 7)                                            # key width vs B's
    kr = (13 if key_rows == 4 else 16) * (ku if m == 1 else min(ku, fh))    # corner scaled with key size
    for row in range(key_rows):
        if bars:                                                            # keyboard as three lines
            parts.append(rect(L, y, W, kh, kh / 2)); y += kh + kg
            continue
        if row < key_rows - 1:
            widths = [1] * cols
        elif cols == 5:
            widths = [1, 3, 1]                                              # key, space bar (cols 2-4), key
        else:
            widths = [1, 1, 3, 1, 1]                                        # keyboard-like: space bar
        x = L
        for n in widths:
            w = n * u + (n - 1) * kg
            parts.append(rect(x, y, w, kh, kr))
            x += w + kg
        y += kh + kg
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">\n' + "\n".join(parts) + "\n</svg>\n"

for name, rows, bars, cols in (("A-keys-as-sketched", 4, False, 7), ("B-keys-3-rows", 3, False, 7),
                               ("C-keys-three-lines", 3, True, 7), ("D-five-across", 3, False, 5)):
    with open(os.path.join(OUT, f"duo-icon-{name}.svg"), "w") as f:
        f.write(icon(rows, bars, cols))
for name, m in (("E1-B-gaps-1.5x", 1.5), ("E2-B-gaps-2x", 2.0)):       # B with wider gaps
    with open(os.path.join(OUT, f"duo-icon-{name}.svg"), "w") as f:
        f.write(icon(3, False, 7, m))
