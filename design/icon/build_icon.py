"""Mask full-bleed Codex art into the macOS icon grid and render a size contact sheet.

usage: build_icon.py SRC MASTER_OUT SHEET_OUT [crop_frac]
crop_frac: fraction of the source to keep, centered (default 1.0).
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

src, master_out, sheet_out = sys.argv[1:4]
crop = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0

CANVAS, BODY, RADIUS = 1024, 824, 185
SS = 4  # supersampling for the mask edge

art = Image.open(src).convert("RGBA")
w, h = art.size
cw = int(w * crop)
left = (w - cw) // 2
art = art.crop((left, (h - cw) // 2, left + cw, (h - cw) // 2 + cw))
art = art.resize((BODY, BODY), Image.LANCZOS)

mask = Image.new("L", (BODY * SS, BODY * SS), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    (0, 0, BODY * SS - 1, BODY * SS - 1), radius=RADIUS * SS, fill=255
)
mask = mask.resize((BODY, BODY), Image.LANCZOS)
art.putalpha(mask)

off = (CANVAS - BODY) // 2
master = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
# soft drop shadow, as in Apple's template (shadow below the body)
shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
sh = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 90))
sh.putalpha(mask.point(lambda a: a * 90 // 255))
shadow.paste(sh, (off, off + 12), sh)
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
master = Image.alpha_composite(master, shadow)
layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
layer.paste(art, (off, off), art)
master = Image.alpha_composite(master, layer)
master.save(master_out)

sizes = [16, 32, 64, 128, 256]
pad = 24
width = sum(sizes) + pad * (len(sizes) + 1)
rowh = max(sizes) + pad * 2
sheet = Image.new("RGBA", (width, rowh * 2), (0, 0, 0, 255))
for row, bg in enumerate([(246, 246, 248, 255), (30, 30, 32, 255)]):
    sheet.paste(bg, (0, row * rowh, width, (row + 1) * rowh))
    x = pad
    for s in sizes:
        im = master.resize((s, s), Image.LANCZOS)
        y = row * rowh + (rowh - s) // 2
        sheet.alpha_composite(im, (x, y))
        x += s + pad
sheet.convert("RGB").save(sheet_out)
