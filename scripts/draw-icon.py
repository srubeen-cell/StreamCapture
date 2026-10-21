# Draws the StreamCapture app icon (1024px). Usage: python3 scripts/draw-icon.py Resources/AppIcon.png
# Then rebuild AppIcon.icns from it with sips + iconutil (see README).
# StreamCapture icon: indigo-violet tile, white viewfinder corners, red record dot.
import sys, math
from PIL import Image, ImageDraw, ImageFilter
S = 4096
def sc(v): return int(round(v * S / 1024))
out = sys.argv[1]

# Diagonal gradient #5B5FEF (top-left) -> #8B5CF6 (bottom-right), slightly lifted at the top.
a, b = (79, 70, 229), (139, 92, 246)
grad = Image.new("RGB", (256, 256))
px = grad.load()
for y in range(256):
    for x in range(256):
        t = (x + y) / 510
        lift = max(0, 1 - y / 140) * 0.10
        px[x, y] = tuple(min(255, int(a[i] + (b[i] - a[i]) * t + 255 * lift)) for i in range(3))
grad = grad.resize((S, S), Image.BICUBIC).convert("RGBA")

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([sc(100), sc(116), sc(924), sc(940)], radius=sc(186), fill=(30, 20, 80, 110))
img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(sc(16))))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([sc(100), sc(100), sc(924), sc(924)], radius=sc(186), fill=255)
img.paste(grad, (0, 0), mask)

d = ImageDraw.Draw(img)
white = (255, 255, 255, 255)

# Viewfinder corners: a rounded frame outline, keeping only the four corners.
L, T, R, B = 250, 250, 774, 774
w, r, arm = 46, 96, 170
frame = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(frame).rounded_rectangle([sc(L), sc(T), sc(R), sc(B)], radius=sc(r), outline=white, width=sc(w))
keep = Image.new("L", (S, S), 0)
kd = ImageDraw.Draw(keep)
for x0, y0 in [(L - w, T - w), (R - arm, T - w), (L - w, B - arm), (R - arm, B - arm)]:
    kd.rectangle([sc(x0), sc(y0), sc(x0 + arm + w), sc(y0 + arm + w)], fill=255)
corners = Image.new("RGBA", (S, S), (0, 0, 0, 0))
corners.paste(frame, (0, 0), keep)
img = Image.alpha_composite(img, corners)
d = ImageDraw.Draw(img)
# Round caps on the arm ends.
half = w / 2
for cx_, cy_ in [(L + arm - half * 0, T + half), (L + half, T + arm), (R - arm, T + half), (R - half, T + arm),
                 (L + arm, B - half), (L + half, B - arm), (R - arm, B - half), (R - half, B - arm)]:
    d.ellipse([sc(cx_ - half), sc(cy_ - half), sc(cx_ + half), sc(cy_ + half)], fill=white)

# Record dot: white ring + red core with a faint glow.
cx = cy = 512
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([sc(cx - 150), sc(cy - 150), sc(cx + 150), sc(cy + 150)], fill=(255, 80, 90, 90))
img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(sc(28))))
d = ImageDraw.Draw(img)
d.ellipse([sc(cx - 132), sc(cy - 132), sc(cx + 132), sc(cy + 132)], fill=white)
d.ellipse([sc(cx - 104), sc(cy - 104), sc(cx + 104), sc(cy + 104)], fill=(239, 68, 68, 255))

img.resize((1024, 1024), Image.LANCZOS).save(out)
