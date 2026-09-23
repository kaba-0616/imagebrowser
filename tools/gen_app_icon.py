"""確定した案4(虫眼鏡+写真スタック)から、本番用のAppIcon.appiconsetを
全スロット書き出す。

プレビュー生成(gen_app_icon_previews.py)は比較用に角丸マスク+透過背景
だったが、App Store提出用アイコンは不透明・正方形(角丸はOS側が適用する)
でなければならないため、ここでは別途1024pxの不透明マスターを描いてから
各サイズへダウンサンプルする。

    python tools/gen_app_icon.py
"""
import os

from PIL import Image, ImageDraw

MASTER = 1024
BG_TOP = (0x0E, 0xA5, 0x8C)
BG_BOTTOM = (0x06, 0x5C, 0x4E)

# iPhone/iPadアプリ本体の全スロット。拡張機能を持たないので
# ImageSaverのACTION用スロットは不要。
APPICON_SLOTS = [
    ("iphone", "20x20", "2x", 40), ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58), ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80), ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120), ("iphone", "60x60", "3x", 180),
    ("ipad", "20x20", "1x", 20), ("ipad", "20x20", "2x", 40),
    ("ipad", "29x29", "1x", 29), ("ipad", "29x29", "2x", 58),
    ("ipad", "40x40", "1x", 40), ("ipad", "40x40", "2x", 80),
    ("ipad", "76x76", "1x", 76), ("ipad", "76x76", "2x", 152),
    ("ipad", "83.5x83.5", "2x", 167),
    ("ios-marketing", "1024x1024", "1x", 1024),
]


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        grad.putpixel((0, y), c)
    return grad.resize((size, size))


def render_master():
    size = MASTER
    img = vertical_gradient(size, BG_TOP, BG_BOTTOM)
    d = ImageDraw.Draw(img)
    c = size / 2

    stack_w, stack_h = size * 0.38, size * 0.30
    offsets = [(-size * 0.05, -size * 0.05), (-size * 0.025, -size * 0.025), (0, 0)]
    colors = [(0x9F, 0xE7, 0xDA), (0xC9, 0xF3, 0xEB), (255, 255, 255)]
    base_x, base_y = c - stack_w / 2 - size * 0.03, c - stack_h / 2 - size * 0.02
    for (ox, oy), col in zip(offsets, colors):
        rect = [base_x + ox, base_y + oy, base_x + ox + stack_w, base_y + oy + stack_h]
        d.rounded_rectangle(rect, radius=int(size * 0.02), fill=col)

    mg_cx, mg_cy = c + size * 0.11, c + size * 0.08
    mg_r = size * 0.135
    ring_width = size * 0.032
    lens_fill_r = mg_r + ring_width / 2
    bg_layer = vertical_gradient(size, BG_TOP, BG_BOTTOM)
    lens_mask = Image.new("L", (size, size), 0)
    ld = ImageDraw.Draw(lens_mask)
    ld.ellipse([mg_cx - lens_fill_r, mg_cy - lens_fill_r, mg_cx + lens_fill_r, mg_cy + lens_fill_r], fill=255)
    img.paste(bg_layer, (0, 0), lens_mask)

    d.ellipse([mg_cx - mg_r, mg_cy - mg_r, mg_cx + mg_r, mg_cy + mg_r],
              outline=(255, 255, 255), width=int(ring_width))
    handle_start = (mg_cx + mg_r * 0.72, mg_cy + mg_r * 0.72)
    handle_end = (mg_cx + mg_r * 1.55, mg_cy + mg_r * 1.55)
    d.line([handle_start, handle_end], fill=(255, 255, 255), width=int(size * 0.038))
    return img


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                         "ImageBrowserApp", "Assets.xcassets")
    appicon = os.path.join(root, "AppIcon.appiconset")
    os.makedirs(appicon, exist_ok=True)

    master = render_master().convert("RGB")
    print("rendered %dx%d master" % master.size)

    cache = {MASTER: master}

    def at(size):
        if size not in cache:
            cache[size] = master.resize((size, size), Image.LANCZOS)
        return cache[size]

    entries = []
    for idiom, sizes, scale, px in APPICON_SLOTS:
        name = "icon-%d.png" % px
        at(px).save(os.path.join(appicon, name))
        entries.append('    {\n      "filename" : "%s",\n      "idiom" : "%s",\n'
                        '      "scale" : "%s",\n      "size" : "%s"\n    }'
                        % (name, idiom, scale, sizes))
    with open(os.path.join(appicon, "Contents.json"), "w") as f:
        f.write('{\n  "images" : [\n' + ",\n".join(entries)
                + '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    print("wrote AppIcon.appiconset (%d slots)" % len(APPICON_SLOTS))


if __name__ == "__main__":
    main()
