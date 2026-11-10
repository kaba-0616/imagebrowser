# 動画・音声の保存(VideoBrowser から統合)

閲覧中のページの動画・音声を保存する機能。2026-11-04 に単体アプリ VideoBrowser として
作り始め、**2026-11-10 にユーザー判断で ImageBrowser に統合した**(VideoBrowser は公開せずに
削除)。この文書は VideoBrowser の開発メモ(`docs/plan.md`)から、統合後も必要な部分を移したもの。

## 決まったこと(2026-11-10 ユーザー回答)

| 項目 | 決定 |
|---|---|
| 課金 | 新しい **Pro+**(広告オフ + 画像 + 動画)。月額 ¥1,000 / 年額 ¥10,000。今の Pro と同じサブスクのグループで、Pro より上の段 |
| 無料・Pro | 動画・音声は**保存できない**。一覧(検出結果)は見られ、保存しようとすると Pro+ の購入画面 |
| 買い切り(販売終了)の購入者 | Pro のまま。プラン一覧では Pro+ だけを勧める |
| 対象外のサイト | **DRM 配信だけ**(Netflix・Prime Video・Disney+・Hulu・U-NEXT・ABEMA・DAZN・Apple Music/TV・Spotify)。YouTube・Vimeo・SoundCloud(Guideline 5.2.3 の名指し)は制限していない。審査で指摘されたら `Media/DetectedMedia.swift` の `RestrictedSites` に足す |
| 保存形式 | MP4 / MP3 / M4A(無劣化)。保存先は写真 / ファイル、名前を変えられる |

商品 ID は `jp.kaba.imagebrowser.plus.monthly` / `jp.kaba.imagebrowser.plus.yearly`
(`StoreManager.swift` の `ProProduct`)。

## 仕組み

- **検出** `Media/MediaSniffer.js`(全フレーム、document 開始時): fetch / XHR の URL と
  Content-Type、`<video>`/`<audio>`/`<source>`、再生イベント、Resource Timing。
  直接リンクの動画は `decidePolicyFor navigationResponse` の MIME で拾う。
  報告先は `videoBrowserMedia`(`Browser/WebViewController+Media.swift`)。
  ツールバーの「film」ボタンに検出数のバッジ。
  **スクロールで足される動画も、一覧を開かずにバッジへ反映する**(2026-11-10、ユーザー報告
  「スクロールしても画像のように増えない」)。原因は、要素の走査が一覧を開いた瞬間だけだったこと:
  再生前の `<video preload="none">` は通信も再生イベントも起こさないので、それまで数えられなかった。
  今は MutationObserver(video/audio/source の追加と src 系属性の変化)とスクロールで 0.6 秒に
  まとめて走査し直す。遅延読み込みの `data-src` なども読む。
- **まとめて保存** 一覧の「選択」→ 選んで「n件を保存」→ `Save/BatchSaveView.swift`。
  動画は MP4(HLS は最高画質)で写真 / ファイル、音声は MP3 / M4A でファイル。名前は各項目の
  既定の名前(同名は `_2` を付ける)。1件ずつ順番に処理し、失敗した件は飛ばして続ける。
  ファイル行きは全部終わってから1回の書き出し画面にまとめる。処理中は画面の自動ロックを止める。
- **トーク**(message.sakurazaka46.com 等): 画像の「さかのぼり抽出」と同じ
  タイムライン取得(NetworkTap.js、キャッシュ付き)から、動画(mp4)・ボイス(m4a)を拾う。
  VideoBrowser では MediaSniffer.js に同じ処理を別に持っていたが、統合時に外した。
- **HLS** `Download/`: プレイリスト解析 → 画質選択 → セグメントを4並列で取得
  (AES-128 は CommonCrypto で復号)→
  - TS: 自前の分解器(`TSDemuxer`)で H.264/HEVC と AAC を取り出し、AVAssetWriter に無変換で書く
  - fMP4: つなげて書き出し直す
  - 音声が別プレイリストなら AVMutableComposition で合成
  ffmpeg は使っていない。DASH(.mpd)は検出だけで未対応。
- **保存** `Save/MediaSaver.swift`: 写真は `PHAssetCreationRequest`、ファイルは
  `UIDocumentPickerViewController(forExporting:)`。
- **計測** 保存できたら `save_media`(host・format・source = file/hls/talk)。

## 検証

- **シミュレータ**: `tools/simcheck/DriveUITests/SaveFlowUITests.swift`。
  写真への追加を `xcrun simctl privacy <UDID> grant photos-add jp.kaba.imagebrowser` で許可し、
  HLS 用に `hls.html`(Apple bipbop の m3u8 を `<video>` で埋め込んだページ)を
  `python3 -m http.server 8765` で出してから `xcodebuild test -scheme DriveUITests -only-testing:DriveUITests/SaveFlowUITests`。
  **m3u8 の URL を直接開くと iOS 標準の全画面プレーヤーになり、ツールバーが隠れる。**
  2026-11-10、統合後の ImageBrowser で3本とも通過: デモ MP4 → 写真(10.00秒)、
  音声 → MP3 → ファイル(保存先の選択画面まで)、bipbop 30分 → 写真(映像 1800.10秒 / 音声 1799.91秒)。
  `test4_ScrollAndBatch` は、スクロールで再生前の `<video>` が足されるページ(src と data-src が半々)を
  Mac から出して開く。2026-11-10、一覧を開かずにバッジが 4件 → 12件に増え、12件まとめて写真へ保存できた。
  **ローカルサーバーのポートは他のセッションが使っていることがある**(8765 は別セッションの hlspage だった)。
  開く前に `lsof -i :<port>` で配信元のフォルダを確かめる。
- **Mac 上の HLS 変換**: `tools/hlscheck/build.sh` → `./hlscheck <m3u8> <出力> [画質番号]`
  (アプリと同じソースを Mac 向けにビルドし、全フレームを復号して確かめる)。
  MP3 は `build_mp3check.sh` → `./mp3check <動画> <出力フォルダ>`。
- デモの動画・音声は `tools/demo/gen_demo_media.swift`、置き場所は
  `kaba-0616.github.io/imagebrowser-demo/videobrowser/`。

## HLS で踏んだ罠(すべて実データで原因を確かめてから直した)

- **AVAssetWriter は時刻順に交互に入れても止まる。** 受け付ける方のトラックから入れ、
  片方が尽きたら次のセグメントを待つ(`TSToMP4Writer.drain`)。
- **TS では B フレームの PTS < DTS がありうるが MP4 は不可**(-16364)。DTS を一律に前へずらす。
- **PES ≠ フレーム。** フレームの途中で次の PES が始まる配信がある(bipbop)。
  ES 側の AUD / first_mb_in_slice でフレームを区切り、PES の時刻は「その中で始まる最初のフレーム」に付ける。
- **AAC の magic cookie は ES_Descriptor 形式**。2バイトの AudioSpecificConfig を渡すと
  esds が壊れ、読み戻すと音声トラックが消える。
- **ADTS ヘッダの途中で PES が切れることがある。** 持ち越さないと 2.5% のフレームが消え、
  30分で44秒の音ズレになった。

## MP3(LAME)

iOS は MP3 を書き出せないので、LAME 3.100(LGPL v2 以降)を同梱している。

- ソースは `ThirdParty/lame/`。公式配布物の `libmp3lame/` と `include/lame.h` そのまま +
  手書きの `libmp3lame/config.h`。
- **`config.h` に `DECODE_ON_THE_FLY` を書かない。** LAME は値ではなく「定義されているか」を見るので、
  `0` と書いても使わない復号器を呼びに行き、`_hip_set_errorf` が未定義でリンクに失敗する。
- LGPL のため、アプリ本体に混ぜず **`LameMP3` フレームワーク**(project.yml)にしている。
  ライセンス表記・ソースの入手先は「設定 → ライセンス」。
- **差分ビルドの罠:** `#if canImport(LameMP3)` にしていた頃、フレームワークを足しても
  AudioConverter.swift が再コンパイルされず、MP3 の分岐が黙って消えていた。今は普通に `import LameMP3`。

## 残作業

1. ASC に Pro+ の2商品を作る(API。全175か国に価格、審査用スクリーンショット)。
2. 実機での確認(トーク・写真の権限・ファイルへの書き出しの完了・Pro+ の購入と切り替え)。
3. 「App のプライバシー」は増える項目なし(送るのは同じドメインと件数)。プライバシーポリシーの
   「画像の抽出・保存」の記述を「画像・動画」に広げる。
4. VideoBrowser の後片付け(ASC のアプリ削除はユーザー作業、Notion・GitHub・手元は API / コマンド)。
