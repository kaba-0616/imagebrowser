# ImageBrowser

画像保存に特化した独立ブラウザアプリ(WKWebView自作)。通常のWebでは
弾かれる画像(サイト側JSによる保存ブロック、CSS背景画像、lazy-load埋め込み
画像)も保存できることを目的とする。ImageSaver(Safari Action Extension)
とは別プロジェクト。

## 機能

- 画像の長押しで個別保存(無課金でも利用可)
- ツールバーからページ内の全画像候補を一括抽出→選択保存(Pro限定)
- Pro: 買い切り(非消費型IAP)または月額/年額サブスクのどちらかで解除。
  一括抽出の利用と広告非表示がセットで付与される

## 開発環境

Windowsのみ・Mac/Xcode無しの制約下で開発している。詳細な運用ルールは
`../ios-dev-without-mac-playbook.md`を参照。

- XcodeGen(`project.yml`)でプロジェクト定義を管理。`.xcodeproj`はコミットしない
- `.github/workflows/build.yml`: push時に未署名ビルドでコンパイル確認
- `.github/workflows/testflight.yml`: 手動実行でTestFlightへ署名付きアップロード

## 開発時の検証

```
node tools/dryrun.js
```

`ImageBrowserApp/ImageExtraction/ImageCollector.js`の画像収集ロジックを、
実機ビルド無しに疑似DOM上で検証する。

## 未実施(要Apple Developer Portal/App Store Connect作業)

`docs/ci-signing-setup.md`(gitignore対象、非公開)を参照:

- App ID `jp.kaba.imagebrowser`の新規登録
- 配布用プロビジョニングプロファイルの新規作成
- AdMobでの新規アプリ登録(実App ID/広告ユニットIDへの差し替え)
- App Store ConnectでのIAPプロダクト登録(`pro.lifetime`/`pro.monthly`/`pro.yearly`)
