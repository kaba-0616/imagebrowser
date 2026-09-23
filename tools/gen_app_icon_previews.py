"""imagebrowser のApp Icon案を5パターン、プレビュー用に1024x1024で生成する。

本番のAppIcon.appiconset全サイズ書き出しは、方向性が決まってから
gen_action_icon.py と同様のスロット書き出しを別途行う。ここではまず
5案を並べて選んでもらうためのプレビューPNGだけを作る。

    python tools/gen_app_icon_previews.py
"""
import math
import os

from PIL import Image, ImageDraw

SIZE = 1024
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon_previews")


def rounded_square(size, radius_ratio=0.225):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * radius_ratio)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return img, mask


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        grad.putpixel((0, y), c)
    return grad.resize((size, size))


def apply_background(gradient_top, gradient_bottom):
    img, mask = rounded_square(SIZE)
    bg = vertical_gradient(SIZE, gradient_top, gradient_bottom).convert("RGBA")
    img.paste(bg, (0, 0), mask)
    return img, mask


def finish(img, mask, name):
    # マスクの外側は透明のまま(App Store提出時は不透明が必須だが、
    # プレビュー確認用途なのでここでは角丸のプレビューを優先する)。
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name + ".png")
    img.save(path)
    print("wrote", path)


def stroke_path(draw, points, width, fill, closed=False):
    pts = points + ([points[0]] if closed else [])
    draw.line(pts, fill=fill, width=width, joint="curve")
    r = width / 2
    for (x, y) in points:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


# --- 案1: コンパス風の円 + ダウンロード矢印(ブラウザ感 + 保存) --------------
def icon_compass_download():
    img, mask = apply_background((0x21, 0x63, 0xE8), (0x0B, 0x2F, 0x8F))
    d = ImageDraw.Draw(img)
    c = SIZE / 2
    r = SIZE * 0.30
    d.ellipse([c - r, c - r, c + r, c + r], outline=(255, 255, 255, 255), width=int(SIZE * 0.028))
    # ダウンロード矢印
    stroke_path(d, [(c, c - r * 0.55), (c, c + r * 0.35)], int(SIZE * 0.05), (255, 255, 255, 255))
    stroke_path(d, [(c - r * 0.42, c + r * 0.02), (c, c + r * 0.45), (c + r * 0.42, c + r * 0.02)],
                int(SIZE * 0.05), (255, 255, 255, 255))
    finish(img, mask, "1_compass_download")


# --- 案2: ブラウザウィンドウ + 中に写真、右下に保存バッジ -------------------
def icon_window_photo_badge():
    img, mask = apply_background((0x17, 0x8C, 0xE0), (0x0A, 0x4B, 0x8C))
    d = ImageDraw.Draw(img)
    m = SIZE * 0.16
    top_bar_h = SIZE * 0.12
    win = [m, m, SIZE - m, SIZE - m]
    d.rounded_rectangle(win, radius=int(SIZE * 0.05), fill=(255, 255, 255, 255))
    d.rectangle([m, m, SIZE - m, m + top_bar_h], fill=(0xD8, 0xE8, 0xFA, 255))
    for i, cx in enumerate([m + SIZE * 0.06, m + SIZE * 0.115, m + SIZE * 0.17]):
        d.ellipse([cx - SIZE * 0.014, m + top_bar_h / 2 - SIZE * 0.014,
                   cx + SIZE * 0.014, m + top_bar_h / 2 + SIZE * 0.014],
                  fill=(0x5B, 0x7C, 0xB0, 255))
    # 写真(山と太陽のシンプルなモチーフ)
    photo = [m + SIZE * 0.06, m + top_bar_h + SIZE * 0.05, SIZE - m - SIZE * 0.06, SIZE - m - SIZE * 0.06]
    d.rounded_rectangle(photo, radius=int(SIZE * 0.02), fill=(0xE9, 0xF1, 0xFC, 255))
    sun_r = SIZE * 0.045
    d.ellipse([photo[0] + SIZE * 0.06, photo[1] + SIZE * 0.05,
               photo[0] + SIZE * 0.06 + sun_r * 2, photo[1] + SIZE * 0.05 + sun_r * 2],
              fill=(0xFF, 0xC1, 0x3D, 255))
    mountain_base = photo[3] - SIZE * 0.02
    d.polygon([(photo[0] + SIZE * 0.02, mountain_base),
               (photo[0] + SIZE * 0.18, photo[1] + SIZE * 0.09),
               (photo[0] + SIZE * 0.30, mountain_base)], fill=(0x5B, 0x9B, 0xD8, 255))
    d.polygon([(photo[0] + SIZE * 0.20, mountain_base),
               (photo[0] + SIZE * 0.34, photo[1] + SIZE * 0.04),
               (photo[2] - SIZE * 0.02, mountain_base)], fill=(0x3E, 0x7B, 0xB8, 255))
    # 右下の保存バッジ
    badge_r = SIZE * 0.135
    bx, by = SIZE - m - badge_r * 0.4, SIZE - m - badge_r * 0.4
    d.ellipse([bx - badge_r, by - badge_r, bx + badge_r, by + badge_r], fill=(0x1E, 0xB9, 0x6B, 255))
    stroke_path(d, [(bx, by - badge_r * 0.45), (bx, by + badge_r * 0.25)],
                int(SIZE * 0.032), (255, 255, 255, 255))
    stroke_path(d, [(bx - badge_r * 0.35, by - badge_r * 0.05), (bx, by + badge_r * 0.3),
                     (bx + badge_r * 0.35, by - badge_r * 0.05)],
                int(SIZE * 0.032), (255, 255, 255, 255))
    finish(img, mask, "2_window_photo_badge")


# --- 案3: 開いた鍵 + 写真(ブロック回避のメタファー) -------------------------
def icon_unlocked_photo():
    img, mask = apply_background((0x6A, 0x3D, 0xE8), (0x35, 0x17, 0x8F))
    d = ImageDraw.Draw(img)
    c = SIZE / 2
    photo_r = SIZE * 0.26
    photo = [c - photo_r, c - photo_r * 0.85, c + photo_r, c + photo_r * 1.15]
    d.rounded_rectangle(photo, radius=int(SIZE * 0.03), fill=(255, 255, 255, 255))
    tri = SIZE * 0.09
    d.polygon([(photo[0] + SIZE * 0.03, photo[3] - SIZE * 0.03),
               (photo[0] + SIZE * 0.03 + tri, photo[3] - SIZE * 0.03 - tri * 1.3),
               (photo[0] + SIZE * 0.03 + tri * 2, photo[3] - SIZE * 0.03)],
              fill=(0xB8, 0x9C, 0xF2, 255))
    d.ellipse([photo[2] - SIZE * 0.09, photo[1] + SIZE * 0.02, photo[2] - SIZE * 0.035, photo[1] + SIZE * 0.075],
              fill=(0xFF, 0xC1, 0x3D, 255))
    # 開いた南京錠(写真の上、少し傾けたシャックル)
    lock_cx, lock_cy = c, photo[1] - SIZE * 0.08
    body = [lock_cx - SIZE * 0.10, lock_cy, lock_cx + SIZE * 0.10, lock_cy + SIZE * 0.14]
    shackle_r = SIZE * 0.075
    d.arc([lock_cx - shackle_r * 1.5, lock_cy - shackle_r * 2.1,
           lock_cx + shackle_r * 0.5, lock_cy - shackle_r * 0.1],
          start=140, end=360, fill=(255, 255, 255, 255), width=int(SIZE * 0.028))
    d.rounded_rectangle(body, radius=int(SIZE * 0.015), fill=(255, 255, 255, 255))
    finish(img, mask, "3_unlocked_photo")


# --- 案4: 虫眼鏡 + 写真スタック(一括抽出のメタファー) -----------------------
# 虫眼鏡のレンズが写真スタックと重なる部分は、スタックを覆い隠さず
# 背景のグラデーションを透かして見せる(ガラス越しに背景が見える表現)。
def icon_magnifier_stack():
    bg_top, bg_bottom = (0x0E, 0xA5, 0x8C), (0x06, 0x5C, 0x4E)
    img, mask = apply_background(bg_top, bg_bottom)
    bg_layer = vertical_gradient(SIZE, bg_top, bg_bottom).convert("RGBA")
    d = ImageDraw.Draw(img)
    c = SIZE / 2
    stack_w, stack_h = SIZE * 0.38, SIZE * 0.30
    offsets = [(-SIZE * 0.05, -SIZE * 0.05), (-SIZE * 0.025, -SIZE * 0.025), (0, 0)]
    colors = [(0x9F, 0xE7, 0xDA, 255), (0xC9, 0xF3, 0xEB, 255), (255, 255, 255, 255)]
    base_x, base_y = c - stack_w / 2 - SIZE * 0.03, c - stack_h / 2 - SIZE * 0.02
    for (ox, oy), col in zip(offsets, colors):
        rect = [base_x + ox, base_y + oy, base_x + ox + stack_w, base_y + oy + stack_h]
        d.rounded_rectangle(rect, radius=int(SIZE * 0.02), fill=col)

    # 虫眼鏡のレンズ部分を背景色でくり抜く。縁の白いリング自体も写真
    # スタックの白いカードと重なると「白の上に白」で輪郭が消えるため、
    # リングの内側だけでなく縁の太さぶん外側まで含めてくり抜いておき、
    # リングが必ず背景色の上に描かれるようにする。
    mg_cx, mg_cy = c + SIZE * 0.11, c + SIZE * 0.08
    mg_r = SIZE * 0.135
    ring_width = SIZE * 0.032
    lens_fill_r = mg_r + ring_width / 2  # リング外周まで含めてくり抜く
    lens_mask = Image.new("L", (SIZE, SIZE), 0)
    ld = ImageDraw.Draw(lens_mask)
    ld.ellipse([mg_cx - lens_fill_r, mg_cy - lens_fill_r, mg_cx + lens_fill_r, mg_cy + lens_fill_r], fill=255)
    img.paste(bg_layer, (0, 0), lens_mask)

    # レンズの縁(白いリング)と持ち手
    d.ellipse([mg_cx - mg_r, mg_cy - mg_r, mg_cx + mg_r, mg_cy + mg_r],
              outline=(255, 255, 255, 255), width=int(ring_width))
    handle_start = (mg_cx + mg_r * 0.72, mg_cy + mg_r * 0.72)
    handle_end = (mg_cx + mg_r * 1.55, mg_cy + mg_r * 1.55)
    d.line([handle_start, handle_end], fill=(255, 255, 255, 255), width=int(SIZE * 0.038))
    finish(img, mask, "4_magnifier_stack")


# --- 案5: ブラウザタブ2枚 + 保存矢印(シンプル・フラット) --------------------
def icon_tabs_flat():
    img, mask = apply_background((0xF2, 0x5C, 0x54), (0xC2, 0x2A, 0x3A))
    d = ImageDraw.Draw(img)
    tab_w, tab_h = SIZE * 0.42, SIZE * 0.30
    back = [SIZE * 0.30, SIZE * 0.20, SIZE * 0.30 + tab_w, SIZE * 0.20 + tab_h]
    front = [SIZE * 0.18, SIZE * 0.34, SIZE * 0.18 + tab_w, SIZE * 0.34 + tab_h]
    d.rounded_rectangle(back, radius=int(SIZE * 0.035), fill=(255, 255, 255, 140))
    d.rounded_rectangle(front, radius=int(SIZE * 0.035), fill=(255, 255, 255, 255))
    # front タブの中に簡易画像アイコン
    inset = SIZE * 0.045
    photo = [front[0] + inset, front[1] + inset, front[2] - inset, front[3] - inset]
    d.rounded_rectangle(photo, radius=int(SIZE * 0.015), fill=(0xFB, 0xD9, 0xD6, 255))
    d.ellipse([photo[0] + SIZE * 0.02, photo[1] + SIZE * 0.02, photo[0] + SIZE * 0.055, photo[1] + SIZE * 0.055],
              fill=(0xF2, 0x5C, 0x54, 255))
    # 下部に保存矢印を大きく
    ax = SIZE / 2
    ay0, ay1 = SIZE * 0.68, SIZE * 0.85
    stroke_path(d, [(ax, ay0), (ax, ay1)], int(SIZE * 0.045), (255, 255, 255, 255))
    stroke_path(d, [(ax - SIZE * 0.07, ay1 - SIZE * 0.07), (ax, ay1), (ax + SIZE * 0.07, ay1 - SIZE * 0.07)],
                int(SIZE * 0.045), (255, 255, 255, 255))
    finish(img, mask, "5_tabs_flat")


def main():
    icon_compass_download()
    icon_window_photo_badge()
    icon_unlocked_photo()
    icon_magnifier_stack()
    icon_tabs_flat()

    # 5案を横に並べた一覧画像も作る(見比べやすいように)。
    thumbs = []
    for name in ["1_compass_download", "2_window_photo_badge", "3_unlocked_photo",
                 "4_magnifier_stack", "5_tabs_flat"]:
        im = Image.open(os.path.join(OUT_DIR, name + ".png")).convert("RGBA")
        bg = Image.new("RGBA", im.size, (30, 30, 30, 255))
        bg.paste(im, (0, 0), im)
        thumbs.append(bg.resize((300, 300)))
    sheet = Image.new("RGBA", (300 * 5 + 40 * 6, 300 + 40), (20, 20, 20, 255))
    for i, t in enumerate(thumbs):
        sheet.paste(t, (40 + i * (300 + 40), 20))
    sheet.convert("RGB").save(os.path.join(OUT_DIR, "contact_sheet.png"))
    print("wrote contact sheet")


if __name__ == "__main__":
    main()
