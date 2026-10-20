# 写真圧縮（iPhoneアプリ）

iPhoneの写真をまとめて圧縮・形式変換し、必要なら元の写真を削除できるアプリです。

## できること

| 機能 | 内容 |
|---|---|
| 写真の選択 | 「日ごと／月ごと／年ごと」に写真をまとめて表示。見出しの「選択」でその日・月・年を一括選択、写真をタップで1枚ずつ選択／解除。メニューから全選択・全解除 |
| 圧縮 | 画質（30〜100%）と最大サイズ（長辺 4032〜1024px／元のサイズ）を指定。保存形式は JPEG または HEIC。小さくならない写真は自動でスキップ |
| JPEG / PNG 変換 | 選んだ写真を JPEG または PNG に変換（すでに同じ形式の写真はスキップ） |
| 元の写真の削除 | 処理後の画面で「元の写真を削除しますか？」を表示。削除する写真を個別に選んで削除、または削除せずに閉じることができる。削除した写真は「最近削除した項目」に30日間残る |

- 新しい写真は**元の写真と同じ撮影日・位置情報・お気に入り**で写真アプリに保存されるため、並び順が崩れません。
- 撮影情報（Exif・GPS）も引き継ぎます。写真の向きは正しく回転したうえで保存します。
- iCloudにしかない写真は自動でダウンロードしてから処理します。
- 削除の対象になるのは、新しい写真の保存に成功した元の写真だけです。

## 動かすために必要なもの

- **Mac**（Xcode 16 以降）
  ※ iPhoneアプリのビルドはWindowsではできません
- iPhone（iOS 17 以降）と USB ケーブル
- Apple ID（無料でも可。無料の場合、アプリは7日ごとに入れ直しが必要）

## iPhoneに入れる手順

1. この `写真圧縮アプリ` フォルダを Mac にコピーする
2. `PhotoSqueeze.xcodeproj` をダブルクリックして Xcode で開く
3. 左の一覧で一番上の **PhotoSqueeze** → **Signing & Capabilities** を開き、**Team** に自分の Apple ID を選ぶ
   （「Bundle Identifier が使えない」と出たら、末尾を `PhotoSqueeze2` などに変える）
4. iPhone を Mac につなぎ、Xcode 上部の実行先で自分の iPhone を選ぶ
5. ▶（Run）ボタンを押す
6. 初回は iPhone の「設定 → 一般 → VPNとデバイス管理」で開発元を「信頼」する
   （iOS 16 以降は「設定 → プライバシーとセキュリティ → デベロッパモード」をオンにする必要があります）
7. アプリ起動後、写真へのアクセスは **「フルアクセスを許可」** を選ぶ

## 使い方

1. 上の切り替えで「日ごと／月ごと／年ごと」を選ぶ
2. 見出し右の「選択」でまとめて選ぶ、または写真をタップして個別に選ぶ（見出しの ▼ で折りたたみ）
3. 下の **圧縮** または **JPEG / PNG 変換** を押し、設定を決めて開始
4. 完了画面で結果を確認
   - 元の写真を消す場合：一覧で削除する写真を選び「選択した元の写真を削除」→ iOS の確認で「削除」
   - 元の写真を残す場合：そのまま「閉じる」

## ファイル構成

```
写真圧縮アプリ/
├─ PhotoSqueeze.xcodeproj      Xcodeプロジェクト
└─ PhotoSqueeze/
   ├─ PhotoSqueezeApp.swift    アプリの入口
   ├─ PhotoLibrary.swift       写真の読み込み・日/月/年グループ化・選択状態
   ├─ ContentView.swift        写真一覧画面
   ├─ JobSettingsView.swift    圧縮／変換の設定画面
   ├─ JobRunner.swift          一括処理と元写真の削除
   ├─ ResultView.swift         進捗・結果・削除画面
   ├─ ImageProcessor.swift     画像の縮小・再エンコード・保存・削除
   └─ Assets.xcassets          アプリアイコン・テーマ色
```

## うまく開けない場合

`PhotoSqueeze.xcodeproj` が開けない（Xcode 15 以前など）場合は、Xcode で新規プロジェクト（iOS → App、Interface: SwiftUI、名前 PhotoSqueeze）を作成し、`PhotoSqueeze` フォルダ内の `.swift` ファイルと `Assets.xcassets` を差し替えてください。そのうえで Target の **Info** に次の2項目を追加します。

- `Privacy - Photo Library Usage Description`：写真を日付ごとに表示し、圧縮・変換・削除するために使用します。
- `Privacy - Photo Library Additions Usage Description`：圧縮・変換した写真を写真ライブラリに保存するために使用します。
