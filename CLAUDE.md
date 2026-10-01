# memode

左 Shift のダブルタップで出し入れするポップアップ型のエディタ（自分専用の Mac アプリ）。
計画と決めたことは `docs/plans/2026-10-01-1034memode-popup-editor.md`。

## 構成

- `App/`: Swift（AppKit）。ポップアップ（NSPanel）・メニュー・ファイルの読み書き・Swift と JS の受け渡し
- `web/`: エディタ部分（Vite + TypeScript + Monaco）。ビルド結果 `web/dist/editor` を `.app` の Resources/editor に入れ、
  `memode-editor://app/` という独自の URL スキームで読む（`file://` だと Monaco の worker が動かない）
- Swift ⇄ JS のやり取りは `web/src/bridge.ts`（`EditorHost`）だけを通す。エディタは Monaco に決定済み（日本語入力をユーザーが確認。2026-10-01）
- パネルは nonactivating（前面のアプリを切り替えずにキー入力だけ受ける）。activating への切り替えは dev 版のメニューに残してある
- 見た目は半透明（2026-10-01 にモックから「G. Layer」を選んだ）。パネルの下地は NSVisualEffectView（`.hudWindow`・`state = .active`。
  nonactivating なので既定のままだと非アクティブの灰色になる）で、WKWebView はその上に載る。ページは枠に薄い色だけ塗り、
  文字を書く面（`.editor-host`）だけ濃い板にする。Monaco のテーマは背景を透明にしてある（`languagedefs.ts`）
- `web/src/workspace.ts`: タブ（文書 = Monaco の model）と左右分割（グループ。最大 2 つ）。同じ文書を左右で開くと model を共有する。
  `quickpick.ts` は上に出る絞り込み付きの一覧（言語の選択・Cmd+P）
- 保存・セッション: 中身とタブの状態は JS（`web/src/files.ts`・`session.ts`）、ファイルの読み書き・確認のダイアログ・`session.json` は
  Swift（`DocumentService`・`FileIO`・`SessionStore`）。JS は Swift から `restore` を受け取るまでセッションを書かない（起動直後の空の状態で上書きしないため）
- ファイルを開く: Cmd+O・Cmd+P・`memode <path>`（`scripts/memode`。`memode://open?path=<encodeURIComponent>` を `open -b` で開く）は、どれも
  Swift の `DocumentService.open(paths:)` を通る。登録フォルダ・最近使ったファイルは `<データ>/folders.json`・`recent.json`。
  Cmd+P の一覧（`FolderIndex`）は**ホームの下全部**（除く: ~/Library（CloudStorage 以外）・~/OrbStack・~/Applications・~/Music・~/Movies・~/Pictures・
  ホーム直下の隠しディレクトリ・どこにあっても node_modules / build / .git / .ssh 等）と、登録フォルダ全部（ホームの外や、ホームの一覧で除いている場所を探したいとき）。git のリポジトリの中は `git ls-files`（.gitignore に従う）。
  開けないファイル（画像・PDF・圧縮ファイル等の拡張子 `FolderIndex.unopenableExtensions`、10MB を超えるもの）は一覧に入れない。中身は読まずに拡張子と大きさだけで決める。
  起動時に裏で作り、Cmd+P のときに 5 分より古ければ裏で作り直す。JS には変わったときだけパスの一覧を送る。
  git は `/usr/bin/git` でなく `xcrun --find git` の場所を使う（入口の方はアプリから初回に数秒かかる）。
  たどるときは `FileManager.enumerator(atPath:)` の相対パスを使う（URL でたどると /var と /private/var のように書き方がずれ、除く場所の判定が狂った）
- `mise run install-cli` で `~/.local/bin/memode` に入れる
- 終了時は `applicationShouldTerminate` で `.terminateLater` を返し、JS から最後のセッションが届いて書き終わるまで待つ（3 秒で諦める）。
  この待ち合わせは main キューでなく run loop に載せる（終了が main キューのジョブの中から呼ばれると、main キューに積んだものは動かない）
- ウィンドウの位置と大きさは画面ごとに `<データ>/window.json` に覚える（キーはディスプレイの UUID、値は画面の左下からの位置）。
  出すときはマウスのある画面で覚えたものを使い、無ければ中央に 80%。メニューバーとメインメニューの「ウィンドウの位置とサイズを元に戻す」で消す。
  掴んで動かせるのはタブバーのタブの右の空きだけ。JS（`dragregions.ts`）がその矩形を送っておき、Swift の `PopupPanel.sendEvent` が
  mousedown のときに判定して `performDrag` する（mousedown を JS から回してからでは間に合わない）
- メニューの操作は Swift の `AppDelegate.perform` を通り、タブと分割に関わるものは `{type: "command"}` として JS に送る
- `web/src/monaco.generated.ts` は `web/scripts/gen-monaco-entry.mjs` が毎回作る（言語サービスを除いた Monaco の読み込み口。gitignore）
- 言語: `languages.ts` の `languageForPath` が、Monaco の登録表 → 追加の表（`.zshrc`→shell・`.plist`→xml・`.toml`→ini・`.vue`→html 等）→ 1 行目の shebang の順で決める。
  JSON は言語サービスごと外したので登録されておらず、`languagedefs.ts` で色付けの部品（ワーカー不要）だけ借りて登録し直している。ignore・diff も同じファイルに Monarch で書いた
- アプリのショートカットは `App/MainMenu.swift` のメインメニューに置く（Monaco 側でこれらのキーを使わない）。
  Ctrl+Tab だけはメニューのキーとして届かないので、`bridge.ts` で拾って `action` として Swift に回す

## dev 版と常用版

| | dev 版（Debug） | 常用版（Release） |
|---|---|---|
| 表示名 | Memode-dev | Memode |
| bundle id | local.nyshk97.memode.dev | local.nyshk97.memode |
| URL スキーム | memode-dev:// | memode:// |
| ログ | ~/Library/Logs/memode-dev/memode.log | ~/Library/Logs/memode/memode.log |
| データ | ~/Library/Application Support/Memode-dev/ | ~/Library/Application Support/Memode/ |

データは v0.1.1 まで `~/Memode-dev`・`~/Memode Data` に置いていた。起動時に新しい置き場が無ければフォルダごと移す（`AppInfo.migrateLegacyData`）

## ビルドと起動

- `mise run build`: web のビルド → 署名用 xcconfig の生成 → xcodegen → xcodebuild（dev 版）
- `mise run start` / `mise run stop`: dev 版を起動（ポップアップを出す）/ 終了
- 署名のハッシュ・Team ID は public リポジトリに書かない。`scripts/gen-signing-xcconfig.sh` が keychain から引いて `*.local.xcconfig`（gitignore）に書く
- `.xcodeproj` は生成物（gitignore）。設定は `project.yml` を直す

## リリース

- 手順は 1 つ: `docs/CHANGELOG.md` の `[Unreleased]` を埋めて commit・push → `mise run release [patch|minor|major|x.y.z]`。
  ほかの経路（xcodebuild と gh release create を直接叩く等）を書き足さない（署名・公証が抜けた版が出る）
- 配布物は配信用の public リポジトリ `nyshk97/memode-releases` の GitHub Release に置き、Sparkle の feed は
  `releases/latest/download/appcast.xml`。cask は `nyshk97/homebrew-tap` の `Casks/memode.rb`（リリースで自動更新）。`memode` コマンドは cask の `binary` で入る
- Sparkle の EdDSA 鍵は keychain の account `memode`。控えは `~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-memode-private.key`
- 署名の ID は `scripts/gen-signing-xcconfig.sh` が keychain から決める（public リポジトリなので Team ID もハッシュも書かない）
- アイコンは `mise run icon`（`scripts/make-icon.swift`）で作り直す。生成した PNG はコミットする
- 常用版（Memode）と dev 版（Memode-dev）を同時に動かすと、左 Shift のダブルタップで両方が反応する。開発しないときは dev 版を止める

## 検証

`VERIFY.md` を見る。dev 版の起動引数 `--selftest` で、キー操作・メニュー・クリップボード・フォーカスの戻りを自動で確かめられる。
