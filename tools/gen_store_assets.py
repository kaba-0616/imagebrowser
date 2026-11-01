"""ストア用クリエイティブの SVG を作る(ImageSaver の生成スクリプトと同じ作り)。

- ストア掲載用/プロダクトページ/ … ヘッダ / 検索結果アセット
- ストア掲載用/Duo/              … iPhone Duo のスクリーンショット(外側 1398×2034)

SVG が原本で、PNG は tools/svg2png.swift で書き出す(ワークスペース共通ルール)。
端末画面の元画像は Duo/src/ に置き、tools/simcheck/run_shots.sh で撮り直せる。

  python3 tools/gen_store_assets.py
"""
import base64
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.join(ROOT, "ストア掲載用")

# アプリアイコン(tools/gen_app_icon.py)と同じ緑。
G0, G1 = "#0EA58C", "#065C4E"

# **空白を含む名前にしない。** 引き当てられず、エラーも出ないまま明朝で描かれる。
FONT_FAMILY = "RoundedMplus1cBold"


def font_face():
    """ストア用の書体は Rounded Mplus 1c Bold(全プロジェクト共通)。

    **相対パスの url() では読めない**ので base64 で SVG に抱える。
    """
    with open(os.path.join(ROOT, "tools", "fonts", "rounded-mplus-1c-bold.ttf"), "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    return (f'<style>@font-face{{font-family:"{FONT_FAMILY}";font-weight:700;'
            f'src:url(data:font/ttf;base64,{b64}) format("truetype")}}</style>')


def gradient(w, h):
    return f'''<linearGradient id="bg" x1="0" y1="0" x2="{w * 0.25:.0f}" y2="{h}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{G0}"/>
      <stop offset="1" stop-color="{G1}"/>
    </linearGradient>'''


def motif(cx, cy, scale):
    """アイコンと同じ「重ねた写真 + 虫眼鏡」。

    ローカル 1000 単位系で、中心は原点、占有は おおよそ ±340。レンズの輪の
    内側は背景を透かす(白の上に白の輪が消えないよう、アイコンと同じくり抜き)。
    """
    w, h, r = 380, 300, 22
    bx, by = -w / 2 - 30, -h / 2 - 20
    layers = [(-50, "#9FE7DA"), (-25, "#C9F3EB"), (0, "#FFFFFF")]
    rects = "".join(
        f'<rect x="{bx + o}" y="{by + o}" width="{w}" height="{h}" rx="{r}" fill="{c}"/>'
        for o, c in layers)
    mx, my, mr, ring = 110, 80, 135, 32
    lens = mr + ring / 2
    return f'''
    <g transform="translate({cx:.1f},{cy:.1f}) scale({scale:.4f})">
      <mask id="lens" maskUnits="userSpaceOnUse" x="-500" y="-500" width="1000" height="1000">
        <rect x="-500" y="-500" width="1000" height="1000" fill="#FFFFFF"/>
        <circle cx="{mx}" cy="{my}" r="{lens}" fill="#000000"/>
      </mask>
      <g mask="url(#lens)">{rects}
        <path d="M {bx + 44} {by + h - 42} L {bx + 136} {by + 120} L {bx + 200} {by + 196} L {bx + 244} {by + 148} L {bx + 330} {by + h - 42} Z"
              fill="{G1}" fill-opacity="0.55"/>
        <circle cx="{bx + 92}" cy="{by + 78}" r="30" fill="{G0}" fill-opacity="0.65"/>
      </g>
      <circle cx="{mx}" cy="{my}" r="{mr}" fill="none" stroke="#FFFFFF" stroke-width="{ring}"/>
      <path d="M {mx + mr * 0.72:.1f} {my + mr * 0.72:.1f} L {mx + mr * 1.55:.1f} {my + mr * 1.55:.1f}"
            stroke="#FFFFFF" stroke-width="44" stroke-linecap="round"/>
    </g>'''


def background(w, h):
    return f'''
  <defs>
    {font_face()}
    {gradient(w, h)}
  </defs>
  <rect width="{w}" height="{h}" fill="url(#bg)"/>'''


def header(w, h):
    """ヘッダ。**文字は入れない。**

    iPhone のプロダクトページでは 16:9 の **横は中央の約 52%、縦は上端から約 66%**
    しか見えない(ImageSaver で実測)。絵柄はその内側に上寄せで収める。
    """
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">{background(w, h)}
  {motif(w / 2, h * 0.30, h / 1000 * 0.82)}
</svg>'''


def search(w, h):
    """検索結果アセット。**価格に触れる言葉は入れない**(Guideline 2.3.7)。"""
    unit = h / 1000
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">{background(w, h)}
  {motif(w / 2, h * 0.38, unit * 0.74)}
  <text x="{w / 2:.0f}" y="{h * 0.84:.0f}" text-anchor="middle"
        font-family="{FONT_FAMILY}" font-weight="700" font-size="{unit * 84:.0f}"
        fill="#FFFFFF" letter-spacing="{unit * 3:.0f}">保存できない画像も保存できる</text>
</svg>'''


def duo_shot(screen, lines):
    """既存の iPhone / iPad 版と同じ作り: 緑の地に白のコピー、下に端末の枠と画面。"""
    W, H = 1398, 2034
    screen_w = 870
    screen_h = round(screen_w * H / W)
    screen_x = (W - screen_w) // 2
    screen_y = 600
    pad, radius = 14, 66
    size, lead = 100, 136
    first = 310 if len(lines) > 1 else 372
    text = "".join(
        f'<text x="{W // 2}" y="{first + i * lead}" text-anchor="middle" '
        f'font-family="{FONT_FAMILY}" font-weight="700" font-size="{size}" '
        f'fill="#FFFFFF">{line}</text>'
        for i, line in enumerate(lines))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 {W} {H}">
  <defs>
    {font_face()}
    {gradient(W, H)}
    <clipPath id="screen">
      <rect x="{screen_x}" y="{screen_y}" width="{screen_w}" height="{screen_h}" rx="{radius}"/>
    </clipPath>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="18" stdDeviation="26" flood-color="#032A24" flood-opacity="0.45"/>
    </filter>
  </defs>
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  {text}
  <rect x="{screen_x - pad}" y="{screen_y - pad}" width="{screen_w + pad * 2}" height="{screen_h + pad * 2}"
        rx="{radius + pad}" fill="#15161A" filter="url(#shadow)"/>
  <image xlink:href="{screen}" x="{screen_x}" y="{screen_y}" width="{screen_w}" height="{screen_h}"
         preserveAspectRatio="xMidYMid slice" clip-path="url(#screen)"/>
</svg>'''


TARGETS = [
    ("プロダクトページ/header-5244x2950.svg", header(5244, 2950)),
    ("プロダクトページ/search-1920x1280.svg", search(1920, 1280)),
    ("Duo/Duo_IB_1.svg", duo_shot("src/A-長押し.png", ["「この画像欲しい」", "画像を長押しで保存"])),
    ("Duo/Duo_IB_2.svg", duo_shot("src/B-選択.png", ["一括での保存も可能"])),
    ("Duo/Duo_IB_3.svg", duo_shot("src/C-タブ.png", ["他ブラウザ同様に", "タブもあります"])),
]

if __name__ == "__main__":
    for rel, svg in TARGETS:
        path = os.path.join(STORE, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(svg)
        print(path)
