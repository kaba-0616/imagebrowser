# ImageBrowser

画像保存に特化した独立ブラウザアプリ(WKWebView自作)。通常のWebでは
弾かれる画像(サイト側JSによる保存ブロック、CSS背景画像、lazy-load埋め込み
画像)も保存できることを目的とする。ImageSaver(Safari Action Extension)
とは別プロジェクト。

現在TestFlightで配布中(v0.1.0)。App Store未公開。

## 機能

- 画像の長押しで個別保存(無課金でも利用可)。Safari風のフローティング
  メニュー(写真に保存/リンクをコピー)で保存操作を行う。サイト側が
  保存操作をブロックしているページや、サムネイルの上に別要素が重なって
  いるカード型レイアウトでも画像を検出できるよう対応済み
- ツールバーからページ内の全画像候補を一括抽出→選択保存(Pro限定)
- タブ機能(複数タブの開閉・切り替え、グリッド表示。開いていたページは
  アプリ再起動後も復元)
- ブックマーク(追加・一覧・削除)
- ページ内広告ブロック(WKContentRuleListによる主要広告/トラッキング
  ドメインのブロック。全ユーザー無料、設定画面でON/OFF切り替え可能)
- 設定画面: デフォルト検索エンジン切り替え(Google/Yahoo!/Bing)、
  広告ブロックのON/OFF、Pro状態確認・購入復元、プライバシーポリシー/
  サポートへのリンク
- 保存ログ(ページ読み込み・長押し検出・一括抽出・保存の一連の動きを記録。
  「保存が出てこない」時の切り分け用)
- Pro: 買い切り(非消費型IAP)または月額/年額サブスクのどちらかで解除。
  一括抽出の利用と広告非表示がセットで付与される
- AdMobバナー広告(Pro未購入時、画面下部に固定表示)

## 開発環境

Windowsのみ・Mac/Xcode無しの制約下で開発している。詳細な運用ルールは
`../ios-dev-without-mac-playbook.md`を参照。

- XcodeGen(`project.yml`)でプロジェクト定義を管理。`.xcodeproj`はコミットしない
- `.github/workflows/build.yml`: push時に未署名ビルドでコンパイル確認
- `.github/workflows/testflight.yml`: 手動実行でTestFlightへ署名付きアップロード
- バージョン運用ルールは`../ios-dev-without-mac-playbook.md`の
  「バージョン番号の運用ルール」に準拠(リリースまでは`0.x.x`固定、
  ビルド番号はpushのたびに必ず1つ上げる)

## 開発時の検証

```
node tools/dryrun.js
```

`ImageBrowserApp/ImageExtraction/ImageCollector.js`の画像収集ロジックを、
実機ビルド無しに疑似DOM上で検証する。主要ニュース/音楽サイト・SNS・
アイドル/タレント公式サイトを調査し、対応漏れが見つかるたびにここへ
テストケースを追加している。

## 実機での確認

`docs/real-device-checklist.md`に、TestFlightでインストール後に確認する
項目一覧をまとめている。新機能を出すたびに更新すること。

## 未実施(要Apple Developer Portal/App Store Connect作業)

`docs/ci-signing-setup.md`(gitignore対象、非公開)を参照:

- App Store提出用のスクリーンショット・審査情報の準備
- App Storeへの正式提出(現状TestFlightのみ)
