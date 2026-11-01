# ストア掲載用の画像

| 場所 | 用途 | 寸法 |
|---|---|---|
| `IB_*.png` | iPhone | 1320×2868 |
| `iPad_IB_*.png` | iPad | 2064×2752 |
| `Duo/Duo_IB_*` | iPhone Duo(外側の画面。ASC の `APP_IPHONE_DUO`) | 1398×2034 |
| `プロダクトページ/` | ヘッダ 5244×2950 / 検索結果 1920×1280 | |

Duo とプロダクトページは SVG が原本。文言や色を直すときは PNG ではなく
`tools/gen_store_assets.py` を直して作り直す。書体は Rounded Mplus 1c Bold
(`tools/fonts/`)。**価格に触れる言葉は入れない**(Guideline 2.3.7)。

```
python3 tools/gen_store_assets.py
cd ストア掲載用
swift ../tools/svg2png.swift プロダクトページ/search-1920x1280.svg プロダクトページ/search-1920x1280.png 1920 1280
swift ../tools/svg2png.swift Duo/Duo_IB_1.svg Duo/Duo_IB_1.png 1398 2034
```

Duo の端末画面は `tools/simcheck/run_shots.sh <Duo の UDID> <出力先>` で撮り、
`Duo/src/` に置く。先にシミュレータ向けに `-derivedDataPath build/sim` でビルドしておく。
内側の画面はシミュレータでは撮れない(`ios-dev-playbook.md`)。

ASC へは `tools/upload_store_assets.py`。ヘッダは差し替えるなら先に placement を消す。
